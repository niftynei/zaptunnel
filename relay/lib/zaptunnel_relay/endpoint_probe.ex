defmodule ZaptunnelRelay.EndpointProbe do
  @moduledoc false

  alias ZaptunnelRelay.Bolt8

  @init <<16::16, 0::16, 0::16>>
  @ping <<18::16, 16::16, 0::16>>
  @max_intervening_messages 256

  def verify(node_id, {ip, port}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, probe_timeout())
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, remote_static} <- tagged(Base.decode16(node_id, case: :mixed), :node_id),
         {:ok, socket} <- tagged(connect(ip, port, remaining(deadline)), :tcp_connect) do
      verify_protocol(socket, remote_static, deadline)
    else
      {:error, {_stage, _reason}} = error -> error
    end
  rescue
    _error -> {:error, {:internal, :exception}}
  end

  defp verify_protocol(socket, remote_static, deadline) do
    try do
      with {:ok, transport} <-
             tagged(
               Bolt8.handshake(socket, remote_static, timeout: remaining(deadline)),
               :bolt8_handshake
             ),
           {:ok, transport} <- tagged(Bolt8.send_message(socket, @init, transport), :init),
           {:ok, transport} <-
             tagged(
               await_message(socket, transport, deadline, @max_intervening_messages),
               :init
             ),
           {:ok, transport} <- tagged(Bolt8.send_message(socket, @ping, transport), :ping),
           {:ok, _transport} <-
             tagged(
               await_pong(socket, transport, deadline, @max_intervening_messages),
               :ping
             ) do
        :ok
      end
    after
      :gen_tcp.close(socket)
    end
  end

  defp connect(ip, port, timeout) do
    :gen_tcp.connect(ip, port, [:binary, active: false, packet: :raw, nodelay: true], timeout)
  end

  defp await_message(_socket, _transport, _deadline, 0),
    do: {:error, :message_limit}

  defp await_message(socket, transport, deadline, attempts) do
    if expired?(deadline) do
      {:error, :timeout}
    else
      case Bolt8.receive_message(socket, transport, remaining(deadline)) do
        {:ok, <<16::16, _body::binary>>, transport} ->
          {:ok, transport}

        {:ok, _other_message, transport} ->
          await_message(socket, transport, deadline, attempts - 1)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp await_pong(_socket, _transport, _deadline, 0),
    do: {:error, :message_limit}

  defp await_pong(socket, transport, deadline, attempts) do
    if expired?(deadline) do
      {:error, :timeout}
    else
      case Bolt8.receive_message(socket, transport, remaining(deadline)) do
        {:ok, <<19::16, 16::16, _ignored::binary-size(16)>>, transport} ->
          {:ok, transport}

        {:ok, _other_message, transport} ->
          await_pong(socket, transport, deadline, attempts - 1)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp tagged({:ok, value}, _stage), do: {:ok, value}
  defp tagged(:ok, _stage), do: :ok
  defp tagged({:error, reason}, stage), do: {:error, {stage, safe_reason(reason)}}

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :error

  defp probe_timeout do
    Application.fetch_env!(:zaptunnel_relay, :verification_timeout_ms)
  end

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 1)
  end

  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline
end
