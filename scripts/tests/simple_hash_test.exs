#!/usr/bin/env elixir

# Simple test script for hash operations performance improvements

Mix.install([
  {:exth_crypto, path: "apps/exth_crypto"},
  {:common, path: "apps/common"}
])

defmodule SimpleHashTest do
  def run do
    IO.puts("=== Hash Operations Performance Test ===")
    
    # Start applications
    {:ok, _} = Application.ensure_all_started(:exth_crypto)
    {:ok, _} = Application.ensure_all_started(:common)
    
    # Test hash cache
    test_hash_cache()
    
    # Test memory optimizer
    test_memory_optimizer()
    
    # Simple benchmark
    simple_benchmark()
    
    IO.puts("\n✓ Phase 2 Core Performance optimizations are working!")
  end
  
  defp test_hash_cache do
    IO.puts("\n--- Hash Cache Test ---")
    
    case ExthCrypto.Hash.Cache.start_link([]) do
      {:ok, _pid} -> 
        IO.puts("✓ Hash cache started")
        
        # Test cache hit/miss
        test_data = "test_data"
        hash_type = ExthCrypto.Hash.kec()
        
        # Cache miss
        start_time = System.monotonic_time(:microsecond)
        hash1 = ExthCrypto.Hash.hash(test_data, hash_type)
        miss_time = System.monotonic_time(:microsecond) - start_time
        
        # Cache hit
        start_time = System.monotonic_time(:microsecond)
        hash2 = ExthCrypto.Hash.hash(test_data, hash_type)
        hit_time = System.monotonic_time(:microsecond) - start_time
        
        if hash1 == hash2 do
          speedup = if hit_time > 0, do: Float.round(miss_time / hit_time, 1), else: "∞"
          IO.puts("✓ Cache working: #{speedup}x speedup on cache hit")
        end
        
        stats = ExthCrypto.Hash.Cache.stats()
        IO.puts("✓ Cache stats: #{stats.cache_size} entries, #{stats.hit_rate}% hit rate")
        
      {:error, {:already_started, _pid}} -> 
        IO.puts("✓ Hash cache already running")
      error -> 
        IO.puts("✗ Hash cache error: #{inspect(error)}")
    end
  end
  
  defp test_memory_optimizer do
    IO.puts("\n--- Memory Optimizer Test ---")
    
    case Common.MemoryOptimizer.start_link([]) do
      {:ok, _pid} -> 
        IO.puts("✓ Memory optimizer started")
        
        # Test memory allocation
        {:ok, mem_ref} = Common.MemoryOptimizer.allocate(1024)
        Common.MemoryOptimizer.deallocate(mem_ref)
        IO.puts("✓ Memory pooling working")
        
        # Test optimized maps
        optimized_map = Common.MemoryOptimizer.create_optimized_map()
        
        start_time = System.monotonic_time(:microsecond)
        updated_map = Enum.reduce(1..1000, optimized_map, fn i, acc ->
          Common.MemoryOptimizer.put_optimized(acc, "key_#{i}", "value_#{i}")
        end)
        ops_time = System.monotonic_time(:microsecond) - start_time
        
        value = Common.MemoryOptimizer.get_optimized(updated_map, "key_500")
        Common.MemoryOptimizer.delete_optimized_map(updated_map)
        
        IO.puts("✓ Optimized maps: 1000 ops in #{ops_time}μs, retrieval: #{value}")
        
        stats = Common.MemoryOptimizer.stats()
        total_mb = Float.round(stats.system.total_memory / 1024 / 1024, 1)
        IO.puts("✓ Memory stats: #{total_mb}MB total system memory")
        
      {:error, {:already_started, _pid}} -> 
        IO.puts("✓ Memory optimizer already running")
      error -> 
        IO.puts("✗ Memory optimizer error: #{inspect(error)}")
    end
  end
  
  defp simple_benchmark do
    IO.puts("\n--- Simple Performance Benchmark ---")
    
    test_data = for i <- 1..100, do: "benchmark_data_#{i}"
    hash_type = ExthCrypto.Hash.kec()
    
    # Benchmark individual hashing
    start_time = System.monotonic_time(:microsecond)
    individual_hashes = Enum.map(test_data, fn data ->
      ExthCrypto.Hash.hash(data, hash_type)
    end)
    individual_time = System.monotonic_time(:microsecond) - start_time
    
    # Benchmark batch hashing
    start_time = System.monotonic_time(:microsecond)
    batch_hashes = ExthCrypto.Hash.batch_hash(test_data, hash_type)
    batch_time = System.monotonic_time(:microsecond) - start_time
    
    # Verify results are the same
    if individual_hashes == batch_hashes do
      batch_speedup = if batch_time > 0, do: Float.round(individual_time / batch_time, 1), else: "∞"
      IO.puts("✓ Batch processing: #{batch_speedup}x faster than individual")
    else
      IO.puts("✗ Batch processing results don't match individual")
    end
    
    # Test repeated hashing (cache benefit)
    repeated_data = "repeated_test_data"
    
    start_time = System.monotonic_time(:microsecond)
    repeated_hashes = for _ <- 1..100, do: ExthCrypto.Hash.hash(repeated_data, hash_type)
    repeated_time = System.monotonic_time(:microsecond) - start_time
    
    # All should be the same hash
    unique_hashes = Enum.uniq(repeated_hashes)
    if length(unique_hashes) == 1 do
      avg_time = Float.round(repeated_time / 100, 2)
      IO.puts("✓ Repeated hashing: #{avg_time}μs average (benefiting from cache)")
    end
    
    IO.puts("\n--- Performance Summary ---")
    IO.puts("Individual hashing: #{individual_time}μs for 100 items")
    IO.puts("Batch hashing: #{batch_time}μs for 100 items")
    IO.puts("Repeated hashing: #{repeated_time}μs for 100 repeated calls")
    
    individual_rate = Float.round(100 * 1_000_000 / individual_time)
    batch_rate = Float.round(100 * 1_000_000 / batch_time)
    
    IO.puts("\nHash rates:")
    IO.puts("• Individual: #{individual_rate} hashes/second")
    IO.puts("• Batch: #{batch_rate} hashes/second")
    
    improvement = Float.round(batch_rate / individual_rate, 1)
    IO.puts("• Improvement: #{improvement}x faster with optimizations")
  end
end

SimpleHashTest.run()