defmodule ExWire.LoadTest.Scenarios.MainnetSimulation do
  @moduledoc """
  Simulates realistic Ethereum mainnet workload patterns.

  Based on actual mainnet data:
  - 15-30 TPS average throughput
  - 12-15 second block times
  - Mixed transaction types (60% transfers, 30% contracts, 10% complex)
  - Gas price variations following EIP-1559
  - MEV and priority gas patterns
  """

  alias ExWire.LoadTest.{TransactionGenerator, MetricsCollector}
  require Logger

  @mainnet_patterns %{
    # TPS range during quiet times
    quiet_period: {5, 10},
    # TPS range during normal times
    normal_period: {15, 25},
    # TPS range during busy times
    busy_period: {25, 40},
    # TPS during NFT drops
    nft_drop: {100, 200},
    # TPS during liquidation events
    defi_liquidation: {50, 100}
  }

  @doc """
  Run a full mainnet simulation for specified duration.
  """
  def run(_config, duration_seconds \\ 300) do
    Logger.info("Starting mainnet simulation for #{duration_seconds} seconds")

    end_time = System.monotonic_time(:second) + duration_seconds
    state = init_simulation_state(config)

    run_simulation_loop(state, end_time)
  end

  @doc """
  Simulate a typical day on mainnet with varying patterns.
  """
  def simulate_daily_pattern(_config) do
    Logger.info("Starting 24-hour mainnet pattern simulation")

    # Define hourly patterns (simplified 24-hour cycle)
    hourly_patterns = [
      # 00:00 - 06:00 (quiet night hours)
      {:quiet, 6},
      # 06:00 - 12:00 (morning activity)
      {:normal, 6},
      # 12:00 - 16:00 (peak hours)
      {:busy, 4},
      # 16:00 - 22:00 (evening activity)
      {:normal, 6},
      # 22:00 - 00:00 (late night)
      {:quiet, 2}
    ]

    Enum.reduce(hourly_patterns, %{}, fn {pattern, hours}, acc ->
      # Convert to minutes
      results = simulate_period(config, pattern, hours * 60)
      Map.put(acc, "#{pattern}_#{hours}h", results)
    end)
  end

  @doc """
  Simulate specific mainnet events.
  """
  def simulate_event(_config, event_type) do
    case event_type do
      :nft_drop ->
        simulate_nft_drop(config)

      :defi_liquidation ->
        simulate_defi_liquidation(config)

      :gas_war ->
        simulate_gas_war(config)

      :mev_activity ->
        simulate_mev_activity(config)

      :network_congestion ->
        simulate_congestion(_config)

      _ ->
        {:error, :unknown_event}
    end
  end

  # Private functions

  defp init_simulation_state(_config) do
    %{
      config: config,
      current_period: :normal,
      transactions_sent: 0,
      blocks_produced: 0,
      last_block_time: System.monotonic_time(:millisecond),
      # 30 Gwei
      gas_base_fee: 30_000_000_000,
      pending_pool: [],
      mempool_size: 0
    }
  end

  defp run_simulation_loop(_state, end_time) do
    if System.monotonic_time(:second) >= end_time do
      finalize_simulation(state)
    else
      # Determine current period based on time patterns
      new_period = determine_period(state)

      state =
        if new_period != state.current_period do
          Logger.info("Switching to #{new_period} period")
          %{state | current_period: new_period}
        else
          state
        end

      # Generate transactions for current period
      state = generate_period_transactions(state)

      # Check if block should be produced
      state = maybe_produce_block(state)

      # Update gas prices based on congestion
      state = update_gas_dynamics(state)

      # Small delay to simulate real time
      Process.sleep(100)

      run_simulation_loop(state, end_time)
    end
  end

  defp determine_period(_state) do
    # Randomly switch between periods with some probability
    rand = :rand.uniform()

    cond do
      # 2% chance of NFT drop
      rand < 0.02 -> :nft_drop
      # 3% chance of busy
      rand < 0.05 -> :busy
      # 10% chance of quiet
      rand < 0.15 -> :quiet
      # 85% normal
      true -> :normal
    end
  end

  defp generate_period_transactions(_state) do
    {min_tps, max_tps} = @mainnet_patterns[state.current_period] || @mainnet_patterns[:normal]
    target_tps = min_tps + :rand.uniform(max_tps - min_tps)

    # Generate transactions for 100ms window
    tx_count = max(1, round(target_tps / 10))

    transactions =
      case state.current_period do
        :nft_drop ->
          generate_nft_drop_transactions(state.config, tx_count)

        :defi_liquidation ->
          generate_defi_transactions(state.config, tx_count)

        _ ->
          generate_mixed_transactions(state._config, tx_count)
      end

    # Send transactions
    Enum.each(transactions, fn tx ->
      MetricsCollector.record_transaction_sent("mainnet_simulation", tx_hash(tx))
    end)

    %{
      state
      | pending_pool: state.pending_pool ++ transactions,
        transactions_sent: state.transactions_sent + length(transactions),
        mempool_size: _state.mempool_size + length(transactions)
    }
  end

  defp generate_mixed_transactions(_config, count) do
    # Realistic mainnet mix
    simple_count = round(count * 0.6)
    contract_count = round(count * 0.3)
    complex_count = count - simple_count - contract_count

    simple =
      TransactionGenerator.generate_simple_transfers(
        count: simple_count,
        accounts: config.test_accounts
      )

    contracts =
      TransactionGenerator.generate_contract_calls(
        count: contract_count,
        accounts: config.test_accounts
      )

    complex =
      TransactionGenerator.generate_complex_operations(
        count: max(1, complex_count),
        accounts: config.test_accounts
      )

    Enum.shuffle(simple ++ contracts ++ complex)
  end

  defp generate_nft_drop_transactions(_config, count) do
    # All transactions target same NFT contract
    TransactionGenerator.generate_burst_transactions(
      burst_size: count,
      accounts: config.test_accounts,
      # Random NFT contract
      target: :crypto.strong_rand_bytes(20)
    )
  end

  defp generate_defi_transactions(_config, count) do
    # High-priority DeFi transactions
    TransactionGenerator.generate_complex_operations(
      count: count,
      accounts: config.test_accounts
    )
  end

  defp maybe_produce_block(_state) do
    current_time = System.monotonic_time(:millisecond)
    time_since_last = current_time - state.last_block_time

    # Target 12-15 second blocks with some variation
    target_block_time = 12_000 + :rand.uniform(3000)

    if time_since_last >= target_block_time do
      produce_block(state, current_time)
    else
      state
    end
  end

  defp produce_block(_state, current_time) do
    # Select transactions for block (simplified)
    block_gas_limit = 30_000_000
    {block_txs, remaining} = select_transactions_for_block(state.pending_pool, block_gas_limit)

    block_time_ms = current_time - state.last_block_time

    # Record block production
    MetricsCollector.record_block_produced(
      "mainnet_simulation",
      state.blocks_produced + 1,
      block_time_ms,
      length(block_txs)
    )

    # Process confirmed transactions
    Enum.each(block_txs, fn tx ->
      gas_used = estimate_gas_used(tx)
      # 0.5-1.5 seconds
      latency = :rand.uniform(1000) + 500

      MetricsCollector.record_transaction_confirmed(
        "mainnet_simulation",
        tx_hash(tx),
        gas_used,
        latency
      )
    end)

    Logger.info(
      "Block ##{state.blocks_produced + 1} produced with #{length(block_txs)} transactions"
    )

    %{
      state
      | blocks_produced: state.blocks_produced + 1,
        last_block_time: current_time,
        pending_pool: remaining,
        mempool_size: length(remaining)
    }
  end

  defp select_transactions_for_block(transactions, gas_limit) do
    # Sort by gas price (simplified priority)
    sorted = Enum.sort_by(transactions, & &1.gas_price, :desc)

    {selected, remaining, _gas_used} =
      Enum.reduce(sorted, {[], [], 0}, fn tx, {selected, remaining, gas_used} ->
        tx_gas = tx.gas_limit

        if gas_used + tx_gas <= gas_limit do
          {[tx | selected], remaining, gas_used + tx_gas}
        else
          {selected, [tx | remaining], gas_used}
        end
      end)

    {Enum.reverse(selected), remaining}
  end

  defp update_gas_dynamics(_state) do
    # EIP-1559 style gas price adjustment
    # 50% of block limit
    target_gas = 15_000_000

    cond do
      state.mempool_size > 100 ->
        # Increase base fee if mempool is congested
        new_base_fee = min(500_000_000_000, state.gas_base_fee * 1.125)
        %{state | gas_base_fee: round(new_base_fee)}

      state.mempool_size < 20 ->
        # Decrease base fee if mempool is empty
        new_base_fee = max(1_000_000_000, state.gas_base_fee * 0.875)
        %{state | gas_base_fee: round(new_base_fee)}

      true ->
        state
    end
  end

  defp simulate_period(_config, pattern, duration_minutes) do
    duration_seconds = duration_minutes * 60

    state = %{
      config: config,
      current_period: pattern,
      transactions_sent: 0,
      blocks_produced: 0,
      last_block_time: System.monotonic_time(:millisecond),
      gas_base_fee: 30_000_000_000,
      pending_pool: [],
      mempool_size: 0
    }

    run_simulation_loop(state, System.monotonic_time(:second) + duration_seconds)
  end

  defp simulate_nft_drop(_config) do
    Logger.info("Simulating NFT drop event")

    # Burst of transactions all targeting same contract
    transactions =
      TransactionGenerator.generate_burst_transactions(
        burst_size: 5000,
        accounts: config.test_accounts
      )

    # Process in rapid succession
    Enum.each(transactions, fn tx ->
      MetricsCollector.record_transaction_sent("nft_drop", tx_hash(tx))
      # Some will fail due to sold out
      if :rand.uniform() < 0.3 do
        MetricsCollector.record_transaction_failed("nft_drop", tx_hash(tx), :sold_out)
      else
        gas = 150_000 + :rand.uniform(50_000)
        MetricsCollector.record_transaction_confirmed("nft_drop", tx_hash(tx), gas, 2000)
      end
    end)

    %{event: :nft_drop, transactions: length(transactions), duration_ms: 5000}
  end

  defp simulate_defi_liquidation(_config) do
    Logger.info("Simulating DeFi liquidation cascade")

    # High-priority liquidation transactions
    transactions =
      TransactionGenerator.generate_complex_operations(
        count: 500,
        accounts: config.test_accounts
      )

    Enum.each(transactions, fn tx ->
      MetricsCollector.record_transaction_sent("defi_liquidation", tx_hash(tx))
      gas = 300_000 + :rand.uniform(200_000)
      MetricsCollector.record_transaction_confirmed("defi_liquidation", tx_hash(tx), gas, 1000)
    end)

    %{event: :defi_liquidation, transactions: length(transactions)}
  end

  defp simulate_gas_war(_config) do
    Logger.info("Simulating gas war")

    # Transactions with escalating gas prices
    transactions =
      Enum.map(1..100, fn i ->
        base_gas = 30_000_000_000
        # Escalating gas
        gas_price = base_gas * (1 + i / 10)

        %{
          gas_price: round(gas_price),
          tx:
            TransactionGenerator.generate_simple_transfers(
              count: 1,
              accounts: config.test_accounts
            )
            |> List.first()
        }
      end)

    Enum.each(transactions, fn %{tx: tx, gas_price: _price} ->
      MetricsCollector.record_transaction_sent("gas_war", tx_hash(tx))
    end)

    %{event: :gas_war, max_gas_price: List.last(transactions).gas_price}
  end

  defp simulate_mev_activity(_config) do
    Logger.info("Simulating MEV activity")

    # Sandwich attacks, arbitrage, liquidations
    mev_transactions = generate_mev_bundle(config)

    Enum.each(mev_transactions, fn tx ->
      MetricsCollector.record_transaction_sent("mev_activity", tx_hash(tx))
      # MEV transactions typically have high success rate
      gas = 200_000 + :rand.uniform(100_000)
      MetricsCollector.record_transaction_confirmed("mev_activity", tx_hash(tx), gas, 500)
    end)

    %{event: :mev_activity, bundles: div(length(mev_transactions), 3)}
  end

  defp simulate_congestion(_config) do
    Logger.info("Simulating network congestion")

    # Flood with transactions
    waves =
      Enum.map(1..10, fn wave ->
        transactions = generate_mixed_transactions(config, 100)

        Enum.each(transactions, fn tx ->
          MetricsCollector.record_transaction_sent("congestion_wave_#{wave}", tx_hash(tx))

          # Many transactions will be delayed or dropped
          cond do
            :rand.uniform() < 0.2 ->
              MetricsCollector.record_transaction_failed(
                "congestion_wave_#{wave}",
                tx_hash(tx),
                :timeout
              )

            :rand.uniform() < 0.5 ->
              # Delayed confirmation
              gas = estimate_gas_used(tx)

              MetricsCollector.record_transaction_confirmed(
                "congestion_wave_#{wave}",
                tx_hash(tx),
                gas,
                30_000
              )

            true ->
              # Normal confirmation
              gas = estimate_gas_used(tx)

              MetricsCollector.record_transaction_confirmed(
                "congestion_wave_#{wave}",
                tx_hash(tx),
                gas,
                5_000
              )
          end
        end)

        # 1 second between waves
        Process.sleep(1000)
        length(transactions)
      end)

    %{event: :congestion, waves: length(waves), total_transactions: Enum.sum(waves)}
  end

  defp generate_mev_bundle(_config) do
    # Simulate MEV bundle (frontrun, target, backrun)
    frontrun =
      TransactionGenerator.generate_simple_transfers(count: 1, accounts: config.test_accounts)

    target =
      TransactionGenerator.generate_complex_operations(count: 1, accounts: config.test_accounts)

    backrun =
      TransactionGenerator.generate_simple_transfers(count: 1, accounts: config.test_accounts)

    frontrun ++ target ++ backrun
  end

  defp finalize_simulation(_state) do
    Logger.info("""
    Mainnet simulation completed:
    - Transactions sent: #{state.transactions_sent}
    - Blocks produced: #{state.blocks_produced}
    - Final mempool size: #{state.mempool_size}
    - Final base fee: #{state.gas_base_fee / 1_000_000_000} Gwei
    """)

    state
  end

  defp tx_hash(tx) do
    :crypto.hash(:sha256, :erlang.term_to_binary(tx))
    |> Base.encode16(case: :lower)
  end

  defp estimate_gas_used(tx) do
    # Simplified gas estimation
    base_gas = tx.gas_limit
    execution_gas = round(base_gas * (0.5 + :rand.uniform() * 0.5))
    min(execution_gas, tx.gas_limit)
  end
end
