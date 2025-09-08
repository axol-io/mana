defmodule Mix.Tasks.TestProcessSpawningPerformance do
  @moduledoc """
  Performance benchmark for process spawning optimization.
  
  Tests the improvement from 0.50K ops/sec to 5K+ ops/sec target.
  
  ## Usage
  
      mix test_process_spawning_performance
      mix test_process_spawning_performance --iterations 10000
      mix test_process_spawning_performance --comparison
  """
  
  use Mix.Task
  require Logger
  
  @shortdoc "Benchmark process spawning performance improvements"
  
  @default_iterations 1000
  @default_batches 10
  @warmup_iterations 100
  
  def run(args) do
    # Start necessary applications
    Application.ensure_all_started(:ex_wire)
    
    {options, _} = OptionParser.parse!(args, 
      switches: [
        iterations: :integer,
        batches: :integer,
        comparison: :boolean,
        detailed: :boolean
      ],
      aliases: [i: :iterations, b: :batches, c: :comparison, d: :detailed]
    )
    
    iterations = Keyword.get(options, :iterations, @default_iterations)
    batches = Keyword.get(options, :batches, @default_batches)
    comparison = Keyword.get(options, :comparison, false)
    detailed = Keyword.get(options, :detailed, false)
    
    Mix.shell().info("🚀 Process Spawning Performance Benchmark")
    Mix.shell().info("Target: Improve from 0.50K to 5K+ ops/sec (10x improvement)")
    Mix.shell().info("")
    
    # Warmup
    Mix.shell().info("Warming up...")
    warmup_benchmark(div(@warmup_iterations, 10))
    
    results = %{}
    
    # Test traditional Task.async patterns
    if comparison do
      Mix.shell().info("📊 Testing traditional Task.async patterns...")
      traditional_results = benchmark_traditional_spawning(iterations, batches, detailed)
      results = Map.put(results, :traditional, traditional_results)
    end
    
    # Test optimized patterns
    Mix.shell().info("📊 Testing optimized process pooling patterns...")
    optimized_results = benchmark_optimized_spawning(iterations, batches, detailed)
    results = Map.put(results, :optimized, optimized_results)
    
    # Test P2P connection pooling
    Mix.shell().info("📊 Testing P2P connection pooling...")
    p2p_results = benchmark_p2p_connection_pooling(iterations, detailed)
    results = Map.put(results, :p2p_pooling, p2p_results)
    
    # Display comprehensive results
    display_results(results, comparison)
    
    # Check if we hit our target
    validate_performance_targets(results)
  end
  
  defp warmup_benchmark(iterations) do
    1..iterations
    |> Task.async_stream(fn _i ->
      Process.sleep(1)
      :ok
    end, max_concurrency: 10, timeout: 1000)
    |> Stream.run()
  end
  
  defp benchmark_traditional_spawning(iterations, batches, detailed) do
    Mix.shell().info("  Running #{iterations} iterations across #{batches} batches...")
    
    start_time = System.monotonic_time(:microsecond)
    memory_before = :erlang.memory(:total)
    
    results = 
      1..batches
      |> Enum.map(fn batch_num ->
        batch_start = System.monotonic_time(:microsecond)
        
        # Traditional Task.async pattern (like original code)
        batch_results = 
          1..div(iterations, batches)
          |> Enum.map(fn _i ->
            Task.async(fn ->
              # Simulate work similar to distributed operations
              :timer.sleep(1)  # Simulate network/computation delay
              {:ok, :completed}
            end)
          end)
          |> Task.await_many(5000)
        
        batch_time = System.monotonic_time(:microsecond) - batch_start
        
        if detailed do
          Mix.shell().info("    Batch #{batch_num}: #{length(batch_results)} tasks in #{Float.round(batch_time / 1000, 2)}ms")
        end
        
        {batch_time, length(batch_results)}
      end)
    
    total_time = System.monotonic_time(:microsecond) - start_time
    memory_after = :erlang.memory(:total)
    memory_used = memory_after - memory_before
    
    total_operations = Enum.sum(for {_time, count} <- results, do: count)
    ops_per_sec = (total_operations * 1_000_000) / total_time
    
    %{
      total_time: total_time,
      total_operations: total_operations,
      ops_per_sec: ops_per_sec,
      memory_used: memory_used,
      batch_results: results
    }
  end
  
  defp benchmark_optimized_spawning(iterations, batches, detailed) do
    # Start our optimized components
    {:ok, _} = ExWire.Performance.TaskPoolSupervisor.start_link()
    {:ok, _} = ExWire.Performance.SchedulerOptimizer.start_link()
    
    # Apply high-throughput optimizations
    ExWire.Performance.SchedulerOptimizer.optimize_for_high_throughput()
    
    Mix.shell().info("  Running #{iterations} iterations across #{batches} batches with optimization...")
    
    start_time = System.monotonic_time(:microsecond)
    memory_before = :erlang.memory(:total)
    
    results = 
      1..batches
      |> Enum.map(fn batch_num ->
        batch_start = System.monotonic_time(:microsecond)
        
        # Use our optimized TaskPoolSupervisor
        work_items = 1..div(iterations, batches) |> Enum.to_list()
        
        batch_results = 
          ExWire.Performance.TaskPoolSupervisor.async_batch(
            :data_processing,
            work_items,
            fn _i ->
              # Simulate work similar to distributed operations
              :timer.sleep(1)  # Simulate network/computation delay
              {:ok, :completed}
            end,
            timeout: 5000,
            ordered: false
          )
        
        batch_time = System.monotonic_time(:microsecond) - batch_start
        
        successful_results = Enum.count(batch_results, &match?({:ok, _}, &1))
        
        if detailed do
          Mix.shell().info("    Batch #{batch_num}: #{successful_results} tasks in #{Float.round(batch_time / 1000, 2)}ms")
        end
        
        {batch_time, successful_results}
      end)
    
    total_time = System.monotonic_time(:microsecond) - start_time
    memory_after = :erlang.memory(:total)
    memory_used = memory_after - memory_before
    
    total_operations = Enum.sum(for {_time, count} <- results, do: count)
    ops_per_sec = (total_operations * 1_000_000) / total_time
    
    %{
      total_time: total_time,
      total_operations: total_operations,
      ops_per_sec: ops_per_sec,
      memory_used: memory_used,
      batch_results: results
    }
  end
  
  defp benchmark_p2p_connection_pooling(iterations, detailed) do
    Mix.shell().info("  Testing P2P connection pool with #{iterations} connection attempts...")
    
    # Start P2P connection pool
    {:ok, pool_pid} = ExWire.P2P.ConnectionPool.start_link(
      pool_size: 20,
      max_overflow: 50,
      name: :benchmark_pool
    )
    
    start_time = System.monotonic_time(:microsecond)
    memory_before = :erlang.memory(:total)
    
    # Simulate P2P connection requests
    connection_results = 
      1..iterations
      |> Task.async_stream(fn i ->
        peer_info = %{host: "127.0.0.1", port: 30300 + rem(i, 100)}
        
        case ExWire.P2P.ConnectionPool.get_connection(:benchmark_pool, peer_info, 1000) do
          {:ok, _connection} -> 
            # Simulate returning connection to pool
            :ok
          
          {:error, :pool_exhausted} ->
            :pool_exhausted
          
          {:error, reason} ->
            {:connection_failed, reason}
        end
      end, 
      max_concurrency: 50, 
      timeout: 2000, 
      on_timeout: :kill_task
    )
    |> Enum.to_list()
    
    total_time = System.monotonic_time(:microsecond) - start_time
    memory_after = :erlang.memory(:total)
    memory_used = memory_after - memory_before
    
    successful_connections = Enum.count(connection_results, &match?({:ok, :ok}, &1))
    ops_per_sec = (successful_connections * 1_000_000) / total_time
    
    if detailed do
      pool_exhausted = Enum.count(connection_results, &match?({:ok, :pool_exhausted}, &1))
      Mix.shell().info("    Successful: #{successful_connections}, Pool exhausted: #{pool_exhausted}")
    end
    
    # Get pool metrics
    pool_metrics = ExWire.P2P.ConnectionPool.get_metrics(:benchmark_pool)
    
    # Clean up
    GenServer.stop(pool_pid, :normal)
    
    %{
      total_time: total_time,
      total_operations: successful_connections,
      ops_per_sec: ops_per_sec,
      memory_used: memory_used,
      pool_metrics: pool_metrics,
      connection_results: connection_results
    }
  end
  
  defp display_results(results, comparison) do
    Mix.shell().info("")
    Mix.shell().info("📈 Performance Results:")
    Mix.shell().info("=" <> String.duplicate("=", 60))
    
    if comparison and Map.has_key?(results, :traditional) do
      traditional = results.traditional
      Mix.shell().info("Traditional Task.async:")
      Mix.shell().info("  Operations/sec: #{Float.round(traditional.ops_per_sec, 0)} ops/sec")
      Mix.shell().info("  Total time: #{Float.round(traditional.total_time / 1000, 2)}ms")
      Mix.shell().info("  Memory used: #{Float.round(traditional.memory_used / 1024, 2)} KB")
      Mix.shell().info("")
    end
    
    if Map.has_key?(results, :optimized) do
      optimized = results.optimized
      Mix.shell().info("Optimized Process Pooling:")
      Mix.shell().info("  Operations/sec: #{Float.round(optimized.ops_per_sec, 0)} ops/sec")
      Mix.shell().info("  Total time: #{Float.round(optimized.total_time / 1000, 2)}ms")
      Mix.shell().info("  Memory used: #{Float.round(optimized.memory_used / 1024, 2)} KB")
      Mix.shell().info("")
      
      if comparison and Map.has_key?(results, :traditional) do
        improvement = optimized.ops_per_sec / results.traditional.ops_per_sec
        Mix.shell().info("  🎯 Improvement: #{Float.round(improvement, 1)}x faster")
        Mix.shell().info("")
      end
    end
    
    if Map.has_key?(results, :p2p_pooling) do
      p2p = results.p2p_pooling
      Mix.shell().info("P2P Connection Pooling:")
      Mix.shell().info("  Connection ops/sec: #{Float.round(p2p.ops_per_sec, 0)} ops/sec")
      Mix.shell().info("  Total time: #{Float.round(p2p.total_time / 1000, 2)}ms")
      Mix.shell().info("  Memory used: #{Float.round(p2p.memory_used / 1024, 2)} KB")
      Mix.shell().info("  Pool metrics: #{inspect(p2p.pool_metrics)}")
      Mix.shell().info("")
    end
  end
  
  defp validate_performance_targets(results) do
    Mix.shell().info("🎯 Performance Target Validation:")
    Mix.shell().info("=" <> String.duplicate("=", 40))
    
    target_ops_per_sec = 5000  # 5K ops/sec target
    baseline_ops_per_sec = 500  # 0.5K ops/sec baseline
    
    if Map.has_key?(results, :optimized) do
      optimized_perf = results.optimized.ops_per_sec
      
      cond do
        optimized_perf >= target_ops_per_sec ->
          Mix.shell().info("✅ SUCCESS: Achieved #{Float.round(optimized_perf, 0)} ops/sec (target: #{target_ops_per_sec})")
          improvement_factor = optimized_perf / baseline_ops_per_sec
          Mix.shell().info("✅ Improvement: #{Float.round(improvement_factor, 1)}x over baseline")
          
        optimized_perf >= baseline_ops_per_sec * 5 ->
          Mix.shell().info("⚠️  GOOD: Achieved #{Float.round(optimized_perf, 0)} ops/sec (5x improvement)")
          Mix.shell().info("   Still below target of #{target_ops_per_sec} ops/sec")
          
        optimized_perf > baseline_ops_per_sec ->
          improvement_factor = optimized_perf / baseline_ops_per_sec
          Mix.shell().info("⚠️  PARTIAL: #{Float.round(improvement_factor, 1)}x improvement (#{Float.round(optimized_perf, 0)} ops/sec)")
          Mix.shell().info("   Target: #{target_ops_per_sec} ops/sec")
          
        true ->
          Mix.shell().info("❌ NEEDS WORK: #{Float.round(optimized_perf, 0)} ops/sec below baseline")
      end
    end
    
    if Map.has_key?(results, :p2p_pooling) do
      p2p_perf = results.p2p_pooling.ops_per_sec
      Mix.shell().info("P2P Pooling: #{Float.round(p2p_perf, 0)} ops/sec")
    end
    
    Mix.shell().info("")
  end
end