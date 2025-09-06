defmodule Common.Validation do
  @moduledoc """
  Reusable validation patterns for the Mana codebase.

  Provides composable validators for common blockchain data types:
  - Transactions
  - Blocks  
  - Addresses
  - Hashes
  - Numeric ranges
  """

  import Common.Functional

  # Common validators as composable functions

  @doc """
  Validates an Ethereum address.
  """
  @spec validate_address(binary()) :: {:ok, binary()} | {:error, String.t()}
  def validate_address(address) when is_binary(address) do
    validate_all(address, [
      validator(&(byte_size(&1) == 20), "Address must be 20 bytes"),
      validator(&is_binary/1, "Address must be binary")
    ])
  end

  def validate_address(_), do: {:error, "Invalid address type"}

  @doc """
  Validates a transaction hash.
  """
  @spec validate_hash(binary(), pos_integer()) :: {:ok, binary()} | {:error, String.t()}
  def validate_hash(hash, expected_size \\ 32) do
    validate_all(hash, [
      validator(&is_binary/1, "Hash must be binary"),
      validator(&(byte_size(&1) == expected_size), "Hash must be #{expected_size} bytes")
    ])
  end

  @doc """
  Validates a numeric value is within range.
  """
  @spec validate_range(number(), number(), number()) :: {:ok, number()} | {:error, String.t()}
  def validate_range(value, min, max) do
    validate_all(value, [
      validator(&(&1 >= min), "Value must be >= #{min}"),
      validator(&(&1 <= max), "Value must be <= #{max}")
    ])
  end

  @doc """
  Validates gas parameters.
  """
  @spec validate_gas(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_gas(params) do
    with {:ok, _} <- validate_range(params.gas_price, 0, :infinity),
         {:ok, _} <- validate_range(params.gas_limit, 21_000, 8_000_000) do
      {:ok, params}
    end
  end

  @doc """
  Composable validator for non-empty values.
  """
  @spec non_empty(any()) :: {:ok, any()} | {:error, String.t()}
  def non_empty(value) when value in [nil, "", <<>>, []], do: {:error, "Value cannot be empty"}

  def non_empty(value) when is_map(value) and map_size(value) == 0,
    do: {:error, "Map cannot be empty"}

  def non_empty(value), do: {:ok, value}

  @doc """
  Validates a value matches a pattern.
  """
  @spec validate_pattern(String.t(), Regex.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate_pattern(value, pattern, error_msg \\ "Pattern mismatch") do
    if Regex.match?(pattern, value) do
      {:ok, value}
    else
      {:error, error_msg}
    end
  end

  @doc """
  Creates a type validator.
  """
  defmacro type_validator(type) do
    quote do
      fn value ->
        if unquote(type)(value) do
          {:ok, value}
        else
          {:error, "Invalid type, expected #{unquote(type)}"}
        end
      end
    end
  end

  @doc """
  Validates transaction structure with composable validators.
  """
  @spec validate_transaction(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_transaction(tx) do
    validators = [
      &validate_transaction_nonce/1,
      &validate_transaction_gas_params/1,
      &validate_transaction_addresses/1,
      &validate_transaction_signature/1
    ]

    chain_results({:ok, tx}, validators)
  end

  defp validate_transaction_nonce(tx) do
    validate_range(tx.nonce, 0, :infinity)
    |> map_ok(fn _ -> tx end)
  end

  defp validate_transaction_gas_params(tx) do
    with {:ok, _} <- validate_range(tx.gas_price, 1, :infinity),
         {:ok, _} <- validate_range(tx.gas_limit, 21_000, 8_000_000) do
      {:ok, tx}
    end
  end

  defp validate_transaction_addresses(tx) do
    with {:ok, _} <- if(tx.to, do: validate_address(tx.to), else: {:ok, nil}),
         {:ok, _} <- if(tx.from, do: validate_address(tx.from), else: {:ok, nil}) do
      {:ok, tx}
    end
  end

  defp validate_transaction_signature(tx) do
    validate_all(tx, [
      validator(&(&1.v > 0), "Invalid v value"),
      validator(&(&1.r > 0), "Invalid r value"),
      validator(&(&1.s > 0), "Invalid s value")
    ])
  end

  @doc """
  Creates a cached validator for expensive validations.
  """
  @spec cached_validator(function(), keyword()) :: function()
  def cached_validator(validator_fun, opts \\ []) do
    cache_name = Keyword.get(opts, :cache_name, :validation_cache)
    # 5 minutes default
    ttl = Keyword.get(opts, :ttl, 300)

    memoize(validator_fun, cache_name: cache_name, ttl: ttl)
  end

  @doc """
  Validates a collection of items.
  """
  @spec validate_collection(list(), function()) :: {:ok, list()} | {:error, String.t()}
  def validate_collection(items, validator) do
    traverse(items, validator)
  end

  @doc """
  Conditional validator - only validates if condition is met.
  """
  @spec validate_if(any(), boolean() | function(), function()) ::
          {:ok, any()} | {:error, String.t()}
  def validate_if(value, condition, validator) do
    should_validate = if is_function(condition), do: condition.(value), else: condition

    if should_validate do
      validator.(value)
    else
      {:ok, value}
    end
  end

  @doc """
  Validates with a custom error transformer.
  """
  @spec validate_with_context(any(), function(), map()) :: {:ok, any()} | {:error, map()}
  def validate_with_context(value, validator, context) do
    case validator.(value) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, Map.put(context, :reason, reason)}
    end
  end

  @doc """
  Combines validators with AND logic more efficiently.
  """
  @spec all_of([function()]) :: function()
  def all_of(validators) do
    fn value -> validate_all(value, validators) end
  end

  @doc """
  Combines validators with OR logic more efficiently.
  """
  @spec any_of([function()]) :: function()
  def any_of(validators) do
    fn value -> validate_any(value, validators) end
  end

  @doc """
  Creates a validator from a specification map.
  """
  @spec spec_validator(map()) :: function()
  def spec_validator(spec) do
    fn value ->
      spec
      |> Enum.reduce_while({:ok, value}, fn {field, field_validator}, {:ok, val} ->
        field_value = Map.get(val, field)

        case field_validator.(field_value) do
          {:ok, _} -> {:cont, {:ok, val}}
          {:error, reason} -> {:halt, {:error, "#{field}: #{reason}"}}
        end
      end)
    end
  end

  @doc """
  Validates deeply nested structures.
  """
  @spec validate_nested(any(), list()) :: {:ok, any()} | {:error, String.t()}
  def validate_nested(value, path) when is_list(path) do
    get_in(value, path)
    |> case do
      nil -> {:error, "Path not found: #{inspect(path)}"}
      found -> {:ok, found}
    end
  end

  @doc """
  Creates a sanitizer that cleans and validates input.
  """
  @spec sanitize_and_validate(any(), function(), function()) ::
          {:ok, any()} | {:error, String.t()}
  def sanitize_and_validate(value, sanitizer, validator) do
    value
    |> sanitizer.()
    |> validator.()
  end

  @doc """
  Validates with multiple error accumulation.
  """
  @spec validate_accumulating(any(), [function()]) :: {:ok, any()} | {:error, [String.t()]}
  def validate_accumulating(value, validators) do
    errors =
      validators
      |> Enum.map(& &1.(value))
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, reason} -> reason end)

    if Enum.empty?(errors) do
      {:ok, value}
    else
      {:error, errors}
    end
  end
end
