defmodule Blockchain.Transaction.BlobValidator do
  @moduledoc """
  Validation logic for EIP-4844 blob transactions.

  Ensures blob transactions meet all requirements including:
  - Valid versioned hashes
  - KZG proof verification
  - Blob gas limits
  - Transaction format compliance
  """

  require Logger

  alias Blockchain.Transaction.Blob
  alias Blockchain.BlobGasMarket
  alias ExWire.Crypto.KZG

  # EIP-4844 constants
  @blob_tx_type 0x03
  @versioned_hash_version_kzg 0x01
  @max_blobs_per_tx 6
  @bytes_per_blob 131_072
  @bytes_per_field_element 32

  @doc """
  Validate a blob transaction completely.
  """
  @spec validate_blob_transaction(Blob.t(), list({binary(), binary(), binary()})) ::
          :ok | {:error, term()}
  def validate_blob_transaction(blob_tx, blob_data_list) do
    with :ok <- validate_transaction_type(blob_tx),
         :ok <- validate_blob_count(blob_tx, blob_data_list),
         :ok <- validate_versioned_hashes(blob_tx, blob_data_list),
         :ok <- validate_blob_data_format(blob_data_list),
         :ok <- validate_kzg_proofs(blob_data_list),
         :ok <- validate_gas_requirements(blob_tx),
         :ok <- validate_signature(blob_tx) do
      :ok
    end
  end

  @doc """
  Validate blob transaction for mempool acceptance.
  Lighter validation without full KZG proof verification.
  """
  @spec validate_for_mempool(Blob.t()) :: :ok | {:error, term()}
  def validate_for_mempool(blob_tx) do
    with :ok <- validate_transaction_type(blob_tx),
         :ok <- validate_basic_blob_fields(blob_tx),
         :ok <- validate_gas_requirements(blob_tx),
         :ok <- validate_signature(blob_tx) do
      :ok
    end
  end

  @doc """
  Compute versioned hash from KZG commitment.
  """
  @spec compute_versioned_hash(binary()) :: binary()
  def compute_versioned_hash(commitment) when byte_size(commitment) == 48 do
    hash = :crypto.hash(:sha256, commitment)
    <<@versioned_hash_version_kzg, rest::binary-size(31)>> = hash
    <<@versioned_hash_version_kzg, rest::binary>>
  end

  @doc """
  Validate blob data meets consensus rules.
  """
  @spec validate_blob_data(binary()) :: :ok | {:error, term()}
  def validate_blob_data(blob) do
    cond do
      byte_size(blob) != @bytes_per_blob ->
        {:error, {:invalid_blob_size, byte_size(blob)}}

      not valid_field_elements?(blob) ->
        {:error, :invalid_field_elements}

      true ->
        :ok
    end
  end

  # Private validation functions

  defp validate_transaction_type(blob_tx) do
    if Map.get(blob_tx, :type) == @blob_tx_type do
      :ok
    else
      {:error, {:invalid_tx_type, Map.get(blob_tx, :type)}}
    end
  end

  defp validate_blob_count(blob_tx, blob_data_list) do
    hash_count = length(blob_tx.blob_versioned_hashes)
    data_count = length(blob_data_list)

    cond do
      hash_count == 0 ->
        {:error, :no_blob_hashes}

      hash_count > @max_blobs_per_tx ->
        {:error, {:too_many_blobs, hash_count}}

      hash_count != data_count ->
        {:error, {:blob_count_mismatch, hash_count, data_count}}

      true ->
        :ok
    end
  end

  defp validate_versioned_hashes(blob_tx, blob_data_list) do
    computed_hashes =
      blob_data_list
      |> Enum.map(fn {_blob, commitment, _proof} ->
        compute_versioned_hash(commitment)
      end)

    if blob_tx.blob_versioned_hashes == computed_hashes do
      :ok
    else
      {:error, :versioned_hash_mismatch}
    end
  end

  defp validate_blob_data_format(blob_data_list) do
    invalid_blob =
      Enum.find(blob_data_list, fn {blob, commitment, proof} ->
        byte_size(blob) != @bytes_per_blob or
          byte_size(commitment) != 48 or
          byte_size(proof) != 48
      end)

    if invalid_blob do
      {:error, :invalid_blob_data_format}
    else
      :ok
    end
  end

  defp validate_kzg_proofs(blob_data_list) do
    {blobs, commitments, proofs} = unzip_blob_data(blob_data_list)

    case KZG.verify_blob_kzg_proof_batch(blobs, commitments, proofs) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error, :kzg_proof_verification_failed}

      {:error, reason} ->
        {:error, {:kzg_error, reason}}
    end
  end

  defp validate_gas_requirements(blob_tx) do
    blob_count = length(blob_tx.blob_versioned_hashes)
    _min_blob_gas = blob_count * 131_072

    cond do
      not Map.has_key?(blob_tx, :max_fee_per_blob_gas) ->
        {:error, :missing_blob_gas_fee}

      blob_tx.max_fee_per_blob_gas <= 0 ->
        {:error, :invalid_blob_gas_fee}

      blob_tx.gas_limit < 21_000 ->
        {:error, :insufficient_gas_limit}

      true ->
        :ok
    end
  end

  defp validate_signature(blob_tx) do
    # Validate transaction signature
    case recover_sender(blob_tx) do
      {:ok, _sender} ->
        :ok

      {:error, reason} ->
        {:error, {:invalid_signature, reason}}
    end
  end

  defp validate_basic_blob_fields(blob_tx) do
    cond do
      not is_list(blob_tx.blob_versioned_hashes) ->
        {:error, :invalid_versioned_hashes}

      length(blob_tx.blob_versioned_hashes) == 0 ->
        {:error, :no_blob_hashes}

      length(blob_tx.blob_versioned_hashes) > @max_blobs_per_tx ->
        {:error, :too_many_blobs}

      not Enum.all?(blob_tx.blob_versioned_hashes, &valid_versioned_hash?/1) ->
        {:error, :invalid_versioned_hash_format}

      true ->
        :ok
    end
  end

  defp valid_versioned_hash?(hash) when byte_size(hash) == 32 do
    <<version::8, _rest::binary>> = hash
    version == @versioned_hash_version_kzg
  end

  defp valid_versioned_hash?(_), do: false

  defp valid_field_elements?(blob) do
    # Check that all field elements are valid (less than BLS modulus)
    blob
    |> :binary.bin_to_list()
    |> Enum.chunk_every(@bytes_per_field_element)
    |> Enum.all?(&valid_field_element?/1)
  end

  defp valid_field_element?(bytes) when length(bytes) == @bytes_per_field_element do
    # Convert to integer and check against BLS12-381 field modulus
    value = :binary.list_to_bin(bytes) |> :binary.decode_unsigned(:big)
    # BLS12-381 field modulus
    modulus =
      52_435_875_175_126_190_479_447_740_508_185_965_837_690_552_500_527_637_822_603_658_699_938_581_184_513

    value < modulus
  end

  defp valid_field_element?(_), do: false

  defp unzip_blob_data(blob_data_list) do
    blob_data_list
    |> Enum.reduce({[], [], []}, fn {blob, commitment, proof}, {blobs, commitments, proofs} ->
      {[blob | blobs], [commitment | commitments], [proof | proofs]}
    end)
    |> then(fn {blobs, commitments, proofs} ->
      {Enum.reverse(blobs), Enum.reverse(commitments), Enum.reverse(proofs)}
    end)
  end

  defp recover_sender(blob_tx) do
    # Simplified sender recovery - would use proper ECDSA recovery
    if Map.has_key?(blob_tx, :signature) and byte_size(blob_tx.signature) >= 65 do
      # Extract sender from signature
      # Placeholder sender
      {:ok, <<0::160>>}
    else
      {:error, :missing_signature}
    end
  end

  @doc """
  Calculate the total blob gas cost for a transaction.
  """
  @spec calculate_blob_gas_cost(Blob.t(), map()) :: non_neg_integer()
  def calculate_blob_gas_cost(blob_tx, blob_gas_state) do
    blob_count = length(blob_tx.blob_versioned_hashes)
    blob_gas = blob_count * 131_072

    base_fee = BlobGasMarket.calculate_blob_basefee(blob_gas_state.excess_blob_gas)
    blob_gas * base_fee
  end

  @doc """
  Check if transaction can pay for blob gas.
  """
  @spec can_pay_blob_gas?(Blob.t(), map(), non_neg_integer()) :: boolean()
  def can_pay_blob_gas?(blob_tx, blob_gas_state, sender_balance) do
    blob_gas_cost = calculate_blob_gas_cost(blob_tx, blob_gas_state)
    regular_gas_cost = blob_tx.gas_limit * blob_tx.max_fee_per_gas

    total_cost = blob_gas_cost + regular_gas_cost + blob_tx.value
    sender_balance >= total_cost
  end
end
