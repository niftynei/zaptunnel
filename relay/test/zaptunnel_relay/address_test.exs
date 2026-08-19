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
          "192.31.196.1:9735",
          "192.52.193.1:9735",
          "192.175.48.1:9735",
          "198.18.0.1:9735",
          "198.51.100.1:9735",
          "203.0.113.1:9735",
          "[::]:9735",
          "[::ffff:127.0.0.1]:9735",
          "[64:ff9b::1]:9735",
          "[2001:db8::1]:9735",
          "[2002::1]:9735",
          "[3ffe::1]:9735",
          "[3fff::1]:9735",
          "[5f00::1]:9735",
          "[fec0::1]:9735",
          "[2620:4f:8000::1]:9735"
        ] do
      assert {:ok, parsed} = Address.parse(address)
      assert {:error, :non_public_address} = Address.resolve(parsed)
    end
  end

  test "does not over-block the public neighbor of the AS112 range" do
    assert {:ok, parsed} = Address.parse("[2620:4f:8001::1]:9735")
    assert {:ok, {_ip, 9_735}} = Address.resolve(parsed)
  end

  test "does not over-block neighboring public IPv4 ranges" do
    for address <- ["192.31.195.1:9735", "192.52.192.1:9735", "198.51.99.1:9735"] do
      assert {:ok, parsed} = Address.parse(address)
      assert {:ok, {_ip, 9_735}} = Address.resolve(parsed)
    end
  end

  test "validates the single DNS answer once and returns a pinned IP" do
    test_pid = self()

    resolver = fn host ->
      send(test_pid, {:resolved, host})
      {:ok, {93, 184, 216, 34}}
    end

    assert {:ok, parsed} = Address.parse("node.example:9735")

    assert {:ok, {{93, 184, 216, 34}, 9_735}} =
             Address.resolve(parsed, resolver: resolver)

    assert_receive {:resolved, "node.example"}
    refute_receive {:resolved, _host}
  end

  test "rejects a private DNS answer after resolution" do
    assert {:ok, parsed} = Address.parse("attacker.example:9735")

    assert {:error, :non_public_address} =
             Address.resolve(parsed, resolver: fn _host -> {:ok, {127, 0, 0, 1}} end)
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
