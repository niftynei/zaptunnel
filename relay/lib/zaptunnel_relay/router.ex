defmodule ZaptunnelRelay.Router do
  @moduledoc false

  use Plug.Router
  require Logger

  @static_opts Plug.Static.init(
                 at: "/",
                 from: :zaptunnel_relay,
                 gzip: true,
                 only: ~w(assets favicon.svg)
               )

  plug(:request_id)
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

  get "/readyz" do
    relay_only(conn, fn conn ->
      if ZaptunnelRelay.Admission.ready?() do
        json(conn, 200, %{status: "ready"})
      else
        json(conn, 503, %{status: "draining"})
      end
    end)
  end

  get "/metrics" do
    relay_only(conn, fn conn ->
      conn
      |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
      |> send_resp(200, ZaptunnelRelay.Metrics.render())
    end)
  end

  post "/v1/connections" do
    request_id = conn.assigns.zaptunnel_request_id
    submitted_node_id = conn.body_params["node_id"]
    submitted_address = conn.body_params["address"]

    relay_only(conn, fn conn ->
      result =
        with :ok <- ZaptunnelRelay.RateLimiter.check(conn.remote_ip),
             :ok <- ZaptunnelRelay.Admission.check_ready(),
             {:ok, node_id} <- validate_node_id(submitted_node_id),
             {:ok, parsed} <- ZaptunnelRelay.Address.parse(submitted_address),
             {:ok, pinned_address} <- resolve(parsed),
             :ok <-
               ZaptunnelRelay.EndpointVerifier.verify(node_id, pinned_address,
                 request_id: request_id
               ),
             result <- admit(conn, node_id, pinned_address, request_id) do
          result
        end

      ZaptunnelRelay.Telemetry.emit([:admission, :request], %{count: 1}, %{
        result: result_tag(result)
      })

      log_admission(request_id, result, submitted_node_id, submitted_address)

      case result do
        {:ok, ticket} ->
          json(conn, 201, %{websocket_path: "/v1/connect/#{ticket}"})

        {:ok, ticket, lease, receipt} ->
          conn
          |> put_resp_header("payment-receipt", receipt)
          |> json(201, %{
            lease: lease.token,
            lease_expires_at: lease.expires_at,
            websocket_path: "/v1/connect/#{ticket}"
          })

        {:payment_required, challenge} ->
          payment_required(conn, challenge)

        {:error, :rate_limited} ->
          json(conn, 429, %{error: "rate_limited"})

        {:error, :connection_limit} ->
          json(conn, 429, %{error: "connection_limit"})

        {:error, :lease_in_use} ->
          json(conn, 409, %{error: "lease_in_use"})

        {:error, reason} when reason in [:invalid_lease, :lease_node_mismatch] ->
          json(conn, 401, %{error: Atom.to_string(reason)})

        {:error, reason}
        when reason in [
               :malformed_payment_credential,
               :unsupported_payment_credential,
               :invalid_payment_token,
               :invalid_preimage,
               :unknown_challenge,
               :challenge_mismatch,
               :payment_expired
             ] ->
          json(conn, 402, %{error: Atom.to_string(reason)})

        {:error, :billing_unavailable} ->
          json(conn, 503, %{error: "billing_unavailable"})

        {:error, :payment_quote_limit} ->
          json(conn, 429, %{error: "payment_quote_limit"})

        {:error, :endpoint_unverified} ->
          json(conn, 422, %{error: "endpoint_unverified"})

        {:error, :relay_overloaded} ->
          json(conn, 503, %{error: "relay_overloaded"})

        {:error, :relay_draining} ->
          json(conn, 503, %{error: "relay_draining"})

        {:error, :onion_unavailable} ->
          json(conn, 503, %{error: "onion_unavailable"})

        {:error, :non_public_address} ->
          json(conn, 400, %{error: "non_public_address"})

        {:error, _reason} ->
          json(conn, 400, %{error: "invalid_connection_request"})
      end
    end)
  end

  post "/v1/payments/:quote_id/claim" do
    relay_only(conn, fn conn ->
      claim_token =
        conn
        |> get_req_header("authorization")
        |> List.first()
        |> parse_claim_authorization()

      result =
        with true <- ZaptunnelRelay.Payments.enabled?(),
             :ok <- ZaptunnelRelay.RateLimiter.check(conn.remote_ip),
             {:ok, token} <- claim_token do
          ZaptunnelRelay.Payments.claim(quote_id, token)
        else
          false -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end

      conn = put_resp_header(conn, "cache-control", "no-store")

      case result do
        {:ok, lease} ->
          json(conn, 200, %{
            lease: lease.token,
            lease_expires_at: lease.expires_at,
            status: "paid"
          })

        {:pending, retry_after_ms} ->
          conn
          |> put_resp_header("retry-after", Integer.to_string(ceil(retry_after_ms / 1_000)))
          |> json(202, %{status: "pending"})

        {:error, :payment_expired} ->
          json(conn, 410, %{error: "payment_expired"})

        {:error, reason} when reason in [:invalid_claim_token, :unknown_challenge] ->
          json(conn, 401, %{error: "invalid_claim"})

        {:error, :rate_limited} ->
          json(conn, 429, %{error: "rate_limited"})

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, _reason} ->
          json(conn, 503, %{error: "payment_status_unavailable"})
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
        _error ->
          Logger.warning(
            "session ticket rejected request_id=#{conn.assigns.zaptunnel_request_id} reason=invalid_ticket"
          )

          json(conn, 401, %{error: "invalid_ticket"})
      end
    end)
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  defp cors(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header(
      "access-control-allow-headers",
      "authorization,content-type,x-zaptunnel-lease"
    )
    |> put_resp_header(
      "access-control-expose-headers",
      "payment-receipt,www-authenticate,x-request-id"
    )
    |> put_resp_header("access-control-allow-methods", "GET,POST,OPTIONS")
  end

  defp request_id(conn, _opts) do
    request_id = "zt_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    conn
    |> assign(:zaptunnel_request_id, request_id)
    |> put_resp_header("x-request-id", request_id)
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
    allow_onion? = not is_nil(Application.get_env(:zaptunnel_relay, :tor_socks_proxy))

    ZaptunnelRelay.Address.resolve(parsed,
      allow_private?: allow_private?,
      allow_onion?: allow_onion?
    )
  end

  defp admit(conn, node_id, address, request_id) do
    lease = get_req_header(conn, "x-zaptunnel-lease") |> List.first()
    authorization = get_req_header(conn, "authorization") |> List.first()

    cond do
      is_binary(lease) and ZaptunnelRelay.Payments.enabled?() ->
        with {:ok, lease_id} <- ZaptunnelRelay.Payments.authorize_lease(lease, node_id) do
          ZaptunnelRelay.Admission.issue(node_id, address,
            request_id: request_id,
            paid_lease: lease_id
          )
        end

      is_binary(authorization) and ZaptunnelRelay.Payments.enabled?() ->
        with {:ok, paid_lease, receipt} <- ZaptunnelRelay.Payments.redeem(authorization, node_id),
             {:ok, ticket} <-
               ZaptunnelRelay.Admission.issue(node_id, address,
                 request_id: request_id,
                 paid_lease: paid_lease.id
               ) do
          {:ok, ticket, paid_lease, receipt}
        end

      true ->
        case ZaptunnelRelay.Admission.issue(node_id, address, request_id: request_id) do
          {:error, :connection_limit} = limit ->
            if ZaptunnelRelay.Payments.enabled?() do
              case ZaptunnelRelay.Payments.challenge(node_id, conn.host, conn.remote_ip) do
                {:ok, challenge} -> {:payment_required, challenge}
                {:error, reason} -> {:error, reason}
              end
            else
              limit
            end

          result ->
            result
        end
    end
  end

  defp payment_required(conn, challenge) do
    headers = Enum.map(challenge.www_authenticate, &{"www-authenticate", &1})

    conn
    |> prepend_resp_headers(headers)
    |> put_resp_header("cache-control", "no-store")
    |> json(402, %{
      amount_sats: challenge.amount_sats,
      claim_path: challenge.claim_path,
      claim_token: challenge.claim_token,
      error: "payment_required",
      expires_at: challenge.expires_at,
      invoice: challenge.invoice,
      l402_token: challenge.l402_token,
      mpp_challenge: challenge.mpp_challenge,
      payment_hash: challenge.payment_hash,
      payment_protocols: challenge.protocols,
      quote_id: challenge.quote_id,
      retry_after_ms: challenge.retry_after_ms
    })
  end

  defp parse_claim_authorization("ZaptunnelClaim " <> token) when byte_size(token) >= 32,
    do: {:ok, token}

  defp parse_claim_authorization(_authorization), do: {:error, :invalid_claim_token}

  defp result_tag({:ok, _ticket}), do: :ok
  defp result_tag({:ok, _ticket, _lease, _receipt}), do: :ok
  defp result_tag({:payment_required, _challenge}), do: {:error, :payment_required}
  defp result_tag({:error, reason}), do: {:error, reason}

  defp log_admission(request_id, {:ok, _ticket}, node_id, address) do
    Logger.info(
      "admission accepted request_id=#{request_id} node_id=#{abbreviate_node_id(node_id)} " <>
        "submitted_address=#{inspect_submitted(address)}"
    )
  end

  defp log_admission(request_id, {:ok, _ticket, _lease, _receipt}, node_id, address) do
    Logger.info(
      "paid admission accepted request_id=#{request_id} node_id=#{abbreviate_node_id(node_id)} " <>
        "submitted_address=#{inspect_submitted(address)}"
    )
  end

  defp log_admission(request_id, {:payment_required, challenge}, node_id, address) do
    Logger.info(
      "admission payment required request_id=#{request_id} quote_id=#{challenge.quote_id} " <>
        "node_id=#{abbreviate_node_id(node_id)} submitted_address=#{inspect_submitted(address)}"
    )
  end

  defp log_admission(request_id, {:error, reason}, node_id, address) do
    Logger.warning(
      "admission rejected request_id=#{request_id} stage=#{admission_stage(reason)} " <>
        "reason=#{safe_reason(reason)} node_id=#{abbreviate_node_id(node_id)} " <>
        "submitted_address=#{inspect_submitted(address)}"
    )
  end

  defp admission_stage(:rate_limited), do: :rate_limit
  defp admission_stage(:connection_limit), do: :quota
  defp admission_stage(:relay_overloaded), do: :capacity
  defp admission_stage(:relay_draining), do: :lifecycle
  defp admission_stage(:endpoint_unverified), do: :verification
  defp admission_stage(:non_public_address), do: :address_policy

  defp admission_stage(reason) when reason in [:onion_unavailable, :invalid_onion_address],
    do: :address_policy

  defp admission_stage(reason) when reason in [:invalid_node_id, :invalid_address], do: :input
  defp admission_stage(reason) when reason in [:dns_timeout, :nxdomain, :eai_again], do: :dns
  defp admission_stage(_reason), do: :admission

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :error

  defp abbreviate_node_id(<<prefix::binary-size(8), _::binary-size(50), suffix::binary-size(8)>>),
    do: prefix <> "…" <> suffix

  defp abbreviate_node_id(_node_id), do: "invalid"

  defp inspect_submitted(value) when is_binary(value),
    do: inspect(value, printable_limit: 128, limit: 10)

  defp inspect_submitted(_value), do: "invalid"

  defp json(conn, status, body) do
    body =
      case {body, conn.assigns[:zaptunnel_request_id]} do
        {%{error: _error}, request_id} when is_binary(request_id) ->
          Map.put_new(body, :request_id, request_id)

        _success_or_unidentified ->
          body
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
