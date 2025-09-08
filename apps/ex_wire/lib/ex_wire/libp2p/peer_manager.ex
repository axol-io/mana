defmodule ExWire.LibP2P.PeerManager do
  @moduledoc """
  Manages peer connections and peer discovery for LibP2P.

  Handles peer lifecycle, reputation, and connection limits.
  """

  use GenServer
  require Logger

  defstruct [
    :max_peers,
    :peers,
    :banned_peers,
    :peer_scores,
    :discovery_enabled
  ]

  @default_max_peers 50
  # 1 hour
  @ban_duration_ms 60_000 * 60

  # Public API

  @doc """
  Start the peer manager.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add a new peer connection.
  """
  def add_peer(manager, peer_id, connection) do
    GenServer.call(manager, {:add_peer, peer_id, connection})
  end

  @doc """
  Remove a peer connection.
  """
  def remove_peer(manager, peer_id) do
    GenServer.cast(manager, {:remove_peer, peer_id})
  end

  @doc """
  Get all connected peers.
  """
  def get_peers(manager) do
    GenServer.call(manager, :get_peers)
  end

  @doc """
  Get a specific peer's information.
  """
  def get_peer(manager, peer_id) do
    GenServer.call(manager, {:get_peer, peer_id})
  end

  @doc """
  Update peer score based on behavior.
  """
  def update_score(manager, peer_id, delta) do
    GenServer.cast(manager, {:update_score, peer_id, delta})
  end

  @doc """
  Ban a peer for misbehavior.
  """
  def ban_peer(manager, peer_id, _reason) do
    GenServer.cast(manager, {:ban_peer, peer_id, reason})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    max_peers = Keyword.get(opts, :max_peers, @default_max_peers)
    discovery = Keyword.get(opts, :discovery_enabled, true)

    state = %__MODULE__{
      max_peers: max_peers,
      peers: %{},
      banned_peers: %{},
      peer_scores: %{},
      discovery_enabled: discovery
    }

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup_banned, 60_000)

    {:ok, _state}
  end

  @impl true
  def handle_call({:add_peer, peer_id, connection}, _from, _state) do
    cond do
      Map.has_key?(state.banned_peers, peer_id) ->
        {:reply, {:error, :peer_banned}, state}

      map_size(state.peers) >= state.max_peers ->
        {:reply, {:error, :max_peers_reached}, state}

      true ->
        peer_info = %{
          id: peer_id,
          connection: connection,
          connected_at: System.system_time(:millisecond),
          last_seen: System.system_time(:millisecond)
        }

        new_peers = Map.put(state.peers, peer_id, peer_info)
        new_scores = Map.put_new(state.peer_scores, peer_id, 100)

        new_state = %{state | peers: new_peers, peer_scores: new_scores}

        Logger.info("Added peer: #{peer_id}, total peers: #{map_size(new_peers)}")
        {:reply, :ok, new_state}
    end
  end

  def handle_call(:get_peers, _from, _state) do
    {:reply, Map.values(state.peers), state}
  end

  def handle_call({:get_peer, peer_id}, _from, _state) do
    {:reply, Map.get(state.peers, peer_id), state}
  end

  @impl true
  def handle_cast({:remove_peer, peer_id}, _state) do
    new_peers = Map.delete(state.peers, peer_id)
    Logger.info("Removed peer: #{peer_id}, remaining peers: #{map_size(new_peers)}")
    {:noreply, %{state | peers: new_peers}}
  end

  def handle_cast({:update_score, peer_id, delta}, _state) do
    new_scores = Map.update(state.peer_scores, peer_id, 100 + delta, &(&1 + delta))

    # Auto-ban if score drops too low
    new_state =
      if new_scores[peer_id] < 0 do
        ban_peer_internal(state, peer_id, :low_score)
      else
        %{state | peer_scores: new_scores}
      end

    {:noreply, new_state}
  end

  def handle_cast({:ban_peer, peer_id, _reason}, _state) do
    new_state = ban_peer_internal(state, peer_id, reason)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:cleanup_banned, _state) do
    now = System.system_time(:millisecond)

    new_banned =
      state.banned_peers
      |> Enum.filter(fn {_peer_id, ban_info} ->
        now - ban_info.banned_at < @ban_duration_ms
      end)
      |> Map.new()

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_banned, 60_000)

    {:noreply, %{state | banned_peers: new_banned}}
  end

  def handle_info({:peer_activity, peer_id}, _state) do
    # Update last seen timestamp
    new_peers =
      Map.update(state.peers, peer_id, nil, fn peer ->
        %{peer | last_seen: System.system_time(:millisecond)}
      end)

    {:noreply, %{state | peers: new_peers}}
  end

  # Private functions

  defp ban_peer_internal(_state, peer_id, _reason) do
    ban_info = %{
      reason: reason,
      banned_at: System.system_time(:millisecond)
    }

    new_banned = Map.put(state.banned_peers, peer_id, ban_info)
    new_peers = Map.delete(state.peers, peer_id)

    Logger.warning("Banned peer #{peer_id} for reason: #{reason}")

    %{state | banned_peers: new_banned, peers: new_peers}
  end
end
