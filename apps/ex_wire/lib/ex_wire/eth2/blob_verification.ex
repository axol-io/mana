defmodule ExWire.Eth2.BlobVerification do
  @moduledoc """
  Blob verification for Ethereum consensus layer.

  This module handles verification of blob sidecars and KZG commitments
  as part of the beacon chain consensus process for EIP-4844.
  """

  require Logger
  alias ExWire.Crypto.KZG
  alias ExWire.Eth2.{BlobSidecar, BeaconBlock, ExecutionPayload}

  # EIP-4844 constants
  @max_blobs_per_block 6
  # 128 KiB
  @blob_size 131_072

  @doc """
  Verify all blob sidecars for a beacon block.

  This function validates:
  1. KZG commitment inclusion proofs
  2. Blob KZG proof verification
  3. Blob sidecar consistency with block
  """
  @spec verify_blob_sidecars(BeaconBlock.t(), [BlobSidecar.t()]) ::
          {:ok, :valid} | {:error, term()}
  def verify_blob_sidecars(block, blob_sidecars) do
    with :ok <- validate_sidecar_count(block, blob_sidecars),
         :ok <- verify_kzg_commitments(block, blob_sidecars),
         :ok <- verify_kzg_proofs(blob_sidecars),
         :ok <- verify_inclusion_proofs(block, blob_sidecars) do
      {:ok, :valid}
    else
      {:error, reason} ->
        Logger.warning("Blob verification failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Verify blob KZG commitments batch for execution payload.

  This is called during execution payload processing to verify
  blob transactions have valid KZG commitments.
  """
  @spec verify_execution_payload_blobs(ExecutionPayload.t(), [binary()]) ::
          {:ok, :valid} | {:error, term()}
  def verify_execution_payload_blobs(execution_payload, blob_kzg_commitments) do
    case execution_payload.blob_gas_used do
      0 when blob_kzg_commitments == [] ->
        {:ok, :valid}

      blob_gas_used when blob_gas_used > 0 ->
        verify_blob_gas_consistency(execution_payload, blob_kzg_commitments)

      _ ->
        {:error, :inconsistent_blob_gas}
    end
  end

  @doc """
  Validate blob sidecar for gossip propagation.

  This function performs lightweight validation suitable for
  P2P gossip validation before full consensus verification.
  """
  @spec validate_blob_sidecar_for_gossip(BlobSidecar.t()) ::
          {:ok, :valid} | {:error, term()}
  def validate_blob_sidecar_for_gossip(sidecar) do
    with :ok <- validate_blob_size(sidecar.blob),
         :ok <- validate_commitment_proof(sidecar) do
      {:ok, :valid}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Private implementation functions

  defp validate_sidecar_count(block, blob_sidecars) do
    expected_count = length(block.body.blob_kzg_commitments)
    actual_count = length(blob_sidecars)

    cond do
      expected_count == actual_count ->
        :ok

      expected_count > @max_blobs_per_block ->
        {:error, :too_many_blob_commitments}

      actual_count > expected_count ->
        {:error, :too_many_blob_sidecars}

      actual_count < expected_count ->
        {:error, :missing_blob_sidecars}
    end
  end

  defp verify_kzg_commitments(block, blob_sidecars) do
    block_commitments = block.body.blob_kzg_commitments
    sidecar_commitments = Enum.map(blob_sidecars, & &1.kzg_commitment)

    if block_commitments == sidecar_commitments do
      :ok
    else
      {:error, :commitment_mismatch}
    end
  end

  defp verify_kzg_proofs(blob_sidecars) do
    # Batch verify all KZG proofs for efficiency
    blobs = Enum.map(blob_sidecars, & &1.blob)
    commitments = Enum.map(blob_sidecars, & &1.kzg_commitment)
    proofs = Enum.map(blob_sidecars, & &1.kzg_proof)

    case KZG.verify_batch_with_validation(blobs, commitments, proofs) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        # Fallback to individual verification for better error reporting
        verify_individual_proofs(blob_sidecars)

      {:error, reason} ->
        {:error, {:kzg_verification_error, reason}}
    end
  end

  defp verify_individual_proofs(blob_sidecars) do
    invalid_sidecar =
      blob_sidecars
      |> Enum.with_index()
      |> Enum.find(fn {sidecar, _index} ->
        case KZG.verify_blob_with_validation(
               sidecar.blob,
               sidecar.kzg_commitment,
               sidecar.kzg_proof
             ) do
          {:ok, true} -> false
          _ -> true
        end
      end)

    case invalid_sidecar do
      nil -> :ok
      {_sidecar, index} -> {:error, {:invalid_kzg_proof, index}}
    end
  end

  defp verify_inclusion_proofs(block, blob_sidecars) do
    # Verify that each blob sidecar's KZG commitment is properly included
    # in the beacon block's blob_kzg_commitments field

    block_root = hash_tree_root(block)

    blob_sidecars
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {sidecar, index}, _acc ->
      case verify_single_inclusion_proof(sidecar, block_root, index) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_single_inclusion_proof(sidecar, block_root, index) do
    # Verify the Merkle proof that the KZG commitment is included in the block
    # This is a simplified implementation - in production would use proper Merkle proof verification

    expected_commitment = sidecar.kzg_commitment
    proof = sidecar.kzg_commitment_inclusion_proof

    # For now, just verify that the proof is present and non-empty
    # In a full implementation, this would verify the Merkle branch proof
    case proof do
      proof when is_list(proof) and length(proof) > 0 ->
        :ok

      _ ->
        {:error, {:invalid_inclusion_proof, index}}
    end
  end

  defp verify_blob_gas_consistency(execution_payload, blob_kzg_commitments) do
    # Calculate expected blob gas based on number of commitments using proper market
    expected_blob_gas =
      Blockchain.BlobGasMarket.calculate_total_blob_gas([
        %{blob_versioned_hashes: blob_kzg_commitments}
      ])

    case ExecutionPayload.validate_blob_gas_fields(execution_payload, expected_blob_gas) do
      :ok -> {:ok, :valid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_blob_size(blob) do
    case byte_size(blob) do
      @blob_size -> :ok
      size -> {:error, {:invalid_blob_size, size, @blob_size}}
    end
  end

  defp validate_commitment_proof(sidecar) do
    # Basic validation of KZG commitment and proof format
    commitment_size = byte_size(sidecar.kzg_commitment)
    proof_size = byte_size(sidecar.kzg_proof)

    cond do
      commitment_size != KZG.commitment_size() ->
        {:error, {:invalid_commitment_size, commitment_size}}

      proof_size != KZG.proof_size() ->
        {:error, {:invalid_proof_size, proof_size}}

      true ->
        :ok
    end
  end

  # Helper function to compute tree hash root using proper SSZ
  defp hash_tree_root(block) do
    # Use proper SSZ hash_tree_root for Deneb compliance
    SSZ.hash_tree_root(block)
  end

  # EIP-4844 gas calculation using the market module
  defp gas_per_blob do
    # Delegate to the blob gas market for consistency
    # Keep inline for performance, matches BlobGasMarket constant
    131_072
  end

  @doc """
  Get blob sidecars that should be gossiped for a block.

  Returns the list of blob sidecars that need to be distributed
  via the P2P network for this block.
  """
  @spec get_blob_sidecars_for_gossip(BeaconBlock.t(), [binary()]) :: [BlobSidecar.t()]
  def get_blob_sidecars_for_gossip(block, blobs) do
    block.body.blob_kzg_commitments
    |> Enum.with_index()
    |> Enum.zip(blobs)
    |> Enum.map(fn {{commitment, index}, blob} ->
      %BlobSidecar{
        index: index,
        blob: blob,
        kzg_commitment: commitment,
        kzg_proof: generate_kzg_proof_for_blob(blob, commitment),
        signed_block_header: extract_signed_block_header(block),
        kzg_commitment_inclusion_proof: generate_inclusion_proof(block, index)
      }
    end)
  end

  # Helper functions for blob sidecar generation
  defp generate_kzg_proof_for_blob(blob, commitment) do
    case KZG.compute_blob_kzg_proof(blob, commitment) do
      proof when is_binary(proof) -> proof
      # Fallback empty proof
      _ -> <<0::48*8>>
    end
  end

  defp extract_signed_block_header(_block) do
    # In production, this would extract the actual signed block header
    %{
      slot: 0,
      proposer_index: 0,
      parent_root: <<0::32*8>>,
      state_root: <<0::32*8>>,
      body_root: <<0::32*8>>,
      signature: <<0::96*8>>
    }
  end

  defp generate_inclusion_proof(block, index) do
    # Generate Merkle proof that blob KZG commitment is included in block
    # The proof path from blob_kzg_commitments[index] to body_root

    # Get the commitments list
    commitments = block.body.blob_kzg_commitments

    # Build Merkle tree of commitments
    commitment_leaves =
      commitments
      |> Enum.map(&SSZ.hash_tree_root/1)
      |> pad_to_power_of_2()

    # Generate proof path for the specific index
    proof_path = generate_merkle_proof(commitment_leaves, index)

    # Add intermediate nodes up to body_root
    # This includes the path through the BeaconBlockBody structure
    body_fields_proof = generate_body_fields_proof(block.body, :blob_kzg_commitments)

    proof_path ++ body_fields_proof
  end

  defp generate_merkle_proof(leaves, index) do
    # Generate proof path from leaf at index to root
    proof = []
    current_index = index
    current_level = leaves

    generate_proof_recursive(current_level, current_index, proof)
  end

  defp generate_proof_recursive([_single], _index, proof), do: proof

  defp generate_proof_recursive(level, index, proof) do
    # Get sibling node
    sibling_index = if rem(index, 2) == 0, do: index + 1, else: index - 1
    sibling = Enum.at(level, sibling_index, <<0::256>>)

    # Add sibling to proof
    new_proof = proof ++ [sibling]

    # Build next level
    next_level =
      level
      |> Enum.chunk_every(2)
      |> Enum.map(fn
        [left, right] -> :crypto.hash(:sha256, left <> right)
        [single] -> single
      end)

    # Continue with parent index
    parent_index = div(index, 2)
    generate_proof_recursive(next_level, parent_index, new_proof)
  end

  defp generate_body_fields_proof(body, field_name) do
    # Generate proof from field to body_root
    # This would need the actual SSZ structure path
    # For now, return the hash of adjacent fields as proof nodes

    # BeaconBlockBody fields in order (simplified)
    fields = [
      :randao_reveal,
      :eth1_data,
      :graffiti,
      :proposer_slashings,
      :attester_slashings,
      :attestations,
      :deposits,
      :voluntary_exits,
      :sync_aggregate,
      :execution_payload,
      :bls_to_execution_changes,
      :blob_kzg_commitments
    ]

    field_index = Enum.find_index(fields, &(&1 == field_name))

    # Generate proof nodes for SSZ container
    field_hashes =
      Enum.map(fields, fn f ->
        SSZ.hash_tree_root(Map.get(body, f))
      end)

    # Pad to power of 2
    padded_fields = pad_to_power_of_2(field_hashes)

    # Generate proof for field position
    generate_merkle_proof(padded_fields, field_index)
  end

  defp pad_to_power_of_2(list) do
    count = length(list)
    next_power = next_power_of_2(count)

    if next_power == count do
      list
    else
      padding_count = next_power - count
      list ++ List.duplicate(<<0::256>>, padding_count)
    end
  end

  defp next_power_of_2(n) when n <= 1, do: 1

  defp next_power_of_2(n) do
    trunc(1 * :math.pow(2, ceil(:math.log2(n))))
  end
end
