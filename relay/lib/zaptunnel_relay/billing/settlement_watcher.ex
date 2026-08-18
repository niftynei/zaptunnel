defmodule ZaptunnelRelay.Billing.SettlementWatcher do
  @moduledoc false

  use GenServer
  require Logger

  alias ZaptunnelRelay.Payments

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Payments.enabled?() do
      send(self(), :watch)
      {:ok, %{failures: 0}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:watch, state) do
    provider = Application.fetch_env!(:zaptunnel_relay, :invoice_provider)
    timeout_seconds = Application.fetch_env!(:zaptunnel_relay, :payment_watch_timeout_seconds)

    result =
      if function_exported?(provider, :wait_payment, 2) do
        provider.wait_payment(Payments.last_pay_index(), timeout_seconds: timeout_seconds)
      else
        {:error, :settlement_polling_unsupported}
      end

    case result do
      {:ok, payment} ->
        case Payments.record_settlement(payment) do
          :ok ->
            Payments.watcher_heartbeat(:healthy)
            send(self(), :watch)
            {:noreply, %{state | failures: 0}}

          {:error, reason} ->
            retry(state, {:invalid_settlement, reason})
        end

      {:error, :timeout} ->
        Payments.watcher_heartbeat(:healthy)
        send(self(), :watch)
        {:noreply, %{state | failures: 0}}

      {:error, reason} ->
        retry(state, reason)
    end
  end

  defp retry(state, reason) do
    Payments.watcher_heartbeat(:unhealthy)
    failures = state.failures + 1
    delay = reconnect_delay(failures)

    Logger.warning(
      "billing settlement watcher unavailable reason=#{safe_reason(reason)} retry_ms=#{delay}"
    )

    ZaptunnelRelay.Telemetry.emit([:payment, :watcher], %{count: 1}, %{result: :error})
    Process.send_after(self(), :watch, delay)
    {:noreply, %{state | failures: failures}}
  end

  defp reconnect_delay(failures) do
    base = Application.fetch_env!(:zaptunnel_relay, :payment_watch_retry_ms)
    max_delay = Application.fetch_env!(:zaptunnel_relay, :payment_watch_max_retry_ms)
    min(trunc(base * :math.pow(2, min(failures - 1, 8))), max_delay)
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :billing_unavailable
end
