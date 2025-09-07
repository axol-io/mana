defmodule ExWire.Eth2.ForkChoiceOptimized do
  @moduledoc """
  Optimized Fork Choice implementation with weight caching.

  Key optimizations:
  - Weight caching: O(1) weight lookups instead of O(n) recalculation
  - Best child/descendant tracking: O(1) path finding
  - Incremental updates: Only recalculate affected branches
  - Batch attestation processing: Amortized weight updates
  """

  require Logger
  import Bitwise

  alias ExWire.Eth2.{BeaconState, BeaconBlock, Attestation, AttestationData, Checkpoint}

  defstruct [
    :justified_checkpoint,
    :finalized_checkpoint,
    :best_justified_checkpoint,
    :proposer_boost_root,
    :time,
    :genesis_time,
    blocks: %{},
    block_tree: %{},
    weight_cache: %{},
    latest_messages: %{},
    unrealized_justifications: %{},
    unrealized_finalizations: %{},
    proposer_boost_amount: 0,
    # Optimization structures
    # parent -> list of children
    children_cache: %{},
    # block -> best child
    best_child_cache: %{},
    # block -> best descendant
    best_descendant_cache: %{},
    # blocks needing weight recalc
    dirty_weights: MapSet.new(),
    # buffer for batch processing
    pending_attestations: []
  ]

  @type store :: %__MODULE__{}
  @type block_root :: binary()
  @type validator_index :: non_neg_integer()
  @type weight :: non_neg_integer()

  # Cache invalidation strategies
  @cache_invalidation_batch_size 100
  # ms
  @attestation_batch_timeout 100

  # Client API

  @doc """
  Initialize fork choice from genesis
  """
  def init(genesis_state, genesis_block_root, genesis_time) do
    %__MODULE__{
      justified_checkpoint: %Checkpoint{
        epoch: 0,
        root: genesis_block_root
      },
      finalized_checkpoint: %Checkpoint{
        epoch: 0,
        root: genesis_block_root
      },
      best_justified_checkpoint: %Checkpoint{
        epoch: 0,
        root: genesis_block_root
      },
      time: genesis_time,
      genesis_time: genesis_time,
      blocks: %{
        genesis_block_root => %{
          block: nil,
          state: genesis_state,
          parent_root: nil,
          justified_checkpoint: %Checkpoint{epoch: 0, root: genesis_block_root},
          finalized_checkpoint: %Checkpoint{epoch: 0, root: genesis_block_root},
          weight: 0,
          invalid: false
        }
      },
      weight_cache: %{genesis_block_root => 0},
      children_cache: %{genesis_block_root => []},
      best_child_cache: %{},
      best_descendant_cache: %{genesis_block_root => genesis_block_root}
    }
  end

  @doc """
  Process a new block with optimized weight updates
  """
  def on_block(store, %BeaconBlock{slot: slot} = block, block_root, %BeaconState{} = _state) do
    # Validate block timing
    current_slot = get_current_slot(store)

    if slot > current_slot do
      {:error, :future_block}
    else
      # Add block to store with caching
      store = add_block_with_caching(store, block, block_root, state)

      # Update checkpoints if better
      store = update_checkpoints(store, state)

      # Update proposer boost
      store = maybe_update_proposer_boost(store, block_root, state)

      # Process any pending attestations in batch
      store = process_pending_attestations(store)

      {:ok, store}
    end
  end

  @doc """
  Process attestation with batching for efficiency
  """
  def on_attestation(store, %Attestation{data: %AttestationData{slot: slot}} = attestation) do
    # Validate attestation slot
    current_slot = get_current_slot(store)

    # Allow attestations from the previous two epochs
    # 32 slots per epoch * 2 epochs
    oldest_valid_slot = max(0, current_slot - 64)

    if slot >= oldest_valid_slot and slot <= current_slot do
      # Add to pending buffer for batch processing
      store = %{store | pending_attestations: [attestation | store.pending_attestations]}

      # Process batch if buffer is full or timeout reached
      if length(store.pending_attestations) >= @cache_invalidation_batch_size do
        process_pending_attestations(store)
      else
        # Schedule batch processing
        maybe_schedule_batch_processing(store)
        {:ok, store}
      end
    else
      {:error, :attestation_too_old}
    end
  end

  @doc """
  Get head with O(1) lookup using caches
  """
  def get_head(store) do
    # Start from justified checkpoint
    justified_root = store.justified_checkpoint.root

    # Use best descendant cache for O(1) lookup
    head = get_best_descendant(store, justified_root)

    # Apply proposer boost if active
    if store.proposer_boost_root && is_descendant?(store, store.proposer_boost_root, head) do
      store.proposer_boost_root
    else
      head
    end
  end

  @doc """
  Get block weight with O(1) cache lookup
  """
  def get_weight(store, block_root) do
    Map.get(store.weight_cache, block_root, 0)
  end

  @doc """
  Prune old blocks to manage memory
  """
  def prune(store, finalized_root) do
    # Get all blocks to keep (descendants of finalized)
    blocks_to_keep = get_all_descendants(store, finalized_root)

    # Remove non-finalized blocks
    pruned_blocks =
      Map.filter(store.blocks, fn {root, _} ->
        MapSet.member?(blocks_to_keep, root) || root == finalized_root
      end)

    # Update caches
    pruned_weight_cache =
      Map.filter(store.weight_cache, fn {root, _} ->
        Map.has_key?(pruned_blocks, root)
      end)

    pruned_children =
      Map.filter(store.children_cache, fn {root, _} ->
        Map.has_key?(pruned_blocks, root)
      end)

    %{
      store
      | blocks: pruned_blocks,
        weight_cache: pruned_weight_cache,
        children_cache: pruned_children,
        # Will be rebuilt on demand
        best_child_cache: %{},
        # Will be rebuilt on demand
        best_descendant_cache: %{}
    }
  end

  # Private Functions - Block Management

  defp add_block_with_caching(store, block, block_root, _state) do
    parent_root = block.parent_root

    # Create block info
    block_info = %{
      block: block,
      state: state,
      parent_root: parent_root,
      justified_checkpoint: state.current_justified_checkpoint,
      finalized_checkpoint: state.finalized_checkpoint,
      weight: 0,
      invalid: false
    }

    # Update block store
    blocks = Map.put(store.blocks, block_root, block_info)

    # Update children cache
    children_cache =
      Map.update(
        store.children_cache,
        parent_root,
        [block_root],
        fn children -> [block_root | children] end
      )

    # Initialize weight cache
    weight_cache = Map.put(store.weight_cache, block_root, 0)

    # Mark parent branch as dirty (needs cache update)
    dirty_weights = mark_ancestors_dirty(store, parent_root)

    %{
      store
      | blocks: blocks,
        children_cache: children_cache,
        weight_cache: weight_cache,
        dirty_weights: dirty_weights
    }
  end

  defp mark_ancestors_dirty(store, block_root) do
    mark_ancestors_dirty(store, block_root, MapSet.new())
  end

  defp mark_ancestors_dirty(_store, nil, dirty), do: dirty

  defp mark_ancestors_dirty(store, block_root, dirty) do
    case Map.get(store.blocks, block_root) do
      nil ->
        dirty

      block_info ->
        dirty = MapSet.put(dirty, block_root)
        mark_ancestors_dirty(store, block_info.parent_root, dirty)
    end
  end

  # Private Functions - Weight Management

  defp process_pending_attestations(store) do
    if store.pending_attestations == [] do
      store
    else
      # Group attestations by target block
      attestations_by_target =
        Enum.group_by(
          store.pending_attestations,
          & &1.data.target.root
        )

      # Process each group
      store =
        Enum.reduce(attestations_by_target, store, fn {target_root, attestations}, acc ->
          process_attestation_batch(acc, target_root, attestations)
        end)

      # Clear pending buffer
      %{store | pending_attestations: []}
    end
  end

  defp process_attestation_batch(store, target_root, attestations) do
    # Calculate total weight from attestations
    total_weight =
      Enum.reduce(attestations, 0, fn attestation, acc ->
        validator_indices = get_attesting_indices(attestation, store)
        acc + length(validator_indices)
      end)

    # Update weight cache
    current_weight = Map.get(store.weight_cache, target_root, 0)
    weight_cache = Map.put(store.weight_cache, target_root, current_weight + total_weight)

    # Update latest messages for validators
    latest_messages =
      Enum.reduce(attestations, store.latest_messages, fn attestation, acc ->
        validator_indices = get_attesting_indices(attestation, store)

        Enum.reduce(validator_indices, acc, fn validator_index, messages ->
          Map.put(messages, validator_index, %{
            epoch: attestation.data.target.epoch,
            root: attestation.data.beacon_block_root
          })
        end)
      end)

    # Mark ancestors as needing cache update
    dirty_weights = mark_ancestors_dirty(store, target_root)

    store = %{
      store
      | weight_cache: weight_cache,
        latest_messages: latest_messages,
        dirty_weights: dirty_weights
    }

    # Incrementally update affected caches
    update_affected_caches(store, target_root)
  end

  defp update_affected_caches(store, starting_root) do
    # Update weights along the path to root
    store = update_ancestor_weights(store, starting_root)

    # Update best child/descendant caches
    update_best_caches(store, starting_root)
  end

  defp update_ancestor_weights(store, block_root) do
    update_ancestor_weights(store, block_root, MapSet.new())
  end

  defp update_ancestor_weights(store, nil, _visited), do: store

  defp update_ancestor_weights(store, block_root, visited) do
    if MapSet.member?(visited, block_root) do
      # Cycle detection
      store
    else
      visited = MapSet.put(visited, block_root)

      # Calculate weight from children
      children = Map.get(store.children_cache, block_root, [])

      child_weight =
        Enum.reduce(children, 0, fn child_root, acc ->
          acc + Map.get(store.weight_cache, child_root, 0)
        end)

      # Get direct attestation weight
      direct_weight = get_direct_weight(store, block_root)

      # Update total weight
      total_weight = direct_weight + child_weight
      weight_cache = Map.put(store.weight_cache, block_root, total_weight)

      # Clean dirty flag
      dirty_weights = MapSet.delete(store.dirty_weights, block_root)

      store = %{store | weight_cache: weight_cache, dirty_weights: dirty_weights}

      # Continue up the tree
      case Map.get(store.blocks, block_root) do
        nil -> store
        block_info -> update_ancestor_weights(store, block_info.parent_root, visited)
      end
    end
  end

  defp get_direct_weight(store, block_root) do
    # Count validators who voted directly for this block
    Enum.count(store.latest_messages, fn {_validator, message} ->
      message.root == block_root
    end)
  end

  # Private Functions - Best Child/Descendant Caching

  defp update_best_caches(store, block_root) do
    # Update best child for this block
    store = update_best_child(store, block_root)

    # Update best descendant
    store = update_best_descendant(store, block_root)

    # Update parent's caches
    case Map.get(store.blocks, block_root) do
      nil ->
        store

      block_info when block_info.parent_root != nil ->
        update_best_caches(store, block_info.parent_root)

      _ ->
        store
    end
  end

  defp update_best_child(store, block_root) do
    children = Map.get(store.children_cache, block_root, [])

    if children == [] do
      # No children
      %{store | best_child_cache: Map.delete(store.best_child_cache, block_root)}
    else
      # Find child with highest weight
      best_child =
        Enum.max_by(children, fn child_root ->
          Map.get(store.weight_cache, child_root, 0)
        end)

      %{store | best_child_cache: Map.put(store.best_child_cache, block_root, best_child)}
    end
  end

  defp update_best_descendant(store, block_root) do
    case Map.get(store.best_child_cache, block_root) do
      nil ->
        # No children, best descendant is self
        %{
          store
          | best_descendant_cache: Map.put(store.best_descendant_cache, block_root, block_root)
        }

      best_child ->
        # Best descendant is best descendant of best child
        best_descendant = get_best_descendant(store, best_child)

        %{
          store
          | best_descendant_cache:
              Map.put(store.best_descendant_cache, block_root, best_descendant)
        }
    end
  end

  defp get_best_descendant(store, block_root) do
    case Map.get(store.best_descendant_cache, block_root) do
      nil ->
        # Not cached, compute it
        case Map.get(store.best_child_cache, block_root) do
          # No children, self is best
          nil -> block_root
          best_child -> get_best_descendant(store, best_child)
        end

      cached ->
        cached
    end
  end

  # Private Functions - Proposer Boost

  defp maybe_update_proposer_boost(store, block_root, _state) do
    if should_update_proposer_boost?(store, block_root) do
      %{
        store
        | proposer_boost_root: block_root,
          proposer_boost_amount: calculate_proposer_boost(_state)
      }
    else
      store
    end
  end

  defp should_update_proposer_boost?(store, block_root) do
    # Update if this is the first block in the slot
    case Map.get(store.blocks, block_root) do
      nil ->
        false

      block_info ->
        current_slot = get_current_slot(store)
        block_info.block.slot == current_slot
    end
  end

  defp calculate_proposer_boost(_state) do
    # Boost is worth sqrt(total_active_balance) // 256
    total_balance = get_total_active_balance(state)
    floor(:math.sqrt(total_balance) / 256)
  end

  # Private Functions - Checkpoints

  defp update_checkpoints(store, _state) do
    store
    |> update_justified_checkpoint(state)
    |> update_finalized_checkpoint(state)
    |> update_best_justified_checkpoint(state)
  end

  defp update_justified_checkpoint(store, _state) do
    if state.current_justified_checkpoint.epoch > store.justified_checkpoint.epoch do
      %{store | justified_checkpoint: _state.current_justified_checkpoint}
    else
      store
    end
  end

  defp update_finalized_checkpoint(store, _state) do
    if state.finalized_checkpoint.epoch > store.finalized_checkpoint.epoch do
      %{store | finalized_checkpoint: state.finalized_checkpoint}
    else
      store
    end
  end

  defp update_best_justified_checkpoint(store, _state) do
    if state.current_justified_checkpoint.epoch > store.best_justified_checkpoint.epoch do
      %{store | best_justified_checkpoint: state.current_justified_checkpoint}
    else
      store
    end
  end

  # Private Functions - Utilities

  defp get_current_slot(store) do
    # 12 seconds per slot
    div(store.time - store.genesis_time, 12)
  end

  defp is_descendant?(store, descendant_root, ancestor_root) do
    is_descendant?(store, descendant_root, ancestor_root, MapSet.new())
  end

  defp is_descendant?(_store, root, root, _visited), do: true
  defp is_descendant?(_store, nil, _ancestor, _visited), do: false

  defp is_descendant?(store, descendant, ancestor, visited) do
    if MapSet.member?(visited, descendant) do
      # Cycle detection
      false
    else
      case Map.get(store.blocks, descendant) do
        nil ->
          false

        block_info ->
          visited = MapSet.put(visited, descendant)
          is_descendant?(store, block_info.parent_root, ancestor, visited)
      end
    end
  end

  defp get_all_descendants(store, root) do
    get_all_descendants(store, root, MapSet.new())
  end

  defp get_all_descendants(store, root, descendants) do
    descendants = MapSet.put(descendants, root)

    children = Map.get(store.children_cache, root, [])

    Enum.reduce(children, descendants, fn child, acc ->
      get_all_descendants(store, child, acc)
    end)
  end

  defp get_attesting_indices(attestation, store) do
    # Get committee for this attestation
    case Map.get(store.blocks, attestation.data.beacon_block_root) do
      nil ->
        []

      block_info ->
        committee =
          get_beacon_committee(
            block_info._state,
            attestation.data.slot,
            attestation.data.index
          )

        # Filter by aggregation bits
        committee
        |> Enum.with_index()
        |> Enum.filter(fn {_validator, idx} ->
          bit_set?(attestation.aggregation_bits, idx)
        end)
        |> Enum.map(&elem(&1, 0))
    end
  end

  defp get_beacon_committee(_state, _slot, _index) do
    # Placeholder - would get actual committee
    []
  end

  defp bit_set?(bits, index) do
    byte_index = div(index, 8)
    bit_index = rem(index, 8)

    case bits do
      <<_::binary-size(byte_index), byte, _::binary>> ->
        (byte &&& 1 <<< bit_index) != 0

      _ ->
        false
    end
  end

  defp get_total_active_balance(_state) do
    # Sum of all active validator balances
    Enum.reduce(state.validators, 0, fn validator, acc ->
      if is_active_validator?(validator, get_current_epoch(state)) do
        acc + validator.effective_balance
      else
        acc
      end
    end)
  end

  defp is_active_validator?(validator, epoch) do
    validator.activation_epoch <= epoch && epoch < validator.exit_epoch
  end

  defp get_current_epoch(_state) do
    div(_state.slot, 32)
  end

  defp maybe_schedule_batch_processing(store) do
    # Schedule batch processing after timeout
    Process.send_after(self(), :process_attestation_batch, @attestation_batch_timeout)
    store
  end

  # Public Functions - Cache Statistics

  @doc """
  Get cache statistics for monitoring
  """
  def get_cache_stats(store) do
    %{
      total_blocks: map_size(store.blocks),
      cached_weights: map_size(store.weight_cache),
      cached_children: map_size(store.children_cache),
      cached_best_children: map_size(store.best_child_cache),
      cached_best_descendants: map_size(store.best_descendant_cache),
      dirty_weights: MapSet.size(store.dirty_weights),
      pending_attestations: length(store.pending_attestations),
      cache_hit_rate: calculate_cache_hit_rate(store)
    }
  end

  defp calculate_cache_hit_rate(store) do
    # Track cache hits/misses in production
    # For now return a placeholder
    if map_size(store.best_descendant_cache) > 0 do
      Float.round(map_size(store.best_descendant_cache) / map_size(store.blocks) * 100, 2)
    else
      0.0
    end
  end

  @doc """
  Force cache rebuild (for testing/debugging)
  """
  def rebuild_caches(store) do
    # Mark all blocks as dirty
    all_blocks = Map.keys(store.blocks)
    dirty_weights = MapSet.new(all_blocks)

    store = %{
      store
      | dirty_weights: dirty_weights,
        best_child_cache: %{},
        best_descendant_cache: %{}
    }

    # Rebuild weight cache
    Enum.reduce(all_blocks, store, fn block_root, acc ->
      update_ancestor_weights(acc, block_root)
    end)
  end
end
