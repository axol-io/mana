defmodule Common.Production.TransactionPriorityQueue do
  @moduledoc """
  Priority queue implementation for transaction pool.

  Maintains transactions ordered by:
  1. Gas price (higher first)
  2. Nonce (lower first for same sender)
  3. Arrival time (earlier first as tiebreaker)

  Uses a heap-based implementation for O(log n) insertion/removal.
  """

  defstruct heap: :gb_trees.empty(),
            size: 0,
            max_size: 10_000,
            total_gas: 0,
            # ~1 block worth of gas
            max_total_gas: 30_000_000

  @type t :: %__MODULE__{
          heap: :gb_trees.tree(),
          size: non_neg_integer(),
          max_size: non_neg_integer(),
          total_gas: non_neg_integer(),
          max_total_gas: non_neg_integer()
        }

  @type transaction :: map()
  @type priority_key :: {non_neg_integer(), binary(), non_neg_integer(), integer()}

  @doc """
  Creates a new priority queue with optional configuration.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_size: Keyword.get(opts, :max_size, 10_000),
      max_total_gas: Keyword.get(opts, :max_total_gas, 30_000_000)
    }
  end

  @doc """
  Adds a transaction to the priority queue.

  Returns {:ok, queue} if successful, or {:error, _reason} if the queue is full
  or the transaction would exceed gas limits.
  """
  @spec add(t(), transaction()) :: {:ok, t()} | {:error, atom()}
  def add(%__MODULE__{size: size, max_size: max_size} = _queue, _transaction)
      when size >= max_size do
    {:error, :queue_full}
  end

  def add(%__MODULE__{} = queue, transaction) do
    gas_limit = Map.get(transaction, :gas_limit, 21_000)
    new_total_gas = queue.total_gas + gas_limit

    if new_total_gas > queue.max_total_gas do
      # Try to evict lower priority transactions
      case make_room_for(queue, gas_limit) do
        {:ok, queue} -> do_add(queue, transaction)
        {:error, _} = error -> error
      end
    else
      do_add(queue, transaction)
    end
  end

  @doc """
  Removes and returns the highest priority transaction.
  """
  @spec pop(t()) :: {transaction() | nil, t()}
  def pop(%__MODULE__{size: 0} = queue), do: {nil, queue}

  def pop(%__MODULE__{heap: heap} = queue) do
    case :gb_trees.is_empty(heap) do
      true ->
        {nil, queue}

      false ->
        {_key, transaction, new_heap} = :gb_trees.take_largest(heap)
        gas_limit = Map.get(transaction, :gas_limit, 21_000)

        new_queue = %{
          queue
          | heap: new_heap,
            size: queue.size - 1,
            total_gas: max(0, queue.total_gas - gas_limit)
        }

        {transaction, new_queue}
    end
  end

  @doc """
  Returns the highest priority transaction without removing it.
  """
  @spec peek(t()) :: transaction() | nil
  def peek(%__MODULE__{heap: heap}) do
    case :gb_trees.is_empty(heap) do
      true ->
        nil

      false ->
        {_key, transaction} = :gb_trees.largest(heap)
        transaction
    end
  end

  @doc """
  Returns all transactions in priority order.
  """
  @spec to_list(t(), non_neg_integer() | nil) :: [transaction()]
  def to_list(%__MODULE__{heap: heap}, limit \\ nil) do
    transactions = :gb_trees.values(heap) |> Enum.reverse()

    case limit do
      nil -> transactions
      n when is_integer(n) -> Enum.take(transactions, n)
    end
  end

  @doc """
  Removes a specific transaction by hash.
  """
  @spec remove(t(), binary()) :: t()
  def remove(%__MODULE__{heap: heap} = queue, transaction_hash) do
    # Find and remove the transaction
    # This is O(n) but necessary for specific removal
    new_heap =
      :gb_trees.from_orddict(
        :gb_trees.to_list(heap)
        |> Enum.reject(fn {_key, tx} ->
          Map.get(tx, :hash) == transaction_hash
        end)
      )

    removed_gas = calculate_removed_gas(heap, new_heap)
    new_size = :gb_trees.size(new_heap)

    %{queue | heap: new_heap, size: new_size, total_gas: max(0, queue.total_gas - removed_gas)}
  end

  @doc """
  Removes all transactions from a specific sender.
  """
  @spec remove_by_sender(t(), binary()) :: t()
  def remove_by_sender(%__MODULE__{heap: heap} = queue, sender_address) do
    new_heap =
      :gb_trees.from_orddict(
        :gb_trees.to_list(heap)
        |> Enum.reject(fn {_key, tx} ->
          Map.get(tx, :from) == sender_address
        end)
      )

    removed_gas = calculate_removed_gas(heap, new_heap)
    new_size = :gb_trees.size(new_heap)

    %{queue | heap: new_heap, size: new_size, total_gas: max(0, queue.total_gas - removed_gas)}
  end

  @doc """
  Returns statistics about the queue.
  """
  @spec stats(t()) :: map()
  def stats(%__MODULE__{} = queue) do
    %{
      size: queue.size,
      max_size: queue.max_size,
      total_gas: queue.total_gas,
      max_total_gas: queue.max_total_gas,
      utilization: queue.size / queue.max_size * 100,
      gas_utilization: queue.total_gas / queue.max_total_gas * 100
    }
  end

  @doc """
  Checks if the queue is empty.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{size: 0}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Checks if the queue is full.
  """
  @spec full?(t()) :: boolean()
  def full?(%__MODULE__{size: size, max_size: max_size}), do: size >= max_size

  # Private functions

  defp do_add(%__MODULE__{heap: heap} = queue, transaction) do
    key = make_priority_key(transaction)

    # Add transaction with its priority key
    new_heap = :gb_trees.insert(key, transaction, heap)
    gas_limit = Map.get(transaction, :gas_limit, 21_000)

    new_queue = %{
      queue
      | heap: new_heap,
        size: queue.size + 1,
        total_gas: queue.total_gas + gas_limit
    }

    {:ok, new_queue}
  end

  defp make_priority_key(transaction) do
    # Priority key: {gas_price, sender, nonce, -timestamp}
    # Higher gas price = higher priority
    # Same sender: lower nonce = higher priority
    # Earlier timestamp = higher priority (negative to reverse order)
    gas_price = Map.get(transaction, :gas_price, 0)
    sender = Map.get(transaction, :from, <<>>)
    nonce = Map.get(transaction, :nonce, 0)
    timestamp = Map.get(transaction, :timestamp, System.system_time(:millisecond))

    # Negate gas_price to get descending order (higher price first)
    # Negate timestamp to prefer earlier transactions
    {-gas_price, sender, nonce, -timestamp}
  end

  defp make_room_for(%__MODULE__{} = queue, required_gas) do
    # Evict lowest priority transactions until we have room
    evict_until_space(queue, required_gas, [])
  end

  defp evict_until_space(
         %__MODULE__{total_gas: total, max_total_gas: max} = queue,
         required,
         _evicted
       )
       when total + required <= max do
    # We have enough space now
    {:ok, queue}
  end

  defp evict_until_space(%__MODULE__{heap: heap} = queue, required, evicted) do
    case :gb_trees.is_empty(heap) do
      true ->
        # Can't evict anymore
        {:error, :cannot_make_room}

      false ->
        # Remove lowest priority transaction
        {_key, tx, new_heap} = :gb_trees.take_smallest(heap)
        gas_limit = Map.get(tx, :gas_limit, 21_000)

        new_queue = %{
          queue
          | heap: new_heap,
            size: queue.size - 1,
            total_gas: max(0, queue.total_gas - gas_limit)
        }

        evict_until_space(new_queue, required, [tx | evicted])
    end
  end

  defp calculate_removed_gas(old_heap, new_heap) do
    old_gas =
      :gb_trees.values(old_heap)
      |> Enum.map(&Map.get(&1, :gas_limit, 21_000))
      |> Enum.sum()

    new_gas =
      :gb_trees.values(new_heap)
      |> Enum.map(&Map.get(&1, :gas_limit, 21_000))
      |> Enum.sum()

    old_gas - new_gas
  end

  @doc """
  Returns a list of transactions with optional optimization.

  The third parameter can be used for additional filtering or optimization hints.
  """
  @spec to_list_optimized(t(), non_neg_integer(), keyword()) :: list(transaction())
  def to_list_optimized(%__MODULE__{} = queue, limit, _opts \\ []) do
    to_list(queue, limit)
  end

  @doc """
  Optimizes the internal structure of the queue.

  This can be used to rebalance the heap or clean up internal state.
  Returns the optimized queue.
  """
  @spec optimize(t()) :: t()
  def optimize(%__MODULE__{heap: heap} = queue) do
    # Rebuild the heap to ensure optimal structure
    transactions = :gb_trees.values(heap)

    new_heap =
      Enum.reduce(transactions, :gb_trees.empty(), fn tx, acc ->
        key = make_priority_key(tx)
        :gb_trees.insert(key, tx, acc)
      end)

    %{queue | heap: new_heap}
  end
end
