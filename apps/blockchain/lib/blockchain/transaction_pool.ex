defmodule Blockchain.TransactionPool do
  @moduledoc """
  GenServer that manages the transaction pool (mempool) for pending transactions.

  This module handles:
  - Adding new transactions to the pool
  - Validating transactions before acceptance
  - Retrieving pending transactions for block creation
  - Removing mined transactions from the pool
  - Broadcasting transactions to peers
  """

  use GenServer
  require Logger

  alias ExthCrypto.Hash.Keccak

  @max_pool_size 5000
  # 128 KB
  @max_transaction_size 128 * 1024
  # 1 Gwei minimum
  @min_gas_price 1_000_000_000

  # Client API

  @doc """
  Starts the TransactionPool GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a signed transaction to the pool.

  ## Parameters
  - raw_transaction: RLP-encoded signed transaction as binary or hex string

  ## Returns
  - {:ok, transaction_hash} on success
  - {:error, reason} on failure
  """
  def add_transaction(raw_transaction) when is_binary(raw_transaction) do
    GenServer.call(__MODULE__, {:add_transaction, raw_transaction})
  end

  @doc """
  Creates and adds a new transaction to the pool.

  ## Parameters
  - transaction_params: Map with from, to, value, data, gas, gasPrice, nonce

  ## Returns
  - {:ok, transaction_hash} on success
  - {:error, reason} on failure
  """
  def send_transaction(transaction_params) do
    GenServer.call(__MODULE__, {:send_transaction, transaction_params})
  end

  @doc """
  Gets all pending transactions from the pool.

  ## Returns
  List of pending transactions sorted by gas price (highest first)
  """
  def get_pending_transactions(limit \\ nil) do
    GenServer.call(__MODULE__, {:get_pending, limit})
  end

  @doc """
  Gets a specific pending transaction by hash.
  """
  def get_transaction(transaction_hash) do
    GenServer.call(__MODULE__, {:get_transaction, transaction_hash})
  end

  @doc """
  Removes transactions that were included in a block.
  """
  def remove_transactions(transaction_hashes) when is_list(transaction_hashes) do
    GenServer.cast(__MODULE__, {:remove_transactions, transaction_hashes})
  end

  @doc """
  Gets the next nonce for an address based on pending transactions.
  """
  def get_next_nonce(address) do
    GenServer.call(__MODULE__, {:get_next_nonce, address})
  end

  @doc """
  Gets statistics about the transaction pool.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Clears all transactions from the pool.
  """
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Initialize state
    state = %{
      # Map of transaction_hash => transaction
      transactions: %{},
      # Map of address => [transaction_hashes] for nonce tracking
      by_address: %{},
      # Priority queue of transactions sorted by gas price
      by_gas_price: [],
      # Statistics
      stats: %{
        total_added: 0,
        total_removed: 0,
        total_rejected: 0,
        last_cleared: System.system_time(:second)
      }
    }

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_call({:add_transaction, raw_transaction}, _from, state) do
    case decode_and_validate_transaction(raw_transaction, state) do
      {:ok, transaction} ->
        transaction_hash = calculate_transaction_hash(transaction)

        # Check if transaction already exists
        if Map.has_key?(state.transactions, transaction_hash) do
          {:reply, {:ok, encode_hash(transaction_hash)}, state}
        else
          new_state = add_transaction_to_pool(state, transaction, transaction_hash)

          # Notify subscribers about new pending transaction
          notify_new_pending_transaction(transaction, transaction_hash)

          Logger.info("Added transaction #{encode_hash(transaction_hash)} to pool")

          {:reply, {:ok, encode_hash(transaction_hash)}, new_state}
        end

      {:error, reason} = error ->
        new_state = update_in(state, [:stats, :total_rejected], &(&1 + 1))
        Logger.warning("Rejected transaction: #{inspect(reason)}")
        {:reply, error, new_state}
    end
  end

  @impl true
  def handle_call({:send_transaction, _params}, _from, state) do
    # This would require wallet functionality to sign transactions
    # For now, return not supported
    {:reply, {:error, "Wallet functionality not implemented"}, state}
  end

  @impl true
  def handle_call({:get_pending, limit}, _from, state) do
    transactions = get_sorted_transactions(state, limit)
    {:reply, transactions, state}
  end

  @impl true
  def handle_call({:get_transaction, transaction_hash}, _from, state) do
    transaction = Map.get(state.transactions, transaction_hash)
    {:reply, transaction, state}
  end

  @impl true
  def handle_call({:get_next_nonce, address}, _from, state) do
    # Get the highest nonce from pending transactions for this address
    transaction_hashes = Map.get(state.by_address, address, [])

    highest_nonce =
      transaction_hashes
      |> Enum.map(fn hash ->
        case Map.get(state.transactions, hash) do
          nil -> -1
          tx -> tx.nonce
        end
      end)
      |> Enum.max(fn -> -1 end)

    # Next nonce is highest + 1, or fetch from blockchain if no pending
    next_nonce =
      if highest_nonce >= 0 do
        highest_nonce + 1
      else
        # Would need to fetch from blockchain state
        # For now return 0
        0
      end

    {:reply, next_nonce, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        current_size: map_size(state.transactions),
        unique_addresses: map_size(state.by_address)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:remove_transactions, transaction_hashes}, state) do
    new_state =
      Enum.reduce(transaction_hashes, state, fn hash, acc ->
        remove_transaction_from_pool(acc, hash)
      end)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:clear, state) do
    new_state = %{
      state
      | transactions: %{},
        by_address: %{},
        by_gas_price: [],
        stats: Map.put(state.stats, :last_cleared, System.system_time(:second))
    }

    Logger.info("Cleared transaction pool")

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Remove old transactions (e.g., older than 1 hour)
    current_time = System.system_time(:second)
    # 1 hour
    cutoff_time = current_time - 3600

    {old_txs, _current_txs} =
      Enum.split_with(state.transactions, fn {_hash, tx} ->
        Map.get(tx, :timestamp, current_time) < cutoff_time
      end)

    old_hashes = Enum.map(old_txs, fn {hash, _tx} -> hash end)

    new_state =
      Enum.reduce(old_hashes, state, fn hash, acc ->
        remove_transaction_from_pool(acc, hash)
      end)

    if length(old_hashes) > 0 do
      Logger.info("Cleaned up #{length(old_hashes)} old transactions from pool")
    end

    # Check pool size limit
    final_state =
      if map_size(new_state.transactions) > @max_pool_size do
        enforce_size_limit(new_state)
      else
        new_state
      end

    # Schedule next cleanup
    schedule_cleanup()

    {:noreply, final_state}
  end

  # Private Functions

  defp decode_and_validate_transaction(raw_transaction, state) do
    with {:ok, decoded} <- decode_raw_transaction(raw_transaction),
         {:ok, transaction} <- validate_transaction_format(decoded),
         :ok <- validate_transaction_signature(transaction),
         :ok <- validate_transaction_gas(transaction),
         :ok <- validate_transaction_size(raw_transaction),
         :ok <- validate_pool_capacity(state) do
      {:ok, transaction}
    end
  end

  defp decode_raw_transaction(raw) when is_binary(raw) do
    try do
      # Handle hex string or binary
      binary =
        if String.starts_with?(raw, "0x") do
          raw
          |> String.slice(2..-1//1)
          |> Base.decode16!(case: :mixed)
        else
          raw
        end

      # Decode RLP
      case ExRLP.decode(binary) do
        [nonce, gas_price, gas_limit, to, value, data, v, r, s] ->
          {:ok,
           %{
             nonce: :binary.decode_unsigned(nonce),
             gas_price: :binary.decode_unsigned(gas_price),
             gas_limit: :binary.decode_unsigned(gas_limit),
             to: if(to == <<>>, do: nil, else: to),
             value: :binary.decode_unsigned(value),
             data: data,
             v: :binary.decode_unsigned(v),
             r: :binary.decode_unsigned(r),
             s: :binary.decode_unsigned(s),
             timestamp: System.system_time(:second)
           }}

        _ ->
          {:error, "Invalid RLP structure"}
      end
    rescue
      e -> {:error, "Failed to decode transaction: #{inspect(e)}"}
    end
  end

  defp validate_transaction_format(tx) do
    # Basic format validation
    cond do
      tx.gas_price < @min_gas_price ->
        {:error, "Gas price too low"}

      tx.gas_limit < 21000 ->
        {:error, "Gas limit too low"}

      tx.gas_limit > 8_000_000 ->
        {:error, "Gas limit too high"}

      tx.nonce < 0 ->
        {:error, "Invalid nonce"}

      true ->
        {:ok, tx}
    end
  end

  defp validate_transaction_signature(transaction) do
    # Would need to implement full signature validation
    # For now, just check that v, r, s are present
    if transaction.v > 0 && transaction.r > 0 && transaction.s > 0 do
      :ok
    else
      {:error, "Invalid signature"}
    end
  end

  defp validate_transaction_gas(transaction) do
    # Calculate intrinsic gas
    intrinsic_gas = calculate_intrinsic_gas(transaction)

    if transaction.gas_limit >= intrinsic_gas do
      :ok
    else
      {:error, "Insufficient gas limit"}
    end
  end

  defp calculate_intrinsic_gas(transaction) do
    # Base transaction cost
    base_gas = 21000

    # Add gas for data
    data_gas =
      if transaction.data do
        # Simplified: 16 gas per byte
        byte_size(transaction.data) * 16
      else
        0
      end

    base_gas + data_gas
  end

  defp validate_transaction_size(raw_transaction) do
    size =
      if is_binary(raw_transaction) do
        byte_size(raw_transaction)
      else
        0
      end

    if size <= @max_transaction_size do
      :ok
    else
      {:error, "Transaction too large"}
    end
  end

  defp validate_pool_capacity(state) do
    if map_size(state.transactions) < @max_pool_size do
      :ok
    else
      {:error, "Transaction pool is full"}
    end
  end

  defp calculate_transaction_hash(transaction) do
    # Calculate transaction hash
    # Simplified version - would need full RLP encoding
    transaction
    |> Map.take([:nonce, :gas_price, :gas_limit, :to, :value, :data])
    |> :erlang.term_to_binary()
    |> Keccak.kec()
  end

  defp add_transaction_to_pool(state, transaction, hash) do
    # Derive sender address (simplified - would need proper recovery)
    sender = derive_sender_address(transaction)

    state
    |> put_in([:transactions, hash], Map.put(transaction, :hash, hash))
    |> update_in([:by_address, sender], fn
      nil -> [hash]
      hashes -> [hash | hashes]
    end)
    |> update_in([:by_gas_price], fn queue ->
      insert_by_gas_price(queue, {transaction.gas_price, hash})
    end)
    |> update_in([:stats, :total_added], &(&1 + 1))
  end

  defp remove_transaction_from_pool(state, hash) do
    case Map.get(state.transactions, hash) do
      nil ->
        state

      transaction ->
        sender = derive_sender_address(transaction)

        state
        |> update_in([:transactions], &Map.delete(&1, hash))
        |> update_in([:by_address, sender], fn
          nil -> nil
          hashes -> Enum.reject(hashes, &(&1 == hash))
        end)
        |> update_in([:by_gas_price], fn queue ->
          Enum.reject(queue, fn {_price, h} -> h == hash end)
        end)
        |> update_in([:stats, :total_removed], &(&1 + 1))
    end
  end

  defp derive_sender_address(_transaction) do
    # Simplified - would need proper ECDSA recovery
    # For now return a dummy address
    <<0::160>>
  end

  defp insert_by_gas_price([], item), do: [item]

  defp insert_by_gas_price([{price, _} = head | tail], {new_price, _} = item) do
    if new_price > price do
      [item, head | tail]
    else
      [head | insert_by_gas_price(tail, item)]
    end
  end

  defp get_sorted_transactions(state, limit) do
    transactions =
      state.by_gas_price
      |> Enum.map(fn {_price, hash} ->
        Map.get(state.transactions, hash)
      end)
      |> Enum.filter(&(&1 != nil))

    case limit do
      nil -> transactions
      n -> Enum.take(transactions, n)
    end
  end

  defp enforce_size_limit(state) do
    # Remove lowest gas price transactions
    to_remove = map_size(state.transactions) - @max_pool_size

    if to_remove > 0 do
      hashes_to_remove =
        state.by_gas_price
        |> Enum.reverse()
        |> Enum.take(to_remove)
        |> Enum.map(fn {_price, hash} -> hash end)

      Enum.reduce(hashes_to_remove, state, fn hash, acc ->
        remove_transaction_from_pool(acc, hash)
      end)
    else
      state
    end
  end

  defp notify_new_pending_transaction(transaction, hash) do
    # Notify SubscriptionManager about new pending transaction
    if Process.whereis(JSONRPC2.SubscriptionManager) do
      JSONRPC2.SubscriptionManager.notify_new_pending_transaction(%{
        hash: hash,
        from: derive_sender_address(transaction),
        to: transaction.to,
        value: transaction.value,
        gas: transaction.gas_limit,
        gas_price: transaction.gas_price,
        data: transaction.data,
        nonce: transaction.nonce
      })
    end
  end

  defp encode_hash(hash) when is_binary(hash) do
    "0x" <> Base.encode16(hash, case: :lower)
  end

  defp schedule_cleanup do
    # Schedule cleanup every 5 minutes
    Process.send_after(self(), :cleanup, 5 * 60_000)
  end
end
