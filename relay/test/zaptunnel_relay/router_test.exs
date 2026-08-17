defmodule ZaptunnelRelay.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test
  import ExUnit.CaptureLog

  alias ZaptunnelRelay.{Admission, EndpointVerifier, RateLimiter, Router}

  defmodule Probe do
    def verify(node_id, address) do
      send(Application.fetch_env!(:zaptunnel_relay, :router_test_pid), {:probe, node_id, address})
      Application.get_env(:zaptunnel_relay, :router_test_probe_result, :ok)
    end
  end

  @node_id "02" <> String.duplicate("11", 32)

  setup do
    previous = Application.fetch_env!(:zaptunnel_relay, :endpoint_probe_module)
    Application.put_env(:zaptunnel_relay, :endpoint_probe_module, Probe)
    Application.put_env(:zaptunnel_relay, :router_test_pid, self())
    Application.put_env(:zaptunnel_relay, :router_test_probe_result, :ok)
    previous_website_host = Application.get_env(:zaptunnel_relay, :website_host)
    previous_relay_host = Application.get_env(:zaptunnel_relay, :relay_host)
    Admission.reset()
    EndpointVerifier.reset()
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:zaptunnel_relay, :endpoint_probe_module, previous)
      Application.delete_env(:zaptunnel_relay, :router_test_pid)
      Application.delete_env(:zaptunnel_relay, :router_test_probe_result)
      Application.put_env(:zaptunnel_relay, :website_host, previous_website_host)
      Application.put_env(:zaptunnel_relay, :relay_host, previous_relay_host)
    end)

    :ok
  end

  test "verifies the pinned endpoint before issuing a ticket" do
    conn = post_connection()
    assert conn.status == 201
    assert %{"websocket_path" => "/v1/connect/" <> ticket} = Jason.decode!(conn.resp_body)
    assert byte_size(ticket) > 20
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

  defp post_connection do
    :post
    |> conn("/v1/connections", Jason.encode!(%{node_id: @node_id, address: "127.0.0.1:9735"}))
    |> put_req_header("content-type", "application/json")
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
end
