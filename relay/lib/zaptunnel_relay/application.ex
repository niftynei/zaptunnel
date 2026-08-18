defmodule ZaptunnelRelay.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        ZaptunnelRelay.Admission,
        ZaptunnelRelay.Payments,
        ZaptunnelRelay.Metrics,
        ZaptunnelRelay.Billing.SettlementWatcher,
        ZaptunnelRelay.RateLimiter,
        {Task.Supervisor, name: ZaptunnelRelay.ProbeSupervisor},
        ZaptunnelRelay.EndpointVerifier
      ]
      |> maybe_add_server()

    Supervisor.start_link(children, strategy: :one_for_one, name: ZaptunnelRelay.Supervisor)
  end

  @impl true
  def prep_stop(state) do
    if Process.whereis(ZaptunnelRelay.Admission) do
      :ok = ZaptunnelRelay.Admission.begin_drain()
      timeout = Application.fetch_env!(:zaptunnel_relay, :drain_timeout_ms)
      deadline = System.monotonic_time(:millisecond) + timeout
      Logger.info("relay draining started timeout_ms=#{timeout}")
      wait_for_sessions(deadline)
    end

    state
  end

  defp wait_for_sessions(deadline) do
    stats = ZaptunnelRelay.Admission.stats()

    cond do
      stats.total == 0 ->
        Logger.info("relay draining completed active=0 pending=0")

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning(
          "relay drain deadline reached active=#{stats.active} pending=#{stats.pending}"
        )

      true ->
        Process.sleep(100)
        wait_for_sessions(deadline)
    end
  end

  defp maybe_add_server(children) do
    if Application.fetch_env!(:zaptunnel_relay, :enabled) do
      ip = Application.fetch_env!(:zaptunnel_relay, :ip)
      port = Application.fetch_env!(:zaptunnel_relay, :port)
      children ++ [{Bandit, server_options(ip, port)}]
    else
      children
    end
  end

  def server_options(ip, port) do
    base = [plug: ZaptunnelRelay.Router, ip: ip, port: port]

    case Application.fetch_env!(:zaptunnel_relay, :tls) do
      false ->
        base

      %{certfile: certfile, keyfile: keyfile} ->
        base ++
          [
            scheme: :https,
            thousand_island_options: [
              transport_options: [certfile: certfile, keyfile: keyfile]
            ]
          ]
    end
  end
end
