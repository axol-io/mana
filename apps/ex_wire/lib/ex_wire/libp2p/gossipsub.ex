defmodule ExWire.LibP2P.GossipSub do
  @moduledoc """
  GossipSub protocol implementation for Ethereum 2.0 consensus layer.

  Implements the GossipSub v1.1 protocol with:
  - Mesh-based message propagation
  - Opportunistic grafting
  - Adaptive gossip dissemination
  - Peer scoring and pruning
  - EIP-4844 blob sidecar propagation
  """

  use GenServer
  require Logger

  # GossipSub parameters
  # Target degree for mesh
  @d 8
  # Lower bound for mesh degree
  @d_low 6
  # Upper bound for mesh degree
  @d_high 12
  # Degree for gossip emission
  @d_lazy 6
  # 1 second
  @heartbeat_interval 1_000
  # 1 minute
  @fanout_ttl 60_000
  # Message cache history length
  @mcache_len 5
  # Number of history windows to gossip
  @mcache_gossip 3
  # 2 minutes
  @seen_ttl 120_000

  # EIP-4844 constants
  @max_blobs_per_block 6
  @blob_sidecar_topic_prefix "/eth2/9c2887af/blob_sidecar_"

  # Scoring parameters
  # Time in mesh weight
  @p1 1.0
  # First message deliveries weight
  @p2 1.0
  # Mesh message deliveries weight
  @p3 1.0
  # Mesh message deliveries threshold
  @p3b 0.5
  # Invalid message weight
  @p4 -1.0
  # 1 second
  @decay_interval 1_000
  @decay_to_zero 0.01

  defstruct [
    :node_id,
    :d,
    :d_low,
    :d_high,
    :d_lazy,
    # topic => MapSet of peer_ids
    mesh: %{},
    # topic => MapSet of peer_ids
    fanout: %{},
    # peer_id => peer_info
    peers: %{},
    # topic => MapSet of interested peers
    topics: %{},
    # Message cache (ring buffer)
    mcache: [],
    # message_id => timestamp
    seen: %{},
    # peer_id => score
    scores: %{},
    # topic => handler function
    handlers: %{},
    config: %{}
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe to a topic
  """
  def subscribe(server \\ __MODULE__, topic) do
    GenServer.call(server, {:subscribe, topic})
  end

  @doc """
  Unsubscribe from a topic
  """
  def unsubscribe(server \\ __MODULE__, topic) do
    GenServer.call(server, {:unsubscribe, topic})
  end

  @doc """
  Publish a message to a topic
  """
  def publish(server \\ __MODULE__, topic, message) do
    GenServer.cast(server, {:publish, topic, message})
  end

  @doc """
  Subscribe to all blob sidecar topics for EIP-4844
  """
  def subscribe_to_blob_sidecars(server \\ __MODULE__) do
    for index <- 0..(@max_blobs_per_block - 1) do
      topic = blob_sidecar_topic(index)
      GenServer.call(server, {:subscribe, topic})
    end
  end

  @doc """
  Publish a blob sidecar to the appropriate gossip topic
  """
  def publish_blob_sidecar(server \\ __MODULE__, blob_sidecar) do
    # Validate blob sidecar before publishing
    case ExWire.Eth2.BlobVerification.validate_blob_sidecar_for_gossip(blob_sidecar) do
      {:ok, :valid} ->
        topic = blob_sidecar_topic(blob_sidecar.index)
        # Serialize with SSZ and compress
        serialized = SSZ.encode(blob_sidecar) |> compress_snappy()
        GenServer.cast(server, {:publish, topic, serialized})

      {:error, _reason} ->
        Logger.warning("Invalid blob sidecar for gossip: #{inspect(reason)}")
        {:error, _reason}
    end
  end

  @doc """
  Get the blob sidecar topic name for a given index
  """
  def blob_sidecar_topic(index) when index >= 0 and index < @max_blobs_per_block do
    @blob_sidecar_topic_prefix <> Integer.to_string(index) <> "/ssz_snappy"
  end

  @doc """
  Add a peer to the protocol
  """
  def add_peer(server \\ __MODULE__, peer_id, peer_info) do
    GenServer.cast(server, {:add_peer, peer_id, peer_info})
  end

  @doc """
  Remove a peer from the protocol
  """
  def remove_peer(server \\ __MODULE__, peer_id) do
    GenServer.cast(server, {:remove_peer, peer_id})
  end

  @doc """
  Handle incoming message from a peer
  """
  def handle_message(server \\ __MODULE__, peer_id, message) do
    GenServer.cast(server, {:handle_message, peer_id, message})
  end

  @doc """
  Register a message handler for a topic
  """
  def register_handler(server \\ __MODULE__, topic, handler) do
    GenServer.call(server, {:register_handler, topic, handler})
  end

  @doc """
  Get mesh peers for a topic
  """
  def get_mesh_peers(server \\ __MODULE__, topic) do
    GenServer.call(server, {:get_mesh_peers, topic})
  end

  @doc """
  Propagate a message to peers (excluding source)
  """
  def propagate(server \\ __MODULE__, topic, message, source_peer) do
    GenServer.cast(server, {:propagate, topic, message, source_peer})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %__MODULE__{
      node_id: Keyword.fetch!(opts, :node_id),
      d: Keyword.get(opts, :d, @d),
      d_low: Keyword.get(opts, :d_low, @d_low),
      d_high: Keyword.get(opts, :d_high, @d_high),
      d_lazy: Keyword.get(opts, :d_lazy, @d_lazy),
      mesh: %{},
      fanout: %{},
      peers: %{},
      topics: %{},
      mcache: List.duplicate([], @mcache_len),
      seen: %{},
      scores: %{},
      handlers: %{},
      config: build_config(opts)
    }

    # Schedule heartbeat
    schedule_heartbeat()

    # Schedule cache cleanup
    schedule_cleanup()

    {:ok, _state}
  end

  @impl true
  def handle_call({:subscribe, topic}, _from, _state) do
    Logger.debug("Subscribing to topic: #{topic}")

    # Add topic to our interests
    new_topics = Map.update(state.topics, topic, MapSet.new(), & &1)

    # Join mesh for this topic
    {mesh_peers, new_state} = join_mesh(topic, state)

    # Notify peers of subscription
    broadcast_subscription(topic, mesh_peers)

    {:reply, :ok, %{new_state | topics: new_topics}}
  end

  def handle_call({:unsubscribe, topic}, _from, _state) do
    Logger.debug("Unsubscribing from topic: #{topic}")

    # Leave mesh for this topic
    new_state = leave_mesh(topic, state)

    # Remove topic from our interests
    new_topics = Map.delete(new_state.topics, topic)

    # Notify peers of unsubscription
    broadcast_unsubscription(topic, Map.get(state.mesh, topic, MapSet.new()))

    {:reply, :ok, %{new_state | topics: new_topics}}
  end

  def handle_call({:register_handler, topic, handler}, _from, _state) do
    new_handlers = Map.put(state.handlers, topic, handler)
    {:reply, :ok, %{state | handlers: new_handlers}}
  end

  def handle_call({:get_mesh_peers, topic}, _from, _state) do
    peers = Map.get(state.mesh, topic, MapSet.new())
    {:reply, MapSet.to_list(peers), state}
  end

  @impl true
  def handle_cast({:publish, topic, message}, _state) do
    message_id = compute_message_id(message)

    # Check if we've seen this message
    if Map.has_key?(state.seen, message_id) do
      {:noreply, state}
    else
      # Mark as seen
      new_seen = Map.put(state.seen, message_id, System.system_time(:millisecond))

      # Add to message cache
      new_mcache = add_to_cache(state.mcache, {topic, message_id, message})

      # Determine target peers
      peers = get_publish_peers(topic, state)

      # Send to mesh peers
      Enum.each(peers, fn peer_id ->
        send_message(peer_id, topic, message)
      end)

      # Send gossip to non-mesh peers
      gossip_peers = get_gossip_peers(topic, peers, state)

      Enum.each(gossip_peers, fn peer_id ->
        send_ihave(peer_id, topic, [message_id])
      end)

      {:noreply, %{state | seen: new_seen, mcache: new_mcache}}
    end
  end

  def handle_cast({:add_peer, peer_id, peer_info}, _state) do
    Logger.debug("Adding peer: #{inspect(peer_id)}")

    new_peers =
      Map.put(
        state.peers,
        peer_id,
        Map.merge(peer_info, %{
          topics: MapSet.new(),
          score: 0.0,
          behaviour_penalty: 0.0,
          time_in_mesh: %{},
          first_message_deliveries: %{},
          mesh_message_deliveries: %{},
          invalid_messages: 0
        })
      )

    # Initialize score
    new_scores = Map.put(state.scores, peer_id, 0.0)

    {:noreply, %{state | peers: new_peers, scores: new_scores}}
  end

  def handle_cast({:remove_peer, peer_id}, _state) do
    Logger.debug("Removing peer: #{inspect(peer_id)}")

    # Remove from all meshes
    new_mesh =
      Enum.reduce(state.mesh, %{}, fn {topic, peers}, acc ->
        Map.put(acc, topic, MapSet.delete(peers, peer_id))
      end)

    # Remove from fanout
    new_fanout =
      Enum.reduce(state.fanout, %{}, fn {topic, peers}, acc ->
        Map.put(acc, topic, MapSet.delete(peers, peer_id))
      end)

    # Remove from topics
    new_topics =
      Enum.reduce(state.topics, %{}, fn {topic, peers}, acc ->
        Map.put(acc, topic, MapSet.delete(peers, peer_id))
      end)

    # Remove peer info
    new_peers = Map.delete(state.peers, peer_id)
    new_scores = Map.delete(state.scores, peer_id)

    {:noreply,
     %{
       state
       | mesh: new_mesh,
         fanout: new_fanout,
         topics: new_topics,
         peers: new_peers,
         scores: new_scores
     }}
  end

  def handle_cast({:handle_message, peer_id, %{type: :rpc} = message}, _state) do
    new_state = handle_rpc(peer_id, message, state)
    {:noreply, new_state}
  end

  def handle_cast({:propagate, topic, message, source_peer}, _state) do
    message_id = compute_message_id(message)

    # Get mesh peers excluding source
    mesh_peers =
      Map.get(state.mesh, topic, MapSet.new())
      |> MapSet.delete(source_peer)

    # Propagate to mesh
    Enum.each(mesh_peers, fn peer_id ->
      send_message(peer_id, topic, message)
    end)

    # Gossip to additional peers
    gossip_peers = get_gossip_peers(topic, MapSet.to_list(mesh_peers), state)

    Enum.each(gossip_peers, fn peer_id ->
      if peer_id != source_peer do
        send_ihave(peer_id, topic, [message_id])
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, _state) do
    new_state =
      state
      |> maintain_mesh()
      |> emit_gossip()
      |> update_scores()
      |> prune_low_scored_peers()

    schedule_heartbeat()
    {:noreply, new_state}
  end

  def handle_info(:cleanup, _state) do
    # Clean up old seen messages
    now = System.system_time(:millisecond)

    new_seen =
      Map.filter(state.seen, fn {_id, timestamp} ->
        now - timestamp < @seen_ttl
      end)

    # Clean up fanout
    new_fanout =
      Map.filter(state.fanout, fn {_topic, last_pub} ->
        now - last_pub < @fanout_ttl
      end)

    schedule_cleanup()
    {:noreply, %{state | seen: new_seen, fanout: new_fanout}}
  end

  # Private Functions - Mesh Management

  defp join_mesh(topic, _state) do
    current_peers = Map.get(state.mesh, topic, MapSet.new())

    # Get peers interested in this topic
    interested_peers = get_topic_peers(topic, state)

    # Select peers to add to mesh
    needed = state.d - MapSet.size(current_peers)

    if needed > 0 do
      candidates =
        interested_peers
        |> MapSet.difference(current_peers)
        |> MapSet.to_list()
        |> Enum.sort_by(fn peer_id -> Map.get(state.scores, peer_id, 0) end, :desc)
        |> Enum.take(needed)

      new_mesh_peers =
        Enum.reduce(candidates, current_peers, fn peer_id, acc ->
          send_graft(peer_id, topic)
          MapSet.put(acc, peer_id)
        end)

      new_mesh = Map.put(state.mesh, topic, new_mesh_peers)
      {new_mesh_peers, %{state | mesh: new_mesh}}
    else
      {current_peers, state}
    end
  end

  defp leave_mesh(topic, _state) do
    case Map.get(state.mesh, topic) do
      nil ->
        state

      mesh_peers ->
        # Send PRUNE to all mesh peers
        Enum.each(mesh_peers, fn peer_id ->
          send_prune(peer_id, topic)
        end)

        # Remove mesh
        new_mesh = Map.delete(state.mesh, topic)
        %{_state | mesh: new_mesh}
    end
  end

  defp maintain_mesh(_state) do
    Enum.reduce(state.mesh, state, fn {topic, peers}, acc_state ->
      peer_count = MapSet.size(peers)

      cond do
        peer_count < acc_state.d_low ->
          # Need more peers
          graft_peers(topic, acc_state.d - peer_count, acc_state)

        peer_count > acc_state.d_high ->
          # Too many peers
          prune_peers(topic, peer_count - acc_state.d, acc_state)

        true ->
          # Opportunistic grafting
          opportunistic_graft(topic, acc_state)
      end
    end)
  end

  defp graft_peers(topic, count, _state) do
    current_peers = Map.get(state.mesh, topic, MapSet.new())
    interested_peers = get_topic_peers(topic, state)

    candidates =
      interested_peers
      |> MapSet.difference(current_peers)
      |> MapSet.to_list()
      |> Enum.sort_by(fn peer_id -> Map.get(state.scores, peer_id, 0) end, :desc)
      |> Enum.take(count)

    new_mesh_peers =
      Enum.reduce(candidates, current_peers, fn peer_id, acc ->
        send_graft(peer_id, topic)
        MapSet.put(acc, peer_id)
      end)

    new_mesh = Map.put(state.mesh, topic, new_mesh_peers)
    %{state | mesh: new_mesh}
  end

  defp prune_peers(topic, count, _state) do
    current_peers = Map.get(state.mesh, topic, MapSet.new())

    # Select lowest scored peers to prune
    to_prune =
      current_peers
      |> MapSet.to_list()
      |> Enum.sort_by(fn peer_id -> Map.get(state.scores, peer_id, 0) end)
      |> Enum.take(count)

    new_mesh_peers =
      Enum.reduce(to_prune, current_peers, fn peer_id, acc ->
        send_prune(peer_id, topic)
        MapSet.delete(acc, peer_id)
      end)

    new_mesh = Map.put(state.mesh, topic, new_mesh_peers)
    %{state | mesh: new_mesh}
  end

  defp opportunistic_graft(topic, _state) do
    # Randomly select peer with good score to graft
    current_peers = Map.get(state.mesh, topic, MapSet.new())

    if MapSet.size(current_peers) < state.d_high do
      interested_peers = get_topic_peers(topic, state)

      candidates =
        interested_peers
        |> MapSet.difference(current_peers)
        |> MapSet.to_list()
        |> Enum.filter(fn peer_id -> Map.get(state.scores, peer_id, 0) > 0 end)

      case candidates do
        [] ->
          state

        peers ->
          selected = Enum.random(peers)
          send_graft(selected, topic)

          new_mesh_peers = MapSet.put(current_peers, selected)
          new_mesh = Map.put(state.mesh, topic, new_mesh_peers)
          %{_state | mesh: new_mesh}
      end
    else
      state
    end
  end

  # Private Functions - Gossip

  defp emit_gossip(_state) do
    # Get recent messages from cache
    gossip_messages = get_gossip_messages(state.mcache)

    # For each topic, send IHAVE to peers not in mesh
    Enum.each(gossip_messages, fn {topic, message_ids} ->
      mesh_peers = Map.get(state.mesh, topic, MapSet.new())
      gossip_peers = get_gossip_peers(topic, MapSet.to_list(mesh_peers), state)

      Enum.each(gossip_peers, fn peer_id ->
        send_ihave(peer_id, topic, message_ids)
      end)
    end)

    # Shift message cache
    new_mcache = shift_cache(state.mcache)
    %{state | mcache: new_mcache}
  end

  defp get_gossip_messages(mcache) do
    # Get messages from recent history windows
    mcache
    |> Enum.take(@mcache_gossip)
    |> List.flatten()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp get_gossip_peers(topic, exclude_peers, _state) do
    interested_peers = get_topic_peers(topic, state)

    interested_peers
    |> MapSet.difference(MapSet.new(exclude_peers))
    |> MapSet.to_list()
    |> Enum.shuffle()
    |> Enum.take(state.d_lazy)
  end

  # Private Functions - RPC Handling

  defp handle_rpc(peer_id, %{type: :rpc, messages: messages, control: control}, _state) do
    # Handle messages
    new_state =
      Enum.reduce(messages, state, fn msg, acc ->
        handle_publish(peer_id, msg.topic, msg.data, acc)
      end)

    # Handle control messages
    handle_control(peer_id, control, new_state)
  end

  defp handle_publish(peer_id, topic, data, _state) do
    message_id = compute_message_id(data)

    # Check if seen
    if Map.has_key?(state.seen, message_id) do
      state
    else
      # Validate message based on topic type
      case validate_gossip_message(topic, data, peer_id) do
        :ok ->
          # Mark as seen
          new_seen = Map.put(state.seen, message_id, System.system_time(:millisecond))

          # Add to cache
          new_mcache = add_to_cache(_state.mcache, {topic, message_id, data})

          # Update peer score (first message delivery)
          new_state = update_peer_score(peer_id, topic, :first_delivery, state)

          # Deliver to application
          deliver_message(topic, data, state)

          # Forward to mesh (except source)
          mesh_peers =
            Map.get(new_state.mesh, topic, MapSet.new())
            |> MapSet.delete(peer_id)

          Enum.each(mesh_peers, fn forward_peer ->
            send_message(forward_peer, topic, data)
          end)

          %{new_state | seen: new_seen, mcache: new_mcache}

        {:error, _reason} ->
          # Invalid message - penalize peer
          Logger.warning(
            "Invalid message from peer #{inspect(peer_id)} on topic #{topic}: #{inspect(reason)}"
          )

          penalize_peer(peer_id, :invalid_message, state)
      end
    end
  end

  defp handle_control(peer_id, control, _state) do
    state
    |> handle_ihave(peer_id, control.ihave)
    |> handle_iwant(peer_id, control.iwant)
    |> handle_graft(peer_id, control.graft)
    |> handle_prune(peer_id, control.prune)
  end

  defp handle_ihave(_state, _peer_id, []), do: state

  defp handle_ihave(_state, peer_id, ihave_messages) do
    # Collect message IDs we want
    wanted =
      Enum.flat_map(ihave_messages, fn %{topic: topic, message_ids: ids} ->
        if Map.has_key?(state.topics, topic) do
          Enum.filter(ids, fn id -> not Map.has_key?(state.seen, id) end)
        else
          []
        end
      end)

    # Request wanted messages
    if wanted != [] do
      send_iwant(peer_id, wanted)
    end

    state
  end

  defp handle_iwant(_state, peer_id, message_ids) do
    # Send requested messages from cache
    Enum.each(message_ids, fn msg_id ->
      case find_in_cache(state.mcache, msg_id) do
        nil -> :ok
        {topic, _id, data} -> send_message(peer_id, topic, data)
      end
    end)

    state
  end

  defp handle_graft(_state, peer_id, topics) do
    Enum.reduce(topics, state, fn topic, acc ->
      if Map.has_key?(acc.topics, topic) do
        # Add peer to mesh
        current_mesh = Map.get(acc.mesh, topic, MapSet.new())

        if MapSet.size(current_mesh) < acc.d_high do
          new_mesh = MapSet.put(current_mesh, peer_id)
          %{acc | mesh: Map.put(acc.mesh, topic, new_mesh)}
        else
          # Reject graft - mesh is full
          send_prune(peer_id, topic)
          acc
        end
      else
        # We're not subscribed to this topic
        send_prune(peer_id, topic)
        acc
      end
    end)
  end

  defp handle_prune(_state, peer_id, topics) do
    Enum.reduce(topics, state, fn topic, acc ->
      case Map.get(acc.mesh, topic) do
        nil ->
          acc

        mesh_peers ->
          new_mesh = MapSet.delete(mesh_peers, peer_id)
          %{acc | mesh: Map.put(acc.mesh, topic, new_mesh)}
      end
    end)
  end

  # Private Functions - Scoring

  defp update_scores(_state) do
    now = System.system_time(:millisecond)

    new_scores =
      Enum.reduce(state.peers, %{}, fn {peer_id, peer_info}, acc ->
        score = calculate_peer_score(peer_id, peer_info, state, now)
        Map.put(acc, peer_id, score)
      end)

    %{state | scores: new_scores}
  end

  defp calculate_peer_score(peer_id, peer_info, _state, now) do
    # P1: Time in mesh
    p1_score =
      Enum.reduce(peer_info.time_in_mesh, 0.0, fn {_topic, time}, acc ->
        acc + @p1 * (now - time) / 1000
      end)

    # P2: First message deliveries
    p2_score =
      Enum.reduce(peer_info.first_message_deliveries, 0.0, fn {_topic, count}, acc ->
        acc + @p2 * count
      end)

    # P3: Mesh message deliveries
    p3_score =
      Enum.reduce(peer_info.mesh_message_deliveries, 0.0, fn {_topic, count}, acc ->
        if count >= @p3b do
          acc + @p3 * count
        else
          acc
        end
      end)

    # P4: Invalid messages
    p4_score = @p4 * peer_info.invalid_messages

    # Behaviour penalty
    behaviour_penalty = peer_info.behaviour_penalty

    p1_score + p2_score + p3_score + p4_score - behaviour_penalty
  end

  defp update_peer_score(peer_id, topic, :first_delivery, _state) do
    case Map.get(state.peers, peer_id) do
      nil ->
        _state

      peer_info ->
        deliveries = Map.get(peer_info.first_message_deliveries, topic, 0)
        new_deliveries = Map.put(peer_info.first_message_deliveries, topic, deliveries + 1)
        new_peer_info = %{peer_info | first_message_deliveries: new_deliveries}
        new_peers = Map.put(state.peers, peer_id, new_peer_info)
        %{state | peers: new_peers}
    end
  end

  defp prune_low_scored_peers(_state) do
    # Remove peers with very low scores
    threshold = -100.0

    peers_to_remove =
      state.scores
      |> Enum.filter(fn {_peer_id, score} -> score < threshold end)
      |> Enum.map(&elem(&1, 0))

    Enum.reduce(peers_to_remove, state, fn peer_id, acc ->
      elem(handle_cast({:remove_peer, peer_id}, acc), 1)
    end)
  end

  # Private Functions - Utilities

  defp get_topic_peers(topic, _state) do
    Map.get(state.topics, topic, MapSet.new())
  end

  defp get_publish_peers(topic, _state) do
    case Map.get(state.mesh, topic) do
      nil ->
        # Not in mesh, use fanout
        case Map.get(state.fanout, topic) do
          nil ->
            # Create new fanout
            interested_peers = get_topic_peers(topic, state)

            fanout_peers =
              interested_peers
              |> MapSet.to_list()
              |> Enum.shuffle()
              |> Enum.take(_state.d)
              |> MapSet.new()

            fanout_peers

          fanout_peers ->
            fanout_peers
        end

      mesh_peers ->
        MapSet.to_list(mesh_peers)
    end
  end

  defp add_to_cache([_oldest | rest], entry) do
    rest ++ [[entry]]
  end

  defp shift_cache([_oldest | rest]) do
    rest ++ [[]]
  end

  defp find_in_cache(cache, message_id) do
    cache
    |> List.flatten()
    |> Enum.find(fn {_topic, id, _data} -> id == message_id end)
  end

  defp compute_message_id(message) do
    :crypto.hash(:sha256, message) |> Base.encode16()
  end

  defp deliver_message(topic, message, _state) do
    case Map.get(state.handlers, topic) do
      nil ->
        Logger.debug("No handler for topic: #{topic}")

      handler ->
        handler.(topic, message)
    end
  end

  defp build_config(opts) do
    %{
      heartbeat_interval: Keyword.get(opts, :heartbeat_interval, @heartbeat_interval),
      fanout_ttl: Keyword.get(opts, :fanout_ttl, @fanout_ttl),
      seen_ttl: Keyword.get(opts, :seen_ttl, @seen_ttl),
      mcache_len: Keyword.get(opts, :mcache_len, @mcache_len),
      mcache_gossip: Keyword.get(opts, :mcache_gossip, @mcache_gossip)
    }
  end

  # Private Functions - Communication

  defp send_message(peer_id, topic, message) do
    # Send via transport
    send(peer_id, {:gossipsub_message, topic, message})
  end

  defp send_ihave(peer_id, topic, message_ids) do
    send(peer_id, {:gossipsub_control, :ihave, topic, message_ids})
  end

  defp send_iwant(peer_id, message_ids) do
    send(peer_id, {:gossipsub_control, :iwant, message_ids})
  end

  defp send_graft(peer_id, topic) do
    send(peer_id, {:gossipsub_control, :graft, topic})
  end

  defp send_prune(peer_id, topic) do
    send(peer_id, {:gossipsub_control, :prune, topic})
  end

  defp broadcast_subscription(topic, peers) do
    Enum.each(peers, fn peer_id ->
      send(peer_id, {:gossipsub_subscription, :subscribe, topic})
    end)
  end

  defp broadcast_unsubscription(topic, peers) do
    Enum.each(peers, fn peer_id ->
      send(peer_id, {:gossipsub_subscription, :unsubscribe, topic})
    end)
  end

  # Private Functions - Scheduling

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @seen_ttl)
  end

  # Private Functions - Message Validation

  defp validate_gossip_message(topic, data, _peer_id) do
    cond do
      String.starts_with?(topic, @blob_sidecar_topic_prefix) ->
        validate_blob_sidecar_message(topic, data)

      String.contains?(topic, "/beacon_block/") ->
        validate_beacon_block_message(data)

      String.contains?(topic, "/attestation_") ->
        validate_attestation_message(data)

      true ->
        # For other topics, basic validation
        # 1MB limit
        if byte_size(data) > 0 and byte_size(data) < 1_048_576 do
          :ok
        else
          {:error, :invalid_message_size}
        end
    end
  end

  defp validate_blob_sidecar_message(topic, data) do
    with {:ok, decompressed} <- decompress_snappy(data),
         {:ok, blob_sidecar} <- SSZ.decode(decompressed),
         {:ok, expected_index} <- extract_blob_index_from_topic(topic),
         :ok <- validate_blob_sidecar_index(blob_sidecar, expected_index),
         {:ok, :valid} <-
           ExWire.Eth2.BlobVerification.validate_blob_sidecar_for_gossip(blob_sidecar) do
      :ok
    else
      {:error, _reason} -> {:error, {:blob_sidecar_validation, reason}}
    end
  end

  defp validate_beacon_block_message(data) do
    with {:ok, decompressed} <- decompress_snappy(data),
         {:ok, _block} <- SSZ.decode(decompressed) do
      # Basic structural validation - full validation done by consensus layer
      :ok
    else
      {:error, _reason} -> {:error, {:beacon_block_validation, reason}}
    end
  end

  defp validate_attestation_message(data) do
    with {:ok, decompressed} <- decompress_snappy(data),
         {:ok, _attestation} <- SSZ.decode(decompressed) do
      # Basic structural validation - full validation done by consensus layer
      :ok
    else
      {:error, _reason} -> {:error, {:attestation_validation, reason}}
    end
  end

  defp validate_blob_sidecar_index(blob_sidecar, expected_index) do
    if Map.get(blob_sidecar, :index) == expected_index do
      :ok
    else
      {:error, {:index_mismatch, expected_index, Map.get(blob_sidecar, :index)}}
    end
  end

  defp extract_blob_index_from_topic(topic) do
    case Regex.run(~r/blob_sidecar_(\d+)/, topic) do
      [_, index_str] ->
        case Integer.parse(index_str) do
          {index, ""} when index >= 0 and index < @max_blobs_per_block ->
            {:ok, index}

          _ ->
            {:error, :invalid_blob_index}
        end

      _ ->
        {:error, :invalid_topic_format}
    end
  end

  defp penalize_peer(peer_id, _reason, _state) do
    case Map.get(state.peers, peer_id) do
      nil ->
        _state

      peer_info ->
        penalty =
          case _reason do
            :invalid_message -> 10.0
            :malformed_data -> 5.0
            _ -> 1.0
          end

        new_penalty = peer_info.behaviour_penalty + penalty
        new_invalid_count = peer_info.invalid_messages + 1

        new_peer_info = %{
          peer_info
          | behaviour_penalty: new_penalty,
            invalid_messages: new_invalid_count
        }

        new_peers = Map.put(state.peers, peer_id, new_peer_info)
        %{state | peers: new_peers}
    end
  end

  # Private Functions - Compression

  defp compress_snappy(data) do
    # Placeholder for snappy compression
    # In production, would use :snappyer or similar
    data
  end

  defp decompress_snappy(data) do
    # Placeholder for snappy decompression
    # In production, would use :snappyer or similar
    {:ok, data}
  end
end
