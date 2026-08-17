defmodule ZaptunnelRelay.MetricsTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ZaptunnelRelay.{Admission, Metrics, Router, Telemetry}

  @node_id "02" <> String.duplicate("11", 32)
  @address {{127, 0, 0, 1}, 9_735}

  setup do
    Admission.reset()
    Metrics.reset()
    :ok
  end

  test "exports Prometheus counters, summaries, byte counts, and admission gauges" do
    assert {:ok, ticket} = Admission.issue(@node_id, @address)
    owner = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, _target} = Admission.claim(ticket, owner)

    Telemetry.emit([:admission, :request], %{count: 1}, %{result: :ok})
    Telemetry.emit([:verification, :stop], %{duration_ms: 250}, %{result: :ok})

    Telemetry.emit(
      [:verification, :stop],
      %{duration_ms: 50},
      %{
        result: {:error, :endpoint_unverified},
        failure_stage: :ping,
        failure_reason: :message_limit
      }
    )

    Telemetry.emit([:session, :start], %{count: 1})

    Telemetry.emit(
      [:session, :stop],
      %{duration_ms: 1_500, bytes_from_browser: 12, bytes_from_node: 34},
      %{reason: :normal, node_id: @node_id}
    )

    body = Metrics.render()

    assert body =~ ~s(zaptunnel_admission_requests_total{result="accepted"} 1)
    assert body =~ ~s(zaptunnel_endpoint_verifications_total{result="success"} 1)
    assert body =~ ~s(zaptunnel_endpoint_verifications_total{result="failure"} 1)

    assert body =~
             ~s(zaptunnel_endpoint_verification_failures_total{stage="ping",reason="message_limit"} 1)

    refute body =~ ~s(zaptunnel_endpoint_verification_failures_total{stage="",reason=""})
    assert body =~ "zaptunnel_endpoint_verification_duration_seconds_sum 0.3"
    assert body =~ "zaptunnel_sessions_started_total 1"
    assert body =~ ~s(zaptunnel_sessions_ended_total{reason="normal"} 1)
    assert body =~ ~s(zaptunnel_forwarded_bytes_total{direction="browser_to_node"} 12)
    assert body =~ ~s(zaptunnel_forwarded_bytes_total{direction="node_to_browser"} 34)
    assert body =~ ~s(zaptunnel_sessions{state="active"} 1)
    refute body =~ @node_id

    Process.exit(owner, :kill)
  end

  test "serves metrics using the Prometheus text format" do
    conn = Router.call(conn(:get, "/metrics"), [])

    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "content-type") == [
             "text/plain; version=0.0.4; charset=utf-8"
           ]

    assert conn.resp_body =~ "# TYPE zaptunnel_sessions gauge"
  end
end
