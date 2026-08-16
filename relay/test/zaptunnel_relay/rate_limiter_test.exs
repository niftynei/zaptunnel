defmodule ZaptunnelRelay.RateLimiterTest do
  use ExUnit.Case, async: false

  alias ZaptunnelRelay.RateLimiter

  setup do
    burst = Application.fetch_env!(:zaptunnel_relay, :rate_limit_burst)
    refill = Application.fetch_env!(:zaptunnel_relay, :rate_limit_refill_ms)
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:zaptunnel_relay, :rate_limit_burst, burst)
      Application.put_env(:zaptunnel_relay, :rate_limit_refill_ms, refill)
      RateLimiter.reset()
    end)

    :ok
  end

  test "limits each source independently and refills its bucket" do
    Application.put_env(:zaptunnel_relay, :rate_limit_burst, 2)
    Application.put_env(:zaptunnel_relay, :rate_limit_refill_ms, 20)

    assert :ok = RateLimiter.check({192, 0, 2, 1})
    assert :ok = RateLimiter.check({192, 0, 2, 1})
    assert {:error, :rate_limited} = RateLimiter.check({192, 0, 2, 1})
    assert :ok = RateLimiter.check({192, 0, 2, 2})

    Process.sleep(25)
    assert :ok = RateLimiter.check({192, 0, 2, 1})
  end
end
