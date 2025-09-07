defmodule Mix.Tasks.TestHashPerformance do
  @moduledoc """
  Test hash performance optimizations implemented in Phase 2.
  
  Usage:
    mix test_hash_performance --iterations 1000
    mix test_hash_performance --comparison
  """
  
  use Mix.Task
  require Logger
  
  @shortdoc "Test hash performance optimizations"
  
  def run(args) do
    {opts, _, _} = OptionParser.parse(args,
      switches: [iterations: :integer, comparison: :boolean, help: :boolean],
      aliases: [i: :iterations, c: :comparison, h: :help]
    )
    
    if opts[:help] do
      show_help()
      return
    end
    
    iterations = opts[:iterations] || 1000
    comparison = opts[:comparison] || false
    
    # Start applications
    {:ok, _} = Application.ensure_all_started(:exth_crypto)
    {:ok, _} = Application.ensure_all_started(:common)
    
    Logger.info("Testing hash performance optimizations with #{iterations} iterations")
    
    if comparison do
      run_comparison_tests(iterations)
    else
      run_performance_tests(iterations)
    end
  end
  
  defp show_help do
    IO.puts("""
    Hash Performance Testing for Mana Ethereum Client
    
    Options:
      --iterations, -i    Number of iterations for tests (default: 1000)
      --comparison, -c    Run comparison between optimized and baseline
      --help, -h         Show this help
    
    Examples:
      mix test_hash_performance --iterations 5000
      mix test_hash_performance --comparison
    """)
  end
  
  defp run_performance_tests(iterations) do
    Logger.info("=== Hash Performance Tests ===")
    
    # Test 1: Hash Cache Performance
    test_hash_cache_performance(iterations)
    
    # Test 2: Batch Processing Performance
    test_batch_processing_performance(iterations)
    
    # Test 3: Memory Optimization Performance  
    test_memory_optimization_performance(iterations)
    
    # Test 4: Overall System Performance
    test_overall_performance(iterations)
    
    Logger.info("=== Hash Performance Tests Complete ===")
  end
  
  defp run_comparison_tests(iterations) do
    Logger.info("=== Hash Performance Comparison ===")
    
    # Generate test data
    test_data = for i <- 1..iterations, do: "test_hash_data_#{i}_#{System.unique_integer()}"
    repeated_data = "repeated_test_data"
    
    # Baseline: Direct hash without optimizations
    Logger.info("Running baseline tests...")
    
    baseline_individual_time = measure_time(fn ->
      Enum.each(test_data, fn data ->
        ExthCrypto.Hash.Keccak.kec(data)
      end)
    end)
    
    baseline_repeated_time = measure_time(fn ->
      Enum.each(1..iterations, fn _ ->
        ExthCrypto.Hash.Keccak.kec(repeated_data)
      end)
    end)
    
    # Optimized: Using cache and batch processing
    Logger.info("Running optimized tests...")
    
    # Start optimizations
    {:ok, _} = ExthCrypto.Hash.Cache.start_link([])
    {:ok, _} = Common.MemoryOptimizer.start_link([])
    
    optimized_individual_time = measure_time(fn ->
      Enum.each(test_data, fn data ->
        ExthCrypto.Hash.hash(data, ExthCrypto.Hash.kec())
      end)
    end)
    
    optimized_batch_time = measure_time(fn ->
      ExthCrypto.Hash.batch_hash(test_data, ExthCrypto.Hash.kec())
    end)
    
    optimized_repeated_time = measure_time(fn ->
      Enum.each(1..iterations, fn _ ->
        ExthCrypto.Hash.hash(repeated_data, ExthCrypto.Hash.kec())
      end)
    end)
    
    # Calculate improvements
    individual_improvement = baseline_individual_time / optimized_individual_time
    batch_improvement = baseline_individual_time / optimized_batch_time
    repeated_improvement = baseline_repeated_time / optimized_repeated_time
    
    # Report results
    Logger.info("=== Performance Comparison Results ===")
    Logger.info("Iterations: #{iterations}")
    Logger.info("")
    Logger.info("Individual Hash Operations:")
    Logger.info("  Baseline: #{baseline_individual_time}ms")
    Logger.info("  Optimized: #{optimized_individual_time}ms")
    Logger.info("  Improvement: #{Float.round(individual_improvement, 2)}x faster")
    Logger.info("")
    Logger.info("Batch Hash Operations:")
    Logger.info("  Baseline: #{baseline_individual_time}ms")
    Logger.info("  Optimized Batch: #{optimized_batch_time}ms")
    Logger.info("  Improvement: #{Float.round(batch_improvement, 2)}x faster")
    Logger.info("")
    Logger.info("Repeated Hash Operations (Cache Benefit):")
    Logger.info("  Baseline: #{baseline_repeated_time}ms")
    Logger.info("  Optimized: #{optimized_repeated_time}ms")
    Logger.info("  Improvement: #{Float.round(repeated_improvement, 2)}x faster")
    Logger.info("")
    
    # Calculate hash rates
    baseline_rate = Float.round(iterations * 1000 / baseline_individual_time)
    optimized_rate = Float.round(iterations * 1000 / optimized_individual_time)
    batch_rate = Float.round(iterations * 1000 / optimized_batch_time)
    
    Logger.info("Hash Rates:")
    Logger.info("  Baseline: #{baseline_rate} hashes/second")
    Logger.info("  Optimized Individual: #{optimized_rate} hashes/second")
    Logger.info("  Optimized Batch: #{batch_rate} hashes/second")
    Logger.info("")
    
    # Check if we met our targets
    target_improvement = 3.0  # 3x improvement target
    if individual_improvement >= target_improvement do
      Logger.info("✓ TARGET MET: Individual hash improvement (#{Float.round(individual_improvement, 2)}x >= #{target_improvement}x)")
    else
      Logger.warning("✗ Target not met: Individual hash improvement (#{Float.round(individual_improvement, 2)}x < #{target_improvement}x)")
    end
    
    if batch_improvement >= target_improvement do
      Logger.info("✓ TARGET MET: Batch hash improvement (#{Float.round(batch_improvement, 2)}x >= #{target_improvement}x)")
    else
      Logger.warning("✗ Target not met: Batch hash improvement (#{Float.round(batch_improvement, 2)}x < #{target_improvement}x)")
    end
    
    Logger.info("=== Comparison Complete ===")
  end
  
  defp test_hash_cache_performance(iterations) do
    Logger.info("--- Testing Hash Cache Performance ---")
    
    case ExthCrypto.Hash.Cache.start_link([]) do
      {:ok, _pid} -> 
        Logger.info("Hash cache started successfully")
      {:error, {:already_started, _pid}} -> 
        Logger.info("Hash cache already running")
      error -> 
        Logger.error("Failed to start hash cache: #{inspect(error)}")
        return
    end
    
    test_data = "cache_performance_test_data"
    hash_type = ExthCrypto.Hash.kec()
    
    # Measure cache miss
    miss_time = measure_time(fn ->
      ExthCrypto.Hash.hash(test_data, hash_type)
    end)
    
    # Measure cache hits
    hit_time = measure_time(fn ->
      for _ <- 1..iterations do
        ExthCrypto.Hash.hash(test_data, hash_type)
      end
    end)
    
    avg_hit_time = hit_time / iterations
    speedup = miss_time / avg_hit_time
    
    stats = ExthCrypto.Hash.Cache.stats()
    
    Logger.info("Cache Performance Results:")
    Logger.info("  Cache miss: #{miss_time}ms")
    Logger.info("  Average cache hit: #{Float.round(avg_hit_time, 4)}ms")
    Logger.info("  Cache speedup: #{Float.round(speedup, 2)}x")
    Logger.info("  Cache hit rate: #{stats.hit_rate}%")
    Logger.info("  Cache size: #{stats.cache_size} entries")
  end
  
  defp test_batch_processing_performance(iterations) do
    Logger.info("--- Testing Batch Processing Performance ---")
    
    batch_size = min(iterations, 100)
    test_data = for i <- 1..batch_size, do: "batch_test_#{i}"
    hash_type = ExthCrypto.Hash.kec()
    
    # Individual processing
    individual_time = measure_time(fn ->
      Enum.map(test_data, fn data ->
        ExthCrypto.Hash.hash(data, hash_type)
      end)
    end)
    
    # Batch processing
    batch_time = measure_time(fn ->
      ExthCrypto.Hash.batch_hash(test_data, hash_type)
    end)
    
    improvement = individual_time / batch_time
    
    Logger.info("Batch Processing Results:")
    Logger.info("  Individual processing: #{individual_time}ms for #{batch_size} items")
    Logger.info("  Batch processing: #{batch_time}ms for #{batch_size} items")
    Logger.info("  Batch improvement: #{Float.round(improvement, 2)}x faster")
  end
  
  defp test_memory_optimization_performance(iterations) do
    Logger.info("--- Testing Memory Optimization Performance ---")
    
    case Common.MemoryOptimizer.start_link([]) do
      {:ok, _pid} -> 
        Logger.info("Memory optimizer started successfully")
      {:error, {:already_started, _pid}} -> 
        Logger.info("Memory optimizer already running")
      error -> 
        Logger.error("Failed to start memory optimizer: #{inspect(error)}")
        return
    end
    
    # Test regular map vs optimized map
    test_size = min(iterations, 1000)
    
    # Regular map
    regular_time = measure_time(fn ->
      map = Enum.reduce(1..test_size, %{}, fn i, acc ->
        Map.put(acc, "key_#{i}", "value_#{i}")
      end)
      # Simulate some access
      Map.get(map, "key_#{div(test_size, 2)}")
    end)
    
    # Optimized map
    optimized_time = measure_time(fn ->
      optimized_map = Common.MemoryOptimizer.create_optimized_map()
      final_map = Enum.reduce(1..test_size, optimized_map, fn i, acc ->
        Common.MemoryOptimizer.put_optimized(acc, "key_#{i}", "value_#{i}")
      end)
      # Simulate some access
      value = Common.MemoryOptimizer.get_optimized(final_map, "key_#{div(test_size, 2)}")
      Common.MemoryOptimizer.delete_optimized_map(final_map)
      value
    end)
    
    improvement = regular_time / optimized_time
    
    stats = Common.MemoryOptimizer.stats()
    memory_mb = Float.round(stats.system.total_memory / 1024 / 1024, 1)
    
    Logger.info("Memory Optimization Results:")
    Logger.info("  Regular map operations: #{regular_time}ms for #{test_size} items")
    Logger.info("  Optimized map operations: #{optimized_time}ms for #{test_size} items")
    Logger.info("  Memory improvement: #{Float.round(improvement, 2)}x faster")
    Logger.info("  System memory usage: #{memory_mb}MB")
  end
  
  defp test_overall_performance(iterations) do
    Logger.info("--- Testing Overall System Performance ---")
    
    test_scenarios = %{
      "Mixed hash operations" => fn ->
        # Mix of individual and batch operations
        individual_data = for i <- 1..div(iterations, 4), do: "mixed_#{i}"
        batch_data = for i <- 1..div(iterations, 4), do: "batch_mixed_#{i}"
        repeated_data = "repeated_mixed"
        
        # Individual hashes
        Enum.each(individual_data, fn data ->
          ExthCrypto.Hash.hash(data, ExthCrypto.Hash.kec())
        end)
        
        # Batch hashes
        ExthCrypto.Hash.batch_hash(batch_data, ExthCrypto.Hash.kec())
        
        # Repeated hashes (cache benefit)
        Enum.each(1..div(iterations, 2), fn _ ->
          ExthCrypto.Hash.hash(repeated_data, ExthCrypto.Hash.kec())
        end)
      end,
      "Memory-intensive operations" => fn ->
        maps = for i <- 1..10 do
          map = Common.MemoryOptimizer.create_optimized_map()
          final_map = Enum.reduce(1..div(iterations, 10), map, fn j, acc ->
            Common.MemoryOptimizer.put_optimized(acc, "key_#{i}_#{j}", "value_#{i}_#{j}")
          end)
          # Cleanup
          Common.MemoryOptimizer.delete_optimized_map(final_map)
          final_map
        end
        length(maps)
      end
    }
    
    Enum.each(test_scenarios, fn {name, scenario} ->
      time = measure_time(scenario)
      rate = Float.round(iterations * 1000 / time)
      Logger.info("  #{name}: #{time}ms (#{rate} ops/second)")
    end)
    
    Logger.info("Overall system performance test completed")
  end
  
  defp measure_time(func) do
    start_time = System.monotonic_time(:millisecond)
    func.()
    System.monotonic_time(:millisecond) - start_time
  end
end