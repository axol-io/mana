defmodule ExWire.Eth2.TestDataGenerator do
  @moduledoc """
  Generates large-scale test data for pruning strategy validation.

  Creates realistic datasets that mirror production Ethereum 2.0 environments:
  - Mainnet-scale block trees with realistic fork patterns
  - Large attestation pools with proper committee distributions
  - Historical state chains with validator set evolution
  - Execution layer logs with realistic event patterns

  Supports different network profiles (mainnet, testnet, stress-test).
  """

  require Logger

  alias ExWire.Eth2.BeaconState

  @type network_profile :: :mainnet | :testnet | :stress_test | :archive_node
  @type data_scale :: :small | :medium | :large | :massive

  # Network-specific parameters
  @network_params %{
    mainnet: %{
      validators_count: 900_000,
      avg_attestations_per_slot: 128,
      fork_probability: 0.05,
      reorg_depth_max: 7,
      epochs_per_day: 225
    },
    testnet: %{
      validators_count: 100_000,
      avg_attestations_per_slot: 64,
      fork_probability: 0.08,
      reorg_depth_max: 5,
      epochs_per_day: 225
    },
    stress_test: %{
      validators_count: 1_500_000,
      avg_attestations_per_slot: 256,
      fork_probability: 0.15,
      reorg_depth_max: 12,
      epochs_per_day: 225
    }
  }

  # Data scale configurations
  @scale_params %{
    small: %{hours: 2, fork_choice_blocks: 1_000, states: 500},
    medium: %{hours: 24, fork_choice_blocks: 10_000, states: 5_000},
    # 1 week
    large: %{hours: 168, fork_choice_blocks: 100_000, states: 50_000},
    # 1 month
    massive: %{hours: 720, fork_choice_blocks: 500_000, states: 200_000}
  }

  @doc """
  Generate comprehensive test dataset for specified network and scale
  """
  def generate_dataset(network_profile, data_scale, opts \\ []) do
    Logger.info("Generating #{data_scale} dataset for #{network_profile} network")

    network_params = Map.get(@network_params, network_profile)
    scale_params = Map.get(@scale_params, data_scale)

    start_time = System.monotonic_time(:millisecond)

    dataset = %{
      network_profile: network_profile,
      data_scale: data_scale,
      generation_started: DateTime.utc_now(),

      # Core blockchain data
      fork_choice_store: generate_fork_choice_data(network_params, scale_params, opts),
      beacon_states: generate_beacon_states(network_params, scale_params, opts),
      attestation_pools: generate_attestation_pools(network_params, scale_params, opts),
      block_storage: generate_block_storage(network_params, scale_params, opts),
      execution_logs: generate_execution_logs(network_params, scale_params, opts),

      # Metadata
      generation_stats: %{
        generation_time_ms: System.monotonic_time(:millisecond) - start_time,
        total_memory_mb: :erlang.memory(:total) / (1024 * 1024),
        estimated_disk_usage_gb: estimate_dataset_size(scale_params)
      }
    }

    Logger.info("Generated dataset in #{dataset.generation_stats.generation_time_ms}ms")
    dataset
  end

  @doc """
  Generate realistic fork choice store with multiple forks and reorgs
  """
  def generate_fork_choice_data(network_params, scale_params, _opts) do
    Logger.debug("Generating fork choice data with #{scale_params.fork_choice_blocks} blocks")

    total_blocks = scale_params.fork_choice_blocks
    fork_probability = network_params.fork_probability
    max_reorg_depth = network_params.reorg_depth_max

    # Start with genesis block
    genesis_root = generate_block_root()
    genesis_block = create_test_block(0, genesis_root, <<0::256>>)

    blocks = %{genesis_root => genesis_block}
    block_heights = %{0 => [genesis_root]}

    # Generate main chain with forks
    {blocks, block_heights} =
      generate_block_tree(
        blocks,
        block_heights,
        1,
        total_blocks,
        fork_probability,
        max_reorg_depth
      )

    # Create fork choice caches
    weight_cache = generate_weight_cache(blocks)
    children_cache = generate_children_cache(blocks)
    latest_messages = generate_latest_messages(blocks, network_params.validators_count)

    %{
      blocks: blocks,
      weight_cache: weight_cache,
      children_cache: children_cache,
      best_child_cache: %{},
      best_descendant_cache: %{},
      latest_messages: latest_messages,
      finalized_checkpoint: %{
        # Finalize blocks 1000 behind head
        epoch: div(total_blocks - 1000, 32),
        root: find_finalized_block_root(blocks, total_blocks - 1000)
      }
    }
  end

  @doc """
  Generate historical beacon states with realistic validator evolution
  """
  def generate_beacon_states(network_params, scale_params, _opts) do
    Logger.debug("Generating #{scale_params.states} beacon states")

    total_states = scale_params.states
    validators_count = network_params.validators_count

    states =
      for slot <- 0..(total_states - 1), into: %{} do
        state = create_test_beacon_state(slot, validators_count)
        {slot, state}
      end

    # Create state root index
    state_roots =
      for {slot, state} <- states, into: %{} do
        root = compute_state_root(state)
        {root, slot}
      end

    %{
      states: states,
      state_roots: state_roots,
      hot_states: Map.take(states, Enum.to_list((total_states - 64)..(total_states - 1))),
      warm_states: Map.take(states, Enum.to_list((total_states - 2048)..(total_states - 65))),
      cold_states: Map.take(states, Enum.to_list(0..(total_states - 2049)))
    }
  end

  @doc """
  Generate large attestation pools with realistic patterns
  """
  def generate_attestation_pools(network_params, scale_params, _opts) do
    Logger.debug("Generating attestation pools")

    # 12 second slots
    slots = div(scale_params.hours * 3600, 12)
    avg_attestations = network_params.avg_attestations_per_slot
    validators_count = network_params.validators_count

    pools =
      for slot <- 0..(slots - 1), into: %{} do
        attestation_count =
          :rand.normal(avg_attestations, avg_attestations * 0.2) |> round() |> max(1)

        attestations = generate_slot_attestations(slot, attestation_count, validators_count)
        {slot, attestations}
      end

    # Add some aged attestations that should be pruned
    aged_pools = add_aged_attestations(pools, slots)

    %{
      attestation_pool: aged_pools,
      total_attestations: count_total_attestations(aged_pools),
      slots_covered: slots,
      avg_per_slot: avg_attestations
    }
  end

  @doc """
  Generate realistic block storage with different retention tiers
  """
  def generate_block_storage(network_params, scale_params, _opts) do
    Logger.debug("Generating block storage data")

    total_blocks = scale_params.fork_choice_blocks

    # Generate blocks with realistic sizes
    blocks =
      for slot <- 0..(total_blocks - 1), into: %{} do
        block = create_full_block_with_body(slot)
        {slot, block}
      end

    # Separate into tiers based on age
    recent_blocks = Map.take(blocks, Enum.to_list((total_blocks - 256)..(total_blocks - 1)))

    intermediate_blocks =
      Map.take(blocks, Enum.to_list((total_blocks - 2048)..(total_blocks - 257)))

    ancient_blocks = Map.take(blocks, Enum.to_list(0..(total_blocks - 2049)))

    %{
      blocks: blocks,
      recent_blocks: recent_blocks,
      intermediate_blocks: intermediate_blocks,
      ancient_blocks: ancient_blocks,
      total_size_mb: estimate_blocks_size_mb(blocks)
    }
  end

  @doc """
  Generate execution layer logs with realistic event patterns
  """
  def generate_execution_logs(_network_params, scale_params, _opts) do
    Logger.debug("Generating execution logs")

    slots = div(scale_params.hours * 3600, 12)

    logs =
      for slot <- 0..slots, into: %{} do
        logs_in_slot = generate_execution_logs_for_slot(slot)
        {slot, logs_in_slot}
      end

    # Categorize logs by importance
    {important_logs, regular_logs} = categorize_logs(logs)

    %{
      logs: logs,
      important_logs: important_logs,
      regular_logs: regular_logs,
      total_logs: count_total_logs(logs),
      estimated_size_mb: estimate_logs_size_mb(logs)
    }
  end

  # Private Functions - Block Generation

  defp generate_block_tree(blocks, heights, current_slot, max_slots, fork_prob, max_reorg_depth)
       when current_slot >= max_slots do
    {blocks, heights}
  end

  defp generate_block_tree(blocks, heights, current_slot, max_slots, fork_prob, max_reorg_depth) do
    # Determine if this slot creates a fork
    create_fork = :rand.uniform() < fork_prob and current_slot > 10

    if create_fork do
      # Create fork by building on older block
      fork_depth = :rand.uniform(max_reorg_depth)
      fork_slot = max(0, current_slot - fork_depth)
      parent_candidates = Map.get(heights, fork_slot, [])

      if parent_candidates != [] do
        parent_root = Enum.random(parent_candidates)
        {new_blocks, new_heights} = create_fork_block(blocks, heights, current_slot, parent_root)

        generate_block_tree(
          new_blocks,
          new_heights,
          current_slot + 1,
          max_slots,
          fork_prob,
          max_reorg_depth
        )
      else
        # Fallback to normal block
        {new_blocks, new_heights} = create_normal_block(blocks, heights, current_slot)

        generate_block_tree(
          new_blocks,
          new_heights,
          current_slot + 1,
          max_slots,
          fork_prob,
          max_reorg_depth
        )
      end
    else
      # Create normal block extending canonical chain
      {new_blocks, new_heights} = create_normal_block(blocks, heights, current_slot)

      generate_block_tree(
        new_blocks,
        new_heights,
        current_slot + 1,
        max_slots,
        fork_prob,
        max_reorg_depth
      )
    end
  end

  defp create_normal_block(blocks, heights, slot) do
    # Find canonical head (highest slot)
    parent_slot = slot - 1
    parent_candidates = Map.get(heights, parent_slot, [])

    parent_root =
      if parent_candidates != [] do
        # In real scenario, this would be the head of canonical chain
        hd(parent_candidates)
      else
        # Fallback to any recent block
        find_recent_block_root(blocks, slot)
      end

    block_root = generate_block_root()
    block = create_test_block(slot, block_root, parent_root)

    new_blocks = Map.put(blocks, block_root, block)
    new_heights = Map.update(heights, slot, [block_root], &[block_root | &1])

    {new_blocks, new_heights}
  end

  defp create_fork_block(blocks, heights, slot, parent_root) do
    block_root = generate_block_root()
    block = create_test_block(slot, block_root, parent_root)

    new_blocks = Map.put(blocks, block_root, block)
    new_heights = Map.update(heights, slot, [block_root], &[block_root | &1])

    {new_blocks, new_heights}
  end

  defp create_test_block(slot, root, parent_root) do
    %{
      block: %{
        slot: slot,
        parent_root: parent_root,
        state_root: generate_state_root(),
        body_root: generate_body_root(),
        proposer_index: :rand.uniform(900_000) - 1
      },
      root: root,
      weight: calculate_block_weight(slot),
      invalid: false
    }
  end

  defp create_full_block_with_body(slot) do
    %{
      header: %{
        slot: slot,
        parent_root: generate_block_root(),
        state_root: generate_state_root(),
        body_root: generate_body_root()
      },
      body: %{
        randao_reveal: generate_signature(),
        graffiti: generate_graffiti(),
        proposer_slashings: [],
        attester_slashings: [],
        attestations: generate_slot_attestations(slot, 64, 100_000),
        deposits: generate_deposits(slot),
        voluntary_exits: [],
        execution_payload: generate_execution_payload(slot)
      },
      # 100KB - 600KB blocks
      size_bytes: :rand.uniform(500_000) + 100_000
    }
  end

  # Private Functions - State Generation

  defp create_test_beacon_state(slot, validators_count) do
    epoch = div(slot, 32)

    %BeaconState{
      slot: slot,
      # Mainnet genesis
      genesis_time: 1_606_824_000,
      genesis_validators_root: generate_root(),
      fork: %{
        previous_version: <<0, 0, 0, 0>>,
        current_version: <<1, 0, 0, 0>>,
        epoch: epoch
      },
      latest_block_header: %{
        slot: slot,
        parent_root: generate_block_root(),
        state_root: generate_state_root(),
        body_root: generate_body_root()
      },
      block_roots: generate_block_roots_history(slot),
      state_roots: generate_state_roots_history(slot),
      validators: generate_validator_registry(validators_count, epoch),
      balances: generate_validator_balances(validators_count),
      randao_mixes: generate_randao_mixes(epoch),
      slashings: List.duplicate(0, 8192),
      previous_epoch_participation: generate_participation_bits(validators_count),
      current_epoch_participation: generate_participation_bits(validators_count),
      justification_bits: <<0b00001111>>,
      previous_justified_checkpoint: %{epoch: epoch - 2, root: generate_root()},
      current_justified_checkpoint: %{epoch: epoch - 1, root: generate_root()},
      finalized_checkpoint: %{epoch: epoch - 3, root: generate_root()}
    }
  end

  defp generate_validator_registry(count, epoch) do
    for i <- 0..(count - 1) do
      activation_epoch = max(0, epoch - :rand.uniform(1000))

      %{
        pubkey: generate_pubkey(),
        withdrawal_credentials: generate_withdrawal_credentials(),
        # 32 ETH in Gwei
        effective_balance: 32_000_000_000,
        slashed: false,
        activation_eligibility_epoch: activation_epoch - 1,
        activation_epoch: activation_epoch,
        # FAR_FUTURE_EPOCH
        exit_epoch: 18_446_744_073_709_551_615,
        withdrawable_epoch: 18_446_744_073_709_551_615
      }
    end
  end

  defp generate_validator_balances(count) do
    for _i <- 0..(count - 1) do
      # Realistic balance distribution around 32 ETH
      base_balance = 32_000_000_000
      # +/- 1 ETH
      variation = :rand.uniform(2_000_000_000) - 1_000_000_000
      base_balance + variation
    end
  end

  # Private Functions - Attestation Generation

  defp generate_slot_attestations(slot, count, validators_count) do
    for _i <- 1..count do
      create_test_attestation(slot, validators_count)
    end
  end

  defp create_test_attestation(slot, validators_count) do
    # Realistic committee size
    committee_size = min(128, div(validators_count, 64))
    aggregation_bits = generate_aggregation_bits(committee_size)

    %{
      aggregation_bits: aggregation_bits,
      data: %{
        slot: slot,
        # Committee index
        index: :rand.uniform(64) - 1,
        beacon_block_root: generate_block_root(),
        source: %{epoch: div(slot, 32) - 1, root: generate_root()},
        target: %{epoch: div(slot, 32), root: generate_root()}
      },
      signature: generate_signature()
    }
  end

  defp generate_epoch_attestations(epoch, validators_count) do
    # Realistic attestation count
    attestations_per_epoch = div(validators_count, 32)

    # Cap for memory
    for i <- 1..min(attestations_per_epoch, 1000) do
      slot = epoch * 32 + rem(i, 32)
      create_test_attestation(slot, validators_count)
    end
  end

  defp add_aged_attestations(pools, current_slots) do
    # Add old attestations that should be pruned (older than 2 epochs)
    aged_attestations =
      for slot <- 0..63, into: %{} do
        # Very old
        old_slot = current_slots - 100 - slot

        if old_slot >= 0 do
          attestations = generate_slot_attestations(old_slot, 10, 100_000)
          {old_slot, attestations}
        else
          {old_slot, []}
        end
      end

    Map.merge(aged_attestations, pools)
  end

  # Private Functions - Execution Logs

  defp generate_execution_logs_for_slot(slot) do
    # Generate 10-50 logs per slot with realistic patterns
    log_count = :rand.uniform(40) + 10

    for i <- 1..log_count do
      create_execution_log(slot, i)
    end
  end

  defp create_execution_log(slot, log_index) do
    event_types = [:deposit, :withdrawal, :transfer, :contract_call, :other]
    event_type = Enum.random(event_types)

    %{
      slot: slot,
      log_index: log_index,
      address: generate_address(),
      topics: generate_log_topics(event_type),
      data: generate_log_data(event_type),
      event_type: event_type,
      size_bytes: :rand.uniform(500) + 100
    }
  end

  defp categorize_logs(logs) do
    all_logs = Enum.flat_map(logs, fn {_slot, slot_logs} -> slot_logs end)

    important_logs =
      Enum.filter(all_logs, fn log ->
        log.event_type in [:deposit, :withdrawal]
      end)

    regular_logs =
      Enum.filter(all_logs, fn log ->
        log.event_type not in [:deposit, :withdrawal]
      end)

    {important_logs, regular_logs}
  end

  # Private Functions - Helpers and Generators

  defp generate_weight_cache(blocks) do
    for {root, block_info} <- blocks, into: %{} do
      weight = calculate_block_weight(block_info.block.slot)
      {root, weight}
    end
  end

  defp generate_children_cache(blocks) do
    children =
      for {root, block_info} <- blocks, reduce: %{} do
        acc ->
          parent_root = block_info.block.parent_root
          Map.update(acc, parent_root, [root], &[root | &1])
      end

    # Remove genesis parent (all zeros)
    Map.delete(children, <<0::256>>)
  end

  defp generate_latest_messages(blocks, validators_count) do
    # Simulate validator latest votes - sample subset for memory efficiency
    sample_size = min(validators_count, 10_000)

    for validator_index <- 0..(sample_size - 1), into: %{} do
      # Pick random recent block as latest message
      block_roots = Map.keys(blocks)
      random_root = Enum.random(block_roots)

      message = %{
        epoch: :rand.uniform(100),
        root: random_root
      }

      {validator_index, message}
    end
  end

  defp find_finalized_block_root(blocks, target_slot) do
    # Find block closest to target slot
    blocks
    |> Enum.filter(fn {_root, info} -> info.block.slot <= target_slot end)
    |> Enum.max_by(fn {_root, info} -> info.block.slot end, fn -> {generate_block_root(), nil} end)
    |> elem(0)
  end

  defp find_recent_block_root(blocks, current_slot) do
    # Find most recent block before current slot
    recent_blocks =
      blocks
      |> Enum.filter(fn {_root, info} -> info.block.slot < current_slot end)

    if recent_blocks == [] do
      generate_block_root()
    else
      recent_blocks
      |> Enum.max_by(fn {_root, info} -> info.block.slot end)
      |> elem(0)
    end
  end

  defp calculate_block_weight(slot) do
    # Simulate weight based on attestations (simplified)
    base_weight = 100_000
    slot_bonus = slot * 100
    random_attestations = :rand.uniform(200) * 1000
    base_weight + slot_bonus + random_attestations
  end

  # Data generation helpers
  defp generate_block_root, do: :crypto.strong_rand_bytes(32)
  defp generate_state_root, do: :crypto.strong_rand_bytes(32)
  defp generate_body_root, do: :crypto.strong_rand_bytes(32)
  defp generate_root, do: :crypto.strong_rand_bytes(32)
  defp generate_pubkey, do: :crypto.strong_rand_bytes(48)
  defp generate_signature, do: :crypto.strong_rand_bytes(96)
  defp generate_address, do: :crypto.strong_rand_bytes(20)

  defp generate_withdrawal_credentials do
    # ETH1 withdrawal credentials (0x01 prefix)
    <<0x01, 0::88, :crypto.strong_rand_bytes(20)::binary>>
  end

  defp generate_aggregation_bits(size) do
    # Generate realistic aggregation pattern (70-90% participation)
    participation_rate = 0.7 + :rand.uniform() * 0.2
    participating = round(size * participation_rate)

    bits = List.duplicate(0, size)
    indices = Enum.take_random(0..(size - 1), participating)

    Enum.reduce(indices, bits, fn index, acc ->
      List.replace_at(acc, index, 1)
    end)
    |> Enum.join("")
  end

  defp generate_block_roots_history(slot) do
    # Generate 8192 historical block roots
    for i <- 0..8191 do
      if slot > i do
        generate_block_root()
      else
        <<0::256>>
      end
    end
  end

  defp generate_state_roots_history(slot) do
    # Generate 8192 historical state roots  
    for i <- 0..8191 do
      if slot > i do
        generate_state_root()
      else
        <<0::256>>
      end
    end
  end

  defp generate_randao_mixes(epoch) do
    # Generate 65536 randao mixes
    for i <- 0..65535 do
      if epoch > i do
        :crypto.strong_rand_bytes(32)
      else
        <<0::256>>
      end
    end
  end

  defp generate_deposits(slot) do
    # Occasional deposits (every ~100 slots on average)
    if rem(slot, 100) < 3 do
      [
        %{
          proof: List.duplicate(:crypto.strong_rand_bytes(32), 33),
          data: %{
            pubkey: generate_pubkey(),
            withdrawal_credentials: generate_withdrawal_credentials(),
            # 32 ETH
            amount: 32_000_000_000,
            signature: generate_signature()
          }
        }
      ]
    else
      []
    end
  end

  defp generate_execution_payload(slot) do
    %{
      parent_hash: :crypto.strong_rand_bytes(32),
      fee_recipient: generate_address(),
      state_root: :crypto.strong_rand_bytes(32),
      receipts_root: :crypto.strong_rand_bytes(32),
      logs_bloom: :crypto.strong_rand_bytes(256),
      prev_randao: :crypto.strong_rand_bytes(32),
      block_number: slot,
      gas_limit: 30_000_000,
      gas_used: :rand.uniform(25_000_000),
      timestamp: 1_606_824_000 + slot * 12,
      extra_data: :crypto.strong_rand_bytes(:rand.uniform(32)),
      # 0-100 Gwei
      base_fee_per_gas: :rand.uniform(100) * 1_000_000_000,
      block_hash: :crypto.strong_rand_bytes(32),
      transactions: generate_transactions(slot)
    }
  end

  defp generate_transactions(slot) do
    # 50-200 transactions per block
    tx_count = :rand.uniform(150) + 50

    for _i <- 1..tx_count do
      # Variable size transactions
      :crypto.strong_rand_bytes(:rand.uniform(1000) + 100)
    end
  end

  defp generate_graffiti do
    messages = [
      "Mana Ethereum Client",
      "Pruning Test Data",
      "Large Scale Test",
      "Performance Validation",
      "Storage Optimization"
    ]

    message = Enum.random(messages)
    padded = String.pad_trailing(message, 32, <<0>>)
    :binary.part(padded, 0, 32)
  end

  defp generate_log_topics(:deposit) do
    # Deposit event signature + indexed parameters
    [
      # DepositEvent(bytes pubkey, bytes withdrawal_credentials, bytes amount, bytes signature, bytes index)
      :crypto.hash(:sha256, "DepositEvent"),
      # indexed pubkey hash
      :crypto.strong_rand_bytes(32),
      # indexed index
      :crypto.strong_rand_bytes(32)
    ]
  end

  defp generate_log_topics(:withdrawal) do
    [
      :crypto.hash(:sha256, "WithdrawalEvent"),
      # validator index
      :crypto.strong_rand_bytes(32),
      # amount
      :crypto.strong_rand_bytes(32)
    ]
  end

  defp generate_log_topics(_event_type) do
    # Generic event with 1-3 topics
    topic_count = :rand.uniform(3)

    for _i <- 1..topic_count do
      :crypto.strong_rand_bytes(32)
    end
  end

  defp generate_log_data(:deposit) do
    # Non-indexed deposit data
    pubkey_data = generate_pubkey()
    withdrawal_cred_data = generate_withdrawal_credentials()
    # 32 ETH in Gwei
    amount_data = <<32_000_000_000::256>>
    signature_data = generate_signature()

    pubkey_data <> withdrawal_cred_data <> amount_data <> signature_data
  end

  defp generate_log_data(_event_type) do
    # Random data 100-500 bytes
    size = :rand.uniform(400) + 100
    :crypto.strong_rand_bytes(size)
  end

  # Utility functions
  defp compute_state_root(_state) do
    # Simplified state root computation
    :crypto.hash(:sha256, :erlang.term_to_binary(state))
  end

  defp count_total_attestations(pools) do
    Enum.reduce(pools, 0, fn {_slot, attestations}, acc ->
      acc + length(attestations)
    end)
  end

  defp count_total_logs(logs) do
    Enum.reduce(logs, 0, fn {_slot, slot_logs}, acc ->
      acc + length(slot_logs)
    end)
  end

  defp estimate_dataset_size(scale_params) do
    # Rough estimation in GB
    hours = scale_params.hours
    # Convert to thousands
    blocks = scale_params.fork_choice_blocks / 1000
    states = scale_params.states / 1000

    # Mainnet-based estimation
    # ~500KB per block
    block_data_gb = blocks * 0.5
    # ~50MB per state
    state_data_gb = states * 50
    # ~100MB per hour
    attestation_data_gb = hours * 0.1
    # ~200MB per hour
    log_data_gb = hours * 0.2

    block_data_gb + state_data_gb + attestation_data_gb + log_data_gb
  end

  defp estimate_blocks_size_mb(blocks) do
    total_bytes =
      Enum.reduce(blocks, 0, fn {_slot, block}, acc ->
        # Default 300KB
        acc + Map.get(block, :size_bytes, 300_000)
      end)

    total_bytes / (1024 * 1024)
  end

  defp estimate_logs_size_mb(logs) do
    total_bytes =
      logs
      |> Enum.flat_map(fn {_slot, slot_logs} -> slot_logs end)
      |> Enum.reduce(0, fn log, acc -> acc + log.size_bytes end)

    total_bytes / (1024 * 1024)
  end

  defp generate_participation_bits(validators_count) do
    # Generate participation bitlist for Altair format
    # Each validator gets a participation byte (7 flag bits)
    for _validator <- 1..validators_count do
      # Random participation pattern with ~75% participation
      if :rand.uniform(100) <= 75 do
        # Participated - set appropriate flags
        # 0b01110011 = timely source, target, head, sync committee
        <<0b01110011>>
      else
        # Did not participate
        <<0b00000000>>
      end
    end
    |> Enum.join()
  end
end
