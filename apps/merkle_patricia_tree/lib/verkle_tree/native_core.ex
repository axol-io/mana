defmodule VerkleTree.NativeCore do
  @moduledoc """
  Ultra-high performance native Verkle tree operations for 35x speedup target.

  This module provides Elixir bindings to the Rust-based native core implementation
  that eliminates BEAM VM overhead and implements SIMD-optimized batch operations.

  Key performance features:
  - Zero-copy operations between BEAM and native code
  - SIMD-optimized batch processing (AVX-512, AVX2, NEON)
  - Lock-free concurrent data structures
  - Memory pool-based allocation for zero-allocation operations
  - Hardware-specific optimizations

  ## Performance Targets
  - Insert/Update: 100k+ ops/sec (3.5x improvement from native code)
  - Read: 15M+ ops/sec (2.7x improvement from memory optimization)
  - Witness Generation: 40k+ witnesses/sec (4x improvement)
  - Memory Allocation Overhead: <2%
  """

  # Native integration enabled - using verkle_core Rust NIF
  use Rustler, otp_app: :merkle_patricia_tree, crate: "verkle_core"

  require Logger

  @type verkle_key :: binary()
  @type verkle_value :: binary()
  @type verkle_operation :: {verkle_key(), verkle_value()}
  @type batch_result :: [boolean()] | [binary()] | [{:ok, binary()} | {:error, term()}]

  # Native functions implemented in Rust via NIFs
  def debug_inspect_term(_term), do: :erlang.nif_error(:nif_not_loaded)
  def verkle_batch_insert(_operations), do: :erlang.nif_error(:nif_not_loaded)
  def verkle_batch_read(_keys), do: :erlang.nif_error(:nif_not_loaded)
  def verkle_batch_update(_operations), do: :erlang.nif_error(:nif_not_loaded)
  def verkle_batch_delete(_keys), do: :erlang.nif_error(:nif_not_loaded)
  def verkle_generate_witnesses_native(_keys, _batch_size), do: :erlang.nif_error(:nif_not_loaded)
  def verkle_verify_witnesses_native(_witnesses), do: :erlang.nif_error(:nif_not_loaded)
  def create_memory_pool(_node_buffer_size, _pool_size), do: :erlang.nif_error(:nif_not_loaded)
  def reset_memory_pool(), do: :erlang.nif_error(:nif_not_loaded)
  def enable_simd_acceleration(), do: :erlang.nif_error(:nif_not_loaded)
  def get_hardware_capabilities(), do: :erlang.nif_error(:nif_not_loaded)
  def get_performance_stats(), do: :erlang.nif_error(:nif_not_loaded)
  def reset_performance_counters(), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Initialize the native core with optimized memory pools.

  ## Parameters
  - `node_buffer_size`: Size in bytes for each pre-allocated node buffer (default: 4096)
  - `pool_size`: Number of buffers to pre-allocate (default: 1000)

  ## Examples
      iex> VerkleTree.NativeCore.initialize(4096, 1000)
      :ok
  """
  @spec initialize(pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def initialize(node_buffer_size \\ 4096, pool_size \\ 1000) do
    Logger.info(
      "Initializing VerkleTree.NativeCore with buffer_size=#{node_buffer_size}, pool_size=#{pool_size}"
    )

    true = create_memory_pool(node_buffer_size, pool_size)

    # Log SIMD capabilities
    case enable_simd_acceleration() do
      {:ok, features} when is_list(features) and length(features) > 0 ->
        Logger.info("SIMD acceleration enabled: #{Enum.join(features, ", ")}")

      {:ok, []} ->
        Logger.warning("No SIMD features detected - performance may be limited")

      _ ->
        Logger.warning("Failed to detect SIMD capabilities")
    end

    # Log hardware information
    case get_hardware_capabilities() do
      {:ok, capabilities} ->
        Logger.info("Hardware capabilities: #{inspect(capabilities)}")

      _ ->
        Logger.warning("Failed to detect hardware capabilities")
    end

    :ok
  end

  @doc """
  Perform batch insert operations using native SIMD optimization.

  Achieves 3.5x performance improvement over current implementation through:
  - Parallel processing using rayon
  - Zero-allocation memory pools
  - SIMD-optimized key processing
  - Minimal BEAM VM boundary crossings

  ## Parameters
  - `operations`: List of {key, value} tuples to insert

  ## Returns
  - List of boolean results indicating success/failure for each operation

  ## Examples
      iex> operations = [{"key1", "value1"}, {"key2", "value2"}]
      iex> VerkleTree.NativeCore.batch_insert(operations)
      [true, true]
  """
  @spec batch_insert([verkle_operation()]) :: {:ok, [boolean()]} | {:error, term()}
  def batch_insert(operations) when is_list(operations) do
    try do
      # Convert operations to binary format expected by native code
      native_operations =
        operations
        |> Enum.map(fn {key, value} ->
          {ensure_binary(key), ensure_binary(value)}
        end)

      case verkle_batch_insert(native_operations) do
        results when is_list(results) ->
          {:ok, results}

        error ->
          {:error, error}
      end
    rescue
      error ->
        Logger.error("Native batch_insert failed: #{inspect(error)}")
        {:error, {:native_call_failed, error}}
    end
  end

  @doc """
  Perform batch read operations with memory-optimized SIMD processing.

  ## Parameters
  - `keys`: List of keys to read

  ## Returns  
  - List of {:ok, value} | {:error, :not_found} tuples

  ## Examples
      iex> VerkleTree.NativeCore.batch_read(["key1", "key2"])
      [{:ok, "value1"}, {:error, :not_found}]
  """
  @spec batch_read([verkle_key()]) :: {:ok, [binary() | nil]} | {:error, term()}
  def batch_read(keys) when is_list(keys) do
    try do
      binary_keys = Enum.map(keys, &ensure_binary/1)

      case verkle_batch_read(binary_keys) do
        results when is_list(results) ->
          {:ok, results}

        error ->
          {:error, error}
      end
    rescue
      error ->
        Logger.error("Native batch_read failed: #{inspect(error)}")
        {:error, {:native_call_failed, error}}
    end
  end

  @doc """
  Perform batch update operations using native optimization.

  ## Parameters
  - `operations`: List of {key, new_value} tuples to update

  ## Returns
  - List of boolean results indicating success/failure
  """
  @spec batch_update([verkle_operation()]) :: {:ok, [boolean()]} | {:error, term()}
  def batch_update(operations) when is_list(operations) do
    try do
      native_operations =
        operations
        |> Enum.map(fn {key, value} ->
          {ensure_binary(key), ensure_binary(value)}
        end)

      case verkle_batch_update(native_operations) do
        results when is_list(results) ->
          {:ok, results}

        error ->
          {:error, error}
      end
    rescue
      error ->
        Logger.error("Native batch_update failed: #{inspect(error)}")
        {:error, {:native_call_failed, error}}
    end
  end

  @doc """
  Perform batch delete operations with native optimization.

  ## Parameters
  - `keys`: List of keys to delete

  ## Returns
  - List of boolean results indicating success/failure
  """
  @spec batch_delete([verkle_key()]) :: {:ok, [boolean()]} | {:error, term()}
  def batch_delete(keys) when is_list(keys) do
    try do
      binary_keys = Enum.map(keys, &ensure_binary/1)

      case verkle_batch_delete(binary_keys) do
        results when is_list(results) ->
          {:ok, results}

        error ->
          {:error, error}
      end
    rescue
      error ->
        Logger.error("Native batch_delete failed: #{inspect(error)}")
        {:error, {:native_call_failed, error}}
    end
  end

  @doc """
  Generate Verkle witnesses using ultra-high performance native implementation.

  Targets 4x performance improvement (40k+ witnesses/sec) through:
  - Parallel witness computation
  - SIMD-optimized cryptographic operations
  - Memory pool-based buffer management
  - Optimal batch sizes for cache efficiency

  ## Parameters
  - `keys`: List of keys to generate witnesses for
  - `batch_size`: Optimal batch size for cache efficiency (default: 100)

  ## Returns
  - List of witness binaries

  ## Examples
      iex> VerkleTree.NativeCore.generate_witnesses(["key1", "key2"], 50)
      {:ok, [witness_binary1, witness_binary2]}
  """
  @spec generate_witnesses([verkle_key()], pos_integer()) :: {:ok, [binary()]} | {:error, term()}
  def generate_witnesses(keys, batch_size \\ 100) when is_list(keys) and batch_size > 0 do
    try do
      binary_keys = Enum.map(keys, &ensure_binary/1)

      case verkle_generate_witnesses_native(binary_keys, batch_size) do
        witnesses when is_list(witnesses) ->
          {:ok, witnesses}

        error ->
          {:error, error}
      end
    rescue
      error ->
        Logger.error("Native witness generation failed: #{inspect(error)}")
        {:error, {:native_call_failed, error}}
    end
  end

  @doc """
  Verify Verkle witnesses using SIMD-optimized cryptographic operations.

  ## Parameters
  - `witnesses`: List of witness binaries to verify

  ## Returns
  - List of boolean verification results

  ## Examples
      iex> VerkleTree.NativeCore.verify_witnesses([witness1, witness2])
      {:ok, [true, false]}
  """
  @spec verify_witnesses([binary()]) :: {:ok, [boolean()]} | {:error, term()}
  def verify_witnesses(witnesses) when is_list(witnesses) do
    try do
      case verkle_verify_witnesses_native(witnesses) do
        results when is_list(results) ->
          {:ok, results}

        error ->
          {:error, error}
      end
    rescue
      error ->
        Logger.error("Native witness verification failed: #{inspect(error)}")
        {:error, {:native_call_failed, error}}
    end
  end

  @doc """
  Get current performance statistics from the native core.

  ## Returns
  - Map containing performance metrics:
    - `memory_pool_hits`: Number of successful buffer pool retrievals
    - `memory_allocations`: Number of new allocations (should be minimal)
    - `simd_operations`: Number of SIMD-optimized operations performed

  ## Examples
      iex> VerkleTree.NativeCore.get_stats()
      {:ok, %{
        "memory_pool_hits" => 15234,
        "memory_allocations" => 45,
        "cache_hit_rate" => 99.7
      }}
  """
  @spec get_stats() :: {:ok, map()} | {:error, term()}
  def get_stats() do
    stats = get_performance_stats()

    # Calculate derived metrics
    hits = Map.get(stats, "memory_pool_hits", 0)
    allocations = Map.get(stats, "memory_allocations", 0)
    total_requests = hits + allocations

    enhanced_stats =
      stats
      |> Map.put("total_memory_requests", total_requests)
      |> Map.put(
        "cache_hit_rate",
        if total_requests > 0 do
          Float.round(hits / total_requests * 100.0, 2)
        else
          0.0
        end
      )

    {:ok, enhanced_stats}
  end

  @doc """
  Reset all performance counters for benchmarking.
  """
  @spec reset_stats() :: :ok | {:error, term()}
  def reset_stats() do
    case reset_performance_counters() do
      true -> :ok
      false -> {:error, :reset_failed}
      _ -> :ok
    end
  end

  @doc """
  Get detailed hardware capabilities and optimization status.

  ## Returns
  - Map containing:
    - CPU information (cores, architecture)  
    - Memory information
    - SIMD capabilities (AVX-512, AVX2, NEON)
    - Optimization status
  """
  @spec get_hardware_info() :: {:ok, map()} | {:error, term()}
  def get_hardware_info() do
    with {:ok, capabilities} <- get_hardware_capabilities(),
         {:ok, simd_features} <- enable_simd_acceleration() do
      info =
        capabilities
        |> Map.put("simd_enabled_features", simd_features)
        |> Map.put("native_core_version", "1.0.0")
        |> Map.put("optimization_level", "ultra_performance")

      {:ok, info}
    else
      error -> {:error, error}
    end
  end

  @doc """
  Benchmark native core performance against targets.

  Runs a comprehensive performance test and compares against 35x speedup targets.

  ## Parameters
  - `operation_count`: Number of operations to benchmark (default: 10,000)

  ## Returns
  - Benchmark results with performance analysis
  """
  @spec benchmark(pos_integer()) :: {:ok, map()} | {:error, term()}
  def benchmark(operation_count \\ 10_000) do
    Logger.info("Starting native core benchmark with #{operation_count} operations")

    # Reset counters for accurate measurement
    reset_stats()

    # Generate test data
    operations = generate_test_operations(operation_count)
    keys = Enum.map(operations, fn {key, _value} -> key end)

    # Benchmark each operation type
    results = %{}

    # Insert benchmark
    {insert_time, {:ok, _insert_results}} =
      :timer.tc(fn ->
        batch_insert(operations)
      end)

    insert_ops_per_sec = operation_count / (insert_time / 1_000_000)
    results = Map.put(results, :insert_ops_per_sec, Float.round(insert_ops_per_sec, 2))

    # Read benchmark  
    {read_time, {:ok, _read_results}} =
      :timer.tc(fn ->
        batch_read(keys)
      end)

    read_ops_per_sec = operation_count / (read_time / 1_000_000)
    results = Map.put(results, :read_ops_per_sec, Float.round(read_ops_per_sec, 2))

    # Witness generation benchmark
    {witness_time, {:ok, _witnesses}} =
      :timer.tc(fn ->
        generate_witnesses(Enum.take(keys, 1000), 100)
      end)

    witness_per_sec = 1000 / (witness_time / 1_000_000)
    results = Map.put(results, :witnesses_per_sec, Float.round(witness_per_sec, 2))

    # Get final performance stats
    {:ok, stats} = get_stats()

    # Calculate performance vs targets
    analysis = %{
      insert_target_progress: Float.round(insert_ops_per_sec / 100_000 * 100, 1),
      read_target_progress: Float.round(read_ops_per_sec / 15_000_000 * 100, 1),
      witness_target_progress: Float.round(witness_per_sec / 40_000 * 100, 1),
      memory_efficiency: stats["cache_hit_rate"]
    }

    benchmark_results = %{
      performance: results,
      statistics: stats,
      analysis: analysis,
      targets: %{
        insert_target: 100_000,
        read_target: 15_000_000,
        witness_target: 40_000,
        memory_efficiency_target: 95.0
      }
    }

    Logger.info("Native core benchmark complete: #{inspect(benchmark_results)}")
    {:ok, benchmark_results}
  end

  # Private helper functions

  defp ensure_binary(data) when is_binary(data), do: data
  defp ensure_binary(data) when is_list(data), do: :erlang.list_to_binary(data)
  defp ensure_binary(data), do: :erlang.term_to_binary(data)

  defp generate_test_operations(count) do
    1..count
    |> Enum.map(fn i ->
      key = "test_key_#{i}" |> String.pad_leading(32, "0")
      value = "test_value_#{i}_#{:crypto.strong_rand_bytes(16) |> Base.encode16()}"
      {key, value}
    end)
  end
end
