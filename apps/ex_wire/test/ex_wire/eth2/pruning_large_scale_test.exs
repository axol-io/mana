defmodule ExWire.Eth2.PruningLargeScaleTest do
  use ExUnit.Case, async: false

  alias ExWire.Eth2.{
    TestDataGenerator,
    PruningManager,
    PruningStrategies,
    PruningMetrics,
    PruningConfig,
    PruningScheduler
  }

  @moduletag :large_scale
  # 5 minutes per test
  @moduletag timeout: 300_000

  # Test scales - adjust based on CI environment capabilities
  @test_scales %{
    # For CI environments with limited resources
    ci: :small,
    # For local development testing
    local: :medium,
    # For stress testing with high-end hardware
    stress: :large,
    # For comprehensive benchmarking
    benchmark: :massive
  }

  setup_all do
    # Start required services
    {:ok, _} = PruningMetrics.start_link(name: :large_scale_metrics)

    # Use stress test scale based on environment
    test_scale = get_test_scale()

    %{test_scale: test_scale}
  end

  setup %{test_scale: test_scale} do
    # Generate fresh dataset for each test
    dataset = TestDataGenerator.generate_dataset(:mainnet, test_scale)

    # Start pruning manager with test configuration
    config = get_test_configuration(test_scale)

    {:ok, manager_pid} =
      PruningManager.start_link(
        name: :"pruning_manager_#{:rand.uniform(10000)}",
        config: config
      )

    on_exit(fn ->
      if Process.alive?(manager_pid) do
        GenServer.stop(manager_pid)
      end

      cleanup_test_data()
    end)

    %{
      dataset: dataset,
      config: config,
      manager_pid: manager_pid
    }
  end

  describe "fork choice pruning at scale" do
    @tag :fork_choice
    test "prunes large fork choice stores efficiently", %{dataset: dataset, config: config} do
      fork_choice_data = dataset.fork_choice_store

      Logger.info("Testing fork choice pruning with #{map_size(fork_choice_data.blocks)} blocks")

      # Measure initial state
      initial_memory = :erlang.memory(:total)
      initial_block_count = map_size(fork_choice_data.blocks)

      # Execute fork choice pruning
      start_time = System.monotonic_time(:millisecond)

      {:ok, pruned_store, result} =
        PruningStrategies.prune_fork_choice(
          fork_choice_data,
          fork_choice_data.finalized_checkpoint,
          safety_margin_slots: 32
        )

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      # Verify pruning effectiveness
      final_block_count = map_size(pruned_store.blocks)
      blocks_pruned = initial_block_count - final_block_count
      pruning_ratio = blocks_pruned / initial_block_count

      Logger.info("Fork choice pruning completed in #{duration_ms}ms")
      Logger.info("Pruned #{blocks_pruned} blocks (#{Float.round(pruning_ratio * 100, 1)}%)")
      Logger.info("Memory freed: #{Float.round(result.memory_freed_mb, 1)} MB")

      # Performance assertions
      assert duration_ms < get_performance_threshold(:fork_choice, config)
      assert blocks_pruned > 0, "Should prune at least some blocks"
      assert pruning_ratio > 0.1, "Should prune at least 10% of blocks"
      assert final_block_count > 0, "Should retain some blocks"

      # Memory efficiency assertions
      assert result.memory_freed_mb > 0, "Should free some memory"

      # Verify pruned store integrity
      assert Map.has_key?(pruned_store, :blocks)
      assert Map.has_key?(pruned_store, :weight_cache)
      assert Map.has_key?(pruned_store, :children_cache)

      # Verify finalized blocks are retained
      finalized_root = fork_choice_data.finalized_checkpoint.root

      assert Map.has_key?(pruned_store.blocks, finalized_root),
             "Finalized block should be retained"
    end

    @tag :fork_choice
    test "handles massive fork choice stores with multiple forks", %{dataset: dataset} do
      fork_choice_data = dataset.fork_choice_store

      # Add additional complexity with more forks
      enhanced_data = add_complex_fork_structure(fork_choice_data, 1000)

      Logger.info(
        "Testing with enhanced fork structure: #{map_size(enhanced_data.blocks)} total blocks"
      )

      # Test pruning with complex fork structure
      {:ok, pruned_store, result} =
        PruningStrategies.prune_fork_choice(
          enhanced_data,
          enhanced_data.finalized_checkpoint
        )

      # Should handle complex structures efficiently
      assert result.pruned_blocks > 500, "Should prune significant number of orphaned blocks"
      assert map_size(pruned_store.blocks) > 100, "Should retain canonical chain blocks"

      # Verify no canonical blocks were incorrectly pruned
      verify_canonical_chain_integrity(pruned_store, enhanced_data.finalized_checkpoint)
    end
  end

  describe "state pruning at scale" do
    @tag :state_pruning
    test "prunes historical states efficiently", %{dataset: dataset, config: config} do
      beacon_states = dataset.beacon_states
      state_count = map_size(beacon_states.states)

      Logger.info("Testing state pruning with #{state_count} beacon states")

      # Calculate retention parameters
      # 1 day default
      retention_slots = Map.get(config, :state_retention, 7200)
      current_slot = state_count - 1
      cutoff_slot = max(0, current_slot - retention_slots)

      # Measure initial state
      initial_memory = :erlang.memory(:total)

      # Execute state pruning
      start_time = System.monotonic_time(:millisecond)

      {:ok, result} =
        PruningStrategies.prune_state_trie(
          beacon_states,
          retention_slots,
          parallel_marking: true,
          compact_after_pruning: true
        )

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      Logger.info("State pruning completed in #{duration_ms}ms")
      Logger.info("Freed #{result.freed_bytes} bytes (#{result.pruned_nodes} nodes)")
      Logger.info("Mark phase: #{result.mark_time_ms}ms, Sweep phase: #{result.sweep_time_ms}ms")

      # Performance assertions
      assert duration_ms < get_performance_threshold(:state_pruning, config)
      assert result.pruned_nodes >= 0, "Should report pruned nodes count"
      assert result.freed_bytes >= 0, "Should report freed bytes"

      # Verify phase timing is reasonable
      total_phase_time = result.mark_time_ms + result.sweep_time_ms + result.compact_time_ms
      assert total_phase_time <= duration_ms + 100, "Phase timing should be consistent"

      # Memory efficiency
      if result.freed_bytes > 0 do
        efficiency_mb_per_sec = result.freed_bytes / (1024 * 1024) / (duration_ms / 1000)
        assert efficiency_mb_per_sec > 1.0, "Should achieve at least 1 MB/s pruning rate"
      end
    end

    @tag :state_pruning
    test "handles state trie pruning with reference counting", %{dataset: dataset} do
      beacon_states = dataset.beacon_states

      # Simulate trie node references across multiple states
      Logger.info("Testing reference counting across #{map_size(beacon_states.states)} states")

      # Test with different retention policies
      retention_scenarios = [
        # Very short retention
        {1000, "aggressive"},
        # 1 day retention
        {7200, "normal"},
        # 1 week retention
        {50400, "conservative"}
      ]

      results =
        for {retention, scenario} <- retention_scenarios do
          Logger.info("Testing #{scenario} retention (#{retention} slots)")

          {:ok, result} =
            PruningStrategies.prune_state_trie(
              beacon_states,
              retention,
              parallel_marking: true
            )

          {scenario, result}
        end

      # Verify results make sense relative to each other
      aggressive_result = results |> Enum.find(&(elem(&1, 0) == "aggressive")) |> elem(1)
      conservative_result = results |> Enum.find(&(elem(&1, 0) == "conservative")) |> elem(1)

      # Aggressive pruning should free more than conservative
      assert aggressive_result.pruned_nodes >= conservative_result.pruned_nodes,
             "Aggressive pruning should prune more nodes"
    end
  end

  describe "attestation pool pruning at scale" do
    @tag :attestation_pruning
    test "prunes large attestation pools efficiently", %{dataset: dataset, config: config} do
      attestation_data = dataset.attestation_pools
      total_attestations = attestation_data.total_attestations

      Logger.info(
        "Testing attestation pruning with #{total_attestations} attestations across #{attestation_data.slots_covered} slots"
      )

      # Create mock beacon state and fork choice for testing
      current_slot = attestation_data.slots_covered - 1
      beacon_state = create_mock_beacon_state(current_slot, attestation_data.attestation_pool)
      fork_choice_store = create_mock_fork_choice_store()

      # Measure initial state
      initial_attestation_count = count_attestations_in_pool(attestation_data.attestation_pool)

      # Execute attestation pruning
      start_time = System.monotonic_time(:millisecond)

      {:ok, pruned_pool, result} =
        PruningStrategies.prune_attestation_pool(
          attestation_data.attestation_pool,
          beacon_state,
          fork_choice_store,
          aggressive: false,
          deduplicate: true
        )

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      Logger.info("Attestation pruning completed in #{duration_ms}ms")

      Logger.info(
        "Pruned #{result.total_pruned} attestations (#{Float.round(result.total_pruned / initial_attestation_count * 100, 1)}%)"
      )

      Logger.info(
        "Breakdown - Age: #{result.pruned_by_age}, Orphaned: #{result.pruned_orphaned}, Duplicates: #{result.pruned_duplicates}"
      )

      # Performance assertions
      assert duration_ms < get_performance_threshold(:attestation_pruning, config)
      assert result.total_pruned > 0, "Should prune some attestations"

      assert result.final_attestations < initial_attestation_count,
             "Should reduce total attestations"

      # Verify pruning categories
      assert result.pruned_by_age >= 0, "Should report age-based pruning"
      assert result.pruned_orphaned >= 0, "Should report orphan pruning"
      assert result.pruned_duplicates >= 0, "Should report duplicate pruning"

      # Efficiency assertions
      if duration_ms > 0 do
        attestations_per_second = result.total_pruned / (duration_ms / 1000)
        assert attestations_per_second > 1000, "Should prune at least 1000 attestations/second"
      end

      # Verify pool integrity
      assert is_map(pruned_pool), "Should return valid attestation pool"
      verify_attestation_pool_integrity(pruned_pool)
    end

    @tag :attestation_pruning
    test "handles attestation deduplication at scale", %{dataset: dataset} do
      attestation_data = dataset.attestation_pools

      # Add duplicate attestations to test deduplication
      # 15% duplicates
      duplicated_pool = add_duplicate_attestations(attestation_data.attestation_pool, 0.15)

      initial_count = count_attestations_in_pool(duplicated_pool)

      Logger.info(
        "Testing deduplication with #{initial_count} attestations (including duplicates)"
      )

      beacon_state = create_mock_beacon_state(attestation_data.slots_covered - 1, duplicated_pool)
      fork_choice_store = create_mock_fork_choice_store()

      {:ok, deduplicated_pool, result} =
        PruningStrategies.prune_attestation_pool(
          duplicated_pool,
          beacon_state,
          fork_choice_store,
          deduplicate: true
        )

      # Should find and remove duplicates
      assert result.pruned_duplicates > 0, "Should find duplicate attestations"
      duplicate_ratio = result.pruned_duplicates / initial_count
      assert duplicate_ratio >= 0.05, "Should find at least 5% duplicates"
      assert duplicate_ratio <= 0.25, "Duplicate ratio should be reasonable"

      Logger.info(
        "Deduplication removed #{result.pruned_duplicates} duplicates (#{Float.round(duplicate_ratio * 100, 1)}%)"
      )
    end
  end

  describe "comprehensive pruning scenarios" do
    @tag :comprehensive
    test "executes full pruning cycle on large dataset", %{
      dataset: dataset,
      config: config,
      manager_pid: manager_pid
    } do
      Logger.info("Testing comprehensive pruning cycle")
      Logger.info("Dataset stats: #{inspect(dataset.generation_stats)}")

      # Measure initial system state
      initial_memory = :erlang.memory(:total)

      # Execute comprehensive pruning
      start_time = System.monotonic_time(:millisecond)

      # 2 minute timeout
      result = GenServer.call(manager_pid, :prune_all, 120_000)

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      case result do
        {:ok, pruning_results} ->
          Logger.info("Comprehensive pruning completed in #{duration_ms}ms")

          # Log results for each strategy
          for {strategy, strategy_result} <- pruning_results do
            freed_mb = Map.get(strategy_result, :estimated_freed_mb, 0)
            elapsed_us = Map.get(strategy_result, :elapsed_us, 0)

            Logger.info(
              "#{strategy}: #{Float.round(freed_mb, 1)} MB freed in #{Float.round(elapsed_us / 1000, 1)}ms"
            )
          end

          # Calculate total savings
          total_freed =
            Enum.reduce(pruning_results, 0, fn {_strategy, result}, acc ->
              acc + Map.get(result, :estimated_freed_mb, 0)
            end)

          Logger.info("Total space freed: #{Float.round(total_freed, 1)} MB")

          # Performance assertions
          assert duration_ms < get_performance_threshold(:comprehensive, config)
          assert total_freed > 0, "Should free some space across all strategies"

          # Verify all strategies were executed
          expected_strategies = [:fork_choice, :attestations, :states, :blocks, :trie]
          executed_strategies = Map.keys(pruning_results)

          for strategy <- expected_strategies do
            assert strategy in executed_strategies, "Should execute #{strategy} strategy"
          end

          # Check individual strategy results
          verify_strategy_results(pruning_results, config)

        {:error, reason} ->
          flunk("Comprehensive pruning failed: #{inspect(reason)}")
      end
    end

    @tag :comprehensive
    test "maintains performance under concurrent operations", %{dataset: dataset, config: config} do
      Logger.info("Testing concurrent pruning operations")

      # Start multiple pruning managers
      manager_pids =
        for i <- 1..3 do
          {:ok, pid} =
            PruningManager.start_link(
              name: :"concurrent_manager_#{i}",
              config: config
            )

          pid
        end

      # Execute concurrent pruning operations
      tasks =
        for {pid, i} <- Enum.with_index(manager_pids, 1) do
          Task.async(fn ->
            Logger.info("Starting concurrent pruning task #{i}")

            start_time = System.monotonic_time(:millisecond)
            result = GenServer.call(pid, {:prune, :attestations}, 60_000)
            end_time = System.monotonic_time(:millisecond)

            {i, result, end_time - start_time}
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 120_000)

      # Cleanup
      for pid <- manager_pids do
        if Process.alive?(pid), do: GenServer.stop(pid)
      end

      # Verify all tasks completed successfully
      for {task_id, result, duration_ms} <- results do
        Logger.info("Concurrent task #{task_id} completed in #{duration_ms}ms")
        assert match?({:ok, _}, result), "Task #{task_id} should complete successfully"
        assert duration_ms < 60_000, "Task #{task_id} should complete within timeout"
      end

      # Check for reasonable performance under concurrency
      avg_duration = results |> Enum.map(&elem(&1, 2)) |> Enum.sum() |> div(length(results))

      assert avg_duration < get_performance_threshold(:concurrent, config),
             "Average concurrent performance should be acceptable"
    end
  end

  describe "memory and resource management" do
    @tag :memory
    test "manages memory efficiently during large-scale pruning", %{
      dataset: dataset,
      config: config
    } do
      Logger.info("Testing memory management during pruning")

      # Monitor memory usage throughout operation
      memory_samples = []

      # Start memory monitoring
      monitor_pid = spawn_link(fn -> monitor_memory_usage(self(), 1000) end)

      # Execute memory-intensive pruning operations
      {:ok, manager_pid} = PruningManager.start_link(config: config)

      try do
        # Execute multiple pruning cycles
        for cycle <- 1..3 do
          Logger.info("Executing pruning cycle #{cycle}")
          {:ok, _result} = GenServer.call(manager_pid, :prune_all, 60_000)
          # Allow memory to settle
          Process.sleep(2000)
        end

        # Stop monitoring and collect samples
        send(monitor_pid, :stop)

        memory_samples =
          receive do
            {:memory_samples, samples} -> samples
          after
            5000 -> []
          end

        # Analyze memory usage patterns
        if length(memory_samples) > 0 do
          max_memory = Enum.max(memory_samples)
          min_memory = Enum.min(memory_samples)
          memory_growth = max_memory - min_memory

          Logger.info(
            "Memory usage: #{min_memory} -> #{max_memory} bytes (growth: #{memory_growth})"
          )

          # Memory should not grow excessively
          growth_mb = memory_growth / (1024 * 1024)
          assert growth_mb < 500, "Memory growth should be less than 500MB during pruning"

          # Memory should stabilize (not continuously grow)
          if length(memory_samples) >= 10 do
            recent_samples = Enum.take(memory_samples, -5)
            early_samples = Enum.take(memory_samples, 5)
            recent_avg = Enum.sum(recent_samples) / length(recent_samples)
            early_avg = Enum.sum(early_samples) / length(early_samples)

            memory_stability_ratio = recent_avg / early_avg
            assert memory_stability_ratio < 2.0, "Memory usage should stabilize (not grow >2x)"
          end
        end
      after
        if Process.alive?(manager_pid), do: GenServer.stop(manager_pid)
        if Process.alive?(monitor_pid), do: Process.exit(monitor_pid, :kill)
      end
    end

    @tag :gc_behavior
    test "handles garbage collection effectively during pruning", %{dataset: dataset} do
      Logger.info("Testing garbage collection behavior")

      # Force garbage collection before test
      :erlang.garbage_collect()
      initial_memory = :erlang.memory(:total)

      # Execute pruning that should create garbage
      fork_choice_data = dataset.fork_choice_store

      # Run multiple pruning cycles to create garbage
      results =
        for cycle <- 1..5 do
          Logger.info("GC test cycle #{cycle}")

          # Execute pruning
          {:ok, _pruned_store, result} =
            PruningStrategies.prune_fork_choice(
              fork_choice_data,
              fork_choice_data.finalized_checkpoint
            )

          # Check memory before and after GC
          before_gc = :erlang.memory(:total)
          :erlang.garbage_collect()
          after_gc = :erlang.memory(:total)

          gc_freed = before_gc - after_gc

          Logger.info("Cycle #{cycle}: GC freed #{gc_freed} bytes")

          {cycle, result, before_gc, after_gc, gc_freed}
        end

      # Analyze GC effectiveness
      total_gc_freed = results |> Enum.map(&elem(&1, 4)) |> Enum.sum()
      avg_gc_freed = total_gc_freed / length(results)

      Logger.info(
        "Total GC freed: #{total_gc_freed} bytes, Average: #{Float.round(avg_gc_freed, 0)} bytes"
      )

      # GC should be effective (free some memory)
      assert total_gc_freed > 0, "Garbage collection should free some memory"

      # Memory shouldn't grow excessively across cycles
      final_memory = :erlang.memory(:total)
      memory_growth = final_memory - initial_memory
      growth_mb = memory_growth / (1024 * 1024)

      assert growth_mb < 100, "Memory growth should be controlled (< 100MB)"
    end
  end

  describe "performance benchmarking" do
    @tag :benchmark
    test "achieves target performance thresholds", %{dataset: dataset, config: config} do
      Logger.info("Running performance benchmark")

      # Define performance targets
      targets = %{
        fork_choice_mb_per_sec: 50.0,
        state_pruning_mb_per_sec: 20.0,
        attestation_pruning_per_sec: 10_000.0,
        overall_efficiency_mb_per_sec: 25.0
      }

      benchmark_results = %{}

      # Benchmark fork choice pruning
      Logger.info("Benchmarking fork choice pruning...")
      fork_choice_data = dataset.fork_choice_store

      start_time = System.monotonic_time(:millisecond)

      {:ok, _pruned_store, fc_result} =
        PruningStrategies.prune_fork_choice(
          fork_choice_data,
          fork_choice_data.finalized_checkpoint
        )

      fc_duration_ms = System.monotonic_time(:millisecond) - start_time

      fc_efficiency = fc_result.memory_freed_mb / (fc_duration_ms / 1000)
      benchmark_results = Map.put(benchmark_results, :fork_choice_mb_per_sec, fc_efficiency)

      Logger.info("Fork choice: #{Float.round(fc_efficiency, 1)} MB/s")

      # Benchmark attestation pruning
      Logger.info("Benchmarking attestation pruning...")
      attestation_data = dataset.attestation_pools

      beacon_state =
        create_mock_beacon_state(
          attestation_data.slots_covered - 1,
          attestation_data.attestation_pool
        )

      fork_choice_store = create_mock_fork_choice_store()

      start_time = System.monotonic_time(:millisecond)

      {:ok, _pruned_pool, att_result} =
        PruningStrategies.prune_attestation_pool(
          attestation_data.attestation_pool,
          beacon_state,
          fork_choice_store
        )

      att_duration_ms = System.monotonic_time(:millisecond) - start_time

      att_efficiency = att_result.total_pruned / (att_duration_ms / 1000)
      benchmark_results = Map.put(benchmark_results, :attestation_pruning_per_sec, att_efficiency)

      Logger.info("Attestation pruning: #{Float.round(att_efficiency, 0)} attestations/s")

      # Calculate overall efficiency
      total_mb_freed = fc_result.memory_freed_mb + att_result.estimated_freed_mb
      total_duration_ms = fc_duration_ms + att_duration_ms
      overall_efficiency = total_mb_freed / (total_duration_ms / 1000)

      benchmark_results =
        Map.put(benchmark_results, :overall_efficiency_mb_per_sec, overall_efficiency)

      Logger.info("Overall efficiency: #{Float.round(overall_efficiency, 1)} MB/s")

      # Verify against targets
      for {metric, target_value} <- targets do
        actual_value = Map.get(benchmark_results, metric, 0)

        if actual_value >= target_value do
          Logger.info("✓ #{metric}: #{Float.round(actual_value, 1)} >= #{target_value}")
        else
          Logger.warn("⚠ #{metric}: #{Float.round(actual_value, 1)} < #{target_value}")

          # For CI environments, reduce expectations
          adjusted_target =
            if get_test_scale() == :small, do: target_value * 0.5, else: target_value

          assert actual_value >= adjusted_target,
                 "#{metric} should achieve at least #{adjusted_target} (got #{Float.round(actual_value, 1)})"
        end
      end
    end
  end

  # Private helper functions

  defp get_test_scale do
    case System.get_env("PRUNING_TEST_SCALE") do
      "large" -> :large
      "massive" -> :massive
      "stress" -> :stress
      # Default to CI scale
      _ -> Map.get(@test_scales, :ci, :small)
    end
  end

  defp get_test_configuration(scale) do
    base_config = PruningConfig.get_preset(:mainnet) |> elem(1)

    # Adjust for test scale
    scale_adjustments =
      case scale do
        :small ->
          %{
            max_concurrent_pruners: 2,
            pruning_batch_size: 500
          }

        :medium ->
          %{
            max_concurrent_pruners: 3,
            pruning_batch_size: 1000
          }

        :large ->
          %{
            max_concurrent_pruners: 4,
            pruning_batch_size: 2000
          }

        :massive ->
          %{
            max_concurrent_pruners: 6,
            pruning_batch_size: 3000
          }
      end

    Map.merge(base_config, scale_adjustments)
  end

  defp get_performance_threshold(operation, config) do
    base_thresholds = %{
      # 30 seconds
      fork_choice: 30_000,
      # 60 seconds
      state_pruning: 60_000,
      # 15 seconds
      attestation_pruning: 15_000,
      # 2 minutes
      comprehensive: 120_000,
      # 45 seconds per concurrent task
      concurrent: 45_000
    }

    base_threshold = Map.get(base_thresholds, operation, 30_000)

    # Adjust for concurrent workers (more workers = higher threshold acceptable)
    worker_multiplier = Map.get(config, :max_concurrent_pruners, 2) / 2
    round(base_threshold * worker_multiplier)
  end

  defp cleanup_test_data do
    # Clean up any ETS tables or temporary files created during testing
    for table <- [:test_fork_choice, :test_states, :test_attestations] do
      if :ets.info(table) != :undefined do
        :ets.delete(table)
      end
    end
  end

  defp add_complex_fork_structure(fork_choice_data, additional_forks) do
    # Add more complex fork patterns for stress testing
    blocks = fork_choice_data.blocks

    # Create additional fork branches
    additional_blocks =
      for i <- 1..additional_forks, into: %{} do
        parent_roots = Map.keys(blocks) |> Enum.take_random(min(10, map_size(blocks)))
        parent_root = Enum.random(parent_roots)
        parent_info = Map.get(blocks, parent_root)

        fork_root = :crypto.strong_rand_bytes(32)
        fork_slot = parent_info.block.slot + :rand.uniform(10)

        fork_block = %{
          block: %{
            slot: fork_slot,
            parent_root: parent_root,
            state_root: :crypto.strong_rand_bytes(32),
            body_root: :crypto.strong_rand_bytes(32),
            proposer_index: :rand.uniform(100_000)
          },
          root: fork_root,
          weight: parent_info.weight + :rand.uniform(1000),
          invalid: false
        }

        {fork_root, fork_block}
      end

    enhanced_blocks = Map.merge(blocks, additional_blocks)

    %{fork_choice_data | blocks: enhanced_blocks}
  end

  defp verify_canonical_chain_integrity(pruned_store, finalized_checkpoint) do
    # Verify that canonical chain from genesis to finalized checkpoint is intact
    finalized_root = finalized_checkpoint.root

    # Should be able to trace back from finalized block to genesis
    assert Map.has_key?(pruned_store.blocks, finalized_root),
           "Finalized block should be present"

    # Trace parent chain
    current_root = finalized_root
    chain_length = verify_chain_loop(pruned_store, current_root, 0)

    assert chain_length > 0, "Should trace back through canonical chain"
  end

  defp count_attestations_in_pool(attestation_pool) do
    Enum.reduce(attestation_pool, 0, fn {_slot, attestations}, acc ->
      acc + length(attestations)
    end)
  end

  defp create_mock_beacon_state(current_slot, attestation_pool) do
    %{
      slot: current_slot,
      attestation_pool: attestation_pool,
      validators: [],
      finalized_checkpoint: %{
        epoch: div(current_slot - 100, 32),
        root: :crypto.strong_rand_bytes(32)
      }
    }
  end

  defp create_mock_fork_choice_store do
    %{
      blocks: %{
        :crypto.strong_rand_bytes(32) => %{
          block: %{slot: 100, parent_root: <<0::256>>}
        }
      }
    }
  end

  defp verify_attestation_pool_integrity(pool) do
    # Verify attestation pool structure
    assert is_map(pool), "Pool should be a map"

    for {slot, attestations} <- pool do
      assert is_integer(slot), "Slot should be integer"
      assert is_list(attestations), "Attestations should be list"

      for attestation <- attestations do
        assert Map.has_key?(attestation, :data), "Attestation should have data"

        assert Map.has_key?(attestation, :aggregation_bits),
               "Attestation should have aggregation bits"
      end
    end
  end

  defp add_duplicate_attestations(attestation_pool, duplicate_ratio) do
    # Add duplicate attestations to test deduplication
    attestation_pool
    |> Enum.map(fn {slot, attestations} ->
      duplicate_count = round(length(attestations) * duplicate_ratio)

      if duplicate_count > 0 and length(attestations) > 0 do
        # Pick random attestations to duplicate
        to_duplicate = Enum.take_random(attestations, min(duplicate_count, length(attestations)))
        duplicated_attestations = attestations ++ to_duplicate
        {slot, duplicated_attestations}
      else
        {slot, attestations}
      end
    end)
    |> Enum.into(%{})
  end

  defp verify_strategy_results(pruning_results, config) do
    # Verify each strategy produced reasonable results
    for {strategy, result} <- pruning_results do
      case strategy do
        :fork_choice ->
          assert Map.has_key?(result, :pruned_blocks), "Fork choice should report pruned blocks"
          assert Map.has_key?(result, :memory_freed_mb), "Fork choice should report memory freed"

        :states ->
          assert Map.has_key?(result, :cutoff_slot), "State pruning should report cutoff slot"

          assert Map.has_key?(result, :estimated_freed_mb),
                 "State pruning should report freed space"

        :attestations ->
          assert Map.has_key?(result, :pruned_attestations),
                 "Attestation pruning should report count"

          assert Map.has_key?(result, :cutoff_slot), "Attestation pruning should report cutoff"

        _ ->
          # Other strategies should have basic timing info
          assert Map.has_key?(result, :elapsed_us), "Strategy should report timing"
      end
    end
  end

  defp verify_chain_loop(_pruned_store, <<0::256>>, chain_length), do: chain_length

  defp verify_chain_loop(_pruned_store, _current_root, chain_length) when chain_length >= 10000,
    do: chain_length

  defp verify_chain_loop(pruned_store, current_root, chain_length) do
    block_info = Map.get(pruned_store.blocks, current_root)

    if block_info == nil do
      chain_length
    else
      verify_chain_loop(pruned_store, block_info.block.parent_root, chain_length + 1)
    end
  end

  defp monitor_memory_usage(parent_pid, interval_ms) do
    samples = monitor_memory_loop([], interval_ms)
    send(parent_pid, {:memory_samples, samples})
  end

  defp monitor_memory_loop(samples, interval_ms) do
    receive do
      :stop -> samples
    after
      interval_ms ->
        current_memory = :erlang.memory(:total)
        monitor_memory_loop([current_memory | samples], interval_ms)
    end
  end
end
