defmodule ZaptunnelRelay.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

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
    Admission.reset()
    EndpointVerifier.reset()
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:zaptunnel_relay, :endpoint_probe_module, previous)
      Application.delete_env(:zaptunnel_relay, :router_test_pid)
      Application.delete_env(:zaptunnel_relay, :router_test_probe_result)
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

    conn = post_connection()
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body) == %{"error" => "endpoint_unverified"}
  end

  defp post_connection do
    :post
    |> conn("/v1/connections", Jason.encode!(%{node_id: @node_id, address: "127.0.0.1:9735"}))
    |> put_req_header("content-type", "application/json")
    |> Router.call([])
  end
end
