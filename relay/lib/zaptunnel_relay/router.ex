defmodule ZaptunnelRelay.Router do
  @moduledoc false

  use Plug.Router

  @static_opts Plug.Static.init(
                 at: "/",
                 from: :zaptunnel_relay,
                 gzip: true,
                 only: ~w(assets favicon.svg)
               )

  plug(:surface)
  plug(:static)
  plug(:cors)
  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  options "/*path" do
    relay_only(conn, fn conn -> send_resp(conn, 204, "") end)
  end

  get "/" do
    case conn.assigns[:zaptunnel_surface] do
      surface when surface in [:website, :development] -> serve_website(conn)
      :relay -> redirect_to_website(conn)
    end
  end

  get "/healthz" do
    relay_only(conn, fn conn -> json(conn, 200, %{status: "ok"}) end)
  end

  get "/metrics" do
    relay_only(conn, fn conn ->
      conn
      |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
      |> send_resp(200, ZaptunnelRelay.Metrics.render())
    end)
  end

  post "/v1/connections" do
    relay_only(conn, fn conn ->
      result =
        with :ok <- ZaptunnelRelay.RateLimiter.check(conn.remote_ip),
             {:ok, node_id} <- validate_node_id(conn.body_params["node_id"]),
             {:ok, parsed} <- ZaptunnelRelay.Address.parse(conn.body_params["address"]),
             {:ok, pinned_address} <- resolve(parsed),
             :ok <- ZaptunnelRelay.EndpointVerifier.verify(node_id, pinned_address),
             {:ok, ticket} <- ZaptunnelRelay.Admission.issue(node_id, pinned_address) do
          {:ok, ticket}
        end

      ZaptunnelRelay.Telemetry.emit([:admission, :request], %{count: 1}, %{
        result: result_tag(result)
      })

      case result do
        {:ok, ticket} -> json(conn, 201, %{websocket_path: "/v1/connect/#{ticket}"})
        {:error, :rate_limited} -> json(conn, 429, %{error: "rate_limited"})
        {:error, :connection_limit} -> json(conn, 429, %{error: "connection_limit"})
        {:error, :endpoint_unverified} -> json(conn, 422, %{error: "endpoint_unverified"})
        {:error, :relay_overloaded} -> json(conn, 503, %{error: "relay_overloaded"})
        {:error, :non_public_address} -> json(conn, 400, %{error: "non_public_address"})
        {:error, _reason} -> json(conn, 400, %{error: "invalid_connection_request"})
      end
    end)
  end

  get "/v1/connect/:ticket/*requested_target" do
    relay_only(conn, fn conn ->
      with [_target] <- requested_target,
           {:ok, target} <- ZaptunnelRelay.Admission.claim(ticket) do
        WebSockAdapter.upgrade(conn, ZaptunnelRelay.Session, target,
          timeout: Application.fetch_env!(:zaptunnel_relay, :session_idle_timeout_ms),
          max_frame_size: Application.fetch_env!(:zaptunnel_relay, :max_websocket_frame_bytes)
        )
      else
        _error -> json(conn, 401, %{error: "invalid_ticket"})
      end
    end)
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

  defp surface(conn, _opts) do
    website_host = Application.get_env(:zaptunnel_relay, :website_host)
    relay_host = Application.get_env(:zaptunnel_relay, :relay_host)

    surface =
      cond do
        is_nil(website_host) and is_nil(relay_host) -> :development
        conn.host == website_host -> :website
        conn.host == relay_host -> :relay
        loopback_request?(conn) -> :relay
        true -> :unknown
      end

    if surface == :unknown do
      conn |> json(421, %{error: "misdirected_request"}) |> halt()
    else
      assign(conn, :zaptunnel_surface, surface)
    end
  end

  defp static(%{assigns: %{zaptunnel_surface: surface}} = conn, _opts)
       when surface in [:website, :development],
       do: Plug.Static.call(conn, @static_opts)

  defp static(conn, _opts), do: conn

  defp relay_only(%{assigns: %{zaptunnel_surface: surface}} = conn, callback)
       when surface in [:relay, :development],
       do: callback.(conn)

  defp relay_only(conn, _callback), do: json(conn, 404, %{error: "not_found"})

  defp redirect_to_website(conn) do
    conn
    |> put_resp_header("location", "https://zapptunnel.com/#sdk")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(302, "")
  end

  defp serve_website(conn) do
    path = Application.app_dir(:zaptunnel_relay, "priv/static/index.html")

    if File.regular?(path) do
      conn
      |> put_resp_header(
        "content-security-policy",
        "default-src 'self'; connect-src 'self' https://relay.zapptunnel.com wss://relay.zapptunnel.com; img-src 'self' data:; style-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
      )
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type("text/html")
      |> send_file(200, path)
    else
      json(conn, 503, %{error: "website_not_packaged"})
    end
  end

  defp loopback_request?(%{host: host, remote_ip: remote_ip}) do
    host in ["127.0.0.1", "localhost", "::1"] and
      remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
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

  defp result_tag({:ok, _ticket}), do: :ok
  defp result_tag({:error, reason}), do: {:error, reason}

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
