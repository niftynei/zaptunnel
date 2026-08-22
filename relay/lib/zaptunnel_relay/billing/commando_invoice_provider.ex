defmodule ZaptunnelRelay.Billing.CommandoInvoiceProvider do
  @moduledoc false
  @behaviour ZaptunnelRelay.Billing.InvoiceProvider

  alias ZaptunnelRelay.Billing.Commando

  @impl true
  def create_invoice(opts) do
    quote_id = Keyword.fetch!(opts, :label)
    expected_offer = Application.fetch_env!(:zaptunnel_relay, :payment_offer)
    expected_offer_id = Application.fetch_env!(:zaptunnel_relay, :payment_offer_id)
    expected_amount_msat = Keyword.fetch!(opts, :amount_sats) * 1_000

    with {:ok, %{"invoice" => invoice, "changes" => changes}} <-
           Commando.call(
             "fetchinvoice",
             %{offer: expected_offer, payer_note: quote_id, timeout: 10},
             commando_options(
               :billing_fetch_rune,
               Application.fetch_env!(:zaptunnel_relay, :payment_invoice_timeout_ms)
             )
           ),
         true <- is_binary(invoice) and String.starts_with?(invoice, "lni") and changes == %{},
         {:ok, decoded} <-
           Commando.call(
             "decode",
             %{string: invoice},
             commando_options(:billing_decode_rune, 5_000)
           ),
         %{
           "type" => "bolt12 invoice",
           "valid" => true,
           "offer_id" => ^expected_offer_id,
           "invreq_payer_note" => ^quote_id,
           "invoice_payment_hash" => payment_hash,
           "invoice_amount_msat" => amount,
           "invoice_created_at" => created_at,
           "invoice_relative_expiry" => relative_expiry
         } <- decoded,
         {:ok, ^expected_amount_msat} <- parse_msat(amount),
         true <- is_binary(payment_hash) and byte_size(payment_hash) == 64,
         true <- is_integer(created_at) and is_integer(relative_expiry) do
      {:ok,
       %{
         invoice: invoice,
         payment_hash: String.downcase(payment_hash),
         expires_at: created_at + relative_expiry,
         offer_id: expected_offer_id
       }}
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
           commando_options(:billing_wait_rune, (timeout_seconds + 5) * 1_000)
         ) do
      {:ok,
       %{
         "label" => label,
         "payment_hash" => payment_hash,
         "amount_received_msat" => amount,
         "paid_at" => paid_at,
         "pay_index" => pay_index,
         "status" => "paid"
       } = payment} ->
        with {:ok, amount_msat} <- parse_msat(amount) do
          {:ok,
           %{
             label: to_string(payment["invreq_payer_note"] || label),
             offer_id: payment["local_offer_id"] || "",
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

  defp commando_options(rune_key, timeout) do
    [
      address: Application.fetch_env!(:zaptunnel_relay, :billing_node_address),
      node_id: Application.fetch_env!(:zaptunnel_relay, :billing_node_id),
      rune: Application.fetch_env!(:zaptunnel_relay, rune_key),
      static_private: billing_private_key(),
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

  defp billing_private_key do
    Application.fetch_env!(:zaptunnel_relay, :billing_commando_private_key)
    |> Base.decode16!(case: :mixed)
  end
end
