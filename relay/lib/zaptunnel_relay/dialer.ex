defmodule ZaptunnelRelay.Dialer do
  @moduledoc false

  @tcp_options [:binary, active: false, packet: :raw, nodelay: true]

  @type target :: ZaptunnelRelay.Address.target()

  @spec connect(target(), keyword()) :: {:ok, port()} | {:error, atom()}
  def connect(target, opts \\ []) do
    timeout = Keyword.fetch!(opts, :timeout)
    active = Keyword.get(opts, :active, false)
    deadline = System.monotonic_time(:millisecond) + timeout

    case target do
      {ip, port} when is_tuple(ip) ->
        tcp_options = [:binary, active: active, packet: :raw, nodelay: true]
        :gen_tcp.connect(ip, port, tcp_options, remaining(deadline))

      {:onion, host, port} ->
        connect_onion(host, port, active, deadline, Keyword.get(opts, :proxy, tor_proxy()))
    end
  end

  defp connect_onion(_host, _port, _active, _deadline, nil), do: {:error, :onion_unavailable}

  defp connect_onion(host, port, active, deadline, {proxy_ip, proxy_port}) do
    with {:ok, socket} <-
           :gen_tcp.connect(proxy_ip, proxy_port, @tcp_options, remaining(deadline)) do
      case negotiate_socks(socket, host, port, deadline) do
        :ok ->
          case :inet.setopts(socket, active: active) do
            :ok -> {:ok, socket}
            {:error, reason} -> close_error(socket, safe_reason(reason))
          end

        {:error, reason} ->
          close_error(socket, reason)
      end
    else
      {:error, :timeout} -> {:error, :timeout}
      {:error, _reason} -> {:error, :tor_proxy_unavailable}
    end
  end

  defp negotiate_socks(socket, host, port, deadline) do
    host_bytes = :erlang.iolist_to_binary(host)

    with true <- byte_size(host_bytes) <= 255,
         :ok <- :gen_tcp.send(socket, <<5, 1, 0>>),
         {:ok, <<5, 0>>} <- recv(socket, 2, deadline),
         :ok <-
           :gen_tcp.send(
             socket,
             <<5, 1, 0, 3, byte_size(host_bytes), host_bytes::binary, port::16>>
           ),
         {:ok, <<5, reply, 0, address_type>>} <- recv(socket, 4, deadline),
         :ok <- socks_reply(reply),
         :ok <- discard_bound_address(socket, address_type, deadline) do
      :ok
    else
      false -> {:error, :invalid_onion_address}
      {:ok, <<5, _method>>} -> {:error, :tor_proxy_auth}
      {:ok, _unexpected} -> {:error, :tor_protocol_error}
      {:error, reason} when is_atom(reason) -> {:error, safe_reason(reason)}
    end
  end

  defp discard_bound_address(socket, 1, deadline), do: discard(socket, 4 + 2, deadline)
  defp discard_bound_address(socket, 4, deadline), do: discard(socket, 16 + 2, deadline)

  defp discard_bound_address(socket, 3, deadline) do
    with {:ok, <<length>>} <- recv(socket, 1, deadline) do
      discard(socket, length + 2, deadline)
    else
      {:ok, _unexpected} -> {:error, :tor_protocol_error}
      {:error, reason} -> {:error, safe_reason(reason)}
    end
  end

  defp discard_bound_address(_socket, _type, _deadline), do: {:error, :tor_protocol_error}

  defp discard(socket, length, deadline) do
    case recv(socket, length, deadline) do
      {:ok, _bytes} -> :ok
      {:error, reason} -> {:error, safe_reason(reason)}
    end
  end

  defp recv(socket, length, deadline) do
    :gen_tcp.recv(socket, length, remaining(deadline))
  end

  defp socks_reply(0), do: :ok
  defp socks_reply(2), do: {:error, :tor_connection_denied}
  defp socks_reply(3), do: {:error, :tor_network_unreachable}
  defp socks_reply(4), do: {:error, :tor_host_unreachable}
  defp socks_reply(5), do: {:error, :tor_connection_refused}
  defp socks_reply(6), do: {:error, :tor_ttl_expired}
  defp socks_reply(7), do: {:error, :tor_command_unsupported}
  defp socks_reply(8), do: {:error, :tor_address_unsupported}
  defp socks_reply(_reply), do: {:error, :tor_protocol_error}

  defp tor_proxy, do: Application.get_env(:zaptunnel_relay, :tor_socks_proxy)

  defp close_error(socket, reason) do
    :gen_tcp.close(socket)
    {:error, reason}
  end

  defp safe_reason(reason)
       when reason in [
              :timeout,
              :closed,
              :invalid_onion_address,
              :tor_proxy_auth,
              :tor_connection_denied,
              :tor_network_unreachable,
              :tor_host_unreachable,
              :tor_connection_refused,
              :tor_ttl_expired,
              :tor_command_unsupported,
              :tor_address_unsupported,
              :tor_protocol_error
            ],
       do: reason

  defp safe_reason(_reason), do: :tor_protocol_error

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 1)
  end
end
