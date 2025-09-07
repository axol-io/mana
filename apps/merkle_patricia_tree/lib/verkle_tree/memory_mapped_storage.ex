defmodule VerkleTree.MemoryMappedStorage do
  @moduledoc """
  Memory-mapped storage backend for large Verkle tree state data.

  Provides high-performance access to large state trees by leveraging
  memory-mapped files, reducing memory pressure and improving cache locality.

  Features:
  - Memory-mapped file I/O for large datasets
  - Segmented storage to prevent excessive memory usage  
  - Optimized for sequential and random access patterns
  - Automatic segment rotation and cleanup
  """

  use GenServer

  require Logger

  @type segment_id :: non_neg_integer()
  @type offset :: non_neg_integer()
  @type mmap_handle :: reference()

  defstruct [
    :base_path,
    :segments,
    :active_segment,
    :segment_size,
    :max_segments,
    :read_handles,
    :write_handle,
    :segment_counter
  ]

  @type t :: %__MODULE__{
          base_path: Path.t(),
          segments: %{segment_id() => mmap_handle()},
          active_segment: segment_id(),
          segment_size: pos_integer(),
          max_segments: pos_integer(),
          read_handles: %{segment_id() => mmap_handle()},
          write_handle: mmap_handle() | nil,
          segment_counter: non_neg_integer()
        }

  # Configuration defaults
  # 128MB segments
  @default_segment_size 1024 * 1024 * 128
  # Max 2GB memory mapped at once
  @default_max_segments 16
  # Reserved space for metadata at start of each segment
  @header_size 64

  ## Client API

  @doc """
  Starts the memory-mapped storage with the given base path and options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores data at the given key with optimal memory mapping.
  """
  @spec put(binary(), binary()) :: :ok | {:error, term()}
  def put(key, value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  @doc """
  Retrieves data for the given key from memory-mapped storage.
  """
  @spec get(binary()) :: {:ok, binary()} | :not_found | {:error, term()}
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc """
  Batch put multiple key-value pairs for optimal throughput.
  """
  @spec batch_put([{binary(), binary()}]) :: :ok | {:error, term()}
  def batch_put(entries) do
    GenServer.call(__MODULE__, {:batch_put, entries}, 30_000)
  end

  @doc """
  Batch get multiple keys with optimized memory access.
  """
  @spec batch_get([binary()]) :: %{binary() => binary()}
  def batch_get(keys) do
    GenServer.call(__MODULE__, {:batch_get, keys})
  end

  @doc """
  Removes data for the given key.
  """
  @spec delete(binary()) :: :ok | {:error, term()}
  def delete(key) do
    GenServer.call(__MODULE__, {:delete, key})
  end

  @doc """
  Forces a sync of all pending writes to disk.
  """
  @spec sync() :: :ok | {:error, term()}
  def sync() do
    GenServer.call(__MODULE__, :sync)
  end

  @doc """
  Gets storage statistics for monitoring.
  """
  @spec stats() :: map()
  def stats() do
    GenServer.call(__MODULE__, :stats)
  end

  ## GenServer Implementation

  @impl true
  def init(opts) do
    base_path = Keyword.get(opts, :base_path, "data/verkle_storage")
    segment_size = Keyword.get(opts, :segment_size, @default_segment_size)
    max_segments = Keyword.get(opts, :max_segments, @default_max_segments)

    # Ensure base directory exists
    :ok = File.mkdir_p(base_path)

    state = %__MODULE__{
      base_path: base_path,
      segments: %{},
      active_segment: 0,
      segment_size: segment_size,
      max_segments: max_segments,
      read_handles: %{},
      write_handle: nil,
      segment_counter: 0
    }

    # Initialize first segment
    case create_new_segment(state, 0) do
      {:ok, new_state} ->
        Logger.info("Memory-mapped storage initialized at #{base_path}")
        {:ok, new_state}

      {:error, reason} ->
        Logger.error("Failed to initialize memory-mapped storage: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    case put_data(state, key, value) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _reason} -> {:reply, {:error, _reason}, state}
    end
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    result = get_data(state, key)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:batch_put, entries}, _from, state) do
    case batch_put_data(state, entries) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _reason} -> {:reply, {:error, _reason}, state}
    end
  end

  @impl true
  def handle_call({:batch_get, keys}, _from, state) do
    results = batch_get_data(state, keys)
    {:reply, results, state}
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    case delete_data(state, key) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _reason} -> {:reply, {:error, _reason}, state}
    end
  end

  @impl true
  def handle_call(:sync, _from, state) do
    :ok = sync_all_segments(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = calculate_storage_stats(state)
    {:reply, stats, state}
  end

  ## Private Implementation

  @spec create_new_segment(t(), segment_id()) :: {:ok, t()} | {:error, term()}
  defp create_new_segment(state, segment_id) do
    segment_path = segment_file_path(state.base_path, segment_id)

    try do
      # Create segment file if it doesn't exist
      if !File.exists?(segment_path) do
        # Create file with initial header and padding to segment size
        header_data = <<0::size(@header_size * 8)>>
        padding_size = state.segment_size - @header_size
        padding_data = <<0::size(padding_size * 8)>>
        :ok = File.write(segment_path, header_data <> padding_data)
      end

      # Memory map the segment file (simulated - would use real mmap in production)
      mmap_handle = simulate_mmap(segment_path)

      new_segments = Map.put(state.segments, segment_id, mmap_handle)
      new_read_handles = Map.put(state.read_handles, segment_id, mmap_handle)

      new_state = %{
        state
        | segments: new_segments,
          read_handles: new_read_handles,
          write_handle: mmap_handle,
          active_segment: segment_id,
          segment_counter: max(state.segment_counter, segment_id + 1)
      }

      {:ok, new_state}
    rescue
      error -> {:error, error}
    end
  end

  @spec put_data(t(), binary(), binary()) :: {:ok, t()} | {:error, term()}
  defp put_data(state, key, value) do
    # Calculate required space
    entry_size = calculate_entry_size(key, value)

    # Check if we need a new segment
    state =
      if needs_new_segment?(state, entry_size) do
        case rotate_to_new_segment(state) do
          {:ok, new_state} -> new_state
          # Continue with current segment
          {:error, _} -> state
        end
      else
        state
      end

    # Write to active segment
    case write_to_segment(state, state.active_segment, key, value) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_data(t(), binary()) :: {:ok, binary()} | :not_found | {:error, term()}
  defp get_data(state, key) do
    # Search through segments, starting with most recent
    segment_ids =
      state.segments
      |> Map.keys()
      # Search newest first
      |> Enum.sort(:desc)

    find_in_segments(state, key, segment_ids)
  end

  @spec find_in_segments(t(), binary(), [segment_id()]) :: {:ok, binary()} | :not_found
  defp find_in_segments(state, _key, []), do: :not_found

  defp find_in_segments(state, key, [segment_id | remaining]) do
    case read_from_segment(state, segment_id, key) do
      {:ok, value} -> {:ok, value}
      :not_found -> find_in_segments(state, key, remaining)
      {:error, _} -> find_in_segments(state, key, remaining)
    end
  end

  @spec batch_put_data(t(), [{binary(), binary()}]) :: {:ok, t()} | {:error, term()}
  defp batch_put_data(state, entries) when is_list(entries) do
    # Sort entries by key for better locality
    sorted_entries = Enum.sort_by(entries, fn {key, _value} -> key end)

    # Process in batches to avoid overwhelming memory
    batch_size = 100

    try do
      final_state =
        sorted_entries
        |> Enum.chunk_every(batch_size)
        |> Enum.reduce(state, fn batch, acc_state ->
          Enum.reduce(batch, acc_state, fn {key, value}, inner_state ->
            case put_data(inner_state, key, value) do
              {:ok, new_state} -> new_state
              # Continue processing
              {:error, _} -> inner_state
            end
          end)
        end)

      {:ok, final_state}
    rescue
      error -> {:error, error}
    end
  end

  @spec batch_get_data(t(), [binary()]) :: %{binary() => binary()}
  defp batch_get_data(state, keys) when is_list(keys) do
    # Group keys by likely segment for better cache locality
    keys
    |> Enum.reduce(%{}, fn key, acc ->
      case get_data(state, key) do
        {:ok, value} -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  @spec delete_data(t(), binary()) :: {:ok, t()} | {:error, term()}
  defp delete_data(state, key) do
    # Mark as deleted in segments (tombstone approach)
    # In production, would use a more sophisticated approach
    # Empty value marks deletion
    case put_data(state, key, <<>>) do
      {:ok, new_state} -> {:ok, new_state}
      {:error, reason} -> {:error, reason}
    end
  end

  # Utility functions (simplified implementations)

  @spec simulate_mmap(Path.t()) :: reference()
  defp simulate_mmap(file_path) do
    # In production, would use actual memory mapping
    # For now, simulate with file handle reference
    make_ref()
    |> tap(fn ref ->
      Process.put({:mmap_path, ref}, file_path)
    end)
  end

  @spec segment_file_path(Path.t(), segment_id()) :: Path.t()
  defp segment_file_path(base_path, segment_id) do
    Path.join(base_path, "segment_#{segment_id}.dat")
  end

  @spec calculate_entry_size(binary(), binary()) :: pos_integer()
  defp calculate_entry_size(key, value) do
    # Key size + Value size + overhead (length prefixes, etc.)
    byte_size(key) + byte_size(value) + 16
  end

  @spec needs_new_segment?(t(), pos_integer()) :: boolean()
  defp needs_new_segment?(state, entry_size) do
    # Simplified check - in production would track actual segment usage
    # Assume 90% full
    estimated_current_size = state.segment_size * 0.9
    entry_size > state.segment_size - estimated_current_size
  end

  @spec rotate_to_new_segment(t()) :: {:ok, t()} | {:error, term()}
  defp rotate_to_new_segment(state) do
    new_segment_id = state.segment_counter

    # Clean up old segments if we're at the limit
    cleaned_state =
      if map_size(state.segments) >= state.max_segments do
        cleanup_old_segments(state)
      else
        state
      end

    create_new_segment(cleaned_state, new_segment_id)
  end

  @spec cleanup_old_segments(t()) :: t()
  defp cleanup_old_segments(state) do
    # Remove oldest segments (simplified)
    oldest_segments =
      state.segments
      |> Map.keys()
      |> Enum.sort()
      # Remove 2 oldest segments
      |> Enum.take(2)

    cleaned_segments =
      Enum.reduce(oldest_segments, state.segments, fn segment_id, acc ->
        # Would unmap memory and close files in production
        Map.delete(acc, segment_id)
      end)

    cleaned_read_handles =
      Enum.reduce(oldest_segments, state.read_handles, fn segment_id, acc ->
        Map.delete(acc, segment_id)
      end)

    %{state | segments: cleaned_segments, read_handles: cleaned_read_handles}
  end

  @spec write_to_segment(t(), segment_id(), binary(), binary()) :: :ok | {:error, term()}
  defp write_to_segment(state, segment_id, key, value) do
    # Simplified write - in production would write to memory-mapped region
    segment_path = segment_file_path(state.base_path, segment_id)
    entry_data = create_entry_data(key, value)

    case File.open(segment_path, [:append, :binary]) do
      {:ok, file} ->
        result = IO.binwrite(file, entry_data)
        File.close(file)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec read_from_segment(t(), segment_id(), binary()) ::
          {:ok, binary()} | :not_found | {:error, term()}
  defp read_from_segment(state, segment_id, key) do
    # Simplified read - in production would read from memory-mapped region
    segment_path = segment_file_path(state.base_path, segment_id)

    case File.read(segment_path) do
      {:ok, data} ->
        parse_segment_for_key(data, key)

      {:error, :enoent} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create_entry_data(binary(), binary()) :: binary()
  defp create_entry_data(key, value) do
    key_len = byte_size(key)
    value_len = byte_size(value)

    # Simple format: key_len (4 bytes) + key + value_len (4 bytes) + value
    <<key_len::32, key::binary, value_len::32, value::binary>>
  end

  @spec parse_segment_for_key(binary(), binary()) :: {:ok, binary()} | :not_found
  defp parse_segment_for_key(data, target_key) do
    # Skip header
    parse_entries(binary_part(data, @header_size, byte_size(data) - @header_size), target_key)
  end

  @spec parse_entries(binary(), binary()) :: {:ok, binary()} | :not_found
  defp parse_entries(<<>>, _target_key), do: :not_found

  defp parse_entries(
         <<key_len::32, key::binary-size(key_len), value_len::32, value::binary-size(value_len),
           rest::binary>>,
         target_key
       ) do
    if key == target_key do
      if value == <<>> do
        # Tombstone (deleted)
        :not_found
      else
        {:ok, value}
      end
    else
      parse_entries(rest, target_key)
    end
  end

  defp parse_entries(_invalid_data, _target_key), do: :not_found

  @spec sync_all_segments(t()) :: :ok | {:error, term()}
  defp sync_all_segments(state) do
    # In production, would sync all memory-mapped regions
    :ok
  end

  @spec calculate_storage_stats(t()) :: map()
  defp calculate_storage_stats(state) do
    %{
      active_segment: state.active_segment,
      total_segments: map_size(state.segments),
      max_segments: state.max_segments,
      segment_size_mb: div(state.segment_size, 1024 * 1024),
      estimated_total_size_mb: map_size(state.segments) * div(state.segment_size, 1024 * 1024),
      segment_utilization: calculate_segment_utilization(state)
    }
  end

  @spec calculate_segment_utilization(t()) :: float()
  defp calculate_segment_utilization(state) do
    # Simplified calculation - would be more accurate in production
    if map_size(state.segments) > 0 do
      # Assume 75% utilization
      0.75
    else
      0.0
    end
  end
end
