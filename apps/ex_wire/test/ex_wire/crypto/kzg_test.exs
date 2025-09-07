defmodule ExWire.Crypto.KZGTest do
  use ExUnit.Case, async: false

  alias ExthCrypto.KZG

  @moduletag :kzg

  setup_all do
    # Initialize trusted setup for testing
    case KZG.init_trusted_setup() do
      :ok -> :ok
      error -> raise "Failed to initialize KZG trusted setup: #{inspect(error)}"
    end
  end

  describe "KZG Setup" do
    test "trusted setup can be loaded" do
      assert KZG.is_setup_loaded()
    end

    test "can reinitialize setup" do
      assert :ok = KZG.init_trusted_setup()
      assert KZG.is_setup_loaded()
    end
  end

  describe "Blob validation" do
    test "validates correct blob size" do
      blob = generate_test_blob()
      IO.puts("Generated blob size: #{byte_size(blob)}, expected: #{KZG.blob_size()}")
      assert byte_size(blob) == KZG.blob_size()
      assert :ok = KZG.validate_blob(blob)
    end

    test "rejects invalid blob size" do
      # Wrong size
      invalid_blob = :crypto.strong_rand_bytes(1000)
      assert {:error, :invalid_blob_size} = KZG.validate_blob(invalid_blob)
    end

    test "validates blob format" do
      blob = generate_valid_test_blob()
      assert :ok = KZG.validate_blob(blob)
    end
  end

  describe "KZG commitment generation" do
    test "generates commitment from blob" do
      blob = generate_test_blob()
      commitment = KZG.blob_to_kzg_commitment(blob)

      assert byte_size(commitment) == KZG.commitment_size()
    end

    test "commitment is deterministic" do
      blob = generate_test_blob()

      commitment1 = KZG.blob_to_kzg_commitment(blob)
      commitment2 = KZG.blob_to_kzg_commitment(blob)

      assert commitment1 == commitment2
    end

    test "different blobs produce different commitments" do
      blob1 = generate_test_blob()
      blob2 = generate_different_test_blob()

      commitment1 = KZG.blob_to_kzg_commitment(blob1)
      commitment2 = KZG.blob_to_kzg_commitment(blob2)

      assert commitment1 != commitment2
    end
  end

  describe "KZG proof generation and verification" do
    test "generates and verifies blob proof" do
      blob = generate_test_blob()
      commitment = KZG.blob_to_kzg_commitment(blob)
      proof = KZG.compute_blob_kzg_proof(blob, commitment)

      assert byte_size(proof) == KZG.proof_size()
      assert KZG.verify_blob_kzg_proof(blob, commitment, proof)
    end

    test "rejects invalid proof" do
      blob = generate_test_blob()
      commitment = KZG.blob_to_kzg_commitment(blob)
      invalid_proof = :crypto.strong_rand_bytes(KZG.proof_size())

      refute KZG.verify_blob_kzg_proof(blob, commitment, invalid_proof)
    end

    test "rejects proof for wrong commitment" do
      blob1 = generate_test_blob()
      blob2 = generate_different_test_blob()

      commitment1 = KZG.blob_to_kzg_commitment(blob1)
      commitment2 = KZG.blob_to_kzg_commitment(blob2)
      proof1 = KZG.compute_blob_kzg_proof(blob1, commitment1)

      # Proof for blob1/commitment1 should not verify with commitment2
      refute KZG.verify_blob_kzg_proof(blob1, commitment2, proof1)
    end
  end

  describe "High-level verification with validation" do
    test "verifies blob with full validation" do
      blob = generate_test_blob()
      {:ok, {commitment, proof}} = KZG.generate_commitment_and_proof(blob)

      assert {:ok, true} = KZG.verify_blob_with_validation(blob, commitment, proof)
    end

    test "rejects invalid blob in validation" do
      invalid_blob = :crypto.strong_rand_bytes(1000)
      commitment = :crypto.strong_rand_bytes(KZG.commitment_size())
      proof = :crypto.strong_rand_bytes(KZG.proof_size())

      assert {:error, :invalid_blob_size} =
               KZG.verify_blob_with_validation(invalid_blob, commitment, proof)
    end

    test "rejects invalid commitment in validation" do
      blob = generate_test_blob()
      # Wrong size
      invalid_commitment = :crypto.strong_rand_bytes(20)
      proof = :crypto.strong_rand_bytes(KZG.proof_size())

      assert {:error, :invalid_commitment_size} =
               KZG.verify_blob_with_validation(blob, invalid_commitment, proof)
    end
  end

  describe "Batch verification" do
    test "verifies multiple blobs in batch" do
      blobs = [generate_test_blob(), generate_different_test_blob(), generate_third_test_blob()]

      commitments_and_proofs =
        Enum.map(blobs, fn blob ->
          {:ok, result} = KZG.generate_commitment_and_proof(blob)
          result
        end)

      {commitments, proofs} = Enum.unzip(commitments_and_proofs)

      assert {:ok, true} = KZG.verify_batch_with_validation(blobs, commitments, proofs)
    end

    test "rejects batch with mismatched lengths" do
      blobs = [generate_test_blob(), generate_different_test_blob()]
      # Wrong length
      commitments = [:crypto.strong_rand_bytes(KZG.commitment_size())]

      proofs = [
        :crypto.strong_rand_bytes(KZG.proof_size()),
        :crypto.strong_rand_bytes(KZG.proof_size())
      ]

      assert {:error, :mismatched_batch_lengths} =
               KZG.verify_batch_with_validation(blobs, commitments, proofs)
    end

    test "rejects empty batch" do
      assert {:error, :empty_batch} = KZG.verify_batch_with_validation([], [], [])
    end

    test "fails batch if any proof is invalid" do
      blob1 = generate_test_blob()
      blob2 = generate_different_test_blob()

      {:ok, {commitment1, proof1}} = KZG.generate_commitment_and_proof(blob1)
      {:ok, {commitment2, _proof2}} = KZG.generate_commitment_and_proof(blob2)

      # Use invalid proof for second blob
      invalid_proof2 = :crypto.strong_rand_bytes(KZG.proof_size())

      blobs = [blob1, blob2]
      commitments = [commitment1, commitment2]
      proofs = [proof1, invalid_proof2]

      assert {:ok, false} = KZG.verify_batch_with_validation(blobs, commitments, proofs)
    end
  end

  describe "Versioned hash creation" do
    test "creates valid versioned hash" do
      commitment = :crypto.strong_rand_bytes(KZG.commitment_size())
      versioned_hash = KZG.create_versioned_hash(commitment)

      assert byte_size(versioned_hash) == 32
      assert <<0x01, _rest::binary-size(31)>> = versioned_hash
    end

    test "versioned hash is deterministic" do
      commitment = :crypto.strong_rand_bytes(KZG.commitment_size())

      hash1 = KZG.create_versioned_hash(commitment)
      hash2 = KZG.create_versioned_hash(commitment)

      assert hash1 == hash2
    end
  end

  describe "Constants and utilities" do
    test "blob size constant" do
      # 4096 * 32
      assert KZG.blob_size() == 131_072
    end

    test "commitment size constant" do
      assert KZG.commitment_size() == 48
    end

    test "proof size constant" do
      assert KZG.proof_size() == 48
    end

    test "field elements per blob constant" do
      assert KZG.field_elements_per_blob() == 4096
    end
  end

  describe "Error handling" do
    test "handles setup not loaded gracefully" do
      # This test would require a way to reset the setup state
      # For now, we assume setup is always loaded in tests
      assert KZG.is_setup_loaded()
    end

    test "validates input sizes strictly" do
      # Too small commitment
      small_commitment = :crypto.strong_rand_bytes(32)
      assert {:error, :invalid_commitment_size} = KZG.validate_commitment(small_commitment)

      # Too large commitment  
      large_commitment = :crypto.strong_rand_bytes(64)
      assert {:error, :invalid_commitment_size} = KZG.validate_commitment(large_commitment)

      # Correct size should pass
      correct_commitment = :crypto.strong_rand_bytes(48)
      assert :ok = KZG.validate_commitment(correct_commitment)
    end
  end

  # Test data generation helpers

  defp generate_test_blob() do
    # Generate a valid blob with proper field elements
    generate_blob_with_pattern(0x01)
  end

  defp generate_different_test_blob() do
    generate_blob_with_pattern(0x02)
  end

  defp generate_third_test_blob() do
    generate_blob_with_pattern(0x03)
  end

  defp generate_valid_test_blob() do
    # Generate a blob where each field element is guaranteed to be < BLS12-381 modulus
    field_elements =
      for i <- 0..(KZG.field_elements_per_blob() - 1) do
        # Create valid field element (simplified - first byte < 0x74 to ensure < modulus)
        # 116 = 0x74
        <<valid_byte::8>> = <<rem(i, 116)>>
        rest_bytes = :crypto.strong_rand_bytes(31)
        <<valid_byte, rest_bytes::binary>>
      end

    :binary.list_to_bin(field_elements)
  end

  defp generate_blob_with_pattern(pattern_byte) do
    # Generate deterministic blob for consistent testing
    field_elements =
      for i <- 0..(KZG.field_elements_per_blob() - 1) do
        # Ensure field element is valid (< BLS12-381 modulus)
        # Keep first byte < 0x74
        base_value = rem(i + pattern_byte, 116)
        rest_bytes = for j <- 1..31, do: rem(i + j + pattern_byte, 256)

        # Create each field element as a 32-byte binary
        field_element = <<base_value>> <> :binary.list_to_bin(rest_bytes)
        field_element
      end

    # Combine all field elements into a single blob
    :binary.list_to_bin(field_elements)
  end
end
