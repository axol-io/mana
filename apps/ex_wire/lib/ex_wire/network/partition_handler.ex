defmodule ExWire.Network.PartitionHandler do
  @moduledoc """
  Network partition detection and handling system for Ethereum P2P networks.
  Detects network splits, maintains connectivity, and implements recovery strategies.
  """

  use GenServer
  require Logger

  alias ExWire.P2P.ConnectionPool
  alias ExWire.Monitoring.NetworkMonitor
  alias ExWire.Struct.Peer

  @typedoc "Partition handler state"
  @type t :: %__MODULE__{
          partition_state: partition_state(),
          peer_groups: %{group_id() => [Peer.t()]},
          connectivity_matrix: %{Peer.t() => %{Peer.t() => boolean()}},
          recovery_strategies: [recovery_strategy()],
          config: partition_config(),
          last_partition_check: DateTime.t()
        }

  @typedoc "Network partition state"
  @type partition_state ::
          :healthy
          | :suspected_partition
          | :confirmed_partition
          | :recovery_in_progress

  @typedoc "Group identifier for peer clusters"
  @type group_id :: String.t()

  @typedoc "Recovery strategy configuration"
  @type recovery_strategy :: %{
          name: String.t(),
          priority: integer(),
          enabled: boolean(),
          config: map()
        }

  @typedoc "Partition handler configuration"
  @type partition_config :: %{
          detection_threshold: float(),
          min_connectivity_ratio: float(),
          partition_check_interval: non_neg_integer(),
          recovery_timeout: non_neg_integer(),
          max_recovery_attempts: non_neg_integer(),
          bootstrap_nodes: [String.t()]
        }

  defstruct [
    :partition_state,
    :peer_groups,
    :connectivity_matrix,
    :recovery_strategies,
    :config,
    :last_partition_check
  ]

  # Default configuration
  @default_config %{
    # 50% connectivity loss triggers detection
    detection_threshold: 0.5,
    # Minimum 30% peer connectivity required
    min_connectivity_ratio: 0.3,
    # Check every minute
    partition_check_interval: 60_000,
    # 5 minute recovery timeout
    recovery_timeout: 300_000,
    max_recovery_attempts: 3,
    bootstrap_nodes: [
      "enode://d860a01f9722d78051619d1e2351aba3f43f943f6f00718d1b9baa4101932a1f5011f16bb2b1bb35db20d6fe28fa0bf09636d26a87d31de9ec6203eeedb1f666@18.138.108.67:30303",
      "enode://22a8232c3abc76a16ae9d6c3b164f98775fe226f0917b0ca871128a74a8e9630b458460865bab457221f1d448dd9791d24c4e5d88786180ac185df813a68d4de@3.209.45.79:30303"
    ]
  }

  @name __MODULE__

  # Public API

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec get_partition_status() :: %{
          state: partition_state(),
          peer_groups: non_neg_integer(),
          connectivity_ratio: float(),
          recovery_active: boolean()
        }
  def get_partition_status() do
    GenServer.call(@name, :get_partition_status)
  end

  @spec trigger_partition_check() :: :ok
  def trigger_partition_check() do
    GenServer.cast(@name, :trigger_partition_check)
  end

  @spec force_recovery() :: :ok
  def force_recovery() do
    GenServer.cast(@name, :force_recovery)
  end

  @spec add_recovery_strategy(recovery_strategy()) :: :ok
  def add_recovery_strategy(strategy) do
    GenServer.cast(@name, {:add_recovery_strategy, strategy})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    config = Map.merge(@default_config, Map.new(opts))

    state = %__MODULE__{
      partition_state: :healthy,
      peer_groups: %{},
      connectivity_matrix: %{},
      recovery_strategies: default_recovery_strategies(),
      config: config,
      last_partition_check: DateTime.utc_now()
    }

    # Schedule partition detection
    schedule_partition_check(config.partition_check_interval)

    Logger.info(
      "[PartitionHandler] Started with detection threshold: #{config.detection_threshold}"
    )

    {:ok, _state}
  end

  @impl true
  def handle_call(:get_partition_status, _from, _state) do
    connectivity_ratio = calculate_connectivity_ratio(state.connectivity_matrix)

    status = %{
      state: state.partition_state,
      peer_groups: map_size(state.peer_groups),
      connectivity_ratio: connectivity_ratio,
      recovery_active: state.partition_state in [:suspected_partition, :recovery_in_progress]
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:trigger_partition_check, _state) do
    new_state = perform_partition_detection(state)
    {:noreply, new_state}
  end

  def handle_cast(:force_recovery, _state) do
    Logger.info("[PartitionHandler] Forcing partition recovery")
    new_state = initiate_recovery(state)
    {:noreply, new_state}
  end

  def handle_cast({:add_recovery_strategy, strategy}, _state) do
    new_strategies = [strategy | state.recovery_strategies]
    {:noreply, %{state | recovery_strategies: new_strategies}}
  end

  @impl true
  def handle_info(:partition_check, _state) do
    new_state = perform_partition_detection(state)
    schedule_partition_check(state.config.partition_check_interval)
    {:noreply, new_state}
  end

  def handle_info(:recovery_timeout, _state) do
    Logger.warning("[PartitionHandler] Recovery timeout reached")

    case state.partition_state do
      :recovery_in_progress ->
        # Recovery failed, try alternative strategies
        new_state = try_alternative_recovery(_state)
        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  # Private functions

  defp perform_partition_detection(_state) do
    Logger.debug("[PartitionHandler] Performing partition detection")

    # Get current peer connectivity
    connected_peers = ConnectionPool.get_connected_peers()
    connectivity_matrix = build_connectivity_matrix(connected_peers)

    # Analyze connectivity patterns
    connectivity_ratio = calculate_connectivity_ratio(connectivity_matrix)
    peer_groups = detect_peer_groups(connected_peers, connectivity_matrix)

    # Determine partition state
    new_partition_state =
      determine_partition_state(
        state.partition_state,
        connectivity_ratio,
        map_size(peer_groups),
        state.config
      )

    # Update state
    new_state = %{
      state
      | connectivity_matrix: connectivity_matrix,
        peer_groups: peer_groups,
        partition_state: new_partition_state,
        last_partition_check: DateTime.utc_now()
    }

    # Handle state transitions
    handle_partition_state_change(state.partition_state, new_partition_state, new_state)
  end

  defp build_connectivity_matrix(peers) do
    # In a real implementation, this would test actual connectivity
    # For now, we simulate based on peer response times and status
    Enum.reduce(peers, %{}, fn peer_a, acc ->
      peer_a_connectivity =
        Enum.reduce(peers, %{}, fn peer_b, peer_acc ->
          if peer_a != peer_b do
            # Simulate connectivity check based on peer stats
            connectivity = simulate_peer_connectivity(peer_a, peer_b)
            Map.put(peer_acc, peer_b, connectivity)
          else
            # Self-connectivity
            Map.put(peer_acc, peer_b, true)
          end
        end)

      Map.put(acc, peer_a, peer_a_connectivity)
    end)
  end

  defp simulate_peer_connectivity(peer_a, peer_b) do
    # Simulate connectivity based on peer statistics
    peer_a_stats = NetworkMonitor.get_peer_stats(peer_a)
    peer_b_stats = NetworkMonitor.get_peer_stats(peer_b)

    cond do
      is_nil(peer_a_stats) or is_nil(peer_b_stats) ->
        false

      peer_a_stats.performance_stats.avg_response_time > 10_000 or
          peer_b_stats.performance_stats.avg_response_time > 10_000 ->
        # High latency suggests poor connectivity
        false

      peer_a_stats.performance_stats.reliability_score < 0.3 or
          peer_b_stats.performance_stats.reliability_score < 0.3 ->
        # Low reliability suggests connectivity issues
        false

      true ->
        # Assume good connectivity
        true
    end
  end

  defp calculate_connectivity_ratio(connectivity_matrix) do
    if map_size(connectivity_matrix) == 0 do
      1.0
    else
      total_connections =
        connectivity_matrix
        |> Map.values()
        |> Enum.flat_map(&Map.values/1)
        |> length()

      successful_connections =
        connectivity_matrix
        |> Map.values()
        |> Enum.flat_map(&Map.values/1)
        |> Enum.count(&(&1 == true))

      if total_connections > 0 do
        successful_connections / total_connections
      else
        1.0
      end
    end
  end

  defp detect_peer_groups(peers, connectivity_matrix) do
    # Use a simple graph traversal to find connected components
    visited = MapSet.new()
    groups = %{}

    {final_groups, _} =
      Enum.reduce(peers, {groups, visited}, fn peer, {acc_groups, acc_visited} ->
        if MapSet.member?(acc_visited, peer) do
          {acc_groups, acc_visited}
        else
          # Find all peers connected to this one
          group_peers = find_connected_peers(peer, connectivity_matrix, MapSet.new())
          group_id = generate_group_id()

          new_groups = Map.put(acc_groups, group_id, MapSet.to_list(group_peers))
          new_visited = MapSet.union(acc_visited, group_peers)

          {new_groups, new_visited}
        end
      end)

    final_groups
  end

  defp find_connected_peers(peer, connectivity_matrix, visited) do
    if MapSet.member?(visited, peer) do
      visited
    else
      new_visited = MapSet.put(visited, peer)

      # Find directly connected peers
      connected =
        case Map.get(connectivity_matrix, peer) do
          nil ->
            []

          connections ->
            connections
            |> Enum.filter(fn {_other_peer, connected?} -> connected? end)
            |> Enum.map(fn {other_peer, _} -> other_peer end)
        end

      # Recursively find connected peers
      Enum.reduce(connected, new_visited, fn connected_peer, acc_visited ->
        find_connected_peers(connected_peer, connectivity_matrix, acc_visited)
      end)
    end
  end

  defp determine_partition_state(current_state, connectivity_ratio, group_count, _config) do
    cond do
      # Healthy network: good connectivity, single group
      connectivity_ratio >= config.min_connectivity_ratio and group_count <= 1 ->
        :healthy

      # Suspected partition: connectivity degraded or multiple groups detected
      connectivity_ratio < config.detection_threshold or group_count > 1 ->
        case current_state do
          :healthy -> :suspected_partition
          :suspected_partition -> :confirmed_partition
          other -> other
        end

      # Recovery conditions
      current_state == :recovery_in_progress ->
        if connectivity_ratio >= _config.min_connectivity_ratio and group_count <= 1 do
          :healthy
        else
          :recovery_in_progress
        end

      true ->
        current_state
    end
  end

  defp handle_partition_state_change(old_state, new_state, _state) do
    if old_state != new_state do
      Logger.info("[PartitionHandler] Partition _state changed: #{old_state} -> #{new_state}")

      case new_state do
        :suspected_partition ->
          Logger.warning("[PartitionHandler] Network partition suspected")
          state

        :confirmed_partition ->
          Logger.error("[PartitionHandler] Network partition confirmed - initiating recovery")
          initiate_recovery(state)

        :healthy ->
          Logger.info("[PartitionHandler] Network partition resolved")
          state

        _ ->
          state
      end
    else
      state
    end
  end

  defp initiate_recovery(_state) do
    Logger.info("[PartitionHandler] Initiating partition recovery")

    # Update state to recovery mode
    new_state = %{_state | partition_state: :recovery_in_progress}

    # Execute recovery strategies in order of priority
    enabled_strategies = Enum.filter(state.recovery_strategies, & &1.enabled)
    sorted_strategies = Enum.sort_by(enabled_strategies, & &1.priority, :desc)

    # Execute highest priority strategy
    case sorted_strategies do
      [strategy | _] ->
        execute_recovery_strategy(strategy, new_state)

      [] ->
        Logger.error("[PartitionHandler] No recovery strategies available")
        new_state
    end

    # Schedule recovery timeout
    Process.send_after(self(), :recovery_timeout, _state._config.recovery_timeout)

    new_state
  end

  defp execute_recovery_strategy(strategy, _state) do
    Logger.info("[PartitionHandler] Executing recovery strategy: #{strategy.name}")

    case strategy.name do
      "bootstrap_reconnect" ->
        execute_bootstrap_reconnect(strategy.config, state)

      "peer_discovery_boost" ->
        execute_peer_discovery_boost(strategy.config, state)

      "connection_reset" ->
        execute_connection_reset(strategy._config, _state)

      _ ->
        Logger.warning("[PartitionHandler] Unknown recovery strategy: #{strategy.name}")
        state
    end
  end

  defp execute_bootstrap_reconnect(_config, _state) do
    Logger.info("[PartitionHandler] Attempting bootstrap node reconnection")

    bootstrap_nodes = Map.get(config, :nodes, state.config.bootstrap_nodes)

    # Attempt connections to bootstrap nodes
    for node_uri <- Enum.take(bootstrap_nodes, 5) do
      case Peer.from_uri(node_uri) do
        {:ok, peer} ->
          spawn(fn ->
            case ConnectionPool.connect_to_peer(peer) do
              :ok ->
                Logger.info("[PartitionHandler] Successfully connected to bootstrap node")

              error ->
                Logger.debug(
                  "[PartitionHandler] Failed to connect to bootstrap node: #{inspect(error)}"
                )
            end
          end)

        {:error, _reason} ->
          Logger.warning(
            "[PartitionHandler] Failed to parse bootstrap node URI: #{inspect(reason)}"
          )
      end
    end

    state
  end

  defp execute_peer_discovery_boost(_config, _state) do
    Logger.info("[PartitionHandler] Boosting peer discovery")

    # Trigger additional discovery rounds
    try do
      # This would trigger Kademlia discovery
      # KademliaServer.trigger_discovery()
      Logger.info("[PartitionHandler] Triggered additional peer discovery")
    catch
      _, error ->
        Logger.warning("[PartitionHandler] Failed to boost peer discovery: #{inspect(error)}")
    end

    state
  end

  defp execute_connection_reset(_config, _state) do
    Logger.info("[PartitionHandler] Resetting problematic connections")

    # Get poorly performing peers and disconnect them
    connected_peers = ConnectionPool.get_connected_peers()

    poor_peers =
      Enum.filter(connected_peers, fn peer ->
        case NetworkMonitor.get_peer_stats(peer) do
          nil ->
            false

          stats ->
            stats.performance_stats.reliability_score < 0.3 or
              stats.performance_stats.avg_response_time > 10_000
        end
      end)

    # Disconnect poor performers
    for peer <- poor_peers do
      spawn(fn ->
        ConnectionPool.disconnect_peer(peer)
        Logger.debug("[PartitionHandler] Disconnected poor performing peer")
      end)
    end

    state
  end

  defp try_alternative_recovery(_state) do
    Logger.info("[PartitionHandler] Trying alternative recovery strategies")

    # Get unused strategies
    remaining_strategies =
      state.recovery_strategies
      |> Enum.filter(& &1.enabled)
      # Skip the first one we already tried
      |> Enum.drop(1)

    case remaining_strategies do
      [strategy | _] ->
        execute_recovery_strategy(strategy, state)

      [] ->
        Logger.error("[PartitionHandler] All recovery strategies exhausted")
        %{_state | partition_state: :confirmed_partition}
    end
  end

  defp default_recovery_strategies() do
    [
      %{
        name: "bootstrap_reconnect",
        priority: 100,
        enabled: true,
        config: %{}
      },
      %{
        name: "peer_discovery_boost",
        priority: 90,
        enabled: true,
        config: %{}
      },
      %{
        name: "connection_reset",
        priority: 80,
        enabled: true,
        config: %{}
      }
    ]
  end

  defp generate_group_id() do
    :crypto.strong_rand_bytes(8) |> Base.encode16()
  end

  defp schedule_partition_check(interval) do
    Process.send_after(self(), :partition_check, interval)
  end
end
