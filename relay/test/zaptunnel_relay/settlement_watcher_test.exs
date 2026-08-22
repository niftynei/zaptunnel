defmodule ZaptunnelRelay.SettlementWatcherTest do
  use ExUnit.Case, async: false

  alias ZaptunnelRelay.Billing.SettlementWatcher
  alias ZaptunnelRelay.Payments

  @node_id "02" <> String.duplicate("44", 32)
  @payment_hash String.duplicate("55", 32)

  defmodule Provider do
    @behaviour ZaptunnelRelay.Billing.InvoiceProvider

    def create_invoice(opts) do
      {:ok,
       %{
         invoice: "lni1watcher",
         offer_id: String.duplicate("aa", 32),
         payment_hash: ZaptunnelRelay.SettlementWatcherTest.payment_hash(),
         expires_at: System.system_time(:second) + Keyword.fetch!(opts, :expiry_seconds)
       }}
    end

    def wait_payment(_last_pay_index, _opts) do
      case Agent.get_and_update(__MODULE__, fn
             [result | rest] -> {result, rest}
             [] -> {{:error, :empty}, []}
           end) do
        {:error, :empty} ->
          Process.sleep(20)
          {:error, :timeout}

        result ->
          result
      end
    end
  end

  def payment_hash, do: @payment_hash

  setup do
    previous =
      for key <- [
            :invoice_provider,
            :payments_enabled,
            :payment_token_secret,
            :payment_watch_timeout_seconds
          ],
          into: %{} do
        {key, Application.fetch_env!(:zaptunnel_relay, key)}
      end

    Application.put_env(:zaptunnel_relay, :invoice_provider, Provider)
    Application.put_env(:zaptunnel_relay, :payments_enabled, true)
    Application.put_env(:zaptunnel_relay, :payment_token_secret, String.duplicate("w", 32))
    Application.put_env(:zaptunnel_relay, :payment_watch_timeout_seconds, 1)
    Payments.reset()

    start_supervised!(%{
      id: Provider,
      start: {Agent, :start_link, [fn -> [] end, [name: Provider]]}
    })

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:zaptunnel_relay, key, value) end)
    end)

    :ok
  end

  test "one cursor-based watcher records CLN settlement for a protected claim" do
    assert {:ok, challenge} = Payments.challenge(@node_id, "relay.zapptunnel.com")

    Agent.update(Provider, fn _queue ->
      [
        {:ok,
         %{
           label: challenge.quote_id,
           offer_id: String.duplicate("aa", 32),
           payment_hash: @payment_hash,
           amount_received_msat: 10_000,
           paid_at: System.system_time(:second),
           pay_index: 12
         }}
      ]
    end)

    start_supervised!(SettlementWatcher)

    assert {:ok, lease} =
             eventually(fn -> Payments.claim(challenge.quote_id, challenge.claim_token) end)

    assert Payments.last_pay_index() == 12
    assert {:ok, lease.id} == Payments.authorize_lease(lease.token, @node_id)
  end

  defp eventually(assertion, attempts \\ 50)

  defp eventually(assertion, attempts) when attempts > 0 do
    case assertion.() do
      {:pending, _retry} ->
        Process.sleep(10)
        eventually(assertion, attempts - 1)

      result ->
        result
    end
  end

  defp eventually(_assertion, 0), do: flunk("settlement watcher did not observe payment")
end
