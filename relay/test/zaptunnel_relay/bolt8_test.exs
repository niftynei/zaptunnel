defmodule ZaptunnelRelay.Bolt8Test do
  use ExUnit.Case, async: true

  alias ZaptunnelRelay.Bolt8

  test "matches the BOLT 8 initiator handshake vector" do
    remote_static = decode("028d7500dd4c12685d1f568b4c2b5048e8534b873319f3a8daa612b469132ec7f7")
    static_private = decode(String.duplicate("11", 32))
    ephemeral_private = decode(String.duplicate("12", 32))

    expected_act1 =
      decode(
        "00036360e856310ce5d294e8be33fc807077dc56ac80d95d9cd4ddbd21325eff73f7" <>
          "0df6086551151f58b8afe6c195782c6a"
      )

    act2 =
      decode(
        "0002466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27" <>
          "6e2470b93aac583c9ef6eafca3f730ae"
      )

    expected_act3 =
      decode(
        "00b9e3a702e93e3a9948c2ed6e5fd7590a6e1c3a0344cfc9d5b57357049aa223553" <>
          "61aa02e55a8fc28fef5bd6d71ad0c38228dc68b1c466263b47fdf31e560e139ba"
      )

    assert {:ok, ^expected_act1, state} =
             Bolt8.initiate(remote_static, static_private, ephemeral_private)

    assert {:ok, ^expected_act3, transport} = Bolt8.finish_act2(state, act2)

    assert transport.send_key ==
             decode("969ab31b4d288cedf6218839b27a3e2140827047f2c0f01bf5c04435d43511a9")

    assert transport.receive_key ==
             decode("bb9020b8965f4df047e07f955f3c4b88418984aadc5cdb35096b9ea8fa5c3442")
  end

  test "rejects the wrong handshake version and a bad authenticator" do
    remote_static = decode("028d7500dd4c12685d1f568b4c2b5048e8534b873319f3a8daa612b469132ec7f7")
    static_private = decode(String.duplicate("11", 32))
    ephemeral_private = decode(String.duplicate("12", 32))

    {:ok, _act1, state} = Bolt8.initiate(remote_static, static_private, ephemeral_private)

    assert {:error, :unsupported_version} = Bolt8.finish_act2(state, <<1, 0::392>>)

    bad_act2 =
      decode(
        "0002466d7fcae563e5cb09a0d1870bb580344804617879a14949cf22285f1bae3f27" <>
          "6e2470b93aac583c9ef6eafca3f730af"
      )

    assert {:error, :authentication_failed} = Bolt8.finish_act2(state, bad_act2)
  end

  test "validates compressed public keys as curve points" do
    assert Bolt8.valid_public_key?(
             decode("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
           )

    refute Bolt8.valid_public_key?(decode("02" <> String.duplicate("ff", 32)))
  end

  defp decode(hex), do: Base.decode16!(hex, case: :mixed)
end
