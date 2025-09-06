defmodule ExWire.SimpleSync do
  @moduledoc """
  Simplified sync implementation using standard GenServer patterns.
  This demonstrates the architectural improvements for sync functionality.
  """

  use GenServer
  require Logger

  # State structure
  defstruct [
    :chain,
    :block_queue,
    :peer_connections,
    :sync_status,
    :current_block,
    :highest_block,
    :metrics,
    :config
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_sync_status do
    GenServer.call(__MODULE__, :get_sync_status)
  end

  def add_peer(peer_info) do
    GenServer.cast(__MODULE__, {:add_peer, peer_info})
  end

  def remove_peer(peer_id) do
    GenServer.cast(__MODULE__, {:remove_peer, peer_id})
  end

  def sync_blocks(start_block, end_block) do
    GenServer.call(__MODULE__, {:sync_blocks, start_block, end_block})
  end

  def get_sync_progress do
    GenServer.call(__MODULE__, :get_sync_progress)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    chain = Keyword.get(opts, :chain, :mainnet)

    state = %__MODULE__{
      chain: chain,
      block_queue: :queue.new(),
      peer_connections: %{},
      sync_status: :initializing,
      current_block: 0,
      highest_block: 0,
      metrics: %{
        blocks_synced: 0,
        peers_connected: 0,
        sync_speed: 0,
        last_sync_time: nil
      },
      config: Keyword.get(opts, :config, %{})
    }

    # Schedule status update
    Process.send_after(self(), :update_status, 1000)

    emit_telemetry(:sync_started, %{chain: chain})
    {:ok, state}
  end

  @impl true
  def handle_call(:get_sync_status, _from, state) do
    status = %{
      status: state.sync_status,
      current_block: state.current_block,
      highest_block: state.highest_block,
      chain: state.chain,
      connected_peers: map_size(state.peer_connections)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:sync_blocks, start_block, end_block}, _from, state) do
    if start_block >= end_block do
      {:reply, {:error, :invalid_range}, state}
    else
      # Simulate block syncing
      block_count = end_block - start_block

      new_state = %{
        state
        | sync_status: :syncing,
          current_block: start_block,
          highest_block: end_block
      }

      # Schedule block processing
      Process.send_after(self(), {:process_blocks, start_block, end_block}, 100)

      emit_telemetry(:sync_started, %{
        start_block: start_block,
        end_block: end_block,
        block_count: block_count
      })

      {:reply, {:ok, block_count}, new_state}
    end
  end

  @impl true
  def handle_call(:get_sync_progress, _from, state) do
    progress = calculate_progress(state)
    {:reply, progress, state}
  end

  @impl true
  def handle_cast({:add_peer, peer_info}, state) do
    peer_id = peer_info.id || generate_peer_id()

    new_peer_connections =
      Map.put(state.peer_connections, peer_id, %{
        info: peer_info,
        connected_at: :os.system_time(:millisecond),
        blocks_received: 0,
        last_seen: :os.system_time(:millisecond)
      })

    new_metrics = Map.put(state.metrics, :peers_connected, map_size(new_peer_connections))

    new_state = %{state | peer_connections: new_peer_connections, metrics: new_metrics}

    emit_telemetry(:peer_connected, %{
      peer_id: peer_id,
      total_peers: map_size(new_peer_connections)
    })

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:remove_peer, peer_id}, state) do
    if Map.has_key?(state.peer_connections, peer_id) do
      new_peer_connections = Map.delete(state.peer_connections, peer_id)
      new_metrics = Map.put(state.metrics, :peers_connected, map_size(new_peer_connections))

      new_state = %{state | peer_connections: new_peer_connections, metrics: new_metrics}

      emit_telemetry(:peer_disconnected, %{
        peer_id: peer_id,
        total_peers: map_size(new_peer_connections)
      })

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:update_status, state) do
    new_sync_status = determine_sync_status(state)

    new_state = %{state | sync_status: new_sync_status}

    # Schedule next update
    Process.send_after(self(), :update_status, 5000)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:process_blocks, start_block, end_block}, state) do
    # Simulate processing blocks
    blocks_to_process = min(10, end_block - state.current_block)

    if blocks_to_process > 0 do
      new_current = state.current_block + blocks_to_process

      new_metrics =
        state.metrics
        |> Map.put(:blocks_synced, state.metrics.blocks_synced + blocks_to_process)
        |> Map.put(:last_sync_time, :os.system_time(:millisecond))

      new_state = %{state | current_block: new_current, metrics: new_metrics}

      emit_telemetry(:blocks_processed, %{
        count: blocks_to_process,
        current_block: new_current,
        progress: new_current / end_block * 100
      })

      # Continue processing if more blocks remain
      if new_current < end_block do
        Process.send_after(self(), {:process_blocks, start_block, end_block}, 50)
      else
        # Sync complete
        final_state = %{new_state | sync_status: :synchronized}

        emit_telemetry(:sync_completed, %{
          total_blocks: end_block - start_block,
          final_block: new_current
        })

        {:noreply, final_state}
      end

      {:noreply, new_state}
    else
      # No more blocks to process
      final_state = %{state | sync_status: :synchronized}
      {:noreply, final_state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private helpers

  defp calculate_progress(state) do
    if state.highest_block > 0 do
      percentage = state.current_block / state.highest_block * 100

      %{
        current_block: state.current_block,
        highest_block: state.highest_block,
        percentage: Float.round(percentage, 2),
        status: state.sync_status,
        blocks_remaining: state.highest_block - state.current_block
      }
    else
      %{
        current_block: state.current_block,
        highest_block: state.highest_block,
        percentage: 0.0,
        status: state.sync_status,
        blocks_remaining: 0
      }
    end
  end

  defp determine_sync_status(state) do
    cond do
      map_size(state.peer_connections) == 0 -> :disconnected
      state.current_block == 0 -> :initializing
      state.current_block < state.highest_block -> :syncing
      state.current_block >= state.highest_block -> :synchronized
      true -> :unknown
    end
  end

  defp generate_peer_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:ex_wire, :simple_sync_v2, event],
      %{count: 1, timestamp: :os.system_time(:millisecond)},
      metadata
    )
  end
end
