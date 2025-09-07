defmodule Blockchain.PerformanceBenchmark do
  @moduledoc """
  Performance benchmarking suite for comparing V1 and V2 module implementations.
  Measures throughput, latency, memory usage, and error rates.
  """

  alias Blockchain.TransactionPool
  alias Blockchain.SimplePool

  require Logger

  @sample_transactions 1000

  def run_full_benchmark do
    Logger.info("Starting comprehensive V1 vs V2 performance benchmark")

    results = %{
      transaction_pool: benchmark_transaction_pools(),
      memory_usage: benchmark_memory_usage(),
      error_rates: benchmark_error_handling(),
      concurrent_performance: benchmark_concurrent_operations()
    }

    generate_report(results)
    results
  end

  def benchmark_transaction_pools do
    Logger.info("Benchmarking Transaction Pool performance")

    # Generate test transactions
    transactions = generate_test_transactions(@sample_transactions)

    v1_results = benchmark_pool_implementation(:v1, transactions)
    v2_results = benchmark_pool_implementation(:v2, transactions)

    %{
      v1: v1_results,
      v2: v2_results,
      improvement: calculate_improvement(v1_results, v2_results)
    }
  end

  defp benchmark_pool_implementation(version, transactions) do
    Logger.info("Benchmarking #{version} transaction pool")

    # Start the appropriate pool
    pool_pid = start_pool(version)

    # Warmup
    warmup_transactions = Enum.take(transactions, 100)
    run_warmup(pool_pid, version, warmup_transactions)

    # Actual benchmark
    start_time = :os.system_time(:microsecond)
    memory_before = :erlang.memory(:processes)

    results = measure_pool_performance(pool_pid, version, transactions)

    end_time = :os.system_time(:microsecond)
    memory_after = :erlang.memory(:processes)

    # Cleanup
    stop_pool(pool_pid, version)

    %{
      total_time_us: end_time - start_time,
      throughput_tps: length(transactions) / ((end_time - start_time) / 1_000_000),
      memory_delta_bytes: memory_after - memory_before,
      successful_transactions: results.successful,
      failed_transactions: results.failed,
      average_latency_us: results.average_latency,
      p95_latency_us: results.p95_latency,
      p99_latency_us: results.p99_latency
    }
  end

  defp start_pool(:v1) do
    {:ok, pid} = TransactionPool.start_link([])
    pid
  end

  defp start_pool(:v2) do
    pool_name = :"benchmark_pool_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(SimplePool, [], name: pool_name)
    {pid, pool_name}
  end

  defp stop_pool(pid, :v1) when is_pid(pid) do
    GenServer.stop(pid)
  end

  defp stop_pool({pid, _name}, :v2) do
    GenServer.stop(pid)
  end

  defp run_warmup(pool_pid, version, transactions) do
    Enum.each(transactions, fn tx ->
      add_transaction(pool_pid, version, tx)
    end)

    # Clear the pool
    clear_pool(pool_pid, version)
  end

  defp measure_pool_performance(pool_pid, version, transactions) do
    {latencies, successful, failed} =
      Enum.reduce(transactions, {[], 0, 0}, fn tx, {lat_acc, succ_acc, fail_acc} ->
        start_time = :os.system_time(:microsecond)

        result = add_transaction(pool_pid, version, tx)

        end_time = :os.system_time(:microsecond)
        latency = end_time - start_time

        case result do
          {:ok, _} -> {[latency | lat_acc], succ_acc + 1, fail_acc}
          {:error, _} -> {[latency | lat_acc], succ_acc, fail_acc + 1}
        end
      end)

    sorted_latencies = Enum.sort(latencies)

    %{
      successful: successful,
      failed: failed,
      average_latency: Enum.sum(latencies) / length(latencies),
      p95_latency: percentile(sorted_latencies, 95),
      p99_latency: percentile(sorted_latencies, 99)
    }
  end

  defp add_transaction(pid, :v1, tx) when is_pid(pid) do
    TransactionPool.add_transaction(tx)
  end

  defp add_transaction({_pid, name}, :v2, tx) do
    GenServer.call(name, {:add_transaction, tx})
  end

  defp clear_pool(pid, :v1) when is_pid(pid) do
    # V1 doesn't have a clear method, so we'll just ignore
    :ok
  end

  defp clear_pool({_pid, name}, :v2) do
    GenServer.call(name, :clear_pool)
  end

  def benchmark_memory_usage do
    Logger.info("Benchmarking memory usage patterns")

    transactions = generate_test_transactions(500)

    v1_memory = measure_memory_usage(:v1, transactions)
    v2_memory = measure_memory_usage(:v2, transactions)

    %{
      v1: v1_memory,
      v2: v2_memory,
      improvement: calculate_memory_improvement(v1_memory, v2_memory)
    }
  end

  defp measure_memory_usage(version, transactions) do
    pool_pid = start_pool(version)

    # Measure baseline memory
    :erlang.garbage_collect()
    baseline_memory = :erlang.memory()

    # Add transactions
    Enum.each(transactions, fn tx ->
      add_transaction(pool_pid, version, tx)
    end)

    # Force garbage collection and measure
    :erlang.garbage_collect()
    loaded_memory = :erlang.memory()

    # Cleanup
    stop_pool(pool_pid, version)
    :erlang.garbage_collect()

    %{
      baseline_total: baseline_memory[:total],
      baseline_processes: baseline_memory[:processes],
      loaded_total: loaded_memory[:total],
      loaded_processes: loaded_memory[:processes],
      memory_per_transaction:
        (loaded_memory[:total] - baseline_memory[:total]) / length(transactions)
    }
  end

  def benchmark_error_handling do
    Logger.info("Benchmarking error handling robustness")

    # Create various types of problematic transactions
    invalid_transactions = [
      # Empty transaction
      "",
      # Oversized transaction
      String.duplicate("x", 200 * 1024),
      # Binary garbage
      <<255, 255, 255, 0, 0>>,
      # Will be added twice
      "duplicate_test"
    ]

    v1_errors = measure_error_handling(:v1, invalid_transactions)
    v2_errors = measure_error_handling(:v2, invalid_transactions)

    %{
      v1: v1_errors,
      v2: v2_errors,
      comparison: compare_error_handling(v1_errors, v2_errors)
    }
  end

  defp measure_error_handling(version, invalid_transactions) do
    pool_pid = start_pool(version)

    results =
      Enum.map(invalid_transactions, fn tx ->
        case add_transaction(pool_pid, version, tx) do
          {:ok, _} -> :unexpected_success
          {:error, _reason} -> {:expected_error, reason}
          other -> {:unexpected_result, other}
        end
      end)

    # Test duplicate handling
    duplicate_result1 = add_transaction(pool_pid, version, "duplicate_test")
    duplicate_result2 = add_transaction(pool_pid, version, "duplicate_test")

    stop_pool(pool_pid, version)

    %{
      invalid_handling: results,
      duplicate_handling: {duplicate_result1, duplicate_result2},
      total_errors: Enum.count(results, fn r -> match?({:expected_error, _}, r) end),
      unexpected_results: Enum.count(results, fn r -> not match?({:expected_error, _}, r) end)
    }
  end

  def benchmark_concurrent_operations do
    Logger.info("Benchmarking concurrent operation performance")

    transaction_sets = for i <- 1..10, do: generate_test_transactions(50, "batch_#{i}")

    v1_concurrent = measure_concurrent_performance(:v1, transaction_sets)
    v2_concurrent = measure_concurrent_performance(:v2, transaction_sets)

    %{
      v1: v1_concurrent,
      v2: v2_concurrent,
      improvement: calculate_concurrent_improvement(v1_concurrent, v2_concurrent)
    }
  end

  defp measure_concurrent_performance(version, transaction_sets) do
    pool_pid = start_pool(version)

    start_time = :os.system_time(:microsecond)

    tasks =
      Enum.map(transaction_sets, fn transactions ->
        Task.async(fn ->
          Enum.map(transactions, fn tx ->
            add_transaction(pool_pid, version, tx)
          end)
        end)
      end)

    results = Task.await_many(tasks, 30_000)
    end_time = :os.system_time(:microsecond)

    stop_pool(pool_pid, version)

    total_transactions = Enum.sum(Enum.map(transaction_sets, &length/1))
    total_time_us = end_time - start_time

    successful =
      results
      |> List.flatten()
      |> Enum.count(fn r -> match?({:ok, _}, r) end)

    %{
      total_time_us: total_time_us,
      total_transactions: total_transactions,
      successful_transactions: successful,
      concurrent_throughput_tps: total_transactions / (total_time_us / 1_000_000),
      success_rate: successful / total_transactions * 100
    }
  end

  # Helper functions

  defp generate_test_transactions(count, prefix \\ "tx") do
    for i <- 1..count do
      "#{prefix}_#{i}_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
    end
  end

  defp percentile(sorted_list, p) when p >= 0 and p <= 100 do
    index = trunc(length(sorted_list) * p / 100)
    Enum.at(sorted_list, max(0, index - 1), 0)
  end

  defp calculate_improvement(v1_results, v2_results) do
    %{
      throughput_improvement:
        percentage_improvement(v1_results.throughput_tps, v2_results.throughput_tps),
      latency_improvement:
        percentage_improvement(
          v1_results.average_latency_us,
          v2_results.average_latency_us,
          :lower_better
        ),
      memory_improvement:
        percentage_improvement(
          v1_results.memory_delta_bytes,
          v2_results.memory_delta_bytes,
          :lower_better
        ),
      p95_latency_improvement:
        percentage_improvement(
          v1_results.p95_latency_us,
          v2_results.p95_latency_us,
          :lower_better
        )
    }
  end

  defp calculate_memory_improvement(v1_memory, v2_memory) do
    %{
      total_memory_improvement:
        percentage_improvement(v1_memory.loaded_total, v2_memory.loaded_total, :lower_better),
      per_transaction_improvement:
        percentage_improvement(
          v1_memory.memory_per_transaction,
          v2_memory.memory_per_transaction,
          :lower_better
        )
    }
  end

  defp calculate_concurrent_improvement(v1_concurrent, v2_concurrent) do
    %{
      throughput_improvement:
        percentage_improvement(
          v1_concurrent.concurrent_throughput_tps,
          v2_concurrent.concurrent_throughput_tps
        ),
      success_rate_improvement:
        percentage_improvement(v1_concurrent.success_rate, v2_concurrent.success_rate)
    }
  end

  defp compare_error_handling(v1_errors, v2_errors) do
    %{
      v1_error_rate:
        v1_errors.total_errors / (v1_errors.total_errors + v1_errors.unexpected_results) * 100,
      v2_error_rate:
        v2_errors.total_errors / (v2_errors.total_errors + v2_errors.unexpected_results) * 100,
      v1_unexpected: v1_errors.unexpected_results,
      v2_unexpected: v2_errors.unexpected_results
    }
  end

  defp percentage_improvement(old_value, new_value, direction \\ :higher_better) do
    if old_value == 0 do
      if new_value == 0, do: 0.0, else: 100.0
    else
      improvement = (new_value - old_value) / old_value * 100
      if direction == :lower_better, do: -improvement, else: improvement
    end
  end

  defp generate_report(results) do
    Logger.info("=== V1 vs V2 Performance Benchmark Report ===")

    # Transaction Pool Performance
    pool_results = results.transaction_pool
    Logger.info("Transaction Pool Performance:")
    Logger.info("  V1 Throughput: #{Float.round(pool_results.v1.throughput_tps, 2)} TPS")
    Logger.info("  V2 Throughput: #{Float.round(pool_results.v2.throughput_tps, 2)} TPS")

    Logger.info(
      "  Throughput Improvement: #{Float.round(pool_results.improvement.throughput_improvement, 2)}%"
    )

    Logger.info("  V1 Avg Latency: #{Float.round(pool_results.v1.average_latency_us, 2)} μs")
    Logger.info("  V2 Avg Latency: #{Float.round(pool_results.v2.average_latency_us, 2)} μs")

    Logger.info(
      "  Latency Improvement: #{Float.round(pool_results.improvement.latency_improvement, 2)}%"
    )

    # Memory Usage
    memory_results = results.memory_usage
    Logger.info("Memory Usage:")

    Logger.info(
      "  V1 Memory per Transaction: #{Float.round(memory_results.v1.memory_per_transaction, 2)} bytes"
    )

    Logger.info(
      "  V2 Memory per Transaction: #{Float.round(memory_results.v2.memory_per_transaction, 2)} bytes"
    )

    Logger.info(
      "  Memory Improvement: #{Float.round(memory_results.improvement.per_transaction_improvement, 2)}%"
    )

    # Concurrent Performance
    concurrent_results = results.concurrent_performance
    Logger.info("Concurrent Performance:")

    Logger.info(
      "  V1 Concurrent Throughput: #{Float.round(concurrent_results.v1.concurrent_throughput_tps, 2)} TPS"
    )

    Logger.info(
      "  V2 Concurrent Throughput: #{Float.round(concurrent_results.v2.concurrent_throughput_tps, 2)} TPS"
    )

    Logger.info(
      "  Concurrent Improvement: #{Float.round(concurrent_results.improvement.throughput_improvement, 2)}%"
    )

    Logger.info("=== End of Benchmark Report ===")
  end
end
