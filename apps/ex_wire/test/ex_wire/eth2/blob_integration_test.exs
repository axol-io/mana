defmodule ExWire.Eth2.BlobIntegrationTest do
  use ExUnit.Case

  alias ExWire.Eth2.{BeaconChain, BlobVerification, BlobSidecar}
  alias ExthCrypto.KZG

  describe "blob verification integration" do
    setup do
      # Initialize KZG trusted setup
      {g1_bytes, g2_bytes} = generate_test_trusted_setup()
      KZG.load_trusted_setup_from_bytes(g1_bytes, g2_bytes)

      # Use unique name per test to avoid conflicts
      test_name = :"test_beacon_chain_#{System.unique_integer([:positive])}"
      {:ok, beacon_chain} = BeaconChain.start_link(name: test_name)

      # Initialize with genesis state
      genesis_block = create_test_genesis_block()
      genesis_state_root = :crypto.hash(:sha256, "genesis_state")

      :ok = GenServer.call(test_name, {:initialize, genesis_state_root, genesis_block})

      %{beacon_chain: beacon_chain, beacon_chain_name: test_name}
    end

    test "processes block with valid blob sidecars", %{beacon_chain_name: beacon_chain_name} do
      # Create a test block with blob commitments
      block = create_test_block_with_blobs()
      signed_block = %{message: block, signature: <<0::96*8>>}

      # Create corresponding blob sidecars
      blob_sidecars = create_test_blob_sidecars(block)

      # Process block with blob sidecars
      result =
        GenServer.call(
          beacon_chain_name,
          {:process_block_with_blobs, signed_block, blob_sidecars}
        )

      assert result == :ok
    end

    test "rejects block with invalid blob sidecars", %{beacon_chain_name: beacon_chain_name} do
      # Create a test block with blob commitments
      block = create_test_block_with_blobs()
      signed_block = %{message: block, signature: <<0::96*8>>}

      # Create invalid blob sidecars (wrong commitment)
      invalid_blob_sidecars = create_invalid_blob_sidecars()

      # Process block with invalid blob sidecars should fail
      result =
        GenServer.call(
          beacon_chain_name,
          {:process_block_with_blobs, signed_block, invalid_blob_sidecars}
        )

      assert {:error, _reason} = result
    end

    test "validates blob sidecar for gossip", %{beacon_chain_name: beacon_chain_name} do
      # Create valid blob sidecar
      blob_sidecar = create_valid_blob_sidecar()

      # Should accept valid blob sidecar
      result = GenServer.call(beacon_chain_name, {:process_blob_sidecar, blob_sidecar})

      assert result == :ok
    end

    test "rejects invalid blob sidecar for gossip", %{beacon_chain_name: beacon_chain_name} do
      # Create invalid blob sidecar (wrong size)
      invalid_blob_sidecar = create_invalid_blob_sidecar()

      # Should reject invalid blob sidecar
      result = GenServer.call(beacon_chain_name, {:process_blob_sidecar, invalid_blob_sidecar})

      assert {:error, _reason} = result
    end
  end

  # Helper functions for test data generation

  defp generate_test_trusted_setup do
    # Generate minimal trusted setup for testing
    # In production, this would be the official Ethereum trusted setup
    g1_points = for _ <- 1..4096, do: <<0::48*8>>
    g2_points = for _ <- 1..65, do: <<0::96*8>>

    g1_bytes = Enum.join(g1_points)
    g2_bytes = Enum.join(g2_points)

    {g1_bytes, g2_bytes}
  end

  defp create_test_genesis_block do
    %{
      slot: 0,
      proposer_index: 0,
      parent_root: <<0::32*8>>,
      state_root: <<0::32*8>>,
      body: %{
        randao_reveal: <<0::96*8>>,
        eth1_data: %{
          deposit_root: <<0::32*8>>,
          deposit_count: 0,
          block_hash: <<0::32*8>>
        },
        graffiti: <<0::32*8>>,
        proposer_slashings: [],
        attester_slashings: [],
        attestations: [],
        deposits: [],
        voluntary_exits: [],
        sync_aggregate: %{
          sync_committee_bits: <<0::512>>,
          sync_committee_signature: <<0::96*8>>
        },
        execution_payload: %{
          parent_hash: <<0::32*8>>,
          fee_recipient: <<0::20*8>>,
          state_root: <<0::32*8>>,
          receipts_root: <<0::32*8>>,
          logs_bloom: <<0::256*8>>,
          prev_randao: <<0::32*8>>,
          block_number: 0,
          gas_limit: 30_000_000,
          gas_used: 0,
          timestamp: System.system_time(:second),
          extra_data: <<>>,
          base_fee_per_gas: 1_000_000_000,
          block_hash: <<0::32*8>>,
          transactions: [],
          withdrawals: [],
          blob_gas_used: 0,
          excess_blob_gas: 0
        },
        bls_to_execution_changes: [],
        blob_kzg_commitments: []
      }
    }
  end

  defp create_test_block_with_blobs do
    # Create test blob
    blob = generate_test_blob()
    commitment = KZG.blob_to_kzg_commitment(blob)

    %{
      slot: 1,
      proposer_index: 0,
      parent_root: <<0::32*8>>,
      state_root: <<0::32*8>>,
      body: %{
        randao_reveal: <<0::96*8>>,
        eth1_data: %{
          deposit_root: <<0::32*8>>,
          deposit_count: 0,
          block_hash: <<0::32*8>>
        },
        graffiti: <<0::32*8>>,
        proposer_slashings: [],
        attester_slashings: [],
        attestations: [],
        deposits: [],
        voluntary_exits: [],
        sync_aggregate: %{
          sync_committee_bits: <<0::512>>,
          sync_committee_signature: <<0::96*8>>
        },
        execution_payload: %{
          parent_hash: <<0::32*8>>,
          fee_recipient: <<0::20*8>>,
          state_root: <<0::32*8>>,
          receipts_root: <<0::32*8>>,
          logs_bloom: <<0::256*8>>,
          prev_randao: <<0::32*8>>,
          block_number: 1,
          gas_limit: 30_000_000,
          gas_used: 0,
          timestamp: System.system_time(:second),
          extra_data: <<>>,
          base_fee_per_gas: 1_000_000_000,
          block_hash: <<0::32*8>>,
          transactions: [],
          withdrawals: [],
          # One blob worth of gas
          blob_gas_used: 131_072,
          excess_blob_gas: 0
        },
        bls_to_execution_changes: [],
        blob_kzg_commitments: [commitment]
      }
    }
  end

  defp create_test_blob_sidecars(block) do
    blob = generate_test_blob()
    commitment = hd(block.body.blob_kzg_commitments)
    proof = KZG.compute_blob_kzg_proof(blob, commitment)

    [
      %BlobSidecar{
        index: 0,
        blob: blob,
        kzg_commitment: commitment,
        kzg_proof: proof,
        signed_block_header: %{
          block_root: :crypto.hash(:sha256, "test_block"),
          slot: block.slot,
          proposer_index: block.proposer_index,
          parent_root: block.parent_root,
          state_root: block.state_root,
          body_root: :crypto.hash(:sha256, "test_body")
        },
        kzg_commitment_inclusion_proof: [<<0::32*8>>, <<0::32*8>>, <<0::32*8>>]
      }
    ]
  end

  defp create_invalid_blob_sidecars do
    blob = generate_test_blob()
    # Use wrong commitment (commitment for different blob)
    wrong_blob = generate_different_test_blob()
    wrong_commitment = KZG.blob_to_kzg_commitment(wrong_blob)
    proof = KZG.compute_blob_kzg_proof(blob, wrong_commitment)

    [
      %BlobSidecar{
        index: 0,
        blob: blob,
        kzg_commitment: wrong_commitment,
        kzg_proof: proof,
        signed_block_header: %{
          block_root: :crypto.hash(:sha256, "test_block"),
          slot: 1,
          proposer_index: 0,
          parent_root: <<0::32*8>>,
          state_root: <<0::32*8>>,
          body_root: :crypto.hash(:sha256, "test_body")
        },
        kzg_commitment_inclusion_proof: [<<0::32*8>>, <<0::32*8>>, <<0::32*8>>]
      }
    ]
  end

  defp create_valid_blob_sidecar do
    blob = generate_test_blob()
    commitment = KZG.blob_to_kzg_commitment(blob)
    proof = KZG.compute_blob_kzg_proof(blob, commitment)

    %BlobSidecar{
      index: 0,
      blob: blob,
      kzg_commitment: commitment,
      kzg_proof: proof,
      signed_block_header: %{
        block_root: :crypto.hash(:sha256, "test_block"),
        slot: 1,
        proposer_index: 0,
        parent_root: <<0::32*8>>,
        state_root: <<0::32*8>>,
        body_root: :crypto.hash(:sha256, "test_body")
      },
      kzg_commitment_inclusion_proof: [<<0::32*8>>, <<0::32*8>>, <<0::32*8>>]
    }
  end

  defp create_invalid_blob_sidecar do
    # Create blob with wrong size
    # Too small
    invalid_blob = <<1, 2, 3, 4, 5>>
    # Invalid commitment
    commitment = <<0::48*8>>
    # Invalid proof
    proof = <<0::48*8>>

    %BlobSidecar{
      index: 0,
      blob: invalid_blob,
      kzg_commitment: commitment,
      kzg_proof: proof,
      signed_block_header: %{
        block_root: :crypto.hash(:sha256, "test_block"),
        slot: 1,
        proposer_index: 0,
        parent_root: <<0::32*8>>,
        state_root: <<0::32*8>>,
        body_root: :crypto.hash(:sha256, "test_body")
      },
      kzg_commitment_inclusion_proof: [<<0::32*8>>, <<0::32*8>>, <<0::32*8>>]
    }
  end

  defp generate_test_blob do
    # Generate deterministic test blob (131072 bytes)
    blob_size = 131_072
    pattern = Stream.cycle([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])

    pattern
    |> Stream.take(blob_size)
    |> Enum.map(& &1)
    |> :binary.list_to_bin()
  end

  defp generate_different_test_blob do
    # Generate different deterministic test blob (131072 bytes)
    blob_size = 131_072
    pattern = Stream.cycle([16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1])

    pattern
    |> Stream.take(blob_size)
    |> Enum.map(& &1)
    |> :binary.list_to_bin()
  end
end
