defmodule ZaptunnelRelay.PaymentsTest do
  use ExUnit.Case, async: false

  alias ZaptunnelRelay.{PaymentProtocol, Payments}

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
         invoice: "lnbc10n1testinvoice",
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

  test "offers one invoice through both MPP and L402 adapters" do
    assert {:ok, challenge} = Payments.challenge(@node_id, "relay.zapptunnel.com")
    assert challenge.protocols == ["mpp", "l402"]
    assert challenge.invoice == "lnbc10n1testinvoice"
    assert challenge.payment_hash == @payment_hash
    assert challenge.claim_path == "/v1/payments/#{challenge.quote_id}/claim"
    assert challenge.claim_token =~ ~r/^zc_[A-Za-z0-9_-]{43}$/
    assert ["Payment " <> _, "L402 " <> _] = challenge.www_authenticate
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

  test "MPP tokens use canonical JSON and accept optional base64url padding" do
    assert PaymentProtocol.encode(%{"z" => 1, "a" => 2}) ==
             Base.url_encode64(~s({"a":2,"z":1}), padding: false)

    assert {:ok, challenge} = Payments.challenge(@node_id, "relay.zapptunnel.com")

    credential =
      %{
        "challenge" => challenge.mpp_challenge,
        "payload" => %{"preimage" => @preimage}
      }
      |> PaymentProtocol.encode()
      |> then(&("Payment " <> &1 <> String.duplicate("=", rem(4 - rem(byte_size(&1), 4), 4))))

    assert {:ok, _lease, _receipt} = Payments.redeem(credential, @node_id)
  end

  test "MPP and L402 normalize to the same idempotent paid lease" do
    assert {:ok, challenge} = Payments.challenge(@node_id, "relay.zapptunnel.com")

    mpp =
      "Payment " <>
        PaymentProtocol.encode(%{
          "challenge" => challenge.mpp_challenge,
          "payload" => %{"preimage" => @preimage}
        })

    assert {:ok, first, receipt} = Payments.redeem(mpp, @node_id)
    assert is_binary(receipt)
    assert {:ok, first.id} == Payments.authorize_lease(first.token, @node_id)

    l402 = "L402 #{challenge.l402_token}:#{@preimage}"
    assert {:ok, second, _receipt} = Payments.redeem(l402, @node_id)
    assert second == first
  end

  test "rejects incorrect preimages and cross-node leases" do
    assert {:ok, challenge} = Payments.challenge(@node_id, "relay.zapptunnel.com")
    credential = "L402 #{challenge.l402_token}:#{String.duplicate("00", 32)}"
    assert {:error, :invalid_preimage} = Payments.redeem(credential, @node_id)

    valid = "L402 #{challenge.l402_token}:#{@preimage}"
    assert {:ok, lease, _receipt} = Payments.redeem(valid, @node_id)

    assert {:error, :invalid_lease} =
             Payments.authorize_lease(lease.token, "03" <> String.duplicate("33", 32))
  end
end
