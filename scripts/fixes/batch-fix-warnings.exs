#!/usr/bin/env elixir

# Script to batch fix common compilation warnings

defmodule WarningFixer do
  @moduledoc """
  Automated warning fixer for the Mana codebase.
  """

  def run do
    IO.puts("🔧 Starting batch warning fixes...")
    
    # Get all Elixir files
    files = Path.wildcard("apps/**/*.ex") ++ Path.wildcard("apps/**/*.exs")
    
    Enum.each(files, &process_file/1)
    
    IO.puts("✅ Batch fixes complete!")
  end

  defp process_file(file) do
    content = File.read!(file)
    original = content
    
    # Fix unused variables in function definitions
    content = fix_unused_params(content)
    
    # Fix unused variables in pattern matches
    content = fix_unused_matches(content)
    
    # Add require Logger if needed
    content = add_require_logger(content)
    
    # Fix unused variables in comprehensions
    content = fix_unused_in_comprehensions(content)
    
    if content != original do
      File.write!(file, content)
      IO.puts("  Fixed: #{file}")
    end
  end

  defp fix_unused_params(content) do
    # Fix unused function parameters by prefixing with underscore
    content
    |> String.replace(~r/def\s+(\w+)\(([^)]*)\)\s+do/, fn match, fname, params ->
      fixed_params = fix_param_list(params)
      "def #{fname}(#{fixed_params}) do"
    end)
    |> String.replace(~r/defp\s+(\w+)\(([^)]*)\)\s+do/, fn match, fname, params ->
      fixed_params = fix_param_list(params)
      "defp #{fname}(#{fixed_params}) do"
    end)
  end

  defp fix_param_list(params) do
    params
    |> String.split(",")
    |> Enum.map(&fix_single_param/1)
    |> Enum.join(",")
  end

  defp fix_single_param(param) do
    param = String.trim(param)
    
    cond do
      # Already prefixed with underscore
      String.starts_with?(param, "_") -> param
      
      # Pattern match or default value
      String.contains?(param, "=") -> 
        [var, default] = String.split(param, "=", parts: 2)
        var = String.trim(var)
        if should_prefix_underscore?(var) do
          "_#{var}=#{default}"
        else
          param
        end
      
      # Destructuring
      String.contains?(param, "%") -> param
      String.contains?(param, "{") -> param
      String.contains?(param, "[") -> param
      
      # Simple variable
      should_prefix_underscore?(param) ->
        "_#{param}"
      
      true -> param
    end
  end

  defp should_prefix_underscore?(var) do
    var = String.trim(var)
    # Check if it's a simple lowercase variable that might be unused
    Regex.match?(~r/^[a-z][a-z0-9_]*$/, var) and
      var not in ["state", "conn", "socket", "pid", "ref", "opts", "config", "params"]
  end

  defp fix_unused_matches(content) do
    # Fix unused variables in case/with clauses
    content
    |> String.replace(~r/^\s*([a-z][a-z0-9_]*)\s*->$/m, fn match, var ->
      String.replace(match, var, "_#{var}")
    end)
    
    # Fix unused variables in pattern matches
    |> String.replace(~r/^\s*([a-z][a-z0-9_]*)\s*=\s*/m, fn match, var ->
      if should_prefix_underscore?(var) do
        String.replace(match, var, "_#{var}")
      else
        match
      end
    end)
  end

  defp fix_unused_in_comprehensions(content) do
    # Fix unused variables in for comprehensions
    content
    |> String.replace(~r/for\s+([a-z][a-z0-9_]*)\s*<-/, fn match, var ->
      "for _#{var} <-"
    end)
    |> String.replace(~r/for\s+{([a-z][a-z0-9_]*),\s*([a-z][a-z0-9_]*)}/, fn match, v1, v2 ->
      "for {_#{v1}, _#{v2}}"
    end)
  end

  defp add_require_logger(content) do
    if String.contains?(content, "Logger.") and not String.contains?(content, "require Logger") do
      # Add require Logger after the module definition
      String.replace(content, ~r/(defmodule\s+[\w\.]+\s+do\n)/, "\\1  require Logger\n")
    else
      content
    end
  end
end

# Run the fixer
WarningFixer.run()