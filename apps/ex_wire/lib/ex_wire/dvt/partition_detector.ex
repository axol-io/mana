defmodule ExWire.DVT.PartitionDetector do
  @moduledoc """
  Network Partition Detection and Recovery System for DVT.

  Implements sophisticated partition detection algorithms:
  - Heartbeat-based connectivity monitoring
  - Consensus round timeout detection  
  - Network topology analysis
  - Automatic partition recovery procedures
  """

  use GenServer
  require Logger

  alias ExWire.Enterprise.AuditLogger
  # Remove unused aliases

  @type cluster_id :: String.t()
  @type node_id :: pos_integer()
  @type partition_state :: :connected | :suspected | :partitioned | :recovering

  # Partition detection parameters
  # 15 seconds
  @heartbeat_timeout_ms 15_000
  # 30 seconds
  @consensus_timeout_ms 30_000
  # 33% of nodes unreachable = partition
  @partition_threshold 0.33
  # 5 seconds
  @recovery_probe_interval_ms 5_000
  @max_recovery_attempts 10

  # Partition event structure
  @type partition_event :: %{
          cluster_id: cluster_id(),
          detected_at: DateTime.t(),
          partition_type: :network | :consensus | :byzantine,
          affected_nodes: [node_id()],
          reachable_nodes: [node_id()],
          consensus_round: pos_integer() | nil,
          recovery_strategy: atom(),
          metadata: map()
        }

  defstruct [
    :node_id,
    # %{cluster_id => cluster_info}
    :cluster_memberships,
    # %{cluster_id => partition_state}
    :partition_states,
    # %{cluster_id => %{node_id => last_heartbeat}}
    :heartbeat_tracking,
    # %{cluster_id => consensus_state}
    :consensus_tracking,
    # %{cluster_id => attempt_count}
    :recovery_attempts,
    # List of recent partition events
    :partition_history,
    # Network topology information
    :topology_cache,
    # Configuration for monitoring
    :monitoring_config
  ]

  # Type definitions for nested structures
  @type cluster_info :: %{
          cluster_id: String.t(),
          total_nodes: pos_integer(),
          threshold: pos_integer(),
          # Set of expected node IDs
          expected_nodes: MapSet.t(),
          # When all nodes were last reachable
          last_full_connectivity: pos_integer(),
          # :none | :minority | :majority
          partition_tolerance: :none | :minority | :majority
        }

  @type consensus_state :: %{
          current_round: pos_integer(),
          round_start_time: pos_integer(),
          participating_nodes: MapSet.t(),
          missing_nodes: MapSet.t(),
          last_successful_round: pos_integer(),
          consecutive_timeouts: pos_integer()
        }

  ## Public API

  @doc """
  Start the partition detector.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a DVT cluster for partition monitoring.
  """
  def monitor_cluster(cluster_id, node_count, threshold, partition_tolerance \\ :minority) do
    GenServer.call(
      __MODULE__,
      {:monitor_cluster, cluster_id, node_count, threshold, partition_tolerance}
    )
  end

  @doc """
  Stop monitoring a cluster.
  """
  def unmonitor_cluster(cluster_id) do
    GenServer.call(__MODULE__, {:unmonitor_cluster, cluster_id})
  end

  @doc """
  Record a heartbeat from a node in a cluster.
  """
  def record_heartbeat(cluster_id, node_id) do
    GenServer.cast(__MODULE__, {:heartbeat, cluster_id, node_id})
  end

  @doc """
  Record consensus round activity for partition detection.
  """
  def record_consensus_activity(cluster_id, round, participating_nodes) do
    GenServer.cast(__MODULE__, {:consensus_activity, cluster_id, round, participating_nodes})
  end

  @doc """
  Get current partition status for all monitored clusters.
  """
  def get_partition_status() do
    GenServer.call(__MODULE__, :get_partition_status)
  end

  @doc """
  Get detailed partition status for a specific cluster.
  """
  def get_cluster_partition_status(cluster_id) do
    GenServer.call(__MODULE__, {:get_cluster_status, cluster_id})
  end

  @doc """
  Manually trigger partition recovery for a cluster.
  """
  def trigger_recovery(cluster_id) do
    GenServer.call(__MODULE__, {:trigger_recovery, cluster_id})
  end

  @doc """
  Get partition event history.
  """
  def get_partition_history(limit \\ 50) do
    GenServer.call(__MODULE__, {:get_history, limit})
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    node_id = Keyword.get(opts, :node_id, :crypto.strong_rand_bytes(4) |> Base.encode16())

    state = %__MODULE__{
      node_id: node_id,
      cluster_memberships: %{},
      partition_states: %{},
      heartbeat_tracking: %{},
      consensus_tracking: %{},
      recovery_attempts: %{},
      partition_history: [],
      topology_cache: %{},
      monitoring_config: parse_monitoring_config(opts)
    }

    # Schedule periodic partition detection
    :timer.send_interval(5_000, :check_partitions)
    :timer.send_interval(30_000, :update_topology)
    :timer.send_interval(@recovery_probe_interval_ms, :probe_recovery)

    Logger.info("DVT Partition Detector started", node_id: node_id)

    {:ok, _state}
  end

  @impl true
  def handle_call(
        {:monitor_cluster, cluster_id, node_count, threshold, partition_tolerance},
        _from,
        _state
      ) do
    cluster_info = %{
      cluster_id: cluster_id,
      total_nodes: node_count,
      threshold: threshold,
      expected_nodes: MapSet.new(1..node_count),
      last_full_connectivity: System.system_time(:millisecond),
      partition_tolerance: partition_tolerance
    }

    consensus_state = %{
      current_round: 0,
      round_start_time: System.system_time(:millisecond),
      participating_nodes: MapSet.new(),
      missing_nodes: MapSet.new(),
      last_successful_round: 0,
      consecutive_timeouts: 0
    }

    new_state = %{
      state
      | cluster_memberships: Map.put(state.cluster_memberships, cluster_id, cluster_info),
        partition_states: Map.put(state.partition_states, cluster_id, :connected),
        heartbeat_tracking: Map.put(state.heartbeat_tracking, cluster_id, %{}),
        consensus_tracking: Map.put(state.consensus_tracking, cluster_id, consensus_state)
    }

    AuditLogger.log(:info, "Started monitoring DVT cluster for partitions", %{
      cluster_id: cluster_id,
      node_count: node_count,
      threshold: threshold,
      partition_tolerance: partition_tolerance
    })

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:unmonitor_cluster, cluster_id}, _from, _state) do
    new_state = %{
      state
      | cluster_memberships: Map.delete(state.cluster_memberships, cluster_id),
        partition_states: Map.delete(state.partition_states, cluster_id),
        heartbeat_tracking: Map.delete(state.heartbeat_tracking, cluster_id),
        consensus_tracking: Map.delete(state.consensus_tracking, cluster_id),
        recovery_attempts: Map.delete(state.recovery_attempts, cluster_id)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_partition_status, _from, _state) do
    status = %{
      monitored_clusters: Map.keys(state.cluster_memberships),
      partition_states: state.partition_states,
      total_clusters: map_size(state.cluster_memberships),
      partitioned_clusters: count_partitioned_clusters(state),
      last_partition_event: get_last_partition_event(state)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:get_cluster_status, cluster_id}, _from, _state) do
    case Map.get(state.cluster_memberships, cluster_id) do
      nil ->
        {:reply, {:error, :not_monitored}, state}

      cluster_info ->
        status = %{
          cluster_id: cluster_id,
          partition_state: Map.get(state.partition_states, cluster_id, :unknown),
          total_nodes: cluster_info.total_nodes,
          reachable_nodes: get_reachable_nodes(cluster_id, state),
          unreachable_nodes: get_unreachable_nodes(cluster_id, state),
          last_full_connectivity: cluster_info.last_full_connectivity,
          consensus_status: Map.get(state.consensus_tracking, cluster_id),
          recovery_attempts: Map.get(state.recovery_attempts, cluster_id, 0)
        }

        {:reply, {:ok, status}, state}
    end
  end

  @impl true
  def handle_call({:trigger_recovery, cluster_id}, _from, _state) do
    case Map.get(state.partition_states, cluster_id) do
      partition_state when partition_state in [:suspected, :partitioned] ->
        state = trigger_partition_recovery(cluster_id, state)
        {:reply, :ok, _state}

      :recovering ->
        {:reply, {:error, :already_recovering}, state}

      :connected ->
        {:reply, {:error, :not_partitioned}, state}

      nil ->
        {:reply, {:error, :not_monitored}, state}
    end
  end

  @impl true
  def handle_call({:get_history, limit}, _from, _state) do
    history = Enum.take(state.partition_history, limit)
    {:reply, history, state}
  end

  @impl true
  def handle_cast({:heartbeat, cluster_id, node_id}, _state) do
    case Map.get(state.heartbeat_tracking, cluster_id) do
      nil ->
        # Cluster not monitored
        {:noreply, _state}

      heartbeats ->
        new_heartbeats = Map.put(heartbeats, node_id, DateTime.utc_now())
        new_tracking = Map.put(state.heartbeat_tracking, cluster_id, new_heartbeats)

        # Check if this heartbeat resolves a partition
        state = maybe_resolve_partition(cluster_id, %{state | heartbeat_tracking: new_tracking})

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:consensus_activity, cluster_id, round, participating_nodes}, _state) do
    case Map.get(state.consensus_tracking, cluster_id) do
      nil ->
        {:noreply, _state}

      consensus_state ->
        cluster_info = Map.get(state.cluster_memberships, cluster_id)

        missing_nodes =
          MapSet.difference(cluster_info.expected_nodes, MapSet.new(participating_nodes))

        updated_consensus = %{
          consensus_state
          | current_round: round,
            round_start_time: DateTime.utc_now(),
            participating_nodes: MapSet.new(participating_nodes),
            missing_nodes: missing_nodes,
            last_successful_round: round,
            consecutive_timeouts: 0
        }

        new_tracking = Map.put(state.consensus_tracking, cluster_id, updated_consensus)

        {:noreply, %{state | consensus_tracking: new_tracking}}
    end
  end

  @impl true
  def handle_info(:check_partitions, _state) do
    state = check_all_clusters_for_partitions(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:update_topology, _state) do
    state = update_network_topology(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:probe_recovery, _state) do
    state = probe_partition_recovery(state)
    {:noreply, state}
  end

  ## Private Functions

  defp parse_monitoring_config(opts) do
    %{
      heartbeat_timeout: Keyword.get(opts, :heartbeat_timeout, @heartbeat_timeout_ms),
      consensus_timeout: Keyword.get(opts, :consensus_timeout, @consensus_timeout_ms),
      partition_threshold: Keyword.get(opts, :partition_threshold, @partition_threshold),
      recovery_probe_interval:
        Keyword.get(opts, :recovery_probe_interval, @recovery_probe_interval_ms),
      max_recovery_attempts: Keyword.get(opts, :max_recovery_attempts, @max_recovery_attempts)
    }
  end

  defp check_all_clusters_for_partitions(_state) do
    Enum.reduce(state.cluster_memberships, state, fn {cluster_id, _cluster_info}, acc_state ->
      check_cluster_partition(cluster_id, acc_state)
    end)
  end

  defp check_cluster_partition(cluster_id, _state) do
    cluster_info = Map.get(state.cluster_memberships, cluster_id)
    heartbeats = Map.get(state.heartbeat_tracking, cluster_id, %{})
    consensus_state = Map.get(state.consensus_tracking, cluster_id)

    # Check heartbeat-based connectivity
    {reachable_nodes, unreachable_nodes} =
      analyze_heartbeat_connectivity(cluster_info, heartbeats)

    # Check consensus-based partition indicators
    consensus_partition = analyze_consensus_partition(cluster_info, consensus_state)

    # Determine partition state
    new_partition_state =
      determine_partition_state(
        cluster_info,
        reachable_nodes,
        unreachable_nodes,
        consensus_partition
      )

    current_state = Map.get(state.partition_states, cluster_id, :connected)

    if new_partition_state != current_state do
      state = handle_partition_state_change(cluster_id, current_state, new_partition_state, state)

      %{
        state
        | partition_states: Map.put(state.partition_states, cluster_id, new_partition_state)
      }
    else
      state
    end
  end

  defp analyze_heartbeat_connectivity(cluster_info, heartbeats) do
    now = DateTime.utc_now()
    timeout_threshold = DateTime.add(now, -@heartbeat_timeout_ms, :millisecond)

    {reachable, unreachable} =
      Enum.reduce(cluster_info.expected_nodes, {[], []}, fn node_id, {reachable, unreachable} ->
        case Map.get(heartbeats, node_id) do
          nil ->
            {reachable, [node_id | unreachable]}

          last_heartbeat ->
            if DateTime.compare(last_heartbeat, timeout_threshold) == :gt do
              {[node_id | reachable], unreachable}
            else
              {reachable, [node_id | unreachable]}
            end
        end
      end)

    {MapSet.new(reachable), MapSet.new(unreachable)}
  end

  defp analyze_consensus_partition(cluster_info, consensus_state) do
    if consensus_state == nil do
      %{partitioned: false, reason: :no_consensus_data}
    else
      now = DateTime.utc_now()
      round_age = DateTime.diff(now, consensus_state.round_start_time, :millisecond)

      cond do
        round_age > @consensus_timeout_ms and MapSet.size(consensus_state.missing_nodes) > 0 ->
          %{
            partitioned: true,
            reason: :consensus_timeout,
            missing_nodes: consensus_state.missing_nodes,
            consecutive_timeouts: consensus_state.consecutive_timeouts + 1
          }

        consensus_state.consecutive_timeouts > 3 ->
          %{
            partitioned: true,
            reason: :repeated_consensus_failures,
            consecutive_timeouts: consensus_state.consecutive_timeouts
          }

        MapSet.size(consensus_state.missing_nodes) >= cluster_info.threshold ->
          %{
            partitioned: true,
            reason: :insufficient_consensus_participation,
            missing_nodes: consensus_state.missing_nodes
          }

        true ->
          %{partitioned: false, reason: :consensus_healthy}
      end
    end
  end

  defp determine_partition_state(
         cluster_info,
         reachable_nodes,
         unreachable_nodes,
         consensus_partition
       ) do
    unreachable_ratio = MapSet.size(unreachable_nodes) / cluster_info.total_nodes

    cond do
      # Network partition detected
      unreachable_ratio >= @partition_threshold ->
        :partitioned

      # Consensus partition detected  
      consensus_partition.partitioned ->
        case consensus_partition.reason do
          :consensus_timeout -> :suspected
          :repeated_consensus_failures -> :partitioned
          :insufficient_consensus_participation -> :partitioned
        end

      # Some nodes unreachable but below threshold
      MapSet.size(unreachable_nodes) > 0 ->
        :suspected

      # All nodes reachable
      true ->
        :connected
    end
  end

  defp handle_partition_state_change(cluster_id, old_state, new_state, _state) do
    Logger.warning("DVT cluster partition _state changed", %{
      cluster_id: cluster_id,
      old_state: old_state,
      new_state: new_state
    })

    partition_event = %{
      cluster_id: cluster_id,
      detected_at: DateTime.utc_now(),
      partition_type: classify_partition_type(new_state),
      old_state: old_state,
      new_state: new_state,
      affected_nodes: get_unreachable_nodes(cluster_id, state),
      reachable_nodes: get_reachable_nodes(cluster_id, state),
      metadata: %{}
    }

    # Log critical partition events
    if new_state == :partitioned do
      AuditLogger.log(:alert, "DVT cluster partition detected", partition_event)

      # Trigger automatic recovery if enabled
      state = maybe_trigger_auto_recovery(cluster_id, state)

      # Update partition history
      new_history = [partition_event | Enum.take(state.partition_history, 99)]
      %{state | partition_history: new_history}
    else
      AuditLogger.log(:info, "DVT cluster partition state updated", partition_event)
      state
    end
  end

  defp classify_partition_type(partition_state) do
    case partition_state do
      :connected -> :none
      :suspected -> :network
      :partitioned -> :network
      :recovering -> :network
    end
  end

  defp maybe_trigger_auto_recovery(cluster_id, _state) do
    cluster_info = Map.get(_state.cluster_memberships, cluster_id)

    case cluster_info.partition_tolerance do
      :none ->
        Logger.info("Auto-recovery disabled for cluster #{cluster_id}")
        state

      _ ->
        trigger_partition_recovery(cluster_id, state)
    end
  end

  defp trigger_partition_recovery(cluster_id, _state) do
    attempts = Map.get(state.recovery_attempts, cluster_id, 0)

    if attempts < @max_recovery_attempts do
      Logger.info(
        "Triggering partition recovery for cluster #{cluster_id} (attempt #{attempts + 1})"
      )

      # Update recovery attempts
      new_attempts = Map.put(state.recovery_attempts, cluster_id, attempts + 1)

      # Set state to recovering
      new_states = Map.put(state.partition_states, cluster_id, :recovering)

      # Initiate recovery procedures
      spawn(fn -> execute_recovery_procedures(cluster_id) end)

      %{state | recovery_attempts: new_attempts, partition_states: new_states}
    else
      Logger.error("Max recovery attempts reached for cluster #{cluster_id}")
      state
    end
  end

  defp execute_recovery_procedures(cluster_id) do
    # 1. Attempt to re-establish network connections
    attempt_network_recovery(cluster_id)

    # 2. Restart consensus if needed
    attempt_consensus_recovery(cluster_id)

    # 3. Verify recovery success
    :timer.sleep(5_000)
    verify_recovery_success(cluster_id)
  end

  defp attempt_network_recovery(cluster_id) do
    Logger.info("Attempting network recovery for cluster #{cluster_id}")

    # Try to reconnect to unreachable peers
    # This would integrate with LibP2P connection management
    :ok
  end

  defp attempt_consensus_recovery(cluster_id) do
    Logger.info("Attempting consensus recovery for cluster #{cluster_id}")

    # Reset consensus state and trigger new round
    DutyConsensus.reset_consensus_round(cluster_id)
  end

  defp verify_recovery_success(cluster_id) do
    # Check if partition is resolved
    case get_cluster_partition_status(cluster_id) do
      {:ok, %{partition_state: :connected}} ->
        Logger.info("Partition recovery successful for cluster #{cluster_id}")

      {:ok, status} ->
        Logger.warning(
          "Partition recovery incomplete for cluster #{cluster_id}: #{inspect(status)}"
        )

      {:error, _reason} ->
        Logger.error("Failed to verify recovery for cluster #{cluster_id}: #{inspect(reason)}")
    end
  end

  defp maybe_resolve_partition(cluster_id, _state) do
    current_state = Map.get(state.partition_states, cluster_id)

    if current_state in [:suspected, :partitioned, :recovering] do
      # Check if partition is resolved
      cluster_info = Map.get(state.cluster_memberships, cluster_id)
      heartbeats = Map.get(state.heartbeat_tracking, cluster_id, %{})

      {reachable_nodes, unreachable_nodes} =
        analyze_heartbeat_connectivity(cluster_info, heartbeats)

      if MapSet.size(unreachable_nodes) == 0 do
        Logger.info("Partition resolved for cluster #{cluster_id}")

        # Reset recovery attempts
        new_attempts = Map.put(state.recovery_attempts, cluster_id, 0)
        new_states = Map.put(state.partition_states, cluster_id, :connected)

        # Update last full connectivity
        cluster_info = Map.put(cluster_info, :last_full_connectivity, DateTime.utc_now())
        new_memberships = Map.put(state.cluster_memberships, cluster_id, cluster_info)

        %{
          state
          | recovery_attempts: new_attempts,
            partition_states: new_states,
            cluster_memberships: new_memberships
        }
      else
        state
      end
    else
      state
    end
  end

  defp probe_partition_recovery(_state) do
    recovering_clusters =
      state.partition_states
      |> Enum.filter(fn {_cluster_id, partition_state} -> partition_state == :recovering end)
      |> Enum.map(fn {cluster_id, _} -> cluster_id end)

    Enum.reduce(recovering_clusters, state, fn cluster_id, acc_state ->
      check_recovery_progress(cluster_id, acc_state)
    end)
  end

  defp check_recovery_progress(cluster_id, _state) do
    # Check if recovery is making progress
    cluster_info = Map.get(state.cluster_memberships, cluster_id)
    heartbeats = Map.get(state.heartbeat_tracking, cluster_id, %{})

    {reachable_nodes, unreachable_nodes} =
      analyze_heartbeat_connectivity(cluster_info, heartbeats)

    unreachable_ratio = MapSet.size(unreachable_nodes) / cluster_info.total_nodes

    if unreachable_ratio < @partition_threshold do
      Logger.info("Recovery progress detected for cluster #{cluster_id}")
      new_states = Map.put(state.partition_states, cluster_id, :suspected)
      %{state | partition_states: new_states}
    else
      state
    end
  end

  defp update_network_topology(_state) do
    # Update cached network topology information
    # This could include peer connectivity graphs, latency measurements, etc.
    state
  end

  defp get_reachable_nodes(cluster_id, _state) do
    cluster_info = Map.get(state.cluster_memberships, cluster_id)
    heartbeats = Map.get(state.heartbeat_tracking, cluster_id, %{})

    if cluster_info do
      {reachable_nodes, _unreachable} = analyze_heartbeat_connectivity(cluster_info, heartbeats)
      MapSet.to_list(reachable_nodes)
    else
      []
    end
  end

  defp get_unreachable_nodes(cluster_id, _state) do
    cluster_info = Map.get(state.cluster_memberships, cluster_id)
    heartbeats = Map.get(state.heartbeat_tracking, cluster_id, %{})

    if cluster_info do
      {_reachable, unreachable_nodes} = analyze_heartbeat_connectivity(cluster_info, heartbeats)
      MapSet.to_list(unreachable_nodes)
    else
      []
    end
  end

  defp count_partitioned_clusters(_state) do
    state.partition_states
    |> Enum.count(fn {_cluster_id, partition_state} -> partition_state == :partitioned end)
  end

  defp get_last_partition_event(_state) do
    case state.partition_history do
      [event | _] -> event
      [] -> nil
    end
  end
end
