defmodule ZaptunnelRelay.Telemetry do
  @moduledoc false

  def emit(event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute([:zaptunnel_relay | event], measurements, metadata)
  end
end
