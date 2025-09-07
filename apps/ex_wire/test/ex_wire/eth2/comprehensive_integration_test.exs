defmodule ExWire.Eth2.ComprehensiveIntegrationTest do
  @moduledoc """
  Comprehensive integration tests for the Ethereum 2.0 consensus layer.

  Tests the complete flow from genesis to finalization including:
  - Genesis state creation
  - Block production and processing
  - Attestation handling
  - Fork choice updates
  - Finalization
  - Validator management
  """

  use ExUnit.Case, async: false

  alias ExWire.Eth2.{
    BeaconState,
    BeaconBlock,
    BeaconChain,
    StateTransition,
    ForkChoiceOptimized,
    Attestation,
    ValidatorRegistryOptimized,
    Types
  }

  @validators_count 32
  @slots_per_epoch 32
  @min_attestation_inclusion_delay 1

  setup do
    # Initialize test configuration
    config = %Types.ChainConfig{
      min_genesis_active_validator_count: @validators_count,
      slots_per_epoch: @slots_per_epoch,
      min_attestation_inclusion_delay: @min_attestation_inclusion_delay,
      seconds_per_slot: 12,
      eth1_follow_distance: 2048,
      target_committee_size: 128,
      max_validators_per_committee: 2048,
      shuffle_round_count: 90,
      min_per_epoch_churn_limit: 4,
      churn_limit_quotient: 65536,
      base_rewards_per_epoch: 4,
      deposit_contract_tree_depth: 32,
      max_effective_balance: 32_000_000_000,
      ejection_balance: 16_000_000_000,
      effective_balance_increment: 1_000_000_000
    }

    {:ok, config: config}
  end

  describe "Complete Beacon Chain Flow" do
    test "processes from genesis to finalization", %{config: config} do
      # Step 1: Create genesis state
      validators = create_test_validators(@validators_count)
      {:ok, genesis_state} = BeaconState.create_genesis_state(validators, config)

      assert genesis_state.slot == 0
      assert length(genesis_state.validators) == @validators_count
      assert genesis_state.finalized_checkpoint.epoch == 0

      # Step 2: Initialize beacon chain
      {:ok, chain} = BeaconChain.init(genesis_state, config)

      # Step 3: Process blocks through multiple epochs
      final_state = process_epochs(chain, genesis_state, 3, config)

      # Verify progression
      assert final_state.slot > genesis_state.slot
      assert final_state.finalized_checkpoint.epoch > 0
    end

    test "handles attestations correctly", %{config: config} do
      validators = create_test_validators(@validators_count)
      {:ok, genesis_state} = BeaconState.create_genesis_state(validators, config)
      {:ok, chain} = BeaconChain.init(genesis_state, config)

      # Create and process attestation
      attestation = create_test_attestation(genesis_state, 1)
      {:ok, updated_chain} = BeaconChain.process_attestation(chain, attestation)

      assert updated_chain != chain
    end

    test "fork choice selects correct head", %{config: config} do
      validators = create_test_validators(@validators_count)
      {:ok, genesis_state} = BeaconState.create_genesis_state(validators, config)

      # Initialize fork choice
      {:ok, fork_choice} = ForkChoiceOptimized.init(genesis_state)

      # Create competing blocks
      block1 = create_test_block(genesis_state, 1, <<1::256>>)
      block2 = create_test_block(genesis_state, 1, <<2::256>>)

      # Process blocks
      {:ok, fc1} = ForkChoiceOptimized.on_block(fork_choice, block1, genesis_state)
      {:ok, fc2} = ForkChoiceOptimized.on_block(fc1, block2, genesis_state)

      # Get head - should pick one of the blocks
      {:ok, head} = ForkChoiceOptimized.get_head(fc2)
      assert head in [block1.hash, block2.hash]
    end

    test "validator registry operations", %{config: config} do
      # Initialize registry
      {:ok, registry} = ValidatorRegistryOptimized.init()

      # Add validators
      validators = create_test_validators(@validators_count)

      Enum.each(validators, fn v ->
        {:ok, _} = ValidatorRegistryOptimized.add_validator(registry, v)
      end)

      # Get active validators
      {:ok, active} = ValidatorRegistryOptimized.get_active_validators(registry, 0)
      assert length(active) == @validators_count

      # Test validator lookup
      {:ok, validator} = ValidatorRegistryOptimized.get_validator(registry, 0)
      assert validator != nil
    end

    test "state transition through complete epoch", %{config: config} do
      validators = create_test_validators(@validators_count)
      {:ok, genesis_state} = BeaconState.create_genesis_state(validators, config)

      # Process full epoch
      final_state =
        Enum.reduce(1..@slots_per_epoch, genesis_state, fn slot, state ->
          block = create_test_block(state, slot, <<slot::256>>)

          case StateTransition.process_block(state, block, config) do
            {:ok, new_state} -> new_state
            _ -> state
          end
        end)

      # Verify epoch transition happened
      assert BeaconState.get_current_epoch(final_state) >
               BeaconState.get_current_epoch(genesis_state)
    end
  end

  describe "Error Handling" do
    test "rejects invalid blocks", %{config: config} do
      validators = create_test_validators(@validators_count)
      {:ok, genesis_state} = BeaconState.create_genesis_state(validators, config)

      # Create block with wrong slot
      invalid_block = create_test_block(genesis_state, 100, <<1::256>>)

      result = StateTransition.process_block(genesis_state, invalid_block, config)
      assert {:error, _} = result
    end

    test "handles missing attestations gracefully", %{config: config} do
      validators = create_test_validators(@validators_count)
      {:ok, genesis_state} = BeaconState.create_genesis_state(validators, config)
      {:ok, chain} = BeaconChain.init(genesis_state, config)

      # Process empty attestation
      result = BeaconChain.process_attestation(chain, nil)
      assert {:error, _} = result
    end
  end

  describe "Performance Characteristics" do
    @tag :performance
    test "processes large validator sets efficiently", %{config: config} do
      large_validator_count = 1000
      validators = create_test_validators(large_validator_count)

      start_time = System.monotonic_time(:millisecond)
      {:ok, genesis_state} = BeaconState.create_genesis_state(validators, config)
      creation_time = System.monotonic_time(:millisecond) - start_time

      # Should create state with 1000 validators in reasonable time
      # Less than 5 seconds
      assert creation_time < 5000
      assert length(genesis_state.validators) == large_validator_count
    end

    @tag :performance
    test "fork choice scales with block count", %{config: config} do
      validators = create_test_validators(@validators_count)
      {:ok, genesis_state} = BeaconState.create_genesis_state(validators, config)
      {:ok, fork_choice} = ForkChoiceOptimized.init(genesis_state)

      # Add many blocks
      final_fc =
        Enum.reduce(1..100, fork_choice, fn i, fc ->
          block = create_test_block(genesis_state, i, <<i::256>>)
          {:ok, new_fc} = ForkChoiceOptimized.on_block(fc, block, genesis_state)
          new_fc
        end)

      # Head selection should still be fast
      start_time = System.monotonic_time(:microsecond)
      {:ok, _head} = ForkChoiceOptimized.get_head(final_fc)
      selection_time = System.monotonic_time(:microsecond) - start_time

      # Less than 1ms
      assert selection_time < 1000
    end
  end

  # Helper functions

  defp create_test_validators(count) do
    Enum.map(0..(count - 1), fn i ->
      %Types.Validator{
        pubkey: <<i::384>>,
        withdrawal_credentials: <<i::256>>,
        effective_balance: 32_000_000_000,
        slashed: false,
        activation_eligibility_epoch: 0,
        activation_epoch: 0,
        exit_epoch: :infinity,
        withdrawable_epoch: :infinity
      }
    end)
  end

  defp create_test_block(_state, slot, block_hash) do
    %BeaconBlock{
      slot: slot,
      proposer_index: rem(slot, length(state.validators)),
      parent_root: state.latest_block_header.parent_root,
      state_root: <<0::256>>,
      body: %BeaconBlock.Body{
        randao_reveal: <<0::768>>,
        eth1_data: %Types.Eth1Data{
          deposit_root: <<0::256>>,
          deposit_count: 0,
          block_hash: <<0::256>>
        },
        graffiti: <<0::256>>,
        proposer_slashings: [],
        attester_slashings: [],
        attestations: [],
        deposits: [],
        voluntary_exits: []
      },
      hash: block_hash
    }
  end

  defp create_test_attestation(_state, slot) do
    %Attestation{
      aggregation_bits: <<1::1, 0::31>>,
      data: %Attestation.Data{
        slot: slot,
        index: 0,
        beacon_block_root: state.latest_block_header.parent_root,
        source: state.current_justified_checkpoint,
        target: %Types.Checkpoint{
          epoch: BeaconState.get_current_epoch(state),
          root: <<0::256>>
        }
      },
      signature: <<0::768>>
    }
  end

  defp process_epochs(chain, initial_state, epoch_count, _config) do
    slots_to_process = epoch_count * @slots_per_epoch

    Enum.reduce(1..slots_to_process, {chain, initial_state}, fn slot, {current_chain, state} ->
      # Create block for this slot
      block = create_test_block(state, slot, <<slot::256>>)

      # Process block
      case BeaconChain.process_block(current_chain, block, config) do
        {:ok, new_chain, new_state} ->
          # Create and process attestations
          attestation = create_test_attestation(new_state, slot)
          {:ok, chain_with_attestation} = BeaconChain.process_attestation(new_chain, attestation)
          {chain_with_attestation, new_state}

        _ ->
          {current_chain, state}
      end
    end)
    # Return final state
    |> elem(1)
  end
end
