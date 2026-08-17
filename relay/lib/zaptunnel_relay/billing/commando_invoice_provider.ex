defmodule ZaptunnelRelay.Billing.CommandoInvoiceProvider do
  @moduledoc false
  @behaviour ZaptunnelRelay.Billing.InvoiceProvider

  alias ZaptunnelRelay.Billing.Commando

  @impl true
  def create_invoice(opts) do
    amount_msat = Keyword.fetch!(opts, :amount_sats) * 1_000

    params = %{
      amount_msat: amount_msat,
      description: Keyword.fetch!(opts, :description),
      expiry: Keyword.fetch!(opts, :expiry_seconds),
      label: Keyword.fetch!(opts, :label)
    }

    with {:ok, result} <-
           Commando.call("invoice", params,
             address: Application.fetch_env!(:zaptunnel_relay, :billing_node_address),
             node_id: Application.fetch_env!(:zaptunnel_relay, :billing_node_id),
             rune: Application.fetch_env!(:zaptunnel_relay, :billing_node_rune),
             timeout: Application.fetch_env!(:zaptunnel_relay, :payment_invoice_timeout_ms)
           ),
         %{"bolt11" => invoice, "payment_hash" => payment_hash, "expires_at" => expires_at} <-
           result do
      {:ok, %{invoice: invoice, payment_hash: payment_hash, expires_at: expires_at}}
    else
      _error -> {:error, :billing_unavailable}
    end
  end
end
