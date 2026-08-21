defmodule ZaptunnelRelay.RateLimiterTest do
  use ExUnit.Case, async: false

  alias ZaptunnelRelay.RateLimiter

  setup do
    previous =
      for key <- [
            :rate_limit_burst,
            :rate_limit_refill_ms,
            :global_rate_limit_burst,
            :global_rate_limit_refill_ms,
            :admission_global_rate_limit_enabled,
            :rate_limit_max_buckets
          ],
          into: %{} do
        {key, Application.fetch_env!(:zaptunnel_relay, key)}
      end

    RateLimiter.reset()

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:zaptunnel_relay, key, value) end)

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

  test "groups IPv6 sources by /64" do
    Application.put_env(:zaptunnel_relay, :rate_limit_burst, 1)
    Application.put_env(:zaptunnel_relay, :rate_limit_refill_ms, 60_000)

    assert :ok = RateLimiter.check({0x2001, 0xDB8, 1, 2, 1, 2, 3, 4})

    assert {:error, :rate_limited} =
             RateLimiter.check({0x2001, 0xDB8, 1, 2, 9, 8, 7, 6})

    assert :ok = RateLimiter.check({0x2001, 0xDB8, 1, 3, 1, 2, 3, 4})
  end

  test "enforces a relay-wide ceiling across source addresses" do
    Application.put_env(:zaptunnel_relay, :admission_global_rate_limit_enabled, true)
    Application.put_env(:zaptunnel_relay, :global_rate_limit_burst, 2)
    Application.put_env(:zaptunnel_relay, :global_rate_limit_refill_ms, 60_000)

    assert :ok = RateLimiter.check({192, 0, 2, 1})
    assert :ok = RateLimiter.check({192, 0, 2, 2})
    assert {:error, :rate_limited} = RateLimiter.check({192, 0, 2, 3})
  end

  test "does not let distributed sources drain a global admission bucket by default" do
    Application.put_env(:zaptunnel_relay, :admission_global_rate_limit_enabled, false)
    Application.put_env(:zaptunnel_relay, :global_rate_limit_burst, 1)
    Application.put_env(:zaptunnel_relay, :global_rate_limit_refill_ms, 60_000)

    for last <- 1..100 do
      assert :ok = RateLimiter.check({192, 0, 2, last})
    end
  end

  test "bounds the number of remembered source buckets" do
    Application.put_env(:zaptunnel_relay, :rate_limit_max_buckets, 1)

    assert :ok = RateLimiter.check({192, 0, 2, 1})
    assert {:error, :rate_limited} = RateLimiter.check({192, 0, 2, 2})
  end
end
