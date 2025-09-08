defmodule ExWire.Layer2.OptimisticRollup do
  @moduledoc """
  Optimistic Rollup implementation for Layer 2 scaling.
  Handles fraud proofs and optimistic state transitions.
  """

  use GenServer
  require Logger

  defstruct [
    :chain_id,
    :sequencer_url,
    :fraud_proof_window,
    :state_root,
    :pending_batches,
    :finalized_batches,
    :challenges
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      chain_id: Keyword.get(opts, :chain_id),
      sequencer_url: Keyword.get(opts, :sequencer_url),
      fraud_proof_window: Keyword.get(opts, :fraud_proof_window, 7 * 24 * 60 * 60),
      state_root: Keyword.get(opts, :state_root, <<0::256>>),
      pending_batches: [],
      finalized_batches: [],
      challenges: %{}
    }

    {:ok, _state}
  end

  @doc """
  Submits a transaction to the optimistic rollup.
  """
  def submit_transaction(transaction) do
    GenServer.call(__MODULE__, {:submit_transaction, transaction})
  end

  @doc """
  Submits a fraud proof challenging a state transition.
  """
  def submit_fraud_proof(batch_id, proof) do
    GenServer.call(__MODULE__, {:submit_fraud_proof, batch_id, proof})
  end

  @doc """
  Gets the current state root.
  """
  def get_state_root do
    GenServer.call(__MODULE__, :get_state_root)
  end

  @doc """
  Processes a batch of transactions optimistically.
  """
  def process_batch(transactions) do
    GenServer.call(__MODULE__, {:process_batch, transactions})
  end

  @doc """
  Finalizes a batch after the fraud proof window.
  """
  def finalize_batch(batch_id) do
    GenServer.call(__MODULE__, {:finalize_batch, batch_id})
  end

  @impl true
  def handle_call({:submit_transaction, transaction}, _from, _state) do
    # TODO: Implement transaction submission
    {:reply, {:ok, transaction}, state}
  end

  @impl true
  def handle_call({:submit_fraud_proof, batch_id, proof}, _from, _state) do
    # TODO: Implement fraud proof verification
    challenges = Map.put(state.challenges, batch_id, proof)
    {:reply, {:ok, batch_id}, %{state | challenges: challenges}}
  end

  @impl true
  def handle_call(:get_state_root, _from, _state) do
    {:reply, state.state_root, state}
  end

  @impl true
  def handle_call({:process_batch, transactions}, _from, _state) do
    batch_id = generate_batch_id()
    batch = %{
      id: batch_id,
      transactions: transactions,
      timestamp: System.system_time(:second)
    }
    
    pending_batches = [batch | state.pending_batches]
    {:reply, {:ok, batch_id}, %{state | pending_batches: pending_batches}}
  end

  @impl true
  def handle_call({:finalize_batch, batch_id}, _from, _state) do
    case find_batch(state.pending_batches, batch_id) do
      nil ->
        {:reply, {:error, :batch_not_found}, state}
      
      batch ->
        if can_finalize?(batch, state.fraud_proof_window) do
          pending_batches = Enum.reject(state.pending_batches, &(&1.id == batch_id))
          finalized_batches = [batch | state.finalized_batches]
          
          new_state = %{state | 
            pending_batches: pending_batches,
            finalized_batches: finalized_batches
          }
          
          {:reply, {:ok, batch_id}, new_state}
        else
          {:reply, {:error, :window_not_elapsed}, state}
        end
    end
  end

  defp generate_batch_id do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  defp find_batch(batches, batch_id) do
    Enum.find(batches, &(&1.id == batch_id))
  end

  defp can_finalize?(batch, fraud_proof_window) do
    current_time = System.system_time(:second)
    current_time - batch.timestamp >= fraud_proof_window
  end
end