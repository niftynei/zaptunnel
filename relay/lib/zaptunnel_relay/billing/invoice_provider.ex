defmodule ZaptunnelRelay.Billing.InvoiceProvider do
  @moduledoc false

  @callback create_invoice(keyword()) ::
              {:ok, %{invoice: String.t(), payment_hash: String.t(), expires_at: integer()}}
              | {:error, atom()}
end
