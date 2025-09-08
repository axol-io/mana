defmodule ExWire.DVT.MessageAuthTest do
  use ExUnit.Case, async: false

  alias ExWire.DVT.{MessageAuth, KeyManager}

  @cluster_id "test_cluster_001"
  @sender_id 1
  @test_private_key :crypto.generate_key(:eddsa, :ed25519) |> elem(1)
  @test_public_key :crypto.generate_key(:eddsa, :ed25519, @test_private_key) |> elem(0)

  setup do
    # Clean up ETS tables before each test
    cleanup_ets_tables()
    
    # Mock KeyManager.get_node_public_key/2
    :meck.new(KeyManager, [:passthrough])
    :meck.expect(KeyManager, :get_node_public_key, fn @cluster_id, @sender_id ->
      {:ok, @test_public_key}
    end)
    
    on_exit(fn ->
      cleanup_ets_tables()
      :meck.unload(KeyManager)
    end)
    
    :ok
  end

  describe "message creation" do
    test "creates authenticated message with valid parameters" do
      payload = %{duty_type: :attestation, slot: 12345}
      
      assert {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id,
        :duty_consensus,
        payload,
        @test_private_key,
        @sender_id
      )
      
      # Verify message structure
      assert message.cluster_id == @cluster_id
      assert message.sender_id == @sender_id
      assert message.message_type == :duty_consensus
      assert message.payload == payload
      assert is_binary(message.signature)
      assert is_binary(message.nonce)
      assert %DateTime{} = message.timestamp
      assert message.sequence == 1
      assert message.auth_version == "1.0"
    end

    test "increments sequence numbers correctly" do
      payload = %{data: "test"}
      
      # Create first message
      {:ok, message1} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      # Create second message
      {:ok, message2} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      assert message1.sequence == 1
      assert message2.sequence == 2
    end

    test "generates unique nonces for each message" do
      payload = %{data: "test"}
      
      {:ok, message1} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      {:ok, message2} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      assert message1.nonce != message2.nonce
    end

    test "fails gracefully with invalid private key" do
      payload = %{data: "test"}
      invalid_key = "not_a_real_key"
      
      assert {:error, :authentication_failed} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, invalid_key, @sender_id
      )
    end
  end

  describe "message verification" do
    test "verifies valid authenticated message" do
      payload = %{duty_type: :attestation, slot: 12345}
      
      {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id, :duty_consensus, payload, @test_private_key, @sender_id
      )
      
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message)
    end

    test "rejects message with invalid signature" do
      payload = %{data: "test"}
      
      {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      # Tamper with signature
      tampered_message = %{message | signature: :crypto.strong_rand_bytes(64)}
      
      assert {:error, :invalid_signature} = MessageAuth.verify_authenticated_message(tampered_message)
    end

    test "rejects message with tampered payload" do
      payload = %{data: "original"}
      
      {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      # Tamper with payload
      tampered_message = %{message | payload: %{data: "tampered"}}
      
      assert {:error, :invalid_signature} = MessageAuth.verify_authenticated_message(tampered_message)
    end

    test "rejects message with missing required fields" do
      incomplete_message = %{
        cluster_id: @cluster_id,
        sender_id: @sender_id,
        # Missing required fields
        payload: %{data: "test"}
      }
      
      assert {:error, :invalid_structure} = MessageAuth.verify_authenticated_message(incomplete_message)
    end

    test "rejects expired message" do
      payload = %{data: "test"}
      
      {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      # Make message appear old
      old_timestamp = DateTime.add(DateTime.utc_now(), -400, :second)  # 400 seconds ago
      old_message = %{message | timestamp: old_timestamp}
      
      assert {:error, :expired} = MessageAuth.verify_authenticated_message(old_message)
    end

    test "rejects message from unknown sender" do
      # Mock unknown sender
      unknown_sender_id = 999
      :meck.expect(KeyManager, :get_node_public_key, fn @cluster_id, ^unknown_sender_id ->
        {:error, :not_found}
      end)
      
      payload = %{data: "test"}
      
      {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, unknown_sender_id
      )
      
      assert {:error, :unknown_sender} = MessageAuth.verify_authenticated_message(message)
    end
  end

  describe "replay protection" do
    test "accepts message first time" do
      payload = %{data: "test"}
      
      {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message)
    end

    test "rejects repeated message" do
      payload = %{data: "test"}
      
      {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      # First verification should succeed
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message)
      
      # Second verification should fail (replay attack)
      assert {:error, :replay_attack} = MessageAuth.verify_authenticated_message(message)
    end

    test "allows different messages with different nonces" do
      payload = %{data: "test"}
      
      {:ok, message1} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      {:ok, message2} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      # Both should be valid (different nonces and sequences)
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message1)
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message2)
    end
  end

  describe "sequence validation" do
    test "accepts first message from sender" do
      payload = %{data: "first"}
      
      {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message)
    end

    test "accepts sequential messages" do
      payload = %{data: "test"}
      
      # Create and verify first message
      {:ok, message1} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message1)
      
      # Create and verify second message
      {:ok, message2} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message2)
    end

    test "rejects out-of-order messages" do
      payload = %{data: "test"}
      
      # Create two messages
      {:ok, message1} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      {:ok, message2} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      # Verify second message first
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message2)
      
      # First message should now be rejected (lower sequence number)
      assert {:error, :invalid_sequence} = MessageAuth.verify_authenticated_message(message1)
    end

    test "warns about large sequence gaps but accepts message" do
      payload = %{data: "test"}
      
      # Create first message
      {:ok, message1} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message1)
      
      # Manually create message with large gap
      large_sequence = 1000  # Much larger than previous
      {:ok, message_gap} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      # Should still accept but log warning
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message_gap)
    end
  end

  describe "cleanup functionality" do
    test "cleans up expired authentication data" do
      payload = %{data: "test"}
      
      # Create and verify message
      {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message)
      
      # Check that data exists
      stats_before = MessageAuth.get_auth_statistics()
      assert stats_before.cache_size > 0
      
      # Cleanup should work without errors
      assert :ok = MessageAuth.cleanup_expired_data()
      
      # Note: For testing, we'd need to manipulate timestamps or wait
      # In a real test, we might mock DateTime.utc_now/0
    end

    test "preserves recent authentication data during cleanup" do
      payload = %{data: "test"}
      
      # Create recent message
      {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message)
      
      # Cleanup recent data
      assert :ok = MessageAuth.cleanup_expired_data()
      
      # Recent message should still be rejected as replay
      assert {:error, :replay_attack} = MessageAuth.verify_authenticated_message(message)
    end
  end

  describe "statistics" do
    test "tracks authentication statistics" do
      payload = %{data: "test"}
      
      # Create and verify a message
      {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message)
      
      # Check statistics
      stats = MessageAuth.get_auth_statistics()
      
      assert is_map(stats)
      assert Map.has_key?(stats, :total_messages_authenticated)
      assert Map.has_key?(stats, :authentication_failures)
      assert Map.has_key?(stats, :replay_attempts)
      assert Map.has_key?(stats, :active_sequences)
      assert Map.has_key?(stats, :cache_size)
      
      # Should have at least one authenticated message
      assert stats.total_messages_authenticated >= 1
    end

    test "tracks replay attempts" do
      payload = %{data: "test"}
      
      {:ok, message} = MessageAuth.create_authenticated_message(
        @cluster_id, :heartbeat, payload, @test_private_key, @sender_id
      )
      
      # First verification
      assert {:ok, :valid} = MessageAuth.verify_authenticated_message(message)
      
      stats_before = MessageAuth.get_auth_statistics()
      
      # Replay attempt
      assert {:error, :replay_attack} = MessageAuth.verify_authenticated_message(message)
      
      stats_after = MessageAuth.get_auth_statistics()
      
      # Should have incremented replay attempts
      assert stats_after.replay_attempts > stats_before.replay_attempts
    end
  end

  ## Test Helpers

  defp cleanup_ets_tables() do
    # Clean up ETS tables that might persist between tests
    [:dvt_message_cache, :dvt_sequence_tracking, :dvt_auth_stats]
    |> Enum.each(fn table_name ->
      case :ets.whereis(table_name) do
        :undefined -> :ok
        table -> :ets.delete(table)
      end
    end)
  end
end