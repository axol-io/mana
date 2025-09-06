defmodule Mix.Tasks.LoadTest do
  @moduledoc """
  Run mainnet-scale load tests on Mana Ethereum client.
  
  ## Usage
  
      mix load_test                    # Run default test suite
      mix load_test --scenario mainnet # Run specific scenario
      mix load_test --duration 300     # Run for 5 minutes
      mix load_test --config path.json # Use custom configuration
      mix load_test --report           # Generate detailed report
  
  ## Scenarios
  
    * `baseline` - Establish baseline performance metrics
    * `mainnet` - Simulate mainnet conditions
    * `stress` - Find system breaking points  
    * `edge` - Test edge cases and error handling
    * `network` - Test network resilience
    * `layer2` - Test Layer 2 systems
    * `full` - Run complete test suite
  
  ## Options
  
    * `--scenario` - Test scenario to run (default: full)
    * `--duration` - Test duration in seconds (default: 60)
    * `--accounts` - Number of test accounts (default: 1000)
    * `--tps` - Target transactions per second (default: 15)
    * `--config` - Path to JSON config file
    * `--output` - Output directory for results (default: ./load_test_results)
    * `--prometheus` - Enable Prometheus metrics export
    * `--report` - Generate HTML report after test
    * `--verbose` - Enable verbose logging
  """

  use Mix.Task
  alias ExWire.LoadTest.Framework
  alias ExWire.LoadTest.MetricsCollector
  
  @shortdoc "Run mainnet-scale load tests"
  
  @default_config %{
    scenario: "full",
    duration: 60,
    accounts: 1000,
    target_tps: 15,
    output_dir: "./load_test_results",
    prometheus: true,
    report: true,
    verbose: false
  }

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, 
      switches: [
        scenario: :string,
        duration: :integer,
        accounts: :integer,
        tps: :integer,
        config: :string,
        output: :string,
        prometheus: :boolean,
        report: :boolean,
        verbose: :boolean,
        help: :boolean
      ],
      aliases: [
        s: :scenario,
        d: :duration,
        a: :accounts,
        t: :tps,
        c: :config,
        o: :output,
        p: :prometheus,
        r: :report,
        v: :verbose,
        h: :help
      ]
    )
    
    if opts[:help] do
      Mix.shell().info(@moduledoc)
      System.halt(0)
    end
    
    config = build_config(opts)
    
    Mix.shell().info("""
    
    ========================================
    MANA ETHEREUM LOAD TEST
    ========================================
    Scenario: #{config.scenario}
    Duration: #{config.duration}s
    Accounts: #{config.accounts}
    Target TPS: #{config.target_tps}
    Output: #{config.output_dir}
    ========================================
    
    Starting test...
    """)
    
    # Ensure application is started
    {:ok, _} = Application.ensure_all_started(:ex_wire)
    
    # Start metrics collector
    {:ok, _} = MetricsCollector.start_link()
    
    # Create output directory
    File.mkdir_p!(config.output_dir)
    
    # Run the appropriate scenario
    results = run_scenario(config)
    
    # Save results
    save_results(config, results)
    
    # Generate report if requested
    if config.report do
      generate_report(config, results)
    end
    
    # Print summary
    print_summary(results)
    
    Mix.shell().info("\nLoad test completed successfully!")
  end

  defp build_config(opts) do
    base_config = if opts[:config] do
      load_config_file(opts[:config])
    else
      @default_config
    end
    
    Map.merge(base_config, %{
      scenario: opts[:scenario] || base_config.scenario,
      duration: opts[:duration] || base_config.duration,
      accounts: opts[:accounts] || base_config.accounts,
      target_tps: opts[:tps] || base_config.target_tps,
      output_dir: opts[:output] || base_config.output_dir,
      prometheus: Keyword.get(opts, :prometheus, base_config.prometheus),
      report: Keyword.get(opts, :report, base_config.report),
      verbose: Keyword.get(opts, :verbose, base_config.verbose)
    })
  end

  defp load_config_file(path) do
    case File.read(path) do
      {:ok, content} ->
        Jason.decode!(content, keys: :atoms)
      
      {:error, reason} ->
        Mix.raise("Failed to load config file: #{reason}")
    end
  end

  defp run_scenario(config) do
    case config.scenario do
      "baseline" ->
        Framework.run_baseline_test(config)
      
      "mainnet" ->
        Framework.run_mainnet_simulation(config)
      
      "stress" ->
        Framework.run_stress_test(config)
      
      "edge" ->
        Framework.run_edge_case_tests(config)
      
      "network" ->
        Framework.run_network_resilience_test(config)
      
      "layer2" ->
        Framework.run_layer2_load_test(config)
      
      "full" ->
        Framework.run_full_suite(
          duration: config.duration,
          accounts: config.accounts
        )
      
      scenario ->
        Mix.raise("Unknown scenario: #{scenario}")
    end
  end

  defp save_results(config, results) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    
    # Save JSON results
    json_path = Path.join(config.output_dir, "results_#{timestamp}.json")
    json_content = Jason.encode!(results, pretty: true)
    File.write!(json_path, json_content)
    
    Mix.shell().info("Results saved to: #{json_path}")
    
    # Save metrics if available
    if is_map(results) && Map.has_key?(results, :metrics) do
      metrics_path = Path.join(config.output_dir, "metrics_#{timestamp}.txt")
      save_metrics(metrics_path, results.metrics)
    end
  end

  defp save_metrics(path, metrics) do
    content = format_metrics(metrics)
    File.write!(path, content)
    Mix.shell().info("Metrics saved to: #{path}")
  end

  defp format_metrics(metrics) do
    """
    Load Test Metrics
    =================
    
    Transactions:
    - Sent: #{metrics[:transactions_sent] || 0}
    - Confirmed: #{metrics[:transactions_confirmed] || 0}
    - Failed: #{metrics[:transactions_failed] || 0}
    
    Performance:
    - Peak TPS: #{metrics[:peak_tps] || 0}
    - Avg Gas Used: #{metrics[:avg_gas_used] || 0}
    - Avg Block Time: #{metrics[:avg_block_time] || 0}ms
    
    Latency:
    - P50: #{get_in(metrics, [:latency_percentiles, :p50]) || 0}ms
    - P95: #{get_in(metrics, [:latency_percentiles, :p95]) || 0}ms
    - P99: #{get_in(metrics, [:latency_percentiles, :p99]) || 0}ms
    """
  end

  defp generate_report(config, results) do
    html_path = Path.join(config.output_dir, "report_#{timestamp_string()}.html")
    html_content = generate_html_report(results)
    File.write!(html_path, html_content)
    
    Mix.shell().info("HTML report generated: #{html_path}")
    
    # Open in browser if available
    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [html_path])
      {:unix, _} -> System.cmd("xdg-open", [html_path])
      _ -> :ok
    end
  end

  defp generate_html_report(results) do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>Mana Load Test Report</title>
      <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .header { background: #2c3e50; color: white; padding: 20px; border-radius: 5px; }
        .metric-card { background: white; padding: 15px; margin: 10px 0; border-radius: 5px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .metric-title { font-weight: bold; color: #34495e; }
        .metric-value { font-size: 24px; color: #27ae60; }
        .warning { color: #e74c3c; }
        .chart { margin: 20px 0; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 10px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background: #ecf0f1; }
      </style>
    </head>
    <body>
      <div class="header">
        <h1>Mana Ethereum Load Test Report</h1>
        <p>Generated: #{DateTime.utc_now()}</p>
      </div>
      
      #{format_html_results(results)}
    </body>
    </html>
    """
  end

  defp format_html_results(results) when is_map(results) do
    sections = []
    
    # Add baseline results if present
    if Map.has_key?(results, :baseline) do
      sections = sections ++ [format_baseline_html(results.baseline)]
    end
    
    # Add mainnet simulation if present
    if Map.has_key?(results, :mainnet_simulation) do
      sections = sections ++ [format_mainnet_html(results.mainnet_simulation)]
    end
    
    # Add stress test results if present
    if Map.has_key?(results, :stress_test) do
      sections = sections ++ [format_stress_html(results.stress_test)]
    end
    
    Enum.join(sections, "\n")
  end
  
  defp format_html_results(_), do: "<p>No detailed results available</p>"

  defp format_baseline_html(baseline) do
    """
    <div class="metric-card">
      <h2>Baseline Performance</h2>
      <div class="metric-title">Transactions Per Second</div>
      <div class="metric-value">#{Float.round(baseline[:tps] || 0, 2)}</div>
      <div class="metric-title">Average Gas Used</div>
      <div class="metric-value">#{baseline[:avg_gas_used] || 0}</div>
    </div>
    """
  end

  defp format_mainnet_html(mainnet) do
    """
    <div class="metric-card">
      <h2>Mainnet Simulation</h2>
      <table>
        <tr><th>Metric</th><th>Value</th></tr>
        <tr><td>Duration</td><td>#{mainnet[:duration_seconds] || 0}s</td></tr>
        <tr><td>Blocks Produced</td><td>#{mainnet[:blocks_produced] || 0}</td></tr>
        <tr><td>Transactions</td><td>#{mainnet[:transactions_processed] || 0}</td></tr>
        <tr><td>Average TPS</td><td>#{Float.round(mainnet[:avg_tps] || 0, 2)}</td></tr>
        <tr><td>Average Block Time</td><td>#{Float.round(mainnet[:avg_block_time] || 0, 2)}s</td></tr>
      </table>
    </div>
    """
  end

  defp format_stress_html(stress) do
    """
    <div class="metric-card">
      <h2>Stress Test Results</h2>
      <table>
        <tr><th>Test</th><th>Breaking Point</th></tr>
        #{format_stress_results_html(stress[:results] || %{})}
      </table>
    </div>
    """
  end

  defp format_stress_results_html(results) do
    Enum.map(results, fn {test, result} ->
      breaking_point = if is_map(result) do
        result[:breaking_point] || "N/A"
      else
        "N/A"
      end
      "<tr><td>#{test}</td><td>#{breaking_point}</td></tr>"
    end) |> Enum.join("\n")
  end

  defp print_summary(results) when is_map(results) do
    Mix.shell().info("""
    
    ========================================
    LOAD TEST SUMMARY
    ========================================
    """)
    
    # Print scenario-specific summaries
    if baseline = results[:baseline] do
      Mix.shell().info("Baseline TPS: #{Float.round(baseline[:tps] || 0, 2)}")
    end
    
    if mainnet = results[:mainnet_simulation] do
      Mix.shell().info("Mainnet Avg TPS: #{Float.round(mainnet[:avg_tps] || 0, 2)}")
      Mix.shell().info("Blocks Produced: #{mainnet[:blocks_produced] || 0}")
    end
    
    if stress = results[:stress_test] do
      Mix.shell().info("Stress Tests Run: #{map_size(stress[:results] || %{})}")
    end
    
    Mix.shell().info("========================================")
  end
  
  defp print_summary(results) do
    Mix.shell().info("Results: #{inspect(results)}")
  end

  defp timestamp_string do
    DateTime.utc_now()
    |> DateTime.to_string()
    |> String.replace(~r/[^0-9]/, "_")
  end
end