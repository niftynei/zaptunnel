defmodule ZaptunnelRelay.Bolt8 do
  @moduledoc false

  @protocol_name "Noise_XK_secp256k1_ChaChaPoly_SHA256"
  @prologue "lightning"

  defstruct [:ck, :h, :e_private, :static_private, :remote_static, :temp_k2]

  defmodule Transport do
    @moduledoc false
    defstruct [:send_key, :receive_key, :send_ck, :receive_ck, send_nonce: 0, receive_nonce: 0]
  end

  def handshake(socket, remote_static, opts \\ []) do
    timeout = Keyword.fetch!(opts, :timeout)
    static_private = Keyword.get_lazy(opts, :static_private, &private_key/0)
    ephemeral_private = Keyword.get_lazy(opts, :ephemeral_private, &private_key/0)

    with {:ok, act1, state} <- initiate(remote_static, static_private, ephemeral_private),
         :ok <- :gen_tcp.send(socket, act1),
         {:ok, act2} <- :gen_tcp.recv(socket, 50, timeout),
         {:ok, act3, transport} <- finish_act2(state, act2),
         :ok <- :gen_tcp.send(socket, act3) do
      {:ok, transport}
    end
  end

  def initiate(remote_static, static_private, ephemeral_private) do
    with :ok <- compressed_key(remote_static),
         {:ok, _static_public} <- public_key(static_private),
         {:ok, ephemeral_public} <- public_key(ephemeral_private),
         {:ok, shared_secret} <- ecdh(ephemeral_private, remote_static) do
      h = hash(@protocol_name)
      ck = h
      h = mix_hash(h, @prologue)
      h = mix_hash(h, remote_static)
      h = mix_hash(h, ephemeral_public)
      {ck, temp_k1} = hkdf(ck, shared_secret)
      ciphertext = encrypt(temp_k1, 0, h, <<>>)
      h = mix_hash(h, ciphertext)

      state = %__MODULE__{
        ck: ck,
        h: h,
        e_private: ephemeral_private,
        static_private: static_private,
        remote_static: remote_static,
        temp_k2: nil
      }

      {:ok, <<0, ephemeral_public::binary, ciphertext::binary>>, state}
    end
  rescue
    _error -> {:error, :invalid_key}
  end

  def finish_act2(
        %__MODULE__{} = state,
        <<0, remote_ephemeral::binary-size(33), tag::binary-size(16)>>
      ) do
    with :ok <- compressed_key(remote_ephemeral),
         {:ok, shared_secret} <- ecdh(state.e_private, remote_ephemeral) do
      h = mix_hash(state.h, remote_ephemeral)
      {ck, temp_k2} = hkdf(state.ck, shared_secret)

      with {:ok, <<>>} <- decrypt(temp_k2, 0, h, tag) do
        h = mix_hash(h, tag)
        static_public = Secp256k1.pubkey(state.static_private, :compressed)
        encrypted_static = encrypt(temp_k2, 1, h, static_public)
        h = mix_hash(h, encrypted_static)

        with {:ok, final_secret} <- ecdh(state.static_private, remote_ephemeral) do
          {ck, temp_k3} = hkdf(ck, final_secret)
          final_tag = encrypt(temp_k3, 0, h, <<>>)
          {send_key, receive_key} = hkdf(ck, <<>>)

          transport = %Transport{
            send_key: send_key,
            receive_key: receive_key,
            send_ck: ck,
            receive_ck: ck
          }

          {:ok, <<0, encrypted_static::binary, final_tag::binary>>, transport}
        end
      end
    end
  rescue
    _error -> {:error, :invalid_handshake}
  end

  def finish_act2(_state, <<version, _rest::binary>>) when version != 0,
    do: {:error, :unsupported_version}

  def finish_act2(_state, _act2), do: {:error, :invalid_handshake}

  def send_message(socket, message, %Transport{} = transport) when byte_size(message) <= 65_535 do
    {length_ciphertext, transport} = encrypt_transport(<<byte_size(message)::16>>, transport)
    {message_ciphertext, transport} = encrypt_transport(message, transport)

    case :gen_tcp.send(socket, [length_ciphertext, message_ciphertext]) do
      :ok -> {:ok, transport}
      {:error, reason} -> {:error, reason}
    end
  end

  def receive_message(socket, %Transport{} = transport, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, encrypted_length} <- :gen_tcp.recv(socket, 18, remaining(deadline)),
         {:ok, <<length::16>>, transport} <- decrypt_transport(encrypted_length, transport),
         {:ok, encrypted_message} <- :gen_tcp.recv(socket, length + 16, remaining(deadline)),
         {:ok, message, transport} <- decrypt_transport(encrypted_message, transport) do
      {:ok, message, transport}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def valid_public_key?(<<prefix, _rest::binary-size(32)>> = public_key)
      when prefix in [2, 3] do
    private_key = <<0::248, 1>>

    case Secp256k1.ecdh(private_key, public_key) do
      shared_secret when is_binary(shared_secret) -> true
      _invalid -> false
    end
  rescue
    _error -> false
  end

  def valid_public_key?(_public_key), do: false

  defp encrypt_transport(plaintext, %Transport{} = transport) do
    ciphertext = encrypt(transport.send_key, transport.send_nonce, <<>>, plaintext)
    {key, ck, nonce} = advance_key(transport.send_key, transport.send_ck, transport.send_nonce)
    {ciphertext, %{transport | send_key: key, send_ck: ck, send_nonce: nonce}}
  end

  defp decrypt_transport(ciphertext, %Transport{} = transport) do
    case decrypt(transport.receive_key, transport.receive_nonce, <<>>, ciphertext) do
      {:ok, plaintext} ->
        {key, ck, nonce} =
          advance_key(transport.receive_key, transport.receive_ck, transport.receive_nonce)

        {:ok, plaintext, %{transport | receive_key: key, receive_ck: ck, receive_nonce: nonce}}

      {:error, _reason} = error ->
        error
    end
  end

  defp advance_key(key, ck, 999) do
    {new_ck, new_key} = hkdf(ck, key)
    {new_key, new_ck, 0}
  end

  defp advance_key(key, ck, nonce), do: {key, ck, nonce + 1}

  defp encrypt(key, nonce, associated_data, plaintext) do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :chacha20_poly1305,
        key,
        nonce(nonce),
        plaintext,
        associated_data,
        16,
        true
      )

    ciphertext <> tag
  end

  defp decrypt(key, nonce, associated_data, ciphertext) when byte_size(ciphertext) >= 16 do
    payload_size = byte_size(ciphertext) - 16
    <<payload::binary-size(payload_size), tag::binary-size(16)>> = ciphertext

    case :crypto.crypto_one_time_aead(
           :chacha20_poly1305,
           key,
           nonce(nonce),
           payload,
           associated_data,
           tag,
           false
         ) do
      :error -> {:error, :authentication_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  defp decrypt(_key, _nonce, _associated_data, _ciphertext),
    do: {:error, :authentication_failed}

  defp nonce(value), do: <<0::32, value::little-64>>

  defp hkdf(salt, input_key_material) do
    pseudo_random_key = :crypto.mac(:hmac, :sha256, salt, input_key_material)
    output1 = :crypto.mac(:hmac, :sha256, pseudo_random_key, <<1>>)
    output2 = :crypto.mac(:hmac, :sha256, pseudo_random_key, <<output1::binary, 2>>)
    {output1, output2}
  end

  defp mix_hash(hash, data), do: hash(hash <> data)
  defp hash(data), do: :crypto.hash(:sha256, data)

  defp ecdh(private_key, public_key) do
    case Secp256k1.ecdh(private_key, public_key) do
      shared_secret when is_binary(shared_secret) -> {:ok, shared_secret}
      {:error, _reason} -> {:error, :invalid_key}
    end
  end

  defp public_key(private_key) do
    case Secp256k1.pubkey(private_key, :compressed) do
      public_key when is_binary(public_key) -> {:ok, public_key}
      {:error, _reason} -> {:error, :invalid_key}
    end
  end

  defp compressed_key(<<prefix, _rest::binary-size(32)>>) when prefix in [2, 3], do: :ok
  defp compressed_key(_key), do: {:error, :invalid_key}

  defp private_key do
    private_key = :crypto.strong_rand_bytes(32)

    case public_key(private_key) do
      {:ok, _public_key} -> private_key
      {:error, _reason} -> private_key()
    end
  end

  defp remaining(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 1)
end
