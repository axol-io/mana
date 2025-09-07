defmodule ExWire.Sync.ReceiptDownloader do
  @moduledoc """
  Receipt Downloader for Fast Sync.

  Downloads and validates transaction receipts for blocks in parallel.
  Receipts are essential for fast sync as they contain the logs bloom filter
  and cumulative gas used, which are needed to validate blocks without
  executing all transactions.

  Features:
  - Parallel receipt downloading with batching
  - Receipt validation against block headers
  - Retry logic for failed downloads
  - Progress tracking and reporting
  """

  use GenServer
  require Logger

  alias Blockchain.Transaction
  alias Block.Header
  alias ExWire.{PeerSupervisor, Packet}
  alias ExWire.Struct.Peer

  alias ExWire.Packet.Capability.Eth.{
    GetReceipts,
    Receipts
  }

  # Receipts per request
  @batch_size 32
  @max_concurrent_requests 8
  # 15 seconds
  @request_timeout 15_000
  @max_retries 3

  @type receipt_status :: :pending | :downloading | :complete | :failed

  @type t :: %__MODULE__{
          # Block range to download receipts for
          from_block: non_neg_integer(),
          to_block: non_neg_integer(),

          # Block headers (needed for validation)
          headers: %{non_neg_integer() => Header.t()},

          # Download tracking
          receipt_queue: :queue.queue(non_neg_integer()),
          receipt_status: %{non_neg_integer() => receipt_status()},
          downloaded_receipts: %{non_neg_integer() => [Transaction.Receipt.t()]},

          # Request tracking
          active_requests: %{reference() => {[non_neg_integer()], Peer.t()}},
          request_retries: %{non_neg_integer() => non_neg_integer()},

          # Progress tracking
          blocks_to_download: non_neg_integer(),
          blocks_downloaded: non_neg_integer(),
          blocks_failed: non_neg_integer(),

          # State
          started_at: integer(),
          sync_complete: boolean()
        }

  defstruct [
    :from_block,
    :to_block,
    :started_at,
    headers: %{},
    receipt_queue: :queue.new(),
    receipt_status: %{},
    downloaded_receipts: %{},
    active_requests: %{},
    request_retries: %{},
    blocks_to_download: 0,
    blocks_downloaded: 0,
    blocks_failed: 0,
    sync_complete: false
  ]

  # Client API

  @doc """
  Starts downloading receipts for the given block range.
  """
  def start_link(from_block, to_block, headers, opts \\ []) do
    GenServer.start_link(__MODULE__, {from_block, to_block, headers}, opts)
  end

  @doc """
  Gets the current download progress.
  """
  def get_progress(pid) do
    GenServer.call(pid, :get_progress)
  end

  @doc """
  Gets downloaded receipts for a specific block.
  """
  def get_receipts(pid, block_number) do
    GenServer.call(pid, {:get_receipts, block_number})
  end

  @doc """
  Gets all downloaded receipts.
  """
  def get_all_receipts(pid) do
    GenServer.call(pid, :get_all_receipts)
  end

  # Server Callbacks

  @impl true
  def init({from_block, to_block, headers}) do
    blocks_to_download = to_block - from_block + 1

    # Initialize queue with all block numbers
    initial_queue =
      from_block..to_block
      |> Enum.reduce(:queue.new(), fn block_num, queue ->
        :queue.in(block_num, queue)
      end)

    # Initialize status map
    initial_status =
      from_block..to_block
      |> Enum.reduce(%{}, fn block_num, status_map ->
        Map.put(status_map, block_num, :pending)
      end)

    state = %__MODULE__{
      from_block: from_block,
      to_block: to_block,
      headers: headers,
      receipt_queue: initial_queue,
      receipt_status: initial_status,
      blocks_to_download: blocks_to_download,
      started_at: System.system_time(:second)
    }

    Logger.info(
      "Starting receipt download for blocks #{from_block} to #{to_block} (#{blocks_to_download} blocks)"
    )

    # Start the download process
    send(self(), :process_queue)

    {:ok, _state}
  end

  @impl true
  def handle_call(:get_progress, _from, _state) do
    progress = %{
      total_blocks: state.blocks_to_download,
      blocks_downloaded: state.blocks_downloaded,
      blocks_failed: state.blocks_failed,
      blocks_pending: :queue.len(state.receipt_queue),
      active_requests: map_size(state.active_requests),
      completion_percentage:
        if(state.blocks_to_download > 0,
          do: state.blocks_downloaded / state.blocks_to_download * 100,
          else: 0
        ),
      sync_complete: state.sync_complete,
      elapsed_time: System.system_time(:second) - state.started_at
    }

    {:reply, progress, state}
  end

  @impl true
  def handle_call({:get_receipts, block_number}, _from, _state) do
    receipts = Map.get(state.downloaded_receipts, block_number)
    {:reply, receipts, state}
  end

  @impl true
  def handle_call(:get_all_receipts, _from, _state) do
    {:reply, state.downloaded_receipts, state}
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
  def handle_info({:_packet, %Receipts{receipts: receipts_data}, peer}, _state) do
    new_state = handle_receipts(receipts_data, peer, state)
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

    if available_slots > 0 and :queue.len(state.receipt_queue) > 0 do
      # Get blocks to download
      {block_batches, remaining_queue} = get_block_batches(state.receipt_queue, available_slots)

      # Send requests for each batch
      new_state =
        Enum.reduce(block_batches, state, fn blocks, acc ->
          send_receipt_request(acc, blocks)
        end)

      %{new_state | receipt_queue: remaining_queue}
    else
      # Check if we're done
      check_sync_complete(state)
    end
  end

  defp get_block_batches(queue, available_slots) do
    # Extract blocks from queue and batch them
    {blocks, remaining_queue} = extract_blocks(queue, available_slots * @batch_size, [])

    # Group blocks into batches
    batches = Enum.chunk_every(blocks, @batch_size)

    {batches, remaining_queue}
  end

  defp extract_blocks(queue, count, acc) when count <= 0 do
    {Enum.reverse(acc), queue}
  end

  defp extract_blocks(queue, count, acc) do
    case :queue.out(queue) do
      {{:value, block}, remaining_queue} ->
        extract_blocks(remaining_queue, count - 1, [block | acc])

      {:empty, queue} ->
        {Enum.reverse(acc), queue}
    end
  end

  defp send_receipt_request(_state, blocks) do
    # Get available peer
    peers = PeerSupervisor.connected_peers()

    if length(peers) > 0 do
      peer = Enum.random(peers)
      request_ref = make_ref()

      # Get block hashes for the receipt request
      # Note: We need to compute block hashes from headers since headers don't include block_hash
      block_hashes =
        Enum.map(blocks, fn block_num ->
          case Map.get(state.headers, block_num) do
            nil ->
              nil

            header ->
              # Calculate block hash from header
              header |> Header.hash()
          end
        end)
        |> Enum.filter(&(&1 != nil))

      if length(block_hashes) > 0 do
        # Create GetReceipts packet
        _packet = %GetReceipts{hashes: block_hashes}

        # Send to peer
        send_packet_to_peer(peer, packet)

        # Set blocks as downloading
        new_status =
          Enum.reduce(blocks, state.receipt_status, fn block_num, status_map ->
            Map.put(status_map, block_num, :downloading)
          end)

        # Track request
        Process.send_after(self(), {:request_timeout, request_ref}, @request_timeout)

        state
        |> Map.put(:receipt_status, new_status)
        |> put_in([:active_requests, request_ref], {blocks, peer})
      else
        Logger.warning("No valid block hashes for receipt request")
        state
      end
    else
      Logger.warning("No connected peers for receipt download")
      state
    end
  end

  defp handle_receipts(receipts_data, _peer, _state) do
    Logger.debug("Received receipts for #{length(receipts_data)} blocks")

    # Process each set of receipts
    Enum.reduce(receipts_data, state, fn receipts, acc_state ->
      # Find which block these receipts belong to by validating against headers
      case find_matching_block(receipts, acc_state) do
        {:ok, block_number} ->
          process_block_receipts(block_number, receipts, acc_state)

        {:error, _reason} ->
          Logger.warning("Could not match receipts to block: #{inspect(reason)}")
          acc_state
      end
    end)
  end

  defp find_matching_block(receipts, _state) do
    # Calculate receipts root for these receipts
    receipts_root = calculate_receipts_root(receipts)

    # Find header with matching receipts root
    matching_header =
      Enum.find(state.headers, fn {_num, header} ->
        header.receipts_root == receipts_root
      end)

    case matching_header do
      {block_number, _header} -> {:ok, block_number}
      nil -> {:error, :no_matching_header}
    end
  end

  defp calculate_receipts_root(receipts) do
    # Calculate the Merkle root of the receipts
    # This is a simplified implementation
    receipts
    |> Enum.map(&encode_receipt/1)
    |> ExthCrypto.Hash.Keccak.kec()
  end

  defp encode_receipt(receipt) do
    # Encode receipt for Merkle tree calculation
    # This would need proper RLP encoding
    :erlang.term_to_binary(receipt)
  end

  defp process_block_receipts(block_number, receipts, _state) do
    # Validate receipts against block header
    case validate_receipts(block_number, receipts, state) do
      :ok ->
        Logger.debug("Successfully validated receipts for block #{block_number}")

        state
        |> put_in([:downloaded_receipts, block_number], receipts)
        |> put_in([:receipt_status, block_number], :complete)
        |> update_in([:blocks_downloaded], &(&1 + 1))

      {:error, _reason} ->
        Logger.warning("Receipt validation failed for block #{block_number}: #{inspect(reason)}")

        # Re-queue the block for retry
        new_queue = :queue.in(block_number, state.receipt_queue)

        state
        |> Map.put(:receipt_queue, new_queue)
        |> put_in([:receipt_status, block_number], :pending)
    end
  end

  defp validate_receipts(block_number, receipts, _state) do
    case Map.get(state.headers, block_number) do
      nil ->
        {:error, :no_header}

      header ->
        # Validate receipts root
        calculated_root = calculate_receipts_root(receipts)

        if calculated_root == header.receipts_root do
          # Validate cumulative gas used
          validate_cumulative_gas(receipts, header)
        else
          {:error, :receipts_root_mismatch}
        end
    end
  end

  defp validate_cumulative_gas(receipts, header) do
    # Check that the last receipt's cumulative gas matches the header
    case List.last(receipts) do
      nil ->
        if header.gas_used == 0, do: :ok, else: {:error, :gas_used_mismatch}

      last_receipt ->
        if last_receipt.cumulative_gas == header.gas_used do
          :ok
        else
          {:error, :gas_used_mismatch}
        end
    end
  end

  defp handle_request_timeout(request_ref, _state) do
    case Map.get(state.active_requests, request_ref) do
      nil ->
        _state

      {blocks, _peer} ->
        Logger.debug("Request timeout for receipts of blocks: #{inspect(blocks)}")

        # Separate blocks that can be retried from those that should fail
        {retry_blocks, failed_blocks} =
          Enum.split_with(blocks, fn block_num ->
            retries = Map.get(state.request_retries, block_num, 0)
            retries < @max_retries
          end)

        # Update retry counts
        new_retries =
          Enum.reduce(retry_blocks, state.request_retries, fn block_num, retries ->
            Map.update(retries, block_num, 1, &(&1 + 1))
          end)

        # Re-queue blocks that can be retried
        new_queue =
          Enum.reduce(retry_blocks, state.receipt_queue, fn block_num, queue ->
            :queue.in(block_num, queue)
          end)

        # Mark blocks for retry or failure
        new_status =
          retry_blocks
          |> Enum.reduce(state.receipt_status, &Map.put(&2, &1, :pending))
          |> then(fn status ->
            Enum.reduce(failed_blocks, status, &Map.put(&2, &1, :failed))
          end)

        state
        |> Map.put(:receipt_queue, new_queue)
        |> Map.put(:receipt_status, new_status)
        |> Map.put(:request_retries, new_retries)
        |> update_in([:blocks_failed], &(&1 + length(failed_blocks)))
        |> update_in([:active_requests], &Map.delete(&1, request_ref))
    end
  end

  defp check_sync_complete(_state) do
    queue_empty = :queue.is_empty(state.receipt_queue)
    no_active_requests = map_size(state.active_requests) == 0

    if queue_empty and no_active_requests and not state.sync_complete do
      elapsed_time = System.system_time(:second) - state.started_at

      Logger.info("""
      Receipt download complete!
        Total blocks: #{state.blocks_to_download}
        Downloaded: #{state.blocks_downloaded}
        Failed: #{state.blocks_failed}
        Success rate: #{Float.round(state.blocks_downloaded / state.blocks_to_download * 100, 1)}%
        Time: #{format_duration(elapsed_time)}
      """)

      %{state | sync_complete: true}
    else
      state
    end
  end

  defp send_packet_to_peer(_peer, _packet) do
    # This would send the packet to the peer
    # Implementation depends on peer communication system
    :ok
  end

  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    "#{hours}h #{minutes}m #{secs}s"
  end
end
