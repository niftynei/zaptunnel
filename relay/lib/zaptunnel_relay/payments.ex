defmodule ZaptunnelRelay.Payments do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def enabled?, do: Application.fetch_env!(:zaptunnel_relay, :payments_enabled)

  def challenge(node_id, realm, source \\ nil) do
    GenServer.call(__MODULE__, {:challenge, node_id, realm, source}, payment_timeout())
  end

  def authorize_lease(token, node_id) do
    safe_call({:authorize_lease, token, node_id})
  end

  def claim(quote_id, claim_token) do
    safe_call({:claim, quote_id, claim_token})
  end

  defp safe_call(request) do
    GenServer.call(__MODULE__, request)
  catch
    :exit, {:timeout, _} -> {:error, :billing_unavailable}
    :exit, {:noproc, _} -> {:error, :billing_unavailable}
    :exit, {:normal, _} -> {:error, :billing_unavailable}
  end

  def last_pay_index, do: GenServer.call(__MODULE__, :last_pay_index)

  def record_settlement(payment) do
    GenServer.call(__MODULE__, {:record_settlement, payment})
  end

  def watcher_heartbeat(status) when status in [:healthy, :unhealthy] do
    GenServer.cast(__MODULE__, {:watcher_heartbeat, status})
  end

  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts) do
    if enabled?() and byte_size(token_secret()) < 32 do
      {:stop, :payment_token_secret_too_short}
    else
      {table, quotes, last_pay_index} =
        open_store(Application.get_env(:zaptunnel_relay, :payment_state_path))

      {quotes, expired_ids} = prune(quotes)
      delete_expired(table, expired_ids)

      {:ok,
       %{
         quotes: quotes,
         table: table,
         last_pay_index: last_pay_index,
         watcher_healthy_at: nil
       }}
    end
  end

  @impl true
  def terminate(_reason, %{table: nil}), do: :ok
  def terminate(_reason, %{table: table}), do: :dets.close(table)

  @impl true
  def handle_call({:challenge, node_id, _realm, source}, _from, state) do
    id = random_id("zq_")
    amount_sats = Application.fetch_env!(:zaptunnel_relay, :payment_price_sats)
    ttl_ms = Application.fetch_env!(:zaptunnel_relay, :payment_quote_ttl_ms)
    provider = Application.fetch_env!(:zaptunnel_relay, :invoice_provider)
    claim_token = "zc_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    aggregated_source = ZaptunnelRelay.RateLimiter.source_key(source)

    source_hash =
      :crypto.mac(:hmac, :sha256, token_secret(), :erlang.term_to_binary(aggregated_source))

    result =
      with :ok <- pending_quote_capacity(state.quotes, source_hash),
           {:ok, invoice} <-
             provider.create_invoice(
               amount_sats: amount_sats,
               expiry_seconds: div(ttl_ms, 1_000),
               label: id
             ),
           :ok <- validate_invoice(invoice) do
        expires_at = min(invoice.expires_at, System.system_time(:second) + div(ttl_ms, 1_000))

        quote = %{
          id: id,
          node_id: node_id,
          amount_sats: amount_sats,
          invoice: invoice.invoice,
          payment_hash: String.downcase(invoice.payment_hash),
          offer_id: invoice.offer_id,
          expires_at: expires_at,
          claim_token_hash: :crypto.hash(:sha256, claim_token),
          source_hash: source_hash,
          settled_at: nil,
          redeemed: nil
        }

        response = %{
          amount_sats: amount_sats,
          claim_path: "/v1/payments/#{id}/claim",
          claim_token: claim_token,
          expires_at: expires_at,
          invoice: quote.invoice,
          payment_hash: quote.payment_hash,
          protocol: "bolt12",
          quote_id: id,
          retry_after_ms: Application.fetch_env!(:zaptunnel_relay, :payment_claim_poll_ms)
        }

        {:ok, quote, response}
      end

    case result do
      {:ok, quote, response} ->
        ZaptunnelRelay.Telemetry.emit([:payment, :challenge], %{count: 1}, %{result: :ok})
        persist(state.table, quote)
        {quotes, expired_ids} = prune(state.quotes)
        delete_expired(state.table, expired_ids)
        {:reply, {:ok, response}, %{state | quotes: Map.put(quotes, id, quote)}}

      {:error, reason} ->
        ZaptunnelRelay.Telemetry.emit([:payment, :challenge], %{count: 1}, %{result: :error})
        {:reply, {:error, safe_reason(reason)}, state}
    end
  end

  def handle_call({:authorize_lease, token, node_id}, _from, state) do
    result =
      with {:ok, payload} <- verify(token),
           true <- payload["type"] == "lease",
           true <- payload["node_id"] == node_id,
           :ok <- unexpired(payload["expires_at"]),
           lease_id when is_binary(lease_id) <- payload["lease_id"] do
        {:ok, lease_id}
      else
        _invalid -> {:error, :invalid_lease}
      end

    {:reply, result, state}
  end

  def handle_call({:claim, quote_id, claim_token}, _from, state) do
    result =
      with {:ok, quote} <- fetch_quote(state.quotes, quote_id),
           :ok <- verify_claim_token(claim_token, quote) do
        claim_quote(quote, state)
      end

    case result do
      {:ok, lease, quote} ->
        persist(state.table, quote)
        quotes = Map.put(state.quotes, quote.id, quote)
        ZaptunnelRelay.Telemetry.emit([:payment, :claim], %{count: 1}, %{result: :success})
        {:reply, {:ok, lease}, %{state | quotes: quotes}}

      {:pending, retry_after_ms} ->
        ZaptunnelRelay.Telemetry.emit([:payment, :claim], %{count: 1}, %{result: :pending})
        {:reply, {:pending, retry_after_ms}, state}

      {:error, reason} ->
        ZaptunnelRelay.Telemetry.emit([:payment, :claim], %{count: 1}, %{result: reason})
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_settlement, payment}, _from, state) do
    {result, state} = record_payment(state, payment)
    {:reply, result, state}
  end

  def handle_call(:last_pay_index, _from, state), do: {:reply, state.last_pay_index, state}

  def handle_call(:reset, _from, state) do
    if state.table, do: :dets.delete_all_objects(state.table)

    {:reply, :ok, %{state | quotes: %{}, last_pay_index: 0, watcher_healthy_at: nil}}
  end

  @impl true
  def handle_cast({:watcher_heartbeat, :healthy}, state) do
    {:noreply, %{state | watcher_healthy_at: System.monotonic_time(:millisecond)}}
  end

  def handle_cast({:watcher_heartbeat, :unhealthy}, state) do
    {:noreply, %{state | watcher_healthy_at: nil}}
  end

  defp verify_claim_token(token, %{claim_token_hash: expected}) when is_binary(token) do
    supplied = :crypto.hash(:sha256, token)

    if Plug.Crypto.secure_compare(supplied, expected),
      do: :ok,
      else: {:error, :invalid_claim_token}
  end

  defp verify_claim_token(_token, _quote), do: {:error, :invalid_claim_token}

  defp claim_quote(%{redeemed: lease} = quote, _state) when is_map(lease),
    do: redeem_quote(quote)

  defp claim_quote(%{settled_at: settled_at} = quote, _state) when is_integer(settled_at),
    do: redeem_quote(quote)

  defp claim_quote(quote, state) do
    grace_seconds = div(Application.fetch_env!(:zaptunnel_relay, :payment_claim_grace_ms), 1_000)

    cond do
      System.system_time(:second) <= quote.expires_at + grace_seconds ->
        {:pending, Application.fetch_env!(:zaptunnel_relay, :payment_claim_poll_ms)}

      watcher_healthy?(state) ->
        {:error, :payment_expired}

      true ->
        {:error, :payment_status_unavailable}
    end
  end

  defp watcher_healthy?(%{watcher_healthy_at: nil}), do: false

  defp watcher_healthy?(%{watcher_healthy_at: timestamp}) do
    max_age =
      (Application.fetch_env!(:zaptunnel_relay, :payment_watch_timeout_seconds) + 10) * 1_000

    System.monotonic_time(:millisecond) - timestamp <= max_age
  end

  defp redeem_quote(%{redeemed: lease} = quote) when is_map(lease) do
    if lease.expires_at >= System.system_time(:second),
      do: {:ok, lease, quote},
      else: {:error, :payment_expired}
  end

  defp redeem_quote(quote) do
    lease_id = random_id("zl_")

    expires_at =
      System.system_time(:second) +
        div(Application.fetch_env!(:zaptunnel_relay, :payment_lease_ttl_ms), 1_000)

    token =
      sign(%{
        "expires_at" => expires_at,
        "lease_id" => lease_id,
        "node_id" => quote.node_id,
        "payment_hash" => quote.payment_hash,
        "type" => "lease"
      })

    lease = %{expires_at: expires_at, id: lease_id, token: token}
    {:ok, lease, %{quote | redeemed: lease}}
  end

  defp fetch_quote(quotes, id) do
    case Map.fetch(quotes, id) do
      {:ok, quote} -> {:ok, quote}
      :error -> {:error, :unknown_challenge}
    end
  end

  defp record_payment(state, payment) do
    with %{
           pay_index: pay_index,
           label: label,
           offer_id: offer_id,
           payment_hash: payment_hash,
           amount_received_msat: amount_received_msat,
           paid_at: paid_at
         }
         when is_integer(pay_index) and pay_index > state.last_pay_index and
                is_binary(label) and is_binary(offer_id) and is_binary(payment_hash) and
                is_integer(amount_received_msat) and is_integer(paid_at) <- payment do
      case Map.fetch(state.quotes, label) do
        {:ok, quote} ->
          if valid_settlement?(payment, quote) do
            {:ok, _lease, quote} =
              quote
              |> Map.put(:settled_at, payment.paid_at)
              |> redeem_quote()

            # Persist the paid quote before advancing the cursor. A crash may
            # replay this payment, but it can never skip an unrecorded payment.
            persist(state.table, quote)
            state = advance_cursor(state, pay_index)

            ZaptunnelRelay.Telemetry.emit(
              [:payment, :settlement],
              %{
                count: 1,
                delay_ms: max((System.system_time(:second) - payment.paid_at) * 1_000, 0)
              },
              %{result: :matched}
            )

            {:ok, %{state | quotes: Map.put(state.quotes, quote.id, quote)}}
          else
            ZaptunnelRelay.Telemetry.emit(
              [:payment, :settlement],
              %{count: 1, delay_ms: 0},
              %{result: :invalid}
            )

            {{:error, :invalid_settlement}, advance_cursor(state, pay_index)}
          end

        :error ->
          ZaptunnelRelay.Telemetry.emit(
            [:payment, :settlement],
            %{count: 1, delay_ms: 0},
            %{result: :ignored}
          )

          {:ok, advance_cursor(state, pay_index)}
      end
    else
      _stale_or_invalid -> {{:error, :stale_settlement}, state}
    end
  end

  defp valid_settlement?(payment, quote),
    do:
      payment.offer_id == quote[:offer_id] and
        payment.payment_hash == quote.payment_hash and
        payment.amount_received_msat >= quote.amount_sats * 1_000

  defp advance_cursor(state, pay_index) do
    persist_cursor(state.table, pay_index)
    %{state | last_pay_index: pay_index}
  end

  defp unexpired(expires_at) when is_integer(expires_at) do
    if expires_at >= System.system_time(:second), do: :ok, else: {:error, :payment_expired}
  end

  defp unexpired(_expires_at), do: {:error, :payment_expired}

  defp validate_invoice(%{
         invoice: "lni" <> _invoice,
         payment_hash: hash,
         offer_id: offer_id,
         expires_at: expiry
       })
       when is_binary(hash) and byte_size(hash) == 64 and is_binary(offer_id) and
              byte_size(offer_id) == 64 and is_integer(expiry) do
    with {:ok, decoded_hash} <- Base.decode16(hash, case: :mixed),
         {:ok, decoded_offer_id} <- Base.decode16(offer_id, case: :mixed),
         true <- byte_size(decoded_hash) == 32 and byte_size(decoded_offer_id) == 32 do
      :ok
    else
      _invalid -> {:error, :invalid_invoice_response}
    end
  end

  defp validate_invoice(_invoice), do: {:error, :invalid_invoice_response}

  defp pending_quote_capacity(quotes, source_hash) do
    now = System.system_time(:second)
    grace = div(Application.fetch_env!(:zaptunnel_relay, :payment_claim_grace_ms), 1_000)
    maximum = Application.fetch_env!(:zaptunnel_relay, :payment_max_pending_quotes_per_source)

    pending =
      Enum.count(quotes, fn {_id, quote} ->
        quote[:source_hash] == source_hash and is_nil(quote[:settled_at]) and
          quote.expires_at + grace >= now
      end)

    if pending < maximum, do: :ok, else: {:error, :payment_quote_limit}
  end

  defp sign(payload) do
    encoded = payload |> Jason.encode!() |> Base.url_encode64(padding: false)

    signature =
      :crypto.mac(:hmac, :sha256, token_secret(), encoded) |> Base.url_encode64(padding: false)

    encoded <> "." <> signature
  end

  defp verify(token) do
    with [encoded, supplied] <- String.split(token, ".", parts: 2),
         {:ok, signature} <- Base.url_decode64(supplied, padding: false),
         expected <- :crypto.mac(:hmac, :sha256, token_secret(), encoded),
         true <- byte_size(signature) == byte_size(expected),
         true <- Plug.Crypto.secure_compare(signature, expected),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} <- Jason.decode(json) do
      {:ok, payload}
    else
      _invalid -> {:error, :invalid_payment_token}
    end
  end

  defp prune(quotes) do
    now = System.system_time(:second)

    Enum.reduce(quotes, {%{}, []}, fn {id, quote}, {kept, expired} ->
      lease_expires_at = get_in(quote, [:redeemed, :expires_at])

      retention_seconds =
        div(Application.fetch_env!(:zaptunnel_relay, :payment_quote_retention_ms), 1_000)

      if quote.expires_at + retention_seconds >= now or
           (is_integer(lease_expires_at) and lease_expires_at >= now) do
        {Map.put(kept, id, quote), expired}
      else
        {kept, [id | expired]}
      end
    end)
  end

  defp open_store(nil), do: {nil, %{}, 0}

  defp open_store(path) do
    :ok = File.mkdir_p(Path.dirname(path))
    table = :zaptunnel_payment_quotes
    {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path), type: :set)

    {quotes, last_pay_index} =
      :dets.foldl(
        fn
          {{:meta, :last_pay_index}, value}, {quotes, _cursor} -> {quotes, value}
          {id, quote}, {quotes, cursor} -> {Map.put(quotes, id, quote), cursor}
        end,
        {%{}, 0},
        table
      )

    {table, quotes, last_pay_index}
  end

  defp persist(nil, _quote), do: :ok
  defp persist(table, quote), do: :dets.insert(table, {quote.id, quote})

  defp persist_cursor(nil, _value), do: :ok
  defp persist_cursor(table, value), do: :dets.insert(table, {{:meta, :last_pay_index}, value})

  defp delete_expired(nil, _ids), do: :ok
  defp delete_expired(table, ids), do: Enum.each(ids, &:dets.delete(table, &1))

  defp token_secret, do: Application.fetch_env!(:zaptunnel_relay, :payment_token_secret)
  defp payment_timeout, do: Application.fetch_env!(:zaptunnel_relay, :payment_invoice_timeout_ms)

  defp random_id(prefix),
    do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :billing_unavailable
end
