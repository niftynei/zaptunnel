defmodule ZaptunnelRelay.EndpointVerifierTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ZaptunnelRelay.EndpointVerifier

  defmodule Probe do
    def verify(node_id, address) do
      send(Application.fetch_env!(:zaptunnel_relay, :probe_test_pid), {:probe, node_id, address})
      Process.sleep(Application.get_env(:zaptunnel_relay, :probe_test_delay_ms, 0))
      Application.get_env(:zaptunnel_relay, :probe_test_result, :ok)
    end
  end

  @node_id "02" <> String.duplicate("11", 32)
  @address {{127, 0, 0, 1}, 9_735}

  setup do
    previous = Application.fetch_env!(:zaptunnel_relay, :endpoint_probe_module)
    Application.put_env(:zaptunnel_relay, :endpoint_probe_module, Probe)
    Application.put_env(:zaptunnel_relay, :probe_test_pid, self())
    Application.put_env(:zaptunnel_relay, :probe_test_result, :ok)
    EndpointVerifier.reset()

    on_exit(fn ->
      Application.put_env(:zaptunnel_relay, :endpoint_probe_module, previous)
      Application.delete_env(:zaptunnel_relay, :probe_test_pid)
      Application.delete_env(:zaptunnel_relay, :probe_test_result)
      Application.delete_env(:zaptunnel_relay, :probe_test_delay_ms)
    end)

    :ok
  end

  test "caches a successful endpoint verification" do
    assert :ok = EndpointVerifier.verify(@node_id, @address)
    assert_receive {:probe, @node_id, @address}

    assert :ok = EndpointVerifier.verify(@node_id, @address)
    refute_receive {:probe, _, _}
  end

  test "coalesces simultaneous checks for the same endpoint" do
    Application.put_env(:zaptunnel_relay, :probe_test_delay_ms, 30)

    tasks =
      for _index <- 1..3 do
        Task.async(fn -> EndpointVerifier.verify(@node_id, @address) end)
      end

    assert Enum.map(tasks, &Task.await/1) == [:ok, :ok, :ok]
    assert_receive {:probe, @node_id, @address}
    refute_receive {:probe, _, _}
  end

  test "normalizes and briefly caches probe failures" do
    Application.put_env(
      :zaptunnel_relay,
      :probe_test_result,
      {:error, {:tcp_connect, :econnrefused}}
    )

    log =
      capture_log(fn ->
        assert {:error, :endpoint_unverified} =
                 EndpointVerifier.verify(@node_id, @address, request_id: "zt_abcdefghijklmnop")
      end)

    assert log =~ "endpoint verification failed"
    assert log =~ "request_id=zt_abcdefghijklmnop"
    assert log =~ "stage=tcp_connect"
    assert log =~ "reason=econnrefused"
    assert log =~ "cached=false"
    assert log =~ "node_id=02111111…11111111"
    assert log =~ "target=127.0.0.1:9735"
    assert_receive {:probe, @node_id, @address}

    cached_log =
      capture_log(fn ->
        assert {:error, :endpoint_unverified} =
                 EndpointVerifier.verify(@node_id, @address, request_id: "zt_qrstuvwxyzABCDEF")
      end)

    assert cached_log =~ "request_id=zt_qrstuvwxyzABCDEF"
    assert cached_log =~ "stage=tcp_connect"
    assert cached_log =~ "cached=true"
    refute_receive {:probe, _, _}
  end
end
