defmodule History.Storage.Shard do
  @moduledoc """
  Individual shard backed by CubDB.

  Each shard manages its own CubDB instance for a partition
  of the block number space.
  """
  use GenServer

  require Logger

  defstruct [:id, :db, :data_dir, :stats]

  @type t :: %__MODULE__{
          id: atom(),
          db: CubDB.db(),
          data_dir: String.t(),
          stats: %{
            blocks: non_neg_integer(),
            logs: non_neg_integer(),
            disk_bytes: non_neg_integer()
          }
        }

  # Client API

  def start_link({id, data_dir}) do
    GenServer.start_link(__MODULE__, {id, data_dir}, name: id)
  end

  @spec put(atom(), term(), term()) :: :ok
  def put(shard, key, value) do
    GenServer.call(shard, {:put, key, value})
  end

  @spec get(atom(), term()) :: {:ok, term()} | {:error, :not_found}
  def get(shard, key) do
    GenServer.call(shard, {:get, key})
  end

  @spec delete(atom(), term()) :: :ok
  def delete(shard, key) do
    GenServer.call(shard, {:delete, key})
  end

  @spec stats(atom()) :: %{
          blocks: non_neg_integer(),
          logs: non_neg_integer(),
          disk_bytes: non_neg_integer()
        }
  def stats(shard) do
    GenServer.call(shard, :stats)
  end

  @spec compact(atom()) :: :ok
  def compact(shard) do
    GenServer.cast(shard, :compact)
  end

  # Server callbacks

  @impl true
  def init({id, data_dir}) do
    shard_dir = Path.join(data_dir, Atom.to_string(id))
    File.mkdir_p!(shard_dir)

    {:ok, db} = CubDB.start_link(data_dir: shard_dir)

    state = %__MODULE__{
      id: id,
      db: db,
      data_dir: shard_dir,
      stats: %{blocks: 0, logs: 0, disk_bytes: 0}
    }

    # Calculate initial stats
    state = update_stats(state)

    Logger.debug("[History.Shard] Started #{id} with #{state.stats.blocks} blocks")

    {:ok, state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    CubDB.put(state.db, key, value)

    # Update stats for certain key types
    state =
      case key do
        {:header, _} ->
          update_in(state.stats.blocks, &(&1 + 1))

        {:logs, _} ->
          log_count = length(value)
          update_in(state.stats.logs, &(&1 + log_count))

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:get, key}, _from, state) do
    case CubDB.get(state.db, key) do
      nil -> {:reply, {:error, :not_found}, state}
      value -> {:reply, {:ok, value}, state}
    end
  end

  def handle_call({:delete, key}, _from, state) do
    CubDB.delete(state.db, key)
    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state) do
    # Update disk usage
    disk_bytes = calculate_disk_usage(state.data_dir)
    stats = %{state.stats | disk_bytes: disk_bytes}
    {:reply, stats, %{state | stats: stats}}
  end

  @impl true
  def handle_cast(:compact, state) do
    CubDB.compact(state.db)
    {:noreply, state}
  end

  # Private functions

  defp update_stats(state) do
    # Count entries by type
    blocks =
      CubDB.select(state.db,
        min_key: {:header, 0},
        max_key: {:header, :infinity}
      )
      |> Enum.count()

    logs =
      CubDB.select(state.db,
        min_key: {:logs, 0},
        max_key: {:logs, :infinity}
      )
      |> Enum.reduce(0, fn {_key, value}, acc -> acc + length(value) end)

    disk_bytes = calculate_disk_usage(state.data_dir)

    %{state | stats: %{blocks: blocks, logs: logs, disk_bytes: disk_bytes}}
  end

  defp calculate_disk_usage(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(fn path ->
          case File.stat(path) do
            {:ok, %{size: size}} -> size
            _ -> 0
          end
        end)
        |> Enum.sum()

      _ ->
        0
    end
  end
end
