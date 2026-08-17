defmodule ZaptunnelRelay.Billing.Commando do
  @moduledoc false

  alias ZaptunnelRelay.{Address, Bolt8, Dialer}

  @init <<16::16, 0::16, 0::16>>
  @request_type 19_535
  @response_continues 22_859
  @response_type 22_861
  @max_messages 512

  def call(method, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, node_id} <- Base.decode16(Keyword.fetch!(opts, :node_id), case: :mixed),
         {:ok, parsed} <- Address.parse(Keyword.fetch!(opts, :address)),
         {:ok, target} <-
           Address.resolve(parsed,
             allow_private?: true,
             allow_onion?: not is_nil(Application.get_env(:zaptunnel_relay, :tor_socks_proxy))
           ),
         {:ok, socket} <- Dialer.connect(target, timeout: remaining(deadline)) do
      try do
        with {:ok, transport} <- Bolt8.handshake(socket, node_id, timeout: remaining(deadline)),
             {:ok, transport} <- Bolt8.send_message(socket, @init, transport),
             {:ok, transport} <- await_init(socket, transport, deadline, @max_messages),
             request_id <- :crypto.strong_rand_bytes(8),
             request <-
               Jason.encode!(%{
                 id: "zaptunnel:billing:#{method}:#{Base.encode16(request_id, case: :lower)}",
                 method: method,
                 params: params,
                 rune: Keyword.fetch!(opts, :rune)
               }),
             {:ok, transport} <-
               Bolt8.send_message(
                 socket,
                 <<@request_type::16, request_id::binary, request::binary>>,
                 transport
               ),
             {:ok, response} <-
               await_response(socket, transport, request_id, deadline, @max_messages, <<>>),
             {:ok, decoded} <- Jason.decode(response) do
          case decoded do
            %{"result" => result} -> {:ok, result}
            %{"error" => _error} -> {:error, :commando_rpc_error}
            _invalid -> {:error, :invalid_commando_response}
          end
        end
      after
        :gen_tcp.close(socket)
      end
    else
      _error -> {:error, :billing_unavailable}
    end
  rescue
    _error -> {:error, :billing_unavailable}
  end

  defp await_init(_socket, _transport, _deadline, 0), do: {:error, :message_limit}

  defp await_init(socket, transport, deadline, remaining_messages) do
    case Bolt8.receive_message(socket, transport, remaining(deadline)) do
      {:ok, <<16::16, _body::binary>>, transport} ->
        {:ok, transport}

      {:ok, <<18::16, pong_bytes::16, _ignored_length::16, _ignored::binary>>, transport} ->
        pong = <<19::16>> <> :binary.copy(<<0>>, pong_bytes)

        with {:ok, transport} <- Bolt8.send_message(socket, pong, transport) do
          await_init(socket, transport, deadline, remaining_messages - 1)
        end

      {:ok, _message, transport} ->
        await_init(socket, transport, deadline, remaining_messages - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_response(_socket, _transport, _id, _deadline, 0, _chunks),
    do: {:error, :message_limit}

  defp await_response(socket, transport, id, deadline, remaining_messages, chunks) do
    case Bolt8.receive_message(socket, transport, remaining(deadline)) do
      {:ok, <<@response_continues::16, ^id::binary-size(8), chunk::binary>>, transport} ->
        await_response(socket, transport, id, deadline, remaining_messages - 1, chunks <> chunk)

      {:ok, <<@response_type::16, ^id::binary-size(8), chunk::binary>>, _transport} ->
        {:ok, chunks <> chunk}

      {:ok, <<18::16, pong_bytes::16, _ignored_length::16, _ignored::binary>>, transport} ->
        pong = <<19::16>> <> :binary.copy(<<0>>, pong_bytes)

        with {:ok, transport} <- Bolt8.send_message(socket, pong, transport) do
          await_response(socket, transport, id, deadline, remaining_messages - 1, chunks)
        end

      {:ok, _message, transport} ->
        await_response(socket, transport, id, deadline, remaining_messages - 1, chunks)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 1)
end
