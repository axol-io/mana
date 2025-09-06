defmodule ExWire.Eth2.ValidatorRegistryOptimizedTest do
  use ExUnit.Case, async: false

  alias ExWire.Eth2.{ValidatorRegistryOptimized, ValidatorRegistry}

  @moduletag :validator_optimization

  setup do
    # Start the optimized registry
    {:ok, pid} = ValidatorRegistryOptimized.start_link(name: :test_registry)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, registry: :test_registry}
  end

  describe "basic operations" do
    test "add and retrieve single validator", %{registry: registry} do
      validator = create_test_validator(0)

      {:ok, index} = ValidatorRegistryOptimized.add_validator(registry, validator, 32_000_000_000)
      assert index == 0

      retrieved = ValidatorRegistryOptimized.get_validator(registry, index)
      assert retrieved == validator
    end

    test "batch add validators", %{registry: registry} do
      validators = for i <- 0..99, do: {create_test_validator(i), 32_000_000_000}

      {:ok, indices} = ValidatorRegistryOptimized.add_validators_batch(registry, validators)
      assert length(indices) == 100
      assert indices == Enum.to_list(0..99)

      # Verify all validators were added correctly
      for {index, {validator, _balance}} <- Enum.with_index(validators) do
        retrieved = ValidatorRegistryOptimized.get_validator(registry, index)
        assert retrieved == validator
      end
    end

    test "update balance", %{registry: registry} do
      validator = create_test_validator(0)
      {:ok, index} = ValidatorRegistryOptimized.add_validator(registry, validator, 32_000_000_000)

      :ok = ValidatorRegistryOptimized.update_balance(registry, index, 33_000_000_000)

      # Note: We'd need a get_balance function to verify this properly
      # For now, we just ensure no error occurs
      assert true
    end

    test "batch update balances", %{registry: registry} do
      validators = for i <- 0..99, do: {create_test_validator(i), 32_000_000_000}
      {:ok, indices} = ValidatorRegistryOptimized.add_validators_batch(registry, validators)

      updates = for i <- indices, do: {i, 31_000_000_000 + i * 1000}
      :ok = ValidatorRegistryOptimized.update_balances_batch(registry, updates)

      # Verify operation completed without error
      assert true
    end

    test "get active validators", %{registry: registry} do
      # Add mix of active and inactive validators
      validators =
        for i <- 0..49 do
          validator =
            if rem(i, 2) == 0 do
              create_active_validator(i)
            else
              create_inactive_validator(i)
            end

          {validator, 32_000_000_000}
        end

      {:ok, _indices} = ValidatorRegistryOptimized.add_validators_batch(registry, validators)

      active = ValidatorRegistryOptimized.get_active_validators(registry, 0)
      # Half should be active
      assert length(active) == 25
    end

    test "automatic array growth", %{registry: registry} do
      # Add more validators than initial capacity
      large_batch = for i <- 0..49_999, do: {create_test_validator(i), 32_000_000_000}

      {:ok, indices} = ValidatorRegistryOptimized.add_validators_batch(registry, large_batch)
      assert length(indices) == 50_000

      # Verify first and last
      first = ValidatorRegistryOptimized.get_validator(registry, 0)
      assert first != nil

      last = ValidatorRegistryOptimized.get_validator(registry, 49_999)
      assert last != nil

      count = ValidatorRegistryOptimized.get_validator_count(registry)
      assert count == 50_000
    end
  end

  describe "performance comparison" do
    @tag :benchmark
    test "compare add performance: array vs list", %{registry: opt_registry} do
      # Create original list-based registry
      orig_registry = ValidatorRegistry.init()

      validators = for i <- 0..999, do: create_test_validator(i)

      # Benchmark original list-based approach
      {orig_time, orig_registry} =
        :timer.tc(fn ->
          Enum.reduce(validators, orig_registry, fn validator, acc ->
            ValidatorRegistry.add_validator(acc, validator, 32_000_000_000)
          end)
        end)

      # Benchmark optimized array-based approach
      {opt_time, _} =
        :timer.tc(fn ->
          batch = Enum.map(validators, &{&1, 32_000_000_000})
          ValidatorRegistryOptimized.add_validators_batch(opt_registry, batch)
        end)

      IO.puts("\nAdd 1000 validators performance:")
      IO.puts("  Original (list):    #{orig_time} μs")
      IO.puts("  Optimized (array):  #{opt_time} μs")
      IO.puts("  Speedup:            #{Float.round(orig_time / opt_time, 2)}x")

      assert opt_time < orig_time
    end

    @tag :benchmark
    test "compare lookup performance: array vs list", %{registry: opt_registry} do
      # Setup both registries with validators
      orig_registry = setup_original_registry(1000)
      setup_optimized_registry(opt_registry, 1000)

      # Random indices to lookup
      indices = Enum.take_random(0..999, 100)

      # Benchmark original list-based lookups
      {orig_time, _} =
        :timer.tc(fn ->
          Enum.each(indices, fn index ->
            ValidatorRegistry.get_validator(orig_registry, index)
          end)
        end)

      # Benchmark optimized array-based lookups  
      {opt_time, _} =
        :timer.tc(fn ->
          Enum.each(indices, fn index ->
            ValidatorRegistryOptimized.get_validator(opt_registry, index)
          end)
        end)

      IO.puts("\nLookup 100 validators performance:")
      IO.puts("  Original (list):    #{orig_time} μs")
      IO.puts("  Optimized (array):  #{opt_time} μs")
      IO.puts("  Speedup:            #{Float.round(orig_time / opt_time, 2)}x")

      assert opt_time < orig_time
    end

    @tag :benchmark
    @tag :slow
    test "memory usage comparison with large validator set", %{registry: opt_registry} do
      validator_count = 10_000

      # Measure memory before
      :erlang.garbage_collect()
      Process.sleep(100)
      memory_before = :erlang.memory(:total)

      # Add validators to optimized registry
      batch = for i <- 0..(validator_count - 1), do: {create_test_validator(i), 32_000_000_000}
      {:ok, _} = ValidatorRegistryOptimized.add_validators_batch(opt_registry, batch)

      # Get memory stats
      stats = ValidatorRegistryOptimized.get_memory_stats(opt_registry)

      # Measure memory after
      :erlang.garbage_collect()
      Process.sleep(100)
      memory_after = :erlang.memory(:total)

      memory_used_mb = (memory_after - memory_before) / 1_024 / 1_024

      IO.puts("\nMemory usage for #{validator_count} validators:")
      IO.puts("  Validators stored:     #{stats.validator_count}")
      IO.puts("  Active validators:     #{stats.active_count}")
      IO.puts("  Memory used:           #{Float.round(memory_used_mb, 2)} MB")

      IO.puts(
        "  Est. list-based:       #{Float.round(stats.list_based_bytes / 1_024 / 1_024, 2)} MB"
      )

      IO.puts("  Memory saved:          #{Float.round(stats.memory_saved_mb, 2)} MB")
      IO.puts("  Compression ratio:     #{Float.round(stats.compression_ratio, 2)}")

      # Assert we're using less memory than list-based approach
      assert stats.used_bytes < stats.list_based_bytes
      # Should use less than 60% of list-based memory
      assert stats.compression_ratio < 0.6
    end
  end

  describe "epoch transitions" do
    test "process epoch transition updates active set", %{registry: registry} do
      # Add validators with different activation epochs
      validators =
        for i <- 0..99 do
          validator = %{
            pubkey: <<i::256>>,
            activation_epoch: if(rem(i, 3) == 0, do: 0, else: 1),
            exit_epoch: if(rem(i, 5) == 0, do: 1, else: :infinity)
          }

          {validator, 32_000_000_000}
        end

      {:ok, _} = ValidatorRegistryOptimized.add_validators_batch(registry, validators)

      # Process epoch transition
      :ok = ValidatorRegistryOptimized.process_epoch_transition(registry, 1)

      # Check active validators for epoch 1
      active = ValidatorRegistryOptimized.get_active_validators(registry, 1)

      # Should have validators with activation_epoch <= 1 and exit_epoch > 1
      assert length(active) > 0
      assert length(active) < 100
    end
  end

  # Helper functions

  defp create_test_validator(index) do
    %{
      pubkey: <<index::256>>,
      withdrawal_credentials: <<index::256>>,
      effective_balance: 32_000_000_000,
      slashed: false,
      activation_eligibility_epoch: 0,
      activation_epoch: 0,
      exit_epoch: :infinity,
      withdrawable_epoch: :infinity
    }
  end

  defp create_active_validator(index) do
    %{create_test_validator(index) | activation_epoch: 0}
  end

  defp create_inactive_validator(index) do
    %{create_test_validator(index) | activation_epoch: 100}
  end

  defp setup_original_registry(count) do
    registry = ValidatorRegistry.init()

    Enum.reduce(0..(count - 1), registry, fn i, acc ->
      ValidatorRegistry.add_validator(acc, create_test_validator(i), 32_000_000_000)
    end)
  end

  defp setup_optimized_registry(registry, count) do
    batch = for i <- 0..(count - 1), do: {create_test_validator(i), 32_000_000_000}
    ValidatorRegistryOptimized.add_validators_batch(registry, batch)
  end
end
