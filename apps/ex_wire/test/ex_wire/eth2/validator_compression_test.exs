defmodule ExWire.Eth2.ValidatorCompressionTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias ExWire.Eth2.ValidatorCompression

  @infinity_epoch 0xFFFFFFFFFFFFFFFF

  describe "compression and decompression" do
    test "compresses active validator to minimal size" do
      validator = create_active_validator()
      compressed = ValidatorCompression.compress(validator)

      # Should only have pubkey_hash and status_flags for default active validator
      assert map_size(compressed) == 2
      assert byte_size(compressed.pubkey_hash) == 8
      # Only active flag
      assert compressed.status_flags == 0b00000001

      # Memory size should be minimal
      # 8 + 1 bytes
      assert ValidatorCompression.memory_size(compressed) == 9
    end

    test "compresses exited validator with additional fields" do
      validator = create_exited_validator()
      compressed = ValidatorCompression.compress(validator)

      # Should have exit epoch stored
      assert Map.has_key?(compressed, :exit_epoch)
      assert compressed.exit_epoch == 1000
      # Exited flag set
      assert (compressed.status_flags &&& 0b00000100) != 0
    end

    test "compresses slashed validator correctly" do
      validator = create_slashed_validator()
      compressed = ValidatorCompression.compress(validator)

      # Slashed flag set
      assert (compressed.status_flags &&& 0b00000010) != 0
    end

    test "round-trip compression preserves essential data" do
      validator = create_complex_validator()
      compressed = ValidatorCompression.compress(validator)
      decompressed = ValidatorCompression.decompress(compressed, validator.pubkey)

      # Essential fields should match
      assert decompressed.pubkey == validator.pubkey
      assert decompressed.effective_balance == validator.effective_balance
      assert decompressed.slashed == validator.slashed
      assert decompressed.activation_epoch == validator.activation_epoch
      assert decompressed.exit_epoch == validator.exit_epoch
      assert decompressed.withdrawable_epoch == validator.withdrawable_epoch
    end

    test "handles non-default effective balance" do
      validator = %{create_active_validator() | effective_balance: 31_000_000_000}
      compressed = ValidatorCompression.compress(validator)

      assert Map.has_key?(compressed, :effective_balance_gwei)
      assert compressed.effective_balance_gwei == 31

      decompressed = ValidatorCompression.decompress(compressed)
      assert decompressed.effective_balance == 31_000_000_000
    end
  end

  describe "batch operations" do
    test "compresses batch of validators efficiently" do
      validators = for i <- 0..99, do: create_validator_with_index(i)
      compressed = ValidatorCompression.compress_batch(validators)

      assert length(compressed) == 100

      # Most should be minimal size
      sizes = Enum.map(compressed, &ValidatorCompression.memory_size/1)
      avg_size = Enum.sum(sizes) / length(sizes)

      # Average size should be much less than uncompressed
      # Much less than ~129 bytes uncompressed
      assert avg_size < 50
    end

    test "decompresses batch with pubkey map" do
      validators = for i <- 0..9, do: create_validator_with_index(i)
      compressed = ValidatorCompression.compress_batch(validators)

      # Create pubkey map
      pubkey_map =
        validators
        |> Enum.map(fn v -> {:binary.part(v.pubkey, 0, 8), v.pubkey} end)
        |> Map.new()

      decompressed = ValidatorCompression.decompress_batch(compressed, pubkey_map)

      assert length(decompressed) == 10

      # Verify pubkeys are correctly restored
      Enum.zip(validators, decompressed)
      |> Enum.each(fn {original, restored} ->
        assert restored.pubkey == original.pubkey
      end)
    end
  end

  describe "compression analysis" do
    test "analyzes compression efficiency" do
      # Create mixed validator set
      validators =
        [
          # 30 active validators (minimal compression)
          for(i <- 0..29, do: create_active_validator(i)),
          # 10 exited validators (medium compression)
          for(i <- 30..39, do: create_exited_validator(i)),
          # 5 slashed validators (medium compression)
          for(i <- 40..44, do: create_slashed_validator(i)),
          # 5 pending validators
          for(i <- 45..49, do: create_pending_validator(i))
        ]
        |> List.flatten()

      analysis = ValidatorCompression.analyze_compression(validators)

      assert analysis.validator_count == 50
      # Should compress to less than 30%
      assert analysis.compression_ratio < 0.3
      # Should save more than 70%
      assert analysis.savings_percent > 70

      # Check size distribution
      # Most are minimal
      assert analysis.size_distribution["minimal"] >= 30
    end

    test "compression ratio improves with more default values" do
      # All default active validators
      default_validators = for i <- 0..99, do: create_active_validator(i)
      default_analysis = ValidatorCompression.analyze_compression(default_validators)

      # Mixed validators with non-default values
      mixed_validators =
        for i <- 0..99 do
          if rem(i, 2) == 0 do
            create_active_validator(i)
          else
            %{create_active_validator(i) | effective_balance: 31_000_000_000 + i * 1_000_000_000}
          end
        end

      mixed_analysis = ValidatorCompression.analyze_compression(mixed_validators)

      # Default validators should compress better
      assert default_analysis.compression_ratio < mixed_analysis.compression_ratio
    end
  end

  describe "diff operations" do
    test "creates minimal diff between validator states" do
      old = create_active_validator()
      new = %{old | effective_balance: 31_500_000_000}

      diff = ValidatorCompression.create_diff(old, new)

      # Should only contain changed field
      assert map_size(diff) == 1
      assert diff.effective_balance_gwei == 31
    end

    test "creates diff for status change" do
      old = create_active_validator()
      new = %{old | exit_epoch: 1000}

      diff = ValidatorCompression.create_diff(old, new)

      assert Map.has_key?(diff, :exit_epoch)
      assert diff.exit_epoch == 1000
      # Status changed due to exit
      assert Map.has_key?(diff, :status_flags)
    end

    test "applies diff correctly" do
      validator = create_active_validator()

      diff = %{
        effective_balance_gwei: 31,
        exit_epoch: 1000
      }

      updated = ValidatorCompression.apply_diff(validator, diff)

      assert updated.effective_balance == 31_000_000_000
      assert updated.exit_epoch == 1000
    end
  end

  describe "specialized compression" do
    test "genesis validator compression is ultra-minimal" do
      compressed = ValidatorCompression.compress_genesis_validator(42)

      assert map_size(compressed) == 2
      assert compressed.pubkey_hash == <<42::64>>
      assert compressed.status_flags == 0b00000001
      assert ValidatorCompression.memory_size(compressed) == 9
    end

    test "mutable fields compression excludes immutable data" do
      validator = create_complex_validator()
      mutable = ValidatorCompression.compress_mutable_fields(validator)

      # Should not include pubkey_hash (immutable)
      refute Map.has_key?(mutable, :pubkey_hash)

      # Should include mutable fields
      assert Map.has_key?(mutable, :effective_balance_gwei)
      assert Map.has_key?(mutable, :status_flags)
    end
  end

  # Helper functions

  defp create_active_validator(index \\ 0) do
    %{
      pubkey: <<index::384>>,
      withdrawal_credentials: <<0::256>>,
      effective_balance: 32_000_000_000,
      slashed: false,
      activation_eligibility_epoch: 0,
      activation_epoch: 0,
      exit_epoch: @infinity_epoch,
      withdrawable_epoch: @infinity_epoch
    }
  end

  defp create_exited_validator(index \\ 0) do
    %{create_active_validator(index) | exit_epoch: 1000, withdrawable_epoch: 1256}
  end

  defp create_slashed_validator(index \\ 0) do
    %{create_active_validator(index) | slashed: true, exit_epoch: 500, withdrawable_epoch: 756}
  end

  defp create_pending_validator(index \\ 0) do
    %{
      create_active_validator(index)
      | activation_eligibility_epoch: 100,
        activation_epoch: @infinity_epoch
    }
  end

  defp create_complex_validator do
    %{
      pubkey: <<123, 45, 67, 89::376>>,
      withdrawal_credentials: <<1::256>>,
      effective_balance: 31_500_000_000,
      slashed: true,
      activation_eligibility_epoch: 10,
      activation_epoch: 15,
      exit_epoch: 2000,
      withdrawable_epoch: 2256
    }
  end

  defp create_validator_with_index(index) do
    case rem(index, 4) do
      0 -> create_active_validator(index)
      1 -> create_exited_validator(index)
      2 -> create_slashed_validator(index)
      3 -> create_pending_validator(index)
    end
  end
end
