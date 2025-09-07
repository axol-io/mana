defmodule ExthCrypto.Hash.Cache do
  @moduledoc """
  High-performance LRU cache for hash operations with TTL support.
  
  Optimizes hash operations by caching frequently computed hashes,
  targeting 3-5x performance improvement for repeated hash calculations.
  
  Features:
  - LRU eviction policy with configurable size
  - TTL (Time To Live) support for cache expiration
  - Efficient ETS-based storage
  - Background cleanup process
  - Memory-efficient binary key storage
  """

  use GenServer
  require Logger

  @default_config %{
    max_size: 10_000,
    ttl: 300_000,  # 5 minutes in milliseconds
    cleanup_interval: 60_000,  # 1 minute cleanup interval
    enable_stats: true
  }

  # Client API

  @doc """
  Starts the hash cache with the given configuration.
  
  ## Options
  - `:max_size` - Maximum number of entries to cache (default: 10,000)
  - `:ttl` - Time to live for cache entries in milliseconds (default: 5 minutes)
  - `:cleanup_interval` - How often to run cleanup in milliseconds (default: 1 minute)
  - `:enable_stats` - Whether to collect performance statistics (default: true)
  """
  def start_link(opts \\ []) do
    config = Map.merge(@default_config, Map.new(opts))
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Gets a cached hash or computes it if not present.
  
  ## Examples
  
      iex> ExthCrypto.Hash.Cache.get_or_compute("hello", &ExthCrypto.Hash.Keccak.kec/1)
      <<71, 23, 50, 133, 168, 215, 52, 30, 94, 151, 47, 198, 119, 40, 99, 132, ...>>
  """
  def get_or_compute(data, hash_function) do
    key = :erlang.phash2(data)
    
    case lookup(key) do
      {:hit, hash} -> 
        update_stats(:hit)
        hash
      :miss -> 
        hash = hash_function.(data)
        store(key, hash)
        update_stats(:miss)
        hash
    end
  end

  @doc """
  Batch hash operation for multiple data items.
  Returns a list of hashes in the same order as input.
  
  Significantly more efficient than individual hash operations
  for large datasets due to reduced cache lookup overhead.
  """
  def batch_hash(data_list, hash_function) do
    results = Enum.map(data_list, fn data ->
      key = :erlang.phash2(data)
      {key, data}
    end)
    
    # Check cache for all keys first
    {cached, uncached} = Enum.split_with(results, fn {key, _data} ->
      case lookup(key) do
        {:hit, _hash} -> true
        :miss -> false
      end
    end)
    
    # Get cached results
    cached_hashes = Enum.map(cached, fn {key, _data} ->
      {:hit, hash} = lookup(key)
      {key, hash}
    end)
    
    # Compute uncached results
    uncached_hashes = Enum.map(uncached, fn {key, data} ->
      hash = hash_function.(data)
      store(key, hash)
      {key, hash}
    end)
    
    # Combine and return in original order
    all_hashes = Map.new(cached_hashes ++ uncached_hashes)
    
    update_stats(:batch, length(cached_hashes), length(uncached_hashes))
    
    Enum.map(results, fn {key, _data} -> Map.get(all_hashes, key) end)
  end

  @doc """
  Clear all cached entries.
  """
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Get cache statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Update cache configuration at runtime.
  """
  def configure(new_config) do
    GenServer.call(__MODULE__, {:configure, new_config})
  end

  # Private API

  defp lookup(key) do
    case :ets.lookup(:hash_cache, key) do
      [{^key, hash, expiry}] ->
        if System.monotonic_time(:millisecond) < expiry do
          # Update LRU order
          :ets.update_element(:hash_cache_lru, key, {2, System.monotonic_time(:millisecond)})
          {:hit, hash}
        else
          # Expired entry
          :ets.delete(:hash_cache, key)
          :ets.delete(:hash_cache_lru, key)
          :miss
        end
      [] -> 
        :miss
    end
  end

  defp store(key, hash) do
    GenServer.cast(__MODULE__, {:store, key, hash})
  end

  defp update_stats(type, hits \\ 0, misses \\ 0) do
    if Process.whereis(:hash_cache_stats) do
      case type do
        :hit -> :ets.update_counter(:hash_cache_stats, :hits, 1, {:hits, 0})
        :miss -> :ets.update_counter(:hash_cache_stats, :misses, 1, {:misses, 0})
        :batch -> 
          :ets.update_counter(:hash_cache_stats, :hits, hits, {:hits, 0})
          :ets.update_counter(:hash_cache_stats, :misses, misses, {:misses, 0})
      end
    end
  end

  # GenServer Callbacks

  @impl GenServer
  def init(config) do
    # Create main cache table
    :ets.new(:hash_cache, [:named_table, :public, :set, {:read_concurrency, true}])
    
    # Create LRU tracking table
    :ets.new(:hash_cache_lru, [:named_table, :public, :set, {:read_concurrency, true}])
    
    # Create stats table if enabled
    if config.enable_stats do
      :ets.new(:hash_cache_stats, [:named_table, :public, :set, {:read_concurrency, true}])
      :ets.insert(:hash_cache_stats, [hits: 0, misses: 0, evictions: 0])
    end
    
    # Schedule cleanup
    Process.send_after(self(), :cleanup, config.cleanup_interval)
    
    Logger.info("Hash cache initialized: max_size=#{config.max_size}, ttl=#{config.ttl}ms")
    
    {:ok, config}
  end

  @impl GenServer
  def handle_call(:clear, _from, config) do
    :ets.delete_all_objects(:hash_cache)
    :ets.delete_all_objects(:hash_cache_lru)
    
    if config.enable_stats do
      :ets.insert(:hash_cache_stats, [hits: 0, misses: 0, evictions: 0])
    end
    
    {:reply, :ok, config}
  end

  def handle_call(:stats, _from, config) do
    stats = if config.enable_stats do
      case :ets.tab2list(:hash_cache_stats) do
        stats_list -> Map.new(stats_list)
      end
    else
      %{stats_disabled: true}
    end
    
    cache_size = :ets.info(:hash_cache, :size)
    
    complete_stats = Map.merge(stats, %{
      cache_size: cache_size,
      max_size: config.max_size,
      hit_rate: calculate_hit_rate(stats),
      memory_usage: :ets.info(:hash_cache, :memory) * :erlang.system_info(:wordsize)
    })
    
    {:reply, complete_stats, config}
  end

  def handle_call({:configure, new_config}, _from, config) do
    updated_config = Map.merge(config, Map.new(new_config))
    Logger.info("Hash cache reconfigured: #{inspect(updated_config)}")
    {:reply, :ok, updated_config}
  end

  @impl GenServer
  def handle_cast({:store, key, hash}, config) do
    now = System.monotonic_time(:millisecond)
    expiry = now + config.ttl
    
    # Check if we need to evict entries
    current_size = :ets.info(:hash_cache, :size)
    if current_size >= config.max_size do
      evict_lru_entries(config)
    end
    
    # Store the entry
    :ets.insert(:hash_cache, {key, hash, expiry})
    :ets.insert(:hash_cache_lru, {key, now})
    
    {:noreply, config}
  end

  @impl GenServer
  def handle_info(:cleanup, config) do
    cleanup_expired_entries()
    Process.send_after(self(), :cleanup, config.cleanup_interval)
    {:noreply, config}
  end

  # Helper functions

  defp evict_lru_entries(config) do
    # Find LRU entries to evict (evict 10% of max size)
    evict_count = div(config.max_size, 10)
    
    lru_entries = :ets.tab2list(:hash_cache_lru)
    |> Enum.sort_by(fn {_key, timestamp} -> timestamp end)
    |> Enum.take(evict_count)
    
    Enum.each(lru_entries, fn {key, _timestamp} ->
      :ets.delete(:hash_cache, key)
      :ets.delete(:hash_cache_lru, key)
    end)
    
    if config.enable_stats do
      :ets.update_counter(:hash_cache_stats, :evictions, evict_count, {:evictions, 0})
    end
    
    Logger.debug("Evicted #{evict_count} LRU entries from hash cache")
  end

  defp cleanup_expired_entries do
    now = System.monotonic_time(:millisecond)
    
    expired_keys = :ets.select(:hash_cache, [
      {{:"$1", :"$2", :"$3"}, [{:<, :"$3", now}], [:"$1"]}
    ])
    
    Enum.each(expired_keys, fn key ->
      :ets.delete(:hash_cache, key)
      :ets.delete(:hash_cache_lru, key)
    end)
    
    if length(expired_keys) > 0 do
      Logger.debug("Cleaned up #{length(expired_keys)} expired entries from hash cache")
    end
  end

  defp calculate_hit_rate(%{hits: hits, misses: misses}) when hits + misses > 0 do
    Float.round(hits / (hits + misses) * 100, 2)
  end
  defp calculate_hit_rate(_), do: 0.0
end