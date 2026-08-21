defmodule ZaptunnelRelay.Metrics do
  @moduledoc false

  use GenServer

  @handler_id "zaptunnel-relay-prometheus"
  @events [
    [:zaptunnel_relay, :admission, :request],
    [:zaptunnel_relay, :admission, :rate_limited],
    [:zaptunnel_relay, :verification, :cache_hit],
    [:zaptunnel_relay, :verification, :stop],
    [:zaptunnel_relay, :session, :start],
    [:zaptunnel_relay, :session, :stop],
    [:zaptunnel_relay, :payment, :challenge],
    [:zaptunnel_relay, :payment, :redeem],
    [:zaptunnel_relay, :payment, :claim],
    [:zaptunnel_relay, :payment, :settlement],
    [:zaptunnel_relay, :payment, :watcher]
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def render do
    snapshot = GenServer.call(__MODULE__, :snapshot)
    admission = ZaptunnelRelay.Admission.stats()
    encode(snapshot, admission)
  end

  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts) do
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
    {:ok, initial_state()}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  def handle_event(event, measurements, metadata, _config) do
    GenServer.cast(__MODULE__, {:event, event, measurements, metadata})
  end

  @impl true
  def handle_cast({:event, event, measurements, metadata}, state) do
    {:noreply, record(state, event, measurements, metadata)}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}
  def handle_call(:reset, _from, _state), do: {:reply, :ok, initial_state()}

  defp initial_state do
    %{
      admission: %{},
      rate_limited: %{},
      verification: %{},
      verification_failures: %{},
      verification_cache: %{},
      verification_duration_ms: 0,
      verification_duration_count: 0,
      sessions_started: 0,
      sessions_ended: %{},
      session_duration_ms: 0,
      session_duration_count: 0,
      browser_bytes: 0,
      node_bytes: 0,
      payment_challenges: %{},
      payment_redemptions: %{},
      payment_claims: %{},
      payment_settlements: %{},
      payment_settlement_delay_ms: 0,
      payment_settlement_delay_count: 0,
      payment_watcher_errors: 0
    }
  end

  defp record(state, [:zaptunnel_relay, :admission, :request], _measurements, metadata) do
    update_in(state.admission, &increment(&1, admission_result(metadata[:result])))
  end

  defp record(state, [:zaptunnel_relay, :admission, :rate_limited], measurements, metadata) do
    scope = metadata[:scope] |> to_string()
    update_in(state.rate_limited, &increment_by(&1, scope, measurements[:count]))
  end

  defp record(state, [:zaptunnel_relay, :verification, :cache_hit], _measurements, metadata) do
    update_in(state.verification_cache, &increment(&1, result_label(metadata[:result])))
  end

  defp record(state, [:zaptunnel_relay, :verification, :stop], measurements, metadata) do
    state =
      state
      |> update_in([:verification], &increment(&1, result_label(metadata[:result])))
      |> Map.update!(:verification_duration_ms, &(&1 + measurements[:duration_ms]))
      |> Map.update!(:verification_duration_count, &(&1 + 1))

    case {metadata[:failure_stage], metadata[:failure_reason]} do
      {stage, reason}
      when is_atom(stage) and not is_nil(stage) and is_atom(reason) and not is_nil(reason) ->
        update_in(state.verification_failures, &increment(&1, {stage, reason}))

      _success_or_legacy_event ->
        state
    end
  end

  defp record(state, [:zaptunnel_relay, :session, :start], _measurements, _metadata) do
    %{state | sessions_started: state.sessions_started + 1}
  end

  defp record(state, [:zaptunnel_relay, :session, :stop], measurements, metadata) do
    state
    |> update_in([:sessions_ended], &increment(&1, session_reason(metadata[:reason])))
    |> Map.update!(:session_duration_ms, &(&1 + measurements[:duration_ms]))
    |> Map.update!(:session_duration_count, &(&1 + 1))
    |> Map.update!(:browser_bytes, &(&1 + measurements[:bytes_from_browser]))
    |> Map.update!(:node_bytes, &(&1 + measurements[:bytes_from_node]))
  end

  defp record(state, [:zaptunnel_relay, :payment, :challenge], measurements, metadata) do
    update_in(
      state.payment_challenges,
      &increment_by(&1, result_label(metadata[:result]), measurements[:count])
    )
  end

  defp record(state, [:zaptunnel_relay, :payment, :redeem], measurements, metadata) do
    label = "#{metadata[:protocol]}:#{result_label(metadata[:result])}"
    update_in(state.payment_redemptions, &increment_by(&1, label, measurements[:count]))
  end

  defp record(state, [:zaptunnel_relay, :payment, :claim], measurements, metadata) do
    update_in(
      state.payment_claims,
      &increment_by(&1, Atom.to_string(metadata[:result]), measurements[:count])
    )
  end

  defp record(state, [:zaptunnel_relay, :payment, :settlement], measurements, metadata) do
    state
    |> update_in(
      [:payment_settlements],
      &increment_by(&1, Atom.to_string(metadata[:result]), measurements[:count])
    )
    |> Map.update!(:payment_settlement_delay_ms, &(&1 + measurements[:delay_ms]))
    |> Map.update!(:payment_settlement_delay_count, &(&1 + measurements[:count]))
  end

  defp record(state, [:zaptunnel_relay, :payment, :watcher], measurements, _metadata) do
    Map.update!(state, :payment_watcher_errors, &(&1 + measurements[:count]))
  end

  defp record(state, _event, _measurements, _metadata), do: state

  defp increment(values, key), do: Map.update(values, key, 1, &(&1 + 1))
  defp increment_by(values, key, count), do: Map.update(values, key, count, &(&1 + count))

  defp admission_result(:ok), do: "accepted"
  defp admission_result({:error, reason}), do: Atom.to_string(reason)
  defp admission_result(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp admission_result(_result), do: "error"

  defp result_label(:ok), do: "success"
  defp result_label({:error, _reason}), do: "failure"
  defp result_label(_result), do: "failure"

  defp session_reason(:normal), do: "normal"
  defp session_reason(:frame_too_large), do: "frame_too_large"
  defp session_reason(:unsupported_data), do: "unsupported_data"
  defp session_reason(:timeout), do: "timeout"
  defp session_reason(_reason), do: "error"

  defp encode(metrics, admission) do
    [
      help("zaptunnel_admission_requests_total", "Admission requests by outcome", "counter"),
      labelled("zaptunnel_admission_requests_total", "result", metrics.admission),
      help(
        "zaptunnel_rate_limited_total",
        "Requests rejected by source rate limiting",
        "counter"
      ),
      labelled("zaptunnel_rate_limited_total", "scope", metrics.rate_limited),
      help("zaptunnel_endpoint_verifications_total", "Endpoint verification results", "counter"),
      labelled("zaptunnel_endpoint_verifications_total", "result", metrics.verification),
      help(
        "zaptunnel_endpoint_verification_failures_total",
        "Endpoint verification failures by bounded internal reason",
        "counter"
      ),
      failure_labels(metrics.verification_failures),
      help(
        "zaptunnel_endpoint_verification_cache_hits_total",
        "Endpoint verification cache hits",
        "counter"
      ),
      labelled(
        "zaptunnel_endpoint_verification_cache_hits_total",
        "result",
        metrics.verification_cache
      ),
      help(
        "zaptunnel_endpoint_verification_duration_seconds",
        "Endpoint verification duration",
        "summary"
      ),
      sample(
        "zaptunnel_endpoint_verification_duration_seconds_sum",
        metrics.verification_duration_ms / 1_000
      ),
      sample(
        "zaptunnel_endpoint_verification_duration_seconds_count",
        metrics.verification_duration_count
      ),
      help("zaptunnel_sessions_started_total", "Forwarding sessions started", "counter"),
      sample("zaptunnel_sessions_started_total", metrics.sessions_started),
      help("zaptunnel_sessions_ended_total", "Forwarding sessions ended by reason", "counter"),
      labelled("zaptunnel_sessions_ended_total", "reason", metrics.sessions_ended),
      help("zaptunnel_session_duration_seconds", "Forwarding session duration", "summary"),
      sample("zaptunnel_session_duration_seconds_sum", metrics.session_duration_ms / 1_000),
      sample("zaptunnel_session_duration_seconds_count", metrics.session_duration_count),
      help("zaptunnel_forwarded_bytes_total", "Opaque bytes forwarded by direction", "counter"),
      sample(
        "zaptunnel_forwarded_bytes_total{direction=\"browser_to_node\"}",
        metrics.browser_bytes
      ),
      sample(
        "zaptunnel_forwarded_bytes_total{direction=\"node_to_browser\"}",
        metrics.node_bytes
      ),
      help("zaptunnel_sessions", "Pending and active admission slots", "gauge"),
      sample("zaptunnel_sessions{state=\"pending\"}", admission.pending),
      sample("zaptunnel_sessions{state=\"active\"}", admission.active),
      sample("zaptunnel_sessions{state=\"total\"}", admission.total),
      help("zaptunnel_pending_session_capacity", "Configured pending ticket capacity", "gauge"),
      sample(
        "zaptunnel_pending_session_capacity",
        Application.fetch_env!(:zaptunnel_relay, :max_pending_sessions)
      ),
      help(
        "zaptunnel_payment_challenges_total",
        "Connection payment challenges by outcome",
        "counter"
      ),
      labelled("zaptunnel_payment_challenges_total", "result", metrics.payment_challenges),
      help(
        "zaptunnel_payment_redemptions_total",
        "Connection payment redemptions by protocol and outcome",
        "counter"
      ),
      payment_redemptions(metrics.payment_redemptions),
      help("zaptunnel_payment_claims_total", "Payment lease claims by outcome", "counter"),
      labelled("zaptunnel_payment_claims_total", "result", metrics.payment_claims),
      help(
        "zaptunnel_payment_settlements_total",
        "Billing-node settlements by reconciliation outcome",
        "counter"
      ),
      labelled("zaptunnel_payment_settlements_total", "result", metrics.payment_settlements),
      help(
        "zaptunnel_payment_settlement_delay_seconds",
        "Delay between CLN settlement and relay observation",
        "summary"
      ),
      sample(
        "zaptunnel_payment_settlement_delay_seconds_sum",
        metrics.payment_settlement_delay_ms / 1_000
      ),
      sample(
        "zaptunnel_payment_settlement_delay_seconds_count",
        metrics.payment_settlement_delay_count
      ),
      help(
        "zaptunnel_payment_watcher_errors_total",
        "Billing settlement watcher failures",
        "counter"
      ),
      sample("zaptunnel_payment_watcher_errors_total", metrics.payment_watcher_errors),
      help("zaptunnel_ready", "Whether the relay accepts new admissions", "gauge"),
      sample("zaptunnel_ready", if(admission.draining, do: 0, else: 1)),
      help("zaptunnel_session_capacity", "Configured global session capacity", "gauge"),
      sample(
        "zaptunnel_session_capacity",
        Application.fetch_env!(:zaptunnel_relay, :max_total_sessions)
      )
    ]
    |> IO.iodata_to_binary()
  end

  defp help(name, description, type),
    do: ["# HELP ", name, " ", description, "\n# TYPE ", name, " ", type, "\n"]

  defp labelled(name, label, values) do
    values
    |> Enum.sort()
    |> Enum.map(fn {value, count} -> sample(~s(#{name}{#{label}="#{value}"}), count) end)
  end

  defp failure_labels(values) do
    values
    |> Enum.sort()
    |> Enum.map(fn {{stage, reason}, count} ->
      sample(
        ~s(zaptunnel_endpoint_verification_failures_total{stage="#{stage}",reason="#{reason}"}),
        count
      )
    end)
  end

  defp payment_redemptions(values) do
    values
    |> Enum.sort()
    |> Enum.map(fn {label, count} ->
      [protocol, result] = String.split(label, ":", parts: 2)

      sample(
        ~s(zaptunnel_payment_redemptions_total{protocol="#{protocol}",result="#{result}"}),
        count
      )
    end)
  end

  defp sample(name, value), do: [name, " ", to_string(value), "\n"]
end
