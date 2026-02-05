defmodule History.Cache.Headers do
  @moduledoc """
  In-memory cache for recently accessed block headers.

  Uses ETS for fast concurrent reads.
  """
  use GenServer

  @table_name :history_header_cache
  @default_max_entries 10_000

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec get(non_neg_integer()) :: {:ok, map()} | :miss
  def get(block_number) do
    case :ets.lookup(@table_name, block_number) do
      [{^block_number, header, _ts}] -> {:ok, header}
      [] -> :miss
    end
  end

  @spec put(non_neg_integer(), map()) :: :ok
  def put(block_number, header) do
    GenServer.cast(__MODULE__, {:put, block_number, header})
  end

  @impl true
  def init(config) do
    max_entries = Keyword.get(config, :max_headers, @default_max_entries)

    :ets.new(@table_name, [
      :named_table,
      :set,
      :public,
      read_concurrency: true
    ])

    {:ok, %{max_entries: max_entries}}
  end

  @impl true
  def handle_cast({:put, block_number, header}, state) do
    # Evict old entries if needed
    if :ets.info(@table_name, :size) >= state.max_entries do
      evict_oldest()
    end

    :ets.insert(@table_name, {block_number, header, System.monotonic_time()})
    {:noreply, state}
  end

  defp evict_oldest do
    # Simple LRU: delete 10% of oldest entries
    entries = :ets.tab2list(@table_name)

    entries
    |> Enum.sort_by(fn {_, _, ts} -> ts end)
    |> Enum.take(div(length(entries), 10))
    |> Enum.each(fn {block_number, _, _} ->
      :ets.delete(@table_name, block_number)
    end)
  end
end
