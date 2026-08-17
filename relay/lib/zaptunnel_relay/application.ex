defmodule ZaptunnelRelay.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ZaptunnelRelay.Admission,
        ZaptunnelRelay.Metrics,
        ZaptunnelRelay.RateLimiter,
        {Task.Supervisor, name: ZaptunnelRelay.ProbeSupervisor},
        ZaptunnelRelay.EndpointVerifier
      ]
      |> maybe_add_server()

    Supervisor.start_link(children, strategy: :one_for_one, name: ZaptunnelRelay.Supervisor)
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
