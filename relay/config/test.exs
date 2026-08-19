import Config

config :zaptunnel_relay,
  enabled: false,
  allow_private_addresses: true,
  ticket_ttl_ms: 100,
  verification_timeout_ms: 500,
  verification_success_ttl_ms: 100,
  # Keep failures cached beyond the 500 ms timing-obfuscation window so a
  # caller cannot force a second probe immediately after the first returns.
  verification_failure_ttl_ms: 1_000,
  verification_cache_sweep_ms: 20,
  verification_cache_max_size: 100,
  rate_limit_burst: 1_000,
  rate_limit_refill_ms: 1,
  global_rate_limit_burst: 10_000,
  global_rate_limit_refill_ms: 1,
  payment_claim_rate_limit_burst: 1_000,
  payment_claim_rate_limit_refill_ms: 1,
  payment_claim_global_rate_limit_burst: 10_000,
  payment_claim_global_rate_limit_refill_ms: 1

config :logger, level: :warning
