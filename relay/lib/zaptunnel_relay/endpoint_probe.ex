defmodule ZaptunnelRelay.EndpointProbe do
  @moduledoc false

  alias ZaptunnelRelay.Bolt8

  @init <<16::16, 0::16, 0::16>>
  @ping <<18::16, 16::16, 0::16>>

  def verify(node_id, {ip, port}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, probe_timeout())
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, remote_static} <- Base.decode16(node_id, case: :mixed),
         {:ok, socket} <- connect(ip, port, remaining(deadline)) do
      try do
        with {:ok, transport} <-
               Bolt8.handshake(socket, remote_static, timeout: remaining(deadline)),
             {:ok, transport} <- Bolt8.send_message(socket, @init, transport),
             {:ok, transport} <- await_message(socket, transport, deadline, 16),
             {:ok, transport} <- Bolt8.send_message(socket, @ping, transport),
             {:ok, _transport} <- await_pong(socket, transport, deadline, 16) do
          :ok
        else
          {:error, _reason} -> {:error, :endpoint_unverified}
        end
      after
        :gen_tcp.close(socket)
      end
    else
      _error -> {:error, :endpoint_unverified}
    end
  rescue
    _error -> {:error, :endpoint_unverified}
  end

  defp connect(ip, port, timeout) do
    :gen_tcp.connect(ip, port, [:binary, active: false, packet: :raw, nodelay: true], timeout)
  end

  defp await_message(_socket, _transport, _deadline, 0),
    do: {:error, :too_many_messages}

  defp await_message(socket, transport, deadline, attempts) do
    case Bolt8.receive_message(socket, transport, remaining(deadline)) do
      {:ok, <<16::16, _body::binary>>, transport} -> {:ok, transport}
      {:ok, _other_message, transport} -> await_message(socket, transport, deadline, attempts - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_pong(_socket, _transport, _deadline, 0),
    do: {:error, :too_many_messages}

  defp await_pong(socket, transport, deadline, attempts) do
    case Bolt8.receive_message(socket, transport, remaining(deadline)) do
      {:ok, <<19::16, 16::16, _ignored::binary-size(16)>>, transport} ->
        {:ok, transport}

      {:ok, _other_message, transport} ->
        await_pong(socket, transport, deadline, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp probe_timeout do
    Application.fetch_env!(:zaptunnel_relay, :verification_timeout_ms)
  end

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 1)
  end
end
