defmodule ZaptunnelRelay.MixProject do
  use Mix.Project

  def project do
    [
      app: :zaptunnel_relay,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {ZaptunnelRelay.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:lib_secp256k1, "~> 0.8.0"},
      {:plug, "~> 1.20"},
      {:telemetry, "~> 1.0"},
      {:websock_adapter, "~> 0.6.0"}
    ]
  end
end
