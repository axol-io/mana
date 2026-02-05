defmodule History.Sync.Pipeline do
  @moduledoc """
  Stateless sync pipeline for historical data.

  Syncs headers, transactions, and receipts from the P2P network
  without EVM execution. Uses the existing ExWire P2P infrastructure.

  ## Sync Strategy

  1. Connect to peers via Kademlia discovery
  2. Request block headers in batches
  3. Request block bodies (transactions) for each header
  4. Request receipts for each block
  5. Extract logs from receipts and store with bloom index
  6. Store headers for block queries
  """
  use GenServer

  require Logger

  alias ExWire.PeerSupervisor
  alias ExWire.Struct.Peer
  alias History.{Index, Storage, Telemetry}

  @batch_size 100
  @checkpoint_interval 1_000

  defstruct [
    :chain,
    :config,
    :synced_block,
    :highest_block,
    :pending_headers,
    :pending_bodies,
    :pending_receipts,
    :peers,
    :syncing
  ]

  @type t :: %__MODULE__{
          chain: atom(),
          config: keyword(),
          synced_block: non_neg_integer(),
          highest_block: non_neg_integer(),
          pending_headers: MapSet.t(),
          pending_bodies: MapSet.t(),
          pending_receipts: MapSet.t(),
          peers: [Peer.t()],
          syncing: boolean()
        }

  # Client API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec block_number() :: {:ok, non_neg_integer()} | {:error, term()}
  def block_number, do: GenServer.call(__MODULE__, :block_number)

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec pause() :: :ok
  def pause, do: GenServer.call(__MODULE__, :pause)

  @spec resume() :: :ok
  def resume, do: GenServer.call(__MODULE__, :resume)

  # Server callbacks

  @impl true
  def init(config) do
    chain = Keyword.get(config, :chain, :mainnet)
    synced_block = Storage.get_synced_block() || 0

    state =
      %__MODULE__{
        chain: chain,
        config: config,
        synced_block: synced_block,
        highest_block: synced_block,
        pending_headers: MapSet.new(),
        pending_bodies: MapSet.new(),
        pending_receipts: MapSet.new(),
        peers: [],
        syncing: true
      }
      |> tap(fn s ->
        Logger.info("[History.Sync] Starting stateless sync from block #{s.synced_block}")
        Telemetry.emit(:sync_started, %{chain: chain, start_block: s.synced_block})
      end)

    schedule_discover_peers()
    schedule_sync_tick()

    {:ok, state}
  end

  @impl true
  def handle_call(:block_number, _from, state) do
    {:reply, {:ok, state.synced_block}, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      synced_block: state.synced_block,
      highest_block: state.highest_block,
      peers: length(state.peers),
      syncing: state.syncing,
      pending: %{
        headers: MapSet.size(state.pending_headers),
        bodies: MapSet.size(state.pending_bodies),
        receipts: MapSet.size(state.pending_receipts)
      }
    }

    {:reply, status, state}
  end

  def handle_call(:pause, _from, state) do
    {:reply, :ok, %{state | syncing: false}}
  end

  def handle_call(:resume, _from, state) do
    schedule_sync_tick()
    {:reply, :ok, %{state | syncing: true}}
  end

  @impl true
  def handle_info(:discover_peers, state) do
    peers = discover_peers(state.chain)
    Logger.info("[History.Sync] Discovered #{length(peers)} peers")
    schedule_discover_peers(60_000)
    {:noreply, %{state | peers: peers}}
  end

  def handle_info(:sync_tick, %{syncing: false} = state), do: {:noreply, state}

  def handle_info(:sync_tick, state) do
    state
    |> sync_next_batch()
    |> schedule_next_tick()
    |> then(&{:noreply, &1})
  end

  def handle_info({:headers, block_numbers, headers}, state) do
    {:noreply, process_headers(state, block_numbers, headers)}
  end

  def handle_info({:bodies, block_numbers, bodies}, state) do
    {:noreply, process_bodies(state, block_numbers, bodies)}
  end

  def handle_info({:receipts, block_numbers, receipts}, state) do
    {:noreply, process_receipts(state, block_numbers, receipts)}
  end

  def handle_info({:highest_block, block_number}, state) do
    {:noreply, %{state | highest_block: max(state.highest_block, block_number)}}
  end

  # Private functions

  defp schedule_discover_peers(delay \\ 0), do: Process.send_after(self(), :discover_peers, delay)
  defp schedule_sync_tick(delay \\ 0), do: Process.send_after(self(), :sync_tick, delay)

  defp schedule_next_tick(state) do
    delay = if state.synced_block < state.highest_block, do: 100, else: 1_000
    schedule_sync_tick(delay)
    state
  end

  defp discover_peers(chain) do
    chain_config = History.Config.chain_config(chain)

    case PeerSupervisor.get_active_peers() do
      peers when is_list(peers) and length(peers) > 0 ->
        peers

      _ ->
        Enum.map(chain_config.bootnodes, &%Peer{enode: &1})
    end
  end

  defp sync_next_batch(state) do
    batch_size = Keyword.get(state.config, :batch_size, @batch_size)
    start_block = state.synced_block + 1
    block_numbers = Enum.to_list(start_block..(start_block + batch_size - 1))

    case request_headers(state.peers, block_numbers) do
      {:ok, _request_id} ->
        %{state | pending_headers: MapSet.union(state.pending_headers, MapSet.new(block_numbers))}

      {:error, reason} ->
        Logger.warning("[History.Sync] Failed to request headers: #{inspect(reason)}")
        state
    end
  end

  defp process_headers(state, block_numbers, headers) do
    # Store headers
    block_numbers
    |> Enum.zip(headers)
    |> Enum.each(fn {number, header} -> Storage.put_header(number, header) end)

    highest = Enum.max(block_numbers)

    with {:ok, _} <- request_bodies(state.peers, block_numbers) do
      %{
        state
        | highest_block: max(state.highest_block, highest),
          pending_headers: MapSet.difference(state.pending_headers, MapSet.new(block_numbers)),
          pending_bodies: MapSet.union(state.pending_bodies, MapSet.new(block_numbers))
      }
    else
      _ -> %{state | highest_block: max(state.highest_block, highest)}
    end
  end

  defp process_bodies(state, block_numbers, bodies) do
    # Store transactions
    block_numbers
    |> Enum.zip(bodies)
    |> Enum.each(fn {number, body} -> Storage.put_transactions(number, body.transactions) end)

    with {:ok, _} <- request_receipts(state.peers, block_numbers) do
      %{
        state
        | pending_bodies: MapSet.difference(state.pending_bodies, MapSet.new(block_numbers)),
          pending_receipts: MapSet.union(state.pending_receipts, MapSet.new(block_numbers))
      }
    else
      _ -> state
    end
  end

  defp process_receipts(state, block_numbers, receipts_list) do
    # Extract and store logs from receipts
    block_numbers
    |> Enum.zip(receipts_list)
    |> Enum.each(fn {block_number, receipts} ->
      logs = extract_logs(block_number, receipts)

      Storage.put_logs(block_number, logs)
      Index.BloomIndex.add_logs(block_number, logs)

      # Broadcast to WebSocket subscribers
      Phoenix.PubSub.broadcast(History.PubSub, "blocks", {:new_block, block_number, logs})

      Telemetry.emit(:block_synced, %{block_number: block_number, log_count: length(logs)})
    end)

    new_synced = Enum.max(block_numbers)

    # Checkpoint periodically
    if rem(new_synced, @checkpoint_interval) == 0 do
      Storage.checkpoint(new_synced)
      Logger.info("[History.Sync] Checkpoint at block #{new_synced}")

      Phoenix.PubSub.broadcast(
        History.PubSub,
        "blocks",
        {:sync_status,
         %{
           synced_block: new_synced,
           highest_block: state.highest_block,
           syncing: state.syncing
         }}
      )
    end

    %{
      state
      | synced_block: new_synced,
        pending_receipts: MapSet.difference(state.pending_receipts, MapSet.new(block_numbers))
    }
  end

  defp extract_logs(block_number, receipts) do
    receipts
    |> Enum.with_index()
    |> Enum.flat_map(fn {receipt, tx_index} ->
      receipt.logs
      |> Enum.with_index()
      |> Enum.map(fn {log, log_index} ->
        %{
          address: log.address,
          topics: log.topics,
          data: log.data,
          block_number: block_number,
          transaction_index: tx_index,
          log_index: log_index
        }
      end)
    end)
  end

  # P2P request helpers

  defp request_headers([], _block_numbers), do: {:error, :no_peers}

  defp request_headers(peers, block_numbers) do
    peer = Enum.random(peers)

    request = %ExWire.Packet.Capability.Eth.GetBlockHeaders{
      block_identifier: hd(block_numbers),
      max_headers: length(block_numbers),
      skip: 0,
      reverse: false
    }

    ExWire.Packet.send(peer, request)
    {:ok, make_ref()}
  end

  defp request_bodies([], _block_numbers), do: {:error, :no_peers}

  defp request_bodies(peers, block_numbers) do
    peer = Enum.random(peers)

    hashes =
      Enum.map(block_numbers, fn num ->
        {:ok, header} = Storage.get_header(num)
        header.block_hash
      end)

    request = %ExWire.Packet.Capability.Eth.GetBlockBodies{hashes: hashes}
    ExWire.Packet.send(peer, request)
    {:ok, make_ref()}
  end

  defp request_receipts([], _block_numbers), do: {:error, :no_peers}

  defp request_receipts(peers, block_numbers) do
    peer = Enum.random(peers)

    hashes =
      Enum.map(block_numbers, fn num ->
        {:ok, header} = Storage.get_header(num)
        header.block_hash
      end)

    request = %ExWire.Packet.Capability.Eth.GetReceipts{block_hashes: hashes}
    ExWire.Packet.send(peer, request)
    {:ok, make_ref()}
  end
end
