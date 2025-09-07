defmodule ExWire.DVT.P2PProtocol do
  @moduledoc """
  DVT-specific LibP2P protocol implementation for secure operator communication.

  Provides specialized sub-protocols for DVT coordination:
  - Key generation ceremonies
  - Duty consensus messages
  - Slashing protection coordination
  - Performance monitoring
  """

  use GenServer
  require Logger

  alias ExWire.LibP2P.GossipSub
  alias ExWire.DVT.KeyManager
  alias ExWire.Enterprise.AuditLogger

  @type peer_id :: String.t()
  @type cluster_id :: String.t()
  @type message_type ::
          :key_gen | :duty_consensus | :slashing_alert | :heartbeat | :performance_metrics

  # Protocol identifiers
  @dvt_dkg_protocol "/dvt/dkg/1.0.0"
  @dvt_consensus_protocol "/dvt/consensus/1.0.0"
  @dvt_slashing_protocol "/dvt/slashing/1.0.0"
  @dvt_monitoring_protocol "/dvt/monitoring/1.0.0"

  # Message structure
  @type dvt_message :: %{
          type: message_type(),
          cluster_id: cluster_id(),
          sender_id: pos_integer(),
          sequence: pos_integer(),
          timestamp: DateTime.t(),
          payload: binary(),
          signature: binary(),
          nonce: binary()
        }

  defstruct [
    :node_id,
    # %{cluster_id => %{role, permissions}}
    :cluster_memberships,
    # %{peer_id => connection_info}
    :peer_connections,
    # Recently seen message IDs for replay protection
    :message_cache,
    # Node authentication keys
    :authentication_keys,
    # GossipSub process PID
    :gossipsub_pid,
    # Performance and network metrics
    :monitoring_metrics,
    # Network partition detection state
    :partition_detector
  ]

  # Type definitions for nested structures
  @type connection_info :: %{
          peer_id: String.t(),
          cluster_id: String.t(),
          node_id: String.t(),
          endpoint: String.t(),
          public_key: binary(),
          authenticated_at: pos_integer(),
          last_heartbeat: pos_integer(),
          message_count: pos_integer(),
          latency_ms: float(),
          status: :connecting | :authenticated | :active | :suspicious | :banned
        }

  @type metrics :: %{
          messages_sent: pos_integer(),
          messages_received: pos_integer(),
          consensus_rounds: pos_integer(),
          average_latency: float(),
          partition_events: pos_integer(),
          authentication_failures: pos_integer(),
          replay_attempts: pos_integer()
        }

  ## Public API

  @doc """
  Start the DVT P2P protocol handler.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Join a DVT cluster network with authenticated participation.
  """
  def join_cluster(cluster_id, node_id, authentication_key) do
    GenServer.call(__MODULE__, {:join_cluster, cluster_id, node_id, authentication_key})
  end

  @doc """
  Leave a DVT cluster network.
  """
  def leave_cluster(cluster_id) do
    GenServer.call(__MODULE__, {:leave_cluster, cluster_id})
  end

  @doc """
  Broadcast a message to cluster participants with authentication.
  """
  def broadcast_message(cluster_id, message_type, payload) do
    GenServer.call(__MODULE__, {:broadcast, cluster_id, message_type, payload})
  end

  @doc """
  Send a direct message to a specific node in the cluster.
  """
  def send_direct_message(cluster_id, target_node_id, message_type, payload) do
    GenServer.call(
      __MODULE__,
      {:direct_message, cluster_id, target_node_id, message_type, payload}
    )
  end

  @doc """
  Get network status and performance metrics.
  """
  def get_network_status() do
    GenServer.call(__MODULE__, :get_network_status)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    node_id = Keyword.get(opts, :node_id, generate_node_id())

    # Start GossipSub if not already running
    {:ok, gossipsub_pid} = start_gossipsub()

    # Initialize authentication keys
    auth_keys = generate_authentication_keys()

    state = %__MODULE__{
      node_id: node_id,
      cluster_memberships: %{},
      peer_connections: %{},
      message_cache: :ets.new(:dvt_message_cache, [:set, :private]),
      authentication_keys: auth_keys,
      gossipsub_pid: gossipsub_pid,
      monitoring_metrics: %{
        messages_sent: 0,
        messages_received: 0,
        consensus_rounds: 0,
        average_latency: 0.0,
        partition_events: 0,
        authentication_failures: 0,
        replay_attempts: 0
      },
      partition_detector: init_partition_detector()
    }

    # Schedule periodic tasks
    :timer.send_interval(5_000, :heartbeat)
    :timer.send_interval(30_000, :cleanup_message_cache)
    :timer.send_interval(60_000, :update_metrics)
    :timer.send_interval(10_000, :detect_partitions)

    AuditLogger.log(:info, "DVT P2P Protocol initialized", %{node_id: node_id})

    {:ok, _state}
  end

  @impl true
  def handle_call({:join_cluster, cluster_id, node_id, auth_key}, _from, _state) do
    case authenticate_cluster_join(cluster_id, node_id, auth_key) do
      {:ok, permissions} ->
        # Subscribe to cluster-specific topics
        topics = get_cluster_topics(cluster_id)
        Enum.each(topics, &GossipSub.subscribe(state.gossipsub_pid, &1))

        # Update memberships
        membership = %{role: :operator, permissions: permissions, joined_at: DateTime.utc_now()}
        new_memberships = Map.put(state.cluster_memberships, cluster_id, membership)

        # Announce presence to cluster
        announce_presence(cluster_id, node_id, state)

        AuditLogger.log(:info, "Joined DVT cluster", %{cluster_id: cluster_id, node_id: node_id})

        {:reply, {:ok, permissions}, %{state | cluster_memberships: new_memberships}}

      {:error, _reason} ->
        AuditLogger.log(:warning, "Failed to join DVT cluster", %{
          cluster_id: cluster_id,
          node_id: node_id,
          reason: reason
        })

        {:reply, {:error, _reason}, state}
    end
  end

  @impl true
  def handle_call({:leave_cluster, cluster_id}, _from, _state) do
    case Map.get(state.cluster_memberships, cluster_id) do
      nil ->
        {:reply, {:error, :not_member}, state}

      _membership ->
        # Unsubscribe from cluster topics
        topics = get_cluster_topics(cluster_id)
        Enum.each(topics, &GossipSub.unsubscribe(state.gossipsub_pid, &1))

        # Remove from memberships
        new_memberships = Map.delete(state.cluster_memberships, cluster_id)

        # Remove peer connections for this cluster
        new_connections =
          state.peer_connections
          |> Enum.reject(fn {_peer_id, info} -> info.cluster_id == cluster_id end)
          |> Map.new()

        AuditLogger.log(:info, "Left DVT cluster", %{cluster_id: cluster_id})

        {:reply, :ok,
         %{state | cluster_memberships: new_memberships, peer_connections: new_connections}}
    end
  end

  @impl true
  def handle_call({:broadcast, cluster_id, message_type, payload}, _from, _state) do
    case Map.get(state.cluster_memberships, cluster_id) do
      nil ->
        {:reply, {:error, :not_member}, state}

      membership ->
        case has_permission?(membership, message_type) do
          true ->
            message = create_authenticated_message(cluster_id, message_type, payload, state)
            topic = get_message_topic(cluster_id, message_type)

            case GossipSub.publish(state.gossipsub_pid, topic, :erlang.term_to_binary(message)) do
              :ok ->
                # Update metrics
                metrics = update_sent_metrics(state.monitoring_metrics)
                {:reply, :ok, %{_state | monitoring_metrics: metrics}}

              {:error, _reason} ->
                Logger.warning("Failed to broadcast DVT message: #{inspect(reason)}")
                {:reply, {:error, _reason}, state}
            end

          false ->
            AuditLogger.log(:warning, "Insufficient permissions for message broadcast", %{
              cluster_id: cluster_id,
              message_type: message_type,
              node_id: state.node_id
            })

            {:reply, {:error, :insufficient_permissions}, state}
        end
    end
  end

  @impl true
  def handle_call(
        {:direct_message, cluster_id, target_node_id, message_type, payload},
        _from,
        _state
      ) do
    with {:ok, peer_id} <- find_peer_by_node_id(cluster_id, target_node_id, state),
         {:ok, connection} <- Map.fetch(state.peer_connections, peer_id),
         true <- connection.status == :active do
      message = create_authenticated_message(cluster_id, message_type, payload, state)

      # Send direct message via LibP2P stream
      case send_direct_stream_message(peer_id, message, state) do
        :ok ->
          metrics = update_sent_metrics(state.monitoring_metrics)
          {:reply, :ok, %{_state | monitoring_metrics: metrics}}

        {:error, _reason} ->
          {:reply, {:error, _reason}, state}
      end
    else
      _ ->
        {:reply, {:error, :peer_not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_network_status, _from, _state) do
    status = %{
      node_id: state.node_id,
      cluster_memberships: Map.keys(state.cluster_memberships),
      peer_count: map_size(state.peer_connections),
      active_peers: count_active_peers(state.peer_connections),
      metrics: state.monitoring_metrics,
      partition_status: get_partition_status(state.partition_detector)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:gossipsub, topic, message_data}, _state) do
    case :erlang.binary_to_term(message_data) do
      %{type: _type} = message ->
        handle_dvt_message(topic, message, state)

      _ ->
        Logger.warning("Received invalid DVT message format")
        {:noreply, state}
    end
  rescue
    _ ->
      Logger.warning("Failed to decode DVT message")
      {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, _state) do
    # Send heartbeat to all active connections
    state = send_heartbeats(state)

    # Check for stale connections
    state = cleanup_stale_connections(state)

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_message_cache, _state) do
    # Remove old message IDs from cache (prevent replay attacks)
    # 5 minutes
    cutoff = DateTime.add(DateTime.utc_now(), -300, :second)

    :ets.select_delete(state.message_cache, [
      {{:"$1", :"$2"}, [{:<, :"$2", DateTime.to_unix(cutoff)}], [true]}
    ])

    {:noreply, state}
  end

  @impl true
  def handle_info(:update_metrics, _state) do
    # Update performance metrics
    metrics = calculate_metrics(state)

    # Report to monitoring system
    report_metrics_to_prometheus(metrics)

    {:noreply, %{state | monitoring_metrics: metrics}}
  end

  @impl true
  def handle_info(:detect_partitions, _state) do
    # Check for network partitions
    partition_status = detect_network_partitions(state)

    case partition_status.partitioned do
      true ->
        AuditLogger.log(:alert, "Network partition detected", partition_status)

        # Trigger partition recovery procedures
        state = handle_network_partition(state, partition_status)
        {:noreply, _state}

      false ->
        {:noreply, %{state | partition_detector: partition_status}}
    end
  end

  ## Private Functions

  defp start_gossipsub() do
    case Process.whereis(ExWire.LibP2P.GossipSub) do
      nil ->
        GossipSub.start_link([])

      pid when is_pid(pid) ->
        {:ok, pid}
    end
  end

  defp generate_node_id() do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp generate_authentication_keys() do
    # Generate Ed25519 keypair for message authentication
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: public_key, private: private_key}
  end

  defp authenticate_cluster_join(cluster_id, node_id, auth_key) do
    # Verify the node has permission to join this cluster
    case KeyManager.verify_cluster_permission(cluster_id, node_id, auth_key) do
      {:ok, permissions} ->
        {:ok, permissions}

      {:error, _reason} ->
        {:error, _reason}
    end
  end

  defp get_cluster_topics(cluster_id) do
    [
      "dvt/#{cluster_id}/dkg",
      "dvt/#{cluster_id}/consensus",
      "dvt/#{cluster_id}/slashing",
      "dvt/#{cluster_id}/monitoring"
    ]
  end

  defp get_message_topic(cluster_id, message_type) do
    case message_type do
      :key_gen -> "dvt/#{cluster_id}/dkg"
      :duty_consensus -> "dvt/#{cluster_id}/consensus"
      :slashing_alert -> "dvt/#{cluster_id}/slashing"
      :heartbeat -> "dvt/#{cluster_id}/monitoring"
      :performance_metrics -> "dvt/#{cluster_id}/monitoring"
    end
  end

  defp create_authenticated_message(cluster_id, message_type, payload, _state) do
    sequence = :erlang.system_time(:millisecond)
    nonce = :crypto.strong_rand_bytes(16)

    message = %{
      type: message_type,
      cluster_id: cluster_id,
      sender_id: state.node_id,
      sequence: sequence,
      timestamp: DateTime.utc_now(),
      payload: payload,
      nonce: nonce,
      signature: nil
    }

    # Sign the message
    message_hash = hash_message_for_signing(message)
    signature = :crypto.sign(:eddsa, :ed25519, message_hash, state.authentication_keys.private)

    %{message | signature: signature}
  end

  defp hash_message_for_signing(message) do
    # Create deterministic hash for signing (excluding signature field)
    signable_fields = Map.delete(message, :signature)
    :crypto.hash(:sha256, :erlang.term_to_binary(signable_fields))
  end

  defp has_permission?(membership, message_type) do
    required_permission =
      case message_type do
        :key_gen -> :dkg_participate
        :duty_consensus -> :consensus_participate
        :slashing_alert -> :slashing_report
        :heartbeat -> :basic_communication
        :performance_metrics -> :basic_communication
      end

    required_permission in membership.permissions
  end

  defp announce_presence(cluster_id, node_id, _state) do
    presence_message = %{
      node_id: node_id,
      public_key: _state.authentication_keys.public,
      capabilities: [:dkg, :consensus, :slashing_protection],
      timestamp: DateTime.utc_now()
    }

    broadcast_message(cluster_id, :heartbeat, presence_message)
  end

  defp handle_dvt_message(topic, message, _state) do
    # Verify message authenticity
    case verify_message_signature(message, state) do
      {:ok, verified_message} ->
        # Check for replay attacks
        case check_replay_protection(verified_message, state) do
          :ok ->
            process_verified_message(topic, verified_message, _state)

          :replay ->
            Logger.warning("Replay attack detected", message_id: message.sequence)

            AuditLogger.log(:alert, "DVT replay attack detected", %{
              sender: message.sender_id,
              sequence: message.sequence,
              cluster_id: message.cluster_id
            })

            {:noreply, state}
        end

      {:error, :invalid_signature} ->
        Logger.warning("Invalid DVT message signature")

        AuditLogger.log(:alert, "DVT message authentication failure", %{
          sender: message.sender_id,
          cluster_id: message.cluster_id
        })

        {:noreply, state}
    end
  end

  defp verify_message_signature(message, _state) do
    # Get sender's public key from peer connections or key manager
    case get_sender_public_key(message.sender_id, message.cluster_id) do
      {:ok, public_key} ->
        message_hash = hash_message_for_signing(message)

        case :crypto.verify(:eddsa, :ed25519, message_hash, message.signature, public_key) do
          true -> {:ok, message}
          false -> {:error, :invalid_signature}
        end

      {:error, :key_not_found} ->
        {:error, :invalid_signature}
    end
  end

  defp check_replay_protection(message, _state) do
    message_id = "#{message.sender_id}:#{message.sequence}"
    timestamp = DateTime.to_unix(message.timestamp)

    case :ets.lookup(state.message_cache, message_id) do
      [] ->
        # New message, store it
        :ets.insert(_state.message_cache, {message_id, timestamp})
        :ok

      [{_id, _old_timestamp}] ->
        :replay
    end
  end

  defp process_verified_message(_topic, message, _state) do
    # Route message to appropriate handler based on type
    case message.type do
      :key_gen ->
        ExWire.DVT.KeyManager.handle_dkg_message(message)

      :duty_consensus ->
        ExWire.DVT.DutyConsensus.handle_consensus_message(message)

      :slashing_alert ->
        ExWire.DVT.SlashingProtection.handle_slashing_alert(message)

      :heartbeat ->
        handle_heartbeat_message(message, state)

      :performance_metrics ->
        handle_performance_metrics(message, state)
    end

    # Update received message metrics
    metrics = update_received_metrics(state.monitoring_metrics)
    {:noreply, %{_state | monitoring_metrics: metrics}}
  end

  defp get_sender_public_key(sender_id, cluster_id) do
    # Try to get from current connections first
    case find_peer_by_node_id(cluster_id, sender_id, %{peer_connections: %{}}) do
      {:ok, _peer_id} ->
        # Get from peer connection info
        {:ok, "public_key_placeholder"}

      {:error, :not_found} ->
        # Try to get from key manager
        KeyManager.get_node_public_key(cluster_id, sender_id)
    end
  end

  defp find_peer_by_node_id(cluster_id, node_id, _state) do
    result =
      state.peer_connections
      |> Enum.find(fn {_peer_id, info} ->
        info.cluster_id == cluster_id and info.node_id == node_id
      end)

    case result do
      {peer_id, _info} -> {:ok, peer_id}
      nil -> {:error, :not_found}
    end
  end

  defp send_direct_stream_message(_peer_id, _message, _state) do
    # Implement direct LibP2P stream communication
    # This would use LibP2P's stream protocol
    :ok
  end

  defp send_heartbeats(_state) do
    # Send heartbeat to all clusters
    Enum.reduce(state.cluster_memberships, state, fn {cluster_id, _membership}, acc_state ->
      heartbeat_payload = %{
        timestamp: DateTime.utc_now(),
        metrics: get_basic_metrics(acc_state),
        status: :active
      }

      case broadcast_message(cluster_id, :heartbeat, heartbeat_payload) do
        :ok -> acc_state
        {:error, _reason} -> acc_state
      end
    end)
  end

  defp cleanup_stale_connections(_state) do
    # 1 minute
    cutoff = DateTime.add(DateTime.utc_now(), -60, :second)

    new_connections =
      state.peer_connections
      |> Enum.filter(fn {_peer_id, info} ->
        DateTime.compare(info.last_heartbeat, cutoff) != :lt
      end)
      |> Map.new()

    %{state | peer_connections: new_connections}
  end

  defp handle_heartbeat_message(message, _state) do
    # Update peer connection info
    sender_info = %{
      peer_id: "peer_#{message.sender_id}",
      cluster_id: message.cluster_id,
      node_id: message.sender_id,
      endpoint: "",
      public_key: <<>>,
      authenticated_at: 0,
      last_heartbeat: message.timestamp,
      message_count: 0,
      latency_ms: 0.0,
      status: :active
    }

    new_connections = Map.put(state.peer_connections, sender_info.peer_id, sender_info)
    %{state | peer_connections: new_connections}
  end

  defp handle_performance_metrics(_message, _state) do
    # Process performance metrics from peers
    state
  end

  defp count_active_peers(connections) do
    cutoff = DateTime.add(DateTime.utc_now(), -30, :second)

    connections
    |> Enum.count(fn {_peer_id, info} ->
      info.status == :active and DateTime.compare(info.last_heartbeat, cutoff) != :lt
    end)
  end

  defp get_partition_status(partition_detector) do
    partition_detector
  end

  defp calculate_metrics(_state) do
    # Calculate current performance metrics
    %{
      messages_sent: 0,
      messages_received: 0,
      consensus_rounds: 0,
      average_latency: 0.0,
      partition_events: 0,
      authentication_failures: 0,
      replay_attempts: 0
    }
  end

  defp report_metrics_to_prometheus(_metrics) do
    # Report to Prometheus metrics system
    :ok
  end

  defp detect_network_partitions(_state) do
    # Implement partition detection algorithm
    %{partitioned: false, detected_at: nil, affected_clusters: []}
  end

  # Helper function to get protocol identifiers (uses the module attributes)
  defp get_protocol_for_message_type(message_type) do
    case message_type do
      :key_gen -> @dvt_dkg_protocol
      :duty_consensus -> @dvt_consensus_protocol
      :slashing_alert -> @dvt_slashing_protocol
      :performance_metrics -> @dvt_monitoring_protocol
      _ -> "/dvt/generic/1.0.0"
    end
  end

  defp handle_network_partition(_state, _partition_status) do
    # Implement partition recovery procedures
    _state
  end

  defp update_sent_metrics(metrics) do
    %{metrics | messages_sent: metrics.messages_sent + 1}
  end

  defp update_received_metrics(metrics) do
    %{metrics | messages_received: metrics.messages_received + 1}
  end

  defp get_basic_metrics(_state) do
    %{cpu_usage: 0, memory_usage: 0, network_latency: 0}
  end

  defp init_partition_detector() do
    %{partitioned: false, last_check: DateTime.utc_now()}
  end
end
