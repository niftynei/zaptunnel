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

  config :zaptunnel_relay,
    ip: ip,
    port: String.to_integer(System.get_env("ZAPTUNNEL_WEB_PORT", "4000")),
    allow_private_addresses:
      System.get_env("ZAPTUNNEL_ALLOW_PRIVATE_ADDRESSES", "false") in ["1", "true"],
    ticket_ttl_ms: String.to_integer(System.get_env("ZAPTUNNEL_TICKET_TTL_MS", "10000")),
    free_sessions_per_node:
      String.to_integer(System.get_env("ZAPTUNNEL_FREE_SESSIONS_PER_NODE", "3")),
    max_total_sessions:
      String.to_integer(System.get_env("ZAPTUNNEL_MAX_TOTAL_SESSIONS", "10000")),
    connect_timeout_ms: String.to_integer(System.get_env("ZAPTUNNEL_CONNECT_TIMEOUT_MS", "5000")),
    dns_timeout_ms: String.to_integer(System.get_env("ZAPTUNNEL_DNS_TIMEOUT_MS", "2000")),
    verification_timeout_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_VERIFICATION_TIMEOUT_MS", "5000")),
    verification_success_ttl_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_VERIFICATION_SUCCESS_TTL_MS", "600000")),
    verification_failure_ttl_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_VERIFICATION_FAILURE_TTL_MS", "15000")),
    max_pending_verifications:
      String.to_integer(System.get_env("ZAPTUNNEL_MAX_PENDING_VERIFICATIONS", "128")),
    rate_limit_burst: String.to_integer(System.get_env("ZAPTUNNEL_RATE_LIMIT_BURST", "5")),
    rate_limit_refill_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_RATE_LIMIT_REFILL_MS", "1000")),
    max_websocket_frame_bytes:
      String.to_integer(System.get_env("ZAPTUNNEL_MAX_WEBSOCKET_FRAME_BYTES", "65569")),
    session_idle_timeout_ms:
      String.to_integer(System.get_env("ZAPTUNNEL_SESSION_IDLE_TIMEOUT_MS", "300000")),
    website_host: System.get_env("ZAPTUNNEL_WEBSITE_HOST"),
    relay_host: System.get_env("ZAPTUNNEL_RELAY_HOST"),
    tls: tls
end
