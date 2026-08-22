defmodule ZaptunnelRelay.Billing.InvoiceProvider do
  @moduledoc false

  @callback create_invoice(keyword()) ::
              {:ok,
               %{
                 invoice: String.t(),
                 payment_hash: String.t(),
                 expires_at: integer(),
                 offer_id: String.t()
               }}
              | {:error, atom()}

  @callback wait_payment(non_neg_integer(), keyword()) ::
              {:ok,
               %{
                 label: String.t(),
                 offer_id: String.t(),
                 payment_hash: String.t(),
                 amount_received_msat: non_neg_integer(),
                 paid_at: integer(),
                 pay_index: pos_integer()
               }}
              | {:error, atom()}

  @optional_callbacks wait_payment: 2
end
