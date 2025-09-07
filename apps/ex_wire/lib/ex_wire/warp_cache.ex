defmodule WarpCache do
  @moduledoc """
  Cache for warp sync data and state snapshots.

  Provides efficient storage and retrieval of warp sync checkpoints.
  """

  use GenServer
  require Logger

  @table_name :warp_cache
  @max_cache_size 1000

  defstruct [
    :cache_size,
    :eviction_policy
  ]

  # Public API

  @doc """
  Start the warp cache.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a warp checkpoint.
  """
  def put(key, value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  @doc """
  Retrieve a warp checkpoint.
  """
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc """
  Clear all cached data.
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

  # GenServer callbacks

  @impl true
  def init(opts) do
    # Create ETS table for cache
    :ets.new(@table_name, [:set, :named_table, :public, read_concurrency: true])

    state = %__MODULE__{
      cache_size: Keyword.get(opts, :cache_size, @max_cache_size),
      eviction_policy: Keyword.get(opts, :eviction_policy, :lru)
    }

    {:ok, _state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, _state) do
    # Check cache size and evict if necessary
    current_size = :ets.info(@table_name, :size)

    if current_size >= state.cache_size do
      evict_entry(state.eviction_policy)
    end

    # Store with timestamp for LRU
    entry = {key, value, System.system_time(:millisecond)}
    :ets.insert(@table_name, entry)

    {:reply, :ok, state}
  end

  def handle_call({:get, key}, _from, _state) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, _timestamp}] ->
        # Update access time for LRU
        :ets.insert(@table_name, {key, value, System.system_time(:millisecond)})
        {:reply, {:ok, value}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:clear, _from, _state) do
    :ets.delete_all_objects(@table_name)
    Logger.info("Warp cache cleared")
    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, _state) do
    stats = %{
      size: :ets.info(@table_name, :size),
      memory: :ets.info(@table_name, :memory),
      max_size: state.cache_size,
      eviction_policy: state.eviction_policy
    }

    {:reply, stats, state}
  end

  # Private functions

  defp evict_entry(:lru) do
    # Find oldest entry
    case :ets.tab2list(@table_name) do
      [] ->
        :ok

      entries ->
        oldest = Enum.min_by(entries, fn {_key, _value, timestamp} -> timestamp end)
        {key, _, _} = oldest
        :ets.delete(@table_name, key)
        Logger.debug("Evicted cache entry: #{inspect(key)}")
    end
  end

  defp evict_entry(:fifo) do
    # Simple FIFO: remove first entry
    case :ets.first(@table_name) do
      :"$end_of_table" ->
        :ok

      key ->
        :ets.delete(@table_name, key)
        Logger.debug("Evicted cache entry: #{inspect(key)}")
    end
  end
end
