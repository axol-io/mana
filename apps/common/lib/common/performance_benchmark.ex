defmodule Common.PerformanceBenchmark do
  @moduledoc """
  Performance benchmarking suite for the Mana Ethereum client.
  Tests Layer 2 throughput, Verkle witness generation, and overall system performance.
  """

  require Logger
  alias Benchee

  defmodule BenchmarkResult do
    defstruct [
      :name,
      :category,
      :mean_time,
      :median_time,
      :min_time,
      :max_time,
      :std_dev,
      :throughput,
      :memory_usage,
      :timestamp
    ]
  end

  @doc """
  Run all performance benchmarks
  """
  def run_all_benchmarks do
    Logger.info("Starting comprehensive performance benchmarks...")

    results = [
      benchmark_layer2_throughput(),
      benchmark_verkle_witnesses(),
      benchmark_eth2_consensus(),
      benchmark_transaction_processing(),
      benchmark_state_operations(),
      benchmark_network_performance()
    ]

    generate_performance_report(results)
  end

  @doc """
  Benchmark Layer 2 throughput across different rollup types
  """
  def benchmark_layer2_throughput do
    Logger.info("Benchmarking Layer 2 throughput...")

    scenarios = %{
      "Optimism Bedrock" => fn -> benchmark_optimism_throughput() end,
      "Arbitrum Nitro" => fn -> benchmark_arbitrum_throughput() end,
      "zkSync Era" => fn -> benchmark_zksync_throughput() end
    }

    results =
      Benchee.run(
        scenarios,
        time: 10,
        memory_time: 2,
        warmup: 2,
        parallel: 1,
        formatters: [
          {Benchee.Formatters.Console, extended_statistics: true}
        ]
      )

    convert_to_benchmark_results("Layer2 Throughput", results)
  end

  @doc """
  Benchmark Verkle witness generation
  """
  def benchmark_verkle_witnesses do
    Logger.info("Benchmarking Verkle witness generation...")

    test_cases = [
      {10, "Small state (10 keys)"},
      {100, "Medium state (100 keys)"},
      {1000, "Large state (1000 keys)"},
      {10000, "Very large state (10000 keys)"}
    ]

    results =
      Enum.map(test_cases, fn {key_count, description} ->
        benchmark_witness_generation(key_count, description)
      end)

    List.flatten(results)
  end

  @doc """
  Benchmark Eth2 consensus operations
  """
  def benchmark_eth2_consensus do
    Logger.info("Benchmarking Eth2 consensus operations...")

    scenarios = %{
      "Attestation validation" => fn -> benchmark_attestation_validation() end,
      "Sync committee processing" => fn -> benchmark_sync_committee() end,
      "Block validation" => fn -> benchmark_block_validation() end,
      "Fork choice update" => fn -> benchmark_fork_choice() end,
      "Light client update" => fn -> benchmark_light_client_update() end
    }

    results =
      Benchee.run(
        scenarios,
        time: 5,
        warmup: 1,
        formatters: [
          {Benchee.Formatters.Console, comparison: false}
        ]
      )

    convert_to_benchmark_results("Eth2 Consensus", results)
  end

  # Layer 2 specific benchmarks

  defp benchmark_optimism_throughput do
    # Simulate Optimism transaction batch processing
    batch_size = 1000
    transactions = generate_test_transactions(batch_size)

    # Process batch through Optimism protocol
    start_time = System.monotonic_time(:microsecond)

    # Simulate sequencer batch creation
    batch = create_optimism_batch(transactions)

    # Simulate L1 data commitment
    _commitment = compute_batch_commitment(batch)

    # Simulate fraud proof window check
    validate_fraud_proof_window(batch)

    end_time = System.monotonic_time(:microsecond)
    elapsed = end_time - start_time

    # Calculate throughput (TPS)
    tps = batch_size / (elapsed / 1_000_000)

    {:ok, %{time: elapsed, throughput: tps, batch_size: batch_size}}
  end

  defp benchmark_arbitrum_throughput do
    # Simulate Arbitrum transaction processing
    # Arbitrum typically handles more TPS
    batch_size = 1500
    transactions = generate_test_transactions(batch_size)

    start_time = System.monotonic_time(:microsecond)

    # Simulate sequencer inbox
    inbox = create_arbitrum_inbox(transactions)

    # Simulate Brotli compression
    _compressed = compress_with_brotli(inbox)

    # Simulate interactive fraud proof preparation
    _fraud_proof_data = prepare_interactive_fraud_proof(inbox)

    end_time = System.monotonic_time(:microsecond)
    elapsed = end_time - start_time

    tps = batch_size / (elapsed / 1_000_000)

    {:ok, %{time: elapsed, throughput: tps, batch_size: batch_size}}
  end

  defp benchmark_zksync_throughput do
    # Simulate zkSync transaction processing
    # ZK rollups can handle more transactions
    batch_size = 2000
    transactions = generate_test_transactions(batch_size)

    start_time = System.monotonic_time(:microsecond)

    # Simulate state tree updates
    state_tree = update_zksync_state_tree(transactions)

    # Simulate PLONK proof generation (mock - actual would be much slower)
    proof = generate_mock_plonk_proof(state_tree)

    # Simulate proof verification
    verify_plonk_proof(proof)

    end_time = System.monotonic_time(:microsecond)
    elapsed = end_time - start_time

    tps = batch_size / (elapsed / 1_000_000)

    {:ok, %{time: elapsed, throughput: tps, batch_size: batch_size}}
  end

  # Verkle witness benchmarks

  defp benchmark_witness_generation(key_count, description) do
    Logger.info("Benchmarking Verkle witness for #{description}...")

    # Generate test state
    state = generate_verkle_test_state(key_count)

    # Benchmark witness generation
    {time, witness} =
      :timer.tc(fn ->
        generate_verkle_witness(state)
      end)

    witness_size = byte_size(:erlang.term_to_binary(witness))

    %BenchmarkResult{
      name: "Verkle witness - #{description}",
      category: "Verkle",
      mean_time: time,
      median_time: time,
      min_time: time,
      max_time: time,
      std_dev: 0,
      throughput: key_count / (time / 1_000_000),
      memory_usage: witness_size,
      timestamp: DateTime.utc_now()
    }
  end

  # Eth2 consensus benchmarks

  defp benchmark_attestation_validation do
    # Generate test attestation
    attestation = generate_test_attestation()

    # Validate including BLS signature verification
    validate_attestation(attestation)
  end

  defp benchmark_sync_committee do
    # Generate sync committee update
    update = generate_sync_committee_update()

    # Process update with signature aggregation
    process_sync_committee_update(update)
  end

  defp benchmark_block_validation do
    # Generate test beacon block
    block = generate_test_beacon_block()

    # Full block validation
    validate_beacon_block(block)
  end

  defp benchmark_fork_choice do
    # Simulate fork choice with multiple branches
    branches = generate_fork_branches()

    # Run fork choice algorithm
    compute_fork_choice(branches)
  end

  defp benchmark_light_client_update do
    # Generate light client update
    update = generate_light_client_update()

    # Process update with optimistic sync
    process_light_client_update(update)
  end

  @doc """
  Benchmark transaction processing performance
  """
  def benchmark_transaction_processing do
    Logger.info("Benchmarking transaction processing...")

    scenarios = %{
      "Simple transfer" => fn -> process_simple_transfer() end,
      "Contract deployment" => fn -> process_contract_deployment() end,
      "Contract interaction" => fn -> process_contract_call() end,
      "Batch processing (100 tx)" => fn -> process_transaction_batch(100) end,
      "Batch processing (1000 tx)" => fn -> process_transaction_batch(1000) end
    }

    results =
      Benchee.run(
        scenarios,
        time: 5,
        warmup: 1
      )

    convert_to_benchmark_results("Transaction Processing", results)
  end

  @doc """
  Benchmark state operations
  """
  def benchmark_state_operations do
    Logger.info("Benchmarking state operations...")

    scenarios = %{
      "State read" => fn -> benchmark_state_read() end,
      "State write" => fn -> benchmark_state_write() end,
      "State pruning" => fn -> benchmark_state_pruning() end,
      "Merkle proof generation" => fn -> benchmark_merkle_proof() end,
      "State snapshot" => fn -> benchmark_state_snapshot() end
    }

    results =
      Benchee.run(
        scenarios,
        time: 3,
        warmup: 1
      )

    convert_to_benchmark_results("State Operations", results)
  end

  @doc """
  Benchmark network performance
  """
  def benchmark_network_performance do
    Logger.info("Benchmarking network performance...")

    scenarios = %{
      "Block propagation" => fn -> benchmark_block_propagation() end,
      "Transaction broadcast" => fn -> benchmark_tx_broadcast() end,
      "Peer discovery" => fn -> benchmark_peer_discovery() end,
      "Message serialization" => fn -> benchmark_message_serialization() end,
      "Message deserialization" => fn -> benchmark_message_deserialization() end
    }

    results =
      Benchee.run(
        scenarios,
        time: 3,
        warmup: 1
      )

    convert_to_benchmark_results("Network", results)
  end

  # Helper functions for generating test data

  defp generate_test_transactions(count) do
    Enum.map(1..count, fn i ->
      %{
        nonce: i,
        gas_price: 20_000_000_000,
        gas_limit: 21_000,
        to: generate_random_address(),
        value: :rand.uniform(1_000_000_000_000_000_000),
        data: <<>>,
        v: 27,
        r: :crypto.strong_rand_bytes(32),
        s: :crypto.strong_rand_bytes(32)
      }
    end)
  end

  defp generate_random_address do
    :crypto.strong_rand_bytes(20)
  end

  defp generate_verkle_test_state(key_count) do
    Enum.reduce(1..key_count, %{}, fn i, acc ->
      key = :crypto.hash(:sha256, <<i::256>>)
      value = :crypto.strong_rand_bytes(32)
      Map.put(acc, key, value)
    end)
  end

  defp generate_test_attestation do
    %{
      aggregation_bits: :crypto.strong_rand_bytes(64),
      data: %{
        slot: :rand.uniform(1_000_000),
        index: :rand.uniform(64),
        beacon_block_root: :crypto.strong_rand_bytes(32),
        source: %{
          epoch: :rand.uniform(10_000),
          root: :crypto.strong_rand_bytes(32)
        },
        target: %{
          epoch: :rand.uniform(10_000),
          root: :crypto.strong_rand_bytes(32)
        }
      },
      signature: :crypto.strong_rand_bytes(96)
    }
  end

  defp generate_sync_committee_update do
    %{
      sync_committee: generate_sync_committee(),
      sync_committee_bits: :crypto.strong_rand_bytes(64),
      sync_committee_signature: :crypto.strong_rand_bytes(96),
      slot: :rand.uniform(1_000_000)
    }
  end

  defp generate_sync_committee do
    %{
      pubkeys: Enum.map(1..512, fn _ -> :crypto.strong_rand_bytes(48) end),
      aggregate_pubkey: :crypto.strong_rand_bytes(48)
    }
  end

  defp generate_test_beacon_block do
    %{
      slot: :rand.uniform(1_000_000),
      proposer_index: :rand.uniform(10_000),
      parent_root: :crypto.strong_rand_bytes(32),
      state_root: :crypto.strong_rand_bytes(32),
      body: %{
        randao_reveal: :crypto.strong_rand_bytes(96),
        eth1_data: %{
          deposit_root: :crypto.strong_rand_bytes(32),
          deposit_count: :rand.uniform(1000),
          block_hash: :crypto.strong_rand_bytes(32)
        },
        graffiti: :crypto.strong_rand_bytes(32),
        proposer_slashings: [],
        attester_slashings: [],
        attestations: Enum.map(1..128, fn _ -> generate_test_attestation() end),
        deposits: [],
        voluntary_exits: []
      }
    }
  end

  defp generate_fork_branches do
    Enum.map(1..5, fn _i ->
      %{
        head_block: :crypto.strong_rand_bytes(32),
        justified_epoch: :rand.uniform(1000),
        finalized_epoch: :rand.uniform(900),
        weight: :rand.uniform(1_000_000)
      }
    end)
  end

  defp generate_light_client_update do
    %{
      attested_header: generate_beacon_header(),
      next_sync_committee: generate_sync_committee(),
      next_sync_committee_branch: Enum.map(1..5, fn _ -> :crypto.strong_rand_bytes(32) end),
      finalized_header: generate_beacon_header(),
      finality_branch: Enum.map(1..6, fn _ -> :crypto.strong_rand_bytes(32) end),
      sync_aggregate: %{
        sync_committee_bits: :crypto.strong_rand_bytes(64),
        sync_committee_signature: :crypto.strong_rand_bytes(96)
      },
      signature_slot: :rand.uniform(1_000_000)
    }
  end

  defp generate_beacon_header do
    %{
      slot: :rand.uniform(1_000_000),
      proposer_index: :rand.uniform(10_000),
      parent_root: :crypto.strong_rand_bytes(32),
      state_root: :crypto.strong_rand_bytes(32),
      body_root: :crypto.strong_rand_bytes(32)
    }
  end

  # Mock implementation functions (would be actual implementations in production)

  defp create_optimism_batch(transactions),
    do: %{transactions: transactions, timestamp: System.os_time()}

  defp compute_batch_commitment(batch), do: :crypto.hash(:sha256, :erlang.term_to_binary(batch))
  defp validate_fraud_proof_window(_batch), do: :ok

  defp create_arbitrum_inbox(transactions), do: %{messages: transactions}
  defp compress_with_brotli(data), do: :zlib.compress(:erlang.term_to_binary(data))
  defp prepare_interactive_fraud_proof(_inbox), do: %{challenge_period: 7 * 24 * 60 * 60}

  defp update_zksync_state_tree(transactions),
    do: %{root: :crypto.hash(:sha256, :erlang.term_to_binary(transactions))}

  defp generate_mock_plonk_proof(_state_tree), do: :crypto.strong_rand_bytes(256)
  defp verify_plonk_proof(_proof), do: true

  defp generate_verkle_witness(state) do
    keys = Map.keys(state) |> Enum.take(10)

    %{
      keys: keys,
      values: Enum.map(keys, &Map.get(state, &1)),
      # Verkle witnesses are ~200 bytes
      proof: :crypto.strong_rand_bytes(200)
    }
  end

  defp validate_attestation(_attestation), do: :ok
  defp process_sync_committee_update(_update), do: :ok
  defp validate_beacon_block(_block), do: :ok
  defp compute_fork_choice(_branches), do: :crypto.strong_rand_bytes(32)
  defp process_light_client_update(_update), do: :ok

  defp process_simple_transfer do
    _tx = hd(generate_test_transactions(1))
    # Simulate transaction validation and execution
    :ok
  end

  defp process_contract_deployment do
    # Simulate contract deployment with bytecode
    _bytecode = :crypto.strong_rand_bytes(1000)
    :ok
  end

  defp process_contract_call do
    # Simulate contract interaction
    :ok
  end

  defp process_transaction_batch(count) do
    transactions = generate_test_transactions(count)
    # Simulate batch processing
    Enum.each(transactions, fn _tx -> :ok end)
  end

  defp benchmark_state_read, do: :ok
  defp benchmark_state_write, do: :ok
  defp benchmark_state_pruning, do: :ok
  defp benchmark_merkle_proof, do: :ok
  defp benchmark_state_snapshot, do: :ok

  defp benchmark_block_propagation, do: :ok
  defp benchmark_tx_broadcast, do: :ok
  defp benchmark_peer_discovery, do: :ok
  defp benchmark_message_serialization, do: :ok
  defp benchmark_message_deserialization, do: :ok

  # Report generation

  defp convert_to_benchmark_results(category, _benchee_results) do
    # Convert Benchee results to our format
    # This is a simplified conversion - actual implementation would extract from Benchee
    [
      %BenchmarkResult{
        name: category,
        category: category,
        mean_time: 0,
        median_time: 0,
        min_time: 0,
        max_time: 0,
        std_dev: 0,
        throughput: 0,
        memory_usage: 0,
        timestamp: DateTime.utc_now()
      }
    ]
  end

  @doc """
  Generate comprehensive performance report
  """
  def generate_performance_report(results) do
    report = %{
      timestamp: DateTime.utc_now(),
      summary: generate_performance_summary(results),
      layer2_metrics: extract_layer2_metrics(results),
      verkle_metrics: extract_verkle_metrics(results),
      consensus_metrics: extract_consensus_metrics(results),
      recommendations: generate_performance_recommendations(results)
    }

    write_performance_report(report)
    log_performance_summary(report)

    report
  end

  defp generate_performance_summary(results) do
    flat_results = List.flatten(results)

    %{
      total_benchmarks_run: length(flat_results),
      categories_tested: flat_results |> Enum.map(& &1.category) |> Enum.uniq() |> length(),
      timestamp: DateTime.utc_now()
    }
  end

  defp extract_layer2_metrics(results) do
    results
    |> List.flatten()
    |> Enum.filter(&(&1.category == "Layer2 Throughput"))
    |> Enum.map(fn r ->
      %{
        name: r.name,
        throughput_tps: r.throughput,
        latency_ms: r.mean_time / 1000
      }
    end)
  end

  defp extract_verkle_metrics(results) do
    results
    |> List.flatten()
    |> Enum.filter(&(&1.category == "Verkle"))
    |> Enum.map(fn r ->
      %{
        name: r.name,
        witness_size_bytes: r.memory_usage,
        generation_time_us: r.mean_time,
        keys_per_second: r.throughput
      }
    end)
  end

  defp extract_consensus_metrics(results) do
    results
    |> List.flatten()
    |> Enum.filter(&(&1.category == "Eth2 Consensus"))
    |> Enum.map(fn r ->
      %{
        operation: r.name,
        mean_time_us: r.mean_time,
        throughput: r.throughput
      }
    end)
  end

  defp generate_performance_recommendations(results) do
    recommendations = []

    # Check Layer 2 throughput
    layer2_results = extract_layer2_metrics(results)

    recommendations =
      if Enum.any?(layer2_results, &(&1.throughput_tps < 1000)) do
        ["Consider optimizing Layer 2 batch processing for better throughput" | recommendations]
      else
        recommendations
      end

    # Check Verkle witness size
    verkle_results = extract_verkle_metrics(results)

    recommendations =
      if Enum.any?(verkle_results, &(&1.witness_size_bytes > 500)) do
        ["Verkle witness size exceeds target - review compression" | recommendations]
      else
        recommendations
      end

    recommendations
  end

  defp write_performance_report(report) do
    timestamp = DateTime.to_iso8601(report.timestamp)
    filename = "performance_benchmark_#{timestamp}.json"
    path = Path.join(["benchmarks", filename])

    File.mkdir_p!("benchmarks")
    File.write!(path, Jason.encode!(report, pretty: true))

    Logger.info("Performance report written to #{path}")
  end

  defp log_performance_summary(report) do
    Logger.info("""

    ===== PERFORMANCE BENCHMARK SUMMARY =====
    Timestamp: #{report.timestamp}
    Total Benchmarks Run: #{report.summary.total_benchmarks_run}
    Categories Tested: #{report.summary.categories_tested}

    Layer 2 Metrics:
    #{format_layer2_metrics(report.layer2_metrics)}

    Verkle Metrics:
    #{format_verkle_metrics(report.verkle_metrics)}

    Recommendations:
    #{Enum.join(report.recommendations, "\n")}
    =========================================
    """)
  end

  defp format_layer2_metrics(metrics) do
    metrics
    |> Enum.map(fn m ->
      "  #{m.name}: #{m.throughput_tps} TPS, #{m.latency_ms}ms latency"
    end)
    |> Enum.join("\n")
  end

  defp format_verkle_metrics(metrics) do
    metrics
    |> Enum.map(fn m ->
      "  #{m.name}: #{m.witness_size_bytes} bytes, #{m.generation_time_us}μs"
    end)
    |> Enum.join("\n")
  end
end
