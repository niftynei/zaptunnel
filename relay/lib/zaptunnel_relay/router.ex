defmodule ZaptunnelRelay.Router do
  @moduledoc false

  use Plug.Router

  plug(:cors)
  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  options "/*path" do
    send_resp(conn, 204, "")
  end

  get "/healthz" do
    json(conn, 200, %{status: "ok"})
  end

  post "/v1/connections" do
    with :ok <- ZaptunnelRelay.RateLimiter.check(conn.remote_ip),
         {:ok, node_id} <- validate_node_id(conn.body_params["node_id"]),
         {:ok, parsed} <- ZaptunnelRelay.Address.parse(conn.body_params["address"]),
         {:ok, pinned_address} <- resolve(parsed),
         :ok <- ZaptunnelRelay.EndpointVerifier.verify(node_id, pinned_address),
         {:ok, ticket} <- ZaptunnelRelay.Admission.issue(node_id, pinned_address) do
      json(conn, 201, %{websocket_path: "/v1/connect/#{ticket}"})
    else
      {:error, :rate_limited} -> json(conn, 429, %{error: "rate_limited"})
      {:error, :connection_limit} -> json(conn, 429, %{error: "connection_limit"})
      {:error, :endpoint_unverified} -> json(conn, 422, %{error: "endpoint_unverified"})
      {:error, :relay_overloaded} -> json(conn, 503, %{error: "relay_overloaded"})
      {:error, :non_public_address} -> json(conn, 400, %{error: "non_public_address"})
      {:error, _reason} -> json(conn, 400, %{error: "invalid_connection_request"})
    end
  end

  get "/v1/connect/:ticket/*requested_target" do
    with [_target] <- requested_target,
         {:ok, target} <- ZaptunnelRelay.Admission.claim(ticket) do
      WebSockAdapter.upgrade(conn, ZaptunnelRelay.Session, target,
        timeout: Application.fetch_env!(:zaptunnel_relay, :session_idle_timeout_ms),
        max_frame_size: Application.fetch_env!(:zaptunnel_relay, :max_websocket_frame_bytes)
      )
    else
      _error -> json(conn, 401, %{error: "invalid_ticket"})
    end
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  defp cors(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-headers", "content-type")
    |> put_resp_header("access-control-allow-methods", "GET,POST,OPTIONS")
  end

  defp validate_node_id(<<prefix::binary-size(2), rest::binary-size(64)>> = node_id)
       when prefix in ["02", "03"] do
    case Base.decode16(rest, case: :mixed) do
      {:ok, _bytes} -> {:ok, String.downcase(node_id)}
      :error -> {:error, :invalid_node_id}
    end
  end

  defp validate_node_id(_node_id), do: {:error, :invalid_node_id}

  defp resolve(parsed) do
    allow_private? = Application.fetch_env!(:zaptunnel_relay, :allow_private_addresses)
    ZaptunnelRelay.Address.resolve(parsed, allow_private?: allow_private?)
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
