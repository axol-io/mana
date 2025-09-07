defmodule ExWire.TxPool do
  @moduledoc """
  Transaction pool interface for ExWire.

  Provides access to pending transactions and pool statistics.
  """

  alias Blockchain.TransactionPool

  @doc """
  Get the count of pending transactions.
  """
  def get_pending_count do
    case Process.whereis(TransactionPool) do
      nil ->
        {:error, :pool_not_started}

      pid ->
        try do
          state = :sys.get_state(pid)
          count = map_size(state.transactions)
          {:ok, count}
        rescue
          _ -> {:error, :unavailable}
        end
    end
  end

  @doc """
  Get all pending transactions.
  """
  def get_pending_transactions do
    case Process.whereis(TransactionPool) do
      nil ->
        []

      pid ->
        try do
          GenServer.call(pid, :get_pending_transactions, 5000)
        rescue
          _ -> []
        end
    end
  end

  @doc """
  Add a transaction to the pool.
  """
  def add_transaction(transaction) do
    case Process.whereis(TransactionPool) do
      nil -> {:error, :pool_not_started}
      pid -> GenServer.call(pid, {:add_transaction, transaction})
    end
  end

  @doc """
  Remove a transaction from the pool.
  """
  def remove_transaction(tx_hash) do
    case Process.whereis(TransactionPool) do
      nil -> {:error, :pool_not_started}
      pid -> GenServer.cast(pid, {:remove_transaction, tx_hash})
    end
  end

  @doc """
  Get pool statistics.
  """
  def get_stats do
    case get_pending_count() do
      {:ok, count} ->
        %{
          pending: count,
          queued: 0,
          executable: count
        }

      {:error, _} ->
        %{
          pending: 0,
          queued: 0,
          executable: 0
        }
    end
  end
end
