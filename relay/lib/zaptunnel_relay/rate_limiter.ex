defmodule ZaptunnelRelay.RateLimiter do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check(key, scope \\ :admission), do: GenServer.call(__MODULE__, {:check, scope, key})
  def reset, do: GenServer.call(__MODULE__, :reset)

  def source_key({a, b, c, d}), do: {a, b, c, d}
  def source_key({a, b, c, d, _e, _f, _g, _h}), do: {a, b, c, d, 0, 0, 0, 0}
  def source_key(key), do: key

  @impl true
  def init(_opts), do: {:ok, %{buckets: %{}, globals: %{}, checks: 0}}

  @impl true
  def handle_call({:check, scope, key}, _from, state) do
    policy = policy(scope)
    now = System.monotonic_time(:millisecond)
    normalized_key = {scope, source_key(key)}
    stale_after = policy.burst * policy.refill_ms * 2
    buckets = maybe_prune(state.buckets, state.checks, now, stale_after)

    {result, buckets, globals} =
      if not Map.has_key?(buckets, normalized_key) and
           map_size(buckets) >= Application.fetch_env!(:zaptunnel_relay, :rate_limit_max_buckets) do
        {:limited, buckets, state.globals}
      else
        {source_result, source_bucket} =
          take(Map.get(buckets, normalized_key), policy.burst, policy.refill_ms, now)

        buckets = Map.put(buckets, normalized_key, source_bucket)

        if source_result == :empty do
          {:limited, buckets, state.globals}
        else
          take_global(state.globals, scope, policy, now, buckets)
        end
      end

    state = %{
      state
      | buckets: buckets,
        globals: globals,
        checks: state.checks + 1
    }

    if result == :ok do
      {:reply, :ok, state}
    else
      ZaptunnelRelay.Telemetry.emit(
        [:admission, :rate_limited],
        %{count: 1},
        %{scope: scope}
      )

      {:reply, {:error, :rate_limited}, state}
    end
  end

  def handle_call(:reset, _from, _state),
    do: {:reply, :ok, %{buckets: %{}, globals: %{}, checks: 0}}

  defp take_global(globals, _scope, %{global?: false}, _now, buckets),
    do: {:ok, buckets, globals}

  defp take_global(globals, scope, policy, now, buckets) do
    {global_result, global_bucket} =
      take(
        Map.get(globals, scope),
        policy.global_burst,
        policy.global_refill_ms,
        now
      )

    {global_result, buckets, Map.put(globals, scope, global_bucket)}
  end

  defp take(nil, burst, _refill_ms, now) when burst >= 1,
    do: {:ok, %{tokens: burst - 1, updated_at: now}}

  defp take(nil, _burst, _refill_ms, now),
    do: {:empty, %{tokens: 0, updated_at: now}}

  defp take(bucket, burst, refill_ms, now) when burst >= 1 and refill_ms >= 1 do
    elapsed = max(now - bucket.updated_at, 0)
    replenished = min(burst, bucket.tokens + elapsed / refill_ms)

    if replenished >= 1,
      do: {:ok, %{tokens: replenished - 1, updated_at: now}},
      else: {:empty, %{tokens: replenished, updated_at: now}}
  end

  defp take(_bucket, _burst, _refill_ms, now),
    do: {:empty, %{tokens: 0, updated_at: now}}

  defp maybe_prune(buckets, checks, now, stale_after)
       when checks > 0 and rem(checks, 1_000) == 0 do
    Map.filter(buckets, fn {_key, bucket} -> now - bucket.updated_at < stale_after end)
  end

  defp maybe_prune(buckets, _checks, _now, _stale_after), do: buckets

  defp policy(:payment_claim) do
    %{
      global?: true,
      burst: Application.fetch_env!(:zaptunnel_relay, :payment_claim_rate_limit_burst),
      refill_ms: Application.fetch_env!(:zaptunnel_relay, :payment_claim_rate_limit_refill_ms),
      global_burst:
        Application.fetch_env!(:zaptunnel_relay, :payment_claim_global_rate_limit_burst),
      global_refill_ms:
        Application.fetch_env!(:zaptunnel_relay, :payment_claim_global_rate_limit_refill_ms)
    }
  end

  defp policy(_scope) do
    %{
      global?: Application.fetch_env!(:zaptunnel_relay, :admission_global_rate_limit_enabled),
      burst: Application.fetch_env!(:zaptunnel_relay, :rate_limit_burst),
      refill_ms: Application.fetch_env!(:zaptunnel_relay, :rate_limit_refill_ms),
      global_burst: Application.fetch_env!(:zaptunnel_relay, :global_rate_limit_burst),
      global_refill_ms: Application.fetch_env!(:zaptunnel_relay, :global_rate_limit_refill_ms)
    }
  end
end
