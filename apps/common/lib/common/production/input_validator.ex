defmodule Common.Production.InputValidator do
  @moduledoc """
  Input validation for JSON-RPC requests to prevent attacks and ensure data integrity.

  Provides comprehensive validation for:
  - Size limits to prevent DoS attacks
  - Format validation for addresses, hashes, and numbers
  - Injection attack prevention
  - Rate limiting integration
  """

  require Logger

  # Size limits (in bytes)
  # 10 MB
  @max_request_size 10_485_760
  # 1 MB
  @max_param_size 1_048_576
  # 5 MB for transaction data
  @max_data_size 5_242_880
  # Maximum array elements
  @max_array_length 1000
  # Maximum batch requests
  @max_batch_size 100

  # Pattern matchers
  @address_pattern ~r/^0x[0-9a-fA-F]{40}$/
  @hash_pattern ~r/^0x[0-9a-fA-F]{64}$/
  @hex_pattern ~r/^0x[0-9a-fA-F]*$/
  @block_tag_pattern ~r/^(latest|earliest|pending)$/

  @doc """
  Validates a complete JSON-RPC request.
  """
  @spec validate_request(map()) :: {:ok, map()} | {:error, atom() | binary()}
  def validate_request(request) when is_map(request) do
    with :ok <- validate_request_size(request),
         :ok <- validate_request_structure(request),
         :ok <- validate_method(request["method"]),
         :ok <- validate_params(request["params"], request["method"]) do
      {:ok, request}
    end
  end

  def validate_request(_), do: {:error, :invalid_request_format}

  @doc """
  Validates a batch of requests.
  """
  @spec validate_batch(list()) :: {:ok, list()} | {:error, atom() | binary()}
  def validate_batch(requests) when is_list(requests) do
    if length(requests) > @max_batch_size do
      {:error, "Batch size exceeds maximum of #{@max_batch_size}"}
    else
      case Enum.reduce_while(requests, {:ok, []}, fn req, {:ok, acc} ->
             case validate_request(req) do
               {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
               error -> {:halt, error}
             end
           end) do
        {:ok, validated} -> {:ok, Enum.reverse(validated)}
        error -> error
      end
    end
  end

  def validate_batch(_), do: {:error, :invalid_batch_format}

  @doc """
  Validates an Ethereum address.
  """
  @spec validate_address(binary()) :: {:ok, binary()} | {:error, binary()}
  def validate_address(address) when is_binary(address) do
    if Regex.match?(@address_pattern, address) do
      # Could add checksum validation here
      {:ok, address}
    else
      {:error, "Invalid address format: #{inspect(address)}"}
    end
  end

  def validate_address(_), do: {:error, "Address must be a hex string"}

  @doc """
  Validates a transaction or block hash.
  """
  @spec validate_hash(binary()) :: {:ok, binary()} | {:error, binary()}
  def validate_hash(hash) when is_binary(hash) do
    if Regex.match?(@hash_pattern, hash) do
      {:ok, hash}
    else
      {:error, "Invalid hash format: #{inspect(hash)}"}
    end
  end

  def validate_hash(_), do: {:error, "Hash must be a 32-byte hex string"}

  @doc """
  Validates a block number or tag.
  """
  @spec validate_block_number(binary() | integer()) ::
          {:ok, binary() | integer()} | {:error, binary()}
  def validate_block_number(number) when is_integer(number) and number >= 0 do
    {:ok, number}
  end

  def validate_block_number(tag) when is_binary(tag) do
    cond do
      Regex.match?(@block_tag_pattern, tag) ->
        {:ok, tag}

      Regex.match?(@hex_pattern, tag) ->
        case Integer.parse(String.slice(tag, 2..-1//1), 16) do
          {num, ""} when num >= 0 -> {:ok, tag}
          _ -> {:error, "Invalid block number: #{tag}"}
        end

      true ->
        {:error, "Invalid block number format: #{tag}"}
    end
  end

  def validate_block_number(_), do: {:error, "Block number must be a number or tag"}

  @doc """
  Validates hex data input.
  """
  @spec validate_hex_data(binary(), keyword()) :: {:ok, binary()} | {:error, binary()}
  def validate_hex_data(data, opts \\ [])

  def validate_hex_data(data, opts) when is_binary(data) do
    max_size = Keyword.get(opts, :max_size, @max_data_size)

    cond do
      not Regex.match?(@hex_pattern, data) ->
        {:error, "Invalid hex data format"}

      byte_size(data) > max_size ->
        {:error, "Data exceeds maximum size of #{max_size} bytes"}

      rem(byte_size(data) - 2, 2) != 0 ->
        {:error, "Hex data must have even number of characters"}

      true ->
        {:ok, data}
    end
  end

  def validate_hex_data(_, _), do: {:error, "Data must be a hex string"}

  @doc """
  Validates a quantity (number in hex).
  """
  @spec validate_quantity(binary()) :: {:ok, binary()} | {:error, binary()}
  def validate_quantity(quantity) when is_binary(quantity) do
    if Regex.match?(@hex_pattern, quantity) do
      case Integer.parse(String.slice(quantity, 2..-1//1), 16) do
        {_num, ""} -> {:ok, quantity}
        _ -> {:error, "Invalid quantity format"}
      end
    else
      {:error, "Quantity must be in hex format"}
    end
  end

  def validate_quantity(_), do: {:error, "Quantity must be a hex string"}

  @doc """
  Sanitizes input to prevent injection attacks.
  """
  @spec sanitize_input(binary()) :: binary()
  def sanitize_input(input) when is_binary(input) do
    input
    |> String.replace(~r/[^\w\s\-\.0-9a-fA-Fx]/, "")
    |> String.slice(0, @max_param_size)
  end

  def sanitize_input(input), do: to_string(input) |> sanitize_input()

  # Private functions

  defp validate_request_size(request) do
    # Estimate request size (rough approximation)
    size = :erlang.term_to_binary(request) |> byte_size()

    if size > @max_request_size do
      {:error, "Request exceeds maximum size of #{@max_request_size} bytes"}
    else
      :ok
    end
  end

  defp validate_request_structure(request) do
    cond do
      not Map.has_key?(request, "jsonrpc") ->
        {:error, "Missing jsonrpc field"}

      request["jsonrpc"] != "2.0" ->
        {:error, "Invalid jsonrpc version"}

      not Map.has_key?(request, "method") ->
        {:error, "Missing method field"}

      not Map.has_key?(request, "id") ->
        {:error, "Missing id field"}

      true ->
        :ok
    end
  end

  defp validate_method(method) when is_binary(method) do
    # Check for suspicious patterns that might indicate injection attempts
    if String.contains?(method, ["<", ">", "'", "\"", ";", "&", "|", "$", "`"]) do
      {:error, "Invalid characters in method name"}
    else
      :ok
    end
  end

  defp validate_method(_), do: {:error, "Method must be a string"}

  defp validate_params(params, method) do
    case method do
      "eth_getBalance" ->
        validate_eth_get_balance_params(params)

      "eth_sendTransaction" ->
        validate_eth_send_transaction_params(params)

      "eth_call" ->
        validate_eth_call_params(params)

      "eth_getTransactionByHash" ->
        validate_eth_get_transaction_params(params)

      "eth_getBlockByHash" ->
        validate_eth_get_block_by_hash_params(params)

      "eth_getBlockByNumber" ->
        validate_eth_get_block_by_number_params(params)

      "eth_getLogs" ->
        validate_eth_get_logs_params(params)

      _ ->
        # Generic validation for unknown methods
        validate_generic_params(params)
    end
  end

  defp validate_eth_get_balance_params([address, block]) do
    with {:ok, _} <- validate_address(address),
         {:ok, _} <- validate_block_number(block) do
      :ok
    end
  end

  defp validate_eth_get_balance_params(_), do: {:error, "Invalid parameters for eth_getBalance"}

  defp validate_eth_send_transaction_params([tx_params]) when is_map(tx_params) do
    with {:ok, _} <- validate_address(tx_params["from"] || "0x" <> String.duplicate("0", 40)),
         {:ok, _} <- validate_address(tx_params["to"] || "0x" <> String.duplicate("0", 40)),
         {:ok, _} <- validate_hex_data(tx_params["data"] || "0x", max_size: @max_data_size),
         {:ok, _} <- validate_quantity(tx_params["gas"] || "0x0"),
         {:ok, _} <- validate_quantity(tx_params["gasPrice"] || "0x0"),
         {:ok, _} <- validate_quantity(tx_params["value"] || "0x0") do
      :ok
    end
  end

  defp validate_eth_send_transaction_params(_),
    do: {:error, "Invalid parameters for eth_sendTransaction"}

  defp validate_eth_call_params([call_params, block]) do
    with {:ok, _} <- validate_eth_send_transaction_params([call_params]),
         {:ok, _} <- validate_block_number(block) do
      :ok
    end
  end

  defp validate_eth_call_params(_), do: {:error, "Invalid parameters for eth_call"}

  defp validate_eth_get_transaction_params([hash]) do
    validate_hash(hash) |> handle_validation_result()
  end

  defp validate_eth_get_transaction_params(_),
    do: {:error, "Invalid parameters for eth_getTransactionByHash"}

  defp validate_eth_get_block_by_hash_params([hash, full_transactions]) do
    with {:ok, _} <- validate_hash(hash),
         :ok <- validate_boolean(full_transactions) do
      :ok
    end
  end

  defp validate_eth_get_block_by_hash_params(_),
    do: {:error, "Invalid parameters for eth_getBlockByHash"}

  defp validate_eth_get_block_by_number_params([block, full_transactions]) do
    with {:ok, _} <- validate_block_number(block),
         :ok <- validate_boolean(full_transactions) do
      :ok
    end
  end

  defp validate_eth_get_block_by_number_params(_),
    do: {:error, "Invalid parameters for eth_getBlockByNumber"}

  defp validate_eth_get_logs_params([filter]) when is_map(filter) do
    with :ok <- validate_filter_addresses(filter["address"]),
         :ok <- validate_filter_topics(filter["topics"]),
         :ok <- validate_filter_blocks(filter) do
      :ok
    end
  end

  defp validate_eth_get_logs_params(_), do: {:error, "Invalid parameters for eth_getLogs"}

  defp validate_generic_params(nil), do: :ok
  defp validate_generic_params([]), do: :ok

  defp validate_generic_params(params) when is_list(params) do
    if length(params) > @max_array_length do
      {:error, "Parameter array exceeds maximum length"}
    else
      :ok
    end
  end

  defp validate_generic_params(_), do: :ok

  defp validate_boolean(true), do: :ok
  defp validate_boolean(false), do: :ok
  defp validate_boolean(_), do: {:error, "Expected boolean value"}

  defp validate_filter_addresses(nil), do: :ok

  defp validate_filter_addresses(address) when is_binary(address),
    do: validate_address(address) |> handle_validation_result()

  defp validate_filter_addresses(addresses) when is_list(addresses) do
    if length(addresses) > 100 do
      {:error, "Too many addresses in filter"}
    else
      Enum.reduce_while(addresses, :ok, fn addr, :ok ->
        case validate_address(addr) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_filter_addresses(_), do: {:error, "Invalid address filter"}

  defp validate_filter_topics(nil), do: :ok

  defp validate_filter_topics(topics) when is_list(topics) do
    if length(topics) > 4 do
      {:error, "Too many topics in filter"}
    else
      Enum.reduce_while(topics, :ok, fn topic, :ok ->
        case validate_topic(topic) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_filter_topics(_), do: {:error, "Invalid topics filter"}

  defp validate_topic(nil), do: :ok

  defp validate_topic(topic) when is_binary(topic),
    do: validate_hash(topic) |> handle_validation_result()

  defp validate_topic(topics) when is_list(topics) do
    Enum.reduce_while(topics, :ok, fn t, :ok ->
      case validate_topic(t) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_topic(_), do: {:error, "Invalid topic format"}

  defp validate_filter_blocks(filter) do
    with :ok <- validate_filter_block(filter["fromBlock"]),
         :ok <- validate_filter_block(filter["toBlock"]),
         :ok <- validate_filter_block(filter["blockHash"]) do
      :ok
    end
  end

  defp validate_filter_block(nil), do: :ok

  defp validate_filter_block(block),
    do: validate_block_number(block) |> handle_validation_result()

  defp handle_validation_result({:ok, _}), do: :ok
  defp handle_validation_result(error), do: error
end
