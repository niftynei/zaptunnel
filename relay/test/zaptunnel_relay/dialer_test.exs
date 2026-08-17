defmodule ZaptunnelRelay.DialerTest do
  use ExUnit.Case, async: true

  alias ZaptunnelRelay.Dialer

  @onion "duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion"

  test "connects to an onion target through SOCKS5 without local DNS" do
    test_pid = self()

    {listener, proxy_port} =
      listen(fn socket ->
        assert {:ok, <<5, 1, 0>>} = :gen_tcp.recv(socket, 3, 1_000)
        :ok = :gen_tcp.send(socket, <<5, 0>>)

        assert {:ok, <<5, 1, 0, 3, length>>} = :gen_tcp.recv(socket, 5, 1_000)
        assert {:ok, request} = :gen_tcp.recv(socket, length + 2, 1_000)
        assert <<@onion::binary, 9_735::16>> = request
        send(test_pid, :onion_requested)

        :ok = :gen_tcp.send(socket, <<5, 0, 0, 1, 127, 0, 0, 1, 0, 1>>)
        assert {:ok, "browser bytes"} = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.send(socket, "node bytes")
      end)

    assert {:ok, socket} =
             Dialer.connect({:onion, @onion, 9_735},
               timeout: 1_000,
               proxy: {{127, 0, 0, 1}, proxy_port}
             )

    assert_receive :onion_requested
    assert :ok = :gen_tcp.send(socket, "browser bytes")
    assert {:ok, "node bytes"} = :gen_tcp.recv(socket, 0, 1_000)
    :gen_tcp.close(socket)
    :gen_tcp.close(listener)
  end

  test "maps SOCKS failures to bounded reasons" do
    {listener, proxy_port} =
      listen(fn socket ->
        assert {:ok, <<5, 1, 0>>} = :gen_tcp.recv(socket, 3, 1_000)
        :ok = :gen_tcp.send(socket, <<5, 0>>)
        assert {:ok, <<5, 1, 0, 3, length>>} = :gen_tcp.recv(socket, 5, 1_000)
        assert {:ok, _request} = :gen_tcp.recv(socket, length + 2, 1_000)
        :ok = :gen_tcp.send(socket, <<5, 4, 0, 1, 0, 0, 0, 0, 0, 0>>)
      end)

    assert {:error, :tor_host_unreachable} =
             Dialer.connect({:onion, @onion, 9_735},
               timeout: 1_000,
               proxy: {{127, 0, 0, 1}, proxy_port}
             )

    :gen_tcp.close(listener)
  end

  test "fails closed when no Tor proxy is configured" do
    assert {:error, :onion_unavailable} =
             Dialer.connect({:onion, @onion, 9_735}, timeout: 100, proxy: nil)
  end

  test "rejects malformed SOCKS negotiation and connect responses" do
    cases = [
      {fn socket ->
         assert {:ok, _greeting} = :gen_tcp.recv(socket, 3, 1_000)
         :gen_tcp.send(socket, <<4, 0>>)
       end, :tor_protocol_error},
      {fn socket ->
         assert {:ok, _greeting} = :gen_tcp.recv(socket, 3, 1_000)
         :gen_tcp.send(socket, <<5, 2>>)
       end, :tor_proxy_auth},
      {connect_response(<<5, 0, 1, 1, 127, 0, 0, 1, 0, 1>>), :tor_protocol_error},
      {connect_response(<<5, 0, 0, 9, 0, 0>>), :tor_protocol_error},
      {connect_response(<<5, 9, 0, 1, 127, 0, 0, 1, 0, 1>>), :tor_protocol_error}
    ]

    for {handler, expected_reason} <- cases do
      {listener, proxy_port} = listen(handler)

      assert {:error, ^expected_reason} =
               Dialer.connect({:onion, @onion, 9_735},
                 timeout: 250,
                 proxy: {{127, 0, 0, 1}, proxy_port}
               )

      :gen_tcp.close(listener)
    end
  end

  test "bounds a truncated SOCKS response by the shared dial timeout" do
    {listener, proxy_port} =
      listen(fn socket ->
        assert {:ok, _greeting} = :gen_tcp.recv(socket, 3, 1_000)
        :ok = :gen_tcp.send(socket, <<5, 0>>)
        assert {:ok, <<5, 1, 0, 3, length>>} = :gen_tcp.recv(socket, 5, 1_000)
        assert {:ok, _request} = :gen_tcp.recv(socket, length + 2, 1_000)
        :ok = :gen_tcp.send(socket, <<5, 0>>)
        Process.sleep(250)
      end)

    assert {:error, :timeout} =
             Dialer.connect({:onion, @onion, 9_735},
               timeout: 50,
               proxy: {{127, 0, 0, 1}, proxy_port}
             )

    :gen_tcp.close(listener)
  end

  defp connect_response(response) do
    fn socket ->
      assert {:ok, _greeting} = :gen_tcp.recv(socket, 3, 1_000)
      :ok = :gen_tcp.send(socket, <<5, 0>>)
      assert {:ok, <<5, 1, 0, 3, length>>} = :gen_tcp.recv(socket, 5, 1_000)
      assert {:ok, _request} = :gen_tcp.recv(socket, length + 2, 1_000)
      :gen_tcp.send(socket, response)
    end
  end

  defp listen(handler) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      handler.(socket)
      :gen_tcp.close(socket)
    end)

    {listener, port}
  end
end
