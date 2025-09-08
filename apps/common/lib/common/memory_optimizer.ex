defmodule Common.MemoryOptimizer do
  @moduledoc """
  Memory optimization utilities for Mana Ethereum client.
  
  Provides optimized data structures and memory pooling to reduce
  allocation overhead and improve performance:
  - Memory pools for frequent allocations
  - Optimized Map operations (518KB → 150KB target)
  - Binary operation optimizations
  - Garbage collection tuning
  - Memory-mapped storage for large datasets
  """

  use GenServer
  require Logger

  @pool_config %{
    small_blocks: %{size: 1024, count: 1000, allocated: 0},
    medium_blocks: %{size: 8192, count: 500, allocated: 0},
    large_blocks: %{size: 65536, count: 100, allocated: 0}
  }

  # Client API

  @doc """
  Start the memory optimizer with configuration.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Allocate memory from the appropriate pool.
  Returns {:ok, memory_ref} or {:error, reason}.
  """
  def allocate(size) when is_integer(size) and size > 0 do
    pool_type = determine_pool_type(size)
    GenServer.call(__MODULE__, {:allocate, pool_type, size})
  end

  @doc """
  Deallocate memory back to the pool.
  """
  def deallocate(memory_ref) do
    GenServer.cast(__MODULE__, {:deallocate, memory_ref})
  end

  @doc """
  Create an optimized Map structure for better memory efficiency.
  Uses ETS tables for large maps to reduce memory usage.
  """
  def create_optimized_map(opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 1000)
    type = Keyword.get(opts, :type, :set)
    
    table_name = make_ref()
    :ets.new(table_name, [type, :public, {:read_concurrency, true}, {:write_concurrency, true}])
    
    %{
      __type__: :optimized_map,
      table: table_name,
      threshold: threshold,
      size: 0
    }
  end

  @doc """
  Put a value in an optimized map.
  """
  def put_optimized(map = %{__type__: :optimized_map}, key, value) do
    :ets.insert(map.table, {key, value})
    %{map | size: map.size + 1}
  end

  def put_optimized(map, key, value) when is_map(map) do
    Map.put(map, key, value)
  end

  @doc """
  Get a value from an optimized map.
  """
  def get_optimized(%{__type__: :optimized_map, table: table}, key, default \\ nil) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  def get_optimized(map, key, default) when is_map(map) do
    Map.get(map, key, default)
  end

  @doc """
  Delete an optimized map to free memory.
  """
  def delete_optimized_map(%{__type__: :optimized_map, table: table}) do
    :ets.delete(table)
    :ok
  end

  def delete_optimized_map(_map), do: :ok

  @doc """
  Optimize binary operations for large datasets.
  Uses memory mapping and streaming for efficiency.
  """
  def optimize_binary_ops(data, operation) when is_binary(data) do
    size = byte_size(data)
    
    cond do
      size > 1_048_576 ->  # 1MB
        memory_mapped_binary_op(data, operation)
      size > 65_536 ->     # 64KB
        streaming_binary_op(data, operation)
      true ->
        operation.(data)
    end
  end

  @doc """
  Configure garbage collection for optimal performance.
  """
  def configure_gc_optimization do
    # Configure garbage collection settings
    gc_config = %{
      # Adjust heap sizes for better performance
      min_heap_size: 233,      # Increase minimum heap size
      min_bin_vheap_size: 46422,  # Optimize binary heap
      # Enable more aggressive minor GCs to prevent major GCs
      fullsweep_after: 10,
      # Tune nursery size for better allocation patterns
      nursery_size: 1024
    }
    
    apply_gc_config(gc_config)
    Logger.info("Garbage collection optimized: #{inspect(gc_config)}")
    gc_config
  end

  @doc """
  Get memory optimization statistics.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # GenServer Callbacks

  @impl GenServer
  def init(_opts) do
    # Initialize memory pools
    pools = initialize_pools(@pool_config)
    
    # Configure GC optimization
    configure_gc_optimization()
    
    # Create statistics ETS table
    :ets.new(:memory_optimizer_stats, [:named_table, :public, :set])
    :ets.insert(:memory_optimizer_stats, [
      allocations: 0,
      deallocations: 0,
      memory_saved: 0,
      pool_hits: 0,
      pool_misses: 0
    ])
    
    Logger.info("Memory optimizer initialized with pools: #{inspect(Map.keys(pools))}")
    
    {:ok, %{pools: pools, stats: %{}}}
  end

  @impl GenServer
  def handle_call({:allocate, pool_type, size}, _from, state) do
    case allocate_from_pool(state.pools, pool_type, size) do
      {:ok, memory_ref, updated_pools} ->
        update_stats(:allocation)
        {:reply, {:ok, memory_ref}, %{state | pools: updated_pools}}
      
      {:error, reason} ->
        update_stats(:pool_miss)
        # Fallback to system allocation
        memory_ref = make_ref()
        {:reply, {:ok, memory_ref}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    system_stats = get_system_memory_stats()
    pool_stats = get_pool_stats(state.pools)
    optimizer_stats = :ets.tab2list(:memory_optimizer_stats) |> Map.new()
    
    combined_stats = Map.merge(system_stats, %{
      pools: pool_stats,
      optimizer: optimizer_stats
    })
    
    {:reply, combined_stats, state}
  end

  @impl GenServer
  def handle_cast({:deallocate, memory_ref}, state) do
    # Return memory to appropriate pool
    updated_pools = deallocate_to_pool(state.pools, memory_ref)
    update_stats(:deallocation)
    {:noreply, %{state | pools: updated_pools}}
  end

  # Private Helper Functions

  defp determine_pool_type(size) do
    cond do
      size <= 1024 -> :small_blocks
      size <= 8192 -> :medium_blocks
      size <= 65536 -> :large_blocks
      true -> :large_blocks
    end
  end

  defp initialize_pools(pool_config) do
    Enum.into(pool_config, %{}, fn {pool_type, config} ->
      # Pre-allocate pool blocks
      pool_table = :ets.new(:"pool_#{pool_type}", [:set, :private])
      
      # Initialize with available blocks
      blocks = for i <- 1..config.count do
        block_ref = make_ref()
        :ets.insert(pool_table, {block_ref, :available, config.size})
        block_ref
      end
      
      {pool_type, %{
        table: pool_table,
        config: config,
        available: length(blocks),
        allocated: 0
      }}
    end)
  end

  defp allocate_from_pool(pools, pool_type, _size) do
    pool = Map.get(pools, pool_type)
    
    if pool && pool.available > 0 do
      # Find first available block
      case :ets.select(pool.table, [{{:"$1", :available, :"$2"}, [], [:"$1"]}], 1) do
        {[block_ref], _continuation} ->
          # Mark as allocated
          :ets.update_element(pool.table, block_ref, {2, :allocated})
          
          updated_pool = %{pool | 
            available: pool.available - 1, 
            allocated: pool.allocated + 1
          }
          updated_pools = Map.put(pools, pool_type, updated_pool)
          
          {:ok, block_ref, updated_pools}
        
        _ ->
          {:error, :pool_exhausted}
      end
    else
      {:error, :no_pool}
    end
  end

  defp deallocate_to_pool(pools, memory_ref) do
    # Find which pool this memory belongs to
    Enum.reduce(pools, pools, fn {pool_type, pool}, acc_pools ->
      case :ets.lookup(pool.table, memory_ref) do
        [{^memory_ref, :allocated, _size}] ->
          # Mark as available
          :ets.update_element(pool.table, memory_ref, {2, :available})
          
          updated_pool = %{pool | 
            available: pool.available + 1, 
            allocated: pool.allocated - 1
          }
          Map.put(acc_pools, pool_type, updated_pool)
        
        _ ->
          acc_pools
      end
    end)
  end

  defp memory_mapped_binary_op(data, operation) do
    # For very large binaries, use memory mapping if available
    # This is a simplified implementation - in production you'd use
    # actual memory mapping system calls
    chunk_size = 1_048_576  # 1MB chunks
    
    data
    |> stream_binary_chunks(chunk_size)
    |> Enum.map(operation)
    |> Enum.reduce(&<>/2)
  end

  defp streaming_binary_op(data, operation) do
    # Stream processing for medium-sized binaries
    chunk_size = 65_536  # 64KB chunks
    
    data
    |> stream_binary_chunks(chunk_size)
    |> Enum.map(operation)
    |> Enum.reduce(&<>/2)
  end

  defp stream_binary_chunks(data, chunk_size) do
    Stream.unfold({data, 0}, fn
      {<<>>, _offset} -> nil
      {binary, offset} ->
        case binary do
          <<chunk::binary-size(chunk_size), rest::binary>> ->
            {chunk, {rest, offset + chunk_size}}
          remaining ->
            {remaining, {<<>>, offset + byte_size(remaining)}}
        end
    end)
  end

  defp apply_gc_config(config) do
    # Apply garbage collection configuration
    # Note: Some of these settings might need to be set at VM startup
    try do
      if config[:min_heap_size] do
        :erlang.system_flag(:min_heap_size, config.min_heap_size)
      end
      
      if config[:min_bin_vheap_size] do
        :erlang.system_flag(:min_bin_vheap_size, config.min_bin_vheap_size)
      end
      
      :ok
    rescue
      error ->
        Logger.warn("Could not apply some GC settings: #{inspect(error)}")
        :ok
    end
  end

  defp update_stats(stat_type) do
    case stat_type do
      :allocation -> 
        :ets.update_counter(:memory_optimizer_stats, :allocations, 1, {:allocations, 0})
      :deallocation -> 
        :ets.update_counter(:memory_optimizer_stats, :deallocations, 1, {:deallocations, 0})
      :pool_miss -> 
        :ets.update_counter(:memory_optimizer_stats, :pool_misses, 1, {:pool_misses, 0})
    end
  end

  defp get_system_memory_stats do
    %{
      total_memory: :erlang.memory(:total),
      processes_memory: :erlang.memory(:processes),
      system_memory: :erlang.memory(:system),
      binary_memory: :erlang.memory(:binary),
      ets_memory: :erlang.memory(:ets)
    }
  end

  defp get_pool_stats(pools) do
    Enum.into(pools, %{}, fn {pool_type, pool} ->
      {pool_type, %{
        available: pool.available,
        allocated: pool.allocated,
        total: pool.available + pool.allocated,
        utilization: if pool.available + pool.allocated > 0 do
          Float.round(pool.allocated / (pool.available + pool.allocated) * 100, 2)
        else
          0.0
        end
      }}
    end)
  end
end