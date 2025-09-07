defmodule ExWire.LibP2P.Discovery do
  @moduledoc """
  Peer discovery service for LibP2P.

  Implements DHT-based peer discovery and bootstrap node connections.
  """

  use GenServer
  require Logger

  defstruct [
    :bootstrap_nodes,
    :discovered_peers,
    :dht_enabled,
    :discovery_interval,
    :parent_pid
  ]

  @discovery_interval_ms 30_000
  @max_discovered_peers 1000

  # Public API

  @doc """
  Start the discovery service.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start active peer discovery.
  """
  def start_discovery(discovery) do
    GenServer.cast(discovery, :start_discovery)
  end

  @doc """
  Stop peer discovery.
  """
  def stop_discovery(discovery) do
    GenServer.cast(discovery, :stop_discovery)
  end

  @doc """
  Add a bootstrap node.
  """
  def add_bootstrap_node(discovery, node_info) do
    GenServer.cast(discovery, {:add_bootstrap, node_info})
  end

  @doc """
  Get discovered peers.
  """
  def get_discovered_peers(discovery) do
    GenServer.call(discovery, :get_discovered)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    bootstrap_nodes = Keyword.get(opts, :bootstrap_nodes, default_bootstrap_nodes())
    dht_enabled = Keyword.get(opts, :dht_enabled, true)
    interval = Keyword.get(opts, :discovery_interval, @discovery_interval_ms)
    parent = Keyword.get(opts, :parent_pid)

    state = %__MODULE__{
      bootstrap_nodes: bootstrap_nodes,
      discovered_peers: MapSet.new(),
      dht_enabled: dht_enabled,
      discovery_interval: interval,
      parent_pid: parent
    }

    {:ok, _state}
  end

  @impl true
  def handle_cast(:start_discovery, _state) do
    # Connect to bootstrap nodes
    Enum.each(state.bootstrap_nodes, &connect_to_bootstrap/1)

    # Schedule periodic discovery
    Process.send_after(self(), :discover_peers, state.discovery_interval)

    Logger.info("Started peer discovery with #{length(state.bootstrap_nodes)} bootstrap nodes")
    {:noreply, state}
  end

  def handle_cast(:stop_discovery, _state) do
    Logger.info("Stopped peer discovery")
    {:noreply, state}
  end

  def handle_cast({:add_bootstrap, node_info}, _state) do
    new_bootstrap = [node_info | state.bootstrap_nodes]
    {:noreply, %{state | bootstrap_nodes: new_bootstrap}}
  end

  @impl true
  def handle_call(:get_discovered, _from, _state) do
    peers = MapSet.to_list(state.discovered_peers)
    {:reply, peers, state}
  end

  @impl true
  def handle_info(:discover_peers, _state) do
    # Simulate peer discovery
    new_peers = discover_peers_dht(state)

    updated_peers =
      state.discovered_peers
      |> MapSet.union(MapSet.new(new_peers))
      |> limit_peer_set(@max_discovered_peers)

    # Notify parent about new peers
    if state.parent_pid do
      Enum.each(new_peers, fn peer ->
        send(state.parent_pid, {:discovered_peer, peer})
      end)
    end

    # Schedule next discovery
    Process.send_after(self(), :discover_peers, state.discovery_interval)

    {:noreply, %{state | discovered_peers: updated_peers}}
  end

  def handle_info({:peer_found, peer_info}, _state) do
    updated_peers = MapSet.put(state.discovered_peers, peer_info)

    if state.parent_pid do
      send(state.parent_pid, {:discovered_peer, peer_info})
    end

    {:noreply, %{state | discovered_peers: updated_peers}}
  end

  # Private functions

  defp default_bootstrap_nodes do
    [
      %{
        id: "bootstrap1",
        address: "bootnode1.ethereum.org",
        port: 30303,
        public_key: "0x" <> String.duplicate("0", 128)
      },
      %{
        id: "bootstrap2",
        address: "bootnode2.ethereum.org",
        port: 30303,
        public_key: "0x" <> String.duplicate("1", 128)
      }
    ]
  end

  defp connect_to_bootstrap(node_info) do
    Logger.debug("Connecting to bootstrap node: #{node_info.id}")
    # In production, this would establish actual connection
    Process.send_after(self(), {:peer_found, node_info}, 100)
  end

  defp discover_peers_dht(_state) do
    if state.dht_enabled do
      # Simulate DHT discovery
      # In production, this would query the DHT
      Enum.map(1..3, fn i ->
        %{
          id: "discovered_peer_#{System.unique_integer([:positive])}",
          address: "192.168.1.#{100 + i}",
          port: 30303,
          discovered_at: System.system_time(:millisecond)
        }
      end)
    else
      []
    end
  end

  defp limit_peer_set(peer_set, max_size) do
    if MapSet.size(peer_set) > max_size do
      peer_set
      |> MapSet.to_list()
      |> Enum.take(max_size)
      |> MapSet.new()
    else
      peer_set
    end
  end
end
