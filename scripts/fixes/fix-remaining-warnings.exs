#!/usr/bin/env elixir

# Script to fix remaining compilation warnings in Mana codebase
# Run with: elixir scripts/fix-remaining-warnings.exs

defmodule WarningFixer do
  @moduledoc """
  Automated fixer for common compilation warnings
  """

  def run do
    IO.puts("🔧 Starting comprehensive warning fix...")
    
    fixes = [
      fix_unused_variables(),
      fix_unused_aliases(),
      fix_unused_module_attributes(),
      add_missing_logger_requires(),
      fix_impl_without_behaviour(),
      fix_leveldb_callbacks()
    ]
    
    total_fixed = Enum.sum(fixes)
    IO.puts("\n✅ Fixed #{total_fixed} warnings total")
  end

  defp fix_unused_variables do
    IO.puts("\n1️⃣ Fixing unused variables...")
    
    patterns = [
      # Common unused variables
      {"variable \"state\" is unused", "state", "_state"},
      {"variable \"reason\" is unused", "reason", "_reason"},
      {"variable \"config\" is unused", "config", "_config"},
      {"variable \"params\" is unused", "params", "_params"},
      {"variable \"packet\" is unused", "packet", "_packet"},
      {"variable \"data\" is unused", "data", "_data"},
      {"variable \"from\" is unused", "from", "_from"},
      {"variable \"endpoint\" is unused", "endpoint", "_endpoint"},
      {"variable \"method\" is unused", "method", "_method"},
      {"variable \"peer_id\" is unused", "peer_id", "_peer_id"},
      {"variable \"metrics_summary\" is unused", "metrics_summary", "_metrics_summary"},
      {"variable \"block_root\" is unused", "block_root", "_block_root"},
      {"variable \"results\" is unused", "results", "_results"},
      {"variable \"cluster_id\" is unused", "cluster_id", "_cluster_id"},
      {"variable \"transaction\" is unused", "transaction", "_transaction"},
      {"variable \"sla_id\" is unused", "sla_id", "_sla_id"},
      {"variable \"options\" is unused", "options", "_options"},
      {"variable \"key_id\" is unused", "key_id", "_key_id"},
      {"variable \"checks\" is unused", "checks", "_checks"},
      {"variable \"reachable_nodes\" is unused", "reachable_nodes", "_reachable_nodes"}
    ]
    
    count = 0
    for {_warning, from, to} <- patterns do
      files = find_files_with_pattern(from)
      for file <- files do
        fix_variable_in_file(file, from, to)
        count = count + 1
      end
    end
    
    IO.puts("  Fixed #{count} unused variable warnings")
    count
  end

  defp fix_unused_aliases do
    IO.puts("\n2️⃣ Fixing unused aliases...")
    
    # Find and remove unused aliases
    files = System.cmd("sh", ["-c", "grep -r 'unused alias' apps/ 2>/dev/null | cut -d: -f1 | sort -u"])
            |> elem(0)
            |> String.split("\n", trim: true)
    
    count = 0
    for file <- files do
      if File.exists?(file) do
        content = File.read!(file)
        # Comment out unused aliases instead of removing them
        new_content = Regex.replace(
          ~r/^(\s*)(alias [A-Z][A-Za-z0-9._]*(?:\s*,\s*as:\s*[A-Z][A-Za-z0-9._]*)?)$/m,
          content,
          fn full, indent, alias_line ->
            if String.contains?(alias_line, ["Transaction", "PerformanceBenchmark"]) do
              "#{indent}# #{alias_line} # TODO: Unused, consider removing"
            else
              full
            end
          end
        )
        
        if content != new_content do
          File.write!(file, new_content)
          count = count + 1
        end
      end
    end
    
    IO.puts("  Fixed #{count} unused alias warnings")
    count
  end

  defp fix_unused_module_attributes do
    IO.puts("\n3️⃣ Fixing unused module attributes...")
    
    attributes = [
      "@sync",
      "@incremental_cache_size",
      "@complex_operation_gas",
      "@contract_call_gas",
      "@eth_decimals",
      "@optimization_categories",
      "@tuning_profiles",
      "@decay_to_zero",
      "@decay_interval"
    ]
    
    count = 0
    for attr <- attributes do
      files = find_files_with_pattern(attr)
      for file <- files do
        if File.exists?(file) do
          content = File.read!(file)
          # Comment out unused module attributes
          new_content = Regex.replace(
            ~r/^(\s*)(#{Regex.escape(attr)}\s+.*)$/m,
            content,
            "\\1# \\2 # TODO: Unused attribute, consider removing"
          )
          
          if content != new_content do
            File.write!(file, new_content)
            count = count + 1
          end
        end
      end
    end
    
    IO.puts("  Fixed #{count} unused module attribute warnings")
    count
  end

  defp add_missing_logger_requires do
    IO.puts("\n4️⃣ Adding missing Logger requires...")
    
    files = System.cmd("sh", ["-c", "grep -r 'Logger.info.*is undefined' apps/ 2>/dev/null | cut -d: -f1 | sort -u"])
            |> elem(0)
            |> String.split("\n", trim: true)
    
    count = 0
    for file <- files do
      if File.exists?(file) do
        content = File.read!(file)
        
        # Check if require Logger is already present
        unless String.contains?(content, "require Logger") do
          # Add require Logger after the module definition
          new_content = Regex.replace(
            ~r/(defmodule [A-Z][A-Za-z0-9._]* do\n)/,
            content,
            "\\1  require Logger\n\n",
            global: false
          )
          
          if content != new_content do
            File.write!(file, new_content)
            count = count + 1
          end
        end
      end
    end
    
    IO.puts("  Added Logger require to #{count} files")
    count
  end

  defp fix_impl_without_behaviour do
    IO.puts("\n5️⃣ Fixing @impl without behaviour...")
    
    files = System.cmd("sh", ["-c", "grep -r '@impl true.*but no behaviour' apps/ 2>/dev/null | cut -d: -f1 | sort -u"])
            |> elem(0)
            |> String.split("\n", trim: true)
    
    count = 0
    for file <- files do
      if File.exists?(file) do
        content = File.read!(file)
        
        # Remove @impl true when there's no behaviour
        new_content = Regex.replace(
          ~r/^\s*@impl true\n/m,
          content,
          ""
        )
        
        if content != new_content do
          File.write!(file, new_content)
          count = count + 1
        end
      end
    end
    
    IO.puts("  Fixed #{count} @impl without behaviour warnings")
    count
  end

  defp fix_leveldb_callbacks do
    IO.puts("\n6️⃣ Fixing LevelDB callback issues...")
    
    leveldb_file = "apps/merkle_patricia_tree/lib/merkle_patricia_tree/db/leveldb.ex"
    
    if File.exists?(leveldb_file) do
      content = File.read!(leveldb_file)
      
      # Fix the callback implementations
      new_content = content
      |> String.replace("@impl true\n  def put(", "def put!(")
      |> String.replace("@impl true\n  def delete(", "def delete!(")
      |> String.replace("@impl true\n  def batch_put!(", "def batch_put!(")
      
      File.write!(leveldb_file, new_content)
      IO.puts("  Fixed LevelDB callback implementations")
      1
    else
      0
    end
  end

  defp find_files_with_pattern(pattern) do
    System.cmd("sh", ["-c", "grep -r '#{pattern}' apps/ 2>/dev/null | cut -d: -f1 | sort -u"])
    |> elem(0)
    |> String.split("\n", trim: true)
  end

  defp fix_variable_in_file(file, from_pattern, to_pattern) do
    if File.exists?(file) do
      content = File.read!(file)
      
      # Fix in function definitions
      new_content = Regex.replace(
        ~r/(\bdef\w*\s+\w+\([^)]*)\b#{from_pattern}\b([^)]*\))/,
        content,
        "\\1#{to_pattern}\\2"
      )
      
      # Fix in case statements
      new_content = Regex.replace(
        ~r/(\bcase\s+.*\s+do[^}]*)\b#{from_pattern}\b/,
        new_content,
        "\\1#{to_pattern}"
      )
      
      # Fix in pattern matches
      new_content = Regex.replace(
        ~r/({:ok,\s*)#{from_pattern}(\s*})/,
        new_content,
        "\\1#{to_pattern}\\2"
      )
      
      if content != new_content do
        File.write!(file, new_content)
      end
    end
  end
end

# Run the fixer
WarningFixer.run()