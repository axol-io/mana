defmodule History.Index.BloomIndex do
  @moduledoc """
  Bloom filter index for fast log filtering.

  Maintains bloom filters per block for quick pre-filtering of log queries.
  Uses Ethereum's 2048-bit bloom filter standard.

  ## Query Flow

  1. Build query bloom from filter criteria
  2. Check each block's bloom - skip if no match possible
  3. Load and filter actual logs only for matching blocks
  """
  use GenServer

  import Bitwise

  require Logger

  @bloom_bits 2048
  @bloom_bytes div(@bloom_bits, 8)

  defstruct [:data_dir, :index]

  # Client API

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @doc "Add logs to the bloom index for a block."
  @spec add_logs(non_neg_integer(), [map()]) :: :ok
  def add_logs(block_number, logs),
    do: GenServer.cast(__MODULE__, {:add_logs, block_number, logs})

  @doc "Get blocks that might contain logs matching the filter."
  @spec filter_blocks(non_neg_integer(), non_neg_integer(), map()) :: [non_neg_integer()]
  def filter_blocks(from_block, to_block, filter) do
    GenServer.call(__MODULE__, {:filter_blocks, from_block, to_block, filter})
  end

  @doc "Check if a single block might contain matching logs."
  @spec block_matches?(non_neg_integer(), map()) :: boolean()
  def block_matches?(block_number, filter) do
    GenServer.call(__MODULE__, {:block_matches, block_number, filter})
  end

  # Server callbacks

  @impl true
  def init(config) do
    data_dir = Keyword.get(config, :data_dir, "./data/history/index")
    File.mkdir_p!(data_dir)

    index = load_index(Path.join(data_dir, "bloom_index.bin"))

    Process.send_after(self(), :persist, 60_000)

    {:ok, %__MODULE__{data_dir: data_dir, index: index}}
  end

  @impl true
  def handle_cast({:add_logs, block_number, logs}, state) do
    bloom = build_bloom(logs)
    {:noreply, %{state | index: Map.put(state.index, block_number, bloom)}}
  end

  @impl true
  def handle_call({:filter_blocks, from_block, to_block, filter}, _from, state) do
    query_bloom = build_query_bloom(filter)

    matching =
      from_block..to_block
      |> Enum.filter(fn block ->
        case Map.get(state.index, block) do
          # No bloom stored, must check block
          nil -> true
          block_bloom -> bloom_subset?(query_bloom, block_bloom)
        end
      end)

    {:reply, matching, state}
  end

  def handle_call({:block_matches, block_number, filter}, _from, state) do
    result =
      case Map.get(state.index, block_number) do
        nil -> true
        block_bloom -> bloom_subset?(build_query_bloom(filter), block_bloom)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:persist, state) do
    persist_index(state)
    Process.send_after(self(), :persist, 60_000)
    {:noreply, state}
  end

  def handle_info(:shutdown, state) do
    persist_index(state)
    {:stop, :normal, state}
  end

  # Bloom filter operations

  defp build_bloom(logs) do
    Enum.reduce(logs, empty_bloom(), fn log, bloom ->
      bloom
      |> add_to_bloom(log.address)
      |> then(&Enum.reduce(log.topics, &1, fn t, b -> add_to_bloom(b, t) end))
    end)
  end

  defp build_query_bloom(filter) do
    empty_bloom()
    |> add_addresses(Map.get(filter, :address))
    |> add_topics(Map.get(filter, :topics))
  end

  defp add_addresses(bloom, nil), do: bloom

  defp add_addresses(bloom, addrs) when is_list(addrs),
    do: Enum.reduce(addrs, bloom, &add_to_bloom(&2, &1))

  defp add_addresses(bloom, addr), do: add_to_bloom(bloom, addr)

  defp add_topics(bloom, nil), do: bloom

  defp add_topics(bloom, topics) do
    topics
    |> Enum.with_index()
    |> Enum.reduce(bloom, fn
      {nil, _}, acc -> acc
      # OR positions can't be pre-filtered
      {t, _}, acc when is_list(t) -> acc
      {t, _}, acc -> add_to_bloom(acc, t)
    end)
  end

  defp empty_bloom, do: :binary.copy(<<0>>, @bloom_bytes)

  defp add_to_bloom(bloom, value) when is_binary(value) do
    hash = ExthCrypto.Hash.Keccak.kec(value)

    [bloom_position(hash, 0), bloom_position(hash, 2), bloom_position(hash, 4)]
    |> Enum.reduce(bloom, &set_bit(&2, &1))
  end

  defp add_to_bloom(bloom, _), do: bloom

  defp bloom_position(hash, offset) do
    <<_::binary-size(offset), high::8, low::8, _::binary>> = hash
    rem((high <<< 8) + low, @bloom_bits)
  end

  defp set_bit(bloom, position) do
    byte_idx = div(position, 8)
    bit_idx = 7 - rem(position, 8)

    <<prefix::binary-size(byte_idx), byte::8, suffix::binary>> = bloom
    <<prefix::binary, byte ||| 1 <<< bit_idx::8, suffix::binary>>
  end

  defp bloom_subset?(query, block) do
    # Query bloom must be a subset of block bloom
    query
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(block))
    |> Enum.all?(fn {q, b} -> (q &&& b) == q end)
  end

  # Persistence

  defp load_index(path) do
    case File.read(path) do
      {:ok, data} -> :erlang.binary_to_term(data)
      _ -> %{}
    end
  end

  defp persist_index(state) do
    path = Path.join(state.data_dir, "bloom_index.bin")
    File.write!(path, :erlang.term_to_binary(state.index))
    Logger.debug("[History.BloomIndex] Persisted #{map_size(state.index)} block blooms")
  end
end
