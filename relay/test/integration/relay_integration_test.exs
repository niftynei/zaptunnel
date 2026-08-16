defmodule ZaptunnelRelay.RelayIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ZaptunnelRelay.{Admission, EndpointVerifier, RateLimiter, Router}
  alias ZaptunnelRelay.Application, as: RelayApplication

  defmodule AcceptProbe do
    def verify(_node_id, _address), do: :ok
  end

  @node_id "02" <> String.duplicate("11", 32)

  setup do
    previous_probe = Application.fetch_env!(:zaptunnel_relay, :endpoint_probe_module)
    Application.put_env(:zaptunnel_relay, :endpoint_probe_module, AcceptProbe)
    Admission.reset()
    EndpointVerifier.reset()
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:zaptunnel_relay, :endpoint_probe_module, previous_probe)
    end)

    :ok
  end

  test "HTTP admission and WebSocket transport forward opaque bytes end to end" do
    {target, target_port} = start_echo_server()

    {:ok, relay} =
      Bandit.start_link(
        plug: Router,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(relay)

    on_exit(fn ->
      if Process.alive?(relay), do: Process.exit(relay, :shutdown)
      if Process.alive?(target), do: Process.exit(target, :kill)
    end)

    {:ok, {{127, 0, 0, 1}, relay_port}} = ThousandIsland.listener_info(relay)
    ticket_path = request_ticket(relay_port, target_port)
    socket = websocket_connect(relay_port, ticket_path <> "/lightning")
    on_exit(fn -> :gen_tcp.close(socket) end)

    payload = :crypto.strong_rand_bytes(64)
    :ok = send_websocket_binary(socket, payload)
    assert {:ok, ^payload} = receive_websocket_binary(socket)

    assert {:error, _reason} = reuse_ticket(relay_port, ticket_path)
  end

  test "Bandit terminates HTTPS with the configured certificate files" do
    root = Path.join(System.tmp_dir!(), "zaptunnel-tls-#{System.unique_integer([:positive])}")
    certificate = Path.join(root, "certificate.pem")
    private_key = Path.join(root, "private-key.pem")
    File.mkdir_p!(root)

    {output, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          private_key,
          "-out",
          certificate,
          "-days",
          "1",
          "-subj",
          "/CN=localhost"
        ],
        stderr_to_stdout: true
      )

    assert is_binary(output)
    previous_tls = Application.fetch_env!(:zaptunnel_relay, :tls)
    Application.put_env(:zaptunnel_relay, :tls, %{certfile: certificate, keyfile: private_key})

    {:ok, relay} = Bandit.start_link(RelayApplication.server_options({127, 0, 0, 1}, 0))
    Process.unlink(relay)

    on_exit(fn ->
      if Process.alive?(relay), do: Process.exit(relay, :shutdown)
      Application.put_env(:zaptunnel_relay, :tls, previous_tls)
      File.rm_rf(root)
    end)

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(relay)
    Application.ensure_all_started(:ssl)

    {:ok, socket} =
      :ssl.connect(~c"127.0.0.1", port, [:binary, verify: :verify_none, active: false], 2_000)

    :ok =
      :ssl.send(
        socket,
        "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
      )

    response = receive_tls_until_closed(socket, <<>>)
    :ssl.close(socket)
    assert String.starts_with?(response, "HTTP/1.1 200")
    assert String.contains?(response, ~s({"status":"ok"}))
  end

  defp start_echo_server do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    pid =
      spawn(fn ->
        case :gen_tcp.accept(listener) do
          {:ok, socket} ->
            case :gen_tcp.recv(socket, 0, 2_000) do
              {:ok, bytes} -> :gen_tcp.send(socket, bytes)
              {:error, _reason} -> :ok
            end

            :gen_tcp.close(socket)

          {:error, _reason} ->
            :ok
        end

        :gen_tcp.close(listener)
      end)

    {pid, port}
  end

  defp request_ticket(relay_port, target_port) do
    body = Jason.encode!(%{node_id: @node_id, address: "127.0.0.1:#{target_port}"})

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, relay_port, [:binary, active: false, packet: :raw], 2_000)

    request = [
      "POST /v1/connections HTTP/1.1\r\n",
      "Host: 127.0.0.1:",
      Integer.to_string(relay_port),
      "\r\nContent-Type: application/json\r\nContent-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\nConnection: close\r\n\r\n",
      body
    ]

    :ok = :gen_tcp.send(socket, request)
    response = receive_until_closed(socket, <<>>)
    :gen_tcp.close(socket)
    assert String.starts_with?(response, "HTTP/1.1 201")
    [_headers, response_body] = String.split(response, "\r\n\r\n", parts: 2)

    %{"websocket_path" => ticket_path} = Jason.decode!(response_body)
    ticket_path
  end

  defp websocket_connect(port, path) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request = [
      "GET ",
      path,
      " HTTP/1.1\r\n",
      "Host: 127.0.0.1:",
      Integer.to_string(port),
      "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ",
      key,
      "\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ]

    :ok = :gen_tcp.send(socket, request)
    {:ok, headers} = receive_headers(socket, <<>>)
    assert String.starts_with?(headers, "HTTP/1.1 101")
    socket
  end

  defp reuse_ticket(port, path) do
    try do
      socket = websocket_connect(port, path <> "/lightning")
      :gen_tcp.close(socket)
      :ok
    rescue
      ExUnit.AssertionError -> {:error, :ticket_rejected}
    end
  end

  defp receive_headers(socket, buffer) do
    if :binary.match(buffer, "\r\n\r\n") == :nomatch do
      with {:ok, bytes} <- :gen_tcp.recv(socket, 0, 2_000) do
        receive_headers(socket, buffer <> bytes)
      end
    else
      {:ok, buffer}
    end
  end

  defp receive_until_closed(socket, buffer) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, bytes} -> receive_until_closed(socket, buffer <> bytes)
      {:error, :closed} -> buffer
    end
  end

  defp receive_tls_until_closed(socket, buffer) do
    case :ssl.recv(socket, 0, 2_000) do
      {:ok, bytes} -> receive_tls_until_closed(socket, buffer <> bytes)
      {:error, :closed} -> buffer
    end
  end

  defp send_websocket_binary(socket, payload) when byte_size(payload) < 126 do
    mask = :crypto.strong_rand_bytes(4)
    masked = mask(payload, mask)

    :gen_tcp.send(
      socket,
      <<0x82, Bitwise.bor(0x80, byte_size(payload)), mask::binary, masked::binary>>
    )
  end

  defp receive_websocket_binary(socket) do
    with {:ok, <<0x82, length>>} when length < 126 <- receive_exact(socket, 2),
         {:ok, payload} <- receive_exact(socket, length) do
      {:ok, payload}
    else
      _other -> {:error, :unexpected_websocket_frame}
    end
  end

  defp receive_exact(socket, bytes), do: :gen_tcp.recv(socket, bytes, 2_000)

  defp mask(payload, <<a, b, c, d>>) do
    key = {a, b, c, d}

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, elem(key, rem(index, 4))) end)
    |> :binary.list_to_bin()
  end
end
