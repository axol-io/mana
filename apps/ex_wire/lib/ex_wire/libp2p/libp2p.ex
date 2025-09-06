defmodule ExWire.LibP2P do
  @moduledoc """
  LibP2P implementation for Ethereum 2.0 consensus layer networking.

  Provides peer-to-peer networking capabilities for:
  - Beacon block propagation
  - Attestation gossip
  - Sync committee messages
  - Peer discovery via discv5
  """

  use GenServer
  require Logger

  alias ExWire.LibP2P.{
    Transport,
    PeerManager,
    GossipSub,
    Discovery,
    RPC,
    Stream
  }

  @behaviour :gen_statem

  # LibP2P protocol IDs
  @protocol_prefix "/eth2/beacon_chain/req"
  @gossip_prefix "/eth2"
  @metadata_protocol "#{@protocol_prefix}/metadata/1/"
  @status_protocol "#{@protocol_prefix}/status/1/"
  @goodbye_protocol "#{@protocol_prefix}/goodbye/1/"
  @ping_protocol "#{@protocol_prefix}/ping/1/"

  # Request protocols
  @beacon_blocks_by_range "#{@protocol_prefix}/beacon_blocks_by_range/1/"
  @beacon_blocks_by_root "#{@protocol_prefix}/beacon_blocks_by_root/1/"

  # Default configuration
  @default_port 9000
  @max_peers 64
  @target_peers 50
  @dial_timeout 10_000
  # Desired outbound degree
  @gossip_d 8
  # Lower bound for outbound degree
  @gossip_d_low 6
  # Upper bound for outbound degree
  @gossip_d_high 12

  defstruct [
    :node_id,
    :transport,
    :peer_manager,
    :gossipsub,
    :discovery,
    :rpc,
    :streams,
    :config,
    :fork_digest,
    :enr,
    :metadata,
    topics: %{},
    peers: %{}
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe to a gossip topic
  """
  def subscribe(topic) do
    GenServer.call(__MODULE__, {:subscribe, topic})
  end

  @doc """
  Unsubscribe from a gossip topic
  """
  def unsubscribe(topic) do
    GenServer.call(__MODULE__, {:unsubscribe, topic})
  end

  @doc """
  Publish a message to a gossip topic
  """
  def publish(topic, message) do
    GenServer.cast(__MODULE__, {:publish, topic, message})
  end

  @doc """
  Request beacon blocks by range
  """
  def request_blocks_by_range(peer_id, start_slot, count, step \\ 1) do
    GenServer.call(__MODULE__, {:request_blocks_by_range, peer_id, start_slot, count, step})
  end

  @doc """
  Request beacon blocks by root
  """
  def request_blocks_by_root(peer_id, block_roots) do
    GenServer.call(__MODULE__, {:request_blocks_by_root, peer_id, block_roots})
  end

  @doc """
  Get connected peers
  """
  def get_peers do
    GenServer.call(__MODULE__, :get_peers)
  end

  @doc """
  Get node ENR (Ethereum Node Record)
  """
  def get_enr do
    GenServer.call(__MODULE__, :get_enr)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    config = build_config(opts)

    # Generate node identity
    {node_id, private_key} = generate_or_load_identity(config)

    # Initialize transport layer
    {:ok, transport} =
      Transport.start_link(
        port: config.port,
        node_id: node_id,
        private_key: private_key
      )

    # Initialize peer manager
    {:ok, peer_manager} =
      PeerManager.start_link(
        max_peers: config.max_peers,
        target_peers: config.target_peers
      )

    # Initialize GossipSub
    {:ok, gossipsub} =
      GossipSub.start_link(
        node_id: node_id,
        d: @gossip_d,
        d_low: @gossip_d_low,
        d_high: @gossip_d_high
      )

    # Initialize discovery (discv5)
    {:ok, discovery} =
      Discovery.start_link(
        node_id: node_id,
        port: config.discovery_port,
        bootnodes: config.bootnodes
      )

    # Initialize RPC handler
    {:ok, rpc} = RPC.start_link(self())

    # Build ENR
    enr = build_enr(node_id, config)

    # Build metadata
    metadata = build_metadata(config)

    state = %__MODULE__{
      node_id: node_id,
      transport: transport,
      peer_manager: peer_manager,
      gossipsub: gossipsub,
      discovery: discovery,
      rpc: rpc,
      streams: %{},
      config: config,
      fork_digest: compute_fork_digest(config),
      enr: enr,
      metadata: metadata
    }

    # Start discovery
    Discovery.start_discovery(discovery)

    # Schedule peer management
    schedule_peer_management()

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, topic}, _from, state) do
    full_topic = build_topic_name(topic, state.fork_digest)

    case GossipSub.subscribe(state.gossipsub, full_topic) do
      :ok ->
        new_topics = Map.put(state.topics, topic, full_topic)
        {:reply, :ok, %{state | topics: new_topics}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:unsubscribe, topic}, _from, state) do
    case Map.get(state.topics, topic) do
      nil ->
        {:reply, {:error, :not_subscribed}, state}

      full_topic ->
        GossipSub.unsubscribe(state.gossipsub, full_topic)
        new_topics = Map.delete(state.topics, topic)
        {:reply, :ok, %{state | topics: new_topics}}
    end
  end

  def handle_call({:request_blocks_by_range, peer_id, start_slot, count, step}, _from, state) do
    request = %{
      start_slot: start_slot,
      count: count,
      step: step
    }

    case send_rpc_request(peer_id, @beacon_blocks_by_range, request, state) do
      {:ok, stream_id} ->
        {:reply, {:ok, stream_id}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:request_blocks_by_root, peer_id, block_roots}, _from, state) do
    request = %{block_roots: block_roots}

    case send_rpc_request(peer_id, @beacon_blocks_by_root, request, state) do
      {:ok, stream_id} ->
        {:reply, {:ok, stream_id}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:get_peers, _from, state) do
    peers = PeerManager.get_peers(state.peer_manager)
    {:reply, peers, state}
  end

  def handle_call(:get_enr, _from, state) do
    {:reply, state.enr, state}
  end

  @impl true
  def handle_cast({:publish, topic, message}, state) do
    case Map.get(state.topics, topic) do
      nil ->
        Logger.warning("Attempted to publish to unsubscribed topic: #{topic}")
        {:noreply, state}

      full_topic ->
        GossipSub.publish(state.gossipsub, full_topic, message)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:discovered_peer, peer_info}, state) do
    # New peer discovered via discv5
    if should_dial_peer?(peer_info, state) do
      dial_peer(peer_info, state)
    end

    {:noreply, state}
  end

  def handle_info({:peer_connected, peer_id, connection}, state) do
    # New peer connected
    Logger.info("Peer connected: #{inspect(peer_id)}")

    # Send status message
    send_status(peer_id, state)

    # Add to peer manager
    PeerManager.add_peer(state.peer_manager, peer_id, connection)

    new_peers =
      Map.put(state.peers, peer_id, %{
        connection: connection,
        status: :connected,
        metadata: nil
      })

    {:noreply, %{state | peers: new_peers}}
  end

  def handle_info({:peer_disconnected, peer_id, reason}, state) do
    Logger.info("Peer disconnected: #{inspect(peer_id)}, reason: #{inspect(reason)}")

    # Remove from peer manager
    PeerManager.remove_peer(state.peer_manager, peer_id)

    # Clean up streams
    new_streams =
      Map.reject(state.streams, fn {_id, stream} ->
        stream.peer_id == peer_id
      end)

    new_peers = Map.delete(state.peers, peer_id)

    {:noreply, %{state | peers: new_peers, streams: new_streams}}
  end

  def handle_info({:gossip_message, topic, message, from_peer}, state) do
    # Received gossip message
    handle_gossip_message(topic, message, from_peer, state)
    {:noreply, state}
  end

  def handle_info({:rpc_request, peer_id, protocol, request_id, request}, state) do
    # Handle incoming RPC request
    response = handle_rpc_request(protocol, request, state)
    send_rpc_response(peer_id, request_id, response, state)
    {:noreply, state}
  end

  def handle_info({:rpc_response, stream_id, response}, state) do
    # Handle RPC response
    case Map.get(state.streams, stream_id) do
      nil ->
        Logger.warning("Received response for unknown stream: #{stream_id}")

      stream ->
        handle_rpc_response(stream, response, state)
    end

    {:noreply, state}
  end

  def handle_info(:manage_peers, state) do
    # Periodic peer management
    manage_peers(state)
    schedule_peer_management()
    {:noreply, state}
  end

  # Private Functions

  defp build_config(opts) do
    %{
      port: Keyword.get(opts, :port, @default_port),
      discovery_port: Keyword.get(opts, :discovery_port, @default_port + 1),
      max_peers: Keyword.get(opts, :max_peers, @max_peers),
      target_peers: Keyword.get(opts, :target_peers, @target_peers),
      bootnodes: Keyword.get(opts, :bootnodes, []),
      genesis_validators_root: Keyword.get(opts, :genesis_validators_root),
      fork_version: Keyword.get(opts, :fork_version, <<0, 0, 0, 1>>),
      chain_id: Keyword.get(opts, :chain_id, 1),
      network_id: Keyword.get(opts, :network_id, 1)
    }
  end

  defp generate_or_load_identity(config) do
    identity_file = "#{config.data_dir}/identity.key"

    if File.exists?(identity_file) do
      load_identity(identity_file)
    else
      identity = generate_identity()
      save_identity(identity, identity_file)
      identity
    end
  end

  defp generate_identity do
    private_key = :crypto.strong_rand_bytes(32)
    node_id = compute_node_id(private_key)
    {node_id, private_key}
  end

  defp compute_node_id(private_key) do
    # Derive public key and compute node ID
    {:ok, public_key} = ExthCrypto.Signature.get_public_key(private_key)
    ExthCrypto.Hash.kec(public_key)
  end

  defp build_enr(node_id, config) do
    %{
      id: node_id,
      ip: get_public_ip(),
      tcp: config.port,
      udp: config.discovery_port,
      eth2: %{
        fork_digest: compute_fork_digest(config),
        next_fork_version: config.fork_version,
        next_fork_epoch: 0
      },
      # Subscribed to all attestation subnets
      attnets: <<0xFF, 0xFF>>,
      # Not on sync committee
      syncnets: <<0x00>>
    }
  end

  defp build_metadata(config) do
    %{
      seq_number: 0,
      # Subscribed to all attestation subnets
      attnets: <<0xFF, 0xFF>>,
      # Not on sync committee
      syncnets: <<0x00>>
    }
  end

  defp compute_fork_digest(config) do
    # Compute fork digest from fork version and genesis validators root
    fork_data = config.fork_version <> config.genesis_validators_root
    hash = ExthCrypto.Hash.kec(fork_data)
    binary_part(hash, 0, 4)
  end

  defp build_topic_name(topic, fork_digest) do
    case topic do
      :beacon_block ->
        "#{@gossip_prefix}/#{Base.encode16(fork_digest, case: :lower)}/beacon_block/ssz_snappy"

      :beacon_aggregate_and_proof ->
        "#{@gossip_prefix}/#{Base.encode16(fork_digest, case: :lower)}/beacon_aggregate_and_proof/ssz_snappy"

      {:beacon_attestation, subnet_id} ->
        "#{@gossip_prefix}/#{Base.encode16(fork_digest, case: :lower)}/beacon_attestation_#{subnet_id}/ssz_snappy"

      :voluntary_exit ->
        "#{@gossip_prefix}/#{Base.encode16(fork_digest, case: :lower)}/voluntary_exit/ssz_snappy"

      :proposer_slashing ->
        "#{@gossip_prefix}/#{Base.encode16(fork_digest, case: :lower)}/proposer_slashing/ssz_snappy"

      :attester_slashing ->
        "#{@gossip_prefix}/#{Base.encode16(fork_digest, case: :lower)}/attester_slashing/ssz_snappy"

      :sync_committee_contribution_and_proof ->
        "#{@gossip_prefix}/#{Base.encode16(fork_digest, case: :lower)}/sync_committee_contribution_and_proof/ssz_snappy"

      {:sync_committee, subnet_id} ->
        "#{@gossip_prefix}/#{Base.encode16(fork_digest, case: :lower)}/sync_committee_#{subnet_id}/ssz_snappy"
    end
  end

  defp should_dial_peer?(peer_info, state) do
    # Check if we should dial this peer
    peer_count = map_size(state.peers)

    peer_count < state.config.target_peers and
      not Map.has_key?(state.peers, peer_info.id) and
      not is_blacklisted?(peer_info.id)
  end

  defp dial_peer(peer_info, state) do
    Task.start(fn ->
      case Transport.dial(state.transport, peer_info) do
        {:ok, connection} ->
          send(self(), {:peer_connected, peer_info.id, connection})

        {:error, reason} ->
          Logger.debug("Failed to dial peer #{inspect(peer_info.id)}: #{inspect(reason)}")
      end
    end)
  end

  defp send_status(peer_id, state) do
    status = %{
      fork_digest: state.fork_digest,
      finalized_root: get_finalized_root(),
      finalized_epoch: get_finalized_epoch(),
      head_root: get_head_root(),
      head_slot: get_head_slot()
    }

    send_rpc_request(peer_id, @status_protocol, status, state)
  end

  defp send_rpc_request(peer_id, protocol, request, state) do
    case Map.get(state.peers, peer_id) do
      nil ->
        {:error, :peer_not_found}

      peer ->
        stream_id = generate_stream_id()

        # Send request via transport
        Transport.send_request(
          state.transport,
          peer.connection,
          protocol,
          encode_request(request)
        )

        # Track stream
        stream = %{
          id: stream_id,
          peer_id: peer_id,
          protocol: protocol,
          request: request,
          timestamp: System.system_time(:millisecond)
        }

        new_streams = Map.put(state.streams, stream_id, stream)

        {:ok, stream_id}
    end
  end

  defp send_rpc_response(peer_id, request_id, response, state) do
    case Map.get(state.peers, peer_id) do
      nil ->
        Logger.warning("Cannot send response to disconnected peer: #{inspect(peer_id)}")

      peer ->
        Transport.send_response(
          state.transport,
          peer.connection,
          request_id,
          encode_response(response)
        )
    end
  end

  defp handle_rpc_request(@status_protocol, _request, state) do
    # Handle status request
    %{
      fork_digest: state.fork_digest,
      finalized_root: get_finalized_root(),
      finalized_epoch: get_finalized_epoch(),
      head_root: get_head_root(),
      head_slot: get_head_slot()
    }
  end

  defp handle_rpc_request(@metadata_protocol, _request, state) do
    # Return our metadata
    state.metadata
  end

  defp handle_rpc_request(@ping_protocol, request, _state) do
    # Echo back the ping value
    request
  end

  defp handle_rpc_request(@beacon_blocks_by_range, request, _state) do
    # Fetch blocks from storage
    blocks =
      fetch_blocks_by_range(
        request.start_slot,
        request.count,
        request.step
      )

    %{blocks: blocks}
  end

  defp handle_rpc_request(@beacon_blocks_by_root, request, _state) do
    # Fetch blocks by root
    blocks = fetch_blocks_by_root(request.block_roots)
    %{blocks: blocks}
  end

  defp handle_rpc_response(stream, response, state) do
    # Process response based on protocol
    case stream.protocol do
      @beacon_blocks_by_range ->
        handle_blocks_response(response.blocks, state)

      @beacon_blocks_by_root ->
        handle_blocks_response(response.blocks, state)

      @status_protocol ->
        handle_status_response(stream.peer_id, response, state)

      _ ->
        :ok
    end
  end

  defp handle_gossip_message(topic, message, from_peer, state) do
    # Validate and process gossip message
    case validate_gossip_message(topic, message) do
      :ok ->
        process_gossip_message(topic, message, state)
        # Propagate to other peers
        GossipSub.propagate(state.gossipsub, topic, message, from_peer)

      {:error, reason} ->
        Logger.debug("Invalid gossip message: #{inspect(reason)}")
        # Penalize peer
        PeerManager.penalize_peer(state.peer_manager, from_peer, reason)
    end
  end

  defp manage_peers(state) do
    peer_count = map_size(state.peers)

    cond do
      peer_count < state.config.target_peers ->
        # Need more peers
        request_more_peers(state)

      peer_count > state.config.max_peers ->
        # Too many peers, prune some
        prune_peers(state)

      true ->
        :ok
    end
  end

  defp request_more_peers(state) do
    # Ask discovery for more peers
    Discovery.find_peers(state.discovery, state.config.target_peers - map_size(state.peers))
  end

  defp prune_peers(state) do
    # Remove lowest scoring peers
    peers_to_remove =
      state.peers
      |> Enum.map(fn {id, _peer} ->
        {id, PeerManager.get_peer_score(state.peer_manager, id)}
      end)
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.take(map_size(state.peers) - state.config.max_peers)
      |> Enum.map(&elem(&1, 0))

    Enum.each(peers_to_remove, fn peer_id ->
      disconnect_peer(peer_id, :pruned, state)
    end)
  end

  defp disconnect_peer(peer_id, reason, state) do
    # Send goodbye message
    send_rpc_request(peer_id, @goodbye_protocol, %{reason: reason}, state)

    # Disconnect transport
    case Map.get(state.peers, peer_id) do
      nil -> :ok
      peer -> Transport.disconnect(state.transport, peer.connection)
    end
  end

  defp schedule_peer_management do
    # Every 30 seconds
    Process.send_after(self(), :manage_peers, 30_000)
  end

  defp generate_stream_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16()
  end

  defp encode_request(request) do
    # SSZ encode the request
    SSZ.encode(request)
  end

  defp encode_response(response) do
    # SSZ encode the response
    SSZ.encode(response)
  end

  defp validate_gossip_message(topic, message) do
    # Validate message based on topic type
    case String.split(topic, "/") do
      ["eth2", "beacon_block" | _] ->
        validate_beacon_block(message)

      ["eth2", "beacon_attestation" | _] ->
        validate_attestation(message)

      _ ->
        # Unknown topics pass validation by default
        :ok
    end
  end

  defp validate_beacon_block(_message), do: :ok
  defp validate_attestation(_message), do: :ok

  defp process_gossip_message(topic, message, state) do
    # Process based on topic type
    Logger.debug("Processing gossip message on topic: #{topic}")

    # Route to appropriate handler based on topic
    case String.split(topic, "/") do
      ["eth2", "beacon_block" | _] ->
        ExWire.Eth2.BeaconChain.handle_block(message, state)

      ["eth2", "beacon_attestation" | _] ->
        ExWire.Eth2.BeaconChain.handle_attestation(message, state)

      ["eth2", "voluntary_exit" | _] ->
        ExWire.Eth2.BeaconChain.handle_voluntary_exit(message, state)

      _ ->
        Logger.debug("Unhandled topic: #{topic}")
    end
  end

  defp is_blacklisted?(peer_id) do
    # Check if peer is in blacklist
    case :ets.lookup(:peer_blacklist, peer_id) do
      [] -> false
      [{^peer_id, _reason}] -> true
    end
  rescue
    # If ETS table doesn't exist, no peers are blacklisted
    _ -> false
  end

  defp get_public_ip do
    # Get public IP from configuration or auto-detect
    case Application.get_env(:ex_wire, :public_ip) do
      nil ->
        # Try to auto-detect public IP
        case :inet.getif() do
          {:ok, interfaces} ->
            # Find first non-loopback interface
            interfaces
            |> Enum.find(fn {ip, _broadcast, _netmask} ->
              ip != {127, 0, 0, 1} and ip != {0, 0, 0, 0}
            end)
            |> case do
              {ip, _, _} -> ip
              nil -> {127, 0, 0, 1}
            end

          _ ->
            {127, 0, 0, 1}
        end

      ip when is_tuple(ip) ->
        ip

      ip when is_binary(ip) ->
        String.to_charlist(ip) |> :inet.parse_address() |> elem(1)
    end
  end

  # Stub functions - should connect to actual beacon chain
  defp get_finalized_root, do: <<0::256>>
  defp get_finalized_epoch, do: 0
  defp get_head_root, do: <<0::256>>
  defp get_head_slot, do: 0
  defp fetch_blocks_by_range(_start, _count, _step), do: []
  defp fetch_blocks_by_root(_roots), do: []
  defp handle_blocks_response(_blocks, _state), do: :ok
  defp handle_status_response(_peer_id, _status, _state), do: :ok

  defp load_identity(_file), do: generate_identity()
  defp save_identity(_identity, _file), do: :ok
end
