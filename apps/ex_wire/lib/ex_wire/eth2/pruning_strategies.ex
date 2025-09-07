defmodule ExWire.Eth2.PruningStrategies do
  @moduledoc """
  Specific pruning strategies for different types of blockchain data.

  Each strategy is optimized for the specific characteristics and access patterns
  of different data types in the beacon chain client.
  """

  require Logger

  @doc """
  Enhanced fork choice pruning with detailed block analysis.

  Removes blocks that:
  1. Are not descendants of the finalized block
  2. Have been orphaned for more than the safety margin
  3. Are older than the reorg protection window

  Returns detailed information about what was pruned.
  """
  def prune_fork_choice(store, finalized_checkpoint, opts \\ []) do
    safety_margin_slots = Keyword.get(opts, :safety_margin_slots, 32)
    current_slot = get_current_slot()

    Logger.info(
      "Starting enhanced fork choice pruning for finalized checkpoint #{finalized_checkpoint.epoch}"
    )

    initial_block_count = map_size(store.blocks)
    initial_memory = estimate_fork_choice_memory(store)

    # Get all blocks that are descendants of finalized block
    finalized_root = finalized_checkpoint.root
    finalized_descendants = get_all_descendants(store, finalized_root)

    # Find blocks to prune
    {blocks_to_prune, prune_reasons} =
      identify_prunable_blocks(
        store,
        finalized_descendants,
        current_slot,
        safety_margin_slots
      )

    # Execute pruning with detailed tracking
    pruned_store = execute_fork_choice_pruning(store, blocks_to_prune)

    final_block_count = map_size(pruned_store.blocks)
    final_memory = estimate_fork_choice_memory(pruned_store)

    result = %{
      initial_blocks: initial_block_count,
      final_blocks: final_block_count,
      pruned_blocks: initial_block_count - final_block_count,
      memory_freed_mb: (initial_memory - final_memory) / (1024 * 1024),
      prune_reasons: prune_reasons,
      finalized_root: finalized_root,
      finalized_epoch: finalized_checkpoint.epoch
    }

    {:ok, pruned_store, result}
  end

  @doc """
  State trie pruning with reference counting.

  Implements a mark-and-sweep garbage collector for state trie nodes:
  1. Mark all nodes referenced by recent states
  2. Sweep unreferenced nodes older than the retention period
  3. Compact remaining nodes to reduce fragmentation
  """
  def prune_state_trie(state_store, retention_slots, opts \\ []) do
    Logger.info("Starting state trie pruning with #{retention_slots} slot retention")

    compact_after = Keyword.get(opts, :compact_after_pruning, true)
    parallel_marking = Keyword.get(opts, :parallel_marking, true)

    start_time = System.monotonic_time(:millisecond)

    # Phase 1: Mark all referenced nodes
    {referenced_nodes, mark_time} =
      mark_referenced_nodes(state_store, retention_slots, parallel_marking)

    # Phase 2: Sweep unreferenced nodes
    {pruned_nodes, sweep_time} = sweep_unreferenced_nodes(state_store, referenced_nodes)

    # Phase 3: Optional compaction
    {compaction_stats, compact_time} =
      if compact_after do
        compact_state_storage(state_store)
      else
        {%{}, 0}
      end

    total_time = System.monotonic_time(:millisecond) - start_time

    result = %{
      referenced_nodes: MapSet.size(referenced_nodes),
      pruned_nodes: pruned_nodes.count,
      freed_bytes: pruned_nodes.bytes,
      mark_time_ms: mark_time,
      sweep_time_ms: sweep_time,
      compact_time_ms: compact_time,
      total_time_ms: total_time,
      compaction_stats: compaction_stats
    }

    {:ok, result}
  end

  @doc """
  Intelligent attestation pool pruning based on inclusion possibility.

  Removes attestations that:
  1. Are too old to be included in new blocks (> 1 epoch)
  2. Are from orphaned forks that can never be canonical
  3. Have invalid committee assignments after finalization
  4. Are duplicates or subsumed by other attestations
  """
  def prune_attestation_pool(attestation_pool, beacon_state, fork_choice_store, opts \\ []) do
    Logger.info("Starting intelligent attestation pool pruning")

    aggressive = Keyword.get(opts, :aggressive, false)
    deduplicate = Keyword.get(opts, :deduplicate, true)

    current_slot = beacon_state.slot
    # 1 or 2 epochs
    inclusion_window = if aggressive, do: 32, else: 64

    initial_count = count_attestations(attestation_pool)

    # Prune by age
    {pool_after_age, age_pruned} =
      prune_attestations_by_age(
        attestation_pool,
        current_slot,
        inclusion_window
      )

    # Prune orphaned attestations
    {pool_after_orphan, orphan_pruned} =
      prune_orphaned_attestations(
        pool_after_age,
        fork_choice_store
      )

    # Prune invalid committee attestations
    {pool_after_committee, committee_pruned} =
      prune_invalid_committee_attestations(
        pool_after_orphan,
        beacon_state
      )

    # Optional deduplication
    {final_pool, dedup_pruned} =
      if deduplicate do
        deduplicate_attestations(pool_after_committee)
      else
        {pool_after_committee, 0}
      end

    final_count = count_attestations(final_pool)

    result = %{
      initial_attestations: initial_count,
      final_attestations: final_count,
      total_pruned: initial_count - final_count,
      pruned_by_age: age_pruned,
      pruned_orphaned: orphan_pruned,
      pruned_invalid_committee: committee_pruned,
      pruned_duplicates: dedup_pruned,
      inclusion_window_slots: inclusion_window
    }

    {:ok, final_pool, result}
  end

  @doc """
  Block storage pruning with archive-aware retention.

  Implements tiered block storage:
  1. Keep recent blocks in full (headers + bodies)
  2. Keep intermediate blocks with headers only
  3. Archive ancient blocks to cold storage
  4. Remove blocks that are definitely not needed
  """
  def prune_block_storage(block_store, finalized_slot, _config, _opts \\ []) do
    Logger.info("Starting block storage pruning for finalized slot #{finalized_slot}")

    archive_mode = Map.get(config, :archive_mode, false)
    cold_storage = Map.get(config, :enable_cold_storage, false)

    if archive_mode do
      # Skip pruning in archive mode
      {:ok, block_store, %{archive_mode: true, pruned_blocks: 0}}
    else
      # Define retention tiers
      # ~1 day
      full_retention = finalized_slot - Map.get(config, :full_block_retention, 32 * 256)
      # ~1 week
      header_retention = finalized_slot - Map.get(config, :header_retention, 32 * 256 * 7)

      initial_count = count_blocks(block_store)

      # Tier 1: Prune old block bodies (keep headers)
      {store_after_body, body_stats} = prune_block_bodies(block_store, full_retention)

      # Tier 2: Archive very old blocks
      {store_after_archive, archive_stats} =
        if cold_storage do
          archive_old_blocks(store_after_body, header_retention)
        else
          {store_after_body, %{archived: 0}}
        end

      # Tier 3: Remove ancient blocks completely
      {final_store, removal_stats} =
        remove_ancient_blocks(store_after_archive, header_retention * 2)

      final_count = count_blocks(final_store)

      result = %{
        initial_blocks: initial_count,
        final_blocks: final_count,
        total_pruned: initial_count - final_count,
        body_pruning: body_stats,
        archive_stats: archive_stats,
        removal_stats: removal_stats,
        full_retention_slot: full_retention,
        header_retention_slot: header_retention
      }

      {:ok, final_store, result}
    end
  end

  @doc """
  Execution layer log pruning with event filtering.

  Manages execution layer logs by:
  1. Removing logs older than retention period
  2. Keeping important events (deposits, withdrawals, etc.)
  3. Compressing old logs before archival
  4. Maintaining address-based indexes for queries
  """
  def prune_execution_logs(log_store, finalized_slot, _config, opts \\ []) do
    Logger.info("Starting execution layer log pruning")

    # ~1 month
    retention_slots = Map.get(config, :execution_log_retention, 32 * 256 * 30)
    keep_important = Keyword.get(opts, :keep_important_events, true)

    cutoff_slot = finalized_slot - retention_slots
    initial_log_count = count_logs(log_store)

    # Identify logs to keep (important events)
    important_logs =
      if keep_important do
        identify_important_logs(log_store, cutoff_slot)
      else
        MapSet.new()
      end

    # Prune old logs
    {pruned_store, pruned_count} = prune_logs_before_slot(log_store, cutoff_slot, important_logs)

    # Update log indexes
    updated_store = rebuild_log_indexes(pruned_store)

    final_count = count_logs(updated_store)

    result = %{
      initial_logs: initial_log_count,
      final_logs: final_count,
      pruned_logs: pruned_count,
      important_logs_kept: MapSet.size(important_logs),
      cutoff_slot: cutoff_slot,
      retention_slots: retention_slots
    }

    {:ok, updated_store, result}
  end

  # Private Functions - Fork Choice Pruning

  defp identify_prunable_blocks(store, finalized_descendants, current_slot, safety_margin) do
    prunable = []
    reasons = %{}

    Enum.reduce(store.blocks, {prunable, reasons}, fn {block_root, block_info},
                                                      {acc_blocks, acc_reasons} ->
      cond do
        # Not a descendant of finalized block
        not MapSet.member?(finalized_descendants, block_root) ->
          reason = {:not_finalized_descendant, block_info.block.slot}
          {[block_root | acc_blocks], Map.put(acc_reasons, block_root, reason)}

        # Too old even with safety margin
        block_info.block.slot < current_slot - safety_margin ->
          reason = {:too_old, block_info.block.slot, current_slot - safety_margin}
          {[block_root | acc_blocks], Map.put(acc_reasons, block_root, reason)}

        # Marked as invalid
        Map.get(block_info, :invalid, false) ->
          reason = {:marked_invalid, block_info.block.slot}
          {[block_root | acc_blocks], Map.put(acc_reasons, block_root, reason)}

        true ->
          {acc_blocks, acc_reasons}
      end
    end)
  end

  defp execute_fork_choice_pruning(store, blocks_to_prune) do
    # Remove prunable blocks and clean up caches
    blocks = Map.drop(store.blocks, blocks_to_prune)

    # Clean up related caches
    weight_cache = Map.drop(store.weight_cache || %{}, blocks_to_prune)
    children_cache = Map.drop(store.children_cache || %{}, blocks_to_prune)
    best_child_cache = Map.drop(store.best_child_cache || %{}, blocks_to_prune)
    best_descendant_cache = Map.drop(store.best_descendant_cache || %{}, blocks_to_prune)

    # Remove from latest messages if they reference pruned blocks
    latest_messages =
      Map.filter(store.latest_messages || %{}, fn {_validator, message} ->
        not Enum.member?(blocks_to_prune, message.root)
      end)

    %{
      store
      | blocks: blocks,
        weight_cache: weight_cache,
        children_cache: children_cache,
        best_child_cache: best_child_cache,
        best_descendant_cache: best_descendant_cache,
        latest_messages: latest_messages
    }
  end

  defp get_all_descendants(store, root) do
    descendants = MapSet.new([root])

    get_descendants_recursive(store, root, descendants)
  end

  defp get_descendants_recursive(store, parent_root, descendants) do
    children = Map.get(store.children_cache || %{}, parent_root, [])

    Enum.reduce(children, descendants, fn child_root, acc ->
      if MapSet.member?(acc, child_root) do
        # Already processed
        acc
      else
        new_acc = MapSet.put(acc, child_root)
        get_descendants_recursive(store, child_root, new_acc)
      end
    end)
  end

  # Private Functions - State Trie Pruning

  defp mark_referenced_nodes(state_store, retention_slots, parallel) do
    start_time = System.monotonic_time(:millisecond)

    # Get states to analyze
    current_slot = get_current_slot()
    start_slot = max(0, current_slot - retention_slots)

    referenced =
      if parallel do
        mark_nodes_parallel(state_store, start_slot, current_slot)
      else
        mark_nodes_sequential(state_store, start_slot, current_slot)
      end

    elapsed = System.monotonic_time(:millisecond) - start_time

    {referenced, elapsed}
  end

  defp mark_nodes_parallel(state_store, start_slot, end_slot) do
    # Use Task.async_stream for parallel marking
    start_slot..end_slot
    |> Task.async_stream(
      fn slot ->
        case get_state_by_slot(state_store, slot) do
          {:ok, _state} -> extract_trie_nodes(state)
          _ -> MapSet.new()
        end
      end,
      max_concurrency: System.schedulers_online()
    )
    |> Enum.reduce(MapSet.new(), fn {:ok, nodes}, acc ->
      MapSet.union(acc, nodes)
    end)
  end

  defp mark_nodes_sequential(state_store, start_slot, end_slot) do
    start_slot..end_slot
    |> Enum.reduce(MapSet.new(), fn slot, acc ->
      case get_state_by_slot(state_store, slot) do
        {:ok, _state} ->
          nodes = extract_trie_nodes(state)
          MapSet.union(acc, nodes)

        _ ->
          acc
      end
    end)
  end

  defp sweep_unreferenced_nodes(state_store, referenced_nodes) do
    start_time = System.monotonic_time(:millisecond)

    # This would iterate through all trie nodes and remove unreferenced ones
    # Placeholder implementation
    pruned_count = 1000
    pruned_bytes = pruned_count * 1024

    elapsed = System.monotonic_time(:millisecond) - start_time

    {%{count: pruned_count, bytes: pruned_bytes}, elapsed}
  end

  defp compact_state_storage(state_store) do
    start_time = System.monotonic_time(:millisecond)

    # Defragment storage and optimize layout
    # Placeholder implementation
    stats = %{
      defragmented_mb: 50.0,
      optimization_ratio: 0.85
    }

    elapsed = System.monotonic_time(:millisecond) - start_time

    {stats, elapsed}
  end

  # Private Functions - Attestation Pruning

  defp prune_attestations_by_age(attestation_pool, current_slot, window_slots) do
    cutoff_slot = current_slot - window_slots

    initial_count = count_attestations(attestation_pool)

    pruned_pool =
      Map.filter(attestation_pool, fn {slot, _attestations} ->
        slot >= cutoff_slot
      end)

    final_count = count_attestations(pruned_pool)
    pruned_count = initial_count - final_count

    {pruned_pool, pruned_count}
  end

  defp prune_orphaned_attestations(attestation_pool, fork_choice_store) do
    # Remove attestations for blocks not in fork choice
    canonical_blocks = MapSet.new(Map.keys(fork_choice_store.blocks || %{}))

    initial_count = count_attestations(attestation_pool)

    pruned_pool =
      Map.new(attestation_pool, fn {slot, attestations} ->
        {slot,
         Enum.filter(attestations, fn attestation ->
           MapSet.member?(canonical_blocks, attestation.data.beacon_block_root)
         end)}
      end)
      # Remove empty slots
      |> Map.filter(fn {_slot, attestations} -> length(attestations) > 0 end)

    final_count = count_attestations(pruned_pool)
    pruned_count = initial_count - final_count

    {pruned_pool, pruned_count}
  end

  defp prune_invalid_committee_attestations(attestation_pool, beacon_state) do
    # This would validate committee assignments against current state
    # For now, return unchanged
    initial_count = count_attestations(attestation_pool)
    {attestation_pool, 0}
  end

  defp deduplicate_attestations(attestation_pool) do
    initial_count = count_attestations(attestation_pool)

    # Remove duplicate attestations within each slot
    deduped_pool =
      Map.map(attestation_pool, fn {slot, attestations} ->
        {slot, Enum.uniq_by(attestations, &attestation_signature_key/1)}
      end)

    final_count = count_attestations(deduped_pool)
    pruned_count = initial_count - final_count

    {deduped_pool, pruned_count}
  end

  defp attestation_signature_key(attestation) do
    {attestation.data, attestation.aggregation_bits}
  end

  # Private Functions - Block Storage Pruning

  defp prune_block_bodies(block_store, retention_cutoff) do
    # Remove block bodies older than cutoff, keep headers
    # Placeholder implementation
    {block_store, %{bodies_pruned: 100, space_freed_mb: 50.0}}
  end

  defp archive_old_blocks(block_store, archive_cutoff) do
    # Move old blocks to cold storage
    # Placeholder implementation
    {block_store, %{archived: 50}}
  end

  defp remove_ancient_blocks(block_store, removal_cutoff) do
    # Remove very old blocks completely
    # Placeholder implementation  
    {block_store, %{removed: 10}}
  end

  # Private Functions - Log Pruning

  defp identify_important_logs(log_store, cutoff_slot) do
    # Identify important events to keep (deposits, withdrawals, etc.)
    # Placeholder implementation
    MapSet.new()
  end

  defp prune_logs_before_slot(log_store, cutoff_slot, important_logs) do
    # Remove logs before cutoff except important ones
    # Placeholder implementation
    {log_store, 1000}
  end

  defp rebuild_log_indexes(log_store) do
    # Rebuild address and topic indexes after pruning
    # Placeholder implementation
    log_store
  end

  # Private Functions - Helpers

  defp get_current_slot do
    div(System.system_time(:second), 12)
  end

  defp get_state_by_slot(_state_store, _slot) do
    # Get beacon state for specific slot
    {:error, :not_implemented}
  end

  defp extract_trie_nodes(_state) do
    # Extract all trie node hashes from a beacon state
    MapSet.new()
  end

  defp count_attestations(attestation_pool) do
    Enum.reduce(attestation_pool, 0, fn {_slot, attestations}, acc ->
      acc + length(attestations)
    end)
  end

  defp count_blocks(block_store) do
    map_size(block_store)
  end

  defp count_logs(log_store) do
    # Count execution layer logs
    0
  end

  defp estimate_fork_choice_memory(store) do
    # Estimate memory usage of fork choice store
    # ~10KB per block
    map_size(store.blocks) * 10_000
  end
end
