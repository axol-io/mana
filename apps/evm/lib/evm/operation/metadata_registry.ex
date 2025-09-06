defmodule EVM.Operation.MetadataRegistry do
  @moduledoc """
  Compile-time metadata generation for EVM operations.
  Eliminates the need for separate metadata files by extracting
  metadata directly from operation modules using module attributes.
  """

  defmacro __using__(opts) do
    quote do
      @before_compile EVM.Operation.MetadataRegistry

      # Store metadata as module attributes
      @opcode unquote(Keyword.fetch!(opts, :opcode))
      @sym unquote(Keyword.fetch!(opts, :sym))
      @description unquote(Keyword.get(opts, :description, ""))
      @group unquote(Keyword.fetch!(opts, :group))
      @input_count unquote(Keyword.get(opts, :input_count, 0))
      @output_count unquote(Keyword.get(opts, :output_count, 0))
      @machine_code_offset unquote(Keyword.get(opts, :machine_code_offset, 0))
      @gas_cost unquote(Keyword.get(opts, :gas_cost, nil))

      # Make metadata accessible
      def __metadata__ do
        %EVM.Operation.Metadata{
          id: @opcode,
          sym: @sym,
          description: @description,
          group: @group,
          input_count: @input_count,
          output_count: @output_count,
          machine_code_offset: @machine_code_offset,
          gas_cost: @gas_cost
        }
      end
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      # Ensure the module implements the required function
      unless Module.defines?(__MODULE__, {@sym, @input_count}, :def) do
        raise CompileError,
          description:
            "Operation module #{__MODULE__} must define function #{@sym}/#{@input_count}"
      end
    end
  end

  @doc """
  Collects metadata from all operation modules at compile time.
  """
  defmacro collect_metadata(modules) do
    quote bind_quoted: [modules: modules] do
      @operations Enum.flat_map(modules, fn module ->
                    if function_exported?(module, :__metadata__, 0) do
                      [module.__metadata__()]
                    else
                      []
                    end
                  end)

      def all_operations, do: @operations
    end
  end

  @doc """
  Generates operation dispatch functions based on metadata.
  """
  defmacro generate_dispatchers do
    quote do
      @opcodes_to_metadata for(op <- all_operations(), do: {op.id, op}) |> Enum.into(%{})
      @opcodes_to_operations for({id, op} <- @opcodes_to_metadata, do: {id, op.sym})
                             |> Enum.into(%{})
      @operations_to_opcodes EVM.Helpers.invert(@opcodes_to_operations)

      @doc """
      Gets metadata for a given opcode.
      """
      @spec get_metadata(EVM.Operation.opcode()) :: EVM.Operation.Metadata.t() | nil
      def get_metadata(opcode), do: Map.get(@opcodes_to_metadata, opcode)

      @doc """
      Gets operation symbol for a given opcode.
      """
      @spec get_operation(EVM.Operation.opcode()) :: atom() | nil
      def get_operation(opcode), do: Map.get(@opcodes_to_operations, opcode)

      @doc """
      Gets opcode for a given operation symbol.
      """
      @spec get_opcode(atom()) :: EVM.Operation.opcode() | nil
      def get_opcode(operation), do: Map.get(@operations_to_opcodes, operation)

      @doc """
      Returns all opcodes.
      """
      @spec all_opcodes() :: [EVM.Operation.opcode()]
      def all_opcodes, do: Map.keys(@opcodes_to_metadata)

      @doc """
      Returns all operation symbols.
      """
      @spec all_operation_symbols() :: [atom()]
      def all_operation_symbols, do: Map.keys(@operations_to_opcodes)
    end
  end
end
