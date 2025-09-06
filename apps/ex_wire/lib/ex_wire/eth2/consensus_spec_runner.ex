defmodule ExWire.Eth2.ConsensusSpecRunner do
  @moduledoc """
  Runner for official Ethereum Consensus Specification test suite.

  This module provides infrastructure to download, parse, and execute the official
  consensus spec tests from https://github.com/ethereum/consensus-spec-tests.

  Tests are organized by:
  - Fork/upgrade (phase0, altair, bellatrix, capella, deneb, etc.)
  - Test type (blocks, attestations, finality, fork_choice, etc.) 
  - Configuration (mainnet, minimal)

  Test format follows YAML specification with:
  - meta.yaml: Test metadata and configuration
  - Input data files (YAML/SSZ)
  - Expected output files
  """

  require Logger

  alias ExWire.Eth2.ConsensusSpecTests

  @consensus_tests_url "https://github.com/ethereum/consensus-spec-tests"
  @test_data_dir "test/fixtures/consensus_spec_tests"
  @supported_forks ~w(phase0 altair bellatrix capella deneb)a
  @supported_configs ~w(mainnet minimal)a

  defstruct [
    :test_suite,
    :fork,
    :config,
    :test_case,
    :metadata,
    :results,
    total_tests: 0,
    passed_tests: 0,
    failed_tests: 0,
    skipped_tests: 0,
    start_time: nil,
    end_time: nil
  ]

  @type t :: %__MODULE__{
          test_suite: String.t(),
          fork: atom(),
          config: atom(),
          test_case: String.t() | nil,
          metadata: map() | nil,
          results: list(),
          total_tests: non_neg_integer(),
          passed_tests: non_neg_integer(),
          failed_tests: non_neg_integer(),
          skipped_tests: non_neg_integer(),
          start_time: DateTime.t() | nil,
          end_time: DateTime.t() | nil
        }

  @doc """
  Download and setup consensus spec tests from official repository.
  """
  @spec setup_tests() :: {:ok, String.t()} | {:error, term()}
  def setup_tests do
    Logger.info("Setting up Ethereum Consensus Spec Tests...")

    case ensure_test_directory() do
      :ok ->
        download_tests()

      error ->
        error
    end
  end

  @doc """
  Run all supported consensus spec tests.
  """
  @spec run_all_tests(keyword()) :: {:ok, t()} | {:error, term()}
  def run_all_tests(opts \\ []) do
    forks = Keyword.get(opts, :forks, @supported_forks)
    configs = Keyword.get(opts, :configs, @supported_configs)
    test_suites = Keyword.get(opts, :test_suites, :all)

    runner = %__MODULE__{
      start_time: DateTime.utc_now(),
      results: []
    }

    Logger.info("Starting consensus spec tests for forks: #{inspect(forks)}")

    results =
      for fork <- forks,
          config <- configs do
        run_fork_tests(runner, fork, config, test_suites)
      end
      |> List.flatten()
      |> Enum.reduce(runner, &aggregate_results/2)

    final_results = %{results | end_time: DateTime.utc_now()}

    log_summary(final_results)
    {:ok, final_results}
  end

  @doc """
  Run tests for a specific fork and configuration.
  """
  @spec run_fork_tests(t(), atom(), atom(), atom() | list()) :: list()
  def run_fork_tests(runner, fork, config, test_suites) do
    test_dir = Path.join([@test_data_dir, to_string(fork), to_string(config)])

    if File.exists?(test_dir) do
      Logger.info("Running #{fork}/#{config} tests...")

      test_suites
      |> normalize_test_suites()
      |> Enum.flat_map(fn suite ->
        suite_dir = Path.join([test_dir, to_string(suite)])
        run_test_suite(runner, fork, config, suite, suite_dir)
      end)
    else
      Logger.warning("Test directory not found: #{test_dir}")
      []
    end
  end

  @doc """
  Run a specific test suite (e.g., finality, fork_choice, blocks).
  """
  @spec run_test_suite(t(), atom(), atom(), atom(), String.t()) :: list()
  def run_test_suite(runner, fork, config, suite, suite_dir) do
    if File.exists?(suite_dir) do
      Logger.debug("Running test suite: #{fork}/#{config}/#{suite}")

      test_cases = discover_test_cases(suite_dir)

      test_cases
      |> Enum.map(fn test_case ->
        run_test_case(
          %{runner | fork: fork, config: config, test_suite: to_string(suite)},
          test_case
        )
      end)
    else
      Logger.debug("Suite directory not found: #{suite_dir}")
      []
    end
  end

  @doc """
  Run a single test case.
  """
  @spec run_test_case(t(), String.t()) :: map()
  def run_test_case(runner, test_case_dir) do
    test_name = Path.basename(test_case_dir)

    Logger.debug("Running test case: #{test_name}")

    try do
      metadata = load_test_metadata(test_case_dir)
      test_data = load_test_data(test_case_dir, metadata)

      result = execute_test_case(runner.test_suite, test_data, metadata)

      %{
        test_case: test_name,
        fork: runner.fork,
        config: runner.config,
        test_suite: runner.test_suite,
        result: result.status,
        duration: result.duration,
        error: result.error,
        metadata: metadata
      }
    rescue
      error ->
        Logger.error("Test case failed with exception: #{test_name} - #{inspect(error)}")

        %{
          test_case: test_name,
          fork: runner.fork,
          config: runner.config,
          test_suite: runner.test_suite,
          result: :error,
          duration: 0,
          error: Exception.message(error),
          metadata: %{}
        }
    end
  end

  # Private functions

  defp ensure_test_directory do
    case File.mkdir_p(@test_data_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to create test directory: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp download_tests do
    # For now, we'll expect tests to be manually downloaded
    # In production, this could use Git or HTTP to fetch latest tests
    Logger.info("Please download consensus spec tests to #{@test_data_dir}")
    Logger.info("git clone #{@consensus_tests_url} #{@test_data_dir}")

    if File.exists?(@test_data_dir) do
      {:ok, @test_data_dir}
    else
      {:error, "Test directory not found. Please download consensus spec tests."}
    end
  end

  defp normalize_test_suites(:all) do
    ~w(finality fork_choice blocks attestations voluntary_exits deposits)a
  end

  defp normalize_test_suites(suites) when is_list(suites), do: suites
  defp normalize_test_suites(suite) when is_atom(suite), do: [suite]

  defp discover_test_cases(suite_dir) do
    suite_dir
    |> File.ls!()
    |> Enum.filter(fn item ->
      path = Path.join(suite_dir, item)
      File.dir?(path) and has_test_files?(path)
    end)
    |> Enum.map(&Path.join(suite_dir, &1))
    |> Enum.sort()
  end

  defp has_test_files?(dir) do
    File.exists?(Path.join(dir, "meta.yaml")) or
      File.ls!(dir) |> Enum.any?(fn f -> String.ends_with?(f, ".yaml") end)
  end

  defp load_test_metadata(test_case_dir) do
    meta_file = Path.join(test_case_dir, "meta.yaml")

    if File.exists?(meta_file) do
      meta_file
      |> File.read!()
      |> YamlElixir.read_from_string!()
    else
      %{}
    end
  end

  defp load_test_data(test_case_dir, metadata) do
    test_case_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".yaml"))
    |> Enum.into(%{}, fn file ->
      key = Path.rootname(file)

      content =
        test_case_dir
        |> Path.join(file)
        |> File.read!()
        |> YamlElixir.read_from_string!()

      {key, content}
    end)
    |> Map.put(:_metadata, metadata)
  end

  defp execute_test_case(suite, test_data, metadata) do
    start_time = System.monotonic_time(:millisecond)

    result =
      case suite do
        "finality" -> ConsensusSpecTests.run_finality_test(test_data)
        "fork_choice" -> ConsensusSpecTests.run_fork_choice_test(test_data)
        "blocks" -> ConsensusSpecTests.run_block_processing_test(test_data)
        "attestations" -> ConsensusSpecTests.run_attestation_test(test_data)
        "voluntary_exits" -> ConsensusSpecTests.run_voluntary_exit_test(test_data)
        "deposits" -> ConsensusSpecTests.run_deposit_test(test_data)
        _ -> {:skip, "Unsupported test suite: #{suite}"}
      end

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    case result do
      {:ok, _output} ->
        %{status: :pass, duration: duration, error: nil}

      {:error, reason} ->
        %{status: :fail, duration: duration, error: reason}

      {:skip, reason} ->
        %{status: :skip, duration: duration, error: reason}
    end
  end

  defp aggregate_results(test_result, runner) do
    new_totals =
      case test_result.result do
        :pass -> %{runner | passed_tests: runner.passed_tests + 1}
        :fail -> %{runner | failed_tests: runner.failed_tests + 1}
        :skip -> %{runner | skipped_tests: runner.skipped_tests + 1}
        :error -> %{runner | failed_tests: runner.failed_tests + 1}
      end

    %{
      new_totals
      | total_tests: new_totals.total_tests + 1,
        results: [test_result | new_totals.results]
    }
  end

  defp log_summary(results) do
    duration = DateTime.diff(results.end_time, results.start_time, :second)

    pass_rate =
      if results.total_tests > 0, do: results.passed_tests / results.total_tests * 100, else: 0.0

    Logger.info("""

    ==========================================
    Ethereum Consensus Spec Test Results
    ==========================================

    Total Tests:    #{results.total_tests}
    Passed:         #{results.passed_tests}
    Failed:         #{results.failed_tests}
    Skipped:        #{results.skipped_tests}
    Pass Rate:      #{:erlang.float_to_binary(pass_rate, decimals: 2)}%
    Duration:       #{duration}s

    ==========================================
    """)

    if results.failed_tests > 0 do
      failed_tests = Enum.filter(results.results, &(&1.result in [:fail, :error]))

      Logger.error("Failed Tests:")

      Enum.each(failed_tests, fn test ->
        Logger.error(
          "  - #{test.fork}/#{test.config}/#{test.test_suite}/#{test.test_case}: #{test.error}"
        )
      end)
    end
  end
end
