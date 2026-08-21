defmodule ZaptunnelRelay.Admission do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def issue(node_id, address, opts \\ []) do
    GenServer.call(
      __MODULE__,
      {:issue, node_id, address, Keyword.get(opts, :request_id), Keyword.get(opts, :paid_lease),
       Keyword.get(opts, :source)}
    )
  end

  def claim(ticket, owner \\ self()) do
    GenServer.call(__MODULE__, {:claim, ticket, owner})
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  def begin_drain do
    GenServer.call(__MODULE__, :begin_drain)
  end

  def ready? do
    GenServer.call(__MODULE__, :ready?)
  end

  def check_ready do
    GenServer.call(__MODULE__, :check_ready)
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       tickets: %{},
       active: %{},
       counts: %{},
       pending_counts: %{},
       pending_sources: %{},
       paid_leases: MapSet.new(),
       total: 0,
       draining: false
     }}
  end

  @impl true
  def handle_call({:issue, node_id, address, request_id, paid_lease, source}, _from, state) do
    state =
      if state.draining,
        do: state,
        else: replace_pending_retry(state, node_id, paid_lease, source)

    cond do
      state.draining ->
        {:reply, {:error, :relay_draining}, state}

      state.total >= Application.fetch_env!(:zaptunnel_relay, :max_total_sessions) ->
        {:reply, {:error, :relay_overloaded}, state}

      map_size(state.tickets) >=
          Application.fetch_env!(:zaptunnel_relay, :max_pending_sessions) ->
        {:reply, {:error, :relay_overloaded}, state}

      is_binary(paid_lease) and MapSet.member?(state.paid_leases, paid_lease) ->
        {:reply, {:error, :lease_in_use}, state}

      is_nil(paid_lease) and
          Map.get(state.counts, node_id, 0) >=
            Application.fetch_env!(:zaptunnel_relay, :free_sessions_per_node) ->
        {:reply, {:error, :connection_limit}, state}

      is_nil(paid_lease) and
          Map.get(state.pending_counts, node_id, 0) >=
            Application.fetch_env!(:zaptunnel_relay, :max_pending_sessions_per_node) ->
        {:reply, {:error, :pending_limit}, state}

      true ->
        ticket = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
        ttl = Application.fetch_env!(:zaptunnel_relay, :ticket_ttl_ms)
        timer = Process.send_after(self(), {:expire, ticket}, ttl)

        entry = %{
          node_id: node_id,
          address: address,
          request_id: request_id,
          paid_lease: paid_lease,
          source_key: pending_source_key(node_id, paid_lease, source),
          timer: timer
        }

        state = %{
          state
          | tickets: Map.put(state.tickets, ticket, entry),
            counts: Map.update(state.counts, node_id, 1, &(&1 + 1)),
            pending_counts: Map.update(state.pending_counts, node_id, 1, &(&1 + 1)),
            pending_sources: add_pending_source(state.pending_sources, entry.source_key, ticket),
            paid_leases: add_paid_lease(state.paid_leases, paid_lease),
            total: state.total + 1
        }

        {:reply, {:ok, ticket}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.tickets, fn {_ticket, entry} -> Process.cancel_timer(entry.timer) end)
    Enum.each(state.active, fn {ref, _node_id} -> Process.demonitor(ref, [:flush]) end)

    {:reply, :ok,
     %{
       tickets: %{},
       active: %{},
       counts: %{},
       pending_counts: %{},
       pending_sources: %{},
       paid_leases: MapSet.new(),
       total: 0,
       draining: false
     }}
  end

  def handle_call(:begin_drain, _from, state) do
    {:reply, :ok, %{state | draining: true}}
  end

  def handle_call(:ready?, _from, state), do: {:reply, not state.draining, state}

  def handle_call(:check_ready, _from, %{draining: true} = state),
    do: {:reply, {:error, :relay_draining}, state}

  def handle_call(:check_ready, _from, state), do: {:reply, :ok, state}

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       pending: map_size(state.tickets),
       active: map_size(state.active),
       total: state.total,
       draining: state.draining
     }, state}
  end

  def handle_call({:claim, ticket, owner}, _from, state) do
    case Map.pop(state.tickets, ticket) do
      {nil, _tickets} ->
        {:reply, {:error, :invalid_ticket}, state}

      {%{timer: timer} = entry, tickets} ->
        Process.cancel_timer(timer)
        ref = Process.monitor(owner)
        active = Map.put(state.active, ref, Map.take(entry, [:node_id, :paid_lease]))

        {:reply, {:ok, Map.take(entry, [:node_id, :address, :request_id])},
         %{
           state
           | tickets: tickets,
             active: active,
             pending_counts: decrement(state.pending_counts, entry.node_id),
             pending_sources: remove_pending_source(state.pending_sources, entry.source_key)
         }}
    end
  end

  @impl true
  def handle_info({:expire, ticket}, state) do
    case Map.pop(state.tickets, ticket) do
      {nil, _tickets} ->
        {:noreply, state}

      {%{node_id: node_id, paid_lease: paid_lease, source_key: source_key}, tickets} ->
        {:noreply,
         %{
           state
           | tickets: tickets,
             counts: decrement(state.counts, node_id),
             pending_counts: decrement(state.pending_counts, node_id),
             pending_sources: remove_pending_source(state.pending_sources, source_key),
             paid_leases: remove_paid_lease(state.paid_leases, paid_lease),
             total: state.total - 1
         }}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.active, ref) do
      {nil, _active} ->
        {:noreply, state}

      {%{node_id: node_id, paid_lease: paid_lease}, active} ->
        {:noreply,
         %{
           state
           | active: active,
             counts: decrement(state.counts, node_id),
             paid_leases: remove_paid_lease(state.paid_leases, paid_lease),
             total: state.total - 1
         }}
    end
  end

  defp decrement(counts, node_id) do
    case Map.fetch!(counts, node_id) do
      1 -> Map.delete(counts, node_id)
      count -> Map.put(counts, node_id, count - 1)
    end
  end

  defp add_paid_lease(leases, nil), do: leases
  defp add_paid_lease(leases, lease), do: MapSet.put(leases, lease)
  defp remove_paid_lease(leases, nil), do: leases
  defp remove_paid_lease(leases, lease), do: MapSet.delete(leases, lease)

  defp pending_source_key(node_id, nil, source) when not is_nil(source),
    do: {node_id, ZaptunnelRelay.RateLimiter.source_key(source)}

  defp pending_source_key(_node_id, _paid_lease, _source), do: nil

  defp add_pending_source(sources, nil, _ticket), do: sources
  defp add_pending_source(sources, key, ticket), do: Map.put(sources, key, ticket)
  defp remove_pending_source(sources, nil), do: sources
  defp remove_pending_source(sources, key), do: Map.delete(sources, key)

  defp replace_pending_retry(state, node_id, nil, source) when not is_nil(source) do
    key = pending_source_key(node_id, nil, source)

    case Map.pop(state.pending_sources, key) do
      {nil, _sources} ->
        state

      {ticket, sources} ->
        {entry, tickets} = Map.pop!(state.tickets, ticket)
        Process.cancel_timer(entry.timer)

        %{
          state
          | tickets: tickets,
            counts: decrement(state.counts, node_id),
            pending_counts: decrement(state.pending_counts, node_id),
            pending_sources: sources,
            total: state.total - 1
        }
    end
  end

  defp replace_pending_retry(state, _node_id, _paid_lease, _source), do: state
end
