defmodule ZaptunnelRelay.PaymentProtocol do
  @moduledoc false

  def mpp_challenge(quote, realm) do
    request =
      encode(%{
        "amount" => Integer.to_string(quote.amount_sats),
        "currency" => "sat",
        "description" => quote.description,
        "externalId" => quote.id,
        "methodDetails" => %{
          "invoice" => quote.invoice,
          "network" => quote.network,
          "paymentHash" => quote.payment_hash
        }
      })

    challenge = %{
      "expires" => DateTime.from_unix!(quote.expires_at) |> DateTime.to_iso8601(),
      "id" => quote.id,
      "intent" => "charge",
      "method" => "lightning",
      "realm" => realm,
      "request" => request
    }

    header =
      "Payment " <>
        Enum.map_join(["id", "realm", "method", "intent", "request", "expires"], ", ", fn key ->
          ~s(#{key}="#{challenge[key]}")
        end)

    {header, challenge}
  end

  def l402_challenge(quote, token) do
    ~s(L402 macaroon="#{token}", invoice="#{quote.invoice}")
  end

  def parse_credential("Payment " <> encoded) do
    with {:ok, decoded} <- decode_base64url(encoded),
         {:ok,
          %{"challenge" => %{"id" => id} = challenge, "payload" => %{"preimage" => preimage}}} <-
           Jason.decode(decoded) do
      {:ok, %{protocol: :mpp, quote_id: id, challenge: challenge, preimage: preimage}}
    else
      _error -> {:error, :malformed_payment_credential}
    end
  end

  def parse_credential("L402 " <> credential) do
    case String.split(credential, ":", parts: 2) do
      [token, preimage] -> {:ok, %{protocol: :l402, token: token, preimage: preimage}}
      _invalid -> {:error, :malformed_payment_credential}
    end
  end

  def parse_credential(_credential), do: {:error, :unsupported_payment_credential}

  def receipt(quote) do
    encode(%{
      "challengeId" => quote.id,
      "method" => "lightning",
      "reference" => quote.payment_hash,
      "status" => "success",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  def encode(value), do: value |> canonical_json() |> Base.url_encode64(padding: false)

  defp decode_base64url(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      :error -> Base.url_decode64(encoded, padding: true)
      result -> result
    end
  end

  # MPP requires RFC 8785/JCS ordering. Protocol objects contain only JSON
  # primitives, arrays, and string-keyed maps, so this is the complete subset
  # needed here without bringing a second JSON implementation into the relay.
  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, item} -> Jason.encode!(key) <> ":" <> canonical_json(item) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)
end
