defmodule ZaptunnelRelay.EndpointVerifier do
  @moduledoc false

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def verify(node_id, address, opts \\ []) do
    timeout = Application.fetch_env!(:zaptunnel_relay, :verification_timeout_ms)
    request_id = Keyword.get(opts, :request_id)
    GenServer.call(__MODULE__, {:verify, node_id, address, request_id}, timeout + 1_000)
  end

  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts), do: {:ok, %{cache: %{}, pending: %{}}}

  @impl true
  def handle_call({:verify, node_id, address, request_id}, from, state) do
    key = {node_id, address}
    now = System.monotonic_time(:millisecond)

    case Map.get(state.cache, key) do
      %{result: result, failure: failure, expires_at: expires_at} when expires_at > now ->
        ZaptunnelRelay.Telemetry.emit([:verification, :cache_hit], %{count: 1}, %{result: result})
        maybe_log_failure(key, failure, 0, request_id, true)
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
                  waiters: [%{from: from, request_id: request_id}],
                  started_at: now
                })

              {:noreply, %{state | pending: pending, cache: Map.delete(state.cache, key)}}
            end

          entry ->
            waiter = %{from: from, request_id: request_id}
            pending = Map.put(state.pending, key, %{entry | waiters: [waiter | entry.waiters]})
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
        duration = System.monotonic_time(:millisecond) - entry.started_at
        {result, failure} = normalize(result)

        Enum.each(entry.waiters, fn waiter ->
          maybe_log_failure(key, failure, duration, waiter.request_id, false)
          GenServer.reply(waiter.from, result)
        end)

        ttl = cache_ttl(result)

        ZaptunnelRelay.Telemetry.emit(
          [:verification, :stop],
          %{duration_ms: duration},
          telemetry_metadata(result, failure)
        )

        cache =
          Map.put(state.cache, key, %{
            result: result,
            failure: failure,
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
        duration = System.monotonic_time(:millisecond) - entry.started_at
        failure = {:internal, :task_exit}

        Enum.each(entry.waiters, fn waiter ->
          maybe_log_failure(key, failure, duration, waiter.request_id, false)
          GenServer.reply(waiter.from, result)
        end)

        ZaptunnelRelay.Telemetry.emit(
          [:verification, :stop],
          %{
            duration_ms: duration
          },
          telemetry_metadata(result, failure)
        )

        {:noreply, %{state | pending: Map.delete(state.pending, key)}}
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

  defp maybe_log_failure(_key, nil, _duration, _request_id, _cached?), do: :ok

  defp maybe_log_failure(
         {node_id, target},
         {stage, reason},
         duration,
         request_id,
         cached?
       ) do
    Logger.warning(
      "endpoint verification failed request_id=#{format_request_id(request_id)} " <>
        "stage=#{stage} reason=#{reason} cached=#{cached?} " <>
        "node_id=#{abbreviate(node_id)} target=#{format_address(target)} duration_ms=#{duration}"
    )
  end

  defp format_request_id("zt_" <> rest = request_id) when byte_size(rest) == 16, do: request_id
  defp format_request_id(_request_id), do: "internal"

  defp abbreviate(<<prefix::binary-size(8), _middle::binary-size(50), suffix::binary-size(8)>>),
    do: prefix <> "…" <> suffix

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
end
