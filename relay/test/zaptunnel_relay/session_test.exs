defmodule ZaptunnelRelay.SessionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ZaptunnelRelay.Session

  @node_id "02" <> String.duplicate("11", 32)

  test "forwards opaque binary data in both directions" do
    test_pid = self()

    listener =
      listen(fn socket ->
        {:ok, "browser bytes"} = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.send(socket, "node bytes")
        send(test_pid, :echo_complete)
      end)

    {:ok, port} = :inet.port(listener)
    assert {:ok, state} = Session.init(%{address: {{127, 0, 0, 1}, port}, node_id: @node_id})
    assert {:ok, state} = Session.handle_in({"browser bytes", [opcode: :binary]}, state)
    assert_receive {:tcp, socket, "node bytes"}, 1_000

    assert {:push, {:binary, "node bytes"}, state} =
             Session.handle_info({:tcp, socket, "node bytes"}, state)

    assert_receive :echo_complete
    assert :ok = Session.terminate(:normal, state)
  end

  test "rejects an oversized browser frame" do
    listener = listen(fn socket -> :gen_tcp.recv(socket, 0, 100) end)
    {:ok, port} = :inet.port(listener)
    assert {:ok, state} = Session.init(%{address: {{127, 0, 0, 1}, port}, node_id: @node_id})

    maximum = Application.fetch_env!(:zaptunnel_relay, :max_websocket_frame_bytes)

    assert {:stop, :frame_too_large, state} =
             Session.handle_in({:binary.copy(<<0>>, maximum + 1), [opcode: :binary]}, state)

    assert :ok = Session.terminate(:normal, state)
  end

  test "logs a correlated and bounded session dial failure" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)

    log =
      capture_log(fn ->
        assert {:stop, :normal} =
                 Session.init(%{
                   address: {{127, 0, 0, 1}, port},
                   node_id: @node_id,
                   request_id: "zt_1234567890abcdef"
                 })
      end)

    assert log =~ "session connect failed request_id=zt_1234567890abcdef"
    assert log =~ "stage=session_dial reason=econnrefused"
    assert log =~ "node_id=02111111…11111111"
  end

  defp listen(handler) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      handler.(socket)
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    listener
  end
end
