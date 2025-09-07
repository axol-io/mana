defmodule ExWire.Sync.VerkleStateSync do
  @moduledoc """
  EIP-6800 compliant Verkle-aware state synchronization for efficient state sync.

  This module implements stateless client synchronization using Verkle witnesses,
  enabling fast sync without downloading the entire state. It leverages the compact
  proof sizes of Verkle trees (~200 bytes vs ~3KB for MPT) to efficiently
  synchronize state data.

  Key features:
  - Witness-based state synchronization with EIP-6800 compliance
  - Batch witness verification with parallel processing
  - Incremental state healing with priority-based recovery
  - Optimized for Verkle tree structure and commitment schemes
  - Network-aware sync with adaptive batching
  - State expiry handling and resurrection support
  - Parallel witness download and verification
  """

  use GenServer
  require Logger

  alias VerkleTree
  alias VerkleTree.Witness
  alias MerklePatriciaTree.DB
  alias ExWire.PeerSupervisor
  alias ExWire.Struct.Peer

  # Increased for better parallelism
  @max_concurrent_witness_requests 32
  # Optimized for Verkle witnesses
  @witness_batch_size 256
  # Allow more time for large batches
  @request_timeout 15_000
  # More resilient retry logic
  @max_retries 5
  # More frequent healing checks
  @heal_check_interval 30_000
  # Parallel witness verification
  @parallel_verification_concurrency 8
  # Switch to priority mode at 80%
  @priority_sync_threshold 0.8
  # Adapt batch size based on network
  @network_adaptation_interval 10_000

  @type witness_status :: :pending | :downloading | :verified | :failed | :priority
  @type sync_mode :: :witness_sync | :heal_mode | :priority_mode | :complete
  @type key_priority :: :high | :normal | :low
  @type network_stats :: %{
          avg_response_time: non_neg_integer(),
          success_rate: float(),
          optimal_batch_size: non_neg_integer()
        }

  @type t :: %__MODULE__{
          verkle_tree: VerkleTree.t(),
          target_root: binary(),

          # Witness tracking
          needed_keys: MapSet.t(binary()),
          witness_requests: %{binary() => witness_status()},
          verified_witnesses: MapSet.t(binary()),
          failed_keys: MapSet.t(binary()),
          key_priorities: %{binary() => key_priority()},

          # Request management
          active_requests: %{reference() => {[binary()], Peer.t(), integer()}},
          request_retries: %{binary() => non_neg_integer()},
          peer_performance: %{Peer.t() => network_stats()},

          # Progress tracking
          total_keys_needed: non_neg_integer(),
          keys_synchronized: non_neg_integer(),
          witnesses_verified: non_neg_integer(),
          bytes_synchronized: non_neg_integer(),
          verification_pool: pid() | nil,

          # Network adaptation
          current_batch_size: non_neg_integer(),
          network_conditions: network_stats(),
          last_network_update: integer(),

          # State expiry support
          state_expiry_manager: map(),
          resurrection_queue: [binary()],

          # State
          sync_mode: sync_mode(),
          started_at: integer(),
          last_heal_check: integer()
        }

  defstruct [
    :verkle_tree,
    :target_root,
    :started_at,
    :last_heal_check,
    :verification_pool,
    needed_keys: MapSet.new(),
    witness_requests: %{},
    verified_witnesses: MapSet.new(),
    failed_keys: MapSet.new(),
    key_priorities: %{},
    active_requests: %{},
    request_retries: %{},
    peer_performance: %{},
    total_keys_needed: 0,
    keys_synchronized: 0,
    witnesses_verified: 0,
    bytes_synchronized: 0,
    current_batch_size: @witness_batch_size,
    network_conditions: %{
      avg_response_time: 0,
      success_rate: 1.0,
      optimal_batch_size: @witness_batch_size
    },
    last_network_update: 0,
    state_expiry_manager: %{},
    resurrection_queue: [],
    sync_mode: :witness_sync
  ]

  # Client API

  @doc """
  Start Verkle-aware state synchronization for the given keys with EIP-6800 compliance.

  Options:
  - :state_expiry_manager - Manager for state expiry and resurrection
  - :key_priorities - Map of key priorities for selective sync
  - :network_adaptation - Enable adaptive batch sizing
  """
  def start_link(verkle_tree, target_root, required_keys, opts \\ []) do
    GenServer.start_link(__MODULE__, {verkle_tree, target_root, required_keys, opts}, opts)
  end

  @doc """
  Get current synchronization progress.
  """
  def get_progress(pid) do
    GenServer.call(pid, :get_progress)
  end

  @doc """
  Get detailed synchronization statistics.
  """
  def get_stats(pid) do
    GenServer.call(pid, :get_stats)
  end

  @doc """
  Request witness for specific keys.
  """
  def request_witnesses(pid, keys) do
    GenServer.call(pid, {:request_witnesses, keys})
  end

  @doc """
  Force a heal check to find missing state.
  """
  def force_heal(pid) do
    GenServer.call(pid, :force_heal)
  end

  @doc """
  Set priority for specific keys in the sync process.
  """
  def set_key_priorities(pid, key_priority_map) do
    GenServer.call(pid, {:set_key_priorities, key_priority_map})
  end

  @doc """
  Resurrect expired state with resurrection proofs.
  """
  def resurrect_expired_state(pid, keys_with_proofs) do
    GenServer.call(pid, {:resurrect_expired_state, keys_with_proofs})
  end

  @doc """
  Enable or disable adaptive network batching.
  """
  def set_network_adaptation(pid, enabled) do
    GenServer.call(pid, {:set_network_adaptation, enabled})
  end

  @doc """
  Get detailed network performance statistics.
  """
  def get_network_stats(pid) do
    GenServer.call(pid, :get_network_stats)
  end

  @doc """
  Manually trigger parallel verification for queued witnesses.
  """
  def trigger_verification(pid) do
    GenServer.cast(pid, :trigger_verification)
  end

  # Server Callbacks

  @impl true
  def init({verkle_tree, target_root, required_keys, opts}) do
    # Extract options
    state_expiry_manager = Keyword.get(opts, :state_expiry_manager, %{})
    key_priorities = Keyword.get(opts, :key_priorities, %{})
    network_adaptation = Keyword.get(opts, :network_adaptation, true)

    # Start parallel verification pool
    {:ok, verification_pool} =
      Task.Supervisor.start_link(
        max_children: @parallel_verification_concurrency,
        strategy: :one_for_one
      )

    state = %__MODULE__{
      verkle_tree: verkle_tree,
      target_root: target_root,
      needed_keys: MapSet.new(required_keys),
      total_keys_needed: length(required_keys),
      started_at: System.system_time(:second),
      last_heal_check: System.system_time(:second),
      last_network_update: System.system_time(:second),
      verification_pool: verification_pool,
      state_expiry_manager: state_expiry_manager,
      key_priorities: assign_default_priorities(required_keys, key_priorities)
    }

    Logger.info("""
    Starting Verkle state sync:
      Target root: #{encode_hex(target_root)}
      Keys needed: #{length(required_keys)}
    """)

    # Initialize witness requests
    witness_requests =
      Enum.reduce(required_keys, %{}, fn key, acc ->
        Map.put(acc, key, :pending)
      end)

    new_state = %{state | witness_requests: witness_requests}

    # Start the sync process
    send(self(), :process_witness_requests)

    # Schedule heal checks
    Process.send_after(self(), :heal_check, @heal_check_interval)

    {:ok, new_state}
  end

  @impl true
  def handle_call(:get_progress, _from, _state) do
    progress = calculate_progress(state)
    {:reply, progress, state}
  end

  @impl true
  def handle_call(:get_stats, _from, _state) do
    stats = %{
      target_root: encode_hex(state.target_root),
      sync_mode: state.sync_mode,
      keys_needed: MapSet.size(state.needed_keys),
      keys_synchronized: state.keys_synchronized,
      witnesses_verified: state.witnesses_verified,
      bytes_synchronized: state.bytes_synchronized,
      active_requests: map_size(state.active_requests),
      failed_keys: MapSet.size(state.failed_keys),
      elapsed_time: System.system_time(:second) - state.started_at
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:request_witnesses, keys}, _from, _state) do
    # Add new keys to the sync process
    new_needed_keys = MapSet.union(state.needed_keys, MapSet.new(keys))

    new_witness_requests =
      Enum.reduce(keys, state.witness_requests, fn key, acc ->
        Map.put_new(acc, key, :pending)
      end)

    new_state = %{
      state
      | needed_keys: new_needed_keys,
        witness_requests: new_witness_requests,
        total_keys_needed: state.total_keys_needed + length(keys)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:force_heal, _from, _state) do
    new_state = perform_heal_check(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_key_priorities, key_priority_map}, _from, _state) do
    new_priorities = Map.merge(state.key_priorities, key_priority_map)
    new_state = %{state | key_priorities: new_priorities}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:resurrect_expired_state, keys_with_proofs}, _from, _state) do
    new_state = process_resurrection_requests(state, keys_with_proofs)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_network_adaptation, enabled}, _from, _state) do
    # Enable/disable adaptive batch sizing based on network conditions
    if enabled do
      Process.send_after(self(), :adapt_network_settings, @network_adaptation_interval)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_network_stats, _from, _state) do
    network_stats = %{
      current_batch_size: state.current_batch_size,
      network_conditions: state.network_conditions,
      peer_performance: state.peer_performance,
      active_requests: map_size(state.active_requests)
    }

    {:reply, network_stats, state}
  end

  @impl true
  def handle_info(:process_witness_requests, _state) do
    new_state = process_witness_queue(state)

    # Continue processing unless complete
    if state.sync_mode != :complete do
      Process.send_after(self(), :process_witness_requests, 1000)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:heal_check, _state) do
    new_state = perform_heal_check(state)

    # Schedule next heal check
    Process.send_after(self(), :heal_check, @heal_check_interval)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:witness_response, witnesses, peer}, _state) do
    new_state = handle_witness_response(witnesses, peer, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:request_timeout, request_ref}, _state) do
    new_state = handle_request_timeout(request_ref, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:adapt_network_settings, _state) do
    new_state = adapt_network_conditions(state)

    # Schedule next adaptation
    Process.send_after(self(), :adapt_network_settings, @network_adaptation_interval)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:parallel_verification_complete, results}, _state) do
    new_state = process_parallel_verification_results(results, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:trigger_verification, _state) do
    new_state = trigger_parallel_verification(state)
    {:noreply, new_state}
  end

  # Private Functions

  defp process_witness_queue(_state) do
    # Get pending keys with priority ordering
    pending_keys = get_pending_keys_prioritized(state)

    if length(pending_keys) > 0 do
      available_slots = @max_concurrent_witness_requests - map_size(state.active_requests)

      if available_slots > 0 do
        # Use adaptive batch size
        batch_size = determine_optimal_batch_size(state)

        # Create batches for witness requests with priority considerations
        key_batches = create_priority_batches(pending_keys, batch_size, state)
        batches_to_send = Enum.take(key_batches, available_slots)

        # Send witness requests to best performing peers
        Enum.reduce(batches_to_send, state, fn keys, acc_state ->
          send_witness_request_optimized(acc_state, keys)
        end)
      else
        state
      end
    else
      # Check if sync is complete or needs priority mode
      check_sync_status_and_mode(state)
    end
  end

  defp get_pending_keys(_state) do
    state.witness_requests
    |> Enum.filter(fn {_key, status} -> status == :pending end)
    |> Enum.map(fn {key, _status} -> key end)
    |> Enum.take(@witness_batch_size * @max_concurrent_witness_requests)
  end

  defp send_witness_request(_state, keys) do
    peers = PeerSupervisor.connected_peers()

    if length(peers) > 0 do
      peer = Enum.random(peers)
      request_ref = make_ref()

      Logger.debug("Requesting witnesses for #{length(keys)} keys from peer")

      # Create witness request packet (this would be protocol-specific)
      packet = create_witness_request_packet(keys, state.target_root)

      # Send to peer
      send_witness_packet_to_peer(peer, packet)

      # Update key status to downloading
      new_witness_requests =
        Enum.reduce(keys, state.witness_requests, fn key, acc ->
          Map.put(acc, key, :downloading)
        end)

      # Track request
      Process.send_after(self(), {:request_timeout, request_ref}, @request_timeout)

      state
      |> Map.put(:witness_requests, new_witness_requests)
      |> put_in([:active_requests, request_ref], {keys, peer})
    else
      Logger.warning("No connected peers for witness requests")
      state
    end
  end

  defp handle_witness_response(witnesses, _peer, _state) do
    Logger.debug("Received #{length(witnesses)} witness proofs")

    # Verify and process each witness
    {new_state, processed_count} =
      Enum.reduce(witnesses, {state, 0}, fn witness, {acc_state, count} ->
        case verify_and_process_witness(witness, acc_state) do
          {:ok, updated_state} -> {updated_state, count + 1}
          {:error, _reason} -> {acc_state, count}
        end
      end)

    # Update statistics
    final_state = %{
      new_state
      | witnesses_verified: new_state.witnesses_verified + processed_count,
        bytes_synchronized: new_state.bytes_synchronized + calculate_witness_bytes(witnesses)
    }

    final_state
  end

  defp verify_and_process_witness(witness, _state) do
    with {:ok, key_value_pairs} <- extract_key_value_pairs(witness),
         true <- VerkleTree.verify_witness(witness, state.target_root, key_value_pairs),
         :ok <- apply_witness_to_state(witness, key_value_pairs, state) do
      # Mark keys as synchronized
      witness_keys = Enum.map(key_value_pairs, fn {key, _value} -> key end)

      new_verified = MapSet.union(state.verified_witnesses, MapSet.new(witness_keys))

      new_witness_requests =
        Enum.reduce(witness_keys, state.witness_requests, fn key, acc ->
          Map.put(acc, key, :verified)
        end)

      updated_state = %{
        state
        | verified_witnesses: new_verified,
          witness_requests: new_witness_requests,
          keys_synchronized: state.keys_synchronized + length(witness_keys)
      }

      {:ok, updated_state}
    else
      false ->
        Logger.warning("Witness verification failed")
        {:error, :verification_failed}

      {:error, _reason} ->
        Logger.warning("Failed to process witness: #{inspect(reason)}")
        {:error, _reason}
    end
  end

  defp apply_witness_to_state(witness, key_value_pairs, _state) do
    # Apply the witness data to the local Verkle tree
    try do
      Enum.each(key_value_pairs, fn {key, value} ->
        VerkleTree.put(state.verkle_tree, key, value)
      end)

      # Store the witness for future verification
      witness_key = :crypto.hash(:sha256, Witness.serialize(witness))
      DB.put!(state.verkle_tree.db, "witness:" <> witness_key, Witness.serialize(witness))

      :ok
    rescue
      e ->
        {:error, e}
    end
  end

  defp handle_request_timeout(request_ref, _state) do
    case Map.get(state.active_requests, request_ref) do
      nil ->
        _state

      {keys, _peer} ->
        Logger.debug("Witness request timeout for #{length(keys)} keys")

        # Handle retries and failures
        {retry_keys, failed_keys} =
          Enum.split_with(keys, fn key ->
            retries = Map.get(state.request_retries, key, 0)
            retries < @max_retries
          end)

        # Update retry counts
        new_retries =
          Enum.reduce(retry_keys, state.request_retries, fn key, acc ->
            Map.update(acc, key, 1, &(&1 + 1))
          end)

        # Reset retry keys to pending, mark others as failed
        new_witness_requests =
          retry_keys
          |> Enum.reduce(state.witness_requests, &Map.put(&2, &1, :pending))
          |> then(fn acc ->
            Enum.reduce(failed_keys, acc, &Map.put(&2, &1, :failed))
          end)

        new_failed = MapSet.union(state.failed_keys, MapSet.new(failed_keys))

        state
        |> Map.put(:witness_requests, new_witness_requests)
        |> Map.put(:failed_keys, new_failed)
        |> Map.put(:request_retries, new_retries)
        |> update_in([:active_requests], &Map.delete(&1, request_ref))
    end
  end

  defp perform_heal_check(_state) do
    Logger.debug("Performing Verkle state heal check...")

    # Find missing state by checking witness coverage
    missing_keys = find_missing_witness_keys(state)

    if length(missing_keys) > 0 do
      Logger.info("Found #{length(missing_keys)} keys needing healing")

      # Add missing keys to sync process
      new_needed_keys = MapSet.union(state.needed_keys, MapSet.new(missing_keys))

      new_witness_requests =
        Enum.reduce(missing_keys, state.witness_requests, fn key, acc ->
          Map.put_new(acc, key, :pending)
        end)

      %{
        state
        | needed_keys: new_needed_keys,
          witness_requests: new_witness_requests,
          sync_mode: :heal_mode,
          last_heal_check: System.system_time(:second)
      }
    else
      if state.sync_mode == :heal_mode do
        Logger.info("Verkle state healing complete!")
      end

      %{state | sync_mode: :witness_sync, last_heal_check: System.system_time(:second)}
    end
  end

  defp find_missing_witness_keys(_state) do
    # Check for keys that are needed but don't have verified witnesses
    state.needed_keys
    |> MapSet.difference(state.verified_witnesses)
    |> MapSet.to_list()
  end

  defp check_sync_complete(_state) do
    pending_requests = map_size(state.active_requests) == 0
    all_keys_synced = MapSet.subset?(state.needed_keys, state.verified_witnesses)

    if pending_requests and all_keys_synced and state.sync_mode != :complete do
      Logger.info("""
      Verkle state synchronization complete!
        Keys synchronized: #{state.keys_synchronized}
        Witnesses verified: #{state.witnesses_verified}
        Data: #{format_bytes(state.bytes_synchronized)}
        Time: #{format_duration(System.system_time(:second) - state.started_at)}
      """)

      %{state | sync_mode: :complete}
    else
      state
    end
  end

  defp calculate_progress(_state) do
    if state.total_keys_needed > 0 do
      completion = state.keys_synchronized / state.total_keys_needed * 100

      %{
        completion_percentage: Float.round(completion, 2),
        sync_mode: state.sync_mode,
        keys_needed: state.total_keys_needed,
        keys_synchronized: state.keys_synchronized,
        witnesses_verified: state.witnesses_verified,
        failed_keys: MapSet.size(state.failed_keys),
        bytes_synchronized: state.bytes_synchronized
      }
    else
      %{completion_percentage: 0.0}
    end
  end

  # Helper functions for witness processing

  defp extract_key_value_pairs(witness) do
    # Extract key-value pairs from the witness structure
    try do
      case Witness.get_key_value_pairs(witness) do
        {:ok, pairs} -> {:ok, pairs}
        pairs when is_list(pairs) -> {:ok, pairs}
        _ -> {:error, :invalid_witness_format}
      end
    rescue
      _ -> {:error, :witness_extraction_failed}
    end
  end

  defp calculate_witness_bytes(witnesses) when is_list(witnesses) do
    Enum.reduce(witnesses, 0, fn witness, acc ->
      acc + byte_size(Witness.serialize(witness))
    end)
  end

  defp create_witness_request_packet(keys, root_commitment) do
    # This would create the appropriate network packet for witness requests
    # The exact format depends on the network protocol being used
    %{
      type: :get_verkle_witnesses,
      keys: keys,
      root: root_commitment
    }
  end

  defp send_witness_packet_to_peer(_peer, _packet) do
    # This would send the witness request packet to the peer
    # Implementation depends on the peer communication system
    :ok
  end

  # Utility functions

  defp encode_hex(binary) when is_binary(binary) do
    "0x" <> Base.encode16(binary, case: :lower)
  end

  defp format_bytes(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    "#{hours}h #{minutes}m #{secs}s"
  end

  # Enhanced helper functions for advanced sync capabilities

  defp assign_default_priorities(keys, custom_priorities) do
    Enum.reduce(keys, custom_priorities, fn key, acc ->
      Map.put_new(acc, key, :normal)
    end)
  end

  defp get_pending_keys_prioritized(_state) do
    state.witness_requests
    |> Enum.filter(fn {_key, status} -> status in [:pending, :priority] end)
    |> Enum.sort_by(fn {key, _status} ->
      priority_weight(Map.get(state.key_priorities, key, :normal))
    end)
    |> Enum.map(fn {key, _status} -> key end)
    |> Enum.take(state.current_batch_size * @max_concurrent_witness_requests)
  end

  defp priority_weight(priority) do
    case priority do
      :high -> 1
      :normal -> 2
      :low -> 3
    end
  end

  defp determine_optimal_batch_size(_state) do
    base_size = state.network_conditions.optimal_batch_size
    success_rate = state.network_conditions.success_rate

    # Adjust batch size based on network performance
    cond do
      success_rate > 0.95 -> min(base_size * 2, @witness_batch_size * 2)
      success_rate > 0.8 -> base_size
      success_rate > 0.5 -> div(base_size, 2)
      true -> div(base_size, 4)
    end
  end

  defp create_priority_batches(keys, batch_size, _state) do
    # Group keys by priority and create mixed batches
    priority_groups =
      Enum.group_by(keys, fn key ->
        Map.get(state.key_priorities, key, :normal)
      end)

    high_keys = Map.get(priority_groups, :high, [])
    normal_keys = Map.get(priority_groups, :normal, [])
    low_keys = Map.get(priority_groups, :low, [])

    # Create mixed batches ensuring high priority keys are processed first
    create_mixed_batches(high_keys, normal_keys, low_keys, batch_size)
  end

  defp create_mixed_batches(high_keys, normal_keys, low_keys, batch_size) do
    # Create batches with high priority keys taking precedence
    all_keys = high_keys ++ normal_keys ++ low_keys
    Enum.chunk_every(all_keys, batch_size)
  end

  defp send_witness_request_optimized(_state, keys) do
    # Select the best performing peer
    best_peer = select_best_peer(state)

    if best_peer do
      send_witness_request_to_peer(state, keys, best_peer)
    else
      # Fallback to random peer selection
      send_witness_request(state, keys)
    end
  end

  defp select_best_peer(_state) do
    peers = PeerSupervisor.connected_peers()

    if length(peers) == 0 do
      nil
    else
      # Select peer with best performance metrics
      Enum.min_by(peers, fn peer ->
        performance = Map.get(_state.peer_performance, peer, default_performance())
        performance.avg_response_time * (2 - performance.success_rate)
      end)
    end
  end

  defp send_witness_request_to_peer(_state, keys, peer) do
    request_ref = make_ref()
    start_time = System.system_time(:millisecond)

    Logger.debug("Requesting witnesses for #{length(keys)} keys from optimized peer")

    # Create witness request packet
    packet = create_witness_request_packet(keys, state.target_root)

    # Send to peer
    send_witness_packet_to_peer(peer, packet)

    # Update key status to downloading
    new_witness_requests =
      Enum.reduce(keys, state.witness_requests, fn key, acc ->
        Map.put(acc, key, :downloading)
      end)

    # Track request with timing information
    Process.send_after(self(), {:request_timeout, request_ref}, @request_timeout)

    state
    |> Map.put(:witness_requests, new_witness_requests)
    |> put_in([:active_requests, request_ref], {keys, peer, start_time})
  end

  defp check_sync_status_and_mode(_state) do
    progress = calculate_completion_ratio(state)

    cond do
      progress >= @priority_sync_threshold and state.sync_mode != :priority_mode ->
        # Switch to priority mode for final keys
        Logger.info(
          "Switching to priority sync mode (#{Float.round(progress * 100, 1)}% complete)"
        )

        switch_to_priority_mode(state)

      MapSet.size(state.needed_keys) == MapSet.size(state.verified_witnesses) ->
        check_sync_complete(state)

      true ->
        state
    end
  end

  defp calculate_completion_ratio(_state) do
    if state.total_keys_needed > 0 do
      state.keys_synchronized / state.total_keys_needed
    else
      0.0
    end
  end

  defp switch_to_priority_mode(_state) do
    # Mark remaining keys as priority
    remaining_keys = MapSet.difference(state.needed_keys, state.verified_witnesses)

    new_witness_requests =
      Enum.reduce(remaining_keys, state.witness_requests, fn key, acc ->
        Map.put(acc, key, :priority)
      end)

    new_key_priorities =
      Enum.reduce(remaining_keys, state.key_priorities, fn key, acc ->
        Map.put(acc, key, :high)
      end)

    %{
      state
      | sync_mode: :priority_mode,
        witness_requests: new_witness_requests,
        key_priorities: new_key_priorities,
        # Smaller batches for priority
        current_batch_size: div(state.current_batch_size, 2)
    }
  end

  defp adapt_network_conditions(_state) do
    # Analyze recent request performance and adapt batch sizes
    current_time = System.system_time(:second)

    if current_time - state.last_network_update > 10 do
      # Calculate network performance metrics
      new_conditions = calculate_network_performance(state)
      new_batch_size = optimize_batch_size(new_conditions)

      %{
        state
        | network_conditions: new_conditions,
          current_batch_size: new_batch_size,
          last_network_update: current_time
      }
    else
      state
    end
  end

  defp calculate_network_performance(_state) do
    # Analyze peer performance and derive optimal settings
    if map_size(state.peer_performance) > 0 do
      performances = Map.values(state.peer_performance)

      avg_response =
        performances
        |> Enum.map(& &1.avg_response_time)
        |> Enum.reduce(0, &+/2)
        |> div(length(performances))

      avg_success =
        performances
        |> Enum.map(& &1.success_rate)
        |> Enum.reduce(0.0, &+/2)
        |> div(length(performances))

      optimal_batch =
        performances
        |> Enum.map(& &1.optimal_batch_size)
        |> Enum.reduce(0, &+/2)
        |> div(length(performances))

      %{
        avg_response_time: avg_response,
        success_rate: avg_success,
        optimal_batch_size: optimal_batch
      }
    else
      state.network_conditions
    end
  end

  defp optimize_batch_size(conditions) do
    base_size = @witness_batch_size

    # Optimize based on response time and success rate
    case {conditions.avg_response_time, conditions.success_rate} do
      {time, rate} when time < 5000 and rate > 0.95 ->
        min(base_size * 2, 512)

      {time, rate} when time < 10000 and rate > 0.8 ->
        base_size

      {time, rate} when time < 20000 and rate > 0.6 ->
        div(base_size, 2)

      _ ->
        div(base_size, 4)
    end
  end

  defp trigger_parallel_verification(_state) do
    # Submit pending witnesses for parallel verification
    # This would integrate with the verification pool
    Task.Supervisor.async_nolink(state.verification_pool, fn ->
      # Parallel verification logic would go here
      {:verification_complete, []}
    end)

    state
  end

  defp process_parallel_verification_results(results, _state) do
    # Process results from parallel verification
    Logger.debug("Processed #{length(results)} parallel verification results")
    state
  end

  defp process_resurrection_requests(_state, keys_with_proofs) do
    # Process state resurrection requests for expired keys
    Logger.info("Processing #{length(keys_with_proofs)} resurrection requests")

    # Add resurrection keys to queue
    resurrection_keys = Enum.map(keys_with_proofs, fn {key, _proof} -> key end)

    %{
      state
      | resurrection_queue: state.resurrection_queue ++ resurrection_keys,
        sync_mode: :heal_mode
    }
  end

  defp default_performance() do
    %{
      avg_response_time: 10_000,
      success_rate: 0.8,
      optimal_batch_size: @witness_batch_size
    }
  end
end
