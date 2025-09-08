defmodule Blockchain.BasicTransactionPool do
  @moduledoc """
  Basic transaction pool implementation using standard GenServer patterns.
  Manages pending transactions before they are included in blocks.
  """

  use GenServer
  require Logger

  # State structure
  defstruct [
    :transactions,
    :by_address,
    :stats,
    :config
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def add_transaction(raw_transaction) when is_binary(raw_transaction) do
    GenServer.call(__MODULE__, {:add_transaction, raw_transaction})
  end

  def get_transaction(tx_hash) when is_binary(tx_hash) do
    GenServer.call(__MODULE__, {:get_transaction, tx_hash})
  end

  def get_pending_transactions(limit \\ nil) do
    GenServer.call(__MODULE__, {:get_pending, limit})
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  def clear_pool do
    GenServer.call(__MODULE__, :clear_pool)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    state = %__MODULE__{
      transactions: %{},
      by_address: %{},
      stats: %{
        total_added: 0,
        total_removed: 0,
        total_rejected: 0,
        pool_size: 0
      },
      config: Keyword.get(opts, :config, %{})
    }

    emit_telemetry(:pool_started, %{})
    {:ok, _state}
  end

  @impl true
  def handle_call({:add_transaction, raw_transaction}, _from, _state) do
    case validate_transaction(raw_transaction) do
      {:ok, transaction} ->
        tx_hash = compute_hash(raw_transaction)

        if Map.has_key?(state.transactions, tx_hash) do
          new_stats = Map.put(state.stats, :total_rejected, state.stats.total_rejected + 1)
          {:reply, {:error, :already_exists}, %{state | stats: new_stats}}
        else
          state = add_transaction_to_state(state, tx_hash, transaction, raw_transaction)
          emit_telemetry(:transaction_added, %{tx_hash: tx_hash})
          {:reply, {:ok, tx_hash}, state}
        end

      {:error, _reason} ->
        new_stats = Map.put(state.stats, :total_rejected, state.stats.total_rejected + 1)
        emit_telemetry(:transaction_rejected, %{reason: reason})
        {:reply, {:error, _reason}, %{state | stats: new_stats}}
    end
  end

  @impl true
  def handle_call({:get_transaction, tx_hash}, _from, _state) do
    case Map.get(state.transactions, tx_hash) do
      nil -> {:reply, {:error, :not_found}, state}
      transaction -> {:reply, {:ok, transaction}, state}
    end
  end

  @impl true
  def handle_call({:get_pending, limit}, _from, _state) do
    transactions =
      state.transactions
      |> Map.values()
      |> Enum.sort_by(& &1.gas_price, :desc)
      |> maybe_limit(limit)

    {:reply, transactions, state}
  end

  @impl true
  def handle_call(:get_stats, _from, _state) do
    stats = Map.put(state.stats, :pool_size, map_size(state.transactions))
    {:reply, stats, state}
  end

  @impl true
  def handle_call(:clear_pool, _from, _state) do
    cleared_count = map_size(state.transactions)

    new_stats = Map.put(state.stats, :total_removed, state.stats.total_removed + cleared_count)

    state = %{state | transactions: %{}, by_address: %{}, stats: new_stats}

    emit_telemetry(:pool_cleared, %{cleared_count: cleared_count})
    {:reply, :ok, state}
  end

  # Private helpers

  defp validate_transaction(raw_transaction) do
    try do
      # Simple validation - in production this would be more thorough
      if byte_size(raw_transaction) > 0 and byte_size(raw_transaction) < 128 * 1024 do
        transaction = %{
          data: raw_transaction,
          # Default gas price
          gas_price: 2_000_000_000,
          # Placeholder
          from: <<1::160>>,
          size: byte_size(raw_transaction)
        }

        {:ok, transaction}
      else
        {:error, :invalid_size}
      end
    rescue
      _ -> {:error, :invalid_format}
    end
  end

  defp compute_hash(data) do
    :crypto.hash(:sha256, data)
  end

  defp add_transaction_to_state(_state, tx_hash, transaction, _raw_transaction) do
    from_address = transaction.from

    # Update transactions map
    new_transactions = Map.put(state.transactions, tx_hash, transaction)

    # Update by_address map
    existing_txs = Map.get(state.by_address, from_address, [])
    new_by_address = Map.put(state.by_address, from_address, [tx_hash | existing_txs])

    # Update stats
    new_stats = Map.put(state.stats, :total_added, state.stats.total_added + 1)

    %{state | transactions: new_transactions, by_address: new_by_address, stats: new_stats}
  end

  defp maybe_limit(list, nil), do: list
  defp maybe_limit(list, limit) when is_integer(limit), do: Enum.take(list, limit)

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:blockchain, :simple_pool_v2, event],
      %{count: 1, timestamp: :os.system_time(:millisecond)},
      metadata
    )
  end
end
