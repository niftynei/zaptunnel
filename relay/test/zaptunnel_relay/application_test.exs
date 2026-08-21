defmodule ZaptunnelRelay.ApplicationTest do
  use ExUnit.Case, async: true

  alias ZaptunnelRelay.Application, as: RelayApplication

  test "bounds HTTP/2 streams and WebSocket messages" do
    options = RelayApplication.server_options({127, 0, 0, 1}, 4_000)

    assert options[:http_2_options][:default_local_settings][:max_concurrent_streams] == 32
    assert options[:websocket_options][:max_frame_size] == 65_583
    assert options[:websocket_options][:max_fragmented_message_size] == 65_583
    assert options[:websocket_options][:log_protocol_errors] == false
  end
end
