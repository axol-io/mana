defmodule Common.RefactoringPatterns do
  @moduledoc """
  Common functional refactoring patterns to replace imperative code.

  This module demonstrates how to transform common imperative patterns
  into functional equivalents.
  """

  import Common.Functional

  @doc """
  Replace imperative if-else chains with pattern matching.

  ## Instead of:
      if condition1 do
        action1()
      else
        if condition2 do
          action2()
        else
          action3()
        end
      end

  ## Use:
      cond_chain([
        {condition1, &action1/0},
        {condition2, &action2/0},
        {true, &action3/0}
      ])
  """
  def cond_chain(conditions) do
    conditions
    |> Enum.find(fn {cond, _} -> cond end)
    |> case do
      {_, action} -> action.()
      nil -> {:error, "No condition matched"}
    end
  end

  @doc """
  Replace imperative loops with functional pipelines.

  ## Instead of:
      result = []
      for item <- items do
        if condition(item) do
          result = [transform(item) | result]
        end
      end
      Enum.reverse(result)

  ## Use:
      filter_map(items, &condition/1, &transform/1)
  """
  def filter_map(items, filter_fn, map_fn) do
    items
    |> Stream.filter(filter_fn)
    |> Stream.map(map_fn)
    |> Enum.to_list()
  end

  @doc """
  Replace state mutations with immutable updates.

  ## Instead of:
      state = %{counter: 0}
      Enum.each(items, fn item ->
        state = Map.update!(state, :counter, &(&1 + item))
      end)

  ## Use:
      fold_state(items, %{counter: 0}, fn item, state ->
        Map.update!(state, :counter, &(&1 + item))
      end)
  """
  def fold_state(items, initial_state, update_fn) do
    Enum.reduce(items, initial_state, update_fn)
  end

  @doc """
  Replace nested if-else with railway-oriented programming.

  ## Instead of:
      if validate1(data) do
        transformed = transform1(data)
        if validate2(transformed) do
          final = transform2(transformed)
          {:ok, final}
        else
          {:error, "validation2 failed"}
        end
      else
        {:error, "validation1 failed"}
      end

  ## Use:
      railway([
        &validate1/1,
        &transform1/1,
        &validate2/1,
        &transform2/1
      ], data)
  """
  def railway(functions, initial_value) do
    chain_results({:ok, initial_value}, functions)
  end

  @doc """
  Replace imperative error handling with monadic patterns.

  ## Instead of:
      try do
        result1 = operation1()
        result2 = operation2(result1)
        result3 = operation3(result2)
        {:ok, result3}
      rescue
        e -> {:error, e}
      end

  ## Use:
      safe_chain([
        &operation1/0,
        &operation2/1,
        &operation3/1
      ])
  """
  def safe_chain(operations) do
    operations
    |> Enum.reduce({:ok, nil}, fn
      op, {:ok, _prev} when is_function(op, 0) -> safe_apply(op)
      op, {:ok, prev} -> safe_apply(op, [prev])
      _, error -> error
    end)
  end

  @doc """
  Replace imperative collection building with functional builders.

  ## Instead of:
      map = %{}
      for {k, v} <- items do
        if valid?(v) do
          map = Map.put(map, k, transform(v))
        end
      end

  ## Use:
      build_map(items, &valid?/1, &transform/1)
  """
  def build_map(items, filter_fn, transform_fn) do
    items
    |> Enum.filter(fn {_k, v} -> filter_fn.(v) end)
    |> Enum.into(%{}, fn {k, v} -> {k, transform_fn.(v)} end)
  end

  @doc """
  Replace imperative retries with functional retry logic.

  ## Instead of:
      max_attempts = 3
      attempt = 0
      result = nil
      while attempt < max_attempts and result == nil do
        result = try_operation()
        attempt = attempt + 1
      end

  ## Use:
      retry_until(&try_operation/0, max_attempts: 3)
  """
  def retry_until(operation, opts \\ []) do
    retry(operation, opts)
  end

  @doc """
  Replace imperative caching with functional memoization.

  ## Instead of:
      cache = %{}
      def get_value(key) do
        if Map.has_key?(cache, key) do
          cache[key]
        else
          value = compute_value(key)
          cache = Map.put(cache, key, value)
          value
        end
      end

  ## Use:
      memoized_compute = memoize(&compute_value/1)
      memoized_compute.(key)
  """
  def create_memoized(fun, opts \\ []) do
    memoize(fun, opts)
  end

  @doc """
  Replace imperative aggregations with functional reducers.

  ## Instead of:
      totals = %{sum: 0, count: 0, max: 0}
      for item <- items do
        totals = %{
          sum: totals.sum + item.value,
          count: totals.count + 1,
          max: max(totals.max, item.value)
        }
      end

  ## Use:
      aggregate(items, %{sum: 0, count: 0, max: 0}, [
        {:sum, &(&1 + &2.value)},
        {:count, &(&1 + 1)},
        {:max, &max(&1, &2.value)}
      ])
  """
  def aggregate(items, initial, aggregators) do
    Enum.reduce(items, initial, fn item, acc ->
      aggregators
      |> Enum.reduce(acc, fn {key, agg_fn}, inner_acc ->
        Map.update!(inner_acc, key, &agg_fn.(&1, item))
      end)
    end)
  end

  @doc """
  Replace imperative validations with composable validators.

  ## Instead of:
      errors = []
      if !valid_name?(data.name) do
        errors = ["Invalid name" | errors]
      end
      if !valid_email?(data.email) do
        errors = ["Invalid email" | errors]
      end
      if errors == [] do
        {:ok, data}
      else
        {:error, errors}
      end

  ## Use:
      validate_fields(data, [
        {:name, &valid_name?/1, "Invalid name"},
        {:email, &valid_email?/1, "Invalid email"}
      ])
  """
  def validate_fields(data, field_validators) do
    errors =
      field_validators
      |> Enum.map(fn {field, validator, error_msg} ->
        value = Map.get(data, field)
        if validator.(value), do: nil, else: error_msg
      end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(errors) do
      {:ok, data}
    else
      {:error, errors}
    end
  end

  @doc """
  Replace imperative transformations with lenses.

  ## Instead of:
      user = get_user()
      address = user.profile.address
      updated_address = Map.put(address, :city, "New York")
      updated_profile = Map.put(user.profile, :address, updated_address)
      updated_user = Map.put(user, :profile, updated_profile)

  ## Use:
      lens_update(user, [:profile, :address, :city], "New York")
  """
  def lens_update(data, path, value) do
    put_in(data, Enum.map(path, &Access.key(&1)), value)
  end

  def lens_get(data, path) do
    get_in(data, Enum.map(path, &Access.key(&1)))
  end

  @doc """
  Replace imperative batch processing with transducers.

  ## Instead of:
      results = []
      for batch <- chunks do
        processed = process_batch(batch)
        filtered = filter_results(processed)
        results = results ++ filtered
      end

  ## Use:
      transduce(chunks, [
        &process_batch/1,
        &filter_results/1
      ])
  """
  def transduce(data, transformations) do
    transformations
    |> Enum.reduce(data, fn transform, acc ->
      if is_list(acc) do
        Enum.flat_map(acc, transform)
      else
        transform.(acc)
      end
    end)
  end

  @doc """
  Replace imperative side effects with IO monads.

  ## Instead of:
      Logger.info("Starting")
      result = compute()
      Logger.info("Computed: " <> inspect(result))
      save_to_db(result)
      Logger.info("Saved")
      result

  ## Use:
      with_logging([
        {"Starting", &compute/0},
        {"Computed", &save_to_db/1},
        {"Saved", &Function.identity/1}
      ])
  """
  def with_logging(steps) do
    steps
    |> Enum.reduce({:ok, nil}, fn
      {msg, fun}, {:ok, prev} ->
        require Logger
        Logger.info(msg)

        result = if is_function(fun, 0), do: fun.(), else: fun.(prev)
        {:ok, result}

      _, error ->
        error
    end)
  end

  @doc """
  Replace imperative resource management with bracket pattern.

  ## Instead of:
      file = File.open!("data.txt")
      try do
        data = IO.read(file, :all)
        process(data)
      after
        File.close(file)
      end

  ## Use:
      with_resource(
        fn -> File.open!("data.txt") end,
        &File.close/1,
        fn file -> IO.read(file, :all) |> process() end
      )
  """
  def with_resource(acquire, release, use) do
    resource = acquire.()

    try do
      use.(resource)
    after
      release.(resource)
    end
  end
end
