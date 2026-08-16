defmodule ZaptunnelRelay.RateLimiter do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check(key), do: GenServer.call(__MODULE__, {:check, key})
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts), do: {:ok, %{buckets: %{}, checks: 0}}

  @impl true
  def handle_call({:check, key}, _from, state) do
    burst = Application.fetch_env!(:zaptunnel_relay, :rate_limit_burst)
    refill_ms = Application.fetch_env!(:zaptunnel_relay, :rate_limit_refill_ms)
    now = System.monotonic_time(:millisecond)
    buckets = maybe_prune(state.buckets, state.checks, now, burst * refill_ms * 2)
    bucket = Map.get(buckets, key, %{tokens: burst, updated_at: now})
    elapsed = max(now - bucket.updated_at, 0)
    replenished = min(burst, bucket.tokens + elapsed / refill_ms)

    if replenished >= 1 do
      bucket = %{tokens: replenished - 1, updated_at: now}
      {:reply, :ok, %{state | buckets: Map.put(buckets, key, bucket), checks: state.checks + 1}}
    else
      bucket = %{tokens: replenished, updated_at: now}
      ZaptunnelRelay.Telemetry.emit([:admission, :rate_limited], %{count: 1})

      {:reply, {:error, :rate_limited},
       %{state | buckets: Map.put(buckets, key, bucket), checks: state.checks + 1}}
    end
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{buckets: %{}, checks: 0}}

  defp maybe_prune(buckets, checks, now, stale_after)
       when checks > 0 and rem(checks, 1_000) == 0 do
    Map.filter(buckets, fn {_key, bucket} -> now - bucket.updated_at < stale_after end)
  end

  defp maybe_prune(buckets, _checks, _now, _stale_after), do: buckets
end
