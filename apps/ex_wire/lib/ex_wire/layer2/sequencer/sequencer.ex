defmodule ExWire.Layer2.Sequencer.Sequencer do
  @moduledoc """
  Transaction sequencer for Layer 2 rollups.

  Handles:
  - Transaction ordering with priority fees
  - Batch creation and submission
  - MEV resistance mechanisms
  - Fair ordering guarantees
  - Reorg handling
  """

  use GenServer
  require Logger

  alias ExWire.Layer2.Rollup
  alias ExWire.Layer2.Sequencer.{OrderingPolicy, MEVProtection, BatchBuilder}

  @type ordering_mode :: :fifo | :priority_fee | :fair | :mev_auction
  @type tx_status :: :pending | :included | :rejected | :expired

  @type sequencer_tx :: %{
          hash: binary(),
          from: binary(),
          to: binary(),
          data: binary(),
          gas_limit: non_neg_integer(),
          priority_fee: non_neg_integer(),
          max_fee: non_neg_integer(),
          nonce: non_neg_integer(),
          received_at: DateTime.t(),
          status: tx_status()
        }

  @type t :: %__MODULE__{
          sequencer_id: String.t(),
          rollup_id: String.t(),
          ordering_mode: ordering_mode(),
          mempool: list(sequencer_tx()),
          current_batch: list(sequencer_tx()),
          batch_size_limit: non_neg_integer(),
          batch_time_limit: non_neg_integer(),
          last_batch_time: DateTime.t(),
          sequence_number: non_neg_integer(),
          mev_protection: boolean()
        }

  defstruct [
    :sequencer_id,
    :rollup_id,
    :ordering_mode,
    :batch_size_limit,
    :batch_time_limit,
    :last_batch_time,
    mempool: [],
    current_batch: [],
    sequence_number: 0,
    mev_protection: true
  ]

  # Client API

  @doc """
  Starts a sequencer for a rollup.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:sequencer_id]))
  end

  @doc """
  Submits a transaction to the sequencer.
  """
  @spec submit_transaction(String.t(), map()) :: {:ok, binary()} | {:error, term()}
  def submit_transaction(sequencer_id, tx_params) do
    GenServer.call(via_tuple(sequencer_id), {:submit_transaction, tx_params})
  end

  @doc """
  Forces creation of a batch with current pending transactions.
  """
  @spec force_batch(String.t()) :: {:ok, String.t()} | {:error, term()}
  def force_batch(sequencer_id) do
    GenServer.call(via_tuple(sequencer_id), :force_batch)
  end

  @doc """
  Gets the current mempool status.
  """
  @spec get_mempool_status(String.t()) :: {:ok, map()} | {:error, term()}
  def get_mempool_status(sequencer_id) do
    GenServer.call(via_tuple(sequencer_id), :get_mempool_status)
  end

  @doc """
  Gets transaction status by hash.
  """
  @spec get_transaction_status(String.t(), binary()) ::
          {:ok, tx_status()} | {:error, :not_found}
  def get_transaction_status(sequencer_id, tx_hash) do
    GenServer.call(via_tuple(sequencer_id), {:get_transaction_status, tx_hash})
  end

  @doc """
  Updates sequencer configuration.
  """
  @spec update_config(String.t(), map()) :: :ok | {:error, term()}
  def update_config(sequencer_id, config) do
    GenServer.call(via_tuple(sequencer_id), {:update_config, config})
  end

  @doc """
  Handles chain reorganization.
  """
  @spec handle_reorg(String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  def handle_reorg(sequencer_id, old_block, new_block) do
    GenServer.call(via_tuple(sequencer_id), {:handle_reorg, old_block, new_block})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting Sequencer: #{opts[:sequencer_id]} for rollup #{opts[:rollup_id]}")

    state = %__MODULE__{
      sequencer_id: opts[:sequencer_id],
      rollup_id: opts[:rollup_id],
      ordering_mode: opts[:ordering_mode] || :priority_fee,
      batch_size_limit: opts[:batch_size_limit] || 1000,
      # 2 seconds
      batch_time_limit: opts[:batch_time_limit] || 2000,
      last_batch_time: DateTime.utc_now(),
      mev_protection: opts[:mev_protection] != false
    }

    # Schedule periodic batch creation
    Process.send_after(self(), :check_batch_creation, state.batch_time_limit)

    # Schedule mempool cleanup
    # Every minute
    Process.send_after(self(), :cleanup_mempool, 60_000)

    {:ok, state}
  end

  @impl true
  def handle_call({:submit_transaction, tx_params}, _from, state) do
    tx_hash = compute_tx_hash(tx_params)

    transaction = %{
      hash: tx_hash,
      from: tx_params[:from],
      to: tx_params[:to],
      data: tx_params[:data] || <<>>,
      gas_limit: tx_params[:gas_limit],
      priority_fee: tx_params[:priority_fee] || 0,
      max_fee: tx_params[:max_fee],
      nonce: tx_params[:nonce],
      received_at: DateTime.utc_now(),
      status: :pending
    }

    # Validate transaction
    case validate_transaction(transaction, state) do
      :ok ->
        # Add to mempool with MEV protection if enabled
        new_mempool =
          if state.mev_protection do
            add_with_mev_protection(transaction, state.mempool)
          else
            add_to_mempool(transaction, state.mempool, state.ordering_mode)
          end

        Logger.debug("Transaction added to mempool: #{Base.encode16(tx_hash)}")

        {:reply, {:ok, tx_hash}, %{state | mempool: new_mempool}}

      {:error, reason} = error ->
        Logger.warning("Transaction rejected: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:force_batch, _from, state) do
    case create_and_submit_batch(state) do
      {:ok, batch_id, new_state} ->
        {:reply, {:ok, batch_id}, new_state}

      {:error, reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_mempool_status, _from, state) do
    status = %{
      pending_count: length(state.mempool),
      current_batch_size: length(state.current_batch),
      total_priority_fees: calculate_total_fees(state.mempool),
      oldest_tx: get_oldest_tx(state.mempool),
      ordering_mode: state.ordering_mode,
      mev_protection: state.mev_protection
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call({:get_transaction_status, tx_hash}, _from, state) do
    # Check mempool
    case find_transaction(tx_hash, state.mempool) do
      nil ->
        # Check current batch
        case find_transaction(tx_hash, state.current_batch) do
          nil ->
            {:reply, {:error, :not_found}, state}

          tx ->
            {:reply, {:ok, tx.status}, state}
        end

      tx ->
        {:reply, {:ok, tx.status}, state}
    end
  end

  @impl true
  def handle_call({:update_config, config}, _from, state) do
    new_state = %{
      state
      | ordering_mode: config[:ordering_mode] || state.ordering_mode,
        batch_size_limit: config[:batch_size_limit] || state.batch_size_limit,
        batch_time_limit: config[:batch_time_limit] || state.batch_time_limit,
        mev_protection:
          if Map.has_key?(config, :mev_protection) do
            config[:mev_protection]
          else
            state.mev_protection
          end
    }

    Logger.info("Sequencer config updated: #{inspect(config)}")

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:handle_reorg, old_block, new_block}, _from, state) do
    Logger.warning("Handling reorg from block #{old_block} to #{new_block}")

    # Re-add transactions from invalidated batches to mempool
    # This would require tracking which transactions were in which blocks

    # For now, just clear current batch and reset
    new_state = %{state | current_batch: [], sequence_number: calculate_new_sequence(new_block)}

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:check_batch_creation, state) do
    time_since_last = DateTime.diff(DateTime.utc_now(), state.last_batch_time, :millisecond)

    new_state =
      if should_create_batch?(state, time_since_last) do
        case create_and_submit_batch(state) do
          {:ok, _batch_id, updated_state} ->
            updated_state

          {:error, reason} ->
            Logger.error("Failed to create batch: #{inspect(reason)}")
            state
        end
      else
        state
      end

    Process.send_after(self(), :check_batch_creation, state.batch_time_limit)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:cleanup_mempool, state) do
    # Remove expired transactions
    now = DateTime.utc_now()
    # 10 minutes
    max_age = 600

    cleaned_mempool =
      Enum.filter(state.mempool, fn tx ->
        age = DateTime.diff(now, tx.received_at, :second)
        age < max_age
      end)

    removed_count = length(state.mempool) - length(cleaned_mempool)

    if removed_count > 0 do
      Logger.info("Removed #{removed_count} expired transactions from mempool")
    end

    Process.send_after(self(), :cleanup_mempool, 60_000)
    {:noreply, %{state | mempool: cleaned_mempool}}
  end

  # Private Functions

  defp via_tuple(sequencer_id) do
    {:via, Registry, {ExWire.Layer2.SequencerRegistry, sequencer_id}}
  end

  defp compute_tx_hash(tx_params) do
    # Compute transaction hash
    data = :erlang.term_to_binary(tx_params)
    :crypto.hash(:sha256, data)
  end

  defp validate_transaction(tx, state) do
    cond do
      tx.gas_limit < 21_000 ->
        {:error, :gas_limit_too_low}

      tx.max_fee < tx.priority_fee ->
        {:error, :invalid_fee_structure}

      not valid_nonce?(tx, state) ->
        {:error, :invalid_nonce}

      duplicate_transaction?(tx, state) ->
        {:error, :duplicate_transaction}

      true ->
        :ok
    end
  end

  defp valid_nonce?(tx, state) do
    # Check nonce against account state
    # Get account's current nonce from state or mempool
    account_nonce = get_account_nonce(tx.from, state)

    # Transaction nonce should be equal to or slightly ahead of current nonce
    # Allow up to 10 future nonces to be queued
    tx.nonce >= account_nonce && tx.nonce < account_nonce + 10
  end

  defp get_account_nonce(address, state) do
    # Check pending transactions in mempool for highest nonce
    pending_nonces =
      state.mempool
      |> Enum.filter(fn tx -> tx.from == address end)
      |> Enum.map(fn tx -> tx.nonce end)

    # Get the highest pending nonce + 1, or default to 0 for new accounts
    case pending_nonces do
      # No pending transactions, start from 0
      [] -> 0
      nonces -> Enum.max(nonces) + 1
    end
  end

  defp duplicate_transaction?(tx, state) do
    Enum.any?(state.mempool ++ state.current_batch, fn existing ->
      existing.hash == tx.hash
    end)
  end

  defp add_to_mempool(tx, mempool, ordering_mode) do
    case ordering_mode do
      :fifo ->
        # First in, first out
        mempool ++ [tx]

      :priority_fee ->
        # Sort by priority fee (highest first)
        [tx | mempool]
        |> Enum.sort_by(& &1.priority_fee, :desc)

      :fair ->
        # Fair ordering (randomized within time windows)
        OrderingPolicy.fair_order([tx | mempool])

      :mev_auction ->
        # MEV auction ordering
        OrderingPolicy.mev_auction_order([tx | mempool])
    end
  end

  defp add_with_mev_protection(tx, mempool) do
    # Add transaction with MEV protection
    # This includes commit-reveal, time-based ordering, etc.
    MEVProtection.add_protected(tx, mempool)
  end

  defp should_create_batch?(state, time_since_last) do
    cond do
      # Time limit reached
      time_since_last >= state.batch_time_limit and length(state.mempool) > 0 ->
        true

      # Size limit reached
      length(state.mempool) >= state.batch_size_limit ->
        true

      # Critical transactions pending (high priority fees)
      has_critical_transactions?(state.mempool) ->
        true

      true ->
        false
    end
  end

  defp has_critical_transactions?(mempool) do
    # Check if there are high-priority transactions
    Enum.any?(mempool, fn tx ->
      # 100 Gwei
      tx.priority_fee > 100_000_000_000
    end)
  end

  defp create_and_submit_batch(state) do
    # Select transactions for batch
    {batch_txs, remaining} =
      select_batch_transactions(
        state.mempool,
        state.batch_size_limit,
        state.ordering_mode
      )

    if length(batch_txs) == 0 do
      {:error, :no_transactions}
    else
      # Build batch
      batch =
        BatchBuilder.build(
          batch_txs,
          state.sequence_number + 1,
          state.rollup_id
        )

      # Submit to rollup
      case Rollup.submit_batch(state.rollup_id, batch) do
        {:ok, batch_number} ->
          # Update transaction statuses
          updated_batch_txs =
            Enum.map(batch_txs, fn tx ->
              %{tx | status: :included}
            end)

          new_state = %{
            state
            | mempool: remaining,
              current_batch: updated_batch_txs,
              sequence_number: state.sequence_number + 1,
              last_batch_time: DateTime.utc_now()
          }

          batch_id = "batch_#{batch_number}"

          Logger.info(
            "Batch created and submitted: #{batch_id} with #{length(batch_txs)} transactions"
          )

          {:ok, batch_id, new_state}

        {:error, reason} = error ->
          Logger.error("Failed to submit batch: #{inspect(reason)}")
          error
      end
    end
  end

  defp select_batch_transactions(mempool, limit, ordering_mode) do
    case ordering_mode do
      :fifo ->
        Enum.split(mempool, limit)

      :priority_fee ->
        # Take highest fee transactions
        sorted = Enum.sort_by(mempool, & &1.priority_fee, :desc)
        Enum.split(sorted, limit)

      :fair ->
        # Fair selection with some randomization
        OrderingPolicy.fair_select(mempool, limit)

      :mev_auction ->
        # MEV auction based selection
        OrderingPolicy.mev_select(mempool, limit)
    end
  end

  defp calculate_total_fees(mempool) do
    Enum.reduce(mempool, 0, fn tx, acc ->
      acc + tx.priority_fee * tx.gas_limit
    end)
  end

  defp get_oldest_tx([]), do: nil

  defp get_oldest_tx(mempool) do
    Enum.min_by(mempool, & &1.received_at, DateTime)
  end

  defp find_transaction(tx_hash, transactions) do
    Enum.find(transactions, fn tx -> tx.hash == tx_hash end)
  end

  defp calculate_new_sequence(block_number) do
    # Calculate new sequence number after reorg
    # This would depend on the specific rollup implementation
    block_number * 100
  end
end
