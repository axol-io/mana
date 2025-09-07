defmodule ExWire.Eth2.ExecutionPayload do
  @moduledoc """
  Execution payload for Ethereum 2.0 beacon blocks.

  Contains the execution layer block data that is committed to
  by the beacon chain consensus layer.
  """

  defstruct [
    :parent_hash,
    :fee_recipient,
    :state_root,
    :receipts_root,
    :logs_bloom,
    :prev_randao,
    :block_number,
    :gas_limit,
    :gas_used,
    :timestamp,
    :extra_data,
    :base_fee_per_gas,
    :block_hash,
    :transactions,
    :withdrawals,
    :blob_gas_used,
    :excess_blob_gas
  ]

  @type t :: %__MODULE__{
          parent_hash: binary(),
          fee_recipient: binary(),
          state_root: binary(),
          receipts_root: binary(),
          logs_bloom: binary(),
          prev_randao: binary(),
          block_number: non_neg_integer(),
          gas_limit: non_neg_integer(),
          gas_used: non_neg_integer(),
          timestamp: non_neg_integer(),
          extra_data: binary(),
          base_fee_per_gas: non_neg_integer(),
          block_hash: binary(),
          transactions: [binary()],
          withdrawals: [map()],
          blob_gas_used: non_neg_integer(),
          excess_blob_gas: non_neg_integer()
        }

  @doc """
  Create an empty execution payload.
  """
  @spec empty() :: t()
  def empty do
    %__MODULE__{
      parent_hash: <<0::256>>,
      fee_recipient: <<0::160>>,
      state_root: <<0::256>>,
      receipts_root: <<0::256>>,
      logs_bloom: <<0::2048>>,
      prev_randao: <<0::256>>,
      block_number: 0,
      gas_limit: 0,
      gas_used: 0,
      timestamp: 0,
      extra_data: <<>>,
      base_fee_per_gas: 0,
      block_hash: <<0::256>>,
      transactions: [],
      withdrawals: [],
      blob_gas_used: 0,
      excess_blob_gas: 0
    }
  end

  @doc """
  Check if the execution payload contains blob transactions.
  """
  @spec has_blobs?(t()) :: boolean()
  def has_blobs?(payload) do
    payload.blob_gas_used > 0
  end

  @doc """
  Validate execution payload blob gas fields for Deneb compliance.
  """
  @spec validate_blob_gas_fields(t(), non_neg_integer()) :: :ok | {:error, term()}
  def validate_blob_gas_fields(payload, expected_blob_gas) do
    alias Blockchain.BlobGasMarket

    with :ok <- BlobGasMarket.validate_block_blob_gas(payload.blob_gas_used),
         :ok <- validate_blob_gas_consistency(payload, expected_blob_gas),
         :ok <- validate_excess_blob_gas(payload) do
      :ok
    end
  end

  @doc """
  Update execution payload with blob gas market state.
  """
  @spec update_blob_gas_state(t(), map()) :: t()
  def update_blob_gas_state(payload, blob_gas_state) do
    %{
      payload
      | blob_gas_used: blob_gas_state.blob_gas_used,
        excess_blob_gas: blob_gas_state.excess_blob_gas
    }
  end

  @doc """
  Calculate blob base fee from execution payload.
  """
  @spec calculate_blob_basefee(t()) :: non_neg_integer()
  def calculate_blob_basefee(payload) do
    Blockchain.BlobGasMarket.calculate_blob_basefee(payload.excess_blob_gas)
  end

  # Private validation functions

  defp validate_blob_gas_consistency(payload, expected_blob_gas) do
    if payload.blob_gas_used == expected_blob_gas do
      :ok
    else
      {:error, {:blob_gas_mismatch, payload.blob_gas_used, expected_blob_gas}}
    end
  end

  defp validate_excess_blob_gas(payload) do
    # Excess blob gas must be non-negative
    if payload.excess_blob_gas >= 0 do
      :ok
    else
      {:error, {:invalid_excess_blob_gas, payload.excess_blob_gas}}
    end
  end

  @doc """
  Validate blob gas fields in execution payload.
  """
  @spec validate_blob_gas_fields(t(), non_neg_integer()) :: :ok | {:error, term()}
  def validate_blob_gas_fields(payload, expected_blob_gas) do
    case payload do
      %{blob_gas_used: blob_gas_used, excess_blob_gas: excess_blob_gas} 
      when blob_gas_used == expected_blob_gas ->
        # Additional validation for excess blob gas
        if excess_blob_gas >= 0 do
          :ok
        else
          {:error, {:invalid_excess_blob_gas, excess_blob_gas}}
        end
      
      %{blob_gas_used: blob_gas_used} ->
        {:error, {:blob_gas_mismatch, blob_gas_used, expected_blob_gas}}
        
      _ ->
        {:error, :missing_blob_gas_fields}
    end
  end
end
