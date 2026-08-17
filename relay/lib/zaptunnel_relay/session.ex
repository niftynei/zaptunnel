defmodule ZaptunnelRelay.Session do
  @moduledoc false

  @behaviour WebSock

  require Logger

  alias ZaptunnelRelay.Dialer

  @impl true
  def init(%{address: target, node_id: node_id}) do
    timeout = Application.fetch_env!(:zaptunnel_relay, :connect_timeout_ms)

    case Dialer.connect(target, timeout: timeout, active: :once) do
      {:ok, socket} ->
        Logger.debug("session connected node_id=#{node_id} target=#{format_address(target)}")
        ZaptunnelRelay.Telemetry.emit([:session, :start], %{count: 1})

        {:ok,
         %{
           socket: socket,
           node_id: node_id,
           bytes_from_browser: 0,
           bytes_from_node: 0,
           started_at: System.monotonic_time(:millisecond)
         }}

      {:error, reason} ->
        Logger.info("session connect failed node_id=#{node_id} reason=#{inspect(reason)}")
        {:stop, :normal}
    end
  end

  @impl true
  def handle_in({data, [opcode: :binary]}, state) do
    if byte_size(data) <= Application.fetch_env!(:zaptunnel_relay, :max_websocket_frame_bytes) do
      case :gen_tcp.send(state.socket, data) do
        :ok -> {:ok, %{state | bytes_from_browser: state.bytes_from_browser + byte_size(data)}}
        {:error, reason} -> {:stop, reason, state}
      end
    else
      {:stop, :frame_too_large, state}
    end
  end

  def handle_in({_data, [opcode: :text]}, state) do
    {:stop, :unsupported_data, state}
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    :ok = :inet.setopts(socket, active: :once)
    {:push, {:binary, data}, %{state | bytes_from_node: state.bytes_from_node + byte_size(data)}}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(reason, %{socket: socket} = state) do
    :gen_tcp.close(socket)

    ZaptunnelRelay.Telemetry.emit(
      [:session, :stop],
      %{
        duration_ms: System.monotonic_time(:millisecond) - state.started_at,
        bytes_from_browser: state.bytes_from_browser,
        bytes_from_node: state.bytes_from_node
      },
      %{node_id: state.node_id, reason: reason}
    )

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp format_address({ip, port}) do
    "#{:inet.ntoa(ip)}:#{port}"
  end

  defp format_address({:onion, host, port}), do: "#{host}:#{port}"
end
