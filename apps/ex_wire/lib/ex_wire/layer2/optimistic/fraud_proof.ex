defmodule ExWire.Layer2.Optimistic.FraudProof do
  @moduledoc """
  Fraud proof generation and verification for optimistic rollups.
  """

  require Logger

  @type proof_type :: :state_transition | :signature | :execution | :data_availability

  @type t :: %__MODULE__{
          type: proof_type(),
          batch_number: non_neg_integer(),
          transaction_index: non_neg_integer() | nil,
          expected_state_root: binary(),
          actual_state_root: binary(),
          witness_data: binary(),
          proof_data: binary()
        }

  defstruct [
    :type,
    :batch_number,
    :transaction_index,
    :expected_state_root,
    :actual_state_root,
    :witness_data,
    :proof_data
  ]

  @doc """
  Generates a fraud proof for an invalid state transition.
  """
  @spec generate(map(), binary(), binary()) :: {:ok, t()} | {:error, term()}
  def generate(batch, expected_root, actual_root) do
    proof = %__MODULE__{
      type: :state_transition,
      batch_number: batch.batch_number,
      expected_state_root: expected_root,
      actual_state_root: actual_root,
      witness_data: generate_witness(batch),
      proof_data: encode_proof_data(batch, expected_root)
    }

    {:ok, proof}
  end

  @doc """
  Verifies a fraud proof against a challenge.
  """
  @spec verify(map(), binary()) :: {:ok, boolean()} | {:error, term()}
  def verify(challenge, proof_binary) do
    try do
      proof = decode_proof(proof_binary)

      result =
        case proof.type do
          :state_transition ->
            verify_state_transition(challenge, proof)

          :signature ->
            verify_signature_fraud(challenge, proof)

          :execution ->
            verify_execution_fraud(challenge, proof)

          :data_availability ->
            verify_data_availability(challenge, proof)

          _ ->
            false
        end

      {:ok, result}
    rescue
      e ->
        Logger.error("Fraud proof verification failed: #{inspect(e)}")
        {:error, e}
    end
  end

  @doc """
  Encodes a fraud proof for transmission.
  """
  @spec encode(t()) :: binary()
  def encode(proof) do
    :erlang.term_to_binary(proof)
  end

  @doc """
  Decodes a fraud proof from binary.
  """
  @spec decode(binary()) :: t()
  def decode(binary) do
    :erlang.binary_to_term(binary)
  end

  # Private Functions

  defp generate_witness(batch) do
    # Generate witness data for the batch
    # This includes pre-state, post-state, and transaction data
    witness = %{
      pre_state: batch.previous_root,
      post_state: batch.state_root,
      transactions: batch.transactions,
      timestamp: batch.timestamp
    }

    :erlang.term_to_binary(witness)
  end

  defp encode_proof_data(batch, expected_root) do
    # Encode the proof data
    data = %{
      batch_hash: compute_batch_hash(batch),
      expected_root: expected_root,
      actual_root: batch.state_root,
      transactions_root: compute_transactions_root(batch.transactions)
    }

    :erlang.term_to_binary(data)
  end

  defp decode_proof(proof_binary) when is_binary(proof_binary) do
    :erlang.binary_to_term(proof_binary)
  end

  defp decode_proof(%__MODULE__{} = proof), do: proof

  defp verify_state_transition(challenge, proof) do
    # Verify that the state transition is invalid
    # The fraud proof is valid if it shows the actual state root
    # differs from what it should be

    expected = proof.expected_state_root
    actual = challenge.claimed_state_root

    # Re-execute transactions to verify the correct state root
    computed_root = recompute_state_root(proof.witness_data)

    # Fraud is proven if:
    # 1. The claimed root doesn't match the expected root
    # 2. Our computed root matches the expected root
    actual != expected and computed_root == expected
  end

  defp verify_signature_fraud(challenge, proof) do
    # Verify that a transaction signature is invalid
    witness = :erlang.binary_to_term(proof.witness_data)
    tx_index = proof.transaction_index || 0

    case Enum.at(witness.transactions, tx_index) do
      nil -> false
      tx -> not verify_transaction_signature(tx)
    end
  end

  defp verify_execution_fraud(challenge, proof) do
    # Verify that transaction execution is invalid
    witness = :erlang.binary_to_term(proof.witness_data)

    # Re-execute the transactions
    {:ok, expected_root} =
      execute_transactions(
        witness.transactions,
        witness.pre_state
      )

    # Fraud is proven if execution produces different result
    expected_root != proof.actual_state_root
  end

  defp verify_data_availability(_challenge, proof) do
    # Verify that data is not available
    # This would check if the batch data can be retrieved

    # For testing, simulate availability check
    :rand.uniform() > 0.8
  end

  defp compute_batch_hash(batch) do
    data = :erlang.term_to_binary(batch)
    :crypto.hash(:sha256, data)
  end

  defp compute_transactions_root(transactions) do
    leaves =
      Enum.map(transactions, fn tx ->
        :crypto.hash(:sha256, :erlang.term_to_binary(tx))
      end)

    merkle_root(leaves)
  end

  defp merkle_root([]), do: <<0::256>>
  defp merkle_root([single]), do: single

  defp merkle_root(leaves) do
    next_level =
      leaves
      |> Enum.chunk_every(2)
      |> Enum.map(fn
        [left, right] -> :crypto.hash(:sha256, left <> right)
        [single] -> single
      end)

    merkle_root(next_level)
  end

  defp recompute_state_root(witness_data) do
    # Recompute the state root from witness data
    witness = :erlang.binary_to_term(witness_data)

    # Simulate state computation
    combined = witness.pre_state <> :erlang.term_to_binary(witness.transactions)
    :crypto.hash(:sha256, combined)
  end

  defp verify_transaction_signature(tx) do
    # Verify ECDSA signature of transaction
    # In production, would use actual crypto verification

    # For testing, accept most signatures
    :rand.uniform() > 0.1
  end

  defp execute_transactions(transactions, pre_state) do
    # Execute transactions starting from pre_state
    final_state =
      Enum.reduce(transactions, pre_state, fn tx, state ->
        apply_transaction(tx, state)
      end)

    {:ok, final_state}
  end

  defp apply_transaction(tx, _state) do
    # Apply a single transaction to the state
    tx_data = :erlang.term_to_binary(tx)
    :crypto.hash(:sha256, state <> tx_data)
  end
end
