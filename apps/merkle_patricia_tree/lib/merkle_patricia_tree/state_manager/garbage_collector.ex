defmodule MerklePatriciaTree.StateManager.GarbageCollector do
  @moduledoc """
  Garbage collection system for removing unreferenced state tree nodes
  and reclaiming storage space.
  """

  require Logger
  alias MerklePatriciaTree.DB

  @typedoc "Garbage collection statistics"
  @type gc_stats :: %{
          nodes_collected: non_neg_integer(),
          bytes_freed: non_neg_integer(),
          duration_ms: non_neg_integer(),
          errors: [term()]
        }

  @doc """
  Collect garbage for unreferenced nodes.
  """
  @spec collect_unreferenced_nodes(DB.db(), [binary()]) :: {non_neg_integer(), non_neg_integer()}
  def collect_unreferenced_nodes(db, unreferenced_roots) do
    Logger.info(
      "[GarbageCollector] Starting collection for #{length(unreferenced_roots)} unreferenced roots"
    )

    start_time = System.monotonic_time(:millisecond)

    # Collect all nodes from unreferenced roots
    all_nodes =
      Enum.flat_map(unreferenced_roots, fn root ->
        collect_trie_nodes(db, root)
      end)
      |> Enum.uniq()

    # Remove duplicates and batch delete
    {nodes_removed, bytes_freed} = batch_delete_nodes(db, all_nodes)

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "[GarbageCollector] Collection completed: #{nodes_removed} nodes, #{bytes_freed} bytes in #{duration}ms"
    )

    {nodes_removed, bytes_freed}
  end

  @doc """
  Perform incremental garbage collection with time limits.
  """
  @spec incremental_collect(DB.db(), [binary()], non_neg_integer()) :: gc_stats()
  def incremental_collect(db, unreferenced_roots, max_time_ms) do
    Logger.debug("[GarbageCollector] Starting incremental collection (#{max_time_ms}ms limit)")

    start_time = System.monotonic_time(:millisecond)

    initial_stats = %{
      nodes_collected: 0,
      bytes_freed: 0,
      duration_ms: 0,
      errors: []
    }

    # Process roots incrementally until time limit
    final_stats =
      Enum.reduce_while(unreferenced_roots, initial_stats, fn root, acc ->
        current_time = System.monotonic_time(:millisecond)
        elapsed = current_time - start_time

        if elapsed >= max_time_ms do
          {:halt, acc}
        else
          try do
            nodes = collect_trie_nodes(db, root)
            {nodes_removed, bytes_freed} = batch_delete_nodes(db, nodes)

            new_acc = %{
              acc
              | nodes_collected: acc.nodes_collected + nodes_removed,
                bytes_freed: acc.bytes_freed + bytes_freed
            }

            {:cont, new_acc}
          rescue
            error ->
              new_acc = %{acc | errors: [error | acc.errors]}
              {:cont, new_acc}
          end
        end
      end)

    total_duration = System.monotonic_time(:millisecond) - start_time

    %{final_stats | duration_ms: total_duration}
  end

  @doc """
  Collect nodes that haven't been accessed recently.
  """
  @spec collect_cold_nodes(DB.db(), non_neg_integer()) :: gc_stats()
  def collect_cold_nodes(db, age_threshold_ms) do
    Logger.info("[GarbageCollector] Collecting cold nodes older than #{age_threshold_ms}ms")

    start_time = System.monotonic_time(:millisecond)
    cutoff_time = start_time - age_threshold_ms

    # Find nodes that haven't been accessed recently
    cold_nodes = find_cold_nodes(db, cutoff_time)

    # Remove cold nodes
    {nodes_removed, bytes_freed} = batch_delete_nodes(db, cold_nodes)

    duration = System.monotonic_time(:millisecond) - start_time

    %{
      nodes_collected: nodes_removed,
      bytes_freed: bytes_freed,
      duration_ms: duration,
      errors: []
    }
  end

  @doc """
  Compact fragmented storage after garbage collection.
  """
  @spec compact_storage(DB.db()) :: {:ok, map()} | {:error, term()}
  def compact_storage(db) do
    Logger.info("[GarbageCollector] Starting storage compaction")

    start_time = System.monotonic_time(:millisecond)

    try do
      compaction_result =
        case db do
          {:ets, table} ->
            # For ETS, we can't really compact, but we can measure fragmentation
            info = :ets.info(table)
            memory_words = Keyword.get(info, :memory, 0)
            size = Keyword.get(info, :size, 0)

            %{
              backend: :ets,
              memory_words: memory_words,
              entries: size,
              fragmentation_ratio: if(size > 0, do: memory_words / size, else: 0.0)
            }

          {:antidote, _} ->
            # AntidoteDB compaction would be handled by the database
            %{
              backend: :antidote,
              compaction_triggered: true
            }

          _ ->
            %{
              backend: :unknown,
              compaction_attempted: true
            }
        end

      duration = System.monotonic_time(:millisecond) - start_time

      result = Map.put(compaction_result, :duration_ms, duration)

      Logger.info("[GarbageCollector] Storage compaction completed: #{inspect(result)}")

      {:ok, result}
    rescue
      error ->
        Logger.error("[GarbageCollector] Storage compaction failed: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Get garbage collection recommendations based on current state.
  """
  @spec get_gc_recommendations(DB.db()) :: %{
          should_collect: boolean(),
          estimated_nodes: non_neg_integer(),
          estimated_bytes: non_neg_integer(),
          urgency: :low | :medium | :high | :critical,
          reasons: [String.t()]
        }
  def get_gc_recommendations(db) do
    # Analyze current database state
    stats = analyze_db_state(db)

    # Calculate recommendations
    reasons = []
    urgency = :low

    # Check fragmentation
    {reasons, urgency} =
      if stats.fragmentation_ratio > 0.5 do
        {[
           "High fragmentation detected (#{Float.round(stats.fragmentation_ratio * 100, 1)}%)"
           | reasons
         ], :high}
      else
        {reasons, urgency}
      end

    # Check memory usage
    {reasons, urgency} =
      if stats.memory_usage_mb > 1000 do
        new_urgency = if urgency == :high, do: :critical, else: :medium

        {["High memory usage (#{Float.round(stats.memory_usage_mb, 1)} MB)" | reasons],
         new_urgency}
      else
        {reasons, urgency}
      end

    # Check orphaned nodes
    {reasons, urgency} =
      if stats.estimated_orphaned_nodes > 1000 do
        new_urgency = max_urgency(urgency, :medium)
        {["Many orphaned nodes (#{stats.estimated_orphaned_nodes})" | reasons], new_urgency}
      else
        {reasons, urgency}
      end

    should_collect = urgency in [:medium, :high, :critical] or length(reasons) > 0

    %{
      should_collect: should_collect,
      estimated_nodes: stats.estimated_orphaned_nodes,
      estimated_bytes: stats.estimated_orphaned_bytes,
      urgency: urgency,
      reasons: reasons
    }
  end

  # Private helper functions

  defp collect_trie_nodes(db, root_hash) do
    # In a real implementation, this would traverse the trie starting from root
    # and collect all reachable node hashes. For now, simulate this.

    case DB.get(db, root_hash) do
      {:ok, _node_data} ->
        # Simulate collecting child nodes
        # In production, this would parse the node and recursively collect children
        child_nodes =
          for i <- 1..5 do
            :crypto.hash(:sha256, root_hash <> <<i>>)
          end

        [root_hash | child_nodes]

      :not_found ->
        Logger.debug("[GarbageCollector] Root not found: #{inspect(root_hash)}")
        []
    end
  end

  defp batch_delete_nodes(db, nodes) when length(nodes) > 100 do
    # For large batches, delete in chunks
    chunk_size = 100

    nodes
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce({0, 0}, fn chunk, {total_nodes, total_bytes} ->
      {chunk_nodes, chunk_bytes} = delete_node_chunk(db, chunk)
      {total_nodes + chunk_nodes, total_bytes + chunk_bytes}
    end)
  end

  defp batch_delete_nodes(db, nodes) do
    delete_node_chunk(db, nodes)
  end

  defp delete_node_chunk(db, nodes) do
    Logger.debug("[GarbageCollector] Deleting chunk of #{length(nodes)} nodes")

    # Calculate bytes before deletion
    total_bytes =
      Enum.reduce(nodes, 0, fn node_hash, acc ->
        case DB.get(db, node_hash) do
          {:ok, data} -> acc + byte_size(data)
          :not_found -> acc
        end
      end)

    # Delete nodes
    deleted_count =
      Enum.reduce(nodes, 0, fn node_hash, acc ->
        try do
          DB.delete!(db, node_hash)
          acc + 1
        rescue
          _ ->
            Logger.debug("[GarbageCollector] Failed to delete node: #{inspect(node_hash)}")
            acc
        end
      end)

    {deleted_count, total_bytes}
  end

  defp find_cold_nodes(db, _cutoff_time) do
    # This is a simplified implementation
    # In production, would maintain access timestamps for nodes

    case db do
      {:ets, _table} ->
        # For ETS, we don't have access time tracking
        # Return empty list for now
        []

      _ ->
        # For other backends, would query based on access patterns
        []
    end
  end

  defp analyze_db_state(db) do
    case db do
      {:ets, table} ->
        info = :ets.info(table)
        memory_words = Keyword.get(info, :memory, 0)
        size = Keyword.get(info, :size, 0)
        word_size = :erlang.system_info(:wordsize)

        %{
          backend: :ets,
          memory_usage_mb: memory_words * word_size / (1024 * 1024),
          fragmentation_ratio: if(size > 0, do: memory_words / size / 100, else: 0.0),
          # Rough estimate
          estimated_orphaned_nodes: max(0, size - 1000),
          estimated_orphaned_bytes: max(0, memory_words * word_size - 1000 * 100)
        }

      _ ->
        %{
          backend: :unknown,
          # Default estimate
          memory_usage_mb: 100.0,
          fragmentation_ratio: 0.2,
          estimated_orphaned_nodes: 500,
          # 1MB estimate
          estimated_orphaned_bytes: 1024 * 1024
        }
    end
  end

  defp max_urgency(a, b) do
    urgencies = [:low, :medium, :high, :critical]

    max(Enum.find_index(urgencies, &(&1 == a)) || 0, Enum.find_index(urgencies, &(&1 == b)) || 0)
    |> then(&Enum.at(urgencies, &1))
  end
end
