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

  @impl true
  def wait_payment(last_pay_index, opts) do
    timeout_seconds = Keyword.fetch!(opts, :timeout_seconds)

    case Commando.call(
           "waitanyinvoice",
           %{lastpay_index: last_pay_index, timeout: timeout_seconds},
           commando_options((timeout_seconds + 5) * 1_000)
         ) do
      {:ok,
       %{
         "label" => label,
         "payment_hash" => payment_hash,
         "amount_received_msat" => amount,
         "paid_at" => paid_at,
         "pay_index" => pay_index,
         "status" => "paid"
       }} ->
        with {:ok, amount_msat} <- parse_msat(amount) do
          {:ok,
           %{
             label: to_string(label),
             payment_hash: String.downcase(payment_hash),
             amount_received_msat: amount_msat,
             paid_at: paid_at,
             pay_index: pay_index
           }}
        end

      {:error, {:commando_rpc_error, 904}} ->
        {:error, :timeout}

      _error ->
        {:error, :billing_unavailable}
    end
  end

  defp commando_options(timeout) do
    [
      address: Application.fetch_env!(:zaptunnel_relay, :billing_node_address),
      node_id: Application.fetch_env!(:zaptunnel_relay, :billing_node_id),
      rune: Application.fetch_env!(:zaptunnel_relay, :billing_node_rune),
      timeout: timeout
    ]
  end

  defp parse_msat(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_msat(%{"msat" => value}) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp parse_msat(value) when is_binary(value) do
    case Integer.parse(String.trim_trailing(value, "msat")) do
      {amount, ""} when amount >= 0 -> {:ok, amount}
      _invalid -> {:error, :invalid_amount}
    end
  end

  defp parse_msat(_value), do: {:error, :invalid_amount}
end
