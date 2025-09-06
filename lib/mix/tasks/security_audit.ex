defmodule Mix.Tasks.SecurityAudit do
  @moduledoc """
  Mix task to run comprehensive security audit on Mana Ethereum Client.

  ## Examples

      # Run full security audit
      mix security_audit

      # Audit specific components
      mix security_audit --components layer2,verkle

      # Generate HTML report
      mix security_audit --format html --output security_report.html

      # Run audit with verbose output
      mix security_audit --verbose

  ## Options

    * `--components` - Comma-separated list of components to audit (layer2, verkle, enterprise, core)
    * `--format` - Report format: markdown (default), json, html
    * `--output` - Output file path (default: prints to stdout)
    * `--verbose` - Enable verbose logging
    * `--severity` - Minimum severity level: critical, high, medium, low, info (default: info)
  """

  @shortdoc "Run security audit on Mana implementations"

  use Mix.Task

  require Logger

  alias Blockchain.Security.AuditFramework

  @impl Mix.Task
  def run(args) do
    # Start the application to ensure all modules are available
    Mix.Task.run("app.start")

    {opts, _} = OptionParser.parse!(args,
      strict: [
        components: :string,
        format: :string,
        output: :string,
        verbose: :boolean,
        severity: :string
      ]
    )

    # Configure logging
    if opts[:verbose] do
      Logger.configure(level: :debug)
    end

    # Parse components
    components = parse_components(opts[:components])
    
    # Parse severity filter
    min_severity = parse_severity(opts[:severity] || "info")

    # Parse format
    format = parse_format(opts[:format] || "markdown")

    Mix.Shell.IO.info("🔒 Starting Mana Security Audit...")
    Mix.Shell.IO.info("Components: #{inspect(components)}")
    Mix.Shell.IO.info("Format: #{format}")
    
    # Run the audit
    case AuditFramework.run_full_audit(components: components) do
      {:ok, report} ->
        # Filter findings by severity
        filtered_report = filter_report_by_severity(report, min_severity)
        
        # Generate report
        case AuditFramework.generate_report(filtered_report, format) do
          {:ok, report_content} ->
            # Output report
            output_report(report_content, opts[:output])
            
            # Print summary
            print_summary(filtered_report)
            
            # Exit with appropriate code
            exit_code = get_exit_code(filtered_report)
            if exit_code != 0 do
              Mix.Shell.IO.error("Security audit found issues. Exit code: #{exit_code}")
              System.halt(exit_code)
            else
              Mix.Shell.IO.info("✅ Security audit completed successfully!")
            end

          {:error, error} ->
            Mix.Shell.IO.error("Failed to generate report: #{inspect(error)}")
            System.halt(1)
        end

      {:error, error} ->
        Mix.Shell.IO.error("Security audit failed: #{inspect(error)}")
        System.halt(1)
    end
  end

  # Parse component list
  defp parse_components(nil), do: [:layer2, :verkle, :enterprise, :core]
  defp parse_components(components_str) do
    components_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
    |> Enum.filter(&(&1 in [:layer2, :verkle, :enterprise, :core]))
  end

  # Parse severity level
  defp parse_severity("critical"), do: :critical
  defp parse_severity("high"), do: :high
  defp parse_severity("medium"), do: :medium
  defp parse_severity("low"), do: :low
  defp parse_severity("info"), do: :info
  defp parse_severity(_), do: :info

  # Parse report format
  defp parse_format("json"), do: :json
  defp parse_format("html"), do: :html
  defp parse_format("markdown"), do: :markdown
  defp parse_format(_), do: :markdown

  # Filter report findings by minimum severity
  defp filter_report_by_severity(report, min_severity) do
    severity_order = [:critical, :high, :medium, :low, :info]
    min_index = Enum.find_index(severity_order, &(&1 == min_severity))
    
    allowed_severities = Enum.take(severity_order, min_index + 1)
    
    filtered_findings = Enum.filter(report.findings, &(&1.severity in allowed_severities))
    
    %{report | 
      findings: filtered_findings,
      summary: AuditFramework.generate_summary(filtered_findings)
    }
  end

  # Output report to file or stdout
  defp output_report(content, nil) do
    Mix.Shell.IO.info(content)
  end
  defp output_report(content, output_path) do
    File.write!(output_path, content)
    Mix.Shell.IO.info("Report saved to: #{output_path}")
  end

  # Print audit summary
  defp print_summary(report) do
    Mix.Shell.IO.info("\n" <> String.duplicate("=", 50))
    Mix.Shell.IO.info("🔒 SECURITY AUDIT SUMMARY")
    Mix.Shell.IO.info(String.duplicate("=", 50))
    
    Mix.Shell.IO.info("📊 Total Findings: #{report.summary.total_findings}")
    
    if report.summary.critical > 0 do
      Mix.Shell.IO.error("🔴 Critical: #{report.summary.critical}")
    end
    
    if report.summary.high > 0 do
      Mix.Shell.IO.error("🟠 High: #{report.summary.high}")
    end
    
    if report.summary.medium > 0 do
      Mix.Shell.IO.info("🟡 Medium: #{report.summary.medium}")
    end
    
    if report.summary.low > 0 do
      Mix.Shell.IO.info("🔵 Low: #{report.summary.low}")
    end
    
    if report.summary.info > 0 do
      Mix.Shell.IO.info("ℹ️  Info: #{report.summary.info}")
    end

    Mix.Shell.IO.info("\n📋 COMPLIANCE STATUS:")
    Mix.Shell.IO.info("Ethereum Security: #{if report.compliance_status.ethereum_security, do: "✅ PASS", else: "❌ FAIL"}")
    Mix.Shell.IO.info("Cryptographic Standards: #{if report.compliance_status.cryptographic_standards, do: "✅ PASS", else: "❌ FAIL"}")
    Mix.Shell.IO.info("Enterprise Requirements: #{if report.compliance_status.enterprise_requirements, do: "✅ PASS", else: "❌ FAIL"}")

    if length(report.recommendations) > 0 do
      Mix.Shell.IO.info("\n🔧 TOP RECOMMENDATIONS:")
      Enum.take(report.recommendations, 3)
      |> Enum.with_index(1)
      |> Enum.each(fn {rec, idx} ->
        Mix.Shell.IO.info("#{idx}. #{rec}")
      end)
    end
    
    Mix.Shell.IO.info(String.duplicate("=", 50))
  end

  # Determine exit code based on findings
  defp get_exit_code(report) do
    cond do
      report.summary.critical > 0 -> 3  # Critical issues found
      report.summary.high > 0 -> 2      # High severity issues found
      report.summary.medium > 0 -> 1    # Medium severity issues found
      true -> 0                         # No significant issues
    end
  end
end