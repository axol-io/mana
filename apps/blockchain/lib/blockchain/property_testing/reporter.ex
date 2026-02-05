defmodule Blockchain.PropertyTesting.Reporter do
  @moduledoc """
  Generates reports for property testing results in various formats.

  This module provides functionality to generate test reports in JSON and JUnit XML
  formats for CI/CD integration and test result tracking.
  """

  @doc """
  Generates a JSON report from property test results.

  ## Parameters
  - `summary` - Map containing test summary with fields:
    - `:timestamp` - Test run timestamp
    - `:duration_ms` - Total duration in milliseconds
    - `:total_modules` - Number of test modules
    - `:total_tests` - Total number of tests
    - `:total_passed` - Number of passed tests
    - `:total_failed` - Number of failed tests
    - `:total_errors` - Number of errors
    - `:success_rate` - Success rate (0.0-1.0)
    - `:counterexamples` - List of counterexamples found
    - `:module_results` - List of per-module results
  - `config` - Configuration map with `:output_dir` and other options

  ## Returns
  `:ok` on success, `{:error, reason}` on failure
  """
  def generate_json_report(summary, config) do
    output_dir = config[:output_dir] || "test_results"
    output_path = Path.join(output_dir, "property_test_report.json")

    File.mkdir_p!(output_dir)

    json_data = %{
      timestamp: DateTime.to_iso8601(summary.timestamp),
      duration_ms: summary.duration_ms,
      total_modules: summary.total_modules,
      total_tests: summary.total_tests,
      total_passed: summary.total_passed,
      total_failed: summary.total_failed,
      total_errors: summary.total_errors,
      success_rate: summary.success_rate,
      counterexamples: summary.counterexamples,
      module_results:
        Enum.map(summary.module_results, fn module_result ->
          %{
            module: Atom.to_string(module_result.module),
            duration_ms: module_result.duration_ms,
            test_count: module_result.test_count,
            passed: module_result.passed,
            failed: module_result.failed,
            errors: module_result.errors
          }
        end)
    }

    case Jason.encode(json_data, pretty: true) do
      {:ok, json_string} ->
        File.write!(output_path, json_string)
        :ok

      {:error, reason} ->
        # Fallback if Jason is not available
        File.write!(output_path, inspect(json_data, pretty: true))
        :ok
    end
  rescue
    error ->
      IO.puts("Warning: Failed to generate JSON report: #{inspect(error)}")
      :ok
  end

  @doc """
  Generates a JUnit XML report from property test results.

  JUnit format is widely supported by CI/CD systems for test result reporting.

  ## Parameters
  - `summary` - Map containing test summary (same structure as `generate_json_report/2`)
  - `config` - Configuration map with `:output_dir` and other options

  ## Returns
  `:ok` on success, `{:error, reason}` on failure
  """
  def generate_junit_report(summary, config) do
    output_dir = config[:output_dir] || "test_results"
    output_path = Path.join(output_dir, "property_test_junit.xml")

    File.mkdir_p!(output_dir)

    # Generate JUnit XML format
    xml_content = """
    <?xml version="1.0" encoding="UTF-8"?>
    <testsuites name="Property Tests" tests="#{summary.total_tests}" failures="#{summary.total_failed}" errors="#{summary.total_errors}" time="#{summary.duration_ms / 1000}">
    #{generate_testsuites(summary.module_results)}
    </testsuites>
    """

    File.write!(output_path, xml_content)
    :ok
  rescue
    error ->
      IO.puts("Warning: Failed to generate JUnit report: #{inspect(error)}")
      :ok
  end

  # Private helper functions

  defp generate_testsuites(module_results) do
    Enum.map_join(module_results, "\n", fn module_result ->
      module_name = Atom.to_string(module_result.module)
      test_count = module_result.test_count
      failures = module_result.failed
      errors = module_result.errors
      time = module_result.duration_ms / 1000

      """
        <testsuite name="#{escape_xml(module_name)}" tests="#{test_count}" failures="#{failures}" errors="#{errors}" time="#{time}">
      #{generate_testcases(module_result)}
        </testsuite>
      """
    end)
  end

  defp generate_testcases(module_result) do
    # Generate placeholder test cases since we don't have detailed test results
    test_results = module_result[:test_results] || []

    if Enum.empty?(test_results) do
      # Generate summary entries
      passed_count = module_result.passed
      failed_count = module_result.failed

      passed_cases =
        if passed_count > 0 do
          """
              <testcase name="property_tests_passed" classname="#{module_result.module}" time="#{module_result.duration_ms / 1000 / module_result.test_count}">
                <!-- #{passed_count} property tests passed -->
              </testcase>
          """
        else
          ""
        end

      failed_cases =
        if failed_count > 0 do
          """
              <testcase name="property_tests_failed" classname="#{module_result.module}" time="0">
                <failure message="#{failed_count} property tests failed" type="PropertyTestFailure">
                  #{failed_count} tests failed. See detailed logs for counterexamples.
                </failure>
              </testcase>
          """
        else
          ""
        end

      passed_cases <> failed_cases
    else
      # Generate detailed test case entries if available
      Enum.map_join(test_results, "\n", fn test_result ->
        """
            <testcase name="#{escape_xml(test_result[:name] || "unknown")}" classname="#{module_result.module}" time="#{test_result[:duration_ms] || 0}">
        #{if test_result[:status] == :failed do
          """
              <failure message="#{escape_xml(test_result[:message] || "Test failed")}" type="PropertyTestFailure">
                #{escape_xml(test_result[:details] || "")}
              </failure>
          """
        end}
            </testcase>
        """
      end)
    end
  end

  defp escape_xml(string) when is_binary(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape_xml(other), do: inspect(other)
end
