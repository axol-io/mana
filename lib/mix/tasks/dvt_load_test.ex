defmodule Mix.Tasks.DvtLoadTest do
  @moduledoc """
  DVT Load Testing Framework

  Comprehensive load testing for DVT validator clusters including:
  - Consensus message throughput testing
  - Network partition simulation
  - Byzantine fault injection
  - Performance metrics collection

  ## Usage

      # Basic load test
      mix dvt_load_test --cluster-size 5 --duration 300

      # Stress test with faults
      mix dvt_load_test --cluster-size 10 --duration 600 --byzantine-nodes 2 --partition-test

      # Performance benchmark
      mix dvt_load_test --benchmark --cluster-size 7 --threshold 5

  """
  
  use Mix.Task
  require Logger
  
  alias ExWire.DVT.{KeyManager, DutyConsensus, P2PProtocol, PartitionDetector, GossipSubOptimizer}

  @shortdoc "Run DVT cluster load testing"

  @default_options [
    cluster_size: 5,
    threshold: 3,
    duration: 300,  # seconds
    message_rate: 100,  # messages per second
    byzantine_nodes: 0,
    partition_test: false,
    benchmark: false,
    output_format: :table,
    metrics_file: nil
  ]

  ## Public API

  def run(args) do
    {options, [], []} = OptionParser.parse(args, 
      strict: [
        cluster_size: :integer,
        threshold: :integer,
        duration: :integer,
        message_rate: :integer,
        byzantine_nodes: :integer,
        partition_test: :boolean,
        benchmark: :boolean,
        output_format: :string,
        metrics_file: :string,
        help: :boolean
      ]
    )

    if options[:help] do
      print_help()
      return
    end

    config = Keyword.merge(@default_options, options)
    
    validate_configuration(config)
    
    Mix.shell().info("Starting DVT Load Testing...")
    Mix.shell().info("Configuration: #{inspect(config)}")
    
    # Initialize testing environment
    {:ok, test_state} = initialize_test_environment(config)
    
    try do
      # Run load test scenarios
      results = run_load_test_scenarios(test_state, config)
      
      # Generate and display results
      display_results(results, config)
      
      # Save metrics if requested
      if config[:metrics_file] do
        save_metrics(results, config[:metrics_file])
      end
      
      Mix.shell().info("Load testing completed successfully")
      
    after
      # Cleanup test environment
      cleanup_test_environment(test_state)
    end
  end

  ## Private Functions

  defp validate_configuration(config) do
    cond do
      config[:threshold] >= config[:cluster_size] ->
        Mix.raise("Threshold (#{config[:threshold]}) must be less than cluster size (#{config[:cluster_size]})")
        
      config[:byzantine_nodes] >= config[:threshold] ->
        Mix.raise("Byzantine nodes (#{config[:byzantine_nodes]}) must be less than threshold (#{config[:threshold]})")
        
      config[:duration] < 60 ->
        Mix.raise("Test duration must be at least 60 seconds")
        
      true ->
        :ok
    end
  end

  defp initialize_test_environment(config) do
    Mix.shell().info("Initializing DVT test cluster...")
    
    # Start required services
    {:ok, _} = Application.ensure_all_started(:ex_wire)
    
    # Create test cluster
    cluster_id = "load_test_#{:os.system_time(:millisecond)}"
    validator_key = :crypto.strong_rand_bytes(32)
    
    participants = generate_test_participants(config[:cluster_size])
    
    {:ok, cluster} = KeyManager.create_cluster(
      cluster_id,
      validator_key,
      config[:threshold],
      config[:cluster_size],
      participants
    )
    
    # Start DVT communication supervisor
    {:ok, comm_supervisor} = ExWire.DVT.CommunicationSupervisor.start_link(
      node_id: "load_test_coordinator"
    )
    
    # Configure cluster for all nodes
    Enum.each(1..config[:cluster_size], fn node_id ->
      cluster_config = %{
        node_id: node_id,
        auth_key: "test_auth_#{node_id}",
        node_count: config[:cluster_size],
        threshold: config[:threshold],
        partition_tolerance: :minority,
        topics: generate_topic_config(cluster_id)
      }
      
      ExWire.DVT.CommunicationSupervisor.configure_cluster(cluster_id, cluster_config)
    end)
    
    test_state = %{
      cluster_id: cluster_id,
      cluster: cluster,
      participants: participants,
      comm_supervisor: comm_supervisor,
      start_time: DateTime.utc_now(),
      metrics: %{
        messages_sent: 0,
        messages_received: 0,
        consensus_rounds: 0,
        partition_events: 0,
        byzantine_detections: 0,
        average_latency: 0,
        errors: []
      }
    }
    
    # Wait for cluster formation
    Process.sleep(5_000)
    
    Mix.shell().info("Test cluster initialized: #{cluster_id}")
    {:ok, test_state}
  end

  defp run_load_test_scenarios(test_state, config) do
    scenarios = build_test_scenarios(config)
    
    results = Enum.map(scenarios, fn scenario ->
      Mix.shell().info("Running scenario: #{scenario.name}")
      
      scenario_result = run_scenario(scenario, test_state, config)
      
      Mix.shell().info("Scenario '#{scenario.name}' completed")
      scenario_result
    end)
    
    %{
      test_state: test_state,
      scenario_results: results,
      overall_metrics: calculate_overall_metrics(results),
      test_duration: DateTime.diff(DateTime.utc_now(), test_state.start_time, :second)
    }
  end

  defp build_test_scenarios(config) do
    scenarios = [
      %{
        name: "Baseline Consensus",
        description: "Normal consensus operations under load",
        duration: div(config[:duration], 4),
        message_rate: config[:message_rate],
        faults: []
      },
      
      %{
        name: "High Throughput",
        description: "Maximum message throughput testing",
        duration: div(config[:duration], 4),
        message_rate: config[:message_rate] * 3,
        faults: []
      }
    ]
    
    # Add partition testing scenario if enabled
    scenarios = if config[:partition_test] do
      partition_scenario = %{
        name: "Network Partitions",
        description: "Consensus under network partitions",
        duration: div(config[:duration], 3),
        message_rate: config[:message_rate],
        faults: [:network_partition]
      }
      
      scenarios ++ [partition_scenario]
    else
      scenarios
    end
    
    # Add Byzantine fault scenario if nodes specified
    scenarios = if config[:byzantine_nodes] > 0 do
      byzantine_scenario = %{
        name: "Byzantine Faults",
        description: "Consensus with Byzantine nodes",
        duration: div(config[:duration], 3),
        message_rate: config[:message_rate],
        faults: [{:byzantine_nodes, config[:byzantine_nodes]}]
      }
      
      scenarios ++ [byzantine_scenario]
    else
      scenarios
    end
    
    scenarios
  end

  defp run_scenario(scenario, test_state, config) do
    scenario_start = DateTime.utc_now()
    
    # Apply scenario faults
    fault_pids = apply_scenario_faults(scenario.faults, test_state)
    
    # Start message generation
    message_generator = start_message_generator(scenario, test_state)
    
    # Start metrics collection
    metrics_collector = start_metrics_collector(test_state)
    
    # Run scenario for specified duration
    Process.sleep(scenario.duration * 1000)
    
    # Stop message generation
    GenServer.stop(message_generator)
    
    # Collect final metrics
    final_metrics = GenServer.call(metrics_collector, :get_metrics)
    GenServer.stop(metrics_collector)
    
    # Remove faults
    Enum.each(fault_pids, &GenServer.stop/1)
    
    scenario_duration = DateTime.diff(DateTime.utc_now(), scenario_start, :millisecond)
    
    %{
      scenario: scenario,
      duration_ms: scenario_duration,
      metrics: final_metrics,
      success: final_metrics.error_count == 0
    }
  end

  defp apply_scenario_faults(faults, test_state) do
    Enum.flat_map(faults, fn fault ->
      case fault do
        :network_partition ->
          [start_partition_simulator(test_state)]
          
        {:byzantine_nodes, count} ->
          start_byzantine_simulators(count, test_state)
          
        _ ->
          []
      end
    end)
  end

  defp start_message_generator(scenario, test_state) do
    {:ok, pid} = GenServer.start_link(__MODULE__.MessageGenerator, %{
      cluster_id: test_state.cluster_id,
      message_rate: scenario.message_rate,
      test_state: test_state
    })
    pid
  end

  defp start_metrics_collector(test_state) do
    {:ok, pid} = GenServer.start_link(__MODULE__.MetricsCollector, %{
      cluster_id: test_state.cluster_id,
      start_time: DateTime.utc_now()
    })
    pid
  end

  defp start_partition_simulator(test_state) do
    {:ok, pid} = GenServer.start_link(__MODULE__.PartitionSimulator, %{
      cluster_id: test_state.cluster_id,
      participants: test_state.participants
    })
    pid
  end

  defp start_byzantine_simulators(count, test_state) do
    1..count
    |> Enum.map(fn node_id ->
      {:ok, pid} = GenServer.start_link(__MODULE__.ByzantineSimulator, %{
        cluster_id: test_state.cluster_id,
        node_id: node_id,
        test_state: test_state
      })
      pid
    end)
  end

  defp calculate_overall_metrics(scenario_results) do
    total_messages = Enum.sum(Enum.map(scenario_results, & &1.metrics.messages_sent))
    total_duration = Enum.sum(Enum.map(scenario_results, & &1.duration_ms))
    
    %{
      total_messages: total_messages,
      total_duration_ms: total_duration,
      average_throughput: if(total_duration > 0, do: total_messages / (total_duration / 1000), else: 0),
      success_rate: calculate_success_rate(scenario_results),
      total_errors: Enum.sum(Enum.map(scenario_results, & &1.metrics.error_count))
    }
  end

  defp calculate_success_rate(scenario_results) do
    successful = Enum.count(scenario_results, & &1.success)
    total = length(scenario_results)
    
    if total > 0, do: successful / total * 100, else: 0
  end

  defp display_results(results, config) do
    case config[:output_format] do
      :json -> display_json_results(results)
      :csv -> display_csv_results(results)
      _ -> display_table_results(results)
    end
  end

  defp display_table_results(results) do
    Mix.shell().info("\n" <> String.duplicate("=", 60))
    Mix.shell().info("DVT LOAD TESTING RESULTS")
    Mix.shell().info(String.duplicate("=", 60))
    
    Mix.shell().info("Overall Metrics:")
    Mix.shell().info("  Total Messages: #{results.overall_metrics.total_messages}")
    Mix.shell().info("  Test Duration: #{results.test_duration}s")
    Mix.shell().info("  Average Throughput: #{Float.round(results.overall_metrics.average_throughput, 2)} msg/s")
    Mix.shell().info("  Success Rate: #{Float.round(results.overall_metrics.success_rate, 1)}%")
    Mix.shell().info("  Total Errors: #{results.overall_metrics.total_errors}")
    
    Mix.shell().info("\nScenario Results:")
    Mix.shell().info(String.duplicate("-", 60))
    
    Enum.each(results.scenario_results, fn result ->
      throughput = result.metrics.messages_sent / (result.duration_ms / 1000)
      
      Mix.shell().info("#{result.scenario.name}:")
      Mix.shell().info("  Duration: #{result.duration_ms}ms")
      Mix.shell().info("  Messages: #{result.metrics.messages_sent}")
      Mix.shell().info("  Throughput: #{Float.round(throughput, 2)} msg/s")
      Mix.shell().info("  Avg Latency: #{result.metrics.average_latency}ms")
      Mix.shell().info("  Success: #{if result.success, do: "✓", else: "✗"}")
      Mix.shell().info("")
    end)
  end

  defp display_json_results(results) do
    json_output = Jason.encode!(results, pretty: true)
    Mix.shell().info(json_output)
  end

  defp display_csv_results(results) do
    Mix.shell().info("scenario,duration_ms,messages_sent,throughput_msg_s,avg_latency_ms,success")
    
    Enum.each(results.scenario_results, fn result ->
      throughput = result.metrics.messages_sent / (result.duration_ms / 1000)
      
      Mix.shell().info("#{result.scenario.name},#{result.duration_ms},#{result.metrics.messages_sent},#{Float.round(throughput, 2)},#{result.metrics.average_latency},#{result.success}")
    end)
  end

  defp save_metrics(results, filename) do
    json_output = Jason.encode!(results, pretty: true)
    File.write!(filename, json_output)
    Mix.shell().info("Metrics saved to #{filename}")
  end

  defp cleanup_test_environment(test_state) do
    Mix.shell().info("Cleaning up test environment...")
    
    # Leave cluster
    ExWire.DVT.CommunicationSupervisor.unconfigure_cluster(test_state.cluster_id)
    
    # Stop communication supervisor
    if Process.alive?(test_state.comm_supervisor) do
      GenServer.stop(test_state.comm_supervisor)
    end
    
    # Cleanup cluster state
    KeyManager.delete_cluster(test_state.cluster_id)
    
    Mix.shell().info("Cleanup completed")
  end

  defp generate_test_participants(cluster_size) do
    1..cluster_size
    |> Enum.map(fn node_id ->
      %{
        node_id: node_id,
        operator_id: "test_operator_#{node_id}",
        endpoint: "localhost:#{9000 + node_id - 1}",
        public_key: Base.encode64(:crypto.strong_rand_bytes(32))
      }
    end)
  end

  defp generate_topic_config(cluster_id) do
    %{
      "dvt/#{cluster_id}/consensus" => %{
        priority: :high,
        max_retries: 3,
        propagation_factor: 1.5,
        mesh_requirements: 6
      },
      "dvt/#{cluster_id}/slashing" => %{
        priority: :critical,
        max_retries: 5,
        propagation_factor: 2.0,
        mesh_requirements: 8
      },
      "dvt/#{cluster_id}/monitoring" => %{
        priority: :normal,
        max_retries: 2,
        propagation_factor: 1.0,
        mesh_requirements: 4
      }
    }
  end

  defp print_help do
    Mix.shell().info("""
    DVT Load Testing Framework

    Usage: mix dvt_load_test [options]

    Options:
      --cluster-size N        Number of DVT nodes (default: 5)
      --threshold N           Consensus threshold (default: 3)
      --duration N            Test duration in seconds (default: 300)
      --message-rate N        Messages per second (default: 100)
      --byzantine-nodes N     Number of Byzantine nodes (default: 0)
      --partition-test        Enable network partition testing
      --benchmark             Run performance benchmarks only
      --output-format FORMAT  Output format: table|json|csv (default: table)
      --metrics-file FILE     Save metrics to JSON file
      --help                  Show this help

    Examples:
      # Basic load test
      mix dvt_load_test --cluster-size 5 --duration 300

      # Stress test with faults  
      mix dvt_load_test --cluster-size 10 --byzantine-nodes 2 --partition-test

      # Performance benchmark
      mix dvt_load_test --benchmark --cluster-size 7 --threshold 5

      # Save detailed metrics
      mix dvt_load_test --duration 600 --metrics-file results.json
    """)
  end
end