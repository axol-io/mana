defmodule ExWire.Eth2.CheckpointSync do
  @moduledoc """
  Checkpoint sync implementation for Ethereum 2.0.

  Enables fast syncing from a trusted checkpoint instead of genesis,
  reducing sync time from days to minutes. Implements weak subjectivity
  checkpoints for secure fast sync.
  """

  use GenServer
  require Logger

  alias ExWire.Eth2.{
    BeaconChain,
    StateStore,
    ForkChoice
  }

  alias ExWire.LibP2P

  # Checkpoint sync parameters
  # slots (~7.5 days)
  @weak_subjectivity_period 54_000
  # blocks per request
  @backfill_batch_size 64
  # requests per second
  @backfill_rate_limit 10
  # 1 minute
  @state_download_timeout 60_000
  # blocks to verify after checkpoint
  @verification_depth 256

  defstruct [
    :checkpoint_root,
    :checkpoint_epoch,
    :checkpoint_state,
    :trusted_block_root,
    :backfill_target,
    :backfill_progress,
    :sync_status,
    :beacon_chain,
    :state_store,
    :libp2p,
    :peers,
    backfilling: false,
    verified: false
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start checkpoint sync from a trusted checkpoint
  """
  def start_sync(checkpoint_root, checkpoint_epoch) do
    GenServer.call(__MODULE__, {:start_sync, checkpoint_root, checkpoint_epoch})
  end

  @doc """
  Get current sync status
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Verify weak subjectivity checkpoint
  """
  def verify_checkpoint(state_root, block_root) do
    GenServer.call(__MODULE__, {:verify_checkpoint, state_root, block_root})
  end

  @doc """
  Resume sync from saved checkpoint
  """
  def resume_sync do
    GenServer.call(__MODULE__, :resume_sync)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %__MODULE__{
      beacon_chain: Keyword.get(opts, :beacon_chain),
      state_store: Keyword.get(opts, :state_store, StateStore),
      libp2p: Keyword.get(opts, :libp2p, LibP2P),
      peers: [],
      sync_status: :idle,
      backfill_progress: %{
        current_slot: nil,
        target_slot: nil,
        blocks_downloaded: 0,
        blocks_processed: 0,
        start_time: nil
      }
    }

    # Check for saved checkpoint
    case load_checkpoint() do
      {:ok, checkpoint} ->
        Logger.info("Resuming from saved checkpoint: #{inspect(checkpoint.root)}")

        {:ok,
         %{
           state
           | checkpoint_root: checkpoint.root,
             checkpoint_epoch: checkpoint.epoch,
             checkpoint_state: checkpoint.state
         }}

      :error ->
        {:ok, _state}
    end
  end

  @impl true
  def handle_call({:start_sync, checkpoint_root, checkpoint_epoch}, _from, _state) do
    Logger.info("Starting checkpoint sync from epoch #{checkpoint_epoch}")

    # Validate checkpoint is within weak subjectivity period
    case validate_checkpoint_age(checkpoint_epoch) do
      :ok ->
        # Start sync process
        new_state = initiate_checkpoint_sync(checkpoint_root, checkpoint_epoch, _state)
        {:reply, :ok, new_state}

      {:error, _reason} = error ->
        Logger.error("Invalid checkpoint: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call(:get_status, _from, _state) do
    status = %{
      status: state.sync_status,
      checkpoint_root: state.checkpoint_root,
      checkpoint_epoch: state.checkpoint_epoch,
      backfilling: state.backfilling,
      verified: state.verified,
      progress: calculate_progress(state)
    }

    {:reply, status, state}
  end

  def handle_call({:verify_checkpoint, state_root, block_root}, _from, _state) do
    result = verify_checkpoint_internal(state_root, block_root, state)

    new_state =
      case result do
        :ok -> %{_state | verified: true}
        _ -> state
      end

    {:reply, result, new_state}
  end

  def handle_call(:resume_sync, _from, _state) do
    if state.checkpoint_root do
      new_state = resume_sync_internal(state)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :no_checkpoint}, state}
    end
  end

  @impl true
  def handle_info({:checkpoint_state_downloaded, checkpoint_state}, _state) do
    Logger.info("Checkpoint state downloaded successfully")

    # Validate state root matches
    computed_root = compute_state_root(checkpoint_state)

    if computed_root == state.checkpoint_root do
      # Save checkpoint state
      save_checkpoint_state(checkpoint_state)

      # Initialize beacon chain from checkpoint
      initialize_from_checkpoint(checkpoint_state, state)

      # Start backfilling
      new_state = start_backfill(checkpoint_state, state)

      {:noreply, %{new_state | checkpoint_state: checkpoint_state, sync_status: :backfilling}}
    else
      Logger.error(
        "State root mismatch! Expected: #{inspect(state.checkpoint_root)}, Got: #{inspect(computed_root)}"
      )

      {:noreply, %{state | sync_status: :failed}}
    end
  end

  def handle_info({:blocks_downloaded, blocks}, _state) do
    # Process downloaded blocks
    new_state = process_backfill_blocks(blocks, state)

    # Continue backfilling if needed
    if more_blocks_needed?(new_state) do
      request_next_batch(new_state)
      {:noreply, new_state}
    else
      # Backfill complete
      Logger.info("Checkpoint sync complete!")
      finalize_sync(new_state)
      {:noreply, %{new_state | sync_status: :synced, backfilling: false}}
    end
  end

  def handle_info({:download_failed, _reason}, _state) do
    Logger.error("Download failed: #{inspect(reason)}")

    # Retry with different peer
    new_state = retry_download(state)
    {:noreply, new_state}
  end

  def handle_info(:verify_checkpoint_blocks, _state) do
    # Verify blocks after checkpoint for security
    case verify_post_checkpoint_blocks(state) do
      :ok ->
        Logger.info("Checkpoint verification successful")
        {:noreply, %{_state | verified: true}}

      {:error, _reason} ->
        Logger.error("Checkpoint verification failed: #{inspect(reason)}")
        {:noreply, %{state | sync_status: :failed}}
    end
  end

  # Private Functions - Sync Initialization

  defp initiate_checkpoint_sync(checkpoint_root, checkpoint_epoch, _state) do
    # Get suitable peers
    peers =
      LibP2P.get_peers()
      |> filter_suitable_peers()

    if peers == [] do
      Logger.error("No suitable peers for checkpoint sync")
      %{state | sync_status: :no_peers}
    else
      # Request checkpoint state from peers
      request_checkpoint_state(checkpoint_root, peers)

      %{
        state
        | checkpoint_root: checkpoint_root,
          checkpoint_epoch: checkpoint_epoch,
          peers: peers,
          sync_status: :downloading_checkpoint,
          backfill_progress: %{
            # slots per epoch
            current_slot: checkpoint_epoch * 32,
            # Genesis
            target_slot: 0,
            blocks_downloaded: 0,
            blocks_processed: 0,
            start_time: System.system_time(:second)
          }
      }
    end
  end

  defp validate_checkpoint_age(checkpoint_epoch) do
    current_epoch = get_current_epoch()
    age = current_epoch - checkpoint_epoch

    if age <= @weak_subjectivity_period do
      :ok
    else
      {:error, :checkpoint_too_old}
    end
  end

  defp request_checkpoint_state(state_root, peers) do
    # Select best peer
    peer = select_best_peer(peers)

    # Request state via LibP2P
    Task.start(fn ->
      case download_state(peer, state_root) do
        {:ok, _state} ->
          send(self(), {:checkpoint_state_downloaded, state})

        {:error, _reason} ->
          send(self(), {:download_failed, reason})
      end
    end)
  end

  defp download_state(peer, state_root) do
    # Download state from peer
    # This would use LibP2P req/resp protocol
    case LibP2P.request_state(peer, state_root) do
      {:ok, encoded_state} ->
        # Decode SSZ encoded state
        decode_beacon_state(encoded_state)

      error ->
        error
    end
  end

  # Private Functions - Backfilling

  defp start_backfill(checkpoint_state, _state) do
    Logger.info("Starting backfill from slot #{checkpoint_state.slot} to genesis")

    # Request first batch of blocks
    request_blocks_batch(
      checkpoint_state.slot - 1,
      @backfill_batch_size,
      state
    )

    %{
      state
      | backfilling: true,
        # Genesis
        backfill_target: 0
    }
  end

  defp request_blocks_batch(start_slot, count, _state) do
    peer = select_best_peer(state.peers)

    Task.start(fn ->
      case LibP2P.request_blocks_by_range(peer, start_slot, count, -1) do
        {:ok, blocks} ->
          send(self(), {:blocks_downloaded, blocks})

        {:error, _reason} ->
          send(self(), {:download_failed, reason})
      end
    end)
  end

  defp process_backfill_blocks(blocks, _state) do
    # Process blocks in reverse order (newest to oldest)
    processed =
      Enum.reduce(blocks, state, fn block, acc_state ->
        case process_backfill_block(block, acc_state) do
          {:ok, new_state} ->
            new_state

          {:error, _reason} ->
            Logger.error("Failed to process block: #{inspect(reason)}")
            acc_state
        end
      end)

    # Update progress
    update_backfill_progress(processed, length(blocks))
  end

  defp process_backfill_block(block, _state) do
    # Verify block signatures
    case verify_block_signatures(block) do
      :ok ->
        # Store block
        StateStore.store_block(state.state_store, block)

        # Update fork choice
        ForkChoice.on_block(block)

        {:ok, _state}

      error ->
        error
    end
  end

  defp more_blocks_needed?(state) do
    state.backfill_progress.current_slot > state.backfill_target
  end

  defp request_next_batch(_state) do
    next_start = state.backfill_progress.current_slot - @backfill_batch_size
    request_blocks_batch(next_start, @backfill_batch_size, state)
  end

  defp update_backfill_progress(_state, blocks_count) do
    progress = state.backfill_progress

    new_progress = %{
      progress
      | blocks_downloaded: progress.blocks_downloaded + blocks_count,
        blocks_processed: progress.blocks_processed + blocks_count,
        current_slot: max(0, progress.current_slot - blocks_count)
    }

    %{state | backfill_progress: new_progress}
  end

  # Private Functions - Verification

  defp verify_checkpoint_internal(state_root, block_root, _state) do
    # Verify the checkpoint against trusted sources
    cond do
      state.checkpoint_root != state_root ->
        {:error, :state_root_mismatch}

      state.trusted_block_root && state.trusted_block_root != block_root ->
        {:error, :block_root_mismatch}

      true ->
        # Additional verification logic
        verify_checkpoint_consistency(state)
    end
  end

  defp verify_checkpoint_consistency(_state) do
    # Verify checkpoint state is consistent
    if state.checkpoint_state do
      # Check state transition validity
      case validate_state_transition(state.checkpoint_state) do
        :ok -> :ok
        error -> error
      end
    else
      {:error, :no_checkpoint_state}
    end
  end

  defp verify_post_checkpoint_blocks(_state) do
    # Verify a number of blocks after checkpoint
    # This ensures the checkpoint leads to valid chain

    blocks_to_verify = @verification_depth
    start_slot = state.checkpoint_epoch * 32

    case fetch_and_verify_blocks(start_slot, blocks_to_verify) do
      {:ok, _blocks} ->
        :ok

      error ->
        error
    end
  end

  defp fetch_and_verify_blocks(start_slot, count) do
    # Fetch blocks and verify signatures
    # Get from available peers
    peer = select_best_peer([])

    case LibP2P.request_blocks_by_range(peer, start_slot, count, 1) do
      {:ok, blocks} ->
        verify_block_chain(blocks)

      error ->
        error
    end
  end

  defp verify_block_chain([]), do: {:ok, []}

  defp verify_block_chain([block | rest]) do
    case verify_block_signatures(block) do
      :ok ->
        case verify_block_chain(rest) do
          {:ok, verified} -> {:ok, [block | verified]}
          error -> error
        end

      error ->
        error
    end
  end

  defp verify_block_signatures(block) do
    # Verify BLS signatures on block
    # This would use the real BLS module
    # Placeholder
    :ok
  end

  # Private Functions - State Management

  defp initialize_from_checkpoint(checkpoint_state, _state) do
    # Initialize beacon chain from checkpoint
    BeaconChain.initialize_from_checkpoint(
      state.beacon_chain,
      checkpoint_state
    )

    # Initialize fork choice
    ForkChoice.initialize_from_checkpoint(checkpoint_state)

    # Start processing new blocks from checkpoint
    schedule_post_checkpoint_verification()
  end

  defp finalize_sync(_state) do
    # Mark sync as complete
    save_sync_progress(state)

    # Notify beacon chain
    BeaconChain.checkpoint_sync_complete(state.beacon_chain)

    # Start normal sync from checkpoint
    BeaconChain.start_sync(state.beacon_chain)
  end

  defp resume_sync_internal(_state) do
    if state.checkpoint_state do
      # Resume from saved state
      initialize_from_checkpoint(state.checkpoint_state, state)

      # Continue backfilling if needed
      if state.backfilling do
        request_next_batch(state)
      end

      %{state | sync_status: :resuming}
    else
      # Need to re-download checkpoint
      initiate_checkpoint_sync(
        state.checkpoint_root,
        state.checkpoint_epoch,
        state
      )
    end
  end

  # Private Functions - Persistence

  defp save_checkpoint_state(checkpoint_state) do
    # Save to disk for recovery
    File.write!(
      checkpoint_file_path(),
      :erlang.term_to_binary(checkpoint_state)
    )
  end

  defp load_checkpoint do
    path = checkpoint_file_path()

    if File.exists?(path) do
      data = File.read!(path)
      checkpoint = :erlang.binary_to_term(data)
      {:ok, checkpoint}
    else
      :error
    end
  end

  defp save_checkpoint(checkpoint) do
    File.write!(
      checkpoint_file_path(),
      :erlang.term_to_binary(checkpoint)
    )
  end

  defp save_sync_progress(_state) do
    progress = %{
      checkpoint_root: state.checkpoint_root,
      checkpoint_epoch: state.checkpoint_epoch,
      backfill_progress: state.backfill_progress,
      verified: state.verified
    }

    File.write!(
      progress_file_path(),
      :erlang.term_to_binary(progress)
    )
  end

  defp checkpoint_file_path do
    Path.join([data_dir(), "checkpoint.dat"])
  end

  defp progress_file_path do
    Path.join([data_dir(), "sync_progress.dat"])
  end

  defp data_dir do
    Application.get_env(:ex_wire, :data_dir, "./data")
  end

  # Private Functions - Utilities

  defp filter_suitable_peers(peers) do
    # Filter peers that support checkpoint sync
    Enum.filter(peers, fn peer ->
      peer.protocols && "checkpoint_sync" in peer.protocols
    end)
  end

  defp select_best_peer(peers) do
    # Select peer with best score/latency
    peers
    |> Enum.sort_by(& &1.score, :desc)
    |> List.first()
  end

  defp retry_download(_state) do
    # Remove failed peer and try another
    case state.peers -- [List.first(state.peers)] do
      [] ->
        Logger.error("No more peers available for download")
        %{_state | sync_status: :failed}

      remaining_peers ->
        request_checkpoint_state(state.checkpoint_root, remaining_peers)
        %{state | peers: remaining_peers}
    end
  end

  defp calculate_progress(_state) do
    if state.backfill_progress.start_time do
      elapsed = System.system_time(:second) - state.backfill_progress.start_time

      blocks_per_second =
        if elapsed > 0 do
          state.backfill_progress.blocks_processed / elapsed
        else
          0
        end

      remaining_blocks = state.backfill_progress.current_slot - state.backfill_target

      eta =
        if blocks_per_second > 0 do
          remaining_blocks / blocks_per_second
        else
          :infinity
        end

      %{
        blocks_downloaded: state.backfill_progress.blocks_downloaded,
        blocks_processed: state.backfill_progress.blocks_processed,
        blocks_per_second: Float.round(blocks_per_second, 2),
        remaining_blocks: remaining_blocks,
        eta_seconds: eta
      }
    else
      %{
        blocks_downloaded: 0,
        blocks_processed: 0,
        blocks_per_second: 0,
        remaining_blocks: :unknown,
        eta_seconds: :infinity
      }
    end
  end

  defp compute_state_root(beacon_state) do
    # Compute SSZ hash tree root of state
    # This would use proper SSZ implementation
    :crypto.hash(:sha256, :erlang.term_to_binary(beacon_state))
  end

  defp decode_beacon_state(encoded) do
    # Decode SSZ encoded beacon state
    # This would use proper SSZ decoder
    {:ok, :erlang.binary_to_term(encoded)}
  end

  defp validate_state_transition(_state) do
    # Validate state transition rules
    :ok
  end

  defp get_current_epoch do
    # Get current epoch from system time
    current_slot = div(System.system_time(:second) - genesis_time(), 12)
    div(current_slot, 32)
  end

  defp genesis_time do
    # Ethereum mainnet genesis time
    1_606_824_023
  end

  defp schedule_post_checkpoint_verification do
    Process.send_after(self(), :verify_checkpoint_blocks, 5_000)
  end
end
