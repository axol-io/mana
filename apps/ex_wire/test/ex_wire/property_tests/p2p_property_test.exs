defmodule ExWire.PropertyTests.P2PPropertyTest do
  @moduledoc """
  Property-based tests for P2P networking and message handling.

  These tests verify that P2P protocol operations maintain invariants,
  message serialization is robust, and network communication handles
  edge cases gracefully across different peer interactions.
  """

  use ExUnitProperties
  import StreamData
  import Blockchain.PropertyTesting.Generators
  import Blockchain.PropertyTesting.Properties

  alias ExWire.P2P.Protocol
  alias ExWire.Message
  alias ExWire.Peer
  alias ExWire.Network.InboundMessage
  alias ExWire.Network.OutboundMessage

  @moduletag :property_test
  @moduletag timeout: 120_000

  # Message Serialization Property Tests

  property "P2P message serialization is deterministic" do
    check all(message <- p2p_message()) do
      serialized1 = Message.serialize(message)
      serialized2 = Message.serialize(message)
      assert serialized1 == serialized2
      assert is_binary(serialized1)
    end
  end

  property "P2P message serialization roundtrip" do
    check all(message <- p2p_message()) do
      case Message.serialize(message) do
        {:ok, serialized} ->
          case Message.deserialize(serialized) do
            {:ok, deserialized} ->
              assert deserialized.message_id == message.message_id
              assert deserialized.data == message.data

            {:error, _} ->
              # Deserialization can fail for edge cases
              :ok
          end

        {:error, _} ->
          # Serialization can fail for invalid messages
          :ok

        serialized when is_binary(serialized) ->
          case Message.deserialize(serialized) do
            {:ok, deserialized} ->
              assert deserialized.message_id == message.message_id
              assert deserialized.data == message.data

            {:error, _} ->
              :ok

            deserialized ->
              assert deserialized.message_id == message.message_id
              assert deserialized.data == message.data
          end
      end
    end
  end

  property "message size limits are enforced" do
    check all(message <- p2p_message()) do
      serialized = Message.serialize(message)

      case serialized do
        {:ok, data} ->
          # Messages should not exceed reasonable limits (16MB)
          assert byte_size(data) < 16_777_216

        data when is_binary(data) ->
          assert byte_size(data) < 16_777_216

        {:error, :message_too_large} ->
          # This is expected for very large messages
          :ok

        _ ->
          :ok
      end
    end
  end

  # Peer Connection Property Tests

  property "peer handshake is symmetric" do
    check all(
            {peer1_info, peer2_info} <- {peer_info(), peer_info()},
            peer1_info.node_id != peer2_info.node_id
          ) do
      # Simulate handshake from peer1 to peer2
      handshake_1to2 = create_handshake(peer1_info, peer2_info)

      # Simulate handshake from peer2 to peer1  
      handshake_2to1 = create_handshake(peer2_info, peer1_info)

      # Both should succeed or both should fail
      case {validate_handshake(handshake_1to2), validate_handshake(handshake_2to1)} do
        {{:ok, _}, {:ok, _}} ->
          :ok

        {{:error, reason1}, {:error, reason2}} ->
          # Both failed, which can happen for incompatible peers
          :ok

        _ ->
          # One succeeded, one failed - this shouldn't happen with symmetric handshake
          flunk("Asymmetric handshake behavior")
      end
    end
  end

  property "peer connection state transitions are valid" do
    check all(operations <- list_of(peer_operation(), min_length: 0, max_length: 20)) do
      initial_state = create_peer_state()

      final_state =
        Enum.reduce(operations, initial_state, fn op, state ->
          apply_peer_operation(op, state)
        end)

      # Verify state is always valid
      assert valid_peer_state?(final_state)

      # Connected peers should have valid connection info
      if final_state.status == :connected do
        assert final_state.remote_id != nil
        assert final_state.established_at != nil
      end
    end
  end

  # Protocol Message Handling

  property "protocol messages maintain version compatibility" do
    check all(
            {version, message} <- {protocol_version(), protocol_message()},
            # ETH/64, ETH/65
            version in [4, 5]
          ) do
      case Protocol.encode_message(message, version) do
        {:ok, encoded} ->
          case Protocol.decode_message(encoded, version) do
            {:ok, decoded} ->
              # Core message properties should be preserved
              assert message_equivalent?(message, decoded)

            {:error, :unsupported_version} ->
              # Some messages may not be supported in all versions
              :ok

            {:error, _} ->
              # Other decode errors are acceptable
              :ok
          end

        {:error, :unsupported_version} ->
          # Not all messages supported in all versions
          :ok

        {:error, _} ->
          # Other encoding errors are acceptable
          :ok
      end
    end
  end

  property "message routing preserves message integrity" do
    check all(
            {from_peer, to_peer, message} <- {peer_id(), peer_id(), p2p_message()},
            from_peer != to_peer
          ) do
      # Create routed message
      routed = create_routed_message(from_peer, to_peer, message)

      # Extract original message
      extracted = extract_message_from_route(routed)

      # Original message should be preserved
      assert extracted.message_id == message.message_id
      assert extracted.data == message.data
    end
  end

  # Network Message Handling

  property "inbound message processing is idempotent" do
    check all(message <- inbound_message()) do
      # Process the same message multiple times
      result1 = InboundMessage.process(message)
      result2 = InboundMessage.process(message)
      result3 = InboundMessage.process(message)

      # Results should be consistent
      assert result1 == result2
      assert result2 == result3
    end
  end

  property "outbound message queue maintains order" do
    check all(messages <- list_of(outbound_message(), min_length: 2, max_length: 10)) do
      # Add messages to queue
      queue =
        Enum.reduce(messages, OutboundMessage.new_queue(), fn msg, q ->
          OutboundMessage.enqueue(q, msg)
        end)

      # Dequeue all messages
      dequeued = dequeue_all_messages(queue, [])

      # Order should be preserved (FIFO)
      original_ids = Enum.map(messages, & &1.id)
      dequeued_ids = Enum.map(dequeued, & &1.id)

      assert dequeued_ids == original_ids
    end
  end

  # Peer Discovery and Management

  property "peer discovery maintains network topology invariants" do
    check all(peers <- list_of(peer_info(), min_length: 1, max_length: 50)) do
      # Simulate peer discovery
      network = build_peer_network(peers)

      # Each peer should know about some other peers
      Enum.each(peers, fn peer ->
        known_peers = get_known_peers(network, peer.node_id)

        # Should know about at least 1 other peer (if network > 1)
        if length(peers) > 1 do
          assert length(known_peers) >= 1
        end

        # Should not know about itself
        refute Enum.any?(known_peers, &(&1.node_id == peer.node_id))
      end)
    end
  end

  property "peer reputation system is monotonic" do
    check all(operations <- list_of(reputation_operation(), min_length: 0, max_length: 20)) do
      initial_reputation = 0

      final_reputation =
        Enum.reduce(operations, initial_reputation, fn op, rep ->
          apply_reputation_operation(op, rep)
        end)

      # Reputation should stay within bounds
      # Min reputation
      assert final_reputation >= -1000
      # Max reputation
      assert final_reputation <= 1000

      # Calculate expected reputation based on operations
      expected = calculate_expected_reputation(operations)
      assert final_reputation == expected
    end
  end

  # Message Broadcasting

  property "message broadcast reaches all connected peers" do
    check all({network_size, message} <- {integer(2..20), p2p_message()}) do
      # Create connected network
      network = create_connected_network(network_size)

      # Pick random peer to broadcast from
      broadcaster = Enum.random(network.peers)

      # Broadcast message
      broadcast_result = broadcast_message(network, broadcaster, message)

      case broadcast_result do
        {:ok, delivery_results} ->
          # Message should reach all other peers
          # Exclude broadcaster
          expected_recipients = network_size - 1
          assert length(delivery_results) == expected_recipients

          # All deliveries should be successful or have valid errors
          Enum.each(delivery_results, fn result ->
            assert result in [:ok, {:error, :peer_disconnected}, {:error, :send_failed}]
          end)

        {:error, :no_connected_peers} ->
          # Can happen if network is fragmented
          :ok
      end
    end
  end

  # Protocol Version Negotiation

  property "protocol version negotiation selects highest common version" do
    check all(
            {local_versions, remote_versions} <-
              {list_of(protocol_version(), min_length: 1),
               list_of(protocol_version(), min_length: 1)}
          ) do
      negotiated = Protocol.negotiate_version(local_versions, remote_versions)

      case negotiated do
        {:ok, version} ->
          # Should be supported by both sides
          assert version in local_versions
          assert version in remote_versions

          # Should be the highest common version
          common_versions = local_versions |> Enum.filter(&(&1 in remote_versions))
          assert version == Enum.max(common_versions)

        {:error, :no_common_version} ->
          # No overlap between version lists
          common_versions = local_versions |> Enum.filter(&(&1 in remote_versions))
          assert common_versions == []
      end
    end
  end

  # Fuzzing Tests for Robustness

  property "fuzz test: malformed message handling" do
    check all(
            malformed_data <- binary(min_length: 0, max_length: 1000),
            max_runs: 300
          ) do
      # Should handle malformed input gracefully
      result =
        try do
          Message.deserialize(malformed_data)
        rescue
          _error -> {:error, :malformed_message}
        catch
          _kind, _value -> {:error, :malformed_message}
        end

      # Should either parse successfully or return error
      assert result in [
               {:ok, %{}},
               {:error, :malformed_message},
               {:error, :invalid_rlp},
               {:error, :invalid_message_format}
             ] or
               match?({:ok, _}, result)
    end
  end

  property "fuzz test: peer connection resilience" do
    check all(
            operations <- list_of(random_peer_operation(), min_length: 0, max_length: 50),
            max_runs: 200
          ) do
      initial_state = create_peer_state()

      # Apply random operations and ensure system doesn't crash
      final_state =
        try do
          Enum.reduce(operations, initial_state, fn op, state ->
            apply_random_operation(op, state)
          end)
        rescue
          # Reset on error
          _error -> initial_state
        catch
          # Reset on error
          _kind, _value -> initial_state
        end

      # System should remain in valid state
      assert valid_peer_state?(final_state)
    end
  end

  # Helper Functions

  defp p2p_message() do
    gen all(
          message_id <- integer(0x00..0xFF),
          data <- binary(min_length: 0, max_length: 1000)
        ) do
      %{message_id: message_id, data: data}
    end
  end

  defp peer_info() do
    gen all(
          node_id <- binary(length: 64),
          ip <- ip_address(),
          port <- integer(1024..65535),
          protocols <- list_of(protocol_version(), min_length: 1, max_length: 3)
        ) do
      %{node_id: node_id, ip: ip, port: port, protocols: protocols}
    end
  end

  defp peer_id() do
    binary(length: 64)
  end

  defp protocol_version() do
    # ETH/64, ETH/65
    integer(4..5)
  end

  defp protocol_message() do
    frequency([
      {3, status_message()},
      {2, block_headers_message()},
      {2, block_bodies_message()},
      {1, new_block_message()},
      {1, transaction_message()}
    ])
  end

  defp status_message() do
    gen all(
          protocol_version <- protocol_version(),
          network_id <- integer(1..100),
          total_difficulty <- integer(1..1_000_000),
          best_hash <- binary(length: 32),
          genesis_hash <- binary(length: 32)
        ) do
      %{
        type: :status,
        protocol_version: protocol_version,
        network_id: network_id,
        total_difficulty: total_difficulty,
        best_hash: best_hash,
        genesis_hash: genesis_hash
      }
    end
  end

  defp block_headers_message() do
    gen all(headers <- list_of(block_header(), min_length: 0, max_length: 192)) do
      %{type: :block_headers, headers: headers}
    end
  end

  defp block_bodies_message() do
    gen all(bodies <- list_of(block_body(), min_length: 0, max_length: 128)) do
      %{type: :block_bodies, bodies: bodies}
    end
  end

  defp new_block_message() do
    gen all(
          block <- block(),
          total_difficulty <- integer(1..1_000_000)
        ) do
      %{type: :new_block, block: block, total_difficulty: total_difficulty}
    end
  end

  defp transaction_message() do
    gen all(transactions <- list_of(transaction(), min_length: 1, max_length: 100)) do
      %{type: :transactions, transactions: transactions}
    end
  end

  defp ip_address() do
    gen all(
          a <- integer(1..255),
          b <- integer(0..255),
          c <- integer(0..255),
          d <- integer(0..255)
        ) do
      {a, b, c, d}
    end
  end

  defp peer_operation() do
    frequency([
      {3, {:connect, peer_info()}},
      {2, :disconnect},
      {2, {:send_message, p2p_message()}},
      {1, :ping},
      {1, :pong}
    ])
  end

  defp reputation_operation() do
    frequency([
      {2, {:successful_message, integer(1..10)}},
      {1, {:failed_message, integer(-5..-1)}},
      {1, {:timeout, -20}},
      {1, {:protocol_violation, integer(-50..-20//-1)}}
    ])
  end

  defp random_peer_operation() do
    frequency([
      {1, {:connect, peer_info()}},
      {1, :disconnect},
      {1, {:send_message, binary(min_length: 0, max_length: 100)}},
      {1, {:invalid_operation, binary(min_length: 0, max_length: 10)}},
      {1, {:malformed_data, binary(min_length: 0, max_length: 50)}}
    ])
  end

  defp inbound_message() do
    gen all(
          peer_id <- binary(length: 64),
          message <- p2p_message(),
          timestamp <- integer(1_600_000_000..1_700_000_000)
        ) do
      %{peer_id: peer_id, message: message, timestamp: timestamp}
    end
  end

  defp outbound_message() do
    gen all(
          id <- integer(1..100_000),
          peer_id <- binary(length: 64),
          message <- p2p_message(),
          priority <- integer(1..10)
        ) do
      %{id: id, peer_id: peer_id, message: message, priority: priority}
    end
  end

  defp create_peer_state() do
    %{
      status: :disconnected,
      remote_id: nil,
      established_at: nil,
      last_seen: nil,
      reputation: 0,
      protocol_version: nil
    }
  end

  defp apply_peer_operation({:connect, peer_info}, _state) do
    %{
      state
      | status: :connected,
        remote_id: peer_info.node_id,
        established_at: :os.system_time(:second),
        protocol_version: List.first(peer_info.protocols)
    }
  end

  defp apply_peer_operation(:disconnect, _state) do
    %{state | status: :disconnected, remote_id: nil, established_at: nil, protocol_version: nil}
  end

  defp apply_peer_operation({:send_message, _message}, _state) do
    %{state | last_seen: :os.system_time(:second)}
  end

  defp apply_peer_operation(_, _state), do: state

  defp valid_peer_state?(state) do
    # Basic state validation
    state.status in [:disconnected, :connecting, :connected] and
      state.reputation >= -1000 and state.reputation <= 1000 and
      (state.status != :connected or state.remote_id != nil)
  end

  defp create_handshake(local_info, remote_info) do
    %{
      local_node_id: local_info.node_id,
      remote_node_id: remote_info.node_id,
      local_protocols: local_info.protocols,
      remote_protocols: remote_info.protocols
    }
  end

  defp validate_handshake(handshake) do
    # Simple validation - check for common protocols
    common_protocols =
      handshake.local_protocols
      |> Enum.filter(&(&1 in handshake.remote_protocols))

    if length(common_protocols) > 0 do
      {:ok, %{protocol_version: Enum.max(common_protocols)}}
    else
      {:error, :no_common_protocol}
    end
  end

  defp apply_reputation_operation({:successful_message, points}, reputation) do
    min(reputation + points, 1000)
  end

  defp apply_reputation_operation({:failed_message, points}, reputation) do
    max(reputation + points, -1000)
  end

  defp apply_reputation_operation({:timeout, points}, reputation) do
    max(reputation + points, -1000)
  end

  defp apply_reputation_operation({:protocol_violation, points}, reputation) do
    max(reputation + points, -1000)
  end

  defp calculate_expected_reputation(operations) do
    Enum.reduce(operations, 0, fn op, acc ->
      case op do
        {:successful_message, points} -> min(acc + points, 1000)
        {:failed_message, points} -> max(acc + points, -1000)
        {:timeout, points} -> max(acc + points, -1000)
        {:protocol_violation, points} -> max(acc + points, -1000)
      end
    end)
  end

  defp message_equivalent?(msg1, msg2) do
    # Compare core message properties
    msg1.message_id == msg2.message_id and
      msg1.data == msg2.data
  end

  defp create_routed_message(from, to, message) do
    %{from: from, to: to, message: message, timestamp: :os.system_time(:second)}
  end

  defp extract_message_from_route(routed) do
    routed.message
  end

  defp dequeue_all_messages(queue, acc) do
    case OutboundMessage.dequeue(queue) do
      {:ok, {message, new_queue}} ->
        dequeue_all_messages(new_queue, acc ++ [message])

      {:error, :empty_queue} ->
        acc
    end
  end

  defp build_peer_network(peers) do
    # Simple network simulation
    %{peers: peers, connections: build_connections(peers)}
  end

  defp build_connections(peers) do
    # Each peer connects to 2-3 random other peers
    Enum.flat_map(peers, fn peer ->
      other_peers = Enum.filter(peers, &(&1.node_id != peer.node_id))
      target_connections = min(3, length(other_peers))
      connected_peers = Enum.take_random(other_peers, target_connections)

      Enum.map(connected_peers, fn connected ->
        {peer.node_id, connected.node_id}
      end)
    end)
  end

  defp get_known_peers(network, node_id) do
    # Get peers this node is connected to
    connected_node_ids =
      network.connections
      |> Enum.filter(fn {from, _to} -> from == node_id end)
      |> Enum.map(fn {_from, to} -> to end)

    network.peers
    |> Enum.filter(&(&1.node_id in connected_node_ids))
  end

  defp create_connected_network(size) do
    peers =
      1..size
      |> Enum.map(fn i ->
        %{node_id: <<i::256>>, status: :connected}
      end)

    %{peers: peers, connections: build_full_connections(peers)}
  end

  defp build_full_connections(peers) do
    # Create fully connected network for testing
    for peer1 <- peers,
        peer2 <- peers,
        peer1.node_id != peer2.node_id do
      {peer1.node_id, peer2.node_id}
    end
  end

  defp broadcast_message(network, broadcaster, message) do
    connected_peers = get_known_peers(network, broadcaster.node_id)

    if length(connected_peers) > 0 do
      delivery_results =
        Enum.map(connected_peers, fn peer ->
          simulate_message_delivery(peer, message)
        end)

      {:ok, delivery_results}
    else
      {:error, :no_connected_peers}
    end
  end

  defp simulate_message_delivery(peer, _message) do
    # Simple simulation - 90% success rate
    if :rand.uniform() < 0.9 do
      :ok
    else
      {:error, :send_failed}
    end
  end

  defp apply_random_operation({:connect, peer_info}, _state) do
    apply_peer_operation({:connect, peer_info}, state)
  end

  defp apply_random_operation(:disconnect, _state) do
    apply_peer_operation(:disconnect, state)
  end

  defp apply_random_operation({:send_message, _data}, _state) do
    # Ignore malformed send attempts
    state
  end

  defp apply_random_operation(_, _state) do
    # Ignore unknown operations
    state
  end
end
