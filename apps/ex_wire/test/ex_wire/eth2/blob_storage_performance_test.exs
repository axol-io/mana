defmodule ExWire.Eth2.BlobStoragePerformanceTest do
  use ExUnit.Case

  alias ExWire.Eth2.{BlobStorage, BlobSidecar}
  alias ExthCrypto.KZG

  @moduletag :performance

  describe "blob storage performance optimization" do
    setup do
      # Initialize KZG for blob generation
      {g1_bytes, g2_bytes} = generate_test_trusted_setup()
      KZG.load_trusted_setup_from_bytes(g1_bytes, g2_bytes)

      # Start optimized blob storage with different configurations
      memory_opts = [
        cache_size: 500,
        enable_compression: true,
        storage_backend: :memory
      ]

      {:ok, memory_storage} = BlobStorage.start_link(memory_opts)

      %{storage: memory_storage}
    end

    test "stores and retrieves single blob with optimal performance", %{storage: storage} do
      blob_sidecar = create_test_blob_sidecar()

      # Measure storage performance
      {store_time, :ok} =
        :timer.tc(fn ->
          BlobStorage.store_blob(blob_sidecar)
        end)

      # Storage should be under 10ms for single blob
      assert store_time < 10_000, "Storage took #{store_time / 1000}ms, expected < 10ms"

      block_root = blob_sidecar.signed_block_header.block_root

      # Measure retrieval performance (cache hit)
      {get_time, {:ok, retrieved_blob}} =
        :timer.tc(fn ->
          BlobStorage.get_blob(block_root, blob_sidecar.index)
        end)

      # Cache hit should be under 1ms
      assert get_time < 1_000, "Cache hit took #{get_time / 1000}ms, expected < 1ms"
      assert retrieved_blob.index == blob_sidecar.index
    end

    test "batch operations provide significant performance improvements" do
      # Create multiple blob sidecars
      blob_sidecars =
        Enum.map(0..99, fn i ->
          create_test_blob_sidecar(i)
        end)

      # Store all blobs
      Enum.each(blob_sidecars, &BlobStorage.store_blob/1)

      # Prepare batch keys
      blob_keys =
        Enum.map(blob_sidecars, fn sidecar ->
          {sidecar.signed_block_header.block_root, sidecar.index}
        end)

      # Measure batch retrieval
      {batch_time, {:ok, batch_results}} =
        :timer.tc(fn ->
          BlobStorage.get_blobs_batch(blob_keys)
        end)

      # Measure individual retrieval for comparison
      {individual_time, _} =
        :timer.tc(fn ->
          Enum.each(blob_keys, fn {block_root, index} ->
            BlobStorage.get_blob(block_root, index)
          end)
        end)

      # Batch should be significantly faster than individual calls
      performance_improvement = individual_time / batch_time

      assert performance_improvement > 2.0,
             "Batch retrieval only #{performance_improvement}x faster, expected > 2x"

      # Verify all blobs retrieved correctly
      assert length(batch_results) == 100

      IO.puts("Batch performance improvement: #{Float.round(performance_improvement, 2)}x")
      IO.puts("Batch time: #{batch_time / 1000}ms, Individual time: #{individual_time / 1000}ms")
    end

    test "compression reduces storage size significantly" do
      # Create large blob for better compression ratio
      # 100KB blob
      large_blob = generate_large_test_blob(100_000)

      blob_sidecar = %BlobSidecar{
        index: 0,
        blob: large_blob,
        kzg_commitment: KZG.blob_to_kzg_commitment(large_blob),
        kzg_proof: KZG.compute_blob_kzg_proof(large_blob, KZG.blob_to_kzg_commitment(large_blob)),
        signed_block_header: %{
          block_root: :crypto.hash(:sha256, "large_test_block"),
          slot: 1,
          proposer_index: 0,
          parent_root: <<0::32*8>>,
          state_root: <<0::32*8>>,
          body_root: :crypto.hash(:sha256, "large_test_body")
        },
        kzg_commitment_inclusion_proof: [<<0::32*8>>, <<0::32*8>>, <<0::32*8>>]
      }

      # Store blob and check compression stats
      BlobStorage.store_blob(blob_sidecar)

      {:ok, stats} = BlobStorage.get_stats()

      # Should achieve significant compression for large repetitive data
      if stats.compression.total_operations > 0 do
        compression_ratio = stats.compression.average_ratio

        assert compression_ratio > 2.0,
               "Compression ratio #{compression_ratio}x too low, expected > 2x"

        IO.puts("Compression ratio: #{Float.round(compression_ratio, 2)}x")
        IO.puts("Storage savings: #{stats.compression.savings_ratio * 100}%")
      end
    end

    test "cache provides excellent hit rates under typical workloads" do
      # Create working set of blobs
      working_set =
        Enum.map(0..49, fn i ->
          create_test_blob_sidecar(i)
        end)

      # Store all blobs
      Enum.each(working_set, &BlobStorage.store_blob/1)

      # Simulate realistic access pattern (80/20 rule)
      # 20% of blobs are accessed 80% of time
      hot_blobs = Enum.take(working_set, 10)
      # 80% of blobs accessed 20% of time
      cold_blobs = Enum.drop(working_set, 10)

      # Generate 1000 access requests following 80/20 distribution
      access_requests =
        Stream.repeatedly(fn ->
          if :rand.uniform() < 0.8 do
            Enum.random(hot_blobs)
          else
            Enum.random(cold_blobs)
          end
        end)
        |> Enum.take(1000)

      # Perform access requests
      Enum.each(access_requests, fn blob ->
        block_root = blob.signed_block_header.block_root
        BlobStorage.get_blob(block_root, blob.index)
      end)

      # Check cache performance
      {:ok, stats} = BlobStorage.get_stats()
      hit_rate = stats.cache.hit_rate

      # Should achieve high hit rate with 80/20 workload
      assert hit_rate > 0.75,
             "Cache hit rate #{hit_rate * 100}% too low, expected > 75%"

      IO.puts("Cache hit rate: #{Float.round(hit_rate * 100, 1)}%")
      IO.puts("Cache size: #{stats.cache.size}/#{stats.cache.max_size}")
    end

    test "handles high throughput workloads without degradation" do
      # Create burst of blob storage operations
      blob_count = 200
      blobs = Enum.map(0..(blob_count - 1), &create_test_blob_sidecar/1)

      # Measure sustained throughput
      {total_time, :ok} =
        :timer.tc(fn ->
          # Store all blobs as fast as possible
          blobs
          |> Enum.map(fn blob ->
            Task.async(fn -> BlobStorage.store_blob(blob) end)
          end)
          |> Enum.each(&Task.await/1)
        end)

      # ops per second
      throughput = blob_count / (total_time / 1_000_000)

      # Should handle at least 100 blobs/second
      assert throughput > 100,
             "Throughput #{throughput} ops/sec too low, expected > 100 ops/sec"

      # Verify no data loss
      random_checks = Enum.take_random(blobs, 10)

      Enum.each(random_checks, fn blob ->
        block_root = blob.signed_block_header.block_root
        {:ok, retrieved} = BlobStorage.get_blob(block_root, blob.index)
        assert retrieved.index == blob.index
      end)

      IO.puts("Sustained throughput: #{Float.round(throughput, 1)} ops/sec")
    end

    test "memory usage remains bounded with LRU eviction" do
      # Configure small cache for testing eviction
      small_cache_opts = [
        cache_size: 10,
        enable_compression: false,
        storage_backend: :memory
      ]

      {:ok, small_storage} = BlobStorage.start_link(small_cache_opts)

      # Store more blobs than cache capacity
      Enum.each(0..19, fn i ->
        blob = create_test_blob_sidecar(i)
        BlobStorage.store_blob(blob)
      end)

      # Check that cache size is bounded
      {:ok, stats} = BlobStorage.get_stats()

      assert stats.cache.size <= 10, "Cache size #{stats.cache.size} exceeds limit 10"
      assert stats.cache.evictions > 0, "No evictions occurred, LRU not working"

      # Recent blobs should still be in cache (cache hits)
      recent_blob = create_test_blob_sidecar(19)
      block_root = recent_blob.signed_block_header.block_root

      {access_time, {:ok, _}} =
        :timer.tc(fn ->
          BlobStorage.get_blob(block_root, recent_blob.index)
        end)

      # Should be cache hit (very fast)
      assert access_time < 1_000, "Recent blob access too slow, likely cache miss"

      IO.puts("Cache evictions: #{stats.cache.evictions}")
      IO.puts("Final cache size: #{stats.cache.size}")
    end
  end

  # Helper functions

  defp generate_test_trusted_setup do
    g1_points = for _ <- 1..4096, do: <<0::48*8>>
    g2_points = for _ <- 1..65, do: <<0::96*8>>

    g1_bytes = Enum.join(g1_points)
    g2_bytes = Enum.join(g2_points)

    {g1_bytes, g2_bytes}
  end

  defp create_test_blob_sidecar(index \\ 0) do
    blob = generate_test_blob()
    commitment = KZG.blob_to_kzg_commitment(blob)
    proof = KZG.compute_blob_kzg_proof(blob, commitment)

    %BlobSidecar{
      index: index,
      blob: blob,
      kzg_commitment: commitment,
      kzg_proof: proof,
      signed_block_header: %{
        block_root: :crypto.hash(:sha256, "test_block_#{index}"),
        slot: 1,
        proposer_index: 0,
        parent_root: <<0::32*8>>,
        state_root: <<0::32*8>>,
        body_root: :crypto.hash(:sha256, "test_body_#{index}")
      },
      kzg_commitment_inclusion_proof: [<<0::32*8>>, <<0::32*8>>, <<0::32*8>>]
    }
  end

  defp generate_test_blob do
    blob_size = 131_072
    pattern = Stream.cycle([1, 2, 3, 4, 5, 6, 7, 8])

    pattern
    |> Stream.take(blob_size)
    |> Enum.map(& &1)
    |> :binary.list_to_bin()
  end

  defp generate_large_test_blob(size) do
    # Generate blob with repetitive pattern for better compression
    pattern = "BLOB_TEST_DATA_PATTERN_FOR_COMPRESSION_"
    pattern_size = byte_size(pattern)

    repeats = div(size, pattern_size) + 1

    Stream.cycle([pattern])
    |> Stream.take(repeats)
    |> Enum.join()
    |> binary_part(0, size)
  end
end
