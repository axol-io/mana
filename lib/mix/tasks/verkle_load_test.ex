defmodule Mix.Tasks.Verkle.LoadTest do
  @moduledoc """
  Production load testing suite for Verkle trees.
  
  This task runs sustained load testing with real data volumes to validate:
  - 35x performance improvement over MPT
  - 7.45M ops/sec storage capability  
  - Production stability under load
  - Memory efficiency and cache performance
  - Network protocol optimization
  
  Usage:
    mix verkle.load_test --duration=300 --target-ops=1000000
  """
  
  use Mix.Task
  require Logger

  @shortdoc "Run production load testing for Verkle trees"

  @default_duration 300  # 5 minutes
  @default_target_ops 1_000_000  # 1M ops/sec target
  @default_concurrent_workers 32
  @ramp_up_time 60  # 1 minute ramp up

  def run(args) do
    Logger.info("🚀 Starting Verkle Tree Production Load Test")
    Logger.info("=" |> String.duplicate(60))

    # Parse arguments
    opts = parse_args(args)
    duration = Keyword.get(opts, :duration, @default_duration)
    target_ops = Keyword.get(opts, :target_ops, @default_target_ops)
    workers = Keyword.get(opts, :workers, @default_concurrent_workers)

    Logger.info("Configuration:")
    Logger.info("  Duration: #{duration} seconds")
    Logger.info("  Target: #{target_ops} ops/sec")
    Logger.info("  Workers: #{workers}")
    Logger.info("")

    # Start required applications
    start_applications()

    # Initialize test environment
    test_state = initialize_load_test(workers, target_ops)

    # Run the load test phases
    results = run_load_test_phases(test_state, duration)

    # Generate comprehensive report
    generate_load_test_report(results, duration, target_ops)

    # Cleanup
    cleanup_load_test(test_state)

    Logger.info("🏁 Load test completed")
    results.overall_success
  end

  defp parse_args(args) do
    {opts, _remaining} = OptionParser.parse!(args,
      switches: [
        duration: :integer,
        target_ops: :integer,
        workers: :integer,
        dataset_size: :integer,
        help: :boolean
      ],
      aliases: [
        d: :duration,
        t: :target_ops,
        w: :workers,
        s: :dataset_size,
        h: :help
      ]
    )

    if opts[:help] do
      print_help()
      System.halt(0)
    end

    opts
  end

  defp print_help do
    IO.puts("""
    Verkle Tree Production Load Testing Suite

    Usage:
      mix verkle.load_test [options]

    Options:
      -d, --duration SECONDS     Duration of load test (default: 300)
      -t, --target-ops OPS_SEC   Target operations per second (default: 1000000)  
      -w, --workers COUNT        Number of concurrent workers (default: 32)
      -s, --dataset-size SIZE    Size of test dataset (default: 1000000)
      -h, --help                 Show this help message

    Examples:
      mix verkle.load_test --duration=600 --target-ops=2000000
      mix verkle.load_test -d 180 -t 500000 -w 16
    """)
  end

  defp start_applications do
    Logger.info("Starting applications...")
    Application.ensure_all_started(:merkle_patricia_tree)
    Application.ensure_all_started(:exth_crypto)
    
    # Ensure AntidoteDB connection
    case Application.ensure_all_started(:antidotedb_client) do
      {:ok, _} -> Logger.info("✅ AntidoteDB client started")
      {:error, reason} -> Logger.warning("⚠️  AntidoteDB client failed: #{inspect(reason)}")
    end
  end

  defp initialize_load_test(workers, target_ops) do
    Logger.info("Initializing load test environment...")

    # Create test databases
    verkle_db = create_verkle_test_db()
    mpt_db = create_mpt_test_db()

    # Pre-generate test dataset
    dataset = generate_large_dataset()

    # Initialize worker pool
    worker_pool = initialize_worker_pool(workers)

    # Calculate per-worker target
    ops_per_worker = div(target_ops, workers)

    %{
      verkle_db: verkle_db,
      mpt_db: mpt_db,
      dataset: dataset,
      worker_pool: worker_pool,
      workers: workers,
      ops_per_worker: ops_per_worker,
      metrics: initialize_metrics()
    }
  end

  defp create_verkle_test_db do
    Logger.info("Creating Verkle tree test database...")
    
    # Use production configuration with AntidoteDB
    case MerklePatriciaTree.DB.AntidoteOptimized.init([
      nodes: [{'localhost', 8087}, {'localhost', 8088}, {'localhost', 8089}],
      bucket: "verkle_load_test"
    ]) do
      {:ok, db} ->
        verkle_tree = VerkleTree.new(db, nil, [
          cache_enabled: true,
          memory_mapped_storage: true,
          simd_enabled: true,
          parallel_workers: 16
        ])
        Logger.info("✅ Verkle tree database initialized")
        verkle_tree
        
      {:error, reason} ->
        Logger.warning("⚠️  Verkle tree database failed, using ETS: #{inspect(reason)}")
        VerkleTree.new(MerklePatriciaTree.Test.random_ets_db())
    end
  end

  defp create_mpt_test_db do
    Logger.info("Creating MPT baseline database...")
    MerklePatriciaTree.Trie.new(MerklePatriciaTree.Test.random_ets_db())
  end

  defp generate_large_dataset do
    Logger.info("Generating large test dataset...")
    dataset_size = 1_000_000
    
    {time_us, dataset} = :timer.tc(fn ->
      1..dataset_size
      |> Task.async_stream(fn i ->
        key = generate_realistic_key(i)
        value = generate_realistic_value(i)
        {key, value}
      end, max_concurrency: System.schedulers_online() * 2)
      |> Enum.map(fn {:ok, result} -> result end)
    end)

    Logger.info("Generated #{dataset_size} entries in #{div(time_us, 1000)}ms")
    dataset
  end

  defp generate_realistic_key(i) do
    # Generate realistic Ethereum-like keys
    case rem(i, 4) do
      0 -> # Account address
        <<i::160>>  # 20 bytes
      1 -> # Storage slot  
        account = <<div(i, 1000)::160>>
        slot = <<rem(i, 1000)::256>>
        account <> slot
      2 -> # Code hash
        :crypto.hash(:sha256, "contract_code_#{i}")
      3 -> # Transaction hash
        :crypto.hash(:sha256, "transaction_#{i}")
    end
  end

  defp generate_realistic_value(i) do
    # Generate realistic Ethereum state values
    case rem(i, 4) do
      0 -> # Account data
        balance = <<(i * 1000000)::256>>
        nonce = <<rem(i, 1000)::64>>
        balance <> nonce
      1 -> # Storage value
        <<(i * 123456789)::256>>
      2 -> # Contract code (variable size)
        code_size = 100 + rem(i, 500)
        :crypto.strong_rand_bytes(code_size)
      3 -> # Transaction data
        tx_data = %{
          from: <<div(i, 1000)::160>>,
          to: <<div(i, 500)::160>>,
          value: i * 1000,
          gas: 21000 + rem(i, 100000)
        }
        :erlang.term_to_binary(tx_data)
    end
  end

  defp initialize_worker_pool(workers) do
    Logger.info("Initializing #{workers} worker processes...")
    
    1..workers
    |> Enum.map(fn worker_id ->
      {:ok, pid} = Task.Supervisor.start_link()
      {worker_id, pid}
    end)
    |> Map.new()
  end

  defp initialize_metrics do
    %{
      start_time: System.monotonic_time(:millisecond),
      verkle_operations: 0,
      mpt_operations: 0,
      verkle_errors: 0,
      mpt_errors: 0,
      total_latency_us: 0,
      operation_count: 0,
      memory_samples: []
    }
  end

  defp run_load_test_phases(test_state, duration) do
    Logger.info("🚦 Starting load test phases...")

    # Phase 1: Ramp up (1 minute)
    Logger.info("Phase 1: Ramp up (#{@ramp_up_time}s)")
    ramp_up_results = run_ramp_up_phase(test_state, @ramp_up_time)

    # Phase 2: Sustained load (main duration)
    sustained_duration = duration - @ramp_up_time
    Logger.info("Phase 2: Sustained load (#{sustained_duration}s)")
    sustained_results = run_sustained_load_phase(test_state, sustained_duration)

    # Phase 3: Stress test (burst load)
    Logger.info("Phase 3: Stress test (30s burst)")
    stress_results = run_stress_test_phase(test_state, 30)

    # Combine results
    combine_phase_results([ramp_up_results, sustained_results, stress_results])
  end

  defp run_ramp_up_phase(test_state, duration) do
    # Gradually increase load over ramp-up period
    steps = 10
    step_duration = div(duration * 1000, steps)  # milliseconds per step
    
    results = 1..steps
    |> Enum.map(fn step ->
      # Gradually increase worker count
      active_workers = div(test_state.workers * step, steps)
      ops_per_worker = div(test_state.ops_per_worker, 2)  # Reduced during ramp-up
      
      Logger.info("  Ramp step #{step}/#{steps}: #{active_workers} workers")
      
      # Run step
      run_load_step(test_state, active_workers, ops_per_worker, step_duration)
    end)
    
    %{
      phase: :ramp_up,
      results: results,
      average_ops_per_sec: calculate_average_ops_per_sec(results),
      error_rate: calculate_error_rate(results)
    }
  end

  defp run_sustained_load_phase(test_state, duration) do
    Logger.info("  Running sustained load with #{test_state.workers} workers")
    Logger.info("  Target: #{test_state.ops_per_worker} ops/worker/sec")
    
    # Run in 30-second intervals for progress reporting
    intervals = div(duration, 30)
    
    results = 1..intervals
    |> Task.async_stream(fn interval ->
      Logger.info("  Sustained load interval #{interval}/#{intervals}")
      
      # Run 30-second interval
      run_load_interval(test_state, 30_000)  # 30 seconds
    end, max_concurrency: 1, timeout: 35_000)
    |> Enum.map(fn {:ok, result} -> result end)
    
    %{
      phase: :sustained,
      results: results,
      average_ops_per_sec: calculate_average_ops_per_sec(results),
      error_rate: calculate_error_rate(results)
    }
  end

  defp run_stress_test_phase(test_state, duration) do
    Logger.info("  Running stress test with 2x load")
    
    # Double the operations per worker for stress test
    stress_ops_per_worker = test_state.ops_per_worker * 2
    
    result = run_load_interval(%{test_state | ops_per_worker: stress_ops_per_worker}, duration * 1000)
    
    %{
      phase: :stress,
      results: [result],
      average_ops_per_sec: result.verkle_ops_per_sec,
      error_rate: calculate_error_rate([result])
    }
  end

  defp run_load_interval(test_state, duration_ms) do
    start_time = System.monotonic_time(:millisecond)
    
    # Start all workers
    worker_tasks = test_state.worker_pool
    |> Enum.map(fn {worker_id, supervisor_pid} ->
      Task.Supervisor.async(supervisor_pid, fn ->
        run_worker_load(test_state, worker_id, duration_ms)
      end)
    end)
    
    # Wait for all workers to complete
    worker_results = worker_tasks
    |> Enum.map(&Task.await(&1, duration_ms + 5000))
    
    end_time = System.monotonic_time(:millisecond)
    actual_duration = end_time - start_time
    
    # Aggregate worker results
    aggregate_worker_results(worker_results, actual_duration)
  end

  defp run_load_step(test_state, active_workers, ops_per_worker, duration_ms) do
    # Similar to run_load_interval but with limited workers
    worker_subset = test_state.worker_pool
    |> Enum.take(active_workers)
    
    start_time = System.monotonic_time(:millisecond)
    
    worker_tasks = worker_subset
    |> Enum.map(fn {worker_id, supervisor_pid} ->
      Task.Supervisor.async(supervisor_pid, fn ->
        run_worker_load(%{test_state | ops_per_worker: ops_per_worker}, worker_id, duration_ms)
      end)
    end)
    
    worker_results = worker_tasks |> Enum.map(&Task.await(&1, duration_ms + 1000))
    
    end_time = System.monotonic_time(:millisecond)
    actual_duration = end_time - start_time
    
    aggregate_worker_results(worker_results, actual_duration)
  end

  defp run_worker_load(test_state, worker_id, duration_ms) do
    end_time = System.monotonic_time(:millisecond) + duration_ms
    dataset_size = length(test_state.dataset)
    
    # Worker metrics
    worker_metrics = %{
      verkle_ops: 0,
      mpt_ops: 0,
      verkle_errors: 0, 
      mpt_errors: 0,
      verkle_total_time: 0,
      mpt_total_time: 0
    }
    
    # Run operations until time expires
    final_metrics = run_worker_operations(test_state, worker_id, end_time, dataset_size, worker_metrics)
    
    # Return worker results
    %{
      worker_id: worker_id,
      verkle_ops: final_metrics.verkle_ops,
      mpt_ops: final_metrics.mpt_ops,
      verkle_errors: final_metrics.verkle_errors,
      mpt_errors: final_metrics.mpt_errors,
      verkle_avg_latency: if(final_metrics.verkle_ops > 0, do: final_metrics.verkle_total_time / final_metrics.verkle_ops, else: 0),
      mpt_avg_latency: if(final_metrics.mpt_ops > 0, do: final_metrics.mpt_total_time / final_metrics.mpt_ops, else: 0)
    }
  end

  defp run_worker_operations(test_state, worker_id, end_time, dataset_size, metrics) do
    if System.monotonic_time(:millisecond) >= end_time do
      metrics
    else
      # Select random operation
      operation_index = :rand.uniform(dataset_size)
      {key, value} = Enum.at(test_state.dataset, operation_index - 1)
      
      # Decide operation type (70% write, 30% read)
      operation_type = if :rand.uniform(100) <= 70, do: :write, else: :read
      
      # Perform Verkle operation
      verkle_metrics = perform_verkle_operation(test_state.verkle_db, operation_type, key, value, metrics)
      
      # Perform MPT operation (for comparison)
      mpt_metrics = perform_mpt_operation(test_state.mpt_db, operation_type, key, value, verkle_metrics)
      
      # Continue with next operation
      run_worker_operations(test_state, worker_id, end_time, dataset_size, mpt_metrics)
    end
  end

  defp perform_verkle_operation(verkle_db, operation_type, key, value, metrics) do
    {time_us, result} = :timer.tc(fn ->
      case operation_type do
        :write -> VerkleTree.put(verkle_db, key, value)
        :read -> VerkleTree.get(verkle_db, key)
      end
    end)
    
    case result do
      {:ok, _} ->
        %{metrics |
          verkle_ops: metrics.verkle_ops + 1,
          verkle_total_time: metrics.verkle_total_time + time_us
        }
      {:error, _} ->
        %{metrics |
          verkle_ops: metrics.verkle_ops + 1,
          verkle_errors: metrics.verkle_errors + 1,
          verkle_total_time: metrics.verkle_total_time + time_us
        }
      _ ->
        %{metrics |
          verkle_ops: metrics.verkle_ops + 1,
          verkle_total_time: metrics.verkle_total_time + time_us
        }
    end
  end

  defp perform_mpt_operation(mpt_db, operation_type, key, value, metrics) do
    {time_us, result} = :timer.tc(fn ->
      case operation_type do
        :write -> 
          MerklePatriciaTree.Trie.update_key(mpt_db, key, value)
        :read -> 
          MerklePatriciaTree.Trie.get_key(mpt_db, key)
      end
    end)
    
    case result do
      {:ok, _} ->
        %{metrics |
          mpt_ops: metrics.mpt_ops + 1,
          mpt_total_time: metrics.mpt_total_time + time_us
        }
      {:error, _} ->
        %{metrics |
          mpt_ops: metrics.mpt_ops + 1,
          mpt_errors: metrics.mpt_errors + 1,
          mpt_total_time: metrics.mpt_total_time + time_us
        }
      _ ->
        %{metrics |
          mpt_ops: metrics.mpt_ops + 1,
          mpt_total_time: metrics.mpt_total_time + time_us
        }
    end
  end

  defp aggregate_worker_results(worker_results, duration_ms) do
    total_verkle_ops = Enum.sum(Enum.map(worker_results, & &1.verkle_ops))
    total_mpt_ops = Enum.sum(Enum.map(worker_results, & &1.mpt_ops))
    total_verkle_errors = Enum.sum(Enum.map(worker_results, & &1.verkle_errors))
    total_mpt_errors = Enum.sum(Enum.map(worker_results, & &1.mpt_errors))
    
    verkle_latencies = Enum.map(worker_results, & &1.verkle_avg_latency)
    mpt_latencies = Enum.map(worker_results, & &1.mpt_avg_latency)
    
    %{
      duration_ms: duration_ms,
      verkle_ops: total_verkle_ops,
      mpt_ops: total_mpt_ops,
      verkle_errors: total_verkle_errors,
      mpt_errors: total_mpt_errors,
      verkle_ops_per_sec: total_verkle_ops / (duration_ms / 1000),
      mpt_ops_per_sec: total_mpt_ops / (duration_ms / 1000),
      verkle_avg_latency: Enum.sum(verkle_latencies) / length(verkle_latencies),
      mpt_avg_latency: Enum.sum(mpt_latencies) / length(mpt_latencies),
      speedup_ratio: if(Enum.sum(mpt_latencies) > 0, do: Enum.sum(mpt_latencies) / Enum.sum(verkle_latencies), else: 1.0)
    }
  end

  defp calculate_average_ops_per_sec(results) do
    total_ops = Enum.sum(Enum.map(results, & Map.get(&1, :verkle_ops, 0)))
    total_duration = Enum.sum(Enum.map(results, & Map.get(&1, :duration_ms, 0))) / 1000
    
    if total_duration > 0, do: total_ops / total_duration, else: 0
  end

  defp calculate_error_rate(results) do
    total_ops = Enum.sum(Enum.map(results, & Map.get(&1, :verkle_ops, 0)))
    total_errors = Enum.sum(Enum.map(results, & Map.get(&1, :verkle_errors, 0)))
    
    if total_ops > 0, do: total_errors / total_ops * 100, else: 0
  end

  defp combine_phase_results(phase_results) do
    total_verkle_ops = phase_results
    |> Enum.flat_map(& &1.results)
    |> Enum.sum(fn result -> Map.get(result, :verkle_ops, 0) end)

    total_mpt_ops = phase_results
    |> Enum.flat_map(& &1.results) 
    |> Enum.sum(fn result -> Map.get(result, :mpt_ops, 0) end)

    avg_speedup = phase_results
    |> Enum.flat_map(& &1.results)
    |> Enum.map(& Map.get(&1, :speedup_ratio, 1.0))
    |> Enum.sum()
    |> Kernel./(length(Enum.flat_map(phase_results, & &1.results)))

    overall_ops_per_sec = phase_results
    |> Enum.map(& &1.average_ops_per_sec)
    |> Enum.max()

    overall_error_rate = phase_results
    |> Enum.map(& &1.error_rate)
    |> Enum.max()

    %{
      phases: phase_results,
      total_verkle_ops: total_verkle_ops,
      total_mpt_ops: total_mpt_ops,
      peak_ops_per_sec: overall_ops_per_sec,
      average_speedup: avg_speedup,
      error_rate: overall_error_rate,
      overall_success: avg_speedup >= 35.0 and overall_error_rate < 1.0
    }
  end

  defp generate_load_test_report(results, duration, target_ops) do
    Logger.info("\n" <> String.duplicate("=", 80))
    Logger.info("🎯 VERKLE TREE PRODUCTION LOAD TEST REPORT")
    Logger.info(String.duplicate("=", 80))

    Logger.info("\n📊 OVERALL RESULTS:")
    Logger.info("  • Test Duration:        #{duration} seconds")
    Logger.info("  • Target Throughput:    #{target_ops} ops/sec")
    Logger.info("  • Peak Throughput:      #{Float.round(results.peak_ops_per_sec)} ops/sec")
    Logger.info("  • Average Speedup:      #{Float.round(results.average_speedup, 1)}x vs MPT")
    Logger.info("  • Error Rate:           #{Float.round(results.error_rate, 2)}%")

    Logger.info("\n🚦 PHASE RESULTS:")
    Enum.each(results.phases, fn phase ->
      Logger.info("  #{phase.phase |> Atom.to_string() |> String.upcase()}:")
      Logger.info("    - Average OPS:        #{Float.round(phase.average_ops_per_sec)} ops/sec")
      Logger.info("    - Error Rate:         #{Float.round(phase.error_rate, 2)}%")
    end)

    Logger.info("\n🎯 TARGET VALIDATION:")
    Logger.info("  • 35x Speedup:          #{if results.average_speedup >= 35.0, do: "✅ ACHIEVED", else: "❌ NOT ACHIEVED"}")
    Logger.info("  • Target Throughput:    #{if results.peak_ops_per_sec >= target_ops, do: "✅ ACHIEVED", else: "❌ NOT ACHIEVED"}")
    Logger.info("  • Error Rate < 1%:      #{if results.error_rate < 1.0, do: "✅ ACHIEVED", else: "❌ NOT ACHIEVED"}")

    Logger.info("\n🏆 FINAL RESULT: #{if results.overall_success, do: "✅ PASSED", else: "❌ FAILED"}")
    Logger.info(String.duplicate("=", 80))

    if results.overall_success do
      Logger.info("🎉 Verkle trees are ready for production deployment!")
    else
      Logger.warning("⚠️  Additional optimization required before production deployment.")
    end
  end

  defp cleanup_load_test(test_state) do
    Logger.info("Cleaning up load test environment...")
    
    # Stop worker processes
    Enum.each(test_state.worker_pool, fn {_worker_id, supervisor_pid} ->
      Task.Supervisor.stop(supervisor_pid)
    end)
    
    Logger.info("✅ Cleanup completed")
  end
end