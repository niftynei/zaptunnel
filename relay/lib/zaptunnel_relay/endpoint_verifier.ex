defmodule ZaptunnelRelay.EndpointVerifier do
  @moduledoc false

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def verify(node_id, address, opts \\ []) do
    timeout = Application.fetch_env!(:zaptunnel_relay, :verification_timeout_ms)
    started_at = System.monotonic_time(:millisecond)
    request_id = Keyword.get(opts, :request_id)
    source = Keyword.get(opts, :source, :internal) |> ZaptunnelRelay.RateLimiter.source_key()

    result =
      GenServer.call(
        __MODULE__,
        {:verify, node_id, address, request_id, source},
        timeout + 1_000
      )

    obscure_probe_timing(result, started_at, timeout)
  end

  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{cache: %{}, cache_order: :queue.new(), pending: %{}}}
  end

  @impl true
  def handle_call({:verify, node_id, address, request_id, source}, from, state) do
    key = {node_id, address}
    now = System.monotonic_time(:millisecond)

    case Map.get(state.cache, key) do
      %{result: result, expires_at: expires_at} when expires_at > now ->
        ZaptunnelRelay.Telemetry.emit([:verification, :cache_hit], %{count: 1}, %{result: result})
        {:reply, result, state}

      _expired_or_missing ->
        case Map.get(state.pending, key) do
          nil ->
            if map_size(state.pending) >= max_pending() or
                 pending_for_source(state.pending, source) >= max_pending_per_source() do
              {:reply, {:error, :relay_overloaded}, state}
            else
              task =
                Task.Supervisor.async_nolink(ZaptunnelRelay.ProbeSupervisor, fn ->
                  probe_module().verify(node_id, address)
                end)

              timer =
                Process.send_after(self(), {:verification_timeout, key, task.ref}, timeout())

              pending =
                Map.put(state.pending, key, %{
                  task_pid: task.pid,
                  task_ref: task.ref,
                  timer: timer,
                  source: source,
                  waiters: [%{from: from, request_id: request_id}],
                  started_at: now
                })

              {:noreply, %{state | pending: pending, cache: Map.delete(state.cache, key)}}
            end

          entry ->
            if length(entry.waiters) >= max_waiters() do
              {:reply, {:error, :relay_overloaded}, state}
            else
              waiter = %{from: from, request_id: request_id}
              pending = Map.put(state.pending, key, %{entry | waiters: [waiter | entry.waiters]})
              {:noreply, %{state | pending: pending}}
            end
        end
    end
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.pending, fn {_key, entry} ->
      Process.cancel_timer(entry.timer)
      Task.Supervisor.terminate_child(ZaptunnelRelay.ProbeSupervisor, entry.task_pid)
      Enum.each(entry.waiters, &GenServer.reply(&1.from, {:error, :relay_overloaded}))
    end)

    {:reply, :ok, %{cache: %{}, cache_order: :queue.new(), pending: %{}}}
  end

  @impl true
  def handle_info({reference, result}, state) when is_reference(reference) do
    Process.demonitor(reference, [:flush])

    case find_pending(state.pending, reference) do
      nil ->
        {:noreply, state}

      {key, entry} ->
        Process.cancel_timer(entry.timer)
        {:noreply, complete(state, key, entry, result, true)}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    case find_pending(state.pending, reference) do
      nil ->
        {:noreply, state}

      {key, entry} ->
        Process.cancel_timer(entry.timer)

        {:noreply, complete(state, key, entry, {:error, {:internal, :task_exit}}, false)}
    end
  end

  def handle_info({:verification_timeout, key, reference}, state) do
    case Map.get(state.pending, key) do
      %{task_ref: ^reference} = entry ->
        Process.demonitor(reference, [:flush])
        Task.Supervisor.terminate_child(ZaptunnelRelay.ProbeSupervisor, entry.task_pid)

        {:noreply, complete(state, key, entry, {:error, {:probe, :timeout}}, false)}

      _missing_or_replaced ->
        {:noreply, state}
    end
  end

  def handle_info(:sweep_cache, state) do
    now = System.monotonic_time(:millisecond)
    cache = Map.filter(state.cache, fn {_key, entry} -> entry.expires_at > now end)

    cache_order =
      cache
      |> Enum.map(fn {key, entry} -> {key, entry.expires_at} end)
      |> :queue.from_list()

    schedule_sweep()
    {:noreply, %{state | cache: cache, cache_order: cache_order}}
  end

  defp complete(state, key, entry, probe_result, cache?) do
    duration = System.monotonic_time(:millisecond) - entry.started_at
    {result, failure} = normalize(probe_result)

    maybe_log_failure(key, failure, duration, entry.waiters)

    ZaptunnelRelay.Telemetry.emit(
      [:verification, :stop],
      %{duration_ms: duration},
      telemetry_metadata(result, failure)
    )

    Enum.each(entry.waiters, &GenServer.reply(&1.from, result))

    state =
      if cache? do
        expires_at = System.monotonic_time(:millisecond) + cache_ttl(result)

        put_cache(state, key, %{
          result: result,
          failure: failure,
          expires_at: expires_at
        })
      else
        state
      end

    %{state | pending: Map.delete(state.pending, key)}
  end

  defp put_cache(state, key, entry) do
    state = %{
      state
      | cache: Map.put(state.cache, key, entry),
        cache_order: :queue.in({key, entry.expires_at}, state.cache_order)
    }

    enforce_cache_cap(state)
  end

  defp enforce_cache_cap(state) do
    if map_size(state.cache) <= cache_max_size() do
      state
    else
      {{:value, {key, expires_at}}, cache_order} = :queue.out(state.cache_order)

      cache =
        case Map.get(state.cache, key) do
          %{expires_at: ^expires_at} -> Map.delete(state.cache, key)
          _newer_or_missing -> state.cache
        end

      enforce_cache_cap(%{state | cache: cache, cache_order: cache_order})
    end
  end

  defp find_pending(pending, reference) do
    Enum.find(pending, fn {_key, entry} -> entry.task_ref == reference end)
  end

  defp normalize(:ok), do: {:ok, nil}

  defp normalize({:error, {stage, reason}}) when is_atom(stage) and is_atom(reason),
    do: {{:error, :endpoint_unverified}, {stage, reason}}

  defp normalize({:error, reason}) when is_atom(reason),
    do: {{:error, :endpoint_unverified}, {:probe, reason}}

  defp normalize(_result),
    do: {{:error, :endpoint_unverified}, {:probe, :error}}

  defp telemetry_metadata(result, nil), do: %{result: result}

  defp telemetry_metadata(result, {stage, reason}),
    do: %{result: result, failure_stage: stage, failure_reason: reason}

  defp maybe_log_failure(_key, nil, _duration, _waiters), do: :ok

  defp maybe_log_failure(
         {node_id, target},
         {stage, reason},
         duration,
         waiters
       ) do
    request_id = waiters |> List.first() |> then(&if(&1, do: &1.request_id, else: nil))

    Logger.warning(
      "endpoint verification failed request_id=#{format_request_id(request_id)} " <>
        "stage=#{stage} reason=#{reason} " <>
        "node_id=#{abbreviate(node_id)} target=#{format_address(target)} " <>
        "duration_ms=#{duration} waiter_count=#{length(waiters)}"
    )
  end

  defp format_request_id("zt_" <> rest = request_id) when byte_size(rest) == 16, do: request_id
  defp format_request_id(_request_id), do: "internal"

  defp abbreviate(
         <<prefix::binary-size(8), _middle::binary-size(50), suffix::binary-size(8)>> = node_id
       ) do
    if String.match?(node_id, ~r/\A(?:02|03)[0-9a-fA-F]{64}\z/),
      do: prefix <> "…" <> suffix,
      else: "invalid"
  end

  defp abbreviate(_node_id), do: "invalid"

  defp format_address({ip, port}) when tuple_size(ip) == 4,
    do: "#{:inet.ntoa(ip)}:#{port}"

  defp format_address({ip, port}) when tuple_size(ip) == 8,
    do: "[#{:inet.ntoa(ip)}]:#{port}"

  defp format_address({:onion, host, port}), do: "#{host}:#{port}"

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

  defp max_pending_per_source do
    Application.fetch_env!(:zaptunnel_relay, :max_pending_verifications_per_source)
  end

  defp max_waiters do
    Application.fetch_env!(:zaptunnel_relay, :max_verification_waiters_per_endpoint)
  end

  defp timeout do
    Application.fetch_env!(:zaptunnel_relay, :verification_timeout_ms)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_cache, cache_sweep_interval())
  end

  defp cache_sweep_interval do
    Application.fetch_env!(:zaptunnel_relay, :verification_cache_sweep_ms)
  end

  defp cache_max_size do
    Application.fetch_env!(:zaptunnel_relay, :verification_cache_max_size)
  end

  defp pending_for_source(pending, source) do
    Enum.count(pending, fn {_key, entry} -> entry.source == source end)
  end

  defp obscure_probe_timing({:error, :endpoint_unverified} = result, started_at, timeout) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    Process.sleep(max(timeout - elapsed, 0))
    result
  end

  defp obscure_probe_timing(result, _started_at, _timeout), do: result
end
