defmodule ZaptunnelRelay.PaymentsTest do
  use ExUnit.Case, async: false

  alias ZaptunnelRelay.Payments

  @preimage String.duplicate("11", 32)
  @payment_hash :crypto.hash(:sha256, Base.decode16!(@preimage, case: :lower))
                |> Base.encode16(case: :lower)
  @node_id "02" <> String.duplicate("22", 32)

  defmodule InvoiceProvider do
    @behaviour ZaptunnelRelay.Billing.InvoiceProvider

    def create_invoice(opts) do
      send(Application.fetch_env!(:zaptunnel_relay, :payments_test_pid), {:invoice, opts})

      {:ok,
       %{
         expires_at: System.system_time(:second) + 300,
         invoice: "lni1testinvoice",
         offer_id: String.duplicate("aa", 32),
         payment_hash: Application.fetch_env!(:zaptunnel_relay, :payments_test_hash)
       }}
    end
  end

  setup do
    previous =
      for key <- [:invoice_provider, :payments_enabled, :payment_token_secret], into: %{} do
        {key, Application.fetch_env!(:zaptunnel_relay, key)}
      end

    Application.put_env(:zaptunnel_relay, :invoice_provider, InvoiceProvider)
    Application.put_env(:zaptunnel_relay, :payments_enabled, true)
    Application.put_env(:zaptunnel_relay, :payment_token_secret, String.duplicate("s", 32))
    Application.put_env(:zaptunnel_relay, :payments_test_pid, self())
    Application.put_env(:zaptunnel_relay, :payments_test_hash, @payment_hash)
    Payments.reset()

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:zaptunnel_relay, key, value) end)

      Application.delete_env(:zaptunnel_relay, :payments_test_pid)
      Application.delete_env(:zaptunnel_relay, :payments_test_hash)
    end)

    :ok
  end

  test "offers a BOLT12 invoice with a protected settlement claim" do
    assert {:ok, challenge} = Payments.challenge(@node_id, "relay.zapptunnel.com")
    assert challenge.protocol == "bolt12"
    assert challenge.invoice == "lni1testinvoice"
    assert challenge.payment_hash == @payment_hash
    assert challenge.claim_path == "/v1/payments/#{challenge.quote_id}/claim"
    assert challenge.claim_token =~ ~r/^zc_[A-Za-z0-9_-]{43}$/
    refute Map.has_key?(challenge, :www_authenticate)
    assert_receive {:invoice, opts}
    assert opts[:amount_sats] == 10
  end

  test "a hashed claim token receives the same lease after observed settlement" do
    assert {:ok, challenge} = Payments.challenge(@node_id, "relay.zapptunnel.com")
    assert {:pending, 2_000} = Payments.claim(challenge.quote_id, challenge.claim_token)
    assert {:error, :invalid_claim_token} = Payments.claim(challenge.quote_id, "wrong-token")

    assert :ok =
             Payments.record_settlement(%{
               label: challenge.quote_id,
               offer_id: String.duplicate("aa", 32),
               payment_hash: @payment_hash,
               amount_received_msat: 10_000,
               paid_at: System.system_time(:second),
               pay_index: 7
             })

    assert Payments.last_pay_index() == 7
    assert {:ok, first} = Payments.claim(challenge.quote_id, challenge.claim_token)
    assert {:ok, second} = Payments.claim(challenge.quote_id, challenge.claim_token)
    assert first == second
    assert {:ok, first.id} == Payments.authorize_lease(first.token, @node_id)
  end

  test "settlement cursor advances while invalid payments cannot issue a lease" do
    assert {:ok, challenge} = Payments.challenge(@node_id, "relay.zapptunnel.com")

    assert {:error, :invalid_settlement} =
             Payments.record_settlement(%{
               label: challenge.quote_id,
               offer_id: String.duplicate("aa", 32),
               payment_hash: String.duplicate("00", 32),
               amount_received_msat: 10_000,
               paid_at: System.system_time(:second),
               pay_index: 8
             })

    assert Payments.last_pay_index() == 8
    assert {:pending, _retry} = Payments.claim(challenge.quote_id, challenge.claim_token)
  end

  test "malformed settlement events do not advance the durable cursor" do
    assert {:error, :stale_settlement} =
             Payments.record_settlement(%{pay_index: 9, label: "missing-payment-fields"})

    assert Payments.last_pay_index() == 0
  end

  test "bounds unpaid quotes per hashed source before creating another invoice" do
    previous =
      Application.fetch_env!(:zaptunnel_relay, :payment_max_pending_quotes_per_source)

    Application.put_env(:zaptunnel_relay, :payment_max_pending_quotes_per_source, 1)

    on_exit(fn ->
      Application.put_env(
        :zaptunnel_relay,
        :payment_max_pending_quotes_per_source,
        previous
      )
    end)

    source = {192, 0, 2, 10}
    assert {:ok, _challenge} = Payments.challenge(@node_id, "relay.zapptunnel.com", source)
    assert_receive {:invoice, _opts}

    assert {:error, :payment_quote_limit} =
             Payments.challenge(@node_id, "relay.zapptunnel.com", source)

    refute_receive {:invoice, _opts}
  end

  test "a settled quote produces one idempotent node-bound lease" do
    assert {:ok, challenge} = Payments.challenge(@node_id, "relay.zapptunnel.com")

    assert :ok =
             Payments.record_settlement(%{
               label: challenge.quote_id,
               offer_id: String.duplicate("aa", 32),
               payment_hash: @payment_hash,
               amount_received_msat: 10_000,
               paid_at: System.system_time(:second),
               pay_index: 10
             })

    assert {:ok, first} = Payments.claim(challenge.quote_id, challenge.claim_token)
    assert {:ok, second} = Payments.claim(challenge.quote_id, challenge.claim_token)
    assert second == first
    assert {:ok, first.id} == Payments.authorize_lease(first.token, @node_id)

    assert {:error, :invalid_lease} =
             Payments.authorize_lease(first.token, "03" <> String.duplicate("33", 32))
  end
end
