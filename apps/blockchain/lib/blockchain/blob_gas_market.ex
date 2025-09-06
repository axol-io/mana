defmodule Blockchain.BlobGasMarket do
  @moduledoc """
  EIP-4844 Blob Gas Fee Market implementation.

  Implements the multidimensional fee market for blob transactions,
  separate from the main transaction gas market.
  """

  # EIP-4844 constants
  @blob_gas_per_blob 131_072
  # 3 blobs
  @target_blob_gas_per_block 393_216
  # 6 blobs
  @max_blob_gas_per_block 786_432
  @blob_gasprice_update_fraction 3_338_477
  @min_blob_gasprice 1

  @type blob_gas_state :: %{
          excess_blob_gas: non_neg_integer(),
          blob_gas_used: non_neg_integer(),
          blob_basefee: non_neg_integer()
        }

  @doc """
  Calculate the blob base fee for a given excess blob gas amount.
  Based on EIP-4844 specification.
  """
  @spec calculate_blob_basefee(non_neg_integer()) :: non_neg_integer()
  def calculate_blob_basefee(excess_blob_gas) do
    # Simplified exponential function for blob fee calculation
    # Real implementation would use more precise exponential calculation
    if excess_blob_gas == 0 do
      @min_blob_gasprice
    else
      # Approximate exponential function: basefee = min_basefee * e^(excess_gas / update_fraction)
      # Using integer arithmetic approximation
      exponent = div(excess_blob_gas, @blob_gasprice_update_fraction)

      # Approximate e^x for small x using Taylor series: e^x ≈ 1 + x + x²/2 + x³/6
      if exponent == 0 do
        @min_blob_gasprice
      else
        # For larger exponents, use simplified exponential growth
        max(@min_blob_gasprice, @min_blob_gasprice * (1 + exponent) * (1 + div(exponent, 2)))
      end
    end
  end

  @doc """
  Update blob gas state after processing a block.
  """
  @spec update_blob_gas_state(blob_gas_state(), non_neg_integer()) :: blob_gas_state()
  def update_blob_gas_state(prev_state, blob_gas_used) do
    # Calculate new excess blob gas
    new_excess = calculate_excess_blob_gas(prev_state.excess_blob_gas, blob_gas_used)

    # Calculate new blob base fee
    new_basefee = calculate_blob_basefee(new_excess)

    %{
      excess_blob_gas: new_excess,
      blob_gas_used: blob_gas_used,
      blob_basefee: new_basefee
    }
  end

  @doc """
  Validate blob gas pricing for a transaction.
  """
  @spec validate_blob_transaction_gas(map(), blob_gas_state()) :: :ok | {:error, term()}
  def validate_blob_transaction_gas(blob_tx, blob_gas_state) do
    blob_count = length(blob_tx.blob_versioned_hashes)
    tx_blob_gas = blob_count * @blob_gas_per_blob

    # Check max fee per blob gas is sufficient
    required_basefee = blob_gas_state.blob_basefee
    max_fee = Map.get(blob_tx, :max_fee_per_blob_gas, 0)

    cond do
      blob_count == 0 ->
        {:error, :no_blobs}

      blob_count > div(@max_blob_gas_per_block, @blob_gas_per_blob) ->
        {:error, :too_many_blobs}

      max_fee < required_basefee ->
        {:error, {:insufficient_blob_fee, required_basefee, max_fee}}

      tx_blob_gas > @max_blob_gas_per_block ->
        {:error, :blob_gas_limit_exceeded}

      true ->
        :ok
    end
  end

  @doc """
  Calculate blob gas fee for a transaction.
  """
  @spec calculate_blob_gas_fee(map(), blob_gas_state()) :: non_neg_integer()
  def calculate_blob_gas_fee(blob_tx, blob_gas_state) do
    blob_count = length(blob_tx.blob_versioned_hashes)
    tx_blob_gas = blob_count * @blob_gas_per_blob

    # Use the current blob base fee
    basefee = blob_gas_state.blob_basefee

    tx_blob_gas * basefee
  end

  @doc """
  Calculate priority fee for blob transaction (tip).
  """
  @spec calculate_blob_priority_fee(map(), blob_gas_state()) :: non_neg_integer()
  def calculate_blob_priority_fee(blob_tx, blob_gas_state) do
    max_fee = Map.get(blob_tx, :max_fee_per_blob_gas, 0)
    max_priority_fee = Map.get(blob_tx, :max_priority_fee_per_blob_gas, 0)
    basefee = blob_gas_state.blob_basefee

    # Priority fee is min(max_priority_fee, max_fee - basefee)
    actual_priority_fee = min(max_priority_fee, max_fee - basefee)

    # Calculate total priority fee for all blobs
    blob_count = length(blob_tx.blob_versioned_hashes)
    tx_blob_gas = blob_count * @blob_gas_per_blob

    max(0, actual_priority_fee * tx_blob_gas)
  end

  @doc """
  Get blob gas market statistics.
  """
  @spec get_market_stats(blob_gas_state()) :: map()
  def get_market_stats(blob_gas_state) do
    %{
      current_basefee: blob_gas_state.blob_basefee,
      excess_blob_gas: blob_gas_state.excess_blob_gas,
      last_block_blob_gas: blob_gas_state.blob_gas_used,
      target_blob_gas: @target_blob_gas_per_block,
      max_blob_gas: @max_blob_gas_per_block,
      utilization_percent:
        if(blob_gas_state.blob_gas_used > 0,
          do: div(blob_gas_state.blob_gas_used * 100, @max_blob_gas_per_block),
          else: 0
        )
    }
  end

  @doc """
  Initialize blob gas state for genesis or first Deneb block.
  """
  @spec init_blob_gas_state() :: blob_gas_state()
  def init_blob_gas_state do
    %{
      excess_blob_gas: 0,
      blob_gas_used: 0,
      blob_basefee: @min_blob_gasprice
    }
  end

  @doc """
  Check if blob gas usage is within block limits.
  """
  @spec validate_block_blob_gas(non_neg_integer()) :: :ok | {:error, term()}
  def validate_block_blob_gas(total_blob_gas) do
    cond do
      total_blob_gas > @max_blob_gas_per_block ->
        {:error, :blob_gas_limit_exceeded}

      rem(total_blob_gas, @blob_gas_per_blob) != 0 ->
        {:error, :invalid_blob_gas_amount}

      true ->
        :ok
    end
  end

  @doc """
  Calculate the expected blob gas for a list of blob transactions.
  """
  @spec calculate_total_blob_gas(list(map())) :: non_neg_integer()
  def calculate_total_blob_gas(blob_transactions) when is_list(blob_transactions) do
    Enum.reduce(blob_transactions, 0, fn tx, acc ->
      blob_count = length(Map.get(tx, :blob_versioned_hashes, []))
      acc + blob_count * @blob_gas_per_blob
    end)
  end

  @doc """
  Sort blob transactions by effective fee per blob gas (for block inclusion).
  """
  @spec sort_by_effective_fee(list(map()), blob_gas_state()) :: list(map())
  def sort_by_effective_fee(blob_transactions, blob_gas_state) do
    Enum.sort_by(blob_transactions, fn tx ->
      # Calculate effective fee per blob gas
      max_fee = Map.get(tx, :max_fee_per_blob_gas, 0)
      max_priority_fee = Map.get(tx, :max_priority_fee_per_blob_gas, 0)
      basefee = blob_gas_state.blob_basefee

      # Effective fee is min(max_fee, basefee + max_priority_fee)
      effective_fee = min(max_fee, basefee + max_priority_fee)

      # Sort in descending order (highest fee first)
      -effective_fee
    end)
  end

  # Private helper functions

  defp calculate_excess_blob_gas(prev_excess, blob_gas_used) do
    # Calculate excess blob gas using EIP-4844 formula
    # excess_blob_gas = max(0, prev_excess + blob_gas_used - target_blob_gas)
    max(0, prev_excess + blob_gas_used - @target_blob_gas_per_block)
  end
end
