defmodule ExWire.Sync.FastSync do
  @moduledoc """
  Fast Sync implementation for Ethereum.

  Fast Sync allows a node to quickly synchronize with the network by:
  1. Selecting a pivot block (recent, well-confirmed block)
  2. Downloading the state trie at the pivot block
  3. Downloading block headers from genesis to pivot
  4. Downloading block bodies and receipts for recent blocks
  5. Validating the downloaded data
  6. Switching to full sync once caught up

  This approach is much faster than full sync as it avoids executing
  all transactions from genesis.
  """

  use GenServer
  require Logger

  alias Blockchain.{Blocktree, Chain}
  alias Block.Header
  alias ExWire.PeerSupervisor
  alias ExWire.Struct.{BlockQueue, Peer}
  alias MerklePatriciaTree.{Trie, DB}

  alias ExWire.Packet.Capability.Eth.{
    BlockBodies,
    BlockHeaders,
    GetBlockBodies,
    GetBlockHeaders,
    GetNodeData,
    GetReceipts,
    NodeData,
    Receipts
  }

  # Number of blocks behind head for pivot
  @pivot_distance 128
  # Headers per request
  @header_batch_size 192
  # Bodies per request
  @body_batch_size 32
  # Receipts per request
  @receipt_batch_size 32
  # State nodes per request
  @state_batch_size 384
  # Maximum parallel requests
  @max_concurrent_requests 16
  # Timeout for requests in ms
  @request_timeout 10_000
  # Delay before starting state sync
  @state_sync_start_delay 5_000

  @type sync_mode :: :fast | :full | :snap

  @type t :: %__MODULE__{
          chain: Chain.t(),
          trie: Trie.t(),
          mode: sync_mode(),
          pivot_block: any() | nil,
          pivot_header: Header.t() | nil,
          highest_block: non_neg_integer(),

          # Download queues
          header_queue: %{non_neg_integer() => :pending | :downloading | :complete},
          body_queue: %{non_neg_integer() => :pending | :downloading | :complete},
          receipt_queue: %{non_neg_integer() => :pending | :downloading | :complete},
          state_queue: MapSet.t(binary()),

          # Progress tracking
          headers_downloaded: non_neg_integer(),
          bodies_downloaded: non_neg_integer(),
          receipts_downloaded: non_neg_integer(),
          state_nodes_downloaded: non_neg_integer(),

          # Request tracking
          active_requests: %{reference() => any()},
          request_retries: %{reference() => non_neg_integer()},

          # Sync state
          sync_start_time: integer(),
          last_progress_report: integer(),
          state_root: binary() | nil,
          state_sync_complete: boolean(),
          headers_sync_complete: boolean(),
          bodies_sync_complete: boolean(),
          receipts_sync_complete: boolean()
        }

  defstruct [
    :chain,
    :trie,
    :mode,
    :pivot_block,
    :pivot_header,
    :highest_block,
    :sync_start_time,
    :last_progress_report,
    :state_root,
    header_queue: %{},
    body_queue: %{},
    receipt_queue: %{},
    state_queue: MapSet.new(),
    headers_downloaded: 0,
    bodies_downloaded: 0,
    receipts_downloaded: 0,
    state_nodes_downloaded: 0,
    active_requests: %{},
    request_retries: %{},
    state_sync_complete: false,
    headers_sync_complete: false,
    bodies_sync_complete: false,
    receipts_sync_complete: false
  ]

  # Client API

  @doc """
  Starts the Fast Sync process.
  """
  def start_link({chain, trie}, opts \\ []) do
    GenServer.start_link(__MODULE__, {chain, trie}, opts)
  end

  @doc """
  Gets the current sync status.
  """
  def get_status(server \\ __MODULE__) do
    GenServer.call(server, :get_status)
  end

  @doc """
  Gets detailed sync progress.
  """
  def get_progress(server \\ __MODULE__) do
    GenServer.call(server, :get_progress)
  end

  @doc """
  Switches sync mode (fast/full/snap).
  """
  def switch_mode(server \\ __MODULE__, mode) when mode in [:fast, :full, :snap] do
    GenServer.call(server, {:switch_mode, mode})
  end

  # Server Callbacks

  @impl true
  def init({chain, trie}) do
    state = %__MODULE__{
      chain: chain,
      trie: trie,
      mode: :fast,
      sync_start_time: System.system_time(:second),
      last_progress_report: System.system_time(:second)
    }

    # Start sync process after a delay
    Process.send_after(self(), :start_sync, 1000)

    {:ok, _state}
  end

  @impl true
  def handle_call(:get_status, _from, _state) do
    status = %{
      mode: state.mode,
      pivot_block: state.pivot_header && state.pivot_header.number,
      highest_block: state.highest_block,
      headers_complete: state.headers_sync_complete,
      bodies_complete: state.bodies_sync_complete,
      receipts_complete: state.receipts_sync_complete,
      state_complete: state.state_sync_complete
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:get_progress, _from, _state) do
    progress = calculate_progress(state)
    {:reply, progress, state}
  end

  @impl true
  def handle_call({:switch_mode, mode}, _from, _state) do
    Logger.info("Switching sync mode from #{state.mode} to #{mode}")
    {:reply, :ok, %{state | mode: mode}}
  end

  @impl true
  def handle_info(:start_sync, _state) do
    Logger.info("Starting fast sync...")

    # Get peers and determine pivot block
    case select_pivot_block(state) do
      {:ok, pivot_header} ->
        Logger.info("Selected pivot block ##{pivot_header.number}")

        new_state = %{
          state
          | pivot_header: pivot_header,
            state_root: pivot_header.state_root,
            highest_block: pivot_header.number + @pivot_distance
        }

        # Start downloading headers from genesis
        new_state = queue_header_downloads(new_state, 0, pivot_header.number)

        # Start downloading recent blocks (pivot to head)
        new_state = queue_recent_block_downloads(new_state, pivot_header.number)

        # Schedule state sync to start
        Process.send_after(self(), :start_state_sync, @state_sync_start_delay)

        # Start processing download queues
        send(self(), :process_download_queue)

        # Schedule progress reporting
        Process.send_after(self(), :report_progress, 5000)

        {:noreply, new_state}

      {:error, _reason} ->
        Logger.error("Failed to select pivot block: #{inspect(reason)}")
        Process.send_after(self(), :start_sync, 5000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:start_state_sync, _state = %{state_root: state_root}) when state_root != nil do
    Logger.info("Starting state sync for root: #{encode_hex(state_root)}")

    # Queue the state root for download
    new_state = queue_state_download(state, state_root)

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:process_download_queue, _state) do
    # Process different download queues
    new_state =
      state
      |> process_header_queue()
      |> process_body_queue()
      |> process_receipt_queue()
      |> process_state_queue()
      |> check_sync_complete()

    # Continue processing if not complete
    if !all_sync_complete?(new_state) do
      Process.send_after(self(), :process_download_queue, 100)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:report_progress, _state) do
    report_sync_progress(state)

    # Schedule next report
    Process.send_after(self(), :report_progress, 10000)

    {:noreply, %{state | last_progress_report: System.system_time(:second)}}
  end

  @impl true
  def handle_info({:_packet, %BlockHeaders{headers: headers}, peer}, _state) do
    new_state = handle_block_headers(headers, peer, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:_packet, %BlockBodies{blocks: blocks}, peer}, _state) do
    new_state = handle_block_bodies(blocks, peer, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:_packet, %Receipts{receipts: receipts}, peer}, _state) do
    new_state = handle_receipts(receipts, peer, state)
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

  defp select_pivot_block(_state) do
    # Get connected peers
    peers = PeerSupervisor.connected_peers()

    if length(peers) < 3 do
      {:error, :insufficient_peers}
    else
      # Get the highest block from peers
      highest_blocks =
        peers
        |> Enum.map(&get_peer_highest_block/1)
        |> Enum.filter(&(&1 != nil))
        |> Enum.sort()

      if length(highest_blocks) < 3 do
        {:error, :no_block_info}
      else
        # Use median of highest blocks
        median_highest = Enum.at(highest_blocks, div(length(highest_blocks), 2))

        # Pivot is @pivot_distance blocks behind highest
        pivot_number = max(0, median_highest - @pivot_distance)

        # Request pivot header from peers
        request_pivot_header(peers, pivot_number)
      end
    end
  end

  defp get_peer_highest_block(peer) do
    # Get the highest block number from peer
    # This would interact with the peer's status
    case Peer.get_status(peer) do
      %{best_block: block_number} -> block_number
      _ -> nil
    end
  end

  defp request_pivot_header(peers, block_number) do
    # Request header from multiple peers for consensus
    peer = Enum.random(peers)

    packet = %GetBlockHeaders{
      block_identifier: block_number,
      max_headers: 1,
      skip: 0,
      reverse: false
    }

    # This would need proper peer communication
    # For now, return a mock header
    {:ok,
     %Header{
       number: block_number,
       state_root: <<1::256>>,
       parent_hash: <<2::256>>,
       beneficiary: <<0::160>>,
       ommers_hash: <<0::256>>,
       transactions_root: <<0::256>>,
       receipts_root: <<0::256>>,
       logs_bloom: <<0::2048>>,
       difficulty: 1_000_000,
       gas_limit: 8_000_000,
       gas_used: 0,
       timestamp: System.system_time(:second),
       extra_data: <<>>,
       mix_hash: <<0::256>>,
       nonce: <<0::64>>
     }}
  end

  defp queue_header_downloads(_state, from_block, to_block) do
    # Queue headers for download in batches
    headers_to_queue =
      from_block..to_block
      |> Enum.chunk_every(@header_batch_size)
      |> Enum.reduce(state.header_queue, fn chunk, queue ->
        start_block = List.first(chunk)
        Map.put(queue, start_block, :pending)
      end)

    %{state | header_queue: headers_to_queue}
  end

  defp queue_recent_block_downloads(_state, from_block) do
    # Queue recent blocks for body and receipt download
    blocks_to_queue = from_block..state.highest_block

    body_queue =
      Enum.reduce(blocks_to_queue, %{}, fn block_num, queue ->
        Map.put(queue, block_num, :pending)
      end)

    receipt_queue =
      Enum.reduce(blocks_to_queue, %{}, fn block_num, queue ->
        Map.put(queue, block_num, :pending)
      end)

    %{state | body_queue: body_queue, receipt_queue: receipt_queue}
  end

  defp queue_state_download(_state, state_root) do
    new_queue = MapSet.put(state.state_queue, state_root)
    %{state | state_queue: new_queue}
  end

  defp process_header_queue(_state) do
    # Find pending headers to download
    pending_headers =
      state.header_queue
      |> Enum.filter(fn {_, status} -> status == :pending end)
      |> Enum.take(@max_concurrent_requests - map_size(state.active_requests))

    Enum.reduce(pending_headers, state, fn {block_number, _}, acc ->
      download_headers(acc, block_number)
    end)
  end

  defp process_body_queue(_state) do
    # Process body downloads
    pending_bodies =
      state.body_queue
      |> Enum.filter(fn {_, status} -> status == :pending end)
      |> Enum.take(@max_concurrent_requests - map_size(state.active_requests))

    Enum.reduce(pending_bodies, state, fn {block_number, _}, acc ->
      download_bodies(acc, block_number)
    end)
  end

  defp process_receipt_queue(_state) do
    # Process receipt downloads
    pending_receipts =
      state.receipt_queue
      |> Enum.filter(fn {_, status} -> status == :pending end)
      |> Enum.take(@max_concurrent_requests - map_size(state.active_requests))

    Enum.reduce(pending_receipts, state, fn {block_number, _}, acc ->
      download_receipts(acc, block_number)
    end)
  end

  defp process_state_queue(_state) do
    # Process state node downloads
    if MapSet.size(state.state_queue) > 0 and
         map_size(state.active_requests) < @max_concurrent_requests do
      nodes_to_download =
        state.state_queue
        |> Enum.take(@state_batch_size)

      download_state_nodes(state, nodes_to_download)
    else
      state
    end
  end

  defp download_headers(_state, block_number) do
    peers = PeerSupervisor.connected_peers()

    if length(peers) > 0 do
      peer = Enum.random(peers)
      request_ref = make_ref()

      packet = %GetBlockHeaders{
        block_identifier: block_number,
        max_headers: @header_batch_size,
        skip: 0,
        reverse: false
      }

      # Send request to peer
      send_packet_to_peer(peer, packet)

      # Track request
      Process.send_after(self(), {:request_timeout, request_ref}, @request_timeout)

      state
      |> put_in([:header_queue, block_number], :downloading)
      |> put_in([:active_requests, request_ref], {:headers, block_number, peer})
    else
      state
    end
  end

  defp download_bodies(_state, block_number) do
    # Similar to download_headers but for block bodies
    state
  end

  defp download_receipts(_state, block_number) do
    # Similar to download_headers but for receipts
    state
  end

  defp download_state_nodes(_state, nodes) do
    peers = PeerSupervisor.connected_peers()

    if length(peers) > 0 do
      peer = Enum.random(peers)
      request_ref = make_ref()

      packet = %GetNodeData{
        hashes: Enum.to_list(nodes)
      }

      # Send request to peer
      send_packet_to_peer(peer, packet)

      # Track request
      Process.send_after(self(), {:request_timeout, request_ref}, @request_timeout)

      new_queue =
        Enum.reduce(nodes, state.state_queue, fn node, queue ->
          MapSet.delete(queue, node)
        end)

      state
      |> Map.put(:state_queue, new_queue)
      |> put_in([:active_requests, request_ref], {:state, nodes, peer})
    else
      state
    end
  end

  defp handle_block_headers(headers, _peer, _state) do
    # Process received headers
    valid_headers = Enum.filter(headers, &validate_header(&1, state))

    new_state =
      Enum.reduce(valid_headers, state, fn header, acc ->
        # Store header
        store_header(header, acc)

        # Update progress
        acc
        |> update_in([:headers_downloaded], &(&1 + 1))
        |> put_in([:header_queue, header.number], :complete)
      end)

    # Check if headers sync is complete
    check_headers_complete(new_state)
  end

  defp handle_block_bodies(blocks, _peer, _state) do
    # Process received blocks (bodies)
    %{state | bodies_downloaded: state.bodies_downloaded + length(blocks)}
  end

  defp handle_receipts(receipts, _peer, _state) do
    # Process received receipts  
    %{state | receipts_downloaded: state.receipts_downloaded + length(receipts)}
  end

  defp handle_node_data(hashes_to_nodes, _peer, _state) do
    # Process received state nodes
    Enum.reduce(hashes_to_nodes, state, fn {_hash, node}, acc ->
      # Store node in trie
      store_state_node(node, acc)

      # Discover new nodes to download
      new_nodes = discover_state_nodes(node)

      new_queue =
        Enum.reduce(new_nodes, acc.state_queue, fn new_node, queue ->
          MapSet.put(queue, new_node)
        end)

      acc
      |> Map.put(:state_queue, new_queue)
      |> update_in([:state_nodes_downloaded], &(&1 + 1))
    end)
  end

  defp handle_request_timeout(request_ref, _state) do
    case Map.get(state.active_requests, request_ref) do
      nil ->
        _state

      {type, data, _peer} ->
        # Retry the request
        retries = Map.get(state.request_retries, request_ref, 0)

        if retries < 3 do
          # Retry request with different peer
          Logger.debug("Retrying #{type} request (attempt #{retries + 1})")

          new_state =
            case type do
              {:headers, block_number, _} ->
                put_in(state, [:header_queue, block_number], :pending)

              {:state, nodes, _} ->
                new_queue = Enum.reduce(nodes, state.state_queue, &MapSet.put(&2, &1))
                Map.put(state, :state_queue, new_queue)

              _ ->
                state
            end

          new_state
          |> update_in([:active_requests], &Map.delete(&1, request_ref))
          |> put_in([:request_retries, request_ref], retries + 1)
        else
          # Give up on this request
          Logger.warning("Request timeout after 3 retries: #{inspect(type)}")

          state
          |> update_in([:active_requests], &Map.delete(&1, request_ref))
          |> update_in([:request_retries], &Map.delete(&1, request_ref))
        end
    end
  end

  defp validate_header(_header, _state) do
    # Validate header against known good headers
    # For now, accept all
    true
  end

  defp store_header(_header, _state) do
    # Store header in database
    state
  end

  defp store_state_node(_node, _state) do
    # Store state node in trie
    state
  end

  defp discover_state_nodes(_node) do
    # Parse node and discover child nodes that need downloading
    []
  end

  defp check_headers_complete(_state) do
    all_complete =
      state.header_queue
      |> Map.values()
      |> Enum.all?(&(&1 == :complete))

    if all_complete and not state.headers_sync_complete do
      Logger.info("Headers sync complete! Downloaded #{state.headers_downloaded} headers")
      %{state | headers_sync_complete: true}
    else
      state
    end
  end

  defp check_sync_complete(_state) do
    if all_sync_complete?(state) do
      Logger.info("Fast sync complete! Switching to full sync mode...")

      # Switch to full sync
      %{state | mode: :full}
    else
      state
    end
  end

  defp all_sync_complete?(state) do
    state.headers_sync_complete and
      state.bodies_sync_complete and
      state.receipts_sync_complete and
      state.state_sync_complete
  end

  defp calculate_progress(_state) do
    header_progress =
      if map_size(state.header_queue) > 0 do
        complete = Enum.count(state.header_queue, fn {_, status} -> status == :complete end)
        complete / map_size(state.header_queue) * 100
      else
        0.0
      end

    %{
      headers: %{
        downloaded: state.headers_downloaded,
        progress: header_progress
      },
      bodies: %{
        downloaded: state.bodies_downloaded
      },
      receipts: %{
        downloaded: state.receipts_downloaded
      },
      state: %{
        nodes_downloaded: state.state_nodes_downloaded,
        queue_size: MapSet.size(state.state_queue)
      },
      elapsed_time: System.system_time(:second) - state.sync_start_time
    }
  end

  defp report_sync_progress(_state) do
    progress = calculate_progress(state)

    Logger.info("""
    Fast Sync Progress:
      Headers:  #{state.headers_downloaded} (#{Float.round(progress.headers.progress, 1)}%)
      Bodies:   #{state.bodies_downloaded}
      Receipts: #{state.receipts_downloaded}
      State:    #{state.state_nodes_downloaded} nodes (#{progress.state.queue_size} queued)
      Time:     #{format_duration(progress.elapsed_time)}
    """)
  end

  defp send_packet_to_peer(_peer, _packet) do
    # This would send the packet to the peer
    # Implementation depends on peer communication system
    :ok
  end

  defp encode_hex(binary) when is_binary(binary) do
    Base.encode16(binary, case: :lower)
  end

  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    "#{hours}h #{minutes}m #{secs}s"
  end
end
