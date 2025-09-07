defmodule Blockchain.Transaction.Blob do
  @moduledoc """
  EIP-4844 Blob Transaction implementation.

  Blob transactions are Type 3 transactions that include blob data commitments
  for Layer 2 scaling. They use a new transaction format with versioned hashes
  and blob gas pricing.
  """

  alias Blockchain.Transaction
  alias ExthCrypto.KZG

  # Transaction type identifier for blob transactions
  @blob_tx_type 0x03

  # Constants from EIP-4844
  @versioned_hash_version_kzg 0x01

  @type versioned_hash :: <<_::256>>

  @type t :: %__MODULE__{
          chain_id: non_neg_integer(),
          nonce: non_neg_integer(),
          max_priority_fee_per_gas: non_neg_integer(),
          max_fee_per_gas: non_neg_integer(),
          gas_limit: non_neg_integer(),
          to: EVM.address(),
          value: non_neg_integer(),
          data: binary(),
          access_list: list({EVM.address(), list(binary())}),
          max_fee_per_blob_gas: non_neg_integer(),
          blob_versioned_hashes: list(versioned_hash()),
          v: non_neg_integer(),
          r: non_neg_integer(),
          s: non_neg_integer()
        }

  defstruct [
    :chain_id,
    :nonce,
    :max_priority_fee_per_gas,
    :max_fee_per_gas,
    :gas_limit,
    :to,
    :value,
    :data,
    :access_list,
    :max_fee_per_blob_gas,
    :blob_versioned_hashes,
    :v,
    :r,
    :s
  ]

  @doc """
  Serialize a blob transaction for RLP encoding.

  The format is:
  rlp([chain_id, nonce, max_priority_fee_per_gas, max_fee_per_gas, gas_limit,
       to, value, data, access_list, max_fee_per_blob_gas, blob_versioned_hashes,
       y_parity, r, s])
  """
  @spec serialize(t()) :: list()
  def serialize(%__MODULE__{} = tx) do
    [
      tx.chain_id |> BitHelper.encode_unsigned(),
      tx.nonce |> BitHelper.encode_unsigned(),
      tx.max_priority_fee_per_gas |> BitHelper.encode_unsigned(),
      tx.max_fee_per_gas |> BitHelper.encode_unsigned(),
      tx.gas_limit |> BitHelper.encode_unsigned(),
      tx.to,
      tx.value |> BitHelper.encode_unsigned(),
      tx.data,
      serialize_access_list(tx.access_list),
      tx.max_fee_per_blob_gas |> BitHelper.encode_unsigned(),
      tx.blob_versioned_hashes,
      tx.v |> BitHelper.encode_unsigned(),
      tx.r |> BitHelper.encode_unsigned(),
      tx.s |> BitHelper.encode_unsigned()
    ]
  end

  @doc """
  Deserialize a blob transaction from RLP-decoded data.
  """
  @spec deserialize(list()) :: {:ok, t()} | {:error, term()}
  def deserialize([
        chain_id,
        nonce,
        max_priority_fee_per_gas,
        max_fee_per_gas,
        gas_limit,
        to,
        value,
        data,
        access_list,
        max_fee_per_blob_gas,
        blob_versioned_hashes,
        v,
        r,
        s
      ]) do
    {:ok,
     %__MODULE__{
       chain_id: :binary.decode_unsigned(chain_id),
       nonce: :binary.decode_unsigned(nonce),
       max_priority_fee_per_gas: :binary.decode_unsigned(max_priority_fee_per_gas),
       max_fee_per_gas: :binary.decode_unsigned(max_fee_per_gas),
       gas_limit: :binary.decode_unsigned(gas_limit),
       to: to,
       value: :binary.decode_unsigned(value),
       data: data,
       access_list: deserialize_access_list(access_list),
       max_fee_per_blob_gas: :binary.decode_unsigned(max_fee_per_blob_gas),
       blob_versioned_hashes: blob_versioned_hashes,
       v: :binary.decode_unsigned(v),
       r: :binary.decode_unsigned(r),
       s: :binary.decode_unsigned(s)
     }}
  end

  def deserialize(_), do: {:error, :invalid_blob_transaction}

  @doc """
  Calculate the total blob gas for a transaction.
  Each blob costs exactly 2^17 (131072) gas.
  """
  @spec get_total_blob_gas(t()) :: non_neg_integer()
  def get_total_blob_gas(%__MODULE__{blob_versioned_hashes: hashes}) do
    length(hashes) * gas_per_blob()
  end

  @doc """
  Calculate the total blob fee for a transaction.
  """
  @spec get_blob_fee(t(), non_neg_integer()) :: non_neg_integer()
  def get_blob_fee(%__MODULE__{} = tx, base_fee_per_blob_gas) do
    get_total_blob_gas(tx) * base_fee_per_blob_gas
  end

  @doc """
  Validate a blob transaction.

  Checks:
  - To address must not be nil (no contract creation)
  - Must have at least one blob
  - All versioned hashes must use KZG version
  - Max fee per blob gas must be reasonable
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = tx) do
    cond do
      tx.to == <<>> or is_nil(tx.to) ->
        {:error, :blob_transaction_cannot_create_contract}

      length(tx.blob_versioned_hashes) == 0 ->
        {:error, :blob_transaction_must_have_blobs}

      not all_valid_versioned_hashes?(tx.blob_versioned_hashes) ->
        {:error, :invalid_versioned_hash}

      tx.max_fee_per_blob_gas < 1 ->
        {:error, :max_fee_per_blob_gas_too_low}

      true ->
        :ok
    end
  end

  @doc """
  Convert a blob transaction to a standard transaction format for execution.
  """
  @spec to_standard_transaction(t()) :: Transaction.t()
  def to_standard_transaction(%__MODULE__{} = tx) do
    %Transaction{
      nonce: tx.nonce,
      gas_price: effective_gas_price(tx),
      gas_limit: tx.gas_limit,
      to: tx.to,
      value: tx.value,
      v: tx.v,
      r: tx.r,
      s: tx.s,
      data: tx.data
    }
  end

  @doc """
  Create a versioned hash from a KZG commitment.
  The versioned hash is: version_byte || sha256(commitment)[1:]
  """
  @spec create_versioned_hash(binary()) :: versioned_hash()
  def create_versioned_hash(commitment) when byte_size(commitment) == 48 do
    KZG.create_versioned_hash(commitment)
  end

  @doc """
  Check if a versioned hash is valid (uses KZG version).
  """
  @spec valid_versioned_hash?(versioned_hash()) :: boolean()
  def valid_versioned_hash?(<<@versioned_hash_version_kzg, _::binary-size(31)>>), do: true
  def valid_versioned_hash?(_), do: false

  @doc """
  Get the transaction type byte for blob transactions.
  """
  @spec transaction_type() :: byte()
  def transaction_type, do: @blob_tx_type

  @doc """
  Get gas per blob constant (2^17).
  """
  @spec gas_per_blob() :: non_neg_integer()
  def gas_per_blob, do: 131_072

  # Private functions

  defp serialize_access_list(access_list) do
    Enum.map(access_list, fn {address, storage_keys} ->
      [address, storage_keys]
    end)
  end

  defp deserialize_access_list(access_list) do
    Enum.map(access_list, fn [address, storage_keys] ->
      {address, storage_keys}
    end)
  end

  defp all_valid_versioned_hashes?(hashes) do
    Enum.all?(hashes, &valid_versioned_hash?/1)
  end

  defp effective_gas_price(%__MODULE__{max_fee_per_gas: max_fee}) do
    # In actual execution, this would be min(max_fee_per_gas, base_fee + max_priority_fee_per_gas)
    # For now, we use max_fee_per_gas as a placeholder
    max_fee
  end

  # KZG verification functions

  @doc """
  Verify that blob data matches its KZG commitment and proof.
  This is the core cryptographic verification for EIP-4844.
  """
  @spec verify_blob_kzg_proof(binary(), binary(), binary()) :: {:ok, boolean()} | {:error, term()}
  def verify_blob_kzg_proof(blob_data, commitment, proof) do
    KZG.verify_blob_with_validation(blob_data, commitment, proof)
  end

  @doc """
  Verify multiple blobs and their KZG proofs in batch.
  More efficient than individual verification for multiple blobs.
  """
  @spec verify_blob_kzg_proof_batch(list(binary()), list(binary()), list(binary())) ::
          {:ok, boolean()} | {:error, term()}
  def verify_blob_kzg_proof_batch(blob_data_list, commitments, proofs) do
    KZG.verify_batch_with_validation(blob_data_list, commitments, proofs)
  end

  @doc """
  Generate KZG commitment and proof for blob data.
  Used for creating blob transactions.
  """
  @spec generate_blob_commitment_and_proof(binary()) ::
          {:ok, {binary(), binary()}} | {:error, term()}
  def generate_blob_commitment_and_proof(blob_data) do
    case KZG.validate_blob(blob_data) do
      :ok -> KZG.generate_commitment_and_proof(blob_data)
      error -> error
    end
  end

  @doc """
  Validate a complete blob transaction including KZG verification.
  This extends the basic validation with cryptographic proof verification.
  """
  @spec validate_with_kzg(t(), list({binary(), binary(), binary()})) :: :ok | {:error, term()}
  def validate_with_kzg(%__MODULE__{} = tx, blob_data_list) when is_list(blob_data_list) do
    with :ok <- validate(tx),
         :ok <- validate_blob_data_consistency(tx, blob_data_list),
         {:ok, true} <- verify_all_blob_proofs(blob_data_list) do
      :ok
    end
  end

  @doc """
  Validate that blob data is consistent with transaction versioned hashes.
  """
  @spec validate_blob_data_consistency(t(), list({binary(), binary(), binary()})) ::
          :ok | {:error, term()}
  def validate_blob_data_consistency(
        %__MODULE__{blob_versioned_hashes: versioned_hashes},
        blob_data_list
      ) do
    if length(versioned_hashes) == length(blob_data_list) do
      validate_each_blob_hash(versioned_hashes, blob_data_list)
    else
      {:error, :blob_count_mismatch}
    end
  end

  # Private KZG helper functions

  defp verify_all_blob_proofs(blob_data_list) do
    {blobs, commitments, proofs} = unzip_blob_data(blob_data_list)
    verify_blob_kzg_proof_batch(blobs, commitments, proofs)
  end

  defp validate_each_blob_hash(versioned_hashes, blob_data_list) do
    versioned_hashes
    |> Enum.zip(blob_data_list)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{expected_hash, {_blob, commitment, _proof}}, index}, acc ->
      computed_hash = create_versioned_hash(commitment)

      if expected_hash == computed_hash do
        {:cont, acc}
      else
        {:halt, {:error, {:versioned_hash_mismatch, index}}}
      end
    end)
  end

  defp unzip_blob_data(blob_data_list) do
    # Manually unzip the 3-tuples since Enum.unzip3 doesn't exist
    {blobs, commitments, proofs} =
      blob_data_list
      |> Enum.reduce({[], [], []}, fn {blob, commitment, proof}, {bs, cs, ps} ->
        {[blob | bs], [commitment | cs], [proof | ps]}
      end)
      |> then(fn {bs, cs, ps} -> {Enum.reverse(bs), Enum.reverse(cs), Enum.reverse(ps)} end)

    {blobs, commitments, proofs}
  end

  @doc """
  Computes the hash of a blob transaction.
  """
  @spec hash(t()) :: binary()
  def hash(blob_tx) do
    blob_tx
    |> serialize()
    |> ExRLP.encode()
    |> ExthCrypto.Hash.Keccak.kec()
  end

  @doc """
  Recovers the sender address from a blob transaction.
  """
  @spec sender(t()) :: {:ok, EVM.address()} | {:error, term()}
  def sender(blob_tx) do
    # Reconstruct the signing data
    signing_data = [
      blob_tx.chain_id,
      blob_tx.nonce,
      blob_tx.max_priority_fee_per_gas,
      blob_tx.max_fee_per_gas,
      blob_tx.gas_limit,
      blob_tx.to,
      blob_tx.value,
      blob_tx.data,
      blob_tx.access_list,
      blob_tx.max_fee_per_blob_gas,
      blob_tx.blob_versioned_hashes
    ]

    message_hash =
      signing_data
      |> ExRLP.encode()
      |> ExthCrypto.Hash.Keccak.kec()

    # Recover public key from signature
    case Blockchain.Transaction.Signature.recover_public(
           message_hash,
           blob_tx.v,
           blob_tx.r,
           blob_tx.s
         ) do
      {:ok, public_key} ->
        address =
          public_key
          |> ExthCrypto.Hash.Keccak.kec()
          |> Binary.take(-20)

        {:ok, address}

      error ->
        error
    end
  end
end
