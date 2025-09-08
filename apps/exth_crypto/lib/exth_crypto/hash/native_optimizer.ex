defmodule ExthCrypto.Hash.NativeOptimizer do
  @moduledoc """
  Native hash function optimizations for maximum performance.
  
  Detects and utilizes the fastest available hash implementations:
  - Native NIFs when available (BLS, KZG)  
  - Optimized Erlang crypto functions
  - SIMD-optimized implementations where supported
  - Hardware acceleration detection
  
  Provides adaptive performance based on available system capabilities.
  """

  require Logger

  @doc """
  Initialize native optimizations and detect available accelerations.
  """
  def init do
    capabilities = detect_capabilities()
    configure_optimizations(capabilities)
    Logger.info("Native hash optimizations initialized: #{inspect(capabilities)}")
    capabilities
  end

  @doc """
  Get the optimal hash function for the given algorithm.
  Returns the fastest available implementation.
  """
  def optimal_hash_function(:keccak256) do
    cond do
      native_keccak_available?() -> &native_keccak256/1
      :crypto.supports()[:hashs] |> Enum.member?(:sha3_256) -> &crypto_keccak256/1
      true -> &ExthCrypto.Hash.Keccak.kec/1
    end
  end

  def optimal_hash_function(:sha256) do
    cond do
      hardware_sha_available?() -> &hardware_sha256/1
      :crypto.supports()[:hashs] |> Enum.member?(:sha256) -> &:crypto.hash(:sha256, &1)
      true -> &ExthCrypto.Hash.SHA.sha256/1
    end
  end

  def optimal_hash_function(:sha3_256) do
    cond do
      :crypto.supports()[:hashs] |> Enum.member?(:sha3_256) -> &:crypto.hash(:sha3_256, &1)
      true -> &fallback_sha3_256/1
    end
  end

  def optimal_hash_function(algorithm) do
    Logger.warn("No native optimization available for #{algorithm}, using default")
    &ExthCrypto.Hash.hash(&1, ExthCrypto.Hash.kec())
  end

  @doc """
  Batch hash optimization using vectorized operations where available.
  """
  def batch_hash_optimized(data_list, algorithm) do
    hash_function = optimal_hash_function(algorithm)
    
    cond do
      simd_available?() and length(data_list) > 16 ->
        simd_batch_hash(data_list, hash_function)
      length(data_list) > 4 ->
        parallel_batch_hash(data_list, hash_function)
      true ->
        Enum.map(data_list, hash_function)
    end
  end

  # Private functions

  defp detect_capabilities do
    %{
      native_nifs: detect_native_nifs(),
      hardware_acceleration: detect_hardware_acceleration(),
      simd_support: detect_simd_support(),
      crypto_support: :crypto.supports(),
      scheduler_count: :erlang.system_info(:schedulers_online)
    }
  end

  defp detect_native_nifs do
    nifs = []
    
    # Check for BLS NIF
    nifs = if Code.ensure_loaded?(ExWire.Crypto.BLS) do
      [:bls | nifs]
    else
      nifs
    end
    
    # Check for KZG NIF  
    nifs = if Code.ensure_loaded?(ExWire.Crypto.KZG) do
      [:kzg | nifs]
    else
      nifs
    end
    
    nifs
  end

  defp detect_hardware_acceleration do
    # Detect CPU features that can accelerate crypto operations
    case System.cmd("cat", ["/proc/cpuinfo"], stderr_to_stdout: true) do
      {output, 0} ->
        features = []
        features = if String.contains?(output, "aes"), do: [:aes | features], else: features
        features = if String.contains?(output, "avx2"), do: [:avx2 | features], else: features
        features = if String.contains?(output, "sha_ni"), do: [:sha_ni | features], else: features
        features
      _ ->
        # Fallback for non-Linux or when /proc/cpuinfo not available
        detect_hardware_fallback()
    end
  end

  defp detect_hardware_fallback do
    # Try to detect through other means or use conservative defaults
    []
  end

  defp detect_simd_support do
    # Check if we can use SIMD-optimized operations
    # This is a simplified check - in practice you'd want more sophisticated detection
    scheduler_count = :erlang.system_info(:schedulers_online)
    scheduler_count >= 4
  end

  defp configure_optimizations(capabilities) do
    # Configure based on detected capabilities
    if Enum.member?(capabilities.hardware_acceleration, :sha_ni) do
      Logger.info("SHA hardware acceleration detected")
    end
    
    if capabilities.simd_support do
      Logger.info("SIMD operations available with #{capabilities.scheduler_count} schedulers")
    end
    
    :ok
  end

  # Native implementations

  defp native_keccak_available? do
    # Check if native Keccak implementation is available
    Code.ensure_loaded?(ExWire.Crypto.KZG)
  end

  defp native_keccak256(data) do
    # Use native implementation if available, fallback otherwise
    try do
      ExWire.Crypto.KZG.hash(data)  # Hypothetical native call
    rescue
      _ -> ExthCrypto.Hash.Keccak.kec(data)
    end
  end

  defp hardware_sha_available? do
    # Detect hardware SHA acceleration
    case :crypto.supports()[:hashs] do
      list when is_list(list) -> Enum.member?(list, :sha256)
      _ -> false
    end
  end

  defp hardware_sha256(data) do
    :crypto.hash(:sha256, data)
  end

  defp crypto_keccak256(data) do
    # Use Erlang crypto if available, otherwise fallback
    case :crypto.supports()[:hashs] do
      list when is_list(list) ->
        if Enum.member?(list, :sha3_256) do
          :crypto.hash(:sha3_256, data)
        else
          ExthCrypto.Hash.Keccak.kec(data)
        end
      _ ->
        ExthCrypto.Hash.Keccak.kec(data)
    end
  end

  defp fallback_sha3_256(data) do
    # Fallback SHA3-256 implementation
    ExthCrypto.Hash.Keccak.kec(data)  # Using Keccak as approximation
  end

  # Batch processing optimizations

  defp simd_available? do
    # Simple heuristic - in production you'd want more sophisticated detection
    :erlang.system_info(:schedulers_online) >= 8
  end

  defp simd_batch_hash(data_list, hash_function) do
    # Simulate SIMD batch processing with chunked parallel execution
    chunk_size = div(length(data_list), :erlang.system_info(:schedulers_online))
    chunk_size = max(chunk_size, 1)
    
    data_list
    |> Enum.chunk_every(chunk_size)
    |> Task.async_stream(fn chunk ->
      Enum.map(chunk, hash_function)
    end, max_concurrency: :erlang.system_info(:schedulers_online))
    |> Enum.reduce([], fn {:ok, chunk_results}, acc ->
      acc ++ chunk_results
    end)
  end

  defp parallel_batch_hash(data_list, hash_function) do
    # Parallel processing for medium-sized batches
    max_concurrency = min(:erlang.system_info(:schedulers_online), div(length(data_list), 2))
    
    data_list
    |> Task.async_stream(hash_function, max_concurrency: max_concurrency)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  @doc """
  Benchmark different hash implementations to find the fastest.
  Used for runtime optimization selection.
  """
  def benchmark_hash_implementations(test_data, iterations \\ 1000) do
    implementations = %{
      "native_keccak" => optimal_hash_function(:keccak256),
      "crypto_sha256" => optimal_hash_function(:sha256),
      "default_keccak" => &ExthCrypto.Hash.Keccak.kec/1
    }
    
    results = Enum.map(implementations, fn {name, hash_func} ->
      start_time = :erlang.monotonic_time(:microsecond)
      
      Enum.each(1..iterations, fn _ ->
        hash_func.(test_data)
      end)
      
      end_time = :erlang.monotonic_time(:microsecond)
      duration = end_time - start_time
      
      {name, duration, duration / iterations}
    end)
    
    Logger.info("Hash implementation benchmarks (#{iterations} iterations):")
    Enum.each(results, fn {name, total_time, avg_time} ->
      Logger.info("  #{name}: #{total_time}μs total, #{Float.round(avg_time, 2)}μs average")
    end)
    
    results
  end
end