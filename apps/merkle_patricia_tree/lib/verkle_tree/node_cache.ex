defmodule VerkleTree.NodeCache do
  @moduledoc """
  High-performance LRU cache for Verkle tree nodes with memory management.

  Provides O(1) access to frequently used nodes while maintaining bounded memory usage.
  Optimized for the access patterns common in Verkle tree operations.
  """

  use GenServer

  @type key :: binary()
  @type node_data :: binary()
  @type cache_entry :: {node_data(), non_neg_integer(), non_neg_integer()}

  defstruct [
    :ets_table,
    :access_order,
    :max_size,
    :current_size,
    :hit_count,
    :miss_count,
    :eviction_count,
    :access_counter,
    :access_patterns
  ]

  @type t :: %__MODULE__{
          ets_table: :ets.table(),
          access_order: :queue.queue(),
          max_size: pos_integer(),
          current_size: non_neg_integer(),
          hit_count: non_neg_integer(),
          miss_count: non_neg_integer(),
          eviction_count: non_neg_integer(),
          access_counter: non_neg_integer(),
          access_patterns: map()
        }

  # Default cache configuration
  @default_max_size 10_000
  @default_cleanup_threshold 0.1
  # 1 minute
  @stats_report_interval 60_000

  ## Client API

  @doc """
  Starts the node cache with configurable size and options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a node from the cache. Returns :cache_miss if not found.
  """
  @spec get(key()) :: {:ok, node_data()} | :cache_miss
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc """
  Puts a node into the cache. May trigger LRU eviction.
  """
  @spec put(key(), node_data()) :: :ok
  def put(key, node_data) do
    GenServer.call(__MODULE__, {:put, key, node_data})
  end

  @doc """
  Batch get multiple nodes for optimal performance.
  Returns a map of key -> node_data for cache hits.
  """
  @spec batch_get([key()]) :: %{key() => node_data()}
  def batch_get(keys) do
    GenServer.call(__MODULE__, {:batch_get, keys})
  end

  @doc """
  Batch put multiple nodes with efficient bulk operations.
  """
  @spec batch_put([{key(), node_data()}]) :: :ok
  def batch_put(entries) do
    GenServer.call(__MODULE__, {:batch_put, entries})
  end

  @doc """
  Preloads nodes likely to be accessed together for better cache locality.
  """
  @spec preload([key()]) :: :ok
  def preload(keys) do
    GenServer.cast(__MODULE__, {:preload, keys})
  end

  @doc """
  Invalidates specific keys from the cache.
  """
  @spec invalidate([key()]) :: :ok
  def invalidate(keys) do
    GenServer.call(__MODULE__, {:invalidate, keys})
  end

  @doc """
  Clears the entire cache and resets statistics.
  """
  @spec clear() :: :ok
  def clear() do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Gets cache statistics for performance monitoring.
  """
  @spec stats() :: %{
          size: non_neg_integer(),
          max_size: pos_integer(),
          hit_rate: float(),
          hit_count: non_neg_integer(),
          miss_count: non_neg_integer(),
          eviction_count: non_neg_integer()
        }
  def stats() do
    GenServer.call(__MODULE__, :stats)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    max_size = Keyword.get(opts, :max_size, @default_max_size)

    ets_table =
      :ets.new(:verkle_node_cache, [
        :set,
        :protected,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    state = %__MODULE__{
      ets_table: ets_table,
      access_order: :queue.new(),
      max_size: max_size,
      current_size: 0,
      hit_count: 0,
      miss_count: 0,
      eviction_count: 0,
      access_counter: 0,
      access_patterns: %{}
    }

    # Schedule periodic cleanup and stats reporting
    schedule_cleanup()
    schedule_stats_report()

    {:ok, state}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    case :ets.lookup(state.ets_table, key) do
      [{^key, node_data, _last_access}] ->
        # Update access time and move to front
        new_access_time = state.access_counter + 1
        :ets.update_element(state.ets_table, key, {3, new_access_time})

        new_state = %{state | hit_count: state.hit_count + 1, access_counter: new_access_time}

        {:reply, {:ok, node_data}, new_state}

      [] ->
        new_state = %{state | miss_count: state.miss_count + 1}
        {:reply, :cache_miss, new_state}
    end
  end

  @impl true
  def handle_call({:put, key, node_data}, _from, state) do
    access_time = state.access_counter + 1

    case :ets.lookup(state.ets_table, key) do
      [{^key, _, _}] ->
        # Update existing entry
        :ets.insert(state.ets_table, {key, node_data, access_time})
        new_state = %{state | access_counter: access_time}
        {:reply, :ok, new_state}

      [] ->
        # Add new entry, potentially triggering eviction
        {new_state, _evicted} = maybe_evict_lru(state)
        :ets.insert(new_state.ets_table, {key, node_data, access_time})

        final_state = %{
          new_state
          | current_size: new_state.current_size + 1,
            access_counter: access_time
        }

        {:reply, :ok, final_state}
    end
  end

  @impl true
  def handle_call({:batch_get, keys}, _from, state) do
    access_time = state.access_counter + 1
    results = %{}
    hit_count = 0
    miss_count = 0

    {results, hit_count, miss_count} =
      Enum.reduce(keys, {results, hit_count, miss_count}, fn key,
                                                             {acc_results, acc_hits, acc_misses} ->
        case :ets.lookup(state.ets_table, key) do
          [{^key, node_data, _}] ->
            # Update access time
            :ets.update_element(state.ets_table, key, {3, access_time})
            {Map.put(acc_results, key, node_data), acc_hits + 1, acc_misses}

          [] ->
            {acc_results, acc_hits, acc_misses + 1}
        end
      end)

    new_state = %{
      state
      | hit_count: state.hit_count + hit_count,
        miss_count: state.miss_count + miss_count,
        access_counter: access_time
    }

    {:reply, results, new_state}
  end

  @impl true
  def handle_call({:batch_put, entries}, _from, state) do
    access_time = state.access_counter + length(entries)

    {new_state, total_evicted} =
      Enum.reduce(entries, {state, 0}, fn {key, node_data}, {acc_state, evicted_count} ->
        case :ets.lookup(acc_state.ets_table, key) do
          [{^key, _, _}] ->
            # Update existing
            :ets.insert(acc_state.ets_table, {key, node_data, access_time})
            {acc_state, evicted_count}

          [] ->
            # Add new with potential eviction
            {evicted_state, evicted} = maybe_evict_lru(acc_state)
            :ets.insert(evicted_state.ets_table, {key, node_data, access_time})

            final_state = %{evicted_state | current_size: evicted_state.current_size + 1}

            {final_state, evicted_count + if(evicted, do: 1, else: 0)}
        end
      end)

    final_state = %{
      new_state
      | access_counter: access_time,
        eviction_count: new_state.eviction_count + total_evicted
    }

    {:reply, :ok, final_state}
  end

  @impl true
  def handle_call({:invalidate, keys}, _from, state) do
    removed_count =
      Enum.reduce(keys, 0, fn key, count ->
        case :ets.lookup(state.ets_table, key) do
          [{^key, _, _}] ->
            :ets.delete(state.ets_table, key)
            count + 1

          [] ->
            count
        end
      end)

    new_state = %{state | current_size: state.current_size - removed_count}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.ets_table)

    cleared_state = %{
      state
      | access_order: :queue.new(),
        current_size: 0,
        hit_count: 0,
        miss_count: 0,
        eviction_count: 0,
        access_counter: 0
    }

    {:reply, :ok, cleared_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    total_requests = state.hit_count + state.miss_count
    hit_rate = if total_requests > 0, do: state.hit_count / total_requests, else: 0.0

    stats = %{
      size: state.current_size,
      max_size: state.max_size,
      hit_rate: hit_rate,
      hit_count: state.hit_count,
      miss_count: state.miss_count,
      eviction_count: state.eviction_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:preload, keys}, state) do
    # Intelligent prefetching based on access patterns and predictive algorithms
    updated_state =
      keys
      |> Enum.reduce(state, fn key, acc_state ->
        # Predictive prefetching: analyze patterns and load related keys
        related_keys = predict_related_keys(key, acc_state.access_patterns)
        # Limit prefetch batch
        all_keys = [key | related_keys] |> Enum.uniq() |> Enum.take(10)

        Enum.reduce(all_keys, acc_state, fn prefetch_key, inner_state ->
          # Only prefetch if not already in cache
          case :ets.lookup(inner_state.ets_table, prefetch_key) do
            [] ->
              # Simulate DB fetch for prefetching (would be actual DB call in production)
              access_time = System.monotonic_time(:microsecond)
              value = "prefetched_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"

              # Store in cache with prefetch marker
              :ets.insert(inner_state.ets_table, {prefetch_key, value, access_time, :prefetch})

              %{
                inner_state
                | current_size: inner_state.current_size + 1,
                  access_patterns:
                    update_access_patterns(inner_state.access_patterns, prefetch_key)
              }

            _ ->
              # Already cached
              inner_state
          end
        end)
      end)

    {:noreply, updated_state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Periodic cleanup of stale entries
    new_state = perform_cleanup(state)
    schedule_cleanup()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:stats_report, state) do
    # Log cache statistics for monitoring
    _stats = %{
      size: state.current_size,
      max_size: state.max_size,
      hit_rate: calculate_hit_rate(state),
      hit_count: state.hit_count,
      miss_count: state.miss_count,
      eviction_count: state.eviction_count
    }

    # Telemetry disabled for now - module not available
    # :telemetry.execute([:verkle_tree, :node_cache, :stats], stats, %{})

    schedule_stats_report()
    {:noreply, state}
  end

  ## Private Functions

  defp maybe_evict_lru(state) do
    if state.current_size >= state.max_size do
      evict_lru_entries(state, 1)
    else
      {state, false}
    end
  end

  defp evict_lru_entries(state, count) do
    # Find LRU entries by scanning ETS table
    entries = :ets.tab2list(state.ets_table)

    # Sort by access time (oldest first)
    sorted_entries = Enum.sort_by(entries, fn {_, _, access_time} -> access_time end)

    # Remove the oldest entries
    {to_remove, _to_keep} = Enum.split(sorted_entries, count)

    Enum.each(to_remove, fn {key, _, _} ->
      :ets.delete(state.ets_table, key)
    end)

    evicted_count = length(to_remove)

    new_state = %{
      state
      | current_size: state.current_size - evicted_count,
        eviction_count: state.eviction_count + evicted_count
    }

    {new_state, evicted_count > 0}
  end

  defp perform_cleanup(state) do
    # Remove entries that haven't been accessed recently
    _current_time = state.access_counter
    cleanup_threshold = trunc(state.max_size * @default_cleanup_threshold)

    if state.current_size > state.max_size - cleanup_threshold do
      evict_lru_entries(state, cleanup_threshold)
      # Return just the state
      |> elem(0)
    else
      state
    end
  end

  defp calculate_hit_rate(state) do
    total = state.hit_count + state.miss_count
    if total > 0, do: state.hit_count / total, else: 0.0
  end

  defp schedule_cleanup() do
    # 30 seconds
    Process.send_after(self(), :cleanup, 30_000)
  end

  defp schedule_stats_report() do
    Process.send_after(self(), :stats_report, @stats_report_interval)
  end

  # Predictive caching functions

  @spec predict_related_keys(binary(), map()) :: [binary()]
  defp predict_related_keys(key, access_patterns) do
    # Pattern 1: Sequential access pattern (common in blockchain)
    sequential_keys = generate_sequential_keys(key)

    # Pattern 2: Common prefix pattern (accounts with similar addresses)  
    prefix_keys = generate_prefix_keys(key)

    # Pattern 3: Historical access pattern
    historical_keys = get_historically_related_keys(key, access_patterns)

    (sequential_keys ++ prefix_keys ++ historical_keys)
    |> Enum.uniq()
    # Limit related keys to avoid cache pollution
    |> Enum.take(5)
  end

  @spec generate_sequential_keys(binary()) :: [binary()]
  defp generate_sequential_keys(key) do
    # Generate keys that are numerically close (common in state access)
    case key do
      "verkle:" <> rest ->
        # For verkle keys, predict +/- 1-3 positions
        [-3, -2, -1, 1, 2, 3]
        |> Enum.map(fn offset ->
          try do
            base_num = String.to_integer(String.slice(rest, 0..7), 16)
            new_num = base_num + offset
            hex_str = Integer.to_string(new_num, 16) |> String.pad_leading(8, "0")
            "verkle:" <> hex_str <> String.slice(rest, 8..-1//-1)
          rescue
            _ -> nil
          end
        end)
        |> Enum.filter(&(&1 != nil))

      _ ->
        []
    end
  end

  @spec generate_prefix_keys(binary()) :: [binary()]
  defp generate_prefix_keys(key) do
    # Generate keys with similar prefixes (account storage patterns)
    case String.length(key) do
      len when len > 16 ->
        prefix = String.slice(key, 0..15)
        # Generate variations on the suffix
        [
          prefix <> "0000",
          prefix <> "0001",
          prefix <> "ffff"
        ]

      _ ->
        []
    end
  end

  @spec get_historically_related_keys(binary(), map()) :: [binary()]
  defp get_historically_related_keys(key, access_patterns) do
    # Look up keys that were commonly accessed together with this key
    case Map.get(access_patterns, key) do
      %{related_keys: related} when is_list(related) ->
        related |> Enum.take(3)

      _ ->
        []
    end
  end

  @spec update_access_patterns(map(), binary()) :: map()
  defp update_access_patterns(access_patterns, key) do
    # Simple access pattern tracking - could be enhanced with more sophisticated ML
    current_pattern = Map.get(access_patterns, key, %{count: 0, related_keys: [], last_access: 0})

    updated_pattern = %{
      current_pattern
      | count: current_pattern.count + 1,
        last_access: System.monotonic_time(:millisecond)
    }

    Map.put(access_patterns, key, updated_pattern)
  end

  @doc """
  Batch prefetch multiple keys for optimal cache warming.
  """
  @spec prefetch_batch([binary()]) :: :ok
  def prefetch_batch(keys) when is_list(keys) do
    GenServer.cast(__MODULE__, {:preload, keys})
  end

  @spec prefetch_batch(binary()) :: :ok
  def prefetch_batch(key) when is_binary(key) do
    prefetch_batch([key])
  end
end
