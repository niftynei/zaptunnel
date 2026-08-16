defmodule ZaptunnelRelay.EndpointVerifier do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def verify(node_id, address) do
    timeout = Application.fetch_env!(:zaptunnel_relay, :verification_timeout_ms)
    GenServer.call(__MODULE__, {:verify, node_id, address}, timeout + 1_000)
  end

  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts), do: {:ok, %{cache: %{}, pending: %{}}}

  @impl true
  def handle_call({:verify, node_id, address}, from, state) do
    key = {node_id, address}
    now = System.monotonic_time(:millisecond)

    case Map.get(state.cache, key) do
      %{result: result, expires_at: expires_at} when expires_at > now ->
        ZaptunnelRelay.Telemetry.emit([:verification, :cache_hit], %{count: 1}, %{result: result})
        {:reply, result, state}

      _expired_or_missing ->
        case Map.get(state.pending, key) do
          nil ->
            if map_size(state.pending) >= max_pending() do
              {:reply, {:error, :relay_overloaded}, state}
            else
              task =
                Task.Supervisor.async_nolink(ZaptunnelRelay.ProbeSupervisor, fn ->
                  probe_module().verify(node_id, address)
                end)

              pending =
                Map.put(state.pending, key, %{
                  task_ref: task.ref,
                  waiters: [from],
                  started_at: now
                })

              {:noreply, %{state | pending: pending, cache: Map.delete(state.cache, key)}}
            end

          entry ->
            pending = Map.put(state.pending, key, %{entry | waiters: [from | entry.waiters]})
            {:noreply, %{state | pending: pending}}
        end
    end
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | cache: %{}}}
  end

  @impl true
  def handle_info({reference, result}, state) when is_reference(reference) do
    Process.demonitor(reference, [:flush])

    case find_pending(state.pending, reference) do
      nil ->
        {:noreply, state}

      {key, entry} ->
        result = normalize(result)
        Enum.each(entry.waiters, &GenServer.reply(&1, result))
        ttl = cache_ttl(result)
        duration = System.monotonic_time(:millisecond) - entry.started_at

        ZaptunnelRelay.Telemetry.emit(
          [:verification, :stop],
          %{duration_ms: duration},
          %{result: result}
        )

        cache =
          Map.put(state.cache, key, %{
            result: result,
            expires_at: System.monotonic_time(:millisecond) + ttl
          })

        {:noreply, %{state | pending: Map.delete(state.pending, key), cache: cache}}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    case find_pending(state.pending, reference) do
      nil ->
        {:noreply, state}

      {key, entry} ->
        result = {:error, :endpoint_unverified}
        Enum.each(entry.waiters, &GenServer.reply(&1, result))

        ZaptunnelRelay.Telemetry.emit(
          [:verification, :stop],
          %{
            duration_ms: System.monotonic_time(:millisecond) - entry.started_at
          },
          %{result: result}
        )

        {:noreply, %{state | pending: Map.delete(state.pending, key)}}
    end
  end

  defp find_pending(pending, reference) do
    Enum.find(pending, fn {_key, entry} -> entry.task_ref == reference end)
  end

  defp normalize(:ok), do: :ok
  defp normalize(_result), do: {:error, :endpoint_unverified}

  defp cache_ttl(:ok),
    do: Application.fetch_env!(:zaptunnel_relay, :verification_success_ttl_ms)

  defp cache_ttl({:error, _reason}),
    do: Application.fetch_env!(:zaptunnel_relay, :verification_failure_ttl_ms)

  defp probe_module do
    Application.fetch_env!(:zaptunnel_relay, :endpoint_probe_module)
  end

  defp max_pending do
    Application.fetch_env!(:zaptunnel_relay, :max_pending_verifications)
  end
end
