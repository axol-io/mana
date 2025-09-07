#!/usr/bin/env elixir

# Simple performance test script that works with current compilation state

defmodule PerformanceTest do
  def run() do
    IO.puts("\n========================================")
    IO.puts("Mana-Ethereum Performance Test Suite")
    IO.puts("========================================\n")
    
    # Test 1: Hash Performance
    test_hash_performance()
    
    # Test 2: Memory Operations
    test_memory_operations()
    
    # Test 3: Process Spawning
    test_process_spawning()
    
    IO.puts("\n========================================")
    IO.puts("Performance Test Complete")
    IO.puts("========================================")
  end
  
  defp test_hash_performance() do
    IO.puts("1. Hash Operation Performance Test")
    IO.puts("-----------------------------------")
    
    data = :crypto.strong_rand_bytes(1024)
    iterations = 100_000
    
    # Test Keccak hash performance using crypto library
    start_time = System.monotonic_time(:microsecond)
    for _ <- 1..iterations do
      :crypto.hash(:sha256, data)
    end
    elapsed = System.monotonic_time(:microsecond) - start_time
    
    ops_per_sec = iterations * 1_000_000 / elapsed
    IO.puts("   SHA256: #{Float.round(ops_per_sec, 2)} ops/sec")
    IO.puts("   Time per op: #{Float.round(elapsed / iterations, 2)} μs")
    
    # Test SHA3 performance
    start_time = System.monotonic_time(:microsecond)
    for _ <- 1..iterations do
      :crypto.hash(:sha3_256, data)
    end
    elapsed = System.monotonic_time(:microsecond) - start_time
    
    ops_per_sec = iterations * 1_000_000 / elapsed
    IO.puts("   SHA3-256: #{Float.round(ops_per_sec, 2)} ops/sec")
    IO.puts("   Time per op: #{Float.round(elapsed / iterations, 2)} μs\n")
  end
  
  defp test_memory_operations() do
    IO.puts("2. Memory Operations Test")
    IO.puts("-------------------------")
    
    # Test Map operations
    iterations = 100_000
    map = %{}
    
    # Insert performance
    start_time = System.monotonic_time(:microsecond)
    final_map = Enum.reduce(1..iterations, map, fn i, acc ->
      Map.put(acc, "key_#{i}", :crypto.strong_rand_bytes(32))
    end)
    elapsed = System.monotonic_time(:microsecond) - start_time
    
    ops_per_sec = iterations * 1_000_000 / elapsed
    IO.puts("   Map Insert: #{Float.round(ops_per_sec, 2)} ops/sec")
    
    # Lookup performance
    keys = Enum.map(1..1000, fn i -> "key_#{i}" end)
    start_time = System.monotonic_time(:microsecond)
    for _ <- 1..iterations do
      key = Enum.random(keys)
      Map.get(final_map, key)
    end
    elapsed = System.monotonic_time(:microsecond) - start_time
    
    ops_per_sec = iterations * 1_000_000 / elapsed
    IO.puts("   Map Lookup: #{Float.round(ops_per_sec, 2)} ops/sec")
    
    # ETS table performance
    :ets.new(:perf_test, [:set, :public, :named_table])
    
    start_time = System.monotonic_time(:microsecond)
    for i <- 1..iterations do
      :ets.insert(:perf_test, {"ets_key_#{i}", :crypto.strong_rand_bytes(32)})
    end
    elapsed = System.monotonic_time(:microsecond) - start_time
    
    ops_per_sec = iterations * 1_000_000 / elapsed
    IO.puts("   ETS Insert: #{Float.round(ops_per_sec, 2)} ops/sec")
    
    :ets.delete(:perf_test)
    IO.puts("")
  end
  
  defp test_process_spawning() do
    IO.puts("3. Process Spawning Performance")
    IO.puts("--------------------------------")
    
    iterations = 10_000
    
    # Test basic process spawning
    start_time = System.monotonic_time(:microsecond)
    pids = for _ <- 1..iterations do
      spawn(fn -> :ok end)
    end
    elapsed = System.monotonic_time(:microsecond) - start_time
    
    ops_per_sec = iterations * 1_000_000 / elapsed
    IO.puts("   Basic Spawn: #{Float.round(ops_per_sec, 2)} processes/sec")
    
    # Test Task.async
    start_time = System.monotonic_time(:microsecond)
    tasks = for _ <- 1..min(iterations, 1000) do
      Task.async(fn -> :crypto.strong_rand_bytes(32) end)
    end
    results = Task.await_many(tasks)
    elapsed = System.monotonic_time(:microsecond) - start_time
    
    task_count = length(tasks)
    ops_per_sec = task_count * 1_000_000 / elapsed
    IO.puts("   Task.async: #{Float.round(ops_per_sec, 2)} tasks/sec")
    
    # Test GenServer calls
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    
    start_time = System.monotonic_time(:microsecond)
    for _ <- 1..iterations do
      Agent.get(pid, & &1)
    end
    elapsed = System.monotonic_time(:microsecond) - start_time
    
    Agent.stop(pid)
    
    ops_per_sec = iterations * 1_000_000 / elapsed
    IO.puts("   GenServer calls: #{Float.round(ops_per_sec, 2)} calls/sec\n")
  end
end

# Run the performance test
PerformanceTest.run()