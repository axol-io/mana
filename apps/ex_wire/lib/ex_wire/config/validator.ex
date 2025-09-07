defmodule ExWire.Config.Validator do
  @moduledoc """
  Configuration validation module that ensures configuration integrity
  and type safety.
  """

  require Logger

  @doc """
  Validates a configuration value against a schema definition.
  """
  def validate_value(value, schema) when is_map(schema) do
    with :ok <- validate_type(value, schema[:type]),
         :ok <- validate_required(value, schema[:required]),
         :ok <- validate_enum(value, schema[:enum]),
         :ok <- validate_range(value, schema[:min], schema[:max]),
         :ok <- validate_format(value, schema[:format]),
         :ok <- validate_custom(value, schema[:validator]) do
      :ok
    end
  end

  def validate_value(_value, nil), do: :ok

  @doc """
  Validates an entire configuration map against a schema.
  """
  def validate_config(_config, schema) when is_map(config) and is_map(schema) do
    errors = collect_validation_errors(config, schema, [])

    case errors do
      [] -> :ok
      errors -> {:error, {:validation_failed, errors}}
    end
  end

  @doc """
  Performs deep validation of nested configuration.
  """
  def deep_validate(_config, schema, path \\ []) do
    Enum.reduce(schema, [], fn {key, spec}, errors ->
      value = Map.get(config, key)
      current_path = path ++ [key]

      case validate_field(value, spec, current_path) do
        :ok ->
          if is_map(value) and is_map(spec) and not Map.has_key?(spec, :type) do
            deep_validate(value, spec, current_path) ++ errors
          else
            errors
          end

        {:error, _reason} ->
          [{current_path, reason} | errors]
      end
    end)
  end

  # Type Validation

  defp validate_type(nil, _type), do: :ok
  defp validate_type(value, :string) when is_binary(value), do: :ok
  defp validate_type(value, :integer) when is_integer(value), do: :ok
  defp validate_type(value, :float) when is_float(value), do: :ok
  defp validate_type(value, :number) when is_number(value), do: :ok
  defp validate_type(value, :boolean) when is_boolean(value), do: :ok
  defp validate_type(value, :atom) when is_atom(value), do: :ok
  defp validate_type(value, :list) when is_list(value), do: :ok
  defp validate_type(value, :map) when is_map(value), do: :ok

  defp validate_type(value, {:list, item_type}) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, _acc ->
      case validate_type(item, item_type) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_type(value, type) do
    {:error, {:invalid_type, expected: type, got: type_of(value)}}
  end

  defp validate_required(nil, true), do: {:error, :required_field_missing}
  defp validate_required(_value, _), do: :ok

  defp validate_enum(_value, nil), do: :ok

  defp validate_enum(value, enum) when is_list(enum) do
    if value in enum do
      :ok
    else
      {:error, {:invalid_enum_value, value: value, allowed: enum}}
    end
  end

  defp validate_range(_value, nil, nil), do: :ok

  defp validate_range(value, min, _max) when not is_nil(min) and value < min do
    {:error, {:below_minimum, value: value, min: min}}
  end

  defp validate_range(value, _min, max) when not is_nil(max) and value > max do
    {:error, {:above_maximum, value: value, max: max}}
  end

  defp validate_range(_value, _min, _max), do: :ok

  defp validate_format(_value, nil), do: :ok

  defp validate_format(value, :email) when is_binary(value) do
    if String.match?(value, ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/) do
      :ok
    else
      {:error, {:invalid_format, format: :email}}
    end
  end

  defp validate_format(value, :url) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> :ok
      _ -> {:error, {:invalid_format, format: :url}}
    end
  end

  defp validate_format(value, :ip_address) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, {:invalid_format, format: :ip_address}}
    end
  end

  defp validate_format(value, regex) when is_binary(value) and is_struct(regex, Regex) do
    if Regex.match?(regex, value) do
      :ok
    else
      {:error, {:invalid_format, pattern: inspect(regex)}}
    end
  end

  defp validate_custom(_value, nil), do: :ok

  defp validate_custom(value, validator) when is_function(validator, 1) do
    validator.(value)
  end

  defp validate_field(value, spec, path) when is_map(spec) do
    # Check if this is a field specification (has :type key) or nested config
    if Map.has_key?(spec, :type) or Map.has_key?(spec, :required) do
      validate_value(value, spec)
    else
      # It's a nested configuration
      if is_map(value) do
        errors = deep_validate(value, spec, path)

        case errors do
          [] -> :ok
          _ -> {:error, {:nested_errors, errors}}
        end
      else
        {:error, {:invalid_type, expected: :map, got: type_of(value)}}
      end
    end
  end

  defp collect_validation_errors(_config, schema, path) do
    deep_validate(config, schema, path)
  end

  defp type_of(value) do
    cond do
      is_binary(value) -> :string
      is_integer(value) -> :integer
      is_float(value) -> :float
      is_boolean(value) -> :boolean
      is_atom(value) -> :atom
      is_list(value) -> :list
      is_map(value) -> :map
      true -> :unknown
    end
  end

  @doc """
  Generates a validation report for a configuration.
  """
  def validation_report(_config, schema) do
    case validate_config(config, schema) do
      :ok ->
        %{
          valid: true,
          errors: [],
          warnings: collect_warnings(_config, schema)
        }

      {:error, {:validation_failed, errors}} ->
        %{
          valid: false,
          errors: format_errors(errors),
          warnings: collect_warnings(config, schema)
        }
    end
  end

  defp format_errors(errors) do
    Enum.map(errors, fn {path, reason} ->
      %{
        path: Enum.join(path, "."),
        error: format_error_reason(reason)
      }
    end)
  end

  defp format_error_reason({:invalid_type, opts}) do
    "Invalid type: expected #{opts[:expected]}, got #{opts[:got]}"
  end

  defp format_error_reason({:invalid_enum_value, opts}) do
    "Invalid value '#{opts[:value]}'. Allowed values: #{inspect(opts[:allowed])}"
  end

  defp format_error_reason({:below_minimum, opts}) do
    "Value #{opts[:value]} is below minimum #{opts[:min]}"
  end

  defp format_error_reason({:above_maximum, opts}) do
    "Value #{opts[:value]} is above maximum #{opts[:max]}"
  end

  defp format_error_reason(:required_field_missing) do
    "Required field is missing"
  end

  defp format_error_reason(_reason) do
    inspect(reason)
  end

  defp collect_warnings(_config, schema) do
    # Collect deprecation warnings, unused fields, etc.
    unused = find_unused_fields(config, schema)
    deprecated = find_deprecated_fields(config, schema)

    warnings = []

    warnings =
      if unused != [] do
        [%{type: :unused_fields, fields: unused} | warnings]
      else
        warnings
      end

    warnings =
      if deprecated != [] do
        [%{type: :deprecated_fields, fields: deprecated} | warnings]
      else
        warnings
      end

    warnings
  end

  defp find_unused_fields(_config, schema) do
    config_keys = extract_all_keys(config)
    schema_keys = extract_all_keys(schema)

    MapSet.difference(config_keys, schema_keys)
    |> MapSet.to_list()
  end

  defp find_deprecated_fields(_config, schema, path \\ []) do
    Enum.flat_map(schema, fn {key, spec} ->
      if Map.get(spec, :deprecated, false) and Map.has_key?(config, key) do
        [Enum.join(path ++ [key], ".")]
      else
        []
      end
    end)
  end

  defp extract_all_keys(map, path \\ [], acc \\ MapSet.new()) do
    Enum.reduce(map, acc, fn {key, value}, acc ->
      current_path = Enum.join(path ++ [key], ".")
      acc = MapSet.put(acc, current_path)

      if is_map(value) and not Map.has_key?(value, :type) do
        extract_all_keys(value, path ++ [key], acc)
      else
        acc
      end
    end)
  end
end
