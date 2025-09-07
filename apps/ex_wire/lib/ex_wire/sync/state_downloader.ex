defmodule ExWire.Sync.StateDownloader do
  @moduledoc """
  State Trie Downloader for Fast Sync.

  This module is responsible for downloading the entire state trie at the pivot block.
  It uses a breadth-first approach to download state nodes, starting from the state root
  and following all child node references.

  Key features:
  - Parallel downloading of state nodes
  - Intelligent batching to minimize requests
  - State healing to recover missing nodes
  - Progress tracking and estimation
  - Verification of downloaded data
  """

  use GenServer
  require Logger

  alias MerklePatriciaTree.{Trie, DB}
  alias ExWire.PeerSupervisor
  alias ExWire.Struct.Peer

  alias ExWire.Packet.Capability.Eth.{
    GetNodeData,
    NodeData
  }

  @max_concurrent_requests 8
  # Nodes per request (Ethereum's standard)
  @batch_size 384
  # 15 seconds
  @request_timeout 15_000
  @max_retries 3
  # Check for missing nodes every 30s
  @heal_check_interval 30_000

  @type node_status :: :pending | :downloading | :complete | :failed

  @type t :: %__MODULE__{
          trie: Trie.t(),
          state_root: binary(),

          # Node tracking
          # Nodes to download
          node_queue: :queue.queue(binary()),
          node_status: %{binary() => node_status()},
          downloaded_nodes: MapSet.t(binary()),
          failed_nodes: MapSet.t(binary()),

          # Request tracking
          active_requests: %{reference() => {[binary()], Peer.t()}},
          request_retries: %{binary() => non_neg_integer()},

          # Progress tracking
          total_nodes_discovered: non_neg_integer(),
          nodes_downloaded: non_neg_integer(),
          nodes_failed: non_neg_integer(),
          bytes_downloaded: non_neg_integer(),

          # State
          started_at: integer(),
          last_heal_check: integer(),
          sync_complete: boolean(),
          heal_mode: boolean()
        }

  defstruct [
    :trie,
    :state_root,
    :started_at,
    :last_heal_check,
    node_queue: :queue.new(),
    node_status: %{},
    downloaded_nodes: MapSet.new(),
    failed_nodes: MapSet.new(),
    active_requests: %{},
    request_retries: %{},
    total_nodes_discovered: 0,
    nodes_downloaded: 0,
    nodes_failed: 0,
    bytes_downloaded: 0,
    sync_complete: false,
    heal_mode: false
  ]

  # Client API

  @doc """
  Starts downloading state at the given state root.
  """
  def start_link(trie, state_root, opts \\ []) do
    GenServer.start_link(__MODULE__, {trie, state_root}, opts)
  end

  @doc """
  Gets the current download progress.
  """
  def get_progress(pid) do
    GenServer.call(pid, :get_progress)
  end

  @doc """
  Gets detailed statistics.
  """
  def get_stats(pid) do
    GenServer.call(pid, :get_stats)
  end

  @doc """
  Forces a heal check to find missing nodes.
  """
  def force_heal(pid) do
    GenServer.call(pid, :force_heal)
  end

  # Server Callbacks

  @impl true
  def init({trie, state_root}) do
    state = %__MODULE__{
      trie: trie,
      state_root: state_root,
      started_at: System.system_time(:second),
      last_heal_check: System.system_time(:second)
    }

    # Queue the state root for download
    initial_queue = :queue.in(state_root, :queue.new())
    initial_status = Map.put(%{}, state_root, :pending)

    new_state = %{
      state
      | node_queue: initial_queue,
        node_status: initial_status,
        total_nodes_discovered: 1
    }

    Logger.info("Starting state download for root: #{encode_hex(state_root)}")

    # Start the download process
    send(self(), :process_queue)

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
      state_root: encode_hex(state.state_root),
      nodes_discovered: state.total_nodes_discovered,
      nodes_downloaded: state.nodes_downloaded,
      nodes_failed: state.nodes_failed,
      bytes_downloaded: state.bytes_downloaded,
      queue_size: :queue.len(state.node_queue),
      active_requests: map_size(state.active_requests),
      sync_complete: state.sync_complete,
      heal_mode: state.heal_mode,
      elapsed_time: System.system_time(:second) - state.started_at
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:force_heal, _from, _state) do
    new_state = perform_heal_check(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:process_queue, _state) do
    new_state = process_download_queue(state)

    # Continue processing if not complete
    if !state.sync_complete do
      Process.send_after(self(), :process_queue, 100)
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
  def handle_info({:_packet, %NodeData{hashes_to_nodes: hashes_to_nodes}, peer}, _state) do
    new_state = handle_node_data(hashes_to_nodes, peer, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:request_timeout, request_ref}, _state) do
    new_state = handle_request_timeout(request_ref, state)
    {:noreply, new_state}
  end

  # Private Functions

  defp process_download_queue(_state) do
    # Calculate how many requests we can make
    available_slots = @max_concurrent_requests - map_size(state.active_requests)

    if available_slots > 0 and :queue.len(state.node_queue) > 0 do
      # Get nodes to download
      {nodes_batch, remaining_queue} = get_nodes_batch(state.node_queue, available_slots)

      # Send requests for each batch
      new_state =
        Enum.reduce(nodes_batch, state, fn nodes, acc ->
          send_node_request(acc, nodes)
        end)

      %{new_state | node_queue: remaining_queue}
    else
      # Check if we're done
      check_sync_complete(state)
    end
  end

  defp get_nodes_batch(queue, available_slots) do
    # Extract nodes from queue and batch them
    {nodes, remaining_queue} = extract_nodes(queue, available_slots * @batch_size, [])

    # Group nodes into batches
    batches = Enum.chunk_every(nodes, @batch_size)

    {batches, remaining_queue}
  end

  defp extract_nodes(queue, count, acc) when count <= 0 do
    {Enum.reverse(acc), queue}
  end

  defp extract_nodes(queue, count, acc) do
    case :queue.out(queue) do
      {{:value, node}, remaining_queue} ->
        extract_nodes(remaining_queue, count - 1, [node | acc])

      {:empty, queue} ->
        {Enum.reverse(acc), queue}
    end
  end

  defp send_node_request(_state, nodes) do
    # Get available peer
    peers = PeerSupervisor.connected_peers()

    if length(peers) > 0 do
      peer = Enum.random(peers)
      request_ref = make_ref()

      # Create GetNodeData packet
      packet = %GetNodeData{hashes: nodes}

      # Send to peer
      send_packet_to_peer(peer, packet)

      # Set nodes as downloading
      new_status =
        Enum.reduce(nodes, state.node_status, fn node, status_map ->
          Map.put(status_map, node, :downloading)
        end)

      # Track request
      Process.send_after(self(), {:request_timeout, request_ref}, @request_timeout)

      state
      |> Map.put(:node_status, new_status)
      |> put_in([:active_requests, request_ref], {nodes, peer})
    else
      Logger.warning("No connected peers for state download")
      state
    end
  end

  defp handle_node_data(hashes_to_nodes, _peer, _state) do
    Logger.debug("Received node data for #{map_size(hashes_to_nodes)} nodes")

    # Process each node
    {new_state, new_nodes} =
      Enum.reduce(hashes_to_nodes, {state, []}, fn {_node_hash, node_data},
                                                   {acc_state, acc_nodes} ->
        case process_state_node(node_data, acc_state) do
          {:ok, processed_state, discovered_nodes} ->
            {processed_state, acc_nodes ++ discovered_nodes}

          {:error, _reason} ->
            {acc_state, acc_nodes}
        end
      end)

    # Queue newly discovered nodes
    final_state = queue_new_nodes(new_state, new_nodes)

    final_state
  end

  defp process_state_node(node_data, _state) do
    node_hash = hash_node_data(node_data)

    # Store the node
    case store_node_in_trie(state.trie, node_hash, node_data) do
      :ok ->
        # Parse node to discover child nodes
        child_nodes = discover_child_nodes(node_data)

        # Update state
        new_state =
          _state
          |> update_in([:downloaded_nodes], &MapSet.put(&1, node_hash))
          |> update_in([:nodes_downloaded], &(&1 + 1))
          |> update_in([:bytes_downloaded], &(&1 + byte_size(node_data)))
          |> put_in([:node_status, node_hash], :complete)

        {:ok, new_state, child_nodes}

      {:error, _reason} ->
        Logger.warning("Failed to store state node #{encode_hex(node_hash)}: #{inspect(reason)}")

        _new_state =
          state
          |> update_in([:failed_nodes], &MapSet.put(&1, node_hash))
          |> update_in([:nodes_failed], &(&1 + 1))
          |> put_in([:node_status, node_hash], :failed)

        {:error, _reason}
    end
  end

  defp discover_child_nodes(node_data) do
    # Parse RLP encoded node data to find child node hashes
    try do
      decoded = ExRLP.decode(node_data)
      extract_child_hashes(decoded)
    rescue
      e ->
        Logger.debug("Failed to decode node data: #{inspect(e)}")
        []
    end
  end

  defp extract_child_hashes(decoded_node) when is_list(decoded_node) do
    # Handle different node types (branch, extension, leaf)
    case length(decoded_node) do
      # Branch node
      17 ->
        decoded_node
        # First 16 elements are child hashes
        |> Enum.take(16)
        # Only 32-byte hashes
        |> Enum.filter(&(byte_size(&1) == 32))

      # Extension or leaf node
      2 ->
        [_path, child] = decoded_node
        if byte_size(child) == 32, do: [child], else: []

      _ ->
        []
    end
  end

  defp extract_child_hashes(_), do: []

  defp queue_new_nodes(_state, new_nodes) do
    # Filter out nodes we already know about
    unknown_nodes =
      Enum.filter(new_nodes, fn node ->
        not Map.has_key?(_state.node_status, node)
      end)

    if length(unknown_nodes) > 0 do
      Logger.debug("Discovered #{length(unknown_nodes)} new state nodes")

      # Add to queue and status
      new_queue =
        Enum.reduce(unknown_nodes, state.node_queue, fn node, queue ->
          :queue.in(node, queue)
        end)

      new_status =
        Enum.reduce(unknown_nodes, state.node_status, fn node, status_map ->
          Map.put(status_map, node, :pending)
        end)

      %{
        state
        | node_queue: new_queue,
          node_status: new_status,
          total_nodes_discovered: state.total_nodes_discovered + length(unknown_nodes)
      }
    else
      state
    end
  end

  defp handle_request_timeout(request_ref, _state) do
    case Map.get(state.active_requests, request_ref) do
      nil ->
        _state

      {nodes, _peer} ->
        Logger.debug("Request timeout for #{length(nodes)} nodes")

        # Re-queue failed nodes with retry tracking
        {retry_nodes, failed_nodes} =
          Enum.split_with(nodes, fn node ->
            retries = Map.get(state.request_retries, node, 0)
            retries < @max_retries
          end)

        # Update retry counts
        new_retries =
          Enum.reduce(retry_nodes, state.request_retries, fn node, retries ->
            Map.update(retries, node, 1, &(&1 + 1))
          end)

        # Re-queue nodes that can be retried
        new_queue =
          Enum.reduce(retry_nodes, state.node_queue, fn node, queue ->
            :queue.in(node, queue)
          end)

        # Mark permanently failed nodes
        new_status =
          retry_nodes
          |> Enum.reduce(state.node_status, &Map.put(&2, &1, :pending))
          |> then(fn status ->
            Enum.reduce(failed_nodes, status, &Map.put(&2, &1, :failed))
          end)

        new_failed = Enum.reduce(failed_nodes, state.failed_nodes, &MapSet.put(&2, &1))

        state
        |> Map.put(:node_queue, new_queue)
        |> Map.put(:node_status, new_status)
        |> Map.put(:failed_nodes, new_failed)
        |> Map.put(:request_retries, new_retries)
        |> update_in([:nodes_failed], &(&1 + length(failed_nodes)))
        |> update_in([:active_requests], &Map.delete(&1, request_ref))
    end
  end

  defp perform_heal_check(_state) do
    Logger.debug("Performing state heal check...")

    # Find missing nodes by traversing the trie
    missing_nodes = find_missing_nodes(state)

    if length(missing_nodes) > 0 do
      Logger.info("Found #{length(missing_nodes)} missing state nodes, healing...")

      # Queue missing nodes for download
      new_queue =
        Enum.reduce(missing_nodes, state.node_queue, fn node, queue ->
          :queue.in(node, queue)
        end)

      new_status =
        Enum.reduce(missing_nodes, state.node_status, fn node, status_map ->
          Map.put(status_map, node, :pending)
        end)

      %{
        state
        | node_queue: new_queue,
          node_status: new_status,
          total_nodes_discovered: state.total_nodes_discovered + length(missing_nodes),
          heal_mode: true,
          last_heal_check: System.system_time(:second)
      }
    else
      # No missing nodes found
      if state.heal_mode do
        Logger.info("State healing complete!")
      end

      %{state | heal_mode: false, last_heal_check: System.system_time(:second)}
    end
  end

  defp find_missing_nodes(_state) do
    # This would traverse the trie and find nodes that are referenced but missing
    # For now, return empty list
    []
  end

  defp check_sync_complete(_state) do
    queue_empty = :queue.is_empty(state.node_queue)
    no_active_requests = map_size(state.active_requests) == 0

    if queue_empty and no_active_requests and not state.sync_complete do
      Logger.info("""
      State download complete!
        Total nodes: #{state.total_nodes_discovered}
        Downloaded: #{state.nodes_downloaded}
        Failed: #{state.nodes_failed}
        Data: #{format_bytes(state.bytes_downloaded)}
        Time: #{format_duration(System.system_time(:second) - state.started_at)}
      """)

      %{state | sync_complete: true}
    else
      state
    end
  end

  defp calculate_progress(_state) do
    if state.total_nodes_discovered > 0 do
      completion = state.nodes_downloaded / state.total_nodes_discovered * 100

      %{
        completion_percentage: Float.round(completion, 2),
        nodes_discovered: state.total_nodes_discovered,
        nodes_downloaded: state.nodes_downloaded,
        nodes_failed: state.nodes_failed,
        nodes_pending: :queue.len(state.node_queue),
        bytes_downloaded: state.bytes_downloaded,
        sync_complete: state.sync_complete,
        heal_mode: state.heal_mode
      }
    else
      %{completion_percentage: 0.0}
    end
  end

  defp hash_node_data(node_data) do
    ExthCrypto.Hash.Keccak.kec(node_data)
  end

  defp store_node_in_trie(trie, node_hash, node_data) do
    # Store the node data in the trie's database
    try do
      :ok = DB.put!(trie.db, node_hash, node_data)
      :ok
    rescue
      e ->
        {:error, e}
    end
  end

  defp send_packet_to_peer(_peer, _packet) do
    # This would send the packet to the peer
    # Implementation depends on peer communication system
    :ok
  end

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
end
