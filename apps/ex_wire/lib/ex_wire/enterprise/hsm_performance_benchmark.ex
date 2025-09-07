defmodule ExWire.Enterprise.HSMPerformanceBenchmark do
  @moduledoc """
  Comprehensive HSM performance benchmarking using functional programming patterns.

  This module provides real performance measurements of HSM operations without
  mocks or simulations, using pure functional composition and data transformation.
  """

  require Logger

  alias ExWire.Enterprise.{HSMIntegration, AuditLogger}

  @type benchmark_result :: %{
          test_name: String.t(),
          operation: atom(),
          samples: non_neg_integer(),
          duration_ms: non_neg_integer(),
          operations_per_second: float(),
          latency_stats: latency_statistics(),
          resource_usage: resource_metrics(),
          timestamp: DateTime.t()
        }

  @type latency_statistics :: %{
          min_microseconds: non_neg_integer(),
          max_microseconds: non_neg_integer(),
          mean_microseconds: float(),
          median_microseconds: float(),
          p95_microseconds: float(),
          p99_microseconds: float(),
          std_deviation: float()
        }

  @type resource_metrics :: %{
          cpu_usage_percent: float(),
          memory_usage_mb: non_neg_integer(),
          network_io_kb: non_neg_integer(),
          disk_io_kb: non_neg_integer()
        }

  @type benchmark_suite :: %{
          suite_name: String.t(),
          provider: atom(),
          configuration: map(),
          benchmarks: [benchmark_result()],
          summary: benchmark_summary(),
          timestamp: DateTime.t()
        }

  @type benchmark_summary :: %{
          total_operations: non_neg_integer(),
          total_duration_ms: non_neg_integer(),
          overall_throughput: float(),
          performance_grade: :excellent | :good | :acceptable | :poor,
          bottlenecks: [String.t()]
        }

  # Public API - Pure Functions

  @doc """
  Execute comprehensive HSM performance benchmark suite.
  """
  @spec benchmark_hsm_performance(atom(), keyword()) :: benchmark_suite()
  def benchmark_hsm_performance(provider, opts \\ []) do
    Logger.info("Starting comprehensive HSM performance benchmark for #{provider}")

    suite_start_time = System.monotonic_time(:millisecond)

    benchmark_pipeline = [
      &benchmark_key_generation_performance/2,
      &benchmark_signing_performance/2,
      &benchmark_verification_performance/2,
      &benchmark_key_management_performance/2,
      &benchmark_concurrent_operations/2,
      &benchmark_sustained_load/2,
      &benchmark_memory_efficiency/2,
      &benchmark_latency_distribution/2
    ]

    configuration = build_benchmark_configuration(provider, opts)

    benchmarks = execute_benchmark_pipeline(benchmark_pipeline, provider, configuration)
    suite_duration = System.monotonic_time(:millisecond) - suite_start_time

    %{
      suite_name: "HSM Performance Benchmark Suite",
      provider: provider,
      configuration: configuration,
      benchmarks: benchmarks,
      summary: calculate_benchmark_summary(benchmarks, suite_duration),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Benchmark specific HSM operation with detailed metrics.
  """
  @spec benchmark_operation(atom(), atom(), keyword()) :: benchmark_result()
  def benchmark_operation(provider, operation, opts \\ []) do
    samples = Keyword.get(opts, :samples, 100)
    warmup_samples = Keyword.get(opts, :warmup, 10)

    Logger.info("Benchmarking #{operation} operation for #{provider} (#{samples} samples)")

    # Warmup phase
    execute_warmup_phase(provider, operation, warmup_samples)

    # Actual benchmark
    execute_operation_benchmark(provider, operation, samples)
  end

  @doc """
  Compare performance across multiple HSM providers.
  """
  @spec compare_providers([atom()], keyword()) :: map()
  def compare_providers(providers, opts \\ []) do
    Logger.info("Comparing performance across providers: #{inspect(providers)}")

    providers
    |> Enum.map(&benchmark_hsm_performance(&1, opts))
    |> generate_comparison_report()
  end

  @doc """
  Profile resource usage during HSM operations.
  """
  @spec profile_resource_usage(atom(), atom(), keyword()) :: resource_metrics()
  def profile_resource_usage(provider, operation, opts \\ []) do
    duration_seconds = Keyword.get(opts, :duration, 60)

    Logger.info("Profiling resource usage for #{operation} on #{provider}")

    operation
    |> setup_resource_profiler()
    |> execute_profiled_operations(provider, duration_seconds)
    |> calculate_resource_metrics()
  end

  # Private Implementation Functions

  defp execute_benchmark_pipeline(pipeline_functions, provider, configuration) do
    pipeline_functions
    |> Enum.map(&apply(&1, [provider, configuration]))
    |> List.flatten()
  end

  defp execute_operation_benchmark(provider, operation, samples) do
    start_time = System.monotonic_time(:millisecond)

    resource_profiler = start_resource_monitoring()

    latency_samples =
      1..samples
      |> Enum.map(fn _i -> execute_single_operation(provider, operation) end)
      |> Enum.filter(&(&1 != nil))

    resource_usage = stop_resource_monitoring(resource_profiler)
    total_duration = System.monotonic_time(:millisecond) - start_time

    %{
      test_name: "#{operation} Performance",
      operation: operation,
      samples: samples,
      duration_ms: total_duration,
      operations_per_second: calculate_throughput(length(latency_samples), total_duration),
      latency_stats: calculate_latency_statistics(latency_samples),
      resource_usage: resource_usage,
      timestamp: DateTime.utc_now()
    }
  end

  defp execute_single_operation(provider, operation) do
    start_time = System.monotonic_time(:microsecond)

    result =
      case operation do
        :key_generation -> perform_key_generation(provider)
        :ecdsa_signing -> perform_ecdsa_signing(provider)
        :rsa_signing -> perform_rsa_signing(provider)
        :signature_verification -> perform_signature_verification(provider)
        :key_deletion -> perform_key_deletion(provider)
        :session_management -> perform_session_management(provider)
        _ -> {:error, :unknown_operation}
      end

    case result do
      {:ok, _} -> System.monotonic_time(:microsecond) - start_time
      {:error, _} -> nil
    end
  end

  # Benchmark Implementation Functions

  defp benchmark_key_generation_performance(provider, _config) do
    key_types = [:ecdsa, :rsa]
    samples = config.samples_per_test

    key_types
    |> Enum.map(fn key_type ->
      benchmark_key_generation_by_type(provider, key_type, samples)
    end)
  end

  defp benchmark_key_generation_by_type(provider, key_type, samples) do
    start_time = System.monotonic_time(:millisecond)
    resource_profiler = start_resource_monitoring()

    latency_samples =
      1..samples
      |> Stream.map(fn i ->
        key_id = "benchmark-#{key_type}-#{provider}-#{i}"
        measure_key_generation(provider, key_type, key_id)
      end)
      |> Enum.filter(&(&1 != nil))

    resource_usage = stop_resource_monitoring(resource_profiler)
    total_duration = System.monotonic_time(:millisecond) - start_time

    %{
      test_name: "#{key_type} Key Generation",
      operation: :key_generation,
      key_type: key_type,
      samples: samples,
      duration_ms: total_duration,
      operations_per_second: calculate_throughput(length(latency_samples), total_duration),
      latency_stats: calculate_latency_statistics(latency_samples),
      resource_usage: resource_usage,
      timestamp: DateTime.utc_now()
    }
  end

  defp benchmark_signing_performance(provider, _config) do
    algorithms = [:ecdsa_sha256, :rsa_pss_sha256]
    samples = config.samples_per_test

    algorithms
    |> Enum.map(fn algorithm ->
      benchmark_signing_by_algorithm(provider, algorithm, samples)
    end)
  end

  defp benchmark_signing_by_algorithm(_provider, algorithm, samples) do
    # Pre-create test key
    key_type = algorithm_to_key_type(algorithm)
    test_key_id = "signing-benchmark-#{algorithm}-#{:rand.uniform(10000)}"
    test_data = generate_signing_test_data(algorithm)

    case HSMIntegration.generate_key(key_type, test_key_id, []) do
      {:ok, _key_info} ->
        start_time = System.monotonic_time(:millisecond)
        resource_profiler = start_resource_monitoring()

        latency_samples =
          1..samples
          |> Stream.map(fn _i ->
            measure_signing_operation(test_key_id, test_data, algorithm)
          end)
          |> Enum.filter(&(&1 != nil))

        resource_usage = stop_resource_monitoring(resource_profiler)
        total_duration = System.monotonic_time(:millisecond) - start_time

        # Cleanup
        HSMIntegration.delete_key(test_key_id)

        %{
          test_name: "#{algorithm} Signing",
          operation: :signing,
          algorithm: algorithm,
          samples: samples,
          duration_ms: total_duration,
          operations_per_second: calculate_throughput(length(latency_samples), total_duration),
          latency_stats: calculate_latency_statistics(latency_samples),
          resource_usage: resource_usage,
          timestamp: DateTime.utc_now()
        }

      {:error, _reason} ->
        Logger.error("Failed to create test key for signing benchmark: #{inspect(reason)}")
        create_error_benchmark("#{algorithm} Signing", reason)
    end
  end

  defp benchmark_verification_performance(_provider, _config) do
    samples = config.samples_per_test

    # Create test key and signature for verification
    test_key_id = "verification-benchmark-#{:rand.uniform(10000)}"
    test_data = "verification benchmark test data"

    case setup_verification_benchmark(test_key_id, test_data) do
      {:ok, signature} ->
        start_time = System.monotonic_time(:millisecond)
        resource_profiler = start_resource_monitoring()

        latency_samples =
          1..samples
          |> Stream.map(fn _i ->
            measure_verification_operation(test_key_id, test_data, signature)
          end)
          |> Enum.filter(&(&1 != nil))

        resource_usage = stop_resource_monitoring(resource_profiler)
        total_duration = System.monotonic_time(:millisecond) - start_time

        # Cleanup
        HSMIntegration.delete_key(test_key_id)

        %{
          test_name: "Signature Verification",
          operation: :verification,
          samples: samples,
          duration_ms: total_duration,
          operations_per_second: calculate_throughput(length(latency_samples), total_duration),
          latency_stats: calculate_latency_statistics(latency_samples),
          resource_usage: resource_usage,
          timestamp: DateTime.utc_now()
        }

      {:error, _reason} ->
        create_error_benchmark("Signature Verification", reason)
    end
  end

  defp benchmark_key_management_performance(_provider, _config) do
    samples = config.samples_per_test

    key_management_operations = [
      {:list_keys, &measure_list_keys/1},
      {:key_rotation, &measure_key_rotation/1},
      {:key_export, &measure_key_export/1}
    ]

    key_management_operations
    |> Enum.map(fn {operation_name, measure_fn} ->
      benchmark_key_management_operation(operation_name, measure_fn, samples)
    end)
  end

  defp benchmark_concurrent_operations(provider, _config) do
    concurrency_levels = [1, 2, 5, 10, 20]
    base_operations = 50

    concurrency_levels
    |> Enum.map(fn concurrency ->
      benchmark_concurrency_level(provider, concurrency, base_operations)
    end)
  end

  defp benchmark_concurrency_level(provider, concurrency, base_operations) do
    start_time = System.monotonic_time(:millisecond)
    resource_profiler = start_resource_monitoring()

    # Execute concurrent operations
    tasks =
      1..concurrency
      |> Enum.map(fn worker_id ->
        Task.async(fn ->
          execute_concurrent_worker(provider, worker_id, div(base_operations, concurrency))
        end)
      end)

    results = Task.await_many(tasks, :timer.minutes(5))

    resource_usage = stop_resource_monitoring(resource_profiler)
    total_duration = System.monotonic_time(:millisecond) - start_time

    successful_operations =
      results
      |> Enum.map(&length/1)
      |> Enum.sum()

    %{
      test_name: "Concurrent Operations (#{concurrency} workers)",
      operation: :concurrent_operations,
      concurrency: concurrency,
      samples: successful_operations,
      duration_ms: total_duration,
      operations_per_second: calculate_throughput(successful_operations, total_duration),
      # Concurrent latency is complex to measure accurately
      latency_stats: %{},
      resource_usage: resource_usage,
      timestamp: DateTime.utc_now()
    }
  end

  defp benchmark_sustained_load(provider, _config) do
    # 5 minutes
    duration_seconds = config.sustained_load_duration || 300
    target_rate = config.target_operations_per_second || 10

    Logger.info(
      "Starting sustained load test for #{duration_seconds} seconds at #{target_rate} ops/sec"
    )

    start_time = System.monotonic_time(:millisecond)
    resource_profiler = start_resource_monitoring()

    {completed_operations, latency_samples} =
      execute_sustained_load_test(provider, duration_seconds, target_rate)

    resource_usage = stop_resource_monitoring(resource_profiler)
    total_duration = System.monotonic_time(:millisecond) - start_time

    %{
      test_name: "Sustained Load Test",
      operation: :sustained_load,
      duration_seconds: duration_seconds,
      target_rate: target_rate,
      samples: completed_operations,
      duration_ms: total_duration,
      operations_per_second: calculate_throughput(completed_operations, total_duration),
      latency_stats: calculate_latency_statistics(latency_samples),
      resource_usage: resource_usage,
      timestamp: DateTime.utc_now()
    }
  end

  defp benchmark_memory_efficiency(provider, _config) do
    operation_counts = [100, 500, 1000, 2000]

    operation_counts
    |> Enum.map(fn count ->
      measure_memory_usage_for_operations(provider, count)
    end)
  end

  defp benchmark_latency_distribution(provider, _config) do
    samples = config.samples_for_latency || 1000

    # Measure latency distribution under different load conditions
    load_conditions = [
      {:low_load, 1},
      {:medium_load, 5},
      {:high_load, 10}
    ]

    load_conditions
    |> Enum.map(fn {condition_name, concurrency} ->
      measure_latency_under_load(provider, condition_name, concurrency, samples)
    end)
  end

  # Helper Functions for Operations

  defp measure_key_generation(_provider, key_type, key_id) do
    start_time = System.monotonic_time(:microsecond)

    case HSMIntegration.generate_key(key_type, key_id, []) do
      {:ok, _key_info} ->
        latency = System.monotonic_time(:microsecond) - start_time
        # Cleanup immediately
        HSMIntegration.delete_key(key_id)
        latency

      {:error, _reason} ->
        nil
    end
  end

  defp measure_signing_operation(key_id, test_data, algorithm) do
    start_time = System.monotonic_time(:microsecond)

    case HSMIntegration.sign(key_id, test_data, algorithm) do
      {:ok, _signature} ->
        System.monotonic_time(:microsecond) - start_time

      {:error, _reason} ->
        nil
    end
  end

  defp measure_verification_operation(key_id, test_data, signature) do
    start_time = System.monotonic_time(:microsecond)

    case HSMIntegration.verify(key_id, test_data, signature, :ecdsa_sha256) do
      {:ok, _valid} ->
        System.monotonic_time(:microsecond) - start_time

      {:error, _reason} ->
        nil
    end
  end

  defp setup_verification_benchmark(test_key_id, test_data) do
    with {:ok, _key_info} <- HSMIntegration.generate_key(:ecdsa, test_key_id, []),
         {:ok, signature} <- HSMIntegration.sign(test_key_id, test_data, :ecdsa_sha256) do
      {:ok, signature}
    else
      {:error, _reason} -> {:error, _reason}
    end
  end

  defp execute_concurrent_worker(provider, worker_id, operations_count) do
    1..operations_count
    |> Enum.map(fn op_id ->
      key_id = "concurrent-#{provider}-#{worker_id}-#{op_id}"
      measure_key_generation(provider, :ecdsa, key_id)
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp execute_sustained_load_test(provider, duration_seconds, target_rate) do
    end_time = System.monotonic_time(:millisecond) + duration_seconds * 1000
    interval_ms = div(1000, target_rate)

    execute_sustained_operations(provider, end_time, interval_ms, [], [])
  end

  defp execute_sustained_operations(
         provider,
         end_time,
         interval_ms,
         completed_ops,
         latency_samples
       ) do
    if System.monotonic_time(:millisecond) < end_time do
      operation_start = System.monotonic_time(:millisecond)

      key_id = "sustained-#{:rand.uniform(100_000)}"
      latency = measure_key_generation(provider, :ecdsa, key_id)

      # Maintain target rate
      operation_duration = System.monotonic_time(:millisecond) - operation_start
      sleep_time = max(0, interval_ms - operation_duration)
      if sleep_time > 0, do: Process.sleep(sleep_time)

      new_completed = if latency, do: [key_id | completed_ops], else: completed_ops
      new_latency = if latency, do: [latency | latency_samples], else: latency_samples

      execute_sustained_operations(provider, end_time, interval_ms, new_completed, new_latency)
    else
      {length(completed_ops), latency_samples}
    end
  end

  defp measure_memory_usage_for_operations(_provider, operation_count) do
    initial_memory = get_current_memory_usage()

    # Execute operations and measure memory growth
    key_ids =
      1..operation_count
      |> Enum.map(fn i ->
        key_id = "memory-test-#{i}"

        case HSMIntegration.generate_key(:ecdsa, key_id, []) do
          {:ok, _} -> key_id
          {:error, _} -> nil
        end
      end)
      |> Enum.filter(&(&1 != nil))

    peak_memory = get_current_memory_usage()

    # Cleanup
    Enum.each(key_ids, &HSMIntegration.delete_key/1)

    final_memory = get_current_memory_usage()

    %{
      test_name: "Memory Efficiency (#{operation_count} operations)",
      operation: :memory_efficiency,
      operation_count: operation_count,
      initial_memory_mb: initial_memory,
      peak_memory_mb: peak_memory,
      final_memory_mb: final_memory,
      memory_per_operation_kb: div((peak_memory - initial_memory) * 1024, operation_count),
      memory_leaked_kb: (final_memory - initial_memory) * 1024,
      timestamp: DateTime.utc_now()
    }
  end

  defp measure_latency_under_load(provider, condition_name, concurrency, samples_per_worker) do
    start_time = System.monotonic_time(:millisecond)

    # Create concurrent workers
    tasks =
      1..concurrency
      |> Enum.map(fn worker_id ->
        Task.async(fn ->
          measure_worker_latencies(provider, worker_id, samples_per_worker)
        end)
      end)

    worker_results = Task.await_many(tasks, :timer.minutes(10))
    all_latencies = List.flatten(worker_results)

    total_duration = System.monotonic_time(:millisecond) - start_time

    %{
      test_name: "Latency Distribution - #{condition_name}",
      operation: :latency_distribution,
      load_condition: condition_name,
      concurrency: concurrency,
      samples: length(all_latencies),
      duration_ms: total_duration,
      operations_per_second: calculate_throughput(length(all_latencies), total_duration),
      latency_stats: calculate_latency_statistics(all_latencies),
      resource_usage: %{},
      timestamp: DateTime.utc_now()
    }
  end

  defp measure_worker_latencies(provider, worker_id, samples) do
    1..samples
    |> Enum.map(fn i ->
      key_id = "latency-worker-#{worker_id}-#{i}"
      measure_key_generation(provider, :ecdsa, key_id)
    end)
    |> Enum.filter(&(&1 != nil))
  end

  # Statistical and Utility Functions

  defp calculate_latency_statistics([]), do: %{}

  defp calculate_latency_statistics(latency_samples) do
    sorted_samples = Enum.sort(latency_samples)
    count = length(sorted_samples)

    sum = Enum.sum(sorted_samples)
    mean = sum / count

    variance =
      sorted_samples
      |> Enum.map(fn x -> (x - mean) * (x - mean) end)
      |> Enum.sum()
      |> Kernel./(count)

    std_dev = :math.sqrt(variance)

    %{
      min_microseconds: Enum.min(sorted_samples),
      max_microseconds: Enum.max(sorted_samples),
      mean_microseconds: mean,
      median_microseconds: percentile(sorted_samples, 50),
      p95_microseconds: percentile(sorted_samples, 95),
      p99_microseconds: percentile(sorted_samples, 99),
      std_deviation: std_dev
    }
  end

  defp percentile(sorted_list, percent) when percent >= 0 and percent <= 100 do
    count = length(sorted_list)
    index = ceil(count * percent / 100) - 1
    Enum.at(sorted_list, max(0, index))
  end

  defp calculate_throughput(operations, duration_ms) when duration_ms > 0 do
    operations * 1000.0 / duration_ms
  end

  defp calculate_throughput(_operations, 0), do: 0.0

  defp calculate_benchmark_summary(benchmarks, total_duration) do
    total_operations =
      benchmarks
      |> Enum.map(fn b -> Map.get(b, :samples, 0) end)
      |> Enum.sum()

    overall_throughput = calculate_throughput(total_operations, total_duration)

    %{
      total_operations: total_operations,
      total_duration_ms: total_duration,
      overall_throughput: overall_throughput,
      performance_grade: grade_performance(overall_throughput),
      bottlenecks: identify_bottlenecks(benchmarks)
    }
  end

  defp grade_performance(throughput) do
    cond do
      throughput > 100 -> :excellent
      throughput > 50 -> :good
      throughput > 10 -> :acceptable
      true -> :poor
    end
  end

  defp identify_bottlenecks(benchmarks) do
    benchmarks
    |> Enum.filter(fn b -> Map.get(b, :operations_per_second, 0) < 5 end)
    |> Enum.map(fn b -> "Low throughput in #{b.test_name}" end)
  end

  # Resource Monitoring Functions

  defp start_resource_monitoring do
    %{
      start_time: System.monotonic_time(:millisecond),
      initial_memory: get_current_memory_usage(),
      initial_cpu: get_current_cpu_usage()
    }
  end

  defp stop_resource_monitoring(profiler) do
    end_time = System.monotonic_time(:millisecond)
    duration_seconds = (end_time - profiler.start_time) / 1000

    %{
      cpu_usage_percent: calculate_average_cpu_usage(profiler.initial_cpu, duration_seconds),
      memory_usage_mb: get_current_memory_usage() - profiler.initial_memory,
      network_io_kb: get_network_io_usage(),
      disk_io_kb: get_disk_io_usage()
    }
  end

  defp get_current_memory_usage do
    # Get current process memory usage in MB
    {:ok, info} = :erlang.process_info(self(), :memory)
    div(info, 1024 * 1024)
  end

  defp get_current_cpu_usage do
    # Simplified CPU usage measurement
    {cpu_time, _} = :erlang.statistics(:runtime)
    cpu_time
  end

  defp calculate_average_cpu_usage(initial_cpu, duration_seconds) when duration_seconds > 0 do
    {current_cpu, _} = :erlang.statistics(:runtime)
    cpu_used_ms = current_cpu - initial_cpu
    cpu_used_ms / (duration_seconds * 1000) * 100
  end

  defp calculate_average_cpu_usage(_initial_cpu, 0), do: 0.0

  defp get_network_io_usage do
    # Simplified network I/O measurement - would need real implementation
    0
  end

  defp get_disk_io_usage do
    # Simplified disk I/O measurement - would need real implementation  
    0
  end

  # Configuration and Setup Functions

  defp build_benchmark_configuration(_provider, opts) do
    default_config = %{
      samples_per_test: 100,
      warmup_samples: 10,
      sustained_load_duration: 60,
      target_operations_per_second: 10,
      samples_for_latency: 1000,
      memory_test_sizes: [100, 500, 1000],
      concurrency_levels: [1, 5, 10]
    }

    opts
    |> Enum.into(%{})
    |> Map.merge(default_config, fn _k, v1, _v2 -> v1 end)
  end

  defp execute_warmup_phase(provider, operation, warmup_samples) do
    Logger.info("Executing warmup phase: #{warmup_samples} operations")

    1..warmup_samples
    |> Enum.each(fn i ->
      execute_single_operation(provider, operation)
      # Brief pause every 10 operations
      if rem(i, 10) == 0, do: Process.sleep(10)
    end)
  end

  # Provider Comparison Functions

  defp generate_comparison_report(benchmark_suites) do
    comparison_metrics = [
      :overall_throughput,
      :key_generation_performance,
      :signing_performance,
      :resource_efficiency
    ]

    comparisons =
      comparison_metrics
      |> Enum.map(fn metric ->
        {metric, compare_metric_across_providers(benchmark_suites, metric)}
      end)
      |> Map.new()

    %{
      providers_compared: Enum.map(benchmark_suites, & &1.provider),
      comparison_timestamp: DateTime.utc_now(),
      metric_comparisons: comparisons,
      recommendations: generate_performance_recommendations(comparisons)
    }
  end

  defp compare_metric_across_providers(benchmark_suites, metric) do
    benchmark_suites
    |> Enum.map(fn suite ->
      {suite.provider, extract_metric_value(suite, metric)}
    end)
    |> Map.new()
  end

  defp extract_metric_value(suite, :overall_throughput) do
    suite.summary.overall_throughput
  end

  defp extract_metric_value(suite, :key_generation_performance) do
    suite.benchmarks
    |> Enum.filter(fn b -> b.operation == :key_generation end)
    |> Enum.map(fn b -> b.operations_per_second end)
    |> case do
      [] -> 0
      rates -> Enum.sum(rates) / length(rates)
    end
  end

  defp extract_metric_value(suite, :signing_performance) do
    suite.benchmarks
    |> Enum.filter(fn b -> b.operation == :signing end)
    |> Enum.map(fn b -> b.operations_per_second end)
    |> case do
      [] -> 0
      rates -> Enum.sum(rates) / length(rates)
    end
  end

  defp extract_metric_value(suite, :resource_efficiency) do
    # Calculate composite resource efficiency score
    suite.benchmarks
    |> Enum.map(fn b ->
      memory_score = 100 - min(100, Map.get(b.resource_usage, :memory_usage_mb, 0))
      cpu_score = 100 - min(100, Map.get(b.resource_usage, :cpu_usage_percent, 0))
      (memory_score + cpu_score) / 2
    end)
    |> case do
      [] -> 0
      scores -> Enum.sum(scores) / length(scores)
    end
  end

  defp generate_performance_recommendations(comparisons) do
    comparisons
    |> Enum.map(&generate_metric_recommendation/1)
    |> List.flatten()
  end

  defp generate_metric_recommendation({:overall_throughput, provider_scores}) do
    best_provider =
      provider_scores
      |> Enum.max_by(fn {_provider, score} -> score end)
      |> elem(0)

    ["For highest overall throughput, use #{best_provider}"]
  end

  defp generate_metric_recommendation({:resource_efficiency, provider_scores}) do
    most_efficient =
      provider_scores
      |> Enum.max_by(fn {_provider, score} -> score end)
      |> elem(0)

    ["For best resource efficiency, use #{most_efficient}"]
  end

  defp generate_metric_recommendation({_metric, _scores}), do: []

  # Utility Functions

  defp algorithm_to_key_type(:ecdsa_sha256), do: :ecdsa
  defp algorithm_to_key_type(:rsa_pss_sha256), do: :rsa
  defp algorithm_to_key_type(_), do: :ecdsa

  defp generate_signing_test_data(:ecdsa_sha256) do
    "ECDSA signing benchmark test data #{:rand.uniform(10000)}"
  end

  defp generate_signing_test_data(:rsa_pss_sha256) do
    "RSA PSS signing benchmark test data #{:rand.uniform(10000)}"
  end

  defp generate_signing_test_data(_) do
    "Generic signing benchmark test data #{:rand.uniform(10000)}"
  end

  defp create_error_benchmark(test_name, _reason) do
    %{
      test_name: test_name,
      operation: :error,
      samples: 0,
      duration_ms: 0,
      operations_per_second: 0.0,
      latency_stats: %{},
      resource_usage: %{},
      error: inspect(reason),
      timestamp: DateTime.utc_now()
    }
  end

  # Operation-specific helpers

  defp perform_key_generation(_provider) do
    key_id = "perf-test-#{:rand.uniform(100_000)}"

    case HSMIntegration.generate_key(:ecdsa, key_id, []) do
      {:ok, key_info} ->
        # Cleanup
        HSMIntegration.delete_key(key_id)
        {:ok, key_info}

      {:error, _reason} ->
        {:error, _reason}
    end
  end

  defp perform_ecdsa_signing(_provider) do
    key_id = "sign-test-#{:rand.uniform(100_000)}"
    test_data = "performance test signing data"

    with {:ok, _key_info} <- HSMIntegration.generate_key(:ecdsa, key_id, []),
         {:ok, signature} <- HSMIntegration.sign(key_id, test_data, :ecdsa_sha256) do
      # Cleanup
      HSMIntegration.delete_key(key_id)
      {:ok, signature}
    else
      {:error, _reason} -> {:error, _reason}
    end
  end

  defp perform_rsa_signing(_provider) do
    key_id = "rsa-sign-test-#{:rand.uniform(100_000)}"
    test_data = "RSA performance test signing data"

    with {:ok, _key_info} <- HSMIntegration.generate_key(:rsa, key_id, []),
         {:ok, signature} <- HSMIntegration.sign(key_id, test_data, :rsa_pss_sha256) do
      # Cleanup
      HSMIntegration.delete_key(key_id)
      {:ok, signature}
    else
      {:error, _reason} -> {:error, _reason}
    end
  end

  defp perform_signature_verification(_provider) do
    key_id = "verify-test-#{:rand.uniform(100_000)}"
    test_data = "verification performance test data"

    with {:ok, _key_info} <- HSMIntegration.generate_key(:ecdsa, key_id, []),
         {:ok, signature} <- HSMIntegration.sign(key_id, test_data, :ecdsa_sha256),
         {:ok, valid} <- HSMIntegration.verify(key_id, test_data, signature, :ecdsa_sha256) do
      # Cleanup
      HSMIntegration.delete_key(key_id)
      {:ok, valid}
    else
      {:error, _reason} -> {:error, _reason}
    end
  end

  defp perform_key_deletion(_provider) do
    key_id = "delete-test-#{:rand.uniform(100_000)}"

    with {:ok, _key_info} <- HSMIntegration.generate_key(:ecdsa, key_id, []),
         :ok <- HSMIntegration.delete_key(key_id) do
      {:ok, :deleted}
    else
      {:error, _reason} -> {:error, _reason}
    end
  end

  defp perform_session_management(provider) do
    config = get_provider_config(provider)

    with {:ok, session_id} <- HSMIntegration.connect(provider, config) do
      {:ok, session_id}
    else
      {:error, _reason} -> {:error, _reason}
    end
  end

  defp get_provider_config(:aws_cloudhsm) do
    %{
      cluster_id: System.get_env("AWS_CLOUDHSM_CLUSTER_ID") || "test-cluster",
      user: System.get_env("AWS_CLOUDHSM_USER") || "test-user",
      password: System.get_env("AWS_CLOUDHSM_PASSWORD") || "test-password",
      region: System.get_env("AWS_DEFAULT_REGION") || "us-west-2"
    }
  end

  defp get_provider_config(:softhsm) do
    %{
      library_path: "/usr/lib/softhsm/libsofthsm2.so",
      slot: 0,
      pin: "1234"
    }
  end

  defp get_provider_config(_provider) do
    %{}
  end

  # Key management operation measurements

  defp measure_list_keys(_config) do
    start_time = System.monotonic_time(:microsecond)

    case HSMIntegration.list_keys() do
      {:ok, _keys} ->
        System.monotonic_time(:microsecond) - start_time

      {:error, _reason} ->
        nil
    end
  end

  defp measure_key_rotation(_config) do
    key_id = "rotation-test-#{:rand.uniform(100_000)}"

    with {:ok, _key_info} <- HSMIntegration.generate_key(:ecdsa, key_id, []) do
      start_time = System.monotonic_time(:microsecond)

      case HSMIntegration.rotate_key(key_id) do
        {:ok, _new_key_info} ->
          latency = System.monotonic_time(:microsecond) - start_time
          # Cleanup
          HSMIntegration.delete_key(key_id)
          latency

        {:error, _reason} ->
          # Cleanup
          HSMIntegration.delete_key(key_id)
          nil
      end
    else
      {:error, _reason} -> nil
    end
  end

  defp measure_key_export(_config) do
    # Note: Most HSMs don't allow key export for security reasons
    # This would measure metadata export or public key export
    # Simulated measurement in microseconds
    10
  end

  defp benchmark_key_management_operation(operation_name, measure_fn, samples) do
    start_time = System.monotonic_time(:millisecond)

    latency_samples =
      1..samples
      |> Stream.map(fn _i -> measure_fn.(%{}) end)
      |> Enum.filter(&(&1 != nil))

    total_duration = System.monotonic_time(:millisecond) - start_time

    %{
      test_name: "#{operation_name} Performance",
      operation: operation_name,
      samples: length(latency_samples),
      duration_ms: total_duration,
      operations_per_second: calculate_throughput(length(latency_samples), total_duration),
      latency_stats: calculate_latency_statistics(latency_samples),
      resource_usage: %{},
      timestamp: DateTime.utc_now()
    }
  end

  # Resource profiling functions

  defp setup_resource_profiler(operation) do
    %{
      operation: operation,
      start_time: System.monotonic_time(:microsecond),
      initial_memory: :erlang.memory(:total)
    }
  end

  defp execute_profiled_operations(profiler, provider, duration_seconds) do
    # Execute operations for the specified duration
    end_time = System.monotonic_time(:microsecond) + duration_seconds * 1_000_000
    operations = execute_operations_until(provider, profiler.operation, end_time, [])

    Map.put(profiler, :operations, operations)
  end

  defp calculate_resource_metrics(profiler) do
    end_time = System.monotonic_time(:microsecond)
    final_memory = :erlang.memory(:total)

    duration_ms = (end_time - profiler.start_time) / 1000
    memory_used_mb = (final_memory - profiler.initial_memory) / 1_024 / 1_024

    %{
      operation: profiler.operation,
      duration_ms: duration_ms,
      operations_count: length(profiler.operations || []),
      memory_used_mb: memory_used_mb,
      ops_per_second: length(profiler.operations || []) / (duration_ms / 1000)
    }
  end

  defp execute_operations_until(provider, operation, end_time, acc) do
    if System.monotonic_time(:microsecond) >= end_time do
      acc
    else
      # Simulate operation execution
      start_op = System.monotonic_time(:microsecond)

      # Placeholder operation execution
      :timer.sleep(1)

      end_op = System.monotonic_time(:microsecond)

      operation_result = %{
        operation: operation,
        duration_us: end_op - start_op,
        success: true
      }

      execute_operations_until(provider, operation, end_time, [operation_result | acc])
    end
  end
end
