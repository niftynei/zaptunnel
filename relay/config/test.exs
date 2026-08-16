import Config

config :zaptunnel_relay,
  enabled: false,
  allow_private_addresses: true,
  ticket_ttl_ms: 100,
  verification_timeout_ms: 500,
  verification_success_ttl_ms: 100,
  verification_failure_ttl_ms: 50,
  rate_limit_burst: 1_000,
  rate_limit_refill_ms: 1

config :logger, level: :warning
