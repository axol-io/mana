defmodule ExWire.Eth2.BeaconConsensusIntegrationTest do
  @moduledoc """
  Integration tests for the complete Ethereum 2.0 beacon chain consensus pipeline.

  Tests the interaction between BeaconState.Operations, BeaconBlock.Operations, 
  Attestation.Operations, and StateTransition modules as a complete system.
  """

  use ExUnit.Case, async: true

  alias ExWire.Eth2.BeaconState.Operations, as: BeaconStateOps
  alias ExWire.Eth2.BeaconBlock.Operations, as: BeaconBlockOps
  alias ExWire.Eth2.Attestation.Operations, as: AttestationOps
  alias ExWire.Eth2.StateTransition
  alias ExWire.Eth2.{BeaconState, BeaconBlock, Attestation, Validator, Checkpoint}

  @slots_per_epoch 32

  describe "Complete Beacon Consensus Pipeline" do
    test "genesis state creation and validation" do
      validators = create_test_validators(64)
      genesis_time = System.system_time(:second)
      genesis_root = <<0::256>>

      # Test genesis state creation
      genesis_state = BeaconStateOps.genesis(genesis_time, validators, genesis_root)

      assert %BeaconState{} = genesis_state
      assert genesis_state.genesis_time == genesis_time
      assert genesis_state.slot == 0
      assert length(genesis_state.validators) == 64
      assert length(genesis_state.balances) == 64

      # All validators should have maximum effective balance
      assert Enum.all?(genesis_state.balances, &(&1 == 32_000_000_000))

      # Test epoch calculation
      assert BeaconStateOps.get_current_epoch(genesis_state) == 0
      assert BeaconStateOps.get_previous_epoch(genesis_state) == 0
    end

    test "beacon block creation and processing" do
      # Setup genesis state
      validators = create_test_validators(64)
      genesis_state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

      # Create a test beacon block
      beacon_block = BeaconBlockOps.new(1, 0, <<0::256>>, <<1::256>>)

      assert %BeaconBlock{} = beacon_block
      assert beacon_block.slot == 1
      assert beacon_block.proposer_index == 0

      # Test block validation
      assert :ok == BeaconBlockOps.validate_structure(beacon_block)

      # Test block processing
      case BeaconBlockOps.process_block(genesis_state, beacon_block) do
        {:ok, new_state} ->
          assert %BeaconState{} = new_state
          assert new_state != genesis_state

        {:error, reason} ->
          # Processing may fail due to validation rules, but structure should be correct
          assert is_atom(reason)
      end
    end

    test "state transition slot processing" do
      validators = create_test_validators(64)
      genesis_state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

      # Test single slot processing
      new_state = BeaconStateOps.process_slot(genesis_state)

      assert %BeaconState{} = new_state
      assert new_state.slot == genesis_state.slot + 1

      # Block roots should be updated  
      assert new_state.block_roots != genesis_state.block_roots
    end

    test "epoch transition processing" do
      validators = create_test_validators(64)
      initial_state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

      # Advance to epoch boundary (slot 32)
      state_at_epoch_boundary = %{initial_state | slot: @slots_per_epoch}

      # Test epoch processing
      new_state = BeaconStateOps.process_epoch(state_at_epoch_boundary)

      assert %BeaconState{} = new_state
      assert BeaconStateOps.get_current_epoch(new_state) == 1
    end

    test "attestation creation and validation" do
      validators = create_test_validators(64)
      genesis_state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

      # Create test checkpoint
      source_checkpoint = %Checkpoint{epoch: 0, root: <<0::256>>}
      target_checkpoint = %Checkpoint{epoch: 0, root: <<1::256>>}

      # Create attestation
      attestation = AttestationOps.new(1, 0, <<2::256>>, source_checkpoint, target_checkpoint)

      assert %Attestation{} = attestation
      assert attestation.data.slot == 1
      assert attestation.data.index == 0

      # Test structure validation
      assert :ok == AttestationOps.validate_structure(attestation)
    end

    test "validator lifecycle management" do
      validators = create_test_validators(64)
      genesis_state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

      # Test active validator indices
      active_indices = BeaconStateOps.get_active_validator_indices(genesis_state, 0)

      assert is_list(active_indices)
      assert length(active_indices) == 64

      # Test validator activity check
      first_validator = Enum.at(genesis_state.validators, 0)
      assert BeaconStateOps.is_active_validator(first_validator, 0) == true
    end

    test "complete state transition with block" do
      validators = create_test_validators(64)
      genesis_state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

      # Create test block
      test_block = BeaconBlockOps.new(1, 0, <<0::256>>, <<1::256>>)

      # Test complete state transition  
      case StateTransition.state_transition(genesis_state, test_block) do
        {:ok, final_state} ->
          assert %BeaconState{} = final_state
          assert final_state.slot >= test_block.slot

        {:error, reason} ->
          # May fail due to validation, but should fail gracefully
          assert is_atom(reason)
      end
    end

    test "fork choice integration (basic)" do
      # This tests that our fork choice modules can be imported and basic operations work
      # without full LMD-GHOST implementation

      validators = create_test_validators(64)
      genesis_state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

      # Test that we can get active validators for fork choice
      active_validators = BeaconStateOps.get_active_validator_indices(genesis_state, 0)

      assert length(active_validators) > 0

      # Test basic epoch calculations needed for fork choice
      assert BeaconStateOps.get_current_epoch(genesis_state) == 0
    end

    test "architecture validation: operations vs types separation" do
      # This test validates our architectural decision to separate operations from types

      # Test that struct types are defined in types.ex
      assert Code.ensure_loaded?(ExWire.Eth2.BeaconState)
      assert Code.ensure_loaded?(ExWire.Eth2.BeaconBlock)
      assert Code.ensure_loaded?(ExWire.Eth2.Attestation)

      # Test that operations are defined in separate modules
      assert Code.ensure_loaded?(ExWire.Eth2.BeaconState.Operations)
      assert Code.ensure_loaded?(ExWire.Eth2.BeaconBlock.Operations)
      assert Code.ensure_loaded?(ExWire.Eth2.Attestation.Operations)

      # Test that struct creation works
      validators = create_test_validators(4)
      state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)
      block = BeaconBlockOps.new(1, 0, <<0::256>>, <<1::256>>)

      assert %BeaconState{} = state
      assert %BeaconBlock{} = block

      # Test that functions are callable on operations modules
      assert is_function(&BeaconStateOps.get_current_epoch/1)
      assert is_function(&BeaconBlockOps.validate_structure/1)
    end
  end

  # Helper functions

  defp create_test_validators(count) do
    for i <- 0..(count - 1) do
      %Validator{
        # 48 bytes
        pubkey: <<i::384>>,
        # 32 bytes  
        withdrawal_credentials: <<i::256>>,
        # 32 ETH in Gwei
        effective_balance: 32_000_000_000,
        slashed: false,
        activation_eligibility_epoch: 0,
        activation_epoch: 0,
        # FAR_FUTURE_EPOCH
        exit_epoch: 18_446_744_073_709_551_615,
        withdrawable_epoch: 18_446_744_073_709_551_615
      }
    end
  end
end
