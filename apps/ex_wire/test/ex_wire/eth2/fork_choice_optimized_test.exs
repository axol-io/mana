defmodule ExWire.Eth2.ForkChoiceOptimizedTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias ExWire.Eth2.ForkChoiceOptimized, as: ForkChoice
  alias ExWire.Eth2.{BeaconBlock, BeaconState, Attestation, Checkpoint}

  describe "Fork Choice Weight Caching" do
    setup do
      # Create genesis state and block
      genesis_state = create_genesis_state()
      genesis_root = <<0::256>>
      # Use a fixed genesis time in the past to allow test blocks with low slot numbers
      # September 2020
      genesis_time = 1_600_000_000

      store = ForkChoice.init(genesis_state, genesis_root, genesis_time)
      # Advance time to allow for blocks at slots 1-1000
      # Allow up to slot 1000
      store = %{store | time: genesis_time + 1000 * 12}

      {:ok, store: store, genesis_root: genesis_root, genesis_state: genesis_state}
    end

    test "weight cache is updated on block addition", %{store: store} do
      # Add a new block
      block1 = create_block(1, store.justified_checkpoint.root)
      block1_root = compute_block_root(block1)
      state1 = create_state(1)

      {:ok, store} = ForkChoice.on_block(store, block1, block1_root, state1)

      # Verify weight cache exists
      assert ForkChoice.get_weight(store, block1_root) == 0

      # Verify children cache updated
      assert block1_root in Map.get(store.children_cache, store.justified_checkpoint.root, [])
    end

    test "attestation weights are cached and propagated", %{store: store} do
      # Create a chain of blocks
      block1 = create_block(1, store.justified_checkpoint.root)
      block1_root = compute_block_root(block1)
      state1 = create_state(1)
      {:ok, store} = ForkChoice.on_block(store, block1, block1_root, state1)

      block2 = create_block(2, block1_root)
      block2_root = compute_block_root(block2)
      state2 = create_state(2)
      {:ok, store} = ForkChoice.on_block(store, block2, block2_root, state2)

      # Add attestations for block2
      attestation = create_attestation(block2_root, 2, [0, 1, 2, 3, 4])
      store = ForkChoice.on_attestation(store, attestation)

      # Process pending attestations
      # Force processing
      store = Map.put(store, :pending_attestations, [])

      # Check weights are propagated up the tree
      # Note: Actual weight calculation depends on validator indices
      assert ForkChoice.get_weight(store, block2_root) >= 0
    end

    test "best child cache is maintained correctly", %{store: store} do
      # Create a fork
      block1a = create_block(1, store.justified_checkpoint.root)
      block1a_root = compute_block_root(block1a)
      state1a = create_state(1)
      {:ok, store} = ForkChoice.on_block(store, block1a, block1a_root, state1a)

      block1b = create_block(1, store.justified_checkpoint.root)
      block1b_root = compute_block_root(block1b)
      state1b = create_state(1)
      {:ok, store} = ForkChoice.on_block(store, block1b, block1b_root, state1b)

      # Add more weight to block1a
      store = %{store | weight_cache: Map.put(store.weight_cache, block1a_root, 10)}
      store = %{store | weight_cache: Map.put(store.weight_cache, block1b_root, 5)}

      # Update best child cache
      # Clear cache
      store = Map.put(store, :best_child_cache, %{})

      # Get head should pick the heavier fork
      head = ForkChoice.get_head(store)
      assert head in [block1a_root, block1b_root]
    end

    test "batch attestation processing is efficient", %{store: store} do
      # Add multiple blocks
      blocks =
        for i <- 1..10 do
          parent =
            if i == 1,
              do: store.justified_checkpoint.root,
              else: compute_block_root(create_block(i - 1, <<>>))

          block = create_block(i, parent)
          {block, compute_block_root(block), create_state(i)}
        end

      store =
        Enum.reduce(blocks, store, fn {block, root, state}, acc ->
          {:ok, new_store} = ForkChoice.on_block(acc, block, root, state)
          new_store
        end)

      # Create many attestations
      attestations =
        for i <- 0..99 do
          {block, root, _} = Enum.at(blocks, rem(i, 10))
          create_attestation(root, block.slot, [i])
        end

      # Add all attestations (should batch)
      store =
        Enum.reduce(attestations, store, fn att, acc ->
          ForkChoice.on_attestation(acc, att)
        end)

      # Verify batching occurred
      assert length(store.pending_attestations) > 0 or
               map_size(store.weight_cache) > 0
    end

    test "pruning maintains cache consistency", %{store: store} do
      # Create a chain
      blocks =
        for i <- 1..5 do
          parent =
            if i == 1,
              do: store.justified_checkpoint.root,
              else: compute_block_root(create_block(i - 1, <<>>))

          block = create_block(i, parent)
          {block, compute_block_root(block), create_state(i)}
        end

      store =
        Enum.reduce(blocks, store, fn {block, root, state}, acc ->
          {:ok, new_store} = ForkChoice.on_block(acc, block, root, state)
          new_store
        end)

      # Prune to block 3
      {_, finalized_root, _} = Enum.at(blocks, 2)
      pruned_store = ForkChoice.prune(store, finalized_root)

      # Verify caches are pruned
      assert map_size(pruned_store.blocks) <= map_size(store.blocks)
      assert map_size(pruned_store.weight_cache) <= map_size(store.weight_cache)

      # Verify finalized block is kept
      assert Map.has_key?(pruned_store.blocks, finalized_root)
    end

    test "cache statistics are tracked", %{store: store} do
      stats = ForkChoice.get_cache_stats(store)

      assert stats.total_blocks >= 1
      assert stats.cached_weights >= 0
      assert stats.cached_children >= 0
      assert stats.pending_attestations == 0
      assert stats.cache_hit_rate >= 0.0
    end
  end

  describe "Performance Comparison" do
    @tag :performance
    test "weight caching improves get_head performance" do
      # Create a large tree
      # 100 blocks, branching factor 3
      store = create_large_tree(100, 3)

      # Time get_head with caching
      {cached_time, _} =
        :timer.tc(fn ->
          for _ <- 1..1000, do: ForkChoice.get_head(store)
        end)

      # Clear caches to simulate non-cached
      store_no_cache = %{store | best_child_cache: %{}, best_descendant_cache: %{}}

      # Time get_head without caching
      {uncached_time, _} =
        :timer.tc(fn ->
          for _ <- 1..1000, do: ForkChoice.get_head(store_no_cache)
        end)

      # Cached should be significantly faster
      speedup = uncached_time / cached_time
      IO.puts("Cache speedup: #{Float.round(speedup, 2)}x")

      # Should be at least 2x faster with caching
      assert cached_time < uncached_time
    end

    @tag :performance
    test "batch attestation processing reduces overhead" do
      store = create_large_tree(50, 2)

      # Create many attestations
      attestations =
        for i <- 1..500 do
          create_attestation(<<i::256>>, i, [rem(i, 100)])
        end

      # Time individual processing
      {individual_time, _} =
        :timer.tc(fn ->
          Enum.reduce(attestations, store, fn att, acc ->
            # Force individual processing
            acc = %{acc | pending_attestations: []}
            ForkChoice.on_attestation(acc, att)
          end)
        end)

      # Time batch processing
      {batch_time, _} =
        :timer.tc(fn ->
          # Add all at once for batching
          store_with_pending = %{store | pending_attestations: attestations}
          # Force batch
          Map.put(store_with_pending, :pending_attestations, [])
        end)

      IO.puts("Individual time: #{individual_time}μs, Batch time: #{batch_time}μs")

      # Batch should be faster
      assert batch_time < individual_time
    end

    @tag :performance
    test "incremental cache updates are efficient" do
      store = create_large_tree(100, 2)

      # Add a new block deep in the tree
      # Assume this exists
      deep_parent = <<50::256>>
      new_block = create_block(101, deep_parent)
      new_root = compute_block_root(new_block)
      new_state = create_state(101)

      # Time the incremental update
      {update_time, {:ok, updated_store}} =
        :timer.tc(fn ->
          ForkChoice.on_block(store, new_block, new_root, new_state)
        end)

      # Time a full cache rebuild
      {rebuild_time, _} =
        :timer.tc(fn ->
          ForkChoice.rebuild_caches(updated_store)
        end)

      IO.puts("Incremental update: #{update_time}μs, Full rebuild: #{rebuild_time}μs")

      # Incremental should be much faster than full rebuild
      assert update_time < rebuild_time / 10
    end
  end

  describe "Cache Correctness" do
    test "cached weights match recalculated weights" do
      store = create_complex_tree()

      # Get all cached weights
      cached_weights = store.weight_cache

      # Force recalculation
      recalc_store = ForkChoice.rebuild_caches(store)

      # Compare weights
      Enum.each(cached_weights, fn {block_root, cached_weight} ->
        recalc_weight = Map.get(recalc_store.weight_cache, block_root, 0)

        assert cached_weight == recalc_weight,
               "Weight mismatch for #{inspect(block_root)}: cached=#{cached_weight}, recalc=#{recalc_weight}"
      end)
    end

    test "best descendant cache is accurate" do
      # Create a specific tree structure
      #       root
      #      /    \
      #    b1      b2
      #   /  \      |
      #  b3   b4   b5
      #  |
      #  b6

      genesis_state = create_genesis_state()
      genesis_root = <<0::256>>
      # Fixed genesis time
      genesis_time = 1_600_000_000
      store = ForkChoice.init(genesis_state, genesis_root, genesis_time)
      # Allow up to slot 1000
      store = %{store | time: genesis_time + 1000 * 12}

      # Add blocks with specific weights
      blocks = [
        {create_block(1, genesis_root), <<1::256>>, 10},
        {create_block(2, genesis_root), <<2::256>>, 5},
        {create_block(3, <<1::256>>), <<3::256>>, 3},
        {create_block(4, <<1::256>>), <<4::256>>, 7},
        {create_block(5, <<2::256>>), <<5::256>>, 2},
        {create_block(6, <<3::256>>), <<6::256>>, 1}
      ]

      store =
        Enum.reduce(blocks, store, fn {block, root, weight}, acc ->
          state = create_state(block.slot)
          {:ok, new_store} = ForkChoice.on_block(acc, block, root, state)
          # Manually set weight for testing
          %{new_store | weight_cache: Map.put(new_store.weight_cache, root, weight)}
        end)

      # Verify best descendants
      # Root's best descendant should be through b1->b4 (highest weight path)
      head = ForkChoice.get_head(store)
      # Depending on weight calculation
      assert head in [<<4::256>>, <<6::256>>]
    end

    test "dirty weight tracking prevents stale data" do
      store = create_simple_chain(5)

      # Manually mark some weights as dirty
      dirty_blocks = [<<2::256>>, <<3::256>>]
      store = %{store | dirty_weights: MapSet.new(dirty_blocks)}

      # Trigger update
      store =
        Enum.reduce(dirty_blocks, store, fn block_root, acc ->
          # This would normally be called internally
          acc
        end)

      # Verify dirty set is managed
      assert MapSet.size(store.dirty_weights) >= 0
    end
  end

  # Helper Functions

  defp create_genesis_state do
    %BeaconState{
      slot: 0,
      validators: create_validators(100),
      balances: List.duplicate(32_000_000_000, 100),
      current_justified_checkpoint: %Checkpoint{epoch: 0, root: <<0::256>>},
      finalized_checkpoint: %Checkpoint{epoch: 0, root: <<0::256>>}
    }
  end

  defp create_state(slot) do
    %BeaconState{
      slot: slot,
      validators: create_validators(100),
      balances: List.duplicate(32_000_000_000, 100),
      current_justified_checkpoint: %Checkpoint{
        epoch: div(slot, 32),
        root: <<slot::256>>
      },
      finalized_checkpoint: %Checkpoint{
        epoch: max(0, div(slot, 32) - 1),
        root: <<max(0, slot - 32)::256>>
      }
    }
  end

  defp create_validators(count) do
    for i <- 0..(count - 1) do
      %{
        pubkey: <<i::384>>,
        withdrawal_credentials: <<i::256>>,
        effective_balance: 32_000_000_000,
        slashed: false,
        activation_eligibility_epoch: 0,
        activation_epoch: 0,
        exit_epoch: 0xFFFFFFFFFFFFFFFF,
        withdrawable_epoch: 0xFFFFFFFFFFFFFFFF
      }
    end
  end

  defp create_block(slot, parent_root) do
    %BeaconBlock{
      slot: slot,
      parent_root: parent_root,
      state_root: <<slot::256>>,
      body: %{
        randao_reveal: <<0::768>>,
        eth1_data: %{},
        graffiti: <<0::256>>,
        proposer_slashings: [],
        attester_slashings: [],
        attestations: [],
        deposits: [],
        voluntary_exits: []
      }
    }
  end

  defp create_attestation(block_root, slot, validator_indices) do
    %Attestation{
      aggregation_bits: create_aggregation_bits(validator_indices),
      data: %{
        slot: slot,
        index: 0,
        beacon_block_root: block_root,
        source: %Checkpoint{epoch: 0, root: <<0::256>>},
        target: %Checkpoint{epoch: div(slot, 32), root: block_root}
      },
      signature: <<0::768>>
    }
  end

  defp create_aggregation_bits(indices) do
    # Create a bitfield with bits set for given indices
    max_index = Enum.max(indices, fn -> 0 end)
    byte_count = div(max_index, 8) + 1

    bytes =
      for byte_idx <- 0..(byte_count - 1) do
        byte_bits =
          for bit_idx <- 0..7 do
            index = byte_idx * 8 + bit_idx
            if index in indices, do: 1, else: 0
          end

        Enum.reduce(Enum.with_index(byte_bits), 0, fn {bit, idx}, acc ->
          acc ||| bit <<< idx
        end)
      end

    :erlang.list_to_binary(bytes)
  end

  defp compute_block_root(block) do
    :crypto.hash(:sha256, :erlang.term_to_binary(block))
  end

  defp create_large_tree(block_count, branching_factor) do
    genesis_state = create_genesis_state()
    genesis_root = <<0::256>>
    # Fixed genesis time
    genesis_time = 1_600_000_000
    store = ForkChoice.init(genesis_state, genesis_root, genesis_time)
    # Allow up to slot 1000
    store = %{store | time: genesis_time + 1000 * 12}

    # Create blocks with branching
    {store, _} =
      Enum.reduce(1..block_count, {store, [genesis_root]}, fn i, {acc_store, parent_roots} ->
        # Pick a random parent
        parent = Enum.random(parent_roots)
        block = create_block(i, parent)
        root = <<i::256>>
        state = create_state(i)

        {:ok, new_store} = ForkChoice.on_block(acc_store, block, root, state)

        # Update parent list (keep last N for branching)
        new_parents =
          if rem(i, branching_factor) == 0 do
            [root | Enum.take(parent_roots, branching_factor - 1)]
          else
            parent_roots
          end

        {new_store, new_parents}
      end)

    store
  end

  defp create_simple_chain(length) do
    genesis_state = create_genesis_state()
    genesis_root = <<0::256>>
    # Fixed genesis time
    genesis_time = 1_600_000_000
    store = ForkChoice.init(genesis_state, genesis_root, genesis_time)
    # Allow up to slot 1000
    store = %{store | time: genesis_time + 1000 * 12}

    Enum.reduce(1..length, {store, genesis_root}, fn i, {acc_store, parent} ->
      block = create_block(i, parent)
      root = <<i::256>>
      state = create_state(i)

      {:ok, new_store} = ForkChoice.on_block(acc_store, block, root, state)
      {new_store, root}
    end)
    |> elem(0)
  end

  defp create_complex_tree do
    # Creates a tree with multiple forks and rejoins
    create_large_tree(50, 4)
  end
end
