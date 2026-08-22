defmodule ZaptunnelRelay.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test
  import ExUnit.CaptureLog

  alias ZaptunnelRelay.{
    Admission,
    EndpointVerifier,
    Payments,
    RateLimiter,
    Router
  }

  defmodule Probe do
    def verify(node_id, address) do
      send(Application.fetch_env!(:zaptunnel_relay, :router_test_pid), {:probe, node_id, address})
      Application.get_env(:zaptunnel_relay, :router_test_probe_result, :ok)
    end
  end

  defmodule InvoiceProvider do
    @behaviour ZaptunnelRelay.Billing.InvoiceProvider
    def create_invoice(_opts), do: Application.fetch_env!(:zaptunnel_relay, :router_test_invoice)
  end

  @node_id "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

  setup do
    previous = Application.fetch_env!(:zaptunnel_relay, :endpoint_probe_module)
    Application.put_env(:zaptunnel_relay, :endpoint_probe_module, Probe)
    Application.put_env(:zaptunnel_relay, :router_test_pid, self())
    Application.put_env(:zaptunnel_relay, :router_test_probe_result, :ok)
    previous_website_host = Application.get_env(:zaptunnel_relay, :website_host)
    previous_relay_host = Application.get_env(:zaptunnel_relay, :relay_host)
    previous_tor_proxy = Application.get_env(:zaptunnel_relay, :tor_socks_proxy)

    previous_payment =
      for key <- [
            :payments_enabled,
            :invoice_provider,
            :payment_token_secret,
            :free_sessions_per_node
          ],
          into: %{} do
        {key, Application.fetch_env!(:zaptunnel_relay, key)}
      end

    Admission.reset()
    Payments.reset()
    EndpointVerifier.reset()
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:zaptunnel_relay, :endpoint_probe_module, previous)
      Application.delete_env(:zaptunnel_relay, :router_test_pid)
      Application.delete_env(:zaptunnel_relay, :router_test_probe_result)
      Application.put_env(:zaptunnel_relay, :website_host, previous_website_host)
      Application.put_env(:zaptunnel_relay, :relay_host, previous_relay_host)
      Application.put_env(:zaptunnel_relay, :tor_socks_proxy, previous_tor_proxy)

      Enum.each(previous_payment, fn {key, value} ->
        Application.put_env(:zaptunnel_relay, key, value)
      end)

      Application.delete_env(:zaptunnel_relay, :router_test_invoice)
    end)

    :ok
  end

  test "verifies the pinned endpoint before issuing a ticket" do
    conn = post_connection()
    assert conn.status == 201
    assert %{"websocket_path" => "/v1/connect/" <> ticket} = Jason.decode!(conn.resp_body)
    assert byte_size(ticket) > 20
    [request_id] = get_resp_header(conn, "x-request-id")

    assert {:ok, %{request_id: ^request_id}} = Admission.claim(ticket)
    assert_receive {:probe, @node_id, {{127, 0, 0, 1}, 9_735}}
  end

  test "does not issue a ticket for an unverified endpoint" do
    Application.put_env(:zaptunnel_relay, :router_test_probe_result, {:error, :wrong_node})

    {conn, log} = capture_result_log(&post_connection/0)
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 422
    assert body["error"] == "endpoint_unverified"
    assert body["request_id"] =~ ~r/^zt_[A-Za-z0-9_-]{16}$/
    assert get_resp_header(conn, "x-request-id") == [body["request_id"]]
    assert log =~ "admission rejected request_id=#{body["request_id"]}"
    assert log =~ "stage=verification reason=endpoint_unverified"
  end

  test "preserves a v3 onion hostname for verification and session dialing" do
    onion = "duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion"
    Application.put_env(:zaptunnel_relay, :tor_socks_proxy, {{127, 0, 0, 1}, 9_050})

    conn = post_connection("#{onion}:9735")

    assert conn.status == 201
    assert_receive {:probe, @node_id, {:onion, ^onion, 9_735}}
  end

  test "rejects onion targets when the relay has no Tor proxy" do
    Application.put_env(:zaptunnel_relay, :tor_socks_proxy, nil)
    onion = "duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion"

    conn = post_connection("#{onion}:9735")

    assert conn.status == 503
    assert %{"error" => "onion_unavailable"} = Jason.decode!(conn.resp_body)
    refute_receive {:probe, _, _}
  end

  test "logs malformed admission input without reflecting it unsafely" do
    malicious_address = "bad-address\nforged=true"

    {conn, log} =
      capture_result_log(fn ->
        :post
        |> conn(
          "/v1/connections",
          Jason.encode!(%{node_id: "not-a-key", address: malicious_address})
        )
        |> put_req_header("content-type", "application/json")
        |> Router.call([])
      end)

    body = Jason.decode!(conn.resp_body)
    assert conn.status == 400
    assert body["request_id"] =~ ~r/^zt_[A-Za-z0-9_-]{16}$/
    assert log =~ "stage=input reason=invalid_node_id"
    assert log =~ ~s(submitted_address="bad-address\\nforged=true")
    refute log =~ "\nforged=true"
  end

  test "rejects a compressed-key encoding that is not a secp256k1 point" do
    conn =
      :post
      |> conn(
        "/v1/connections",
        Jason.encode!(%{node_id: "02" <> String.duplicate("ff", 32), address: "127.0.0.1:9735"})
      )
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status == 400
    assert %{"error" => "invalid_connection_request"} = Jason.decode!(conn.resp_body)
    refute_receive {:probe, _, _}
  end

  test "rate limits admission before parsing a large body" do
    previous_burst = Application.fetch_env!(:zaptunnel_relay, :rate_limit_burst)
    previous_refill = Application.fetch_env!(:zaptunnel_relay, :rate_limit_refill_ms)
    Application.put_env(:zaptunnel_relay, :rate_limit_burst, 1)
    Application.put_env(:zaptunnel_relay, :rate_limit_refill_ms, 60_000)
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:zaptunnel_relay, :rate_limit_burst, previous_burst)
      Application.put_env(:zaptunnel_relay, :rate_limit_refill_ms, previous_refill)
      RateLimiter.reset()
    end)

    assert post_connection().status == 201

    response =
      :post
      |> conn("/v1/connections", String.duplicate("x", 20_000))
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert response.status == 429
    assert %{"error" => "rate_limited"} = Jason.decode!(response.resp_body)
  end

  test "logs and meters admission requests rejected by the limiter" do
    previous_burst = Application.fetch_env!(:zaptunnel_relay, :rate_limit_burst)
    previous_refill = Application.fetch_env!(:zaptunnel_relay, :rate_limit_refill_ms)
    Application.put_env(:zaptunnel_relay, :rate_limit_burst, 0)
    Application.put_env(:zaptunnel_relay, :rate_limit_refill_ms, 60_000)
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:zaptunnel_relay, :rate_limit_burst, previous_burst)
      Application.put_env(:zaptunnel_relay, :rate_limit_refill_ms, previous_refill)
      RateLimiter.reset()
    end)

    {response, log} = capture_result_log(&post_connection/0)
    assert response.status == 429
    assert log =~ "stage=rate_limit reason=rate_limited"

    eventually(fn ->
      ZaptunnelRelay.Metrics.render() =~
        ~s(zaptunnel_admission_requests_total{result="rate_limited"})
    end)
  end

  test "supports the advertised websocket path without a trailing target" do
    response = Router.call(conn(:get, "/v1/connect/not-a-ticket"), [])
    assert response.status == 401
  end

  test "does not parse bodies on unrelated routes" do
    response = Router.call(conn(:put, "/not-found", String.duplicate("x", 20_000)), [])
    assert response.status == 404
  end

  test "caps admission request bodies" do
    request =
      :post
      |> conn("/v1/connections", String.duplicate("x", 20_000))
      |> put_req_header("content-type", "application/json")

    assert_raise Plug.Parsers.RequestTooLargeError, fn -> Router.call(request, []) end
  end

  test "serves metrics only to loopback peers" do
    response = Router.call(%{conn(:get, "/metrics") | remote_ip: {203, 0, 113, 1}}, [])
    assert response.status == 404
  end

  test "adds HSTS when the listener is configured for TLS" do
    previous_tls = Application.fetch_env!(:zaptunnel_relay, :tls)
    Application.put_env(:zaptunnel_relay, :tls, %{certfile: "test", keyfile: "test"})
    on_exit(fn -> Application.put_env(:zaptunnel_relay, :tls, previous_tls) end)

    response = Router.call(conn(:get, "/healthz"), [])

    assert get_resp_header(response, "strict-transport-security") == [
             "max-age=31536000; includeSubDomains"
           ]
  end

  test "static assets receive the website security headers" do
    favicon = Application.app_dir(:zaptunnel_relay, "priv/static/favicon.svg")
    File.mkdir_p!(Path.dirname(favicon))
    File.write!(favicon, ~s(<svg xmlns="http://www.w3.org/2000/svg"/>))
    on_exit(fn -> File.rm(favicon) end)

    response = Router.call(conn(:get, "/favicon.svg"), [])

    assert response.status == 200
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(response, "content-security-policy") != []
    assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
  end

  test "separates the website, relay, and unknown hosts" do
    Application.put_env(:zaptunnel_relay, :website_host, "zapptunnel.com")
    Application.put_env(:zaptunnel_relay, :relay_host, "relay.zapptunnel.com")

    website = Router.call(%{conn(:get, "/healthz") | host: "zapptunnel.com"}, [])
    relay = Router.call(%{conn(:get, "/healthz") | host: "relay.zapptunnel.com"}, [])
    unknown = Router.call(%{conn(:get, "/healthz") | host: "other.example"}, [])

    assert website.status == 404
    assert relay.status == 200
    assert unknown.status == 421
  end

  test "redirects the relay root to the SDK documentation" do
    Application.put_env(:zaptunnel_relay, :website_host, "zapptunnel.com")
    Application.put_env(:zaptunnel_relay, :relay_host, "relay.zapptunnel.com")

    response = Router.call(%{conn(:get, "/") | host: "relay.zapptunnel.com"}, [])

    assert response.status == 302
    assert get_resp_header(response, "location") == ["https://zapptunnel.com/#sdk"]
    assert get_resp_header(response, "cache-control") == ["no-store"]
  end

  test "readiness and admission reflect graceful draining" do
    ready = Router.call(conn(:get, "/readyz"), [])
    assert ready.status == 200
    assert %{"status" => "ready"} = Jason.decode!(ready.resp_body)

    assert :ok = Admission.begin_drain()

    draining = Router.call(conn(:get, "/readyz"), [])
    assert draining.status == 503
    assert %{"status" => "draining"} = Jason.decode!(draining.resp_body)

    admission = post_connection()
    assert admission.status == 503
    assert %{"error" => "relay_draining"} = Jason.decode!(admission.resp_body)
    refute_receive {:probe, _, _}
  end

  test "offers only BOLT12 after free slots are occupied" do
    Application.put_env(:zaptunnel_relay, :payments_enabled, true)
    Application.put_env(:zaptunnel_relay, :free_sessions_per_node, 0)
    Application.put_env(:zaptunnel_relay, :invoice_provider, InvoiceProvider)
    Application.put_env(:zaptunnel_relay, :payment_token_secret, String.duplicate("k", 32))

    Application.put_env(
      :zaptunnel_relay,
      :router_test_invoice,
      {:ok,
       %{
         invoice: "lni1test",
         offer_id: String.duplicate("aa", 32),
         payment_hash: String.duplicate("11", 32),
         expires_at: System.system_time(:second) + 300
       }}
    )

    challenge = post_connection()
    body = Jason.decode!(challenge.resp_body)
    assert challenge.status == 402
    assert body["protocol"] == "bolt12"
    refute Map.has_key?(body, "payment_protocols")
    assert body["invoice"] == "lni1test"
    assert body["claim_path"] == "/v1/payments/#{body["quote_id"]}/claim"
    assert body["claim_token"] =~ ~r/^zc_/
    assert get_resp_header(challenge, "www-authenticate") == []
    assert get_resp_header(challenge, "cache-control") == ["no-store"]

    legacy_credential =
      :post
      |> conn(
        "/v1/connections",
        Jason.encode!(%{node_id: @node_id, address: "127.0.0.1:9735"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "L402 obsolete-token:obsolete-preimage")
      |> Router.call([])

    assert legacy_credential.status == 402
    assert %{"protocol" => "bolt12"} = Jason.decode!(legacy_credential.resp_body)
  end

  test "polls a protected claim until CLN settlement is observed" do
    Application.put_env(:zaptunnel_relay, :payments_enabled, true)
    Application.put_env(:zaptunnel_relay, :free_sessions_per_node, 0)
    Application.put_env(:zaptunnel_relay, :invoice_provider, InvoiceProvider)
    Application.put_env(:zaptunnel_relay, :payment_token_secret, String.duplicate("k", 32))

    Application.put_env(
      :zaptunnel_relay,
      :router_test_invoice,
      {:ok,
       %{
         invoice: "lni1poll",
         offer_id: String.duplicate("aa", 32),
         payment_hash: String.duplicate("11", 32),
         expires_at: System.system_time(:second) + 300
       }}
    )

    body = post_connection() |> Map.fetch!(:resp_body) |> Jason.decode!()

    pending = claim_payment(body["claim_path"], body["claim_token"])
    assert pending.status == 202
    assert get_resp_header(pending, "retry-after") == ["2"]
    assert get_resp_header(pending, "cache-control") == ["no-store"]

    assert :ok =
             Payments.record_settlement(%{
               label: body["quote_id"],
               offer_id: String.duplicate("aa", 32),
               payment_hash: String.duplicate("11", 32),
               amount_received_msat: 10_000,
               paid_at: System.system_time(:second),
               pay_index: 1
             })

    paid = claim_payment(body["claim_path"], body["claim_token"])
    assert paid.status == 200
    assert %{"status" => "paid", "lease" => lease} = Jason.decode!(paid.resp_body)
    assert is_binary(lease)

    stolen = claim_payment(body["claim_path"], String.duplicate("x", 40))
    assert stolen.status == 401
    assert %{"error" => "invalid_claim"} = Jason.decode!(stolen.resp_body)
  end

  test "payment credentials cannot bypass admission while payments are disabled" do
    Application.put_env(:zaptunnel_relay, :payments_enabled, false)
    Application.put_env(:zaptunnel_relay, :free_sessions_per_node, 0)

    response =
      :post
      |> conn(
        "/v1/connections",
        Jason.encode!(%{node_id: @node_id, address: "127.0.0.1:9735"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-zaptunnel-lease", "attacker-controlled")
      |> Router.call([])

    assert response.status == 429
    assert %{"error" => "connection_limit"} = Jason.decode!(response.resp_body)
  end

  defp post_connection(address \\ "127.0.0.1:9735") do
    :post
    |> conn("/v1/connections", Jason.encode!(%{node_id: @node_id, address: address}))
    |> put_req_header("content-type", "application/json")
    |> Router.call([])
  end

  defp claim_payment(path, token) do
    :post
    |> conn(path, "")
    |> put_req_header("authorization", "ZaptunnelClaim #{token}")
    |> Router.call([])
  end

  defp capture_result_log(callback) do
    parent = self()

    log =
      capture_log(fn ->
        send(parent, {:logged_result, callback.()})
      end)

    assert_receive {:logged_result, result}
    {result, log}
  end

  defp eventually(assertion, attempts \\ 20)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(_assertion, 0), do: flunk("condition was not met")
end
