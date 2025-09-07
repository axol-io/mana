defmodule Blockchain.BlobPool do
  @moduledoc """
  Blob transaction pool for EIP-4844 blob transactions.

  This module manages a separate pool of blob transactions with special handling for:
  - Blob data storage and retrieval
  - Blob gas pricing and fee markets
  - KZG proof verification
  - Replacement by fee for blob transactions
  """

  use GenServer

  alias Blockchain.Transaction.Blob
  alias ExthCrypto.KZG

  # Pool configuration
  @max_blob_txs 1000
  # EIP-4844 limit
  @max_blobs_per_tx 6
  # EIP-4844 target * 2
  @max_blob_gas_per_block 786_432

  # State structure
  defstruct [
    # %{hash => {blob_tx, blob_data_list}}
    :blob_transactions,
    # %{sender => MapSet.new([hash])}
    :by_sender,
    # Ordered list by blob gas fee
    :by_gas_fee,
    # Current blob gas in pool
    :blob_gas_used,
    # MapSet of verified KZG proofs
    :verified_proofs,
    :config
  ]

  @type t :: %__MODULE__{
          blob_transactions: %{binary() => {Blob.t(), list()}},
          by_sender: %{binary() => MapSet.t()},
          by_gas_fee: list(),
          blob_gas_used: non_neg_integer(),
          verified_proofs: MapSet.t(),
          config: map()
        }

  # API Functions

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add a blob transaction to the pool with its blob data.
  """
  @spec add_blob_transaction(Blob.t(), list({binary(), binary(), binary()})) ::
          :ok | {:error, term()}
  def add_blob_transaction(blob_tx, blob_data_list) do
    GenServer.call(__MODULE__, {:add_blob_transaction, blob_tx, blob_data_list})
  end

  @doc """
  Get the best blob transactions for block inclusion.
  """
  @spec get_best_blob_transactions(non_neg_integer()) :: list({Blob.t(), list()})
  def get_best_blob_transactions(max_blob_gas \\ @max_blob_gas_per_block) do
    GenServer.call(__MODULE__, {:get_best_blob_transactions, max_blob_gas})
  end

  @doc """
  Remove blob transactions from the pool.
  """
  @spec remove_blob_transactions(list(binary())) :: :ok
  def remove_blob_transactions(hashes) do
    GenServer.call(__MODULE__, {:remove_blob_transactions, hashes})
  end

  @doc """
  Get pool statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Get blob data for a transaction hash.
  """
  @spec get_blob_data(binary()) :: {:ok, list()} | {:error, :not_found}
  def get_blob_data(tx_hash) do
    GenServer.call(__MODULE__, {:get_blob_data, tx_hash})
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    # Initialize KZG trusted setup
    case KZG.init_trusted_setup() do
      :ok ->
        {:ok,
         %__MODULE__{
           blob_transactions: %{},
           by_sender: %{},
           by_gas_fee: [],
           blob_gas_used: 0,
           verified_proofs: MapSet.new(),
           config: Map.new(opts)
         }}

      error ->
        {:stop, {:kzg_setup_failed, error}}
    end
  end

  @impl true
  def handle_call({:add_blob_transaction, blob_tx, blob_data_list}, _from, state) do
    case add_blob_transaction_internal(blob_tx, blob_data_list, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_best_blob_transactions, max_blob_gas}, _from, state) do
    transactions = get_best_transactions_internal(max_blob_gas, state)
    {:reply, transactions, state}
  end

  @impl true
  def handle_call({:remove_blob_transactions, hashes}, _from, state) do
    new_state = remove_transactions_internal(hashes, state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      total_transactions: map_size(state.blob_transactions),
      total_blob_gas: state.blob_gas_used,
      unique_senders: map_size(state.by_sender),
      verified_proofs: MapSet.size(state.verified_proofs)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_blob_data, tx_hash}, _from, state) do
    case Map.get(state.blob_transactions, tx_hash) do
      {_blob_tx, blob_data_list} -> {:reply, {:ok, blob_data_list}, state}
      nil -> {:reply, {:error, :not_found}, state}
    end
  end

  # Internal Functions

  defp add_blob_transaction_internal(blob_tx, blob_data_list, state) do
    with :ok <- validate_blob_transaction(blob_tx, blob_data_list),
         :ok <- check_pool_limits(blob_tx, state),
         :ok <- verify_kzg_proofs(blob_data_list, state) do
      tx_hash = Blob.hash(blob_tx)
      sender = Blob.sender(blob_tx)

      # Handle replacement by fee if transaction from same sender exists
      state = handle_replacement_by_fee(sender, blob_tx, state)

      # Add transaction to all indexes
      blob_gas = calculate_blob_gas(blob_tx)

      new_state = %{
        state
        | blob_transactions: Map.put(state.blob_transactions, tx_hash, {blob_tx, blob_data_list}),
          by_sender: update_by_sender(state.by_sender, sender, tx_hash),
          by_gas_fee: insert_by_gas_fee(state.by_gas_fee, {tx_hash, blob_tx}),
          blob_gas_used: state.blob_gas_used + blob_gas,
          verified_proofs: add_verified_proofs(state.verified_proofs, blob_data_list)
      }

      # Evict old transactions if over limit
      {:ok, maybe_evict_old_transactions(new_state)}
    end
  end

  defp validate_blob_transaction(blob_tx, blob_data_list) do
    case Blob.validate_with_kzg(blob_tx, blob_data_list) do
      :ok -> :ok
      error -> {:error, {:validation_failed, error}}
    end
  end

  defp check_pool_limits(blob_tx, state) do
    blob_count = length(blob_tx.blob_versioned_hashes)

    cond do
      map_size(state.blob_transactions) >= @max_blob_txs ->
        {:error, :pool_full}

      blob_count > @max_blobs_per_tx ->
        {:error, :too_many_blobs}

      state.blob_gas_used + calculate_blob_gas(blob_tx) > @max_blob_gas_per_block * 2 ->
        {:error, :pool_blob_gas_limit}

      true ->
        :ok
    end
  end

  defp verify_kzg_proofs(blob_data_list, state) do
    # Check if proofs are already verified (cache)
    proof_hashes =
      Enum.map(blob_data_list, fn {_blob, _commitment, proof} ->
        :crypto.hash(:sha256, proof)
      end)

    already_verified = Enum.all?(proof_hashes, &MapSet.member?(state.verified_proofs, &1))

    if already_verified do
      :ok
    else
      {blobs, commitments, proofs} = unzip_blob_data(blob_data_list)

      case Blob.verify_blob_kzg_proof_batch(blobs, commitments, proofs) do
        {:ok, true} -> :ok
        {:ok, false} -> {:error, :kzg_verification_failed}
        error -> {:error, {:kzg_error, error}}
      end
    end
  end

  defp calculate_blob_gas(blob_tx) do
    # Each blob uses 131072 gas (2^17)
    length(blob_tx.blob_versioned_hashes) * 131_072
  end

  defp handle_replacement_by_fee(sender, new_tx, state) do
    case Map.get(state.by_sender, sender) do
      nil ->
        state

      existing_hashes ->
        # Find transactions with lower gas fees and remove them
        min_fee = new_tx.max_fee_per_blob_gas

        to_remove =
          existing_hashes
          |> Enum.filter(fn hash ->
            case Map.get(state.blob_transactions, hash) do
              {existing_tx, _} -> existing_tx.max_fee_per_blob_gas < min_fee
              nil -> false
            end
          end)

        remove_transactions_internal(to_remove, state)
    end
  end

  defp update_by_sender(by_sender, sender, tx_hash) do
    Map.update(by_sender, sender, MapSet.new([tx_hash]), &MapSet.put(&1, tx_hash))
  end

  defp insert_by_gas_fee(gas_fee_list, {tx_hash, blob_tx}) do
    fee = blob_tx.max_fee_per_blob_gas

    # Insert in descending order of gas fee
    insert_sorted(gas_fee_list, {tx_hash, fee})
  end

  defp insert_sorted([], item), do: [item]

  defp insert_sorted([{_hash, fee} = head | tail], {_new_hash, new_fee} = new_item) do
    if new_fee >= fee do
      [new_item, head | tail]
    else
      [head | insert_sorted(tail, new_item)]
    end
  end

  defp add_verified_proofs(verified_proofs, blob_data_list) do
    proof_hashes =
      Enum.map(blob_data_list, fn {_blob, _commitment, proof} ->
        :crypto.hash(:sha256, proof)
      end)

    Enum.reduce(proof_hashes, verified_proofs, &MapSet.put(&2, &1))
  end

  defp maybe_evict_old_transactions(state) do
    if map_size(state.blob_transactions) > @max_blob_txs do
      # Remove lowest fee transactions
      to_remove =
        state.by_gas_fee
        |> Enum.reverse()
        |> Enum.take(map_size(state.blob_transactions) - @max_blob_txs)
        |> Enum.map(fn {hash, _fee} -> hash end)

      remove_transactions_internal(to_remove, state)
    else
      state
    end
  end

  defp get_best_transactions_internal(max_blob_gas, state) do
    state.by_gas_fee
    |> Enum.reduce_while({[], 0}, fn {hash, _fee}, {acc, gas_used} ->
      case Map.get(state.blob_transactions, hash) do
        {blob_tx, blob_data_list} ->
          tx_gas = calculate_blob_gas(blob_tx)

          if gas_used + tx_gas <= max_blob_gas do
            {:cont, {[{blob_tx, blob_data_list} | acc], gas_used + tx_gas}}
          else
            {:halt, {acc, gas_used}}
          end

        nil ->
          {:cont, {acc, gas_used}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp remove_transactions_internal(hashes, state) do
    Enum.reduce(hashes, state, fn hash, acc_state ->
      case Map.get(acc_state.blob_transactions, hash) do
        {blob_tx, _blob_data_list} ->
          sender = Blob.sender(blob_tx)
          blob_gas = calculate_blob_gas(blob_tx)

          %{
            acc_state
            | blob_transactions: Map.delete(acc_state.blob_transactions, hash),
              by_sender: update_sender_remove(acc_state.by_sender, sender, hash),
              by_gas_fee: remove_from_gas_fee(acc_state.by_gas_fee, hash),
              blob_gas_used: acc_state.blob_gas_used - blob_gas
          }

        nil ->
          acc_state
      end
    end)
  end

  defp update_sender_remove(by_sender, sender, tx_hash) do
    case Map.get(by_sender, sender) do
      nil ->
        by_sender

      hashes ->
        updated_hashes = MapSet.delete(hashes, tx_hash)

        if MapSet.size(updated_hashes) == 0 do
          Map.delete(by_sender, sender)
        else
          Map.put(by_sender, sender, updated_hashes)
        end
    end
  end

  defp remove_from_gas_fee(gas_fee_list, hash_to_remove) do
    Enum.reject(gas_fee_list, fn {hash, _fee} -> hash == hash_to_remove end)
  end

  defp unzip_blob_data(blob_data_list) do
    {blobs, commitments, proofs} =
      blob_data_list
      |> Enum.reduce({[], [], []}, fn {blob, commitment, proof}, {blobs, commitments, proofs} ->
        {[blob | blobs], [commitment | commitments], [proof | proofs]}
      end)
      |> then(fn {blobs, commitments, proofs} ->
        {Enum.reverse(blobs), Enum.reverse(commitments), Enum.reverse(proofs)}
      end)

    {blobs, commitments, proofs}
  end
end
