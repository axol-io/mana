defmodule Common.Functional do
  @moduledoc """
  Functional programming utilities and patterns for the Mana codebase.

  This module provides:
  - Function composition operators
  - Pipeline helpers
  - Monadic patterns (Result, Maybe)
  - Common higher-order functions
  - Validation combinators
  """

  # Result Monad Pattern
  @type result(ok, error) :: {:ok, ok} | {:error, error}

  @doc """
  Compose multiple functions into a single function.
  Functions are applied from right to left.

  ## Example
      iex> add_one = &(&1 + 1)
      iex> double = &(&1 * 2)
      iex> composed = compose([double, add_one])
      iex> composed.(5)
      12
  """
  @spec compose([function()]) :: function()
  def compose(functions) when is_list(functions) do
    fn input ->
      functions
      |> Enum.reverse()
      |> Enum.reduce(input, fn f, acc -> f.(acc) end)
    end
  end

  @doc """
  Pipe operator for function composition (left-to-right).
  """
  defmacro pipe(value, functions) do
    quote do
      unquote(functions)
      |> Enum.reduce(unquote(value), fn f, acc -> f.(acc) end)
    end
  end

  @doc """
  Maps over a successful result, leaving errors unchanged.

  ## Example
      iex> map_ok({:ok, 5}, &(&1 * 2))
      {:ok, 10}
      iex> map_ok({:error, "failed"}, &(&1 * 2))
      {:error, "failed"}
  """
  @spec map_ok(result(a, e), (a -> b)) :: result(b, e) when a: var, b: var, e: var
  def map_ok({:ok, value}, fun), do: {:ok, fun.(value)}
  def map_ok({:error, _} = error, _fun), do: error

  @doc """
  Flat maps over a successful result (monadic bind).
  """
  @spec flat_map_ok(result(a, e), (a -> result(b, e))) :: result(b, e) when a: var, b: var, e: var
  def flat_map_ok({:ok, value}, fun), do: fun.(value)
  def flat_map_ok({:error, _} = error, _fun), do: error

  @doc """
  Chains multiple result-returning functions together.

  ## Example
      iex> chain_results({:ok, 5}, [
      ...>   &({:ok, &1 * 2}),
      ...>   &({:ok, &1 + 1})
      ...> ])
      {:ok, 11}
  """
  @spec chain_results(result(a, e), [(a -> result(b, e))]) :: result(b, e)
        when a: var, b: var, e: var
  def chain_results(initial, functions) do
    Enum.reduce(functions, initial, &flat_map_ok(&2, &1))
  end

  @doc """
  Validates a value against multiple validators.
  All validators must pass for success.
  """
  @spec validate_all(any(), [validator]) :: result(any(), String.t())
        when validator: (any() -> result(any(), String.t()))
  def validate_all(value, validators) do
    validators
    |> Enum.reduce_while({:ok, value}, fn validator, {:ok, val} ->
      case validator.(val) do
        {:ok, _} = success -> {:cont, success}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Creates a validator that checks if a value satisfies a predicate.
  """
  @spec validator((any() -> boolean()), String.t()) :: (any() -> result(any(), String.t()))
  def validator(predicate, error_message) do
    fn value ->
      if predicate.(value) do
        {:ok, value}
      else
        {:error, error_message}
      end
    end
  end

  @doc """
  Combines multiple validators with OR logic.
  First successful validator wins.
  """
  @spec validate_any(any(), [validator]) :: result(any(), String.t())
        when validator: (any() -> result(any(), String.t()))
  def validate_any(value, validators) do
    validators
    |> Enum.reduce_while({:error, "No validators passed"}, fn validator, _acc ->
      case validator.(value) do
        {:ok, _} = success -> {:halt, success}
        {:error, _} -> {:cont, {:error, "All validators failed"}}
      end
    end)
  end

  @doc """
  Memoizes a function with configurable cache.
  """
  @spec memoize(function(), keyword()) :: function()
  def memoize(fun, opts \\ []) do
    cache_name = Keyword.get(opts, :cache_name, :memoize_cache)
    ttl = Keyword.get(opts, :ttl, :infinity)

    if !:ets.whereis(cache_name) do
      :ets.new(cache_name, [:set, :public, :named_table])
    end

    fn args ->
      key = :erlang.phash2(args)
      now = System.system_time(:second)

      case :ets.lookup(cache_name, key) do
        [{^key, result, timestamp}] when ttl == :infinity or now - timestamp < ttl ->
          result

        _ ->
          result = apply(fun, args)
          :ets.insert(cache_name, {key, result, now})
          result
      end
    end
  end

  @doc """
  Partially applies a function with the given arguments.
  """
  @spec partial(function(), list()) :: function()
  def partial(fun, args) when is_function(fun) and is_list(args) do
    fn more_args -> apply(fun, args ++ more_args) end
  end

  @doc """
  Curries a function to accept arguments one at a time.
  """
  @spec curry(function(), non_neg_integer()) :: function()
  def curry(fun, arity) when is_function(fun, arity) do
    curry_helper(fun, arity, [])
  end

  defp curry_helper(fun, 0, args) do
    apply(fun, Enum.reverse(args))
  end

  defp curry_helper(fun, arity, args) do
    fn arg -> curry_helper(fun, arity - 1, [arg | args]) end
  end

  @doc """
  Applies a function and wraps the result in a Result type.
  Catches exceptions and converts them to errors.
  """
  @spec safe_apply(function(), list()) :: result(any(), String.t())
  def safe_apply(fun, args \\ []) do
    {:ok, apply(fun, args)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc """
  Converts a list of results into a result of a list.
  Fails if any element is an error.
  """
  @spec sequence([result(a, e)]) :: result([a], e) when a: var, e: var
  def sequence(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _} = error, _ -> {:halt, error}
    end)
    |> map_ok(&Enum.reverse/1)
  end

  @doc """
  Maps a function over a list, collecting successful results.
  Returns error if any mapping fails.
  """
  @spec traverse(list(), (any() -> result(any(), e))) :: result(list(), e) when e: var
  def traverse(list, fun) do
    list
    |> Enum.map(fun)
    |> sequence()
  end

  @doc """
  Taps into a pipeline for side effects without changing the value.
  """
  @spec tap(a, (a -> any())) :: a when a: var
  def tap(value, fun) do
    fun.(value)
    value
  end

  @doc """
  Retries a function with exponential backoff.
  """
  @spec retry(function(), keyword()) :: result(any(), any())
  def retry(fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    base_delay = Keyword.get(opts, :base_delay, 100)

    retry_helper(fun, max_attempts, base_delay, 1)
  end

  defp retry_helper(fun, max_attempts, base_delay, attempt) do
    case safe_apply(fun) do
      {:ok, _} = success ->
        success

      {:error, _} = error when attempt >= max_attempts ->
        error

      {:error, _} ->
        delay = (base_delay * :math.pow(2, attempt - 1)) |> round()
        Process.sleep(delay)
        retry_helper(fun, max_attempts, base_delay, attempt + 1)
    end
  end

  @doc """
  Groups elements by a key function and maps values.
  More functional alternative to Enum.group_by.
  """
  @spec group_map_by(Enumerable.t(), (any() -> any()), (any() -> any())) :: map()
  def group_map_by(enumerable, key_fun, value_fun) do
    enumerable
    |> Enum.reduce(%{}, fn element, acc ->
      key = key_fun.(element)
      value = value_fun.(element)
      Map.update(acc, key, [value], &[value | &1])
    end)
    |> Enum.into(%{}, fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  @doc """
  Flattens nested results.
  """
  @spec flatten_result(result(result(a, e), e)) :: result(a, e) when a: var, e: var
  def flatten_result({:ok, {:ok, value}}), do: {:ok, value}
  def flatten_result({:ok, {:error, _} = error}), do: error
  def flatten_result({:error, _} = error), do: error

  @doc """
  Converts a boolean to a result type.
  """
  @spec bool_to_result(boolean(), any(), String.t()) :: result(any(), String.t())
  def bool_to_result(true, value, _error_msg), do: {:ok, value}
  def bool_to_result(false, _value, error_msg), do: {:error, error_msg}

  @doc """
  Lazy evaluation helper.
  """
  defmacro lazy(expression) do
    quote do
      fn -> unquote(expression) end
    end
  end

  @doc """
  Forces evaluation of a lazy value.
  """
  @spec force(function() | any()) :: any()
  def force(fun) when is_function(fun, 0), do: fun.()
  def force(value), do: value

  @doc """
  Creates a pipeline of transformations with error handling.
  Each function should return {:ok, value} or {:error, _reason}.
  """
  defmacro pipeline(initial, do: block) do
    steps = extract_pipeline_steps(block)

    quote do
      unquote(steps)
      |> Common.Functional.chain_results(unquote(initial))
    end
  end

  defp extract_pipeline_steps({:__block__, _, steps}), do: steps
  defp extract_pipeline_steps(single_step), do: [single_step]
end
