defmodule ExWire.Layer2.Rollup do
  @moduledoc """
  Base module for Layer 2 rollup support in Mana-Ethereum.

  This module provides the common abstraction layer for both optimistic
  and zero-knowledge rollups, handling:
  - State commitments and roots
  - Batch processing
  - Proof verification framework
  - Cross-layer synchronization
  """

  use GenServer
  require Logger

  alias ExWire.Layer2.{Batch, StateCommitment, ProofVerifier}

  @type rollup_type :: :optimistic | :zk
  @type rollup_id :: String.t()
  @type state_root :: binary()
  @type batch_number :: non_neg_integer()

  @type t :: %__MODULE__{
          id: rollup_id(),
          type: rollup_type(),
          current_batch: batch_number(),
          state_root: state_root(),
          config: map(),
          batches: map(),
          pending_proofs: list()
        }

  defstruct [
    :id,
    :type,
    :current_batch,
    :state_root,
    :config,
    batches: %{},
    pending_proofs: []
  ]

  @doc """
  Starts a new rollup manager process.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:id]))
  end

  @doc """
  Submits a new batch to the rollup.
  """
  @spec submit_batch(rollup_id(), Batch.t()) :: {:ok, batch_number()} | {:error, term()}
  def submit_batch(rollup_id, batch) do
    GenServer.call(via_tuple(rollup_id), {:submit_batch, batch})
  end

  @doc """
  Verifies a proof for a given batch.
  """
  @spec verify_proof(rollup_id(), batch_number(), binary()) :: {:ok, boolean()} | {:error, term()}
  def verify_proof(rollup_id, batch_number, proof) do
    GenServer.call(via_tuple(rollup_id), {:verify_proof, batch_number, proof})
  end

  @doc """
  Gets the current state root of the rollup.
  """
  @spec get_state_root(rollup_id()) :: {:ok, state_root()} | {:error, term()}
  def get_state_root(rollup_id) do
    GenServer.call(via_tuple(rollup_id), :get_state_root)
  end

  @doc """
  Gets information about a specific batch.
  """
  @spec get_batch(rollup_id(), batch_number()) :: {:ok, Batch.t()} | {:error, :not_found}
  def get_batch(rollup_id, batch_number) do
    GenServer.call(via_tuple(rollup_id), {:get_batch, batch_number})
  end

  @doc """
  Synchronizes the rollup state with Layer 1.
  """
  @spec sync_with_l1(rollup_id(), non_neg_integer()) :: :ok | {:error, term()}
  def sync_with_l1(rollup_id, l1_block_number) do
    GenServer.call(via_tuple(rollup_id), {:sync_with_l1, l1_block_number})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting Layer 2 Rollup: #{opts[:id]}")

    state = %__MODULE__{
      id: opts[:id],
      type: opts[:type] || :optimistic,
      current_batch: 0,
      state_root: opts[:genesis_root] || <<0::256>>,
      config: opts[:config] || default_config(opts[:type])
    }

    # Schedule periodic L1 synchronization
    # Every 12 seconds (L1 block time)
    Process.send_after(self(), :sync_l1, 12_000)

    {:ok, state}
  end

  @impl true
  def handle_call({:submit_batch, batch}, _from, state) do
    case process_batch(batch, state) do
      {:ok, new_state, batch_number} ->
        {:reply, {:ok, batch_number}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:verify_proof, batch_number, proof}, _from, state) do
    case Map.get(state.batches, batch_number) do
      nil ->
        {:reply, {:error, :batch_not_found}, state}

      batch ->
        case verify_batch_proof(batch, proof, state.type) do
          {:ok, true} ->
            updated_batch = %{batch | verified: true}
            new_batches = Map.put(state.batches, batch_number, updated_batch)
            {:reply, {:ok, true}, %{state | batches: new_batches}}

          {:ok, false} ->
            {:reply, {:ok, false}, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call(:get_state_root, _from, state) do
    {:reply, {:ok, state.state_root}, state}
  end

  @impl true
  def handle_call({:get_batch, batch_number}, _from, state) do
    case Map.get(state.batches, batch_number) do
      nil -> {:reply, {:error, :not_found}, state}
      batch -> {:reply, {:ok, batch}, state}
    end
  end

  @impl true
  def handle_call({:sync_with_l1, l1_block_number}, _from, state) do
    case perform_l1_sync(state, l1_block_number) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:sync_l1, state) do
    # Periodic L1 synchronization
    case get_latest_l1_block() do
      {:ok, block_number} ->
        {:ok, new_state} = perform_l1_sync(state, block_number)
        Process.send_after(self(), :sync_l1, 12_000)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("L1 sync failed: #{inspect(reason)}")
        Process.send_after(self(), :sync_l1, 12_000)
        {:noreply, state}
    end
  end

  # Private Functions

  defp via_tuple(rollup_id) do
    {:via, Registry, {ExWire.Layer2.Registry, rollup_id}}
  end

  defp default_config(:optimistic) do
    %{
      # 7 days in seconds
      challenge_period: 7 * 24 * 60 * 60,
      # 24 hours
      fraud_proof_window: 24 * 60 * 60,
      max_batch_size: 1000,
      confirmation_depth: 12
    }
  end

  defp default_config(:zk) do
    %{
      proof_system: :groth16,
      verification_gas_limit: 500_000,
      max_batch_size: 500,
      aggregation_threshold: 10
    }
  end

  defp default_config(_), do: %{}

  defp process_batch(batch, state) do
    batch_number = state.current_batch + 1

    # Validate batch
    with :ok <- validate_batch(batch, state),
         # Compute new state root
         {:ok, new_state_root} <- StateCommitment.compute_root(batch, state.state_root),
         # Store batch
         batch_data <- %{
           number: batch_number,
           transactions: batch.transactions,
           state_root: new_state_root,
           previous_root: state.state_root,
           timestamp: DateTime.utc_now(),
           verified: false
         } do
      new_batches = Map.put(state.batches, batch_number, batch_data)

      new_state = %{
        state
        | current_batch: batch_number,
          state_root: new_state_root,
          batches: new_batches
      }

      Logger.info("Processed batch ##{batch_number} for rollup #{state.id}")

      {:ok, new_state, batch_number}
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_batch(batch, state) do
    cond do
      length(batch.transactions) > state.config[:max_batch_size] ->
        {:error, :batch_too_large}

      not valid_transactions?(batch.transactions) ->
        {:error, :invalid_transactions}

      true ->
        :ok
    end
  end

  defp valid_transactions?(transactions) do
    Enum.all?(transactions, fn tx ->
      # Basic transaction validation
      is_map(tx) and Map.has_key?(tx, :from) and Map.has_key?(tx, :to)
    end)
  end

  defp verify_batch_proof(batch, proof, :optimistic) do
    # For optimistic rollups, verify fraud proofs
    ProofVerifier.verify_fraud_proof(batch, proof)
  end

  defp verify_batch_proof(batch, proof, :zk) do
    # For ZK rollups, verify validity proofs
    ProofVerifier.verify_validity_proof(batch, proof)
  end

  defp perform_l1_sync(state, l1_block_number) do
    # Sync rollup state with L1
    Logger.debug("Syncing rollup #{state.id} with L1 block #{l1_block_number}")

    # Fetch latest L2 output from oracle if configured
    with {:ok, oracle_address} <- Map.fetch(state.config, :l2_output_oracle),
         {:ok, latest_index} <-
           ExWire.Layer2.L1ContractInterface.get_latest_output_index(oracle_address),
         {:ok, output} <-
           ExWire.Layer2.L1ContractInterface.get_l2_output(oracle_address, latest_index) do
      # Update state with L1-confirmed output
      new_state = %{
        state
        | confirmed_root: output.output_root,
          confirmed_l1_block: l1_block_number
      }

      Logger.info("Synced rollup #{state.id} with L1 block #{l1_block_number}")
      {:ok, new_state}
    else
      _ ->
        # No oracle configured or sync failed - continue with current state
        {:ok, state}
    end
  end

  defp get_latest_l1_block() do
    # Get latest L1 block from Web3 client
    case ExWire.Layer2.Web3Client.get_block_number() do
      {:ok, block_number} ->
        {:ok, block_number}

      {:error, reason} ->
        Logger.warning("Failed to get L1 block number: #{inspect(reason)}")
        # Fallback to a default for testing
        {:ok, 0}
    end
  end
end
