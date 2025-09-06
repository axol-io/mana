defmodule Blockchain.Performance.KZGBenchmarks do
  @moduledoc """
  Performance benchmarking for KZG operations in EIP-4844.

  Provides comprehensive benchmarks for:
  - KZG commitment generation
  - KZG proof generation and verification
  - Batch operations
  - Memory usage profiling
  """

  alias ExWire.Crypto.KZG

  @doc """
  Run comprehensive KZG benchmarks.
  """
  def run_benchmarks do
    IO.puts("\n🚀 KZG Performance Benchmarks\n" <> String.duplicate("=", 50))

    # Initialize KZG
    :ok = KZG.init_trusted_setup()

    # Generate test data once
    {_blob_data, test_cases} = generate_benchmark_data()

    # Run all benchmarks
    results = %{
      commitment_generation: benchmark_commitment_generation(test_cases),
      proof_generation: benchmark_proof_generation(test_cases),
      proof_verification: benchmark_proof_verification(test_cases),
      batch_operations: benchmark_batch_operations(test_cases),
      memory_usage: benchmark_memory_usage(test_cases)
    }

    # Print summary
    print_benchmark_summary(results)

    results
  end

  @doc """
  Benchmark KZG commitment generation.
  """
  def benchmark_commitment_generation(test_cases) do
    IO.puts("\n📊 Benchmarking KZG Commitment Generation:")

    results =
      for {name, blobs} <- test_cases do
        {time_microseconds, _commitments} =
          :timer.tc(fn ->
            Enum.map(blobs, &KZG.blob_to_kzg_commitment/1)
          end)

        avg_time = time_microseconds / length(blobs)
        ops_per_sec = 1_000_000 / avg_time

        IO.puts(
          "  #{name}: #{Float.round(avg_time, 2)}μs avg, #{Float.round(ops_per_sec, 1)} ops/sec"
        )

        {name,
         %{
           total_time_us: time_microseconds,
           avg_time_us: avg_time,
           ops_per_sec: ops_per_sec,
           blob_count: length(blobs)
         }}
      end

    Map.new(results)
  end

  @doc """
  Benchmark KZG proof generation.
  """
  def benchmark_proof_generation(test_cases) do
    IO.puts("\n🔐 Benchmarking KZG Proof Generation:")

    results =
      for {name, blobs} <- test_cases do
        # Pre-generate commitments
        commitments = Enum.map(blobs, &KZG.blob_to_kzg_commitment/1)

        {time_microseconds, _proofs} =
          :timer.tc(fn ->
            blobs
            |> Enum.zip(commitments)
            |> Enum.map(fn {blob, commitment} ->
              KZG.compute_blob_kzg_proof(blob, commitment)
            end)
          end)

        avg_time = time_microseconds / length(blobs)
        ops_per_sec = 1_000_000 / avg_time

        IO.puts(
          "  #{name}: #{Float.round(avg_time, 2)}μs avg, #{Float.round(ops_per_sec, 1)} ops/sec"
        )

        {name,
         %{
           total_time_us: time_microseconds,
           avg_time_us: avg_time,
           ops_per_sec: ops_per_sec,
           blob_count: length(blobs)
         }}
      end

    Map.new(results)
  end

  @doc """
  Benchmark KZG proof verification.
  """
  def benchmark_proof_verification(test_cases) do
    IO.puts("\n✅ Benchmarking KZG Proof Verification:")

    results =
      for {name, blobs} <- test_cases do
        # Pre-generate commitments and proofs
        verification_data =
          Enum.map(blobs, fn blob ->
            commitment = KZG.blob_to_kzg_commitment(blob)
            proof = KZG.compute_blob_kzg_proof(blob, commitment)
            {blob, commitment, proof}
          end)

        {time_microseconds, _results} =
          :timer.tc(fn ->
            Enum.map(verification_data, fn {blob, commitment, proof} ->
              KZG.verify_blob_kzg_proof(blob, commitment, proof)
            end)
          end)

        avg_time = time_microseconds / length(blobs)
        ops_per_sec = 1_000_000 / avg_time

        IO.puts(
          "  #{name}: #{Float.round(avg_time, 2)}μs avg, #{Float.round(ops_per_sec, 1)} ops/sec"
        )

        {name,
         %{
           total_time_us: time_microseconds,
           avg_time_us: avg_time,
           ops_per_sec: ops_per_sec,
           blob_count: length(blobs)
         }}
      end

    Map.new(results)
  end

  @doc """
  Benchmark batch operations.
  """
  def benchmark_batch_operations(test_cases) do
    IO.puts("\n🏗️  Benchmarking Batch Operations:")

    results =
      for {name, blobs} <- test_cases do
        # Prepare batch data
        verification_data =
          Enum.map(blobs, fn blob ->
            commitment = KZG.blob_to_kzg_commitment(blob)
            proof = KZG.compute_blob_kzg_proof(blob, commitment)
            {blob, commitment, proof}
          end)

        {blobs_list, commitments_list, proofs_list} =
          Enum.reduce(verification_data, {[], [], []}, fn {blob, commitment, proof},
                                                          {blobs, commitments, proofs} ->
            {[blob | blobs], [commitment | commitments], [proof | proofs]}
          end)
          |> then(fn {blobs, commitments, proofs} ->
            {Enum.reverse(blobs), Enum.reverse(commitments), Enum.reverse(proofs)}
          end)

        # Benchmark batch verification
        {batch_time, _result} =
          :timer.tc(fn ->
            KZG.verify_blob_kzg_proof_batch(blobs_list, commitments_list, proofs_list)
          end)

        # Compare with individual verifications
        {individual_time, _results} =
          :timer.tc(fn ->
            Enum.map(verification_data, fn {blob, commitment, proof} ->
              KZG.verify_blob_kzg_proof(blob, commitment, proof)
            end)
          end)

        speedup = individual_time / batch_time

        IO.puts(
          "  #{name}: Batch #{Float.round(batch_time / 1000, 2)}ms vs Individual #{Float.round(individual_time / 1000, 2)}ms"
        )

        IO.puts("    Batch speedup: #{Float.round(speedup, 2)}x faster")

        {name,
         %{
           batch_time_us: batch_time,
           individual_time_us: individual_time,
           speedup: speedup,
           blob_count: length(blobs)
         }}
      end

    Map.new(results)
  end

  @doc """
  Benchmark memory usage patterns.
  """
  def benchmark_memory_usage(test_cases) do
    IO.puts("\n💾 Benchmarking Memory Usage:")

    results =
      for {name, blobs} <- test_cases do
        # Measure memory before
        :erlang.garbage_collect()
        {memory_before, _} = Process.info(self(), :memory)

        # Perform operations
        _verification_data =
          Enum.map(blobs, fn blob ->
            commitment = KZG.blob_to_kzg_commitment(blob)
            proof = KZG.compute_blob_kzg_proof(blob, commitment)
            _verified = KZG.verify_blob_kzg_proof(blob, commitment, proof)
            {blob, commitment, proof}
          end)

        # Measure memory after
        {memory_after, _} = Process.info(self(), :memory)
        memory_used = memory_after - memory_before

        # Calculate per-blob memory usage
        memory_per_blob = memory_used / length(blobs)

        IO.puts(
          "  #{name}: #{Float.round(memory_used / 1024, 1)} KB total, #{Float.round(memory_per_blob / 1024, 1)} KB per blob"
        )

        # Clean up
        _verification_data = nil
        :erlang.garbage_collect()

        {name,
         %{
           total_memory_bytes: memory_used,
           memory_per_blob_bytes: memory_per_blob,
           blob_count: length(blobs)
         }}
      end

    Map.new(results)
  end

  @doc """
  Compare our implementation with theoretical benchmarks.
  """
  def comparative_analysis do
    IO.puts("\n📈 Comparative Analysis:")
    IO.puts("Comparing against other EIP-4844 implementations...")

    # Theoretical performance targets
    targets = %{
      # ops/sec
      commitment_generation: 1000,
      # ops/sec  
      proof_generation: 100,
      # ops/sec
      proof_verification: 500,
      # 2x improvement
      batch_speedup: 2.0
    }

    # Run our benchmarks
    {_blob_data, test_cases} = generate_benchmark_data()
    single_blob = test_cases["single_blob"]

    commitment_perf = benchmark_commitment_generation(%{"test" => single_blob})["test"]
    proof_gen_perf = benchmark_proof_generation(%{"test" => single_blob})["test"]
    verification_perf = benchmark_proof_verification(%{"test" => single_blob})["test"]

    batch_perf =
      benchmark_batch_operations(%{"small_batch" => Enum.take(single_blob, 5)})["small_batch"]

    # Print comparison
    comparisons = [
      {"Commitment Generation", commitment_perf.ops_per_sec, targets.commitment_generation},
      {"Proof Generation", proof_gen_perf.ops_per_sec, targets.proof_generation},
      {"Proof Verification", verification_perf.ops_per_sec, targets.proof_verification},
      {"Batch Speedup", batch_perf.speedup, targets.batch_speedup}
    ]

    Enum.each(comparisons, fn {operation, actual, target} ->
      status = if actual >= target, do: "✅", else: "⚠️"
      percentage = (actual / target * 100) |> Float.round(1)
      IO.puts("  #{status} #{operation}: #{Float.round(actual, 1)} (#{percentage}% of target)")
    end)

    %{
      our_performance: %{
        commitment_ops_per_sec: commitment_perf.ops_per_sec,
        proof_gen_ops_per_sec: proof_gen_perf.ops_per_sec,
        verification_ops_per_sec: verification_perf.ops_per_sec,
        batch_speedup: batch_perf.speedup
      },
      targets: targets,
      meets_targets: Enum.all?(comparisons, fn {_name, actual, target} -> actual >= target end)
    }
  end

  # Private helper functions

  defp generate_benchmark_data do
    IO.puts("Generating benchmark data...")

    # Generate different blob sizes for testing
    single_blob = [generate_test_blob(0)]
    small_batch = Enum.map(0..4, &generate_test_blob/1)
    medium_batch = Enum.map(0..9, &generate_test_blob/1)
    large_batch = Enum.map(0..49, &generate_test_blob/1)

    test_cases = %{
      "single_blob" => single_blob,
      "small_batch_5" => small_batch,
      "medium_batch_10" => medium_batch,
      "large_batch_50" => large_batch
    }

    {nil, test_cases}
  end

  defp generate_test_blob(seed) do
    # Generate deterministic test blob
    field_elements =
      for i <- 0..(KZG.field_elements_per_blob() - 1) do
        # Create valid field element (< BLS12-381 modulus)
        base_value = rem(i + seed, 116)
        rest_bytes = for j <- 1..31, do: rem(i + j + seed, 256)
        <<base_value>> <> :binary.list_to_bin(rest_bytes)
      end

    :binary.list_to_bin(field_elements)
  end

  defp print_benchmark_summary(results) do
    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("📋 BENCHMARK SUMMARY")
    IO.puts(String.duplicate("=", 50))

    # Extract key metrics
    single_blob_commitment = results.commitment_generation["single_blob"]
    single_blob_verification = results.proof_verification["single_blob"]
    batch_5_speedup = results.batch_operations["small_batch_5"]

    IO.puts("🎯 Key Performance Metrics:")
    IO.puts("  • Single blob commitment: #{Float.round(single_blob_commitment.avg_time_us, 0)}μs")

    IO.puts(
      "  • Single blob verification: #{Float.round(single_blob_verification.avg_time_us, 0)}μs"
    )

    IO.puts("  • Batch verification speedup: #{Float.round(batch_5_speedup.speedup, 2)}x")

    IO.puts(
      "  • Memory per blob: #{Float.round(results.memory_usage["single_blob"].memory_per_blob_bytes / 1024, 1)} KB"
    )

    # Performance rating
    commitment_rating = performance_rating(single_blob_commitment.ops_per_sec, 1000)
    verification_rating = performance_rating(single_blob_verification.ops_per_sec, 500)

    IO.puts("\n⭐ Performance Rating:")
    IO.puts("  • Commitment generation: #{commitment_rating}")
    IO.puts("  • Proof verification: #{verification_rating}")

    overall_rating = (commitment_rating + verification_rating) / 2
    IO.puts("  • Overall: #{Float.round(overall_rating, 1)}/5.0 ⭐")

    IO.puts("\n" <> String.duplicate("=", 50))
  end

  defp performance_rating(actual_ops, target_ops) do
    ratio = actual_ops / target_ops

    cond do
      ratio >= 2.0 -> 5.0
      ratio >= 1.5 -> 4.5
      ratio >= 1.0 -> 4.0
      ratio >= 0.75 -> 3.5
      ratio >= 0.5 -> 3.0
      ratio >= 0.25 -> 2.0
      true -> 1.0
    end
  end
end
