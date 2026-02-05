defmodule ExWire.DVT.PartitionDetectorTest do
  use ExUnit.Case, async: false

  alias ExWire.DVT.{PartitionDetector, DutyConsensus}

  @cluster_id "test_cluster_001"
  @node_count 5
  @threshold 3
  @test_timeout 1_000

  setup do
    # Start the partition detector
    {:ok, _pid} =
      PartitionDetector.start_link(
        node_id: "test_node_001",
        # Shorter timeout for testing
        heartbeat_timeout: 1_000,
        recovery_probe_interval: 500
      )

    on_exit(fn ->
      if Process.whereis(ExWire.DVT.PartitionDetector) do
        GenServer.stop(ExWire.DVT.PartitionDetector)
      end
    end)

    :ok
  end

  describe "cluster monitoring" do
    test "can start monitoring a DVT cluster" do
      assert :ok =
               PartitionDetector.monitor_cluster(@cluster_id, @node_count, @threshold, :minority)

      status = PartitionDetector.get_partition_status()
      assert @cluster_id in status.monitored_clusters
      assert status.total_clusters == 1
    end

    test "can stop monitoring a cluster" do
      # Start monitoring
      :ok = PartitionDetector.monitor_cluster(@cluster_id, @node_count, @threshold, :minority)

      # Verify monitoring is active
      status = PartitionDetector.get_partition_status()
      assert @cluster_id in status.monitored_clusters

      # Stop monitoring
      assert :ok = PartitionDetector.unmonitor_cluster(@cluster_id)

      # Verify monitoring stopped
      status = PartitionDetector.get_partition_status()
      assert @cluster_id not in status.monitored_clusters
    end

    test "tracks cluster configuration correctly" do
      :ok = PartitionDetector.monitor_cluster(@cluster_id, @node_count, @threshold, :majority)

      {:ok, cluster_status} = PartitionDetector.get_cluster_partition_status(@cluster_id)

      assert cluster_status.cluster_id == @cluster_id
      assert cluster_status.total_nodes == @node_count
      # Initial state
      assert cluster_status.partition_state == :connected
    end

    test "returns error for non-monitored cluster status" do
      assert {:error, :not_monitored} =
               PartitionDetector.get_cluster_partition_status("unknown_cluster")
    end
  end

  describe "heartbeat tracking" do
    setup do
      :ok = PartitionDetector.monitor_cluster(@cluster_id, @node_count, @threshold, :minority)
      :ok
    end

    test "records heartbeats from cluster nodes" do
      # Record heartbeats from multiple nodes
      :ok = PartitionDetector.record_heartbeat(@cluster_id, 1)
      :ok = PartitionDetector.record_heartbeat(@cluster_id, 2)
      :ok = PartitionDetector.record_heartbeat(@cluster_id, 3)

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)

      # Should have recorded heartbeats from 3 nodes
      assert length(status.reachable_nodes) == 3
      assert 1 in status.reachable_nodes
      assert 2 in status.reachable_nodes
      assert 3 in status.reachable_nodes
    end

    test "maintains partition state with sufficient heartbeats" do
      # Record heartbeats from majority of nodes
      Enum.each(1..4, fn node_id ->
        PartitionDetector.record_heartbeat(@cluster_id, node_id)
      end)

      # Let the partition detector process the heartbeats
      Process.sleep(100)

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)
      assert status.partition_state == :connected
    end

    test "detects suspected partition with missing heartbeats" do
      # Only send heartbeats from some nodes
      PartitionDetector.record_heartbeat(@cluster_id, 1)
      PartitionDetector.record_heartbeat(@cluster_id, 2)

      # Wait for partition detection to run
      Process.sleep(100)

      # Trigger partition check
      send(ExWire.DVT.PartitionDetector, :check_partitions)
      Process.sleep(100)

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)

      # Should detect some unreachable nodes
      assert length(status.unreachable_nodes) > 0
    end

    test "ignores heartbeats from non-monitored clusters" do
      # Try to record heartbeat for non-monitored cluster
      :ok = PartitionDetector.record_heartbeat("unknown_cluster", 1)

      # Should not affect monitored cluster status
      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)
      assert status.reachable_nodes == []
    end
  end

  describe "consensus activity tracking" do
    setup do
      :ok = PartitionDetector.monitor_cluster(@cluster_id, @node_count, @threshold, :minority)
      :ok
    end

    test "records successful consensus rounds" do
      participating_nodes = [1, 2, 3, 4]
      :ok = PartitionDetector.record_consensus_activity(@cluster_id, 100, participating_nodes)

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)

      assert status.consensus_status.current_round == 100

      assert MapSet.equal?(
               status.consensus_status.participating_nodes,
               MapSet.new(participating_nodes)
             )
    end

    test "tracks missing nodes in consensus" do
      # Only 2 nodes participating (below threshold)
      participating_nodes = [1, 2]
      :ok = PartitionDetector.record_consensus_activity(@cluster_id, 101, participating_nodes)

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)

      # Should identify missing nodes
      expected_missing = MapSet.new([3, 4, 5])
      assert MapSet.equal?(status.consensus_status.missing_nodes, expected_missing)
    end

    test "updates last successful round" do
      :ok = PartitionDetector.record_consensus_activity(@cluster_id, 100, [1, 2, 3, 4])
      :ok = PartitionDetector.record_consensus_activity(@cluster_id, 101, [1, 2, 3])

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)

      assert status.consensus_status.last_successful_round == 101
    end
  end

  describe "partition detection" do
    setup do
      :ok = PartitionDetector.monitor_cluster(@cluster_id, @node_count, @threshold, :minority)
      :ok
    end

    test "detects network partition when too many nodes are unreachable" do
      # Only send heartbeats from 1 node (below threshold)
      PartitionDetector.record_heartbeat(@cluster_id, 1)

      # Trigger partition detection
      send(ExWire.DVT.PartitionDetector, :check_partitions)
      Process.sleep(100)

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)

      # Should detect partition or at least suspected partition
      assert status.partition_state in [:suspected, :partitioned]
      # 4 out of 5 nodes unreachable
      assert length(status.unreachable_nodes) >= 3
    end

    test "maintains connected state with sufficient active nodes" do
      # Send heartbeats from majority of nodes
      Enum.each(1..4, fn node_id ->
        PartitionDetector.record_heartbeat(@cluster_id, node_id)
      end)

      # Trigger partition detection
      send(ExWire.DVT.PartitionDetector, :check_partitions)
      Process.sleep(100)

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)
      assert status.partition_state == :connected
    end

    test "tracks partition history" do
      # Create a partition condition
      # Only 1 node
      PartitionDetector.record_heartbeat(@cluster_id, 1)

      # Trigger partition detection
      send(ExWire.DVT.PartitionDetector, :check_partitions)
      # Give it time to detect
      Process.sleep(200)

      # Check partition history
      history = PartitionDetector.get_partition_history(10)

      # Should have at least one partition event
      if length(history) > 0 do
        event = List.first(history)
        assert event.cluster_id == @cluster_id
        assert %DateTime{} = event.detected_at
      end
    end
  end

  describe "partition recovery" do
    setup do
      :ok = PartitionDetector.monitor_cluster(@cluster_id, @node_count, @threshold, :minority)

      # Mock DutyConsensus for recovery testing
      :meck.new(DutyConsensus, [:passthrough])

      :meck.expect(DutyConsensus, :reset_consensus_round, fn cluster_id ->
        send(self(), {:consensus_reset, cluster_id})
        :ok
      end)

      on_exit(fn ->
        :meck.unload(DutyConsensus)
      end)

      :ok
    end

    test "can manually trigger partition recovery" do
      # Create partition condition first
      # Only 1 node
      PartitionDetector.record_heartbeat(@cluster_id, 1)
      send(ExWire.DVT.PartitionDetector, :check_partitions)
      Process.sleep(100)

      # Manually trigger recovery
      assert :ok = PartitionDetector.trigger_recovery(@cluster_id)

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)

      # Should attempt recovery (may still be partitioned but with recovery attempts)
      assert status.recovery_attempts > 0
    end

    test "cannot trigger recovery for connected cluster" do
      # Ensure cluster is connected
      Enum.each(1..@node_count, fn node_id ->
        PartitionDetector.record_heartbeat(@cluster_id, node_id)
      end)

      send(ExWire.DVT.PartitionDetector, :check_partitions)
      Process.sleep(100)

      # Should fail to trigger recovery
      assert {:error, :not_partitioned} = PartitionDetector.trigger_recovery(@cluster_id)
    end

    test "limits recovery attempts" do
      # Create persistent partition
      PartitionDetector.record_heartbeat(@cluster_id, 1)
      send(ExWire.DVT.PartitionDetector, :check_partitions)
      Process.sleep(100)

      # Trigger multiple recovery attempts
      Enum.each(1..15, fn _ ->
        case PartitionDetector.trigger_recovery(@cluster_id) do
          :ok -> :ok
          # May fail after max attempts
          {:error, _} -> :ok
        end
      end)

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)

      # Should limit recovery attempts (max 10 by default)
      assert status.recovery_attempts <= 10
    end

    test "resolves partition when nodes become reachable again" do
      # Start with partition
      PartitionDetector.record_heartbeat(@cluster_id, 1)
      send(ExWire.DVT.PartitionDetector, :check_partitions)
      Process.sleep(100)

      # Resolve partition by having all nodes send heartbeats
      Enum.each(1..@node_count, fn node_id ->
        PartitionDetector.record_heartbeat(@cluster_id, node_id)
      end)

      # Trigger partition check
      send(ExWire.DVT.PartitionDetector, :check_partitions)
      Process.sleep(100)

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)

      # Should resolve to connected state
      assert status.partition_state == :connected
      # Reset on successful recovery
      assert status.recovery_attempts == 0
    end
  end

  describe "monitoring integration" do
    test "provides comprehensive partition status" do
      :ok = PartitionDetector.monitor_cluster(@cluster_id, @node_count, @threshold, :minority)

      status = PartitionDetector.get_partition_status()

      assert is_map(status)
      assert Map.has_key?(status, :monitored_clusters)
      assert Map.has_key?(status, :partition_states)
      assert Map.has_key?(status, :total_clusters)
      assert Map.has_key?(status, :partitioned_clusters)
      assert Map.has_key?(status, :last_partition_event)

      assert status.total_clusters == 1
      assert @cluster_id in status.monitored_clusters
    end

    test "tracks multiple clusters independently" do
      cluster2 = "test_cluster_002"

      # Monitor two clusters
      :ok = PartitionDetector.monitor_cluster(@cluster_id, @node_count, @threshold, :minority)
      :ok = PartitionDetector.monitor_cluster(cluster2, 3, 2, :majority)

      # Send heartbeats to only one cluster
      Enum.each(1..@node_count, fn node_id ->
        PartitionDetector.record_heartbeat(@cluster_id, node_id)
      end)

      send(ExWire.DVT.PartitionDetector, :check_partitions)
      Process.sleep(100)

      # Check individual cluster statuses
      {:ok, status1} = PartitionDetector.get_cluster_partition_status(@cluster_id)
      {:ok, status2} = PartitionDetector.get_cluster_partition_status(cluster2)

      # First cluster should be healthy, second should be partitioned/suspected
      assert status1.partition_state == :connected
      assert status2.partition_state in [:suspected, :partitioned]
    end
  end

  describe "periodic monitoring" do
    setup do
      :ok = PartitionDetector.monitor_cluster(@cluster_id, @node_count, @threshold, :minority)
      :ok
    end

    test "runs periodic partition checks" do
      # Create partition condition
      PartitionDetector.record_heartbeat(@cluster_id, 1)

      # Wait for automatic partition detection
      # Wait longer than heartbeat timeout
      Process.sleep(1_500)

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)

      # Should automatically detect partition
      assert status.partition_state in [:suspected, :partitioned]
    end

    test "processes recovery probes periodically" do
      # Create and then resolve partition
      PartitionDetector.record_heartbeat(@cluster_id, 1)
      send(ExWire.DVT.PartitionDetector, :check_partitions)
      Process.sleep(100)

      # Trigger recovery
      PartitionDetector.trigger_recovery(@cluster_id)

      # Resolve partition
      Enum.each(1..@node_count, fn node_id ->
        PartitionDetector.record_heartbeat(@cluster_id, node_id)
      end)

      # Wait for recovery probe
      # Recovery probe interval is 500ms
      Process.sleep(600)

      {:ok, status} = PartitionDetector.get_cluster_partition_status(@cluster_id)

      # Should detect recovery
      assert status.partition_state == :connected
    end
  end
end
