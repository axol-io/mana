defmodule History.Query do
  @moduledoc """
  Log query engine for eth_getLogs.

  Implements efficient log filtering with bloom pre-filtering.

  ## Query Flow

  1. Resolve block range (handle :latest, :earliest)
  2. Use bloom index to get candidate blocks
  3. Load logs from candidate blocks in parallel
  4. Apply precise filters (address, topics)
  5. Return matching logs with full metadata
  """

  alias History.{Index, Storage, Sync}

  @max_block_range 10_000
  @max_logs_per_query 10_000

  @type log :: History.log()
  @type filter :: History.log_filter()

  @doc """
  Query logs matching the filter criteria.
  """
  @spec get_logs(filter()) :: {:ok, [log()]} | {:error, term()}
  def get_logs(filter) do
    with {:ok, from_block, to_block} <- resolve_block_range(filter),
         :ok <- validate_range(from_block, to_block) do
      query_logs(from_block, to_block, filter)
    end
  end

  # Block range resolution

  defp resolve_block_range(%{block_hash: hash}) when not is_nil(hash) do
    # TODO: Implement block_hash -> block_number index
    # Once implemented, this will return {:ok, number}
    find_block_by_hash(hash)
  end

  defp resolve_block_range(filter) do
    from_block = filter |> Map.get(:from_block, :earliest) |> resolve_block_number()
    to_block = filter |> Map.get(:to_block, :latest) |> resolve_block_number()
    {:ok, from_block, to_block}
  end

  defp resolve_block_number(:earliest), do: 0
  defp resolve_block_number(:latest), do: current_block()
  defp resolve_block_number(n) when is_integer(n), do: n
  defp resolve_block_number("0x" <> hex), do: String.to_integer(hex, 16)
  defp resolve_block_number(_), do: 0

  defp current_block do
    case Sync.Pipeline.block_number() do
      {:ok, n} -> n
      _ -> 0
    end
  end

  defp validate_range(from, to) when from > to, do: {:error, :invalid_range}

  defp validate_range(from, to) when to - from > @max_block_range,
    do: {:error, {:range_too_large, to - from, @max_block_range}}

  defp validate_range(_, _), do: :ok

  # Query execution

  defp query_logs(from_block, to_block, filter) do
    logs =
      from_block
      |> Index.BloomIndex.filter_blocks(to_block, filter)
      |> Task.async_stream(&fetch_and_filter(&1, filter),
        max_concurrency: System.schedulers_online() * 2,
        timeout: 30_000
      )
      |> Stream.flat_map(fn
        {:ok, logs} -> logs
        _ -> []
      end)
      |> Enum.take(@max_logs_per_query)

    {:ok, logs}
  end

  defp fetch_and_filter(block_number, filter) do
    case Storage.get_logs(block_number) do
      {:ok, logs} ->
        logs
        |> Enum.filter(&matches_filter?(&1, filter))
        |> Enum.map(&enrich_log(&1, block_number))

      {:error, :not_found} ->
        []
    end
  end

  # Filter matching

  defp matches_filter?(log, filter) do
    matches_address?(log, filter) and matches_topics?(log, filter)
  end

  defp matches_address?(_log, filter) when not is_map_key(filter, :address), do: true

  defp matches_address?(log, %{address: addresses}) when is_list(addresses) do
    normalized_log = normalize_address(log.address)
    Enum.any?(addresses, &(normalize_address(&1) == normalized_log))
  end

  defp matches_address?(log, %{address: address}) do
    normalize_address(log.address) == normalize_address(address)
  end

  defp matches_topics?(_log, filter) when not is_map_key(filter, :topics), do: true

  defp matches_topics?(log, %{topics: topic_filters}) do
    topic_filters
    |> Enum.with_index()
    |> Enum.all?(fn {filter_topic, idx} ->
      topic_matches?(Enum.at(log.topics, idx), filter_topic)
    end)
  end

  defp topic_matches?(_log_topic, nil), do: true

  defp topic_matches?(log_topic, filter_topics) when is_list(filter_topics) do
    normalized = normalize_topic(log_topic)
    Enum.any?(filter_topics, &(normalize_topic(&1) == normalized))
  end

  defp topic_matches?(log_topic, filter_topic) do
    normalize_topic(log_topic) == normalize_topic(filter_topic)
  end

  # Normalization helpers

  defp normalize_address(nil), do: nil

  defp normalize_address(addr) when is_binary(addr) do
    addr |> String.downcase() |> String.replace_prefix("0x", "") |> String.pad_leading(40, "0")
  end

  defp normalize_topic(nil), do: nil

  defp normalize_topic(topic) when is_binary(topic) do
    topic |> String.downcase() |> String.replace_prefix("0x", "") |> String.pad_leading(64, "0")
  end

  # Log enrichment

  defp enrich_log(log, block_number) do
    block_hash = get_block_hash(block_number)
    tx_hash = get_tx_hash(block_number, log.transaction_index)

    %{
      address: format_hex(log.address),
      topics: Enum.map(log.topics, &format_hex/1),
      data: format_hex(log.data),
      block_number: block_number,
      block_hash: format_hex(block_hash),
      transaction_hash: format_hex(tx_hash),
      transaction_index: log.transaction_index,
      log_index: log.log_index,
      removed: false
    }
  end

  defp get_block_hash(block_number) do
    case Storage.get_header(block_number) do
      {:ok, header} -> header.block_hash
      _ -> nil
    end
  end

  defp get_tx_hash(block_number, tx_index) do
    with {:ok, txs} <- Storage.get_transactions(block_number),
         tx when not is_nil(tx) <- Enum.at(txs, tx_index) do
      tx.hash
    else
      _ -> nil
    end
  end

  defp format_hex(nil), do: nil
  defp format_hex(bin) when is_binary(bin), do: "0x" <> Base.encode16(bin, case: :lower)

  defp find_block_by_hash(_hash) do
    # TODO: Implement block_hash -> block_number index
    {:error, :block_hash_lookup_not_implemented}
  end
end
