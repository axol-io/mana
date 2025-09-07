defmodule ExWire.Eth2.BlobStorage do
  @moduledoc """
  High-performance blob storage layer with caching, compression, and optimized retrieval.

  Features:
  - LRU cache with configurable size limits
  - Blob compression using LZ4 for storage efficiency
  - Parallel retrieval for batch operations
  - Metrics and monitoring integration
  - Graceful degradation under high load
  """

  use GenServer
  require Logger

  alias ExWire.Eth2.BlobMetrics

  # Number of blobs to cache in memory
  @default_cache_size 1000
  # Cache TTL in seconds (1 hour)
  @default_cache_ttl 3600
  # Compress blobs larger than 32KB
  @default_compression_threshold 32_768
  # EIP-4844: Minimum 18-day retention period
  @blob_retention_days 18

  defstruct [
    # LRU cache for hot blobs
    :cache,
    # Storage backend (memory/disk/database)
    :storage_backend,
    # Metrics collection
    :metrics,
    # Configuration settings
    :config,
    # Compression settings
    :compression,
    # Timer for cleanup tasks
    :cleanup_timer
  ]

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Store a blob sidecar with automatic compression and caching.
  """
  def store_blob(blob_sidecar, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:store_blob, blob_sidecar, opts})
  end

  @doc """
  Retrieve a blob sidecar by block root and index.
  """
  def get_blob(block_root, index, server \\ __MODULE__) do
    GenServer.call(server, {:get_blob, block_root, index})
  end

  @doc """
  Retrieve multiple blobs in parallel for batch operations.
  """
  def get_blobs_batch(blob_keys, server \\ __MODULE__) do
    GenServer.call(server, {:get_blobs_batch, blob_keys}, 30_000)
  end

  @doc """
  Check if a blob exists without loading it into memory.
  """
  def blob_exists?(block_root, index, server \\ __MODULE__) do
    GenServer.call(server, {:blob_exists, block_root, index})
  end

  @doc """
  Get storage statistics and performance metrics.
  """
  def get_stats(server \\ __MODULE__) do
    GenServer.call(server, :get_stats)
  end

  @doc """
  Prune old blobs based on EIP-4844 retention policy (18 days minimum).
  """
  def prune_old_blobs do
    GenServer.cast(__MODULE__, :prune_old_blobs)
  end

  @doc """
  Check if a blob is still within the retention period.
  """
  def is_blob_available?(slot) do
    # Calculate if blob is within 18-day retention period
    current_time = System.system_time(:second)
    # 12 seconds per slot
    blob_time = slot * 12
    age_seconds = current_time - blob_time
    age_days = age_seconds / (24 * 60 * 60)

    age_days <= @blob_retention_days
  end

  @doc """
  Preload blobs into cache for anticipated access.
  """
  def preload_blobs(blob_keys) do
    GenServer.cast(__MODULE__, {:preload_blobs, blob_keys})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting BlobStorage with optimized performance settings")

    config = build_config(opts)
    cache = initialize_cache(config)
    storage_backend = initialize_storage_backend(config)
    metrics = BlobMetrics.init()
    compression = initialize_compression(config)

    # Schedule periodic cleanup
    cleanup_timer = schedule_cleanup()

    state = %__MODULE__{
      cache: cache,
      storage_backend: storage_backend,
      metrics: metrics,
      config: config,
      compression: compression,
      cleanup_timer: cleanup_timer
    }

    Logger.info(
      "BlobStorage initialized with cache_size=#{config.cache_size}, compression=#{config.enable_compression}"
    )

    {:ok, _state}
  end

  @impl true
  def handle_call({:store_blob, blob_sidecar, opts}, _from, _state) do
    start_time = System.monotonic_time()

    try do
      blob_key = generate_blob_key(blob_sidecar)

      # Compress blob if enabled and above threshold
      {compressed_data, compression_ratio} = maybe_compress_blob(blob_sidecar, state.compression)

      # Store in cache
      state = put_cache(state, blob_key, blob_sidecar)

      # Store in persistent storage
      storage_result = store_to_backend(state.storage_backend, blob_key, compressed_data, opts)

      # Update metrics
      duration = System.monotonic_time() - start_time
      state = update_metrics(state, :store, duration, compression_ratio)

      case storage_result do
        :ok ->
          Logger.debug("Stored blob #{inspect(blob_key)} with #{compression_ratio}x compression")
          {:reply, :ok, state}

        {:error, _reason} ->
          Logger.error("Failed to store blob #{inspect(blob_key)}: #{inspect(reason)}")
          {:reply, {:error, _reason}, state}
      end
    rescue
      error ->
        Logger.error("Exception storing blob: #{inspect(error)}")
        {:reply, {:error, :storage_exception}, state}
    end
  end

  @impl true
  def handle_call({:get_blob, block_root, index}, _from, _state) do
    start_time = System.monotonic_time()
    blob_key = {block_root, index}

    # Try cache first
    case get_from_cache(state.cache, blob_key) do
      {:hit, blob_sidecar} ->
        duration = System.monotonic_time() - start_time
        state = update_metrics(state, :cache_hit, duration, 1.0)

        Logger.debug("Cache hit for blob #{inspect(blob_key)}")
        {:reply, {:ok, blob_sidecar}, state}

      :miss ->
        # Load from storage
        case load_from_backend(state.storage_backend, blob_key, state.compression) do
          {:ok, blob_sidecar} ->
            # Update cache
            state = put_cache(state, blob_key, blob_sidecar)

            duration = System.monotonic_time() - start_time
            state = update_metrics(state, :cache_miss, duration, 1.0)

            Logger.debug("Cache miss for blob #{inspect(blob_key)}, loaded from storage")
            {:reply, {:ok, blob_sidecar}, state}

          {:error, :not_found} ->
            duration = System.monotonic_time() - start_time
            state = update_metrics(state, :not_found, duration, 1.0)
            {:reply, {:error, :not_found}, state}

          {:error, _reason} ->
            Logger.error("Failed to load blob #{inspect(blob_key)}: #{inspect(reason)}")
            {:reply, {:error, _reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_blobs_batch, blob_keys}, _from, _state) do
    start_time = System.monotonic_time()

    # Parallel retrieval for better performance
    task_results =
      blob_keys
      |> Enum.map(fn {block_root, index} ->
        Task.async(fn ->
          blob_key = {block_root, index}

          # Try cache first
          case get_from_cache(state.cache, blob_key) do
            {:hit, blob_sidecar} ->
              {blob_key, {:ok, blob_sidecar}}

            :miss ->
              # Load from storage
              case load_from_backend(state.storage_backend, blob_key, state.compression) do
                {:ok, blob_sidecar} ->
                  {blob_key, {:ok, blob_sidecar}}

                error ->
                  {blob_key, error}
              end
          end
        end)
      end)
      |> Enum.map(&Task.await(&1, 10_000))

    # Update cache with loaded blobs and collect results
    {results, cache_updates} =
      task_results
      |> Enum.map_reduce([], fn {blob_key, result}, acc ->
        case result do
          {:ok, blob_sidecar} ->
            {{blob_key, {:ok, blob_sidecar}}, [blob_key | acc]}

          error ->
            {{blob_key, error}, acc}
        end
      end)

    # Batch update cache
    state =
      Enum.reduce(cache_updates, state, fn blob_key, acc_state ->
        case Enum.find(results, fn {k, _} -> k == blob_key end) do
          {_, {:ok, blob_sidecar}} -> put_cache(acc_state, blob_key, blob_sidecar)
          _ -> acc_state
        end
      end)

    duration = System.monotonic_time() - start_time
    state = update_metrics(state, :batch_get, duration, length(blob_keys))

    Logger.info(
      "Batch loaded #{length(blob_keys)} blobs in #{duration |> System.convert_time_unit(:native, :millisecond)}ms"
    )

    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_call({:blob_exists, block_root, index}, _from, _state) do
    blob_key = {block_root, index}

    # Check cache first
    exists =
      case get_from_cache(state.cache, blob_key) do
        {:hit, _} -> true
        :miss -> backend_has_blob?(state.storage_backend, blob_key)
      end

    {:reply, exists, state}
  end

  @impl true
  def handle_call(:get_stats, _from, _state) do
    cache_stats = get_cache_stats(state.cache)
    storage_stats = get_storage_stats(state.storage_backend)

    stats = %{
      cache: cache_stats,
      storage: storage_stats,
      metrics: BlobMetrics.get_stats(state.metrics),
      config: %{
        cache_size: state.config.cache_size,
        compression_enabled: state.config.enable_compression,
        compression_threshold: state.config.compression_threshold
      }
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast(:prune_old_blobs, _state) do
    Logger.info("Starting blob pruning operation")
    start_time = System.monotonic_time()

    cutoff_time = System.system_time(:second) - state.config.retention_days * 24 * 3600

    case prune_storage_backend(state.storage_backend, cutoff_time) do
      {:ok, pruned_count} ->
        duration = System.monotonic_time() - start_time

        Logger.info(
          "Pruned #{pruned_count} old blobs in #{duration |> System.convert_time_unit(:native, :millisecond)}ms"
        )

      {:error, _reason} ->
        Logger.error("Failed to prune blobs: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:preload_blobs, blob_keys}, _state) do
    Logger.debug("Preloading #{length(blob_keys)} blobs into cache")

    # Preload in background without blocking
    Task.start(fn ->
      Enum.each(blob_keys, fn {block_root, index} ->
        blob_key = {block_root, index}

        # Skip if already in cache
        case get_from_cache(state.cache, blob_key) do
          {:hit, _} ->
            :skip

          :miss ->
            case load_from_backend(state.storage_backend, blob_key, state.compression) do
              {:ok, blob_sidecar} ->
                GenServer.cast(__MODULE__, {:cache_update, blob_key, blob_sidecar})

              _ ->
                :skip
            end
        end
      end)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:cache_update, blob_key, blob_sidecar}, _state) do
    state = put_cache(state, blob_key, blob_sidecar)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, _state) do
    # Periodic cleanup tasks
    perform_maintenance(state)

    # Schedule next cleanup
    cleanup_timer = schedule_cleanup()
    state = %{state | cleanup_timer: cleanup_timer}

    {:noreply, state}
  end

  # Private Functions - Configuration

  defp build_config(opts) do
    %{
      cache_size: Keyword.get(opts, :cache_size, @default_cache_size),
      cache_ttl: Keyword.get(opts, :cache_ttl, @default_cache_ttl),
      enable_compression: Keyword.get(opts, :enable_compression, true),
      compression_threshold:
        Keyword.get(opts, :compression_threshold, @default_compression_threshold),
      storage_backend: Keyword.get(opts, :storage_backend, :memory),
      retention_days: Keyword.get(opts, :retention_days, @blob_retention_days)
    }
  end

  # Private Functions - Cache Management

  defp initialize_cache(_config) do
    %{
      data: %{},
      lru_order: [],
      max_size: config.cache_size,
      ttl: config.cache_ttl,
      stats: %{hits: 0, misses: 0, evictions: 0}
    }
  end

  defp get_from_cache(cache, key) do
    case Map.get(cache.data, key) do
      nil ->
        :miss

      {blob_sidecar, timestamp} ->
        # Check TTL
        if System.system_time(:second) - timestamp < cache.ttl do
          {:hit, blob_sidecar}
        else
          :miss
        end
    end
  end

  defp put_cache(_state, key, blob_sidecar) do
    cache = state.cache
    timestamp = System.system_time(:second)

    # Remove from current position in LRU if exists
    lru_order = List.delete(cache.lru_order, key)

    # Add to front of LRU
    lru_order = [key | lru_order]

    # Add/update data
    data = Map.put(cache.data, key, {blob_sidecar, timestamp})

    # Evict if over capacity
    {data, lru_order, evictions} = maybe_evict_cache(data, lru_order, cache.max_size)

    # Update stats
    stats = %{cache.stats | evictions: cache.stats.evictions + evictions}

    new_cache = %{cache | data: data, lru_order: lru_order, stats: stats}

    %{state | cache: new_cache}
  end

  defp maybe_evict_cache(data, lru_order, max_size) do
    if map_size(data) > max_size do
      # Remove least recently used
      {to_evict, remaining_lru} = List.pop_at(lru_order, -1)
      data = Map.delete(data, to_evict)
      {data, remaining_lru, 1}
    else
      {data, lru_order, 0}
    end
  end

  defp get_cache_stats(cache) do
    %{
      size: map_size(cache.data),
      max_size: cache.max_size,
      hit_rate: calculate_hit_rate(cache.stats),
      evictions: cache.stats.evictions
    }
  end

  defp calculate_hit_rate(%{hits: hits, misses: misses}) when hits + misses > 0 do
    hits / (hits + misses)
  end

  defp calculate_hit_rate(_), do: 0.0

  # Private Functions - Compression

  defp initialize_compression(_config) do
    %{
      enabled: config.enable_compression,
      threshold: config.compression_threshold,
      # Using Erlang's built-in compression
      algorithm: :zlib
    }
  end

  defp maybe_compress_blob(blob_sidecar, compression) do
    blob_data = :erlang.term_to_binary(blob_sidecar)

    if compression.enabled && byte_size(blob_data) > compression.threshold do
      # Use Erlang's built-in compression (zlib)
      compressed = :zlib.compress(blob_data)
      ratio = byte_size(blob_data) / byte_size(compressed)
      {{:compressed, compressed}, ratio}
    else
      {blob_data, 1.0}
    end
  end

  defp maybe_decompress_blob({:compressed, compressed_data}) do
    try do
      data = :zlib.uncompress(compressed_data)
      :erlang.binary_to_term(data)
    rescue
      error ->
        {:error, {:decompression_failed, error}}
    end
  end

  defp maybe_decompress_blob(uncompressed_data) do
    :erlang.binary_to_term(uncompressed_data)
  end

  # Private Functions - Storage Backend

  defp initialize_storage_backend(_config) do
    case config.storage_backend do
      :memory ->
        %{type: :memory, data: %{}}

      :disk ->
        storage_dir = Application.get_env(:ex_wire, :blob_storage_dir, "./blob_storage")
        File.mkdir_p!(storage_dir)
        %{type: :disk, path: storage_dir}

      {:database, opts} ->
        %{type: :database, opts: opts}
    end
  end

  defp store_to_backend(%{type: :memory} = backend, key, data, _opts) do
    backend = %{backend | data: Map.put(backend.data, key, {data, System.system_time(:second)})}
    :ok
  end

  defp store_to_backend(%{type: :disk} = backend, key, data, _opts) do
    file_path = blob_file_path(backend.path, key)

    case File.write(file_path, data) do
      :ok -> :ok
      {:error, _reason} -> {:error, _reason}
    end
  end

  defp load_from_backend(%{type: :memory} = backend, key, compression) do
    case Map.get(backend.data, key) do
      {data, _timestamp} ->
        blob_sidecar = maybe_decompress_blob(data)
        {:ok, blob_sidecar}

      nil ->
        {:error, :not_found}
    end
  end

  defp load_from_backend(%{type: :disk} = backend, key, compression) do
    file_path = blob_file_path(backend.path, key)

    case File.read(file_path) do
      {:ok, data} ->
        blob_sidecar = maybe_decompress_blob(data)
        {:ok, blob_sidecar}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, _reason}
    end
  end

  defp backend_has_blob?(%{type: :memory} = backend, key) do
    Map.has_key?(backend.data, key)
  end

  defp backend_has_blob?(%{type: :disk} = backend, key) do
    file_path = blob_file_path(backend.path, key)
    File.exists?(file_path)
  end

  defp get_storage_stats(%{type: :memory} = backend) do
    %{
      type: :memory,
      total_blobs: map_size(backend.data),
      storage_size_bytes: estimate_memory_usage(backend.data)
    }
  end

  defp get_storage_stats(%{type: :disk} = backend) do
    case File.ls(backend.path) do
      {:ok, files} ->
        total_size =
          files
          |> Enum.map(&Path.join(backend.path, &1))
          |> Enum.map(&File.stat!/1)
          |> Enum.map(& &1.size)
          |> Enum.sum()

        %{
          type: :disk,
          total_blobs: length(files),
          storage_size_bytes: total_size
        }

      {:error, _} ->
        %{type: :disk, total_blobs: 0, storage_size_bytes: 0}
    end
  end

  defp prune_storage_backend(%{type: :memory} = backend, cutoff_time) do
    original_size = map_size(backend.data)

    pruned_data =
      backend.data
      |> Enum.filter(fn {_key, {_data, timestamp}} ->
        timestamp > cutoff_time
      end)
      |> Enum.into(%{})

    pruned_count = original_size - map_size(pruned_data)
    {:ok, pruned_count}
  end

  defp prune_storage_backend(%{type: :disk} = backend, cutoff_time) do
    case File.ls(backend.path) do
      {:ok, files} ->
        pruned_count =
          files
          |> Enum.map(&Path.join(backend.path, &1))
          |> Enum.filter(fn file_path ->
            case File.stat(file_path) do
              {:ok, %{mtime: mtime}} ->
                file_timestamp = :calendar.datetime_to_gregorian_seconds(mtime)

                if file_timestamp < cutoff_time do
                  File.rm(file_path)
                  true
                else
                  false
                end

              _ ->
                false
            end
          end)
          |> length()

        {:ok, pruned_count}

      {:error, _reason} ->
        {:error, _reason}
    end
  end

  # Private Functions - Helpers

  defp generate_blob_key(blob_sidecar) do
    block_root = blob_sidecar.signed_block_header.block_root || <<0::32*8>>
    {block_root, blob_sidecar.index}
  end

  defp blob_file_path(storage_path, {block_root, index}) do
    block_hex = Base.encode16(block_root, case: :lower)
    filename = "#{block_hex}_#{index}.blob"
    Path.join(storage_path, filename)
  end

  defp estimate_memory_usage(data) do
    data
    |> Enum.map(fn {key, {value, _timestamp}} ->
      :erlang.external_size(key) + :erlang.external_size(value)
    end)
    |> Enum.sum()
  end

  defp update_metrics(_state, operation, duration, value) do
    metrics = BlobMetrics.record(state.metrics, operation, duration, value)
    %{state | metrics: metrics}
  end

  defp schedule_cleanup do
    # 5 minutes
    Process.send_after(self(), :cleanup, 300_000)
  end

  defp perform_maintenance(_state) do
    # Clean expired cache entries
    Logger.debug("Performing blob storage maintenance")

    # Could add more maintenance tasks here:
    # - Defragment storage
    # - Update metrics
    # - Health checks
    :ok
  end
end
