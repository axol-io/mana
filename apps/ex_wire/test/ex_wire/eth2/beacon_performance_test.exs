defmodule ExWire.Eth2.BeaconPerformanceTest do
  @moduledoc """
  Performance validation tests for Ethereum 2.0 beacon chain operations.

  Validates that our Eth2 implementation meets performance requirements for
  production deployment, especially with large validator sets.
  """

  # Performance tests should not run concurrently
  use ExUnit.Case, async: false

  alias ExWire.Eth2.BeaconState.Operations, as: BeaconStateOps
  alias ExWire.Eth2.BeaconBlock.Operations, as: BeaconBlockOps
  alias ExWire.Eth2.Attestation.Operations, as: AttestationOps
  alias ExWire.Eth2.{BeaconState, BeaconBlock, Validator}

  # Increase timeout for performance tests
  @moduletag timeout: 30_000

  describe "Beacon Chain Performance" do
    test "genesis state creation scales with validator count" do
      test_cases = [
        # 100 validators, max 50ms
        {100, 50},
        # 1000 validators, max 200ms  
        {1000, 200},
        # 4000 validators, max 500ms (realistic mainnet subset)
        {4000, 500}
      ]

      Enum.each(test_cases, fn {validator_count, max_time_ms} ->
        validators = create_test_validators(validator_count)

        {time_microseconds, genesis_state} =
          :timer.tc(fn ->
            BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)
          end)

        time_ms = div(time_microseconds, 1000)

        assert %BeaconState{} = genesis_state
        assert length(genesis_state.validators) == validator_count

        assert time_ms < max_time_ms,
               "Genesis creation for #{validator_count} validators took #{time_ms}ms, expected < #{max_time_ms}ms"
      end)
    end

    test "active validator calculation performance" do
      # Test with realistic mainnet-like validator set
      validator_count = 2000
      validators = create_test_validators(validator_count)
      genesis_state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

      # Measure active validator indices calculation
      {time_microseconds, active_indices} =
        :timer.tc(fn ->
          BeaconStateOps.get_active_validator_indices(genesis_state, 0)
        end)

      time_ms = div(time_microseconds, 1000)

      assert length(active_indices) == validator_count
      assert time_ms < 10, "Active validator calculation took #{time_ms}ms, expected < 10ms"
    end

    test "beacon block processing performance" do
      validators = create_test_validators(1000)
      genesis_state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

      beacon_block = BeaconBlockOps.new(1, 0, <<0::256>>, <<1::256>>)

      # Measure block processing time
      {time_microseconds, _result} =
        :timer.tc(fn ->
          BeaconBlockOps.process_block(genesis_state, beacon_block)
        end)

      time_ms = div(time_microseconds, 1000)

      # Block processing should be fast even with validation
      assert time_ms < 50, "Block processing took #{time_ms}ms, expected < 50ms"
    end

    test "slot processing performance" do
      validators = create_test_validators(1000)
      genesis_state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

      # Measure slot processing time
      {time_microseconds, new_state} =
        :timer.tc(fn ->
          BeaconStateOps.process_slot(genesis_state)
        end)

      time_ms = div(time_microseconds, 1000)

      assert %BeaconState{} = new_state
      assert new_state.slot == genesis_state.slot + 1
      assert time_ms < 20, "Slot processing took #{time_ms}ms, expected < 20ms"
    end

    test "epoch processing performance" do
      validators = create_test_validators(1000)
      genesis_state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

      # Set state to epoch boundary
      epoch_state = %{genesis_state | slot: 32}

      # Measure epoch processing time
      {time_microseconds, new_state} =
        :timer.tc(fn ->
          BeaconStateOps.process_epoch(epoch_state)
        end)

      time_ms = div(time_microseconds, 1000)

      assert %BeaconState{} = new_state
      # Epoch processing can be more expensive, but should still be reasonable
      assert time_ms < 100, "Epoch processing took #{time_ms}ms, expected < 100ms"
    end

    test "memory efficiency with large validator sets" do
      # Test memory usage with increasing validator counts
      test_counts = [100, 500, 1000, 2000]

      memory_measurements =
        Enum.map(test_counts, fn count ->
          # Force garbage collection before measurement
          :erlang.garbage_collect()

          initial_memory = :erlang.memory(:processes)

          validators = create_test_validators(count)

          genesis_state =
            BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

          # Ensure state is actually used
          active_count = length(BeaconStateOps.get_active_validator_indices(genesis_state, 0))
          assert active_count == count

          final_memory = :erlang.memory(:processes)
          memory_per_validator = div(final_memory - initial_memory, count)

          {count, memory_per_validator}
        end)

      # Check that memory usage is reasonable and roughly linear
      Enum.each(memory_measurements, fn {count, memory_per_validator} ->
        # Each validator should use less than 10KB on average
        assert memory_per_validator < 10_000,
               "Memory per validator (#{memory_per_validator} bytes) too high for #{count} validators"
      end)

      # Check that memory usage is roughly linear (no quadratic growth)
      [{_, mem_100}, {_, mem_500}, {_, mem_1000}, {_, mem_2000}] = memory_measurements

      # Memory per validator should not increase dramatically with scale
      max_memory = Enum.max([mem_100, mem_500, mem_1000, mem_2000])
      min_memory = Enum.min([mem_100, mem_500, mem_1000, mem_2000])

      ratio = max_memory / max(min_memory, 1)
      assert ratio < 3.0, "Memory usage not scaling linearly: ratio #{ratio}"
    end

    test "concurrent operations safety" do
      # Test that multiple operations can be performed concurrently safely
      validators = create_test_validators(500)
      genesis_state = BeaconStateOps.genesis(System.system_time(:second), validators, <<0::256>>)

      # Spawn multiple concurrent operations
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            # Each task performs different operations
            case rem(i, 3) do
              0 ->
                BeaconStateOps.get_active_validator_indices(genesis_state, 0)

              1 ->
                BeaconStateOps.get_current_epoch(genesis_state)

              2 ->
                BeaconStateOps.process_slot(genesis_state)
            end
          end)
        end

      # Wait for all tasks and verify they complete successfully
      results = Task.await_many(tasks, 5_000)

      assert length(results) == 10
      assert Enum.all?(results, fn result -> result != nil end)
    end
  end

  # Helper functions

  defp create_test_validators(count) do
    for i <- 0..(count - 1) do
      %Validator{
        # Random 48-byte pubkey
        pubkey: :crypto.strong_rand_bytes(48),
        withdrawal_credentials: :crypto.strong_rand_bytes(32),
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
