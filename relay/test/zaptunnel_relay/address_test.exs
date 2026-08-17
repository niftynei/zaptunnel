defmodule ZaptunnelRelay.AddressTest do
  use ExUnit.Case, async: true

  alias ZaptunnelRelay.Address

  test "parses host and port" do
    assert {:ok, %{host: "node.example.com", port: 9_735}} =
             Address.parse("node.example.com:9735")
  end

  test "rejects missing and invalid ports" do
    assert {:error, :invalid_address} = Address.parse("node.example.com")
    assert {:error, :invalid_address} = Address.parse("node.example.com:0")
  end

  test "rejects private destinations by default" do
    assert {:ok, parsed} = Address.parse("127.0.0.1:9735")
    assert {:error, :non_public_address} = Address.resolve(parsed)
    assert {:ok, {{127, 0, 0, 1}, 9_735}} = Address.resolve(parsed, allow_private?: true)
  end

  test "rejects shared, documentation, benchmarking, and mapped address ranges" do
    for address <- [
          "100.64.0.1:9735",
          "192.0.2.1:9735",
          "198.18.0.1:9735",
          "198.51.100.1:9735",
          "203.0.113.1:9735",
          "[::ffff:127.0.0.1]:9735",
          "[2001:db8::1]:9735"
        ] do
      assert {:ok, parsed} = Address.parse(address)
      assert {:error, :non_public_address} = Address.resolve(parsed)
    end
  end

  test "recognizes v3 onion services without using DNS" do
    onion = "duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion"
    assert {:ok, parsed} = Address.parse("#{String.upcase(onion)}:9735")
    assert {:error, :onion_unavailable} = Address.resolve(parsed)

    assert {:ok, {:onion, ^onion, 9_735}} =
             Address.resolve(parsed, allow_onion?: true)
  end

  test "rejects legacy and malformed onion names without resolving them" do
    for host <- [
          String.duplicate("a", 16) <> ".onion",
          String.duplicate("a", 56) <> ".onion",
          "bad!.onion",
          "sub.example.onion."
        ] do
      assert {:ok, parsed} = Address.parse("#{host}:9735")
      assert {:error, :invalid_onion_address} = Address.resolve(parsed, allow_onion?: true)
    end
  end
end
