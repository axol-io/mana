defmodule Mix.Tasks.ConsensusSpec do
  @moduledoc """
  Mix task for running Ethereum Consensus Specification tests.

  This task downloads, sets up, and executes the official Ethereum consensus 
  specification test suite to ensure 100% compliance with the Ethereum 
  proof-of-stake consensus protocol.

  ## Usage

      # Run all consensus spec tests  
      mix consensus_spec
      
      # Run tests for specific fork
      mix consensus_spec --fork phase0
      
      # Run tests for specific configuration
      mix consensus_spec --config minimal
      
      # Run specific test suite
      mix consensus_spec --suite finality
      
      # Run tests and generate detailed report
      mix consensus_spec --report detailed
      
      # Setup test data (downloads consensus spec tests)
      mix consensus_spec --setup
      
  ## Options

    * `--fork` - Specific fork to test (phase0, altair, bellatrix, capella, deneb)
    * `--config` - Configuration to test (mainnet, minimal)  
    * `--suite` - Test suite to run (finality, fork_choice, blocks, attestations, etc.)
    * `--report` - Report format (summary, detailed, json, junit)
    * `--setup` - Download and setup consensus spec test data
    * `--output` - Output directory for reports (default: test/results)
    * `--verbose` - Enable verbose logging
    
  ## Examples

      # Test Phase 0 mainnet finality
      mix consensus_spec --fork phase0 --config mainnet --suite finality
      
      # Run all Altair tests with detailed reporting  
      mix consensus_spec --fork altair --report detailed
      
      # Generate CI-compatible test report
      mix consensus_spec --report junit --output reports/
      
  """

  use Mix.Task

  require Logger

  alias ExWire.Eth2.ConsensusSpecRunner

  @shortdoc "Run Ethereum Consensus Specification tests"

  @switches [
    fork: :string,
    config: :string,
    suite: :string,
    report: :string,
    setup: :boolean,
    output: :string,
    verbose: :boolean,
    help: :boolean
  ]

  @aliases [
    f: :fork,
    c: :config,
    s: :suite,
    r: :report,
    o: :output,
    v: :verbose,
    h: :help
  ]

  def run(args) do
    {opts, _args} = OptionParser.parse!(args, switches: @switches, aliases: @aliases)

    if opts[:help] do
      print_help()
    else
      execute_task(opts)
    end
  end

  defp execute_task(opts) do
    # Ensure the application is started for proper logging
    Application.ensure_all_started(:ex_wire)

    if opts[:verbose] do
      Logger.configure(level: :debug)
    end

    Logger.info("🔍 Ethereum Consensus Spec Test Runner")
    Logger.info("=====================================")

    cond do
      opts[:setup] ->
        setup_consensus_tests()

      true ->
        run_consensus_tests(opts)
    end
  end

  defp setup_consensus_tests do
    Logger.info("Setting up consensus spec tests...")

    case ConsensusSpecRunner.setup_tests() do
      {:ok, test_dir} ->
        Logger.info("✅ Consensus spec tests ready at: #{test_dir}")
        Logger.info("💡 You can now run: mix consensus_spec")

      {:error, _reason} ->
        Logger.error("❌ Failed to setup consensus spec tests: #{reason}")
        Logger.info("Manual setup:")

        Logger.info(
          "  git clone https://github.com/ethereum/consensus-spec-tests test/fixtures/consensus_spec_tests"
        )

        System.halt(1)
    end
  end

  defp run_consensus_tests(opts) do
    # Parse options into test parameters
    test_opts = []
    test_opts = maybe_add_option(test_opts, :forks, parse_fork_option(opts[:fork]))
    test_opts = maybe_add_option(test_opts, :configs, parse_config_option(opts[:config]))
    test_opts = maybe_add_option(test_opts, :test_suites, parse_suite_option(opts[:suite]))

    Logger.info("Running consensus spec tests...")
    Logger.info("Options: #{inspect(test_opts)}")

    case ConsensusSpecRunner.run_all_tests(test_opts) do
      {:ok, results} ->
        generate_reports(results, opts)

        if results.failed_tests > 0 do
          Logger.error("❌ #{results.failed_tests} tests failed")
          System.halt(1)
        else
          Logger.info("✅ All tests passed!")
        end

      {:error, _reason} ->
        Logger.error("❌ Test run failed: #{reason}")
        System.halt(1)
    end
  end

  defp parse_fork_option(nil), do: nil

  defp parse_fork_option(fork_str) do
    fork = String.to_atom(fork_str)
    supported_forks = ~w(phase0 altair bellatrix capella deneb)a

    if fork in supported_forks do
      [fork]
    else
      Logger.error("Unsupported fork: #{fork_str}. Supported: #{inspect(supported_forks)}")
      System.halt(1)
    end
  end

  defp parse_config_option(nil), do: nil

  defp parse_config_option(config_str) do
    config = String.to_atom(config_str)
    supported_configs = ~w(mainnet minimal)a

    if config in supported_configs do
      [config]
    else
      Logger.error("Unsupported config: #{config_str}. Supported: #{inspect(supported_configs)}")
      System.halt(1)
    end
  end

  defp parse_suite_option(nil), do: :all

  defp parse_suite_option(suite_str) do
    suite = String.to_atom(suite_str)
    supported_suites = ~w(finality fork_choice blocks attestations voluntary_exits deposits)a

    if suite in supported_suites do
      [suite]
    else
      Logger.error("Unsupported suite: #{suite_str}. Supported: #{inspect(supported_suites)}")
      System.halt(1)
    end
  end

  defp maybe_add_option(opts, _key, nil), do: opts
  defp maybe_add_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp generate_reports(results, opts) do
    report_format = opts[:report] || "summary"
    output_dir = opts[:output] || "test/results"

    File.mkdir_p!(output_dir)

    case report_format do
      "summary" ->
        # Summary already logged by ConsensusSpecRunner
        :ok

      "detailed" ->
        generate_detailed_report(results, output_dir)

      "json" ->
        generate_json_report(results, output_dir)

      "junit" ->
        generate_junit_report(results, output_dir)

      _ ->
        Logger.warning("Unknown report format: #{report_format}")
    end
  end

  defp generate_detailed_report(results, output_dir) do
    report_file = Path.join(output_dir, "consensus_spec_detailed_report.txt")

    report_content = """
    Ethereum Consensus Spec Test Results - Detailed Report
    =====================================================

    Execution Time: #{DateTime.to_iso8601(results.start_time)} - #{DateTime.to_iso8601(results.end_time)}
    Total Duration: #{DateTime.diff(results.end_time, results.start_time)}s

    Summary:
    --------
    Total Tests:     #{results.total_tests}
    Passed:          #{results.passed_tests}
    Failed:          #{results.failed_tests} 
    Skipped:         #{results.skipped_tests}
    Pass Rate:       #{if results.total_tests > 0, do: Float.round(results.passed_tests / results.total_tests * 100, 2), else: 0}%

    Test Results by Fork/Config/Suite:
    ----------------------------------
    #{format_results_by_category(results.results)}

    #{if results.failed_tests > 0, do: format_failed_tests(results.results), else: ""}
    """

    File.write!(report_file, report_content)
    Logger.info("📄 Detailed report written to: #{report_file}")
  end

  defp generate_json_report(results, output_dir) do
    report_file = Path.join(output_dir, "consensus_spec_results.json")

    json_data = %{
      summary: %{
        total_tests: results.total_tests,
        passed_tests: results.passed_tests,
        failed_tests: results.failed_tests,
        skipped_tests: results.skipped_tests,
        pass_rate:
          if(results.total_tests > 0,
            do: results.passed_tests / results.total_tests * 100,
            else: 0
          ),
        start_time: DateTime.to_iso8601(results.start_time),
        end_time: DateTime.to_iso8601(results.end_time),
        duration: DateTime.diff(results.end_time, results.start_time)
      },
      tests: results.results
    }

    File.write!(report_file, Jason.encode!(json_data, pretty: true))
    Logger.info("📊 JSON report written to: #{report_file}")
  end

  defp generate_junit_report(results, output_dir) do
    report_file = Path.join(output_dir, "consensus_spec_junit.xml")

    duration = DateTime.diff(results.end_time, results.start_time)

    junit_xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <testsuites name="Ethereum Consensus Spec Tests" 
                tests="#{results.total_tests}" 
                failures="#{results.failed_tests}"
                skipped="#{results.skipped_tests}"
                time="#{duration}">
    #{format_junit_testsuites(results.results)}
    </testsuites>
    """

    File.write!(report_file, junit_xml)
    Logger.info("🧪 JUnit report written to: #{report_file}")
  end

  defp format_results_by_category(results) do
    results
    |> Enum.group_by(fn test -> "#{test.fork}/#{test.config}/#{test.test_suite}" end)
    |> Enum.map(fn {category, tests} ->
      total = length(tests)
      passed = Enum.count(tests, &(&1.result == :pass))
      failed = Enum.count(tests, &(&1.result == :fail))
      skipped = Enum.count(tests, &(&1.result == :skip))

      "#{category}: #{passed}/#{total} passed, #{failed} failed, #{skipped} skipped"
    end)
    |> Enum.join("\n")
  end

  defp format_failed_tests(results) do
    failed_tests = Enum.filter(results, &(&1.result in [:fail, :error]))

    if length(failed_tests) > 0 do
      """

      Failed Tests:
      -------------
      #{Enum.map_join(failed_tests, "\n", fn test -> "❌ #{test.fork}/#{test.config}/#{test.test_suite}/#{test.test_case}: #{test.error}" end)}
      """
    else
      ""
    end
  end

  defp format_junit_testsuites(results) do
    results
    |> Enum.group_by(fn test -> "#{test.fork}.#{test.config}.#{test.test_suite}" end)
    |> Enum.map(fn {suite_name, tests} ->
      total = length(tests)
      failures = Enum.count(tests, &(&1.result in [:fail, :error]))
      skipped = Enum.count(tests, &(&1.result == :skip))
      # Convert to seconds
      time = Enum.sum(Enum.map(tests, & &1.duration)) / 1000.0

      """
        <testsuite name="#{suite_name}" tests="#{total}" failures="#{failures}" skipped="#{skipped}" time="#{time}">
      #{format_junit_testcases(tests)}
        </testsuite>
      """
    end)
    |> Enum.join("\n")
  end

  defp format_junit_testcases(tests) do
    tests
    |> Enum.map(fn test ->
      time = test.duration / 1000.0

      case test.result do
        :pass ->
          "    <testcase name=\"#{test.test_case}\" time=\"#{time}\"/>"

        :fail ->
          """
          <testcase name="#{test.test_case}" time="#{time}">
            <failure message="#{test.error}">#{test.error}</failure>
          </testcase>
          """

        :skip ->
          """
          <testcase name="#{test.test_case}" time="#{time}">
            <skipped message="#{test.error}">#{test.error}</skipped>
          </testcase>
          """

        :error ->
          """
          <testcase name="#{test.test_case}" time="#{time}">
            <error message="#{test.error}">#{test.error}</error>
          </testcase>
          """
      end
    end)
    |> Enum.join("\n    ")
  end

  defp print_help do
    IO.puts(@moduledoc)
  end
end
