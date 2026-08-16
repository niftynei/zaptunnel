defmodule ZaptunnelRelay.AdmissionTest do
  use ExUnit.Case, async: false

  alias ZaptunnelRelay.Admission

  @node_id "02" <> String.duplicate("11", 32)
  @address {{127, 0, 0, 1}, 9_735}

  setup do
    Admission.reset()
    :ok
  end

  test "limits a node to three pending or active sessions" do
    assert {:ok, first} = Admission.issue(@node_id, @address)
    assert {:ok, _second} = Admission.issue(@node_id, @address)
    assert {:ok, _third} = Admission.issue(@node_id, @address)
    assert {:error, :connection_limit} = Admission.issue(@node_id, @address)

    owner = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, %{node_id: @node_id, address: @address}} = Admission.claim(first, owner)
    Process.exit(owner, :kill)

    eventually(fn -> match?({:ok, _ticket}, Admission.issue(@node_id, @address)) end)
  end

  test "tickets are single-use" do
    assert {:ok, ticket} = Admission.issue(@node_id, @address)
    assert {:ok, _target} = Admission.claim(ticket)
    assert {:error, :invalid_ticket} = Admission.claim(ticket)
  end

  test "expired tickets release their slot" do
    for _index <- 1..3 do
      assert {:ok, _ticket} = Admission.issue(@node_id, @address)
    end

    assert {:error, :connection_limit} = Admission.issue(@node_id, @address)
    eventually(fn -> match?({:ok, _ticket}, Admission.issue(@node_id, @address)) end)
  end

  test "enforces a relay-wide session ceiling" do
    previous = Application.fetch_env!(:zaptunnel_relay, :max_total_sessions)
    Application.put_env(:zaptunnel_relay, :max_total_sessions, 2)
    on_exit(fn -> Application.put_env(:zaptunnel_relay, :max_total_sessions, previous) end)

    assert {:ok, _ticket} = Admission.issue(@node_id, @address)
    assert {:ok, _ticket} = Admission.issue("03" <> String.duplicate("22", 32), @address)

    assert {:error, :relay_overloaded} =
             Admission.issue("02" <> String.duplicate("33", 32), @address)
  end

  defp eventually(assertion, attempts \\ 20)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(_assertion, 0), do: flunk("condition did not become true")
end
