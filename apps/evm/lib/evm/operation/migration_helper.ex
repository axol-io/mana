defmodule EVM.Operation.MigrationHelper do
  @moduledoc """
  Helper module to migrate existing operations to the new metadata registry pattern.
  Provides utilities to analyze and convert legacy operation modules.
  """

  @doc """
  Analyzes the existing metadata files and generates migration data.
  """
  def analyze_metadata_files do
    metadata_path = Path.join([__DIR__, "metadata"])

    metadata_path
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.map(fn file ->
      module_name =
        file
        |> String.replace(".ex", "")
        |> Macro.camelize()

      full_module = Module.concat([EVM.Operation.Metadata, module_name])

      # Try to load and get operations
      try do
        if function_exported?(full_module, :operations, 0) do
          {file, full_module.operations()}
        else
          {file, []}
        end
      rescue
        _ -> {file, []}
      end
    end)
    |> Enum.into(%{})
  end

  @doc """
  Generates the use statement for an operation module based on its metadata.
  """
  def generate_use_statement(%EVM.Operation.Metadata{} = metadata) do
    """
    use EVM.Operation.MetadataRegistry,
      opcode: #{inspect(metadata.id)},
      sym: #{inspect(metadata.sym)},
      description: #{inspect(metadata.description)},
      group: #{inspect(metadata.group)},
      input_count: #{metadata.input_count},
      output_count: #{metadata.output_count}#{generate_optional_fields(metadata)}
    """
  end

  defp generate_optional_fields(metadata) do
    fields = []

    fields =
      if metadata.machine_code_offset && metadata.machine_code_offset != 0 do
        fields ++ [",\n      machine_code_offset: #{metadata.machine_code_offset}"]
      else
        fields
      end

    fields =
      if metadata.gas_cost do
        fields ++ [",\n      gas_cost: #{inspect(metadata.gas_cost)}"]
      else
        fields
      end

    Enum.join(fields)
  end

  @doc """
  Generates a refactored operation module from existing code.
  """
  def refactor_operation_module(operation_file, metadata) do
    content = File.read!(operation_file)

    # Extract the module name and functions
    module_name = extract_module_name(content)
    functions = extract_functions(content)

    # Generate the new module
    """
    defmodule #{module_name}Refactored do
      @moduledoc \"\"\"
      Refactored #{module_name} with integrated metadata.
      \"\"\"
      
      #{generate_use_statement(metadata)}
      
      #{extract_aliases(content)}
      
      #{Enum.join(functions, "\n\n")}
    end
    """
  end

  defp extract_module_name(content) do
    case Regex.run(~r/defmodule\s+([\w\.]+)\s+do/, content) do
      [_, module_name] -> module_name
      _ -> "Unknown"
    end
  end

  defp extract_aliases(content) do
    content
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "alias"))
    |> Enum.join("\n")
  end

  defp extract_functions(content) do
    # Simple regex to extract function definitions
    # In production, use proper AST parsing
    Regex.scan(~r/@spec.*?\n.*?def\s+\w+.*?^  end/ms, content)
    |> Enum.map(fn [match] -> match end)
  end

  @doc """
  Generates a report of all operations that need migration.
  """
  def migration_report do
    metadata_files = analyze_metadata_files()

    report =
      metadata_files
      |> Enum.map(fn {file, operations} ->
        """
        File: #{file}
        Operations: #{length(operations)}
        #{Enum.map(operations, fn op -> "  - #{op.sym} (0x#{Integer.to_string(op.id, 16)})" end) |> Enum.join("\n")}
        """
      end)
      |> Enum.join("\n")

    total_operations =
      metadata_files
      |> Enum.map(fn {_, ops} -> length(ops) end)
      |> Enum.sum()

    """
    # EVM Operation Migration Report

    Total metadata files: #{map_size(metadata_files)}
    Total operations: #{total_operations}

    ## Files to migrate:
    #{report}

    ## Benefits of migration:
    - Eliminates #{map_size(metadata_files)} redundant metadata files
    - Reduces code duplication by ~50%
    - Ensures metadata stays in sync with implementation
    - Enables compile-time validation
    - Improves maintainability
    """
  end

  @doc """
  Creates a mapping of old metadata modules to new operation modules.
  """
  def create_migration_mapping do
    %{
      "EVM.Operation.Metadata.SHA3" => "EVM.Operation.Sha3Refactored",
      "EVM.Operation.Metadata.StopAndArithmetic" => [
        "EVM.Operation.StopRefactored",
        "EVM.Operation.ArithmeticRefactored.Add",
        "EVM.Operation.ArithmeticRefactored.Mul",
        "EVM.Operation.ArithmeticRefactored.Sub",
        "EVM.Operation.ArithmeticRefactored.Div",
        "EVM.Operation.ArithmeticRefactored.Mod",
        "EVM.Operation.ArithmeticRefactored.Exp"
      ]
      # Add more mappings as operations are refactored
    }
  end
end
