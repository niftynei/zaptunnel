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
    previous =
      for key <- [
            :endpoint_probe_module,
            :verification_timeout_ms,
            :max_pending_verifications_per_source,
            :max_verification_waiters_per_endpoint,
            :verification_cache_max_size
          ],
          into: %{} do
        {key, Application.fetch_env!(:zaptunnel_relay, key)}
      end

    Application.put_env(:zaptunnel_relay, :endpoint_probe_module, Probe)
    Application.put_env(:zaptunnel_relay, :probe_test_pid, self())
    Application.put_env(:zaptunnel_relay, :probe_test_result, :ok)
    EndpointVerifier.reset()

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:zaptunnel_relay, key, value) end)

      Application.delete_env(:zaptunnel_relay, :probe_test_pid)
      Application.delete_env(:zaptunnel_relay, :probe_test_result)
      Application.delete_env(:zaptunnel_relay, :probe_test_delay_ms)
    end)

    :ok
  end

  test "kills a probe at its independent verification deadline" do
    Application.put_env(:zaptunnel_relay, :verification_timeout_ms, 20)
    Application.put_env(:zaptunnel_relay, :probe_test_delay_ms, 200)

    assert {:error, :endpoint_unverified} =
             EndpointVerifier.verify(@node_id, @address, source: {192, 0, 2, 1})

    Application.put_env(:zaptunnel_relay, :probe_test_delay_ms, 0)
    assert :ok = EndpointVerifier.verify(@node_id, @address, source: {192, 0, 2, 1})
  end

  test "caps unique in-flight probes from one source" do
    Application.put_env(:zaptunnel_relay, :max_pending_verifications_per_source, 1)
    Application.put_env(:zaptunnel_relay, :probe_test_delay_ms, 100)
    source = {0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}

    first = Task.async(fn -> EndpointVerifier.verify(@node_id, @address, source: source) end)
    assert_receive {:probe, @node_id, @address}

    assert {:error, :relay_overloaded} =
             EndpointVerifier.verify(@node_id, {{127, 0, 0, 2}, 9_735},
               source: {0x2001, 0xDB8, 1, 2, 9, 9, 9, 9}
             )

    assert :ok = Task.await(first)
    assert %{pending_by_source: %{}} = :sys.get_state(EndpointVerifier)

    assert :ok =
             EndpointVerifier.verify(@node_id, {{127, 0, 0, 3}, 9_735}, source: source)
  end

  test "caps waiters coalesced onto one endpoint" do
    Application.put_env(:zaptunnel_relay, :max_verification_waiters_per_endpoint, 1)
    Application.put_env(:zaptunnel_relay, :probe_test_delay_ms, 100)

    first = Task.async(fn -> EndpointVerifier.verify(@node_id, @address) end)
    assert_receive {:probe, @node_id, @address}
    assert {:error, :relay_overloaded} = EndpointVerifier.verify(@node_id, @address)
    assert :ok = Task.await(first)
  end

  test "caps cached endpoints and sweeps expired entries" do
    Application.put_env(:zaptunnel_relay, :verification_cache_max_size, 2)

    for last_octet <- 1..3 do
      assert :ok =
               EndpointVerifier.verify(@node_id, {{127, 0, 0, last_octet}, 9_735},
                 source: {192, 0, 2, 1}
               )
    end

    assert %{cache: cache} = :sys.get_state(EndpointVerifier)
    assert map_size(cache) == 2

    Process.sleep(150)
    assert %{cache: cache} = :sys.get_state(EndpointVerifier)
    assert cache == %{}
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
    assert log =~ "node_id=02111111…11111111"
    assert log =~ "target=127.0.0.1:9735"
    assert_receive {:probe, @node_id, @address}

    cached_log =
      capture_log(fn ->
        assert {:error, :endpoint_unverified} =
                 EndpointVerifier.verify(@node_id, @address, request_id: "zt_qrstuvwxyzABCDEF")
      end)

    assert cached_log == ""
    refute_receive {:probe, _, _}
  end

  test "failed probes do not reveal whether the TCP endpoint failed quickly" do
    Application.put_env(:zaptunnel_relay, :verification_timeout_ms, 30)

    Application.put_env(
      :zaptunnel_relay,
      :probe_test_result,
      {:error, {:tcp_connect, :econnrefused}}
    )

    started_at = System.monotonic_time(:millisecond)

    capture_log(fn ->
      assert {:error, :endpoint_unverified} = EndpointVerifier.verify(@node_id, @address)
    end)

    assert System.monotonic_time(:millisecond) - started_at >= 25
  end
end
