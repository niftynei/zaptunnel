import Config

unless config_env() == :test do
  {:ok, ip} =
    System.get_env("ZAPTUNNEL_LISTEN_ADDRESS", "127.0.0.1")
    |> String.to_charlist()
    |> :inet.parse_address()

  tls =
    case {System.get_env("ZAPTUNNEL_TLS_CERTFILE"), System.get_env("ZAPTUNNEL_TLS_KEYFILE")} do
      {nil, nil} ->
        false

      {certfile, keyfile} when is_binary(certfile) and is_binary(keyfile) ->
        %{certfile: certfile, keyfile: keyfile}

      _partial ->
        raise "ZAPTUNNEL_TLS_CERTFILE and ZAPTUNNEL_TLS_KEYFILE must be set together"
    end

  tor_socks_proxy =
    case {System.get_env("ZAPTUNNEL_TOR_SOCKS_ADDRESS"),
          System.get_env("ZAPTUNNEL_TOR_SOCKS_PORT")} do
      {nil, nil} ->
        nil

      {address, port} when is_binary(address) and is_binary(port) ->
        with {:ok, socks_ip} <- :inet.parse_address(String.to_charlist(address)),
             {socks_port, ""} when socks_port in 1..65_535 <- Integer.parse(port) do
          {socks_ip, socks_port}
        else
          {:error, _reason} -> raise "ZAPTUNNEL_TOR_SOCKS_ADDRESS must be an IP address"
          _invalid_port -> raise "ZAPTUNNEL_TOR_SOCKS_PORT must be an integer from 1 to 65535"
        end

      _partial ->
        raise "ZAPTUNNEL_TOR_SOCKS_ADDRESS and ZAPTUNNEL_TOR_SOCKS_PORT must be set together"
    end

  payments_enabled = System.get_env("ZAPTUNNEL_PAYMENTS_ENABLED", "false") in ["1", "true"]
  payment_token_secret = System.get_env("ZAPTUNNEL_PAYMENT_TOKEN_SECRET")
  billing_node_id = System.get_env("ZAPTUNNEL_BILLING_NODE_ID")
  billing_node_address = System.get_env("ZAPTUNNEL_BILLING_NODE_ADDRESS")
  billing_node_rune = System.get_env("ZAPTUNNEL_BILLING_NODE_RUNE")

  if payments_enabled and
       Enum.any?(
         [payment_token_secret, billing_node_id, billing_node_address, billing_node_rune],
         &is_nil/1
       ) do
    raise "payment configuration requires ZAPTUNNEL_PAYMENT_TOKEN_SECRET, ZAPTUNNEL_BILLING_NODE_ID, ZAPTUNNEL_BILLING_NODE_ADDRESS, and ZAPTUNNEL_BILLING_NODE_RUNE"
  end

  config :zaptunnel_relay,
    ip: ip,
    port: String.to_integer(System.get_env("ZAPTUNNEL_WEB_PORT", "4000")),
    allow_private_addresses:
      System.get_env("ZAPTUNNEL_ALLOW_PRIVATE_ADDRESSES", "false") in ["1", "true"],
    tor_socks_proxy: tor_socks_proxy,
    ticket_ttl_ms: String.to_integer(System.get_env("ZAPTUNNEL_TICKET_TTL_MS", "10000")),
    free_sessions_per_node:
      String.to_integer(System.get_env("ZAPTUNNEL_FREE_SESSIONS_PER_NODE", "3")),
    payments_enabled: payments_enabled,
    payment_price_sats: String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_PRICE_SATS", "10")),
    payment_network: System.get_env("ZAPTUNNEL_PAYMENT_NETWORK", "mainnet"),
    payment_quote_ttl_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_QUOTE_TTL_MS", "300000")),
    payment_lease_ttl_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_LEASE_TTL_MS", "28800000")),
    payment_invoice_timeout_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_INVOICE_TIMEOUT_MS", "10000")),
    payment_claim_grace_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_CLAIM_GRACE_MS", "60000")),
    payment_quote_retention_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_QUOTE_RETENTION_MS", "86400000")),
    payment_max_pending_quotes_per_source:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_MAX_PENDING_QUOTES_PER_SOURCE", "5")),
    payment_claim_poll_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_CLAIM_POLL_MS", "2000")),
    payment_watch_timeout_seconds:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_WATCH_TIMEOUT_SECONDS", "30")),
    payment_watch_retry_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_WATCH_RETRY_MS", "1000")),
    payment_watch_max_retry_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_WATCH_MAX_RETRY_MS", "30000")),
    payment_token_secret: payment_token_secret || "development-only-zaptunnel-payment-secret",
    payment_state_path: System.get_env("ZAPTUNNEL_PAYMENT_STATE_PATH"),
    billing_node_id: billing_node_id,
    billing_node_address: billing_node_address,
    billing_node_rune: billing_node_rune,
    max_total_sessions:
      String.to_integer(System.get_env("ZAPTUNNEL_MAX_TOTAL_SESSIONS", "10000")),
    max_pending_sessions_per_node:
      String.to_integer(System.get_env("ZAPTUNNEL_MAX_PENDING_SESSIONS_PER_NODE", "1")),
    connect_timeout_ms: String.to_integer(System.get_env("ZAPTUNNEL_CONNECT_TIMEOUT_MS", "5000")),
    tcp_send_timeout_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_TCP_SEND_TIMEOUT_MS", "5000")),
    dns_timeout_ms: String.to_integer(System.get_env("ZAPTUNNEL_DNS_TIMEOUT_MS", "2000")),
    verification_timeout_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_VERIFICATION_TIMEOUT_MS", "5000")),
    verification_success_ttl_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_VERIFICATION_SUCCESS_TTL_MS", "600000")),
    verification_failure_ttl_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_VERIFICATION_FAILURE_TTL_MS", "15000")),
    max_pending_verifications:
      String.to_integer(System.get_env("ZAPTUNNEL_MAX_PENDING_VERIFICATIONS", "128")),
    max_pending_verifications_per_source:
      String.to_integer(System.get_env("ZAPTUNNEL_MAX_PENDING_VERIFICATIONS_PER_SOURCE", "8")),
    max_verification_waiters_per_endpoint:
      String.to_integer(System.get_env("ZAPTUNNEL_MAX_VERIFICATION_WAITERS_PER_ENDPOINT", "16")),
    verification_cache_sweep_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_VERIFICATION_CACHE_SWEEP_MS", "60000")),
    verification_cache_max_size:
      String.to_integer(System.get_env("ZAPTUNNEL_VERIFICATION_CACHE_MAX_SIZE", "10000")),
    rate_limit_burst: String.to_integer(System.get_env("ZAPTUNNEL_RATE_LIMIT_BURST", "5")),
    rate_limit_refill_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_RATE_LIMIT_REFILL_MS", "1000")),
    global_rate_limit_burst:
      String.to_integer(System.get_env("ZAPTUNNEL_GLOBAL_RATE_LIMIT_BURST", "32")),
    global_rate_limit_refill_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_GLOBAL_RATE_LIMIT_REFILL_MS", "100")),
    payment_claim_rate_limit_burst:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_CLAIM_RATE_LIMIT_BURST", "10")),
    payment_claim_rate_limit_refill_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_CLAIM_RATE_LIMIT_REFILL_MS", "500")),
    payment_claim_global_rate_limit_burst:
      String.to_integer(System.get_env("ZAPTUNNEL_PAYMENT_CLAIM_GLOBAL_RATE_LIMIT_BURST", "256")),
    payment_claim_global_rate_limit_refill_ms:
      String.to_integer(
        System.get_env("ZAPTUNNEL_PAYMENT_CLAIM_GLOBAL_RATE_LIMIT_REFILL_MS", "10")
      ),
    rate_limit_max_buckets:
      String.to_integer(System.get_env("ZAPTUNNEL_RATE_LIMIT_MAX_BUCKETS", "10000")),
    max_websocket_frame_bytes:
      String.to_integer(System.get_env("ZAPTUNNEL_MAX_WEBSOCKET_FRAME_BYTES", "65583")),
    session_idle_timeout_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_SESSION_IDLE_TIMEOUT_MS", "300000")),
    drain_timeout_ms: String.to_integer(System.get_env("ZAPTUNNEL_DRAIN_TIMEOUT_MS", "30000")),
    website_host: System.get_env("ZAPTUNNEL_WEBSITE_HOST"),
    relay_host: System.get_env("ZAPTUNNEL_RELAY_HOST"),
    tls: tls
end
