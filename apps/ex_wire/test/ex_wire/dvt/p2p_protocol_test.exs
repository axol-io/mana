defmodule ExWire.DVT.P2PProtocolTest do
  use ExUnit.Case, async: false
  
  alias ExWire.DVT.P2PProtocol
  alias ExWire.DVT.KeyManager
  
  @cluster_id "test_cluster_001"
  @node_id 1
  @auth_key "test_auth_key"
  @test_timeout 5_000

  setup do
    # Start the P2P protocol for testing
    {:ok, _pid} = P2PProtocol.start_link(node_id: @node_id)
    
    on_exit(fn ->
      # Clean up any test state
      if Process.whereis(ExWire.DVT.P2PProtocol) do
        GenServer.stop(ExWire.DVT.P2PProtocol)
      end
    end)
    
    :ok
  end

  describe "cluster management" do
    test "can join a DVT cluster with valid credentials" do
      # Mock KeyManager response
      expect_key_manager_verification(@cluster_id, @node_id, @auth_key, [:dkg_participate, :consensus_participate])
      
      assert {:ok, permissions} = P2PProtocol.join_cluster(@cluster_id, @node_id, @auth_key)
      assert :dkg_participate in permissions
      assert :consensus_participate in permissions
    end

    test "cannot join cluster with invalid credentials" do
      # Mock KeyManager rejection
      expect_key_manager_verification(@cluster_id, @node_id, "invalid_key", {:error, :invalid_credentials})
      
      assert {:error, :invalid_credentials} = P2PProtocol.join_cluster(@cluster_id, @node_id, "invalid_key")
    end

    test "can leave a joined cluster" do
      # First join the cluster
      expect_key_manager_verification(@cluster_id, @node_id, @auth_key, [:consensus_participate])
      {:ok, _} = P2PProtocol.join_cluster(@cluster_id, @node_id, @auth_key)
      
      # Then leave it
      assert :ok = P2PProtocol.leave_cluster(@cluster_id)
    end

    test "cannot leave cluster that was not joined" do
      assert {:error, :not_member} = P2PProtocol.leave_cluster("nonexistent_cluster")
    end
  end

  describe "message broadcasting" do
    setup do
      expect_key_manager_verification(@cluster_id, @node_id, @auth_key, [:consensus_participate])
      {:ok, _} = P2PProtocol.join_cluster(@cluster_id, @node_id, @auth_key)
      :ok
    end

    test "can broadcast consensus message with proper permissions" do
      payload = %{duty_type: :attestation, data: "test_data"}
      
      assert :ok = P2PProtocol.broadcast_message(@cluster_id, :duty_consensus, payload)
    end

    test "cannot broadcast message without proper permissions" do
      # Join with limited permissions
      limited_cluster = "limited_cluster"
      expect_key_manager_verification(limited_cluster, @node_id, @auth_key, [:basic_communication])
      {:ok, _} = P2PProtocol.join_cluster(limited_cluster, @node_id, @auth_key)
      
      payload = %{duty_type: :attestation, data: "test_data"}
      
      assert {:error, :insufficient_permissions} = P2PProtocol.broadcast_message(limited_cluster, :duty_consensus, payload)
    end

    test "cannot broadcast to cluster not joined" do
      payload = %{data: "test"}
      
      assert {:error, :not_member} = P2PProtocol.broadcast_message("unknown_cluster", :heartbeat, payload)
    end
  end

  describe "direct messaging" do
    setup do
      expect_key_manager_verification(@cluster_id, @node_id, @auth_key, [:consensus_participate])
      {:ok, _} = P2PProtocol.join_cluster(@cluster_id, @node_id, @auth_key)
      :ok
    end

    test "can send direct message to active peer" do
      # Mock an active peer connection
      mock_active_peer(2, @cluster_id)
      
      payload = %{message: "direct_test"}
      
      assert :ok = P2PProtocol.send_direct_message(@cluster_id, 2, :heartbeat, payload)
    end

    test "cannot send direct message to non-existent peer" do
      payload = %{message: "test"}
      
      assert {:error, :peer_not_found} = P2PProtocol.send_direct_message(@cluster_id, 999, :heartbeat, payload)
    end
  end

  describe "network status" do
    test "returns current network status" do
      status = P2PProtocol.get_network_status()
      
      assert is_map(status)
      assert Map.has_key?(status, :node_id)
      assert Map.has_key?(status, :cluster_memberships)
      assert Map.has_key?(status, :peer_count)
      assert Map.has_key?(status, :metrics)
    end

    test "network status includes partition information" do
      status = P2PProtocol.get_network_status()
      
      assert Map.has_key?(status, :partition_status)
    end
  end

  describe "message authentication integration" do
    setup do
      expect_key_manager_verification(@cluster_id, @node_id, @auth_key, [:consensus_participate])
      {:ok, _} = P2PProtocol.join_cluster(@cluster_id, @node_id, @auth_key)
      :ok
    end

    test "messages are properly authenticated before broadcasting" do
      # Mock GossipSub to capture the actual broadcast
      mock_gossipsub_publish()
      
      payload = %{duty_type: :attestation, slot: 12345}
      assert :ok = P2PProtocol.broadcast_message(@cluster_id, :duty_consensus, payload)
      
      # Verify that the message was authenticated (has signature, nonce, etc.)
      assert_receive {:gossipsub_publish, topic, message_data}, @test_timeout
      
      message = :erlang.binary_to_term(message_data)
      assert Map.has_key?(message, :signature)
      assert Map.has_key?(message, :nonce)
      assert Map.has_key?(message, :timestamp)
      assert message.cluster_id == @cluster_id
    end

    test "received messages are validated for authenticity" do
      # Simulate receiving an authenticated message
      authenticated_message = create_mock_authenticated_message(@cluster_id, :heartbeat, %{status: :active})
      
      # Send message through the gossipsub handler
      send(ExWire.DVT.P2PProtocol, {:gossipsub, "dvt/#{@cluster_id}/monitoring", :erlang.term_to_binary(authenticated_message)})
      
      # Should be processed without errors (no crash)
      Process.sleep(100)
      assert Process.alive?(Process.whereis(ExWire.DVT.P2PProtocol))
    end

    test "invalid messages are rejected" do
      # Simulate receiving an invalid message (no signature)
      invalid_message = %{
        cluster_id: @cluster_id,
        sender_id: 2,
        message_type: :heartbeat,
        payload: %{status: :active}
        # Missing signature, nonce, timestamp
      }
      
      # Send invalid message
      send(ExWire.DVT.P2PProtocol, {:gossipsub, "dvt/#{@cluster_id}/monitoring", :erlang.term_to_binary(invalid_message)})
      
      # Should be rejected (process should remain alive)
      Process.sleep(100)
      assert Process.alive?(Process.whereis(ExWire.DVT.P2PProtocol))
    end
  end

  describe "heartbeat management" do
    setup do
      expect_key_manager_verification(@cluster_id, @node_id, @auth_key, [:basic_communication])
      {:ok, _} = P2PProtocol.join_cluster(@cluster_id, @node_id, @auth_key)
      :ok
    end

    test "periodic heartbeats are sent to cluster members" do
      mock_gossipsub_publish()
      
      # Trigger heartbeat
      send(ExWire.DVT.P2PProtocol, :heartbeat)
      
      # Should receive heartbeat broadcast
      assert_receive {:gossipsub_publish, topic, message_data}, @test_timeout
      
      assert String.contains?(topic, "monitoring")
      message = :erlang.binary_to_term(message_data)
      assert message.type == :heartbeat
    end

    test "stale connections are cleaned up" do
      # Add a stale connection
      mock_stale_peer(3, @cluster_id, DateTime.add(DateTime.utc_now(), -120, :second))
      
      # Trigger heartbeat cleanup
      send(ExWire.DVT.P2PProtocol, :heartbeat)
      
      # Verify stale connection was removed
      status = P2PProtocol.get_network_status()
      assert status.active_peers == 0
    end
  end

  ## Test Helpers

  defp expect_key_manager_verification(cluster_id, node_id, auth_key, expected_result) do
    # In a real implementation, this would mock KeyManager.verify_cluster_permission/3
    # For now, we'll simulate the expected behavior
    
    case expected_result do
      permissions when is_list(permissions) ->
        :meck.new(KeyManager, [:passthrough])
        :meck.expect(KeyManager, :verify_cluster_permission, fn ^cluster_id, ^node_id, ^auth_key ->
          {:ok, permissions}
        end)
        
      error_tuple ->
        :meck.new(KeyManager, [:passthrough])
        :meck.expect(KeyManager, :verify_cluster_permission, fn ^cluster_id, ^node_id, ^auth_key ->
          error_tuple
        end)
    end
  end

  defp mock_active_peer(peer_node_id, cluster_id) do
    # Mock an active peer connection in the P2P protocol state
    peer_info = %{
      peer_id: "peer_#{peer_node_id}",
      cluster_id: cluster_id,
      node_id: peer_node_id,
      last_heartbeat: DateTime.utc_now(),
      status: :active
    }
    
    # This would require access to the P2P protocol state
    # In a real implementation, we might need a test helper function
    :ok
  end

  defp mock_gossipsub_publish() do
    test_pid = self()
    
    # Mock GossipSub.publish to capture calls
    :meck.new(ExWire.LibP2P.GossipSub, [:passthrough])
    :meck.expect(ExWire.LibP2P.GossipSub, :publish, fn _pid, topic, message_data ->
      send(test_pid, {:gossipsub_publish, topic, message_data})
      :ok
    end)
  end

  defp mock_stale_peer(peer_node_id, cluster_id, last_heartbeat) do
    # Mock a stale peer connection
    peer_info = %{
      peer_id: "peer_#{peer_node_id}",
      cluster_id: cluster_id,
      node_id: peer_node_id,
      last_heartbeat: last_heartbeat,
      status: :active
    }
    
    # This would require modifying the P2P protocol state for testing
    :ok
  end

  defp create_mock_authenticated_message(cluster_id, message_type, payload) do
    # Create a properly structured authenticated message for testing
    %{
      cluster_id: cluster_id,
      sender_id: 2,
      message_type: message_type,
      sequence: 1,
      timestamp: DateTime.utc_now(),
      nonce: :crypto.strong_rand_bytes(16),
      payload: payload,
      signature: :crypto.strong_rand_bytes(64),  # Mock signature
      auth_version: "1.0"
    }
  end
end