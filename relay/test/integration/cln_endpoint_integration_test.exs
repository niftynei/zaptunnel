defmodule ZaptunnelRelay.ClnEndpointIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ZaptunnelRelay.{Admission, EndpointProbe, EndpointVerifier, RateLimiter, Router}

  @wrong_node_id "028d7500dd4c12685d1f568b4c2b5048e8534b873319f3a8daa612b469132ec7f7"

  test "a real CLN peer accepts its node ID and rejects another" do
    %{node_id: node_id, address: address} = start_cln()

    assert :ok = EndpointProbe.verify(node_id, address, timeout: 5_000)

    assert {:error, :endpoint_unverified} =
             EndpointProbe.verify(@wrong_node_id, address, timeout: 2_000)
  end

  test "the packaged SDK connects through the relay and executes Commando getinfo" do
    %{node_id: node_id, address: {{127, 0, 0, 1}, lightning_port}, lightning_dir: lightning_dir} =
      start_cln()

    %{"rune" => rune} =
      command!("lightning-cli", lightning_cli_args(lightning_dir) ++ ["createrune"])
      |> Jason.decode!()

    previous_private = Application.fetch_env!(:zaptunnel_relay, :allow_private_addresses)
    Application.put_env(:zaptunnel_relay, :allow_private_addresses, true)
    Admission.reset()
    EndpointVerifier.reset()
    RateLimiter.reset()

    {:ok, relay} =
      Bandit.start_link(plug: Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

    Process.unlink(relay)

    on_exit(fn ->
      if Process.alive?(relay), do: Process.exit(relay, :shutdown)
      Application.put_env(:zaptunnel_relay, :allow_private_addresses, previous_private)
    end)

    {:ok, {{127, 0, 0, 1}, relay_port}} = ThousandIsland.listener_info(relay)
    script = sdk_e2e_script()

    unless System.get_env("ZAPTUNNEL_SDK_E2E_SCRIPT") do
      sdk_dir = Path.expand("../../../sdk", __DIR__)
      assert {:ok, _output} = command("pnpm", ["--dir", sdk_dir, "build"])
    end

    assert {:ok, output} =
             command("node", [
               script,
               "http://127.0.0.1:#{relay_port}",
               node_id,
               "127.0.0.1:#{lightning_port}",
               rune
             ])

    assert %{"nodeId" => ^node_id, "browserPeerId" => browser_peer_id} =
             output |> String.trim() |> Jason.decode!()

    assert String.match?(browser_peer_id, ~r/^(02|03)[0-9a-f]{64}$/)
  end

  defp start_cln do
    root = Path.join(System.tmp_dir!(), "zaptunnel-cln-#{System.unique_integer([:positive])}")
    bitcoin_dir = Path.join(root, "bitcoin")
    lightning_dir = Path.join(root, "lightning")
    File.mkdir_p!(bitcoin_dir)
    File.mkdir_p!(lightning_dir)

    [rpc_port, bitcoin_port, lightning_port] = free_ports(3)

    start_bitcoind(bitcoin_dir, rpc_port, bitcoin_port)

    on_exit(fn ->
      command("bitcoin-cli", bitcoin_cli_args(bitcoin_dir, rpc_port) ++ ["stop"],
        allow_failure: true
      )

      File.rm_rf(root)
    end)

    eventually(fn ->
      successful?("bitcoin-cli", bitcoin_cli_args(bitcoin_dir, rpc_port) ++ ["getblockchaininfo"])
    end)

    lightning_process = start_lightningd(lightning_dir, rpc_port, lightning_port)

    on_exit(fn ->
      command("lightning-cli", lightning_cli_args(lightning_dir) ++ ["stop"], allow_failure: true)
      if Port.info(lightning_process), do: Port.close(lightning_process)
    end)

    info =
      eventually(fn ->
        case command("lightning-cli", lightning_cli_args(lightning_dir) ++ ["getinfo"],
               allow_failure: true
             ) do
          {:ok, output} -> Jason.decode!(output)
          {:error, _output} -> false
        end
      end)

    node_id = info["id"]
    address = {{127, 0, 0, 1}, lightning_port}

    %{node_id: node_id, address: address, lightning_dir: lightning_dir}
  end

  defp sdk_e2e_script do
    System.get_env("ZAPTUNNEL_SDK_E2E_SCRIPT") ||
      Path.expand("../../../sdk/scripts/e2e.mjs", __DIR__)
  end

  defp start_bitcoind(directory, rpc_port, bitcoin_port) do
    args = [
      "-regtest",
      "-datadir=#{directory}",
      "-daemon",
      "-server",
      "-rpcuser=zaptunnel",
      "-rpcpassword=zaptunnel",
      "-rpcbind=127.0.0.1",
      "-rpcallowip=127.0.0.1",
      "-rpcport=#{rpc_port}",
      "-port=#{bitcoin_port}",
      "-fallbackfee=0.0002"
    ]

    assert {:ok, _output} = command("bitcoind", args)
  end

  defp start_lightningd(directory, rpc_port, lightning_port) do
    args = [
      "--network=regtest",
      "--lightning-dir=#{directory}",
      "--bitcoin-rpcuser=zaptunnel",
      "--bitcoin-rpcpassword=zaptunnel",
      "--bitcoin-rpcconnect=127.0.0.1",
      "--bitcoin-rpcport=#{rpc_port}",
      "--bind-addr=127.0.0.1:#{lightning_port}",
      "--autolisten=false",
      "--disable-plugin=recover",
      "--disable-plugin=spenderp",
      "--disable-plugin=sql",
      "--log-file=#{Path.join(directory, "lightning.log")}"
    ]

    executable = System.find_executable("lightningd") || flunk("lightningd is not on PATH")

    Port.open({:spawn_executable, executable}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args
    ])
  end

  defp bitcoin_cli_args(directory, rpc_port) do
    [
      "-regtest",
      "-datadir=#{directory}",
      "-rpcuser=zaptunnel",
      "-rpcpassword=zaptunnel",
      "-rpcconnect=127.0.0.1",
      "-rpcport=#{rpc_port}",
      "-rpcclienttimeout=1"
    ]
  end

  defp lightning_cli_args(directory), do: ["--network=regtest", "--lightning-dir=#{directory}"]

  defp command(executable, args, opts \\ []) do
    {output, status} = System.cmd(executable, args, stderr_to_stdout: true)

    cond do
      status == 0 -> {:ok, output}
      opts[:allow_failure] -> {:error, output}
      true -> flunk("#{executable} failed:\n#{output}")
    end
  end

  defp command!(executable, args) do
    case command(executable, args) do
      {:ok, output} -> output
      {:error, output} -> flunk("#{executable} failed:\n#{output}")
    end
  end

  defp successful?(executable, args) do
    match?({:ok, _output}, command(executable, args, allow_failure: true))
  end

  defp eventually(assertion, attempts \\ 100)

  defp eventually(assertion, attempts) when attempts > 0 do
    case assertion.() do
      false ->
        Process.sleep(50)
        eventually(assertion, attempts - 1)

      result ->
        result
    end
  end

  defp eventually(_assertion, 0), do: flunk("service did not become ready")

  defp free_ports(count), do: free_ports(count, MapSet.new())

  defp free_ports(0, ports), do: MapSet.to_list(ports)

  defp free_ports(count, ports) do
    port = free_port()

    if MapSet.member?(ports, port) do
      free_ports(count, ports)
    else
      free_ports(count - 1, MapSet.put(ports, port))
    end
  end

  defp free_port do
    candidate = 18_000 + rem(System.unique_integer([:positive]), 10_000)

    case :gen_tcp.listen(candidate, [:binary, active: false]) do
      {:ok, listener} ->
        :gen_tcp.close(listener)
        candidate

      {:error, :eaddrinuse} ->
        free_port()
    end
  end
end
