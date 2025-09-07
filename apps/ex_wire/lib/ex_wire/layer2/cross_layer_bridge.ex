defmodule ExWire.Layer2.CrossLayerBridge do
  @moduledoc """
  Cross-layer bridge for communication between L1 and L2.
  Handles deposits, withdrawals, and message passing.
  """

  use GenServer
  require Logger

  defstruct [
    :l1_contract,
    :l2_contract,
    :pending_deposits,
    :pending_withdrawals,
    :finalized_deposits,
    :finalized_withdrawals
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      l1_contract: Keyword.get(opts, :l1_contract),
      l2_contract: Keyword.get(opts, :l2_contract),
      pending_deposits: [],
      pending_withdrawals: [],
      finalized_deposits: [],
      finalized_withdrawals: []
    }

    {:ok, _state}
  end

  @doc """
  Initiates a deposit from L1 to L2.
  """
  def deposit(from, to, amount, data \\ <<>>) do
    GenServer.call(__MODULE__, {:deposit, from, to, amount, data})
  end

  @doc """
  Initiates a withdrawal from L2 to L1.
  """
  def withdraw(from, to, amount, data \\ <<>>) do
    GenServer.call(__MODULE__, {:withdraw, from, to, amount, data})
  end

  @doc """
  Relays a message from L1 to L2.
  """
  def relay_message(message) do
    GenServer.call(__MODULE__, {:relay_message, message})
  end

  @doc """
  Finalizes a pending deposit.
  """
  def finalize_deposit(deposit_id) do
    GenServer.call(__MODULE__, {:finalize_deposit, deposit_id})
  end

  @doc """
  Finalizes a pending withdrawal.
  """
  def finalize_withdrawal(withdrawal_id) do
    GenServer.call(__MODULE__, {:finalize_withdrawal, withdrawal_id})
  end

  @impl true
  def handle_call({:deposit, from, to, amount, data}, _from, _state) do
    deposit = %{
      id: generate_id(),
      from: from,
      to: to,
      amount: amount,
      data: data,
      timestamp: System.system_time(:second)
    }
    
    pending_deposits = [deposit | state.pending_deposits]
    {:reply, {:ok, deposit.id}, %{state | pending_deposits: pending_deposits}}
  end

  @impl true
  def handle_call({:withdraw, from, to, amount, data}, _from, _state) do
    withdrawal = %{
      id: generate_id(),
      from: from,
      to: to,
      amount: amount,
      data: data,
      timestamp: System.system_time(:second)
    }
    
    pending_withdrawals = [withdrawal | state.pending_withdrawals]
    {:reply, {:ok, withdrawal.id}, %{state | pending_withdrawals: pending_withdrawals}}
  end

  @impl true
  def handle_call({:relay_message, message}, _from, _state) do
    # TODO: Implement message relaying logic
    {:reply, {:ok, message}, state}
  end

  @impl true
  def handle_call({:finalize_deposit, deposit_id}, _from, _state) do
    case find_pending(state.pending_deposits, deposit_id) do
      nil ->
        {:reply, {:error, :deposit_not_found}, state}
      
      deposit ->
        pending_deposits = Enum.reject(state.pending_deposits, &(&1.id == deposit_id))
        finalized_deposits = [deposit | state.finalized_deposits]
        
        new_state = %{state |
          pending_deposits: pending_deposits,
          finalized_deposits: finalized_deposits
        }
        
        {:reply, {:ok, deposit_id}, new_state}
    end
  end

  @impl true
  def handle_call({:finalize_withdrawal, withdrawal_id}, _from, _state) do
    case find_pending(state.pending_withdrawals, withdrawal_id) do
      nil ->
        {:reply, {:error, :withdrawal_not_found}, state}
      
      withdrawal ->
        pending_withdrawals = Enum.reject(state.pending_withdrawals, &(&1.id == withdrawal_id))
        finalized_withdrawals = [withdrawal | state.finalized_withdrawals]
        
        new_state = %{state |
          pending_withdrawals: pending_withdrawals,
          finalized_withdrawals: finalized_withdrawals
        }
        
        {:reply, {:ok, withdrawal_id}, new_state}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp find_pending(list, id) do
    Enum.find(list, &(&1.id == id))
  end
end