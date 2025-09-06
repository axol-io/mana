defmodule JSONRPC2.HandlerMacro do
  @moduledoc """
  Macro for generating repetitive JSONRPC handler pairs (ByHash and ByNumber variants).
  Eliminates boilerplate for common Ethereum RPC patterns.
  """

  @doc """
  Generates both ByHash and ByNumber handler variants for a given RPC method.

  ## Example
      
      define_dual_handlers :get_block_transaction_count,
        sync_method: :block_transaction_count,
        hash_param: :block_hash,
        number_param: :block_number
  """
  defmacro define_dual_handlers(base_name, opts) do
    sync_method = Keyword.fetch!(opts, :sync_method)
    hash_param = Keyword.get(opts, :hash_param, :hash)
    number_param = Keyword.get(opts, :number_param, :number)

    # Convert atom to camelCase string for RPC method name
    base_string = base_name |> to_string() |> Macro.camelize() |> lcfirst()
    by_hash_method = "eth_#{base_string}ByHash"
    by_number_method = "eth_#{base_string}ByNumber"

    quote do
      def handle_request(unquote(by_hash_method), [hex_hash]) do
        with {:ok, unquote(Macro.var(hash_param, nil))} <- decode_hex(hex_hash) do
          @sync.unquote(sync_method)(unquote(Macro.var(hash_param, nil)))
        end
      end

      def handle_request(unquote(by_number_method), [hex_number]) do
        with {:ok, unquote(Macro.var(number_param, nil))} <- decode_unsigned(hex_number) do
          @sync.unquote(sync_method)(unquote(Macro.var(number_param, nil)))
        end
      end
    end
  end

  @doc """
  Generates handler for methods with optional block parameter.
  """
  defmacro define_block_param_handler(method_name, implementation) do
    eth_method = "eth_#{method_name}"

    quote do
      def handle_request(unquote(eth_method), [param, hex_block_number_or_tag]) do
        with {:ok, block_number} <- decode_block_number(hex_block_number_or_tag) do
          unquote(implementation).(param, block_number)
        end
      end
    end
  end

  # Helper function to convert first letter to lowercase
  defp lcfirst(<<first::utf8, rest::binary>>) do
    String.downcase(<<first::utf8>>) <> rest
  end
end
