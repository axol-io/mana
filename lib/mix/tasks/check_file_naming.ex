defmodule Mix.Tasks.CheckFileNaming do
  @moduledoc """
  Validates file naming conventions to prevent AI-generated generic names.
  
  Checks for common AI-generated patterns like:
  - simple_*, comprehensive_*, optimized_*, enhanced_*, advanced_*
  - basic_*, improved_*, extended_*, generic_*, default_*
  - *_helper (except in test/support), *_utils, *_misc
  
  Usage:
      mix check_file_naming
      mix check_file_naming --strict  # Fail on any violations
  """
  
  use Mix.Task
  
  @shortdoc "Check for AI-generated or generic file names"
  
  # Patterns that indicate AI-generated or generic naming
  @ai_patterns [
    ~r/simple_/,
    ~r/comprehensive_/,
    ~r/optimized_/,
    ~r/enhanced_/,
    ~r/advanced_/,
    ~r/basic_/,
    ~r/improved_/,
    ~r/extended_/,
    ~r/generic_/,
    ~r/default_/,
    ~r/_helper\.exs?$/,  # _helper files outside test/support
    ~r/_helpers\.exs?$/,
    ~r/_util\.exs?$/,
    ~r/_utils\.exs?$/,
    ~r/_misc\.exs?$/,
    ~r/_common\.exs?$/,  # _common files (should use specific names)
    ~r/temp_/,
    ~r/tmp_/,
    ~r/test_(?!.*test\.exs?$)/,  # test_ prefix outside actual test files
    ~r/new_/,
    ~r/old_/
  ]
  
  # Allowed exceptions (files that can have generic names)
  @exceptions [
    # Test support files are OK
    ~r|test/support/.*_helper\.exs?$|,
    ~r|test/.*_helper\.exs?$|,
    # Mix tasks can have generic names
    ~r|lib/mix/tasks/|,
    # Scripts can be more flexible
    ~r|scripts/|,
    # Benchmark files can have simple names
    ~r|bench/.*simple_benchmark\.exs?$|,
    # Dependencies are not under our control
    ~r|deps/|,
    ~r|_build/|,
    # Config files have standard names
    ~r|config/|,
    # Documentation can have generic names
    ~r|docs/|
  ]
  
  @spec run([String.t()]) :: :ok
  def run(args) do
    {options, _, _} = OptionParser.parse(args, switches: [strict: :boolean])
    strict_mode = Keyword.get(options, :strict, false)
    
    violations = find_naming_violations()
    
    if violations == [] do
      Mix.shell().info("✅ No file naming violations found!")
      :ok
    else
      display_violations(violations, strict_mode)
      
      if strict_mode do
        Mix.shell().error("❌ File naming violations found in strict mode!")
        System.halt(1)
      else
        Mix.shell().info("⚠️  File naming violations found (run with --strict to fail CI)")
        :ok
      end
    end
  end
  
  defp find_naming_violations do
    project_files()
    |> Enum.filter(&matches_ai_pattern?/1)
    |> Enum.reject(&is_exception?/1)
    |> Enum.map(&analyze_violation/1)
  end
  
  defp project_files do
    Path.wildcard("**/*.{ex,exs}")
    |> Enum.reject(&String.contains?(&1, "_build"))
    |> Enum.reject(&String.contains?(&1, "deps"))
  end
  
  defp matches_ai_pattern?(file_path) do
    filename = Path.basename(file_path)
    
    Enum.any?(@ai_patterns, fn pattern ->
      Regex.match?(pattern, filename)
    end)
  end
  
  defp is_exception?(file_path) do
    Enum.any?(@exceptions, fn pattern ->
      Regex.match?(pattern, file_path)
    end)
  end
  
  defp analyze_violation(file_path) do
    filename = Path.basename(file_path)
    directory = Path.dirname(file_path)
    
    matched_patterns = 
      @ai_patterns
      |> Enum.filter(fn pattern -> Regex.match?(pattern, filename) end)
      |> Enum.map(&Regex.source/1)
    
    suggestions = generate_suggestions(file_path, filename)
    
    %{
      file: file_path,
      filename: filename,
      directory: directory,
      matched_patterns: matched_patterns,
      suggestions: suggestions,
      severity: determine_severity(filename)
    }
  end
  
  defp generate_suggestions(file_path, filename) do
    cond do
      String.contains?(filename, "simple_") ->
        suggest_specific_name(file_path, "simple_", "Consider: specific_feature_name.ex")
        
      String.contains?(filename, "optimized_") ->
        suggest_specific_name(file_path, "optimized_", "Consider: feature_name_cache.ex or feature_name_fast.ex")
        
      String.contains?(filename, "enhanced_") ->
        suggest_specific_name(file_path, "enhanced_", "Consider: feature_name_v2.ex or feature_name_extended.ex")
        
      String.contains?(filename, "comprehensive_") ->
        suggest_specific_name(file_path, "comprehensive_", "Consider: feature_name_full.ex or feature_name_complete.ex")
        
      String.contains?(filename, "_helper") ->
        "Consider: specific_feature_support.ex or feature_name_utilities.ex"
        
      String.contains?(filename, "_util") ->
        "Consider: feature_name_tools.ex or specific_operations.ex"
        
      true ->
        "Use a more specific name that describes the actual purpose"
    end
  end
  
  defp suggest_specific_name(file_path, pattern, default_suggestion) do
    # Try to infer a better name from the directory structure
    parts = Path.split(file_path)
    
    domain = 
      parts
      |> Enum.find(fn part -> 
        part in ["blockchain", "evm", "ex_wire", "merkle_patricia_tree", "jsonrpc2"]
      end)
    
    if domain do
      "Consider: #{domain}_specific_feature.ex or #{default_suggestion}"
    else
      default_suggestion
    end
  end
  
  defp determine_severity(filename) do
    cond do
      String.contains?(filename, "simple_") or String.contains?(filename, "basic_") ->
        :high
        
      String.contains?(filename, "comprehensive_") or String.contains?(filename, "advanced_") ->
        :high
        
      String.contains?(filename, "optimized_") or String.contains?(filename, "enhanced_") ->
        :medium
        
      String.contains?(filename, "_helper") or String.contains?(filename, "_util") ->
        :medium
        
      true ->
        :low
    end
  end
  
  defp display_violations(violations, strict_mode) do
    Mix.shell().info("\n🤖 File Naming Convention Violations Found:")
    Mix.shell().info("=" |> String.duplicate(60))
    
    violations
    |> Enum.sort_by(& &1.severity, fn a, b ->
      severity_order(a) <= severity_order(b)
    end)
    |> Enum.each(&display_violation/1)
    
    Mix.shell().info("")
    Mix.shell().info("📋 Summary:")
    Mix.shell().info("- Total violations: #{length(violations)}")
    
    by_severity = Enum.group_by(violations, & &1.severity)
    Enum.each([:high, :medium, :low], fn severity ->
      count = length(by_severity[severity] || [])
      if count > 0 do
        Mix.shell().info("- #{String.capitalize(to_string(severity))} priority: #{count}")
      end
    end)
    
    Mix.shell().info("")
    Mix.shell().info("💡 Naming Convention Guidelines:")
    Mix.shell().info("- Use specific, descriptive names that explain purpose")
    Mix.shell().info("- Avoid AI-generated generic patterns")
    Mix.shell().info("- Name files after their primary responsibility")
    Mix.shell().info("- Use domain-specific terminology")
    
    if not strict_mode do
      Mix.shell().info("")
      Mix.shell().info("Run `mix check_file_naming --strict` to fail CI on violations")
    end
  end
  
  defp display_violation(violation) do
    severity_indicator = case violation.severity do
      :high -> "🔴"
      :medium -> "🟡"
      :low -> "🟤"
    end
    
    Mix.shell().info("")
    Mix.shell().info("#{severity_indicator} #{violation.file}")
    Mix.shell().info("   Matched patterns: #{Enum.join(violation.matched_patterns, ", ")}")
    Mix.shell().info("   💡 #{violation.suggestions}")
  end
  
  defp severity_order(:high), do: 1
  defp severity_order(:medium), do: 2
  defp severity_order(:low), do: 3
end