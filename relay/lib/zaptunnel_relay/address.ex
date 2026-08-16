defmodule ZaptunnelRelay.Address do
  @moduledoc false

  @type parsed :: %{host: String.t(), port: :inet.port_number()}

  @spec parse(String.t()) :: {:ok, parsed()} | {:error, :invalid_address}
  def parse(address) when is_binary(address) do
    case URI.new("tcp://" <> address) do
      {:ok, %URI{host: host, port: port, path: path}}
      when is_binary(host) and is_integer(port) and port in 1..65_535 and path in [nil, ""] ->
        {:ok, %{host: host, port: port}}

      _other ->
        {:error, :invalid_address}
    end
  end

  def parse(_address), do: {:error, :invalid_address}

  @spec resolve(parsed(), keyword()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, atom()}
  def resolve(%{host: host, port: port}, opts \\ []) do
    allow_private? = Keyword.get(opts, :allow_private?, false)

    with {:ok, ip} <- resolve_host(host),
         true <- allow_private? or public?(ip) do
      {:ok, {ip, port}}
    else
      false -> {:error, :non_public_address}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_host(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} -> {:ok, ip}
      {:error, :einval} -> resolve_dns(charlist)
    end
  end

  defp resolve_dns(host) do
    task =
      Task.async(fn ->
        case :inet.getaddr(host, :inet6) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(host, :inet)
        end
      end)

    case Task.yield(task, dns_timeout()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :dns_timeout}
    end
  end

  # This deliberately defaults closed. More complete special-purpose ranges
  # will be covered before public deployment.
  defp public?({10, _, _, _}), do: false
  defp public?({127, _, _, _}), do: false
  defp public?({169, 254, _, _}), do: false
  defp public?({172, second, _, _}) when second in 16..31, do: false
  defp public?({100, second, _, _}) when second in 64..127, do: false
  defp public?({192, 168, _, _}), do: false
  defp public?({192, 0, 0, _}), do: false
  defp public?({192, 0, 2, _}), do: false
  defp public?({192, 88, 99, _}), do: false
  defp public?({198, second, _, _}) when second in [18, 19, 51], do: false
  defp public?({203, 0, 113, _}), do: false
  defp public?({0, _, _, _}), do: false
  defp public?({first, _, _, _}) when first >= 224, do: false
  defp public?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public?({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: false
  defp public?({0x64, 0xFF9B, 1, _, _, _, _, _}), do: false
  defp public?({0x100, 0, 0, 0, _, _, _, _}), do: false
  defp public?({0x2001, second, _, _, _, _, _, _}) when second <= 0x01FF, do: false
  defp public?({0x2001, 0xDB8, _, _, _, _, _, _}), do: false
  defp public?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: false
  defp public?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: false
  defp public?({first, _, _, _, _, _, _, _}) when first in 0xFF00..0xFFFF, do: false
  defp public?({_a, _b, _c, _d}), do: true
  defp public?({_a, _b, _c, _d, _e, _f, _g, _h}), do: true

  defp dns_timeout do
    Application.fetch_env!(:zaptunnel_relay, :dns_timeout_ms)
  end
end
