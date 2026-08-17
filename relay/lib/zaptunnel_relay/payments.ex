defmodule ZaptunnelRelay.Payments do
  @moduledoc false

  use GenServer

  alias ZaptunnelRelay.PaymentProtocol

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def enabled?, do: Application.fetch_env!(:zaptunnel_relay, :payments_enabled)

  def challenge(node_id, realm) do
    GenServer.call(__MODULE__, {:challenge, node_id, realm}, payment_timeout())
  end

  def redeem(authorization, node_id) do
    with {:ok, proof} <- PaymentProtocol.parse_credential(authorization) do
      GenServer.call(__MODULE__, {:redeem, proof, node_id})
    end
  end

  def authorize_lease(token, node_id) do
    GenServer.call(__MODULE__, {:authorize_lease, token, node_id})
  end

  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts) do
    if enabled?() and byte_size(token_secret()) < 32 do
      {:stop, :payment_token_secret_too_short}
    else
      {table, quotes} = open_store(Application.get_env(:zaptunnel_relay, :payment_state_path))
      {quotes, expired_ids} = prune(quotes)
      delete_expired(table, expired_ids)
      {:ok, %{quotes: quotes, table: table}}
    end
  end

  @impl true
  def terminate(_reason, %{table: nil}), do: :ok
  def terminate(_reason, %{table: table}), do: :dets.close(table)

  @impl true
  def handle_call({:challenge, node_id, realm}, _from, state) do
    id = random_id("zq_")
    amount_sats = Application.fetch_env!(:zaptunnel_relay, :payment_price_sats)
    ttl_ms = Application.fetch_env!(:zaptunnel_relay, :payment_quote_ttl_ms)
    description = "Zaptunnel connection lease for " <> abbreviate(node_id)
    provider = Application.fetch_env!(:zaptunnel_relay, :invoice_provider)

    result =
      with {:ok, invoice} <-
             provider.create_invoice(
               amount_sats: amount_sats,
               description: description,
               expiry_seconds: div(ttl_ms, 1_000),
               label: id
             ),
           :ok <- validate_invoice(invoice) do
        expires_at = min(invoice.expires_at, System.system_time(:second) + div(ttl_ms, 1_000))

        quote = %{
          id: id,
          node_id: node_id,
          amount_sats: amount_sats,
          description: description,
          invoice: invoice.invoice,
          payment_hash: String.downcase(invoice.payment_hash),
          network: Application.fetch_env!(:zaptunnel_relay, :payment_network),
          expires_at: expires_at,
          redeemed: nil
        }

        l402_token =
          sign(%{
            "expires_at" => expires_at,
            "payment_hash" => quote.payment_hash,
            "quote_id" => id,
            "type" => "quote"
          })

        {mpp_header, mpp_challenge} = PaymentProtocol.mpp_challenge(quote, realm)

        response = %{
          amount_sats: amount_sats,
          expires_at: expires_at,
          invoice: quote.invoice,
          l402_token: l402_token,
          mpp_challenge: mpp_challenge,
          payment_hash: quote.payment_hash,
          protocols: ["mpp", "l402"],
          quote_id: id,
          www_authenticate: [mpp_header, PaymentProtocol.l402_challenge(quote, l402_token)]
        }

        {:ok, quote, response}
      end

    case result do
      {:ok, quote, response} ->
        ZaptunnelRelay.Telemetry.emit([:payment, :challenge], %{count: 1}, %{result: :ok})
        persist(state.table, quote)
        {quotes, expired_ids} = prune(state.quotes)
        delete_expired(state.table, expired_ids)
        {:reply, {:ok, response}, %{state | quotes: Map.put(quotes, id, quote)}}

      {:error, reason} ->
        ZaptunnelRelay.Telemetry.emit([:payment, :challenge], %{count: 1}, %{result: :error})
        {:reply, {:error, safe_reason(reason)}, state}
    end
  end

  def handle_call({:redeem, proof, node_id}, _from, state) do
    with {:ok, quote_id} <- proof_quote_id(proof),
         {:ok, quote} <- fetch_quote(state.quotes, quote_id),
         :ok <- verify_proof(proof, quote),
         :ok <- same_node(quote, node_id),
         :ok <- unexpired(quote.expires_at),
         {:ok, lease, quote} <- redeem_quote(quote) do
      quotes = Map.put(state.quotes, quote.id, quote)
      persist(state.table, quote)

      ZaptunnelRelay.Telemetry.emit([:payment, :redeem], %{count: 1}, %{
        protocol: proof.protocol,
        result: :ok
      })

      {:reply, {:ok, lease, PaymentProtocol.receipt(quote)}, %{state | quotes: quotes}}
    else
      {:error, reason} ->
        ZaptunnelRelay.Telemetry.emit([:payment, :redeem], %{count: 1}, %{
          protocol: proof.protocol,
          result: :error
        })

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:authorize_lease, token, node_id}, _from, state) do
    result =
      with {:ok, payload} <- verify(token),
           true <- payload["type"] == "lease",
           true <- payload["node_id"] == node_id,
           :ok <- unexpired(payload["expires_at"]),
           lease_id when is_binary(lease_id) <- payload["lease_id"] do
        {:ok, lease_id}
      else
        _invalid -> {:error, :invalid_lease}
      end

    {:reply, result, state}
  end

  def handle_call(:reset, _from, state) do
    if state.table, do: :dets.delete_all_objects(state.table)
    {:reply, :ok, %{state | quotes: %{}}}
  end

  defp proof_quote_id(%{protocol: :mpp, quote_id: id}), do: {:ok, id}

  defp proof_quote_id(%{protocol: :l402, token: token}) do
    with {:ok, %{"quote_id" => id, "type" => "quote"}} <- verify(token), do: {:ok, id}
  end

  defp verify_proof(%{protocol: :mpp, challenge: challenge, preimage: preimage}, quote) do
    {_header, expected} = PaymentProtocol.mpp_challenge(quote, challenge["realm"])

    if challenge == expected,
      do: verify_preimage(preimage, quote),
      else: {:error, :challenge_mismatch}
  end

  defp verify_proof(%{protocol: :l402, token: token, preimage: preimage}, quote) do
    with {:ok, payload} <- verify(token),
         true <- payload["quote_id"] == quote.id,
         true <- payload["payment_hash"] == quote.payment_hash do
      verify_preimage(preimage, quote)
    else
      _invalid -> {:error, :invalid_payment_token}
    end
  end

  defp verify_preimage(preimage, quote) when is_binary(preimage) do
    with {:ok, bytes} <- Base.decode16(preimage, case: :lower),
         true <- byte_size(bytes) == 32,
         {:ok, expected} <- Base.decode16(quote.payment_hash, case: :lower),
         true <- Plug.Crypto.secure_compare(:crypto.hash(:sha256, bytes), expected) do
      :ok
    else
      _invalid -> {:error, :invalid_preimage}
    end
  end

  defp verify_preimage(_preimage, _quote), do: {:error, :invalid_preimage}

  defp redeem_quote(%{redeemed: lease} = quote) when is_map(lease), do: {:ok, lease, quote}

  defp redeem_quote(quote) do
    lease_id = random_id("zl_")

    expires_at =
      System.system_time(:second) +
        div(Application.fetch_env!(:zaptunnel_relay, :payment_lease_ttl_ms), 1_000)

    token =
      sign(%{
        "expires_at" => expires_at,
        "lease_id" => lease_id,
        "node_id" => quote.node_id,
        "payment_hash" => quote.payment_hash,
        "type" => "lease"
      })

    lease = %{expires_at: expires_at, id: lease_id, token: token}
    {:ok, lease, %{quote | redeemed: lease}}
  end

  defp fetch_quote(quotes, id) do
    case Map.fetch(quotes, id) do
      {:ok, quote} -> {:ok, quote}
      :error -> {:error, :unknown_challenge}
    end
  end

  defp same_node(%{node_id: node_id}, node_id), do: :ok
  defp same_node(_quote, _node_id), do: {:error, :lease_node_mismatch}

  defp unexpired(expires_at) when is_integer(expires_at) do
    if expires_at >= System.system_time(:second), do: :ok, else: {:error, :payment_expired}
  end

  defp unexpired(_expires_at), do: {:error, :payment_expired}

  defp validate_invoice(%{invoice: invoice, payment_hash: hash, expires_at: expiry})
       when is_binary(invoice) and is_binary(hash) and byte_size(hash) == 64 and
              is_integer(expiry),
       do: :ok

  defp validate_invoice(_invoice), do: {:error, :invalid_invoice_response}

  defp sign(payload) do
    encoded = PaymentProtocol.encode(payload)

    signature =
      :crypto.mac(:hmac, :sha256, token_secret(), encoded) |> Base.url_encode64(padding: false)

    encoded <> "." <> signature
  end

  defp verify(token) do
    with [encoded, supplied] <- String.split(token, ".", parts: 2),
         {:ok, signature} <- Base.url_decode64(supplied, padding: false),
         expected <- :crypto.mac(:hmac, :sha256, token_secret(), encoded),
         true <- byte_size(signature) == byte_size(expected),
         true <- Plug.Crypto.secure_compare(signature, expected),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} <- Jason.decode(json) do
      {:ok, payload}
    else
      _invalid -> {:error, :invalid_payment_token}
    end
  end

  defp prune(quotes) do
    now = System.system_time(:second)

    Enum.reduce(quotes, {%{}, []}, fn {id, quote}, {kept, expired} ->
      lease_expires_at = get_in(quote, [:redeemed, :expires_at])

      if quote.expires_at >= now or (is_integer(lease_expires_at) and lease_expires_at >= now) do
        {Map.put(kept, id, quote), expired}
      else
        {kept, [id | expired]}
      end
    end)
  end

  defp open_store(nil), do: {nil, %{}}

  defp open_store(path) do
    :ok = File.mkdir_p(Path.dirname(path))
    table = :zaptunnel_payment_quotes
    {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path), type: :set)
    quotes = :dets.foldl(fn {id, quote}, acc -> Map.put(acc, id, quote) end, %{}, table)
    {table, quotes}
  end

  defp persist(nil, _quote), do: :ok
  defp persist(table, quote), do: :dets.insert(table, {quote.id, quote})

  defp delete_expired(nil, _ids), do: :ok
  defp delete_expired(table, ids), do: Enum.each(ids, &:dets.delete(table, &1))

  defp token_secret, do: Application.fetch_env!(:zaptunnel_relay, :payment_token_secret)
  defp payment_timeout, do: Application.fetch_env!(:zaptunnel_relay, :payment_invoice_timeout_ms)

  defp random_id(prefix),
    do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp abbreviate(<<prefix::binary-size(8), _::binary-size(50), suffix::binary-size(8)>>),
    do: prefix <> "…" <> suffix

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :billing_unavailable
end
