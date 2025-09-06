defmodule ExWire.Protocol.VerkleProtocol do
  @moduledoc """
  Optimized Verkle tree protocol handler.

  This module implements an efficient network protocol specifically designed for
  Verkle tree operations. It provides optimized handling of witness requests,
  batch processing, and intelligent peer selection for maximum performance.

  Key optimizations:
  - Witness compression and deduplication
  - Intelligent request batching
  - Peer capability-based routing
  - Adaptive timeout management
  - Concurrent request processing
  """

  use GenServer
  require Logger

  alias VerkleTree
  alias VerkleTree.{Witness, KeyEncoding}
  alias ExWire.PeerSupervisor
  alias ExWire.Struct.Peer
  alias ExWire.Packet.Capability.Verkle.{GetWitnesses, Witnesses}

  @max_concurrent_requests 16
  @witness_batch_size 128
  @request_timeout_base 10_000
  @adaptive_timeout_factor 1.5
  @compression_threshold 4096
  @deduplication_window 1000

  @type request_metrics :: %{
          request_count: non_neg_integer(),
          success_count: non_neg_integer(),
          average_response_time: float(),
          compression_ratio: float()
        }

  @type peer_capability :: %{
          verkle_support: boolean(),
          max_witness_batch: non_neg_integer(),
          compression_support: boolean(),
          average_latency: non_neg_integer()
        }

  @type t :: %__MODULE__{
          verkle_tree: VerkleTree.t(),

          # Request management
          active_requests: %{reference() => request_context()},
          request_queue: :queue.queue(request_context()),
          pending_witnesses: %{binary() => reference()},
          witness_cache: %{binary() => {Witness.t(), integer()}},

          # Peer management
          peer_capabilities: %{Peer.t() => peer_capability()},
          peer_metrics: %{Peer.t() => request_metrics()},

          # Protocol optimization
          compression_enabled: boolean(),
          deduplication_enabled: boolean(),
          adaptive_batching: boolean(),

          # Statistics
          total_requests: non_neg_integer(),
          total_witnesses_received: non_neg_integer(),
          total_bytes_saved: non_neg_integer(),
          protocol_version: non_neg_integer()
        }

  @type request_context :: %{
          request_id: non_neg_integer(),
          keys: [binary()],
          root_commitment: binary(),
          requester_pid: pid(),
          started_at: integer(),
          timeout_ref: reference(),
          witness_type: atom(),
          compression_requested: boolean()
        }

  defstruct [
    :verkle_tree,
    active_requests: %{},
    request_queue: :queue.new(),
    pending_witnesses: %{},
    witness_cache: %{},
    peer_capabilities: %{},
    peer_metrics: %{},
    compression_enabled: true,
    deduplication_enabled: true,
    adaptive_batching: true,
    total_requests: 0,
    total_witnesses_received: 0,
    total_bytes_saved: 0,
    protocol_version: 1
  ]

  # Client API

  @doc """
  Start the Verkle protocol handler.
  """
  def start_link(verkle_tree, opts \\ []) do
    GenServer.start_link(__MODULE__, verkle_tree, opts)
  end

  @doc """
  Request witnesses for multiple keys with optimization.
  """
  @spec request_witnesses(pid(), binary(), [binary()], keyword()) ::
          {:ok, reference()} | {:error, term()}
  def request_witnesses(pid, root_commitment, keys, opts \\ []) do
    GenServer.call(pid, {:request_witnesses, root_commitment, keys, opts})
  end

  @doc """
  Request witnesses for healing specific keys.
  """
  @spec request_healing_witnesses(pid(), binary(), [binary()]) ::
          {:ok, reference()} | {:error, term()}
  def request_healing_witnesses(pid, root_commitment, keys) do
    GenServer.call(pid, {:request_healing_witnesses, root_commitment, keys})
  end

  @doc """
  Get protocol statistics and performance metrics.
  """
  def get_stats(pid) do
    GenServer.call(pid, :get_stats)
  end

  @doc """
  Update protocol optimization settings.
  """
  def update_settings(pid, settings) do
    GenServer.call(pid, {:update_settings, settings})
  end

  # Server Callbacks

  @impl true
  def init(verkle_tree) do
    state = %__MODULE__{
      verkle_tree: verkle_tree
    }

    Logger.info("Starting optimized Verkle protocol handler")

    # Start periodic cleanup and optimization tasks
    schedule_cache_cleanup()
    schedule_peer_capability_update()
    schedule_metrics_update()

    {:ok, state}
  end

  @impl true
  def handle_call({:request_witnesses, root_commitment, keys, opts}, from, state) do
    request_context = create_request_context(root_commitment, keys, from, :standard, opts)

    case queue_request(request_context, state) do
      {:ok, new_state, request_ref} ->
        {:reply, {:ok, request_ref}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:request_healing_witnesses, root_commitment, keys}, from, state) do
    request_context = create_request_context(root_commitment, keys, from, :healing, [])

    case queue_request(request_context, state) do
      {:ok, new_state, request_ref} ->
        {:reply, {:ok, request_ref}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = calculate_protocol_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_call({:update_settings, settings}, _from, state) do
    new_state = apply_settings(state, settings)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:process_request_queue, state) do
    new_state = process_request_queue(state)

    # Continue processing if there are queued requests
    if not :queue.is_empty(new_state.request_queue) do
      schedule_queue_processing()
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:witness_response, packet, peer}, state) do
    new_state = handle_witness_response(packet, peer, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:request_timeout, request_ref}, state) do
    new_state = handle_request_timeout(request_ref, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:cleanup_cache, state) do
    new_state = cleanup_witness_cache(state)
    schedule_cache_cleanup()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:update_peer_capabilities, state) do
    new_state = update_peer_capabilities(state)
    schedule_peer_capability_update()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:update_metrics, state) do
    new_state = update_protocol_metrics(state)
    schedule_metrics_update()
    {:noreply, new_state}
  end

  # Private Functions

  defp create_request_context(root_commitment, keys, from, witness_type, opts) do
    compression_requested =
      Keyword.get(opts, :compression, byte_size_sum(keys) > @compression_threshold)

    %{
      request_id: generate_request_id(),
      keys: keys,
      root_commitment: root_commitment,
      requester_pid: elem(from, 0),
      started_at: System.system_time(:millisecond),
      timeout_ref: nil,
      witness_type: witness_type,
      compression_requested: compression_requested
    }
  end

  defp queue_request(request_context, state) do
    # Check for deduplication opportunities
    {deduplicated_keys, cached_witnesses} =
      if state.deduplication_enabled do
        deduplicate_request(request_context.keys, state.witness_cache)
      else
        {request_context.keys, []}
      end

    if length(deduplicated_keys) == 0 do
      # All witnesses are cached, return immediately
      send_cached_response(request_context, cached_witnesses)
      {:ok, state, make_ref()}
    else
      # Queue the deduplicated request
      updated_context = %{request_context | keys: deduplicated_keys}
      new_queue = :queue.in(updated_context, state.request_queue)

      # Start processing if not already running
      if map_size(state.active_requests) == 0 do
        send(self(), :process_request_queue)
      end

      {:ok, %{state | request_queue: new_queue}, make_ref()}
    end
  end

  defp process_request_queue(state) do
    available_slots = @max_concurrent_requests - map_size(state.active_requests)

    if available_slots > 0 and not :queue.is_empty(state.request_queue) do
      # Get optimal batches from queue
      {batches, remaining_queue} =
        extract_optimal_batches(state.request_queue, available_slots, state)

      # Send requests for each batch
      new_state =
        Enum.reduce(batches, state, fn batch_requests, acc_state ->
          send_batch_request(batch_requests, acc_state)
        end)

      %{new_state | request_queue: remaining_queue}
    else
      state
    end
  end

  defp extract_optimal_batches(queue, max_batches, state) do
    # Extract requests and optimize batching
    {all_requests, empty_queue} = extract_all_requests(queue, [])

    if state.adaptive_batching do
      # Create intelligent batches based on peer capabilities and key similarity
      batches = create_adaptive_batches(all_requests, max_batches, state)
      {batches, empty_queue}
    else
      # Simple batch creation
      batches =
        Enum.chunk_every(all_requests, @witness_batch_size)
        |> Enum.take(max_batches)

      remaining_requests = all_requests |> Enum.drop(length(List.flatten(batches)))
      remaining_queue = Enum.reduce(remaining_requests, empty_queue, &:queue.in(&1, &2))

      {batches, remaining_queue}
    end
  end

  defp extract_all_requests(queue, acc) do
    case :queue.out(queue) do
      {{:value, request}, remaining_queue} ->
        extract_all_requests(remaining_queue, [request | acc])

      {:empty, queue} ->
        {Enum.reverse(acc), queue}
    end
  end

  defp create_adaptive_batches(requests, max_batches, state) do
    # Group requests by similarity and peer capability
    grouped_requests = group_requests_by_similarity(requests)

    # Create batches considering peer capabilities
    Enum.take(grouped_requests, max_batches)
    |> Enum.map(fn group ->
      optimize_batch_for_peers(group, state)
    end)
  end

  defp group_requests_by_similarity(requests) do
    # Group requests that have similar key patterns or root commitments
    requests
    |> Enum.group_by(fn req -> req.root_commitment end)
    |> Map.values()
    |> Enum.map(fn group ->
      Enum.take(group, @witness_batch_size)
    end)
  end

  defp optimize_batch_for_peers(batch_requests, state) do
    # Select optimal peer and adjust batch based on capabilities
    best_peer = select_optimal_peer(batch_requests, state)

    case Map.get(state.peer_capabilities, best_peer) do
      %{max_witness_batch: max_batch} when max_batch < length(batch_requests) ->
        Enum.take(batch_requests, max_batch)

      _ ->
        batch_requests
    end
  end

  defp send_batch_request(batch_requests, state) do
    peer = select_optimal_peer(batch_requests, state)

    if peer do
      # Create combined request
      combined_keys = Enum.flat_map(batch_requests, & &1.keys)
      root_commitment = hd(batch_requests).root_commitment

      # Check if compression should be used
      compression_enabled = should_use_compression(combined_keys, peer, state)

      # Create GetWitnesses packet
      packet =
        GetWitnesses.create_batch_request(
          generate_request_id(),
          root_commitment,
          combined_keys,
          compression: compression_enabled
        )

      # Send packet to peer
      request_ref = send_packet_to_peer(peer, packet)

      # Set up timeout
      timeout = calculate_adaptive_timeout(peer, state)
      timeout_ref = Process.send_after(self(), {:request_timeout, request_ref}, timeout)

      # Track requests
      batch_context = %{
        requests: batch_requests,
        peer: peer,
        started_at: System.system_time(:millisecond),
        timeout_ref: timeout_ref,
        compression_used: compression_enabled
      }

      new_active_requests = Map.put(state.active_requests, request_ref, batch_context)

      %{
        state
        | active_requests: new_active_requests,
          total_requests: state.total_requests + length(batch_requests)
      }
    else
      Logger.warning("No suitable peer found for witness requests")
      state
    end
  end

  defp select_optimal_peer(batch_requests, state) do
    # Select peer based on capabilities, latency, and success rate
    available_peers = PeerSupervisor.connected_peers()

    available_peers
    |> Enum.filter(&supports_verkle_protocol/1)
    |> Enum.max_by(
      fn peer ->
        calculate_peer_score(peer, batch_requests, state)
      end,
      fn -> nil end
    )
  end

  defp calculate_peer_score(peer, batch_requests, state) do
    capability = Map.get(state.peer_capabilities, peer, default_peer_capability())
    metrics = Map.get(state.peer_metrics, peer, default_peer_metrics())

    # Calculate score based on multiple factors
    capability_score = if capability.verkle_support, do: 100, else: 0
    batch_score = min(capability.max_witness_batch / length(batch_requests), 1.0) * 50
    latency_score = max(0, 100 - capability.average_latency / 100)
    success_score = metrics.success_count / max(metrics.request_count, 1) * 100
    compression_score = if capability.compression_support, do: 25, else: 0

    capability_score + batch_score + latency_score + success_score + compression_score
  end

  defp handle_witness_response(packet, peer, state) do
    case Witnesses.validate(packet) do
      {:ok, validated_packet} ->
        process_witness_packet(validated_packet, peer, state)

      {:error, reason} ->
        Logger.warning("Invalid witness packet from peer: #{inspect(reason)}")
        state
    end
  end

  defp process_witness_packet(packet, peer, state) do
    # Find the corresponding request
    request_context = find_request_by_id(packet.request_id, state.active_requests)

    if request_context do
      # Verify witnesses
      if Witnesses.verify_all_witnesses(packet) do
        # Update cache with new witnesses
        new_cache = update_witness_cache(state.witness_cache, packet)

        # Send responses to requesting processes
        send_witness_responses(request_context.requests, packet)

        # Update peer metrics
        new_metrics = update_peer_metrics(state.peer_metrics, peer, request_context, :success)

        # Calculate bytes saved through compression
        bytes_saved = calculate_compression_savings(packet)

        # Remove from active requests
        new_active_requests = remove_completed_request(state.active_requests, packet.request_id)

        %{
          state
          | witness_cache: new_cache,
            peer_metrics: new_metrics,
            active_requests: new_active_requests,
            total_witnesses_received: state.total_witnesses_received + packet.total_witnesses,
            total_bytes_saved: state.total_bytes_saved + bytes_saved
        }
      else
        Logger.warning("Witness verification failed from peer")
        handle_verification_failure(packet.request_id, peer, state)
      end
    else
      Logger.debug("Received witness response for unknown request ID: #{packet.request_id}")
      state
    end
  end

  defp handle_request_timeout(request_ref, state) do
    case Map.get(state.active_requests, request_ref) do
      nil ->
        state

      batch_context ->
        Logger.debug(
          "Witness request timeout for batch of #{length(batch_context.requests)} requests"
        )

        # Update peer metrics for timeout
        new_metrics =
          update_peer_metrics(
            state.peer_metrics,
            batch_context.peer,
            batch_context,
            :timeout
          )

        # Retry or fail the requests
        new_state = handle_request_retry_or_failure(batch_context, state)

        # Remove from active requests
        new_active_requests = Map.delete(new_state.active_requests, request_ref)

        %{new_state | active_requests: new_active_requests, peer_metrics: new_metrics}
    end
  end

  # Helper Functions

  defp deduplicate_request(keys, witness_cache) do
    current_time = System.system_time(:millisecond)

    Enum.reduce(keys, {[], []}, fn key, {remaining_keys, cached_witnesses} ->
      cache_key = :crypto.hash(:sha256, key)

      case Map.get(witness_cache, cache_key) do
        {witness, cached_at} when current_time - cached_at < @deduplication_window ->
          {remaining_keys, [{key, witness} | cached_witnesses]}

        _ ->
          {[key | remaining_keys], cached_witnesses}
      end
    end)
  end

  defp should_use_compression(keys, peer, state) do
    state.compression_enabled and
      supports_compression(peer, state) and
      byte_size_sum(keys) > @compression_threshold
  end

  defp calculate_adaptive_timeout(peer, state) do
    base_timeout = @request_timeout_base

    case Map.get(state.peer_capabilities, peer) do
      %{average_latency: latency} ->
        round(base_timeout + latency * @adaptive_timeout_factor)

      _ ->
        base_timeout
    end
  end

  defp supports_verkle_protocol(peer) do
    # Check if peer supports Verkle protocol
    # This would check peer capabilities during handshake
    true
  end

  defp supports_compression(peer, state) do
    case Map.get(state.peer_capabilities, peer) do
      %{compression_support: true} -> true
      _ -> false
    end
  end

  defp byte_size_sum(keys) do
    Enum.reduce(keys, 0, fn key, acc -> acc + byte_size(key) end)
  end

  defp generate_request_id do
    :rand.uniform(0xFFFFFFFF)
  end

  defp default_peer_capability do
    %{
      verkle_support: true,
      max_witness_batch: @witness_batch_size,
      compression_support: false,
      average_latency: 1000
    }
  end

  defp default_peer_metrics do
    %{
      request_count: 0,
      success_count: 0,
      average_response_time: 0.0,
      compression_ratio: 1.0
    }
  end

  # Scheduling functions

  defp schedule_queue_processing do
    Process.send_after(self(), :process_request_queue, 100)
  end

  defp schedule_cache_cleanup do
    # 5 minutes
    Process.send_after(self(), :cleanup_cache, 300_000)
  end

  defp schedule_peer_capability_update do
    # 1 minute
    Process.send_after(self(), :update_peer_capabilities, 60_000)
  end

  defp schedule_metrics_update do
    # 30 seconds
    Process.send_after(self(), :update_metrics, 30_000)
  end

  # Stub implementations for functions that would require more context

  defp send_cached_response(_request_context, _cached_witnesses), do: :ok
  defp send_packet_to_peer(_peer, _packet), do: make_ref()
  defp find_request_by_id(_request_id, _active_requests), do: nil
  defp update_witness_cache(cache, _packet), do: cache
  defp send_witness_responses(_requests, _packet), do: :ok
  defp update_peer_metrics(metrics, _peer, _context, _result), do: metrics
  defp calculate_compression_savings(_packet), do: 0
  defp remove_completed_request(active_requests, _request_id), do: active_requests
  defp handle_verification_failure(_request_id, _peer, state), do: state
  defp handle_request_retry_or_failure(_batch_context, state), do: state
  defp cleanup_witness_cache(state), do: state
  defp update_peer_capabilities(state), do: state
  defp update_protocol_metrics(state), do: state
  defp calculate_protocol_stats(state), do: %{}
  defp apply_settings(state, _settings), do: state
end
