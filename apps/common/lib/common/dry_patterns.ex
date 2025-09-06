defmodule Common.DRYPatterns do
  @moduledoc """
  DRY (Don't Repeat Yourself) utilities for common patterns in the Mana codebase.

  This module extracts repeated patterns found throughout the codebase
  into reusable, composable functions.
  """

  require Logger

  # Common GenServer patterns
  defmodule GenServerPatterns do
    @moduledoc """
    Common GenServer patterns to reduce boilerplate.
    """

    @doc """
    Standard init with state setup and scheduling.
    """
    defmacro standard_init(initial_state, schedule_functions \\ []) do
      quote do
        def init(opts) do
          state = unquote(initial_state).(opts)

          unquote(schedule_functions)
          |> Enum.each(fn {func, interval} ->
            Process.send_after(self(), func, interval)
          end)

          Logger.info("#{__MODULE__} initialized")
          {:ok, state}
        end
      end
    end

    @doc """
    Standard cleanup handler with rescheduling.
    """
    defmacro cleanup_handler(cleanup_fn, interval_key \\ :cleanup_interval) do
      quote do
        def handle_info(:cleanup, _state) do
          new_state = unquote(cleanup_fn).(state)
          interval = get_in(state, [:config, unquote(interval_key)])
          Process.send_after(self(), :cleanup, interval)
          {:noreply, new_state}
        end
      end
    end

    @doc """
    Standard call handler with metrics tracking.
    """
    defmacro tracked_call(name, handler_fn) do
      quote do
        def handle_call(unquote(name), from, state) do
          start_time = System.monotonic_time()

          {reply, new_state} = unquote(handler_fn).(state, from)

          duration = System.monotonic_time() - start_time
          tracked_state = update_in(new_state, [:metrics, unquote(name)], &[duration | &1 || []])

          {:reply, reply, tracked_state}
        end
      end
    end
  end

  # Common validation patterns
  defmodule ValidationPatterns do
    @moduledoc """
    DRY validation patterns found across the codebase.
    """

    @doc """
    Standard transaction validation used in multiple modules.
    """
    def validate_transaction(tx, config \\ %{}) do
      min_gas = Map.get(config, :min_gas_price, 1_000_000_000)
      max_gas_limit = Map.get(config, :max_gas_limit, 8_000_000)

      validators = [
        {:gas_price, &(&1 >= min_gas), "Gas price too low"},
        {:gas_limit, &(&1 >= 21_000 and &1 <= max_gas_limit), "Invalid gas limit"},
        {:nonce, &(&1 >= 0), "Invalid nonce"},
        {:signature, &valid_signature?/1, "Invalid signature"}
      ]

      validators
      |> Enum.reduce_while({:ok, tx}, fn {field, validator, error}, {:ok, transaction} ->
        value = Map.get(transaction, field)

        if validator.(value) do
          {:cont, {:ok, transaction}}
        else
          {:halt, {:error, error}}
        end
      end)
    end

    defp valid_signature?(tx) do
      tx.v > 0 and tx.r > 0 and tx.s > 0
    end

    @doc """
    Standard address validation.
    """
    def validate_address(address) when byte_size(address) == 20, do: {:ok, address}
    def validate_address(_), do: {:error, "Invalid address"}

    @doc """
    Standard hash validation.
    """
    def validate_hash(hash, size \\ 32)
    def validate_hash(hash, size) when byte_size(hash) == size, do: {:ok, hash}
    def validate_hash(_, _), do: {:error, "Invalid hash"}
  end

  # Common collection patterns
  defmodule CollectionPatterns do
    @moduledoc """
    DRY patterns for collection manipulation.
    """

    @doc """
    Standard reduce with accumulator pattern.
    """
    def reduce_with_acc(collection, initial, update_fn) do
      Enum.reduce(collection, initial, fn item, acc ->
        update_fn.(item, acc)
      end)
    end

    @doc """
    Index building pattern used in many modules.
    """
    def build_index(collection, key_fn, value_fn \\ &Function.identity/1) do
      collection
      |> Enum.reduce(%{}, fn item, index ->
        key = key_fn.(item)
        value = value_fn.(item)
        Map.update(index, key, [value], &[value | &1])
      end)
      |> Enum.into(%{}, fn {k, v} -> {k, Enum.reverse(v)} end)
    end

    @doc """
    Batch processing pattern.
    """
    def process_in_batches(collection, batch_size, process_fn) do
      collection
      |> Enum.chunk_every(batch_size)
      |> Enum.flat_map(process_fn)
    end

    @doc """
    Priority queue pattern.
    """
    def maintain_top_n(collection, n, priority_fn) do
      collection
      |> Enum.sort_by(priority_fn, &>=/2)
      |> Enum.take(n)
    end
  end

  # Common state update patterns
  defmodule StatePatterns do
    @moduledoc """
    DRY patterns for state management.
    """

    @doc """
    Update stats in state.
    """
    def update_stats(state, stat_key, increment \\ 1) do
      update_in(state, [:stats, stat_key], &((&1 || 0) + increment))
    end

    @doc """
    Update metrics with timestamp.
    """
    def record_metric(state, metric_key, value) do
      entry = %{value: value, timestamp: System.system_time(:second)}
      update_in(state, [:metrics, metric_key], &[entry | &1 || []])
    end

    @doc """
    Cleanup old entries from state.
    """
    def cleanup_old_entries(state, field, max_age_seconds) do
      current_time = System.system_time(:second)
      cutoff = current_time - max_age_seconds

      cleaned =
        state
        |> Map.get(field, [])
        |> Enum.filter(fn entry ->
          Map.get(entry, :timestamp, current_time) > cutoff
        end)

      Map.put(state, field, cleaned)
    end

    @doc """
    Cache pattern with TTL.
    """
    def cached_lookup(cache, key, ttl, compute_fn) do
      current_time = System.system_time(:second)

      case Map.get(cache, key) do
        {value, timestamp} when timestamp > current_time - ttl ->
          {:cached, value}

        _ ->
          value = compute_fn.()
          updated_cache = Map.put(cache, key, {value, current_time})
          {:computed, value, updated_cache}
      end
    end
  end

  # Common error handling patterns
  defmodule ErrorPatterns do
    @moduledoc """
    DRY error handling patterns.
    """

    @doc """
    Standard error wrapping.
    """
    def wrap_error(operation, context) do
      case operation.() do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, %{reason: reason, context: context}}
      end
    end

    @doc """
    Retry with backoff pattern.
    """
    def retry_with_backoff(operation, opts \\ []) do
      max_attempts = Keyword.get(opts, :max_attempts, 3)
      base_delay = Keyword.get(opts, :base_delay, 100)

      do_retry(operation, max_attempts, base_delay, 1)
    end

    defp do_retry(operation, max_attempts, base_delay, attempt) do
      case operation.() do
        {:ok, _} = success ->
          success

        {:error, _} = error when attempt >= max_attempts ->
          error

        {:error, _} ->
          delay = (base_delay * :math.pow(2, attempt - 1)) |> round()
          Process.sleep(delay)
          do_retry(operation, max_attempts, base_delay, attempt + 1)
      end
    end

    @doc """
    Circuit breaker pattern.
    """
    def with_circuit_breaker(operation, breaker_name, opts \\ []) do
      threshold = Keyword.get(opts, :failure_threshold, 5)
      timeout = Keyword.get(opts, :timeout, 60_000)

      # Simplified circuit breaker - always closed for now
      # Full circuit breaker with failure tracking can be implemented later
      case operation.() do
        {:ok, _} = success ->
          reset_breaker(breaker_name)
          success

        {:error, _} = error ->
          increment_breaker(breaker_name, threshold, timeout)
          error
      end
    end

    defp reset_breaker(_name), do: :ok
    defp increment_breaker(_name, _threshold, _timeout), do: :ok
  end

  # Common logging patterns
  defmodule LoggingPatterns do
    @moduledoc """
    DRY logging patterns.
    """

    @doc """
    Structured logging with context.
    """
    defmacro log_with_context(level, message, context) do
      quote do
        Logger.unquote(level)(
          unquote(message),
          Enum.into(unquote(context), [])
        )
      end
    end

    @doc """
    Performance logging wrapper.
    """
    def with_timing(name, operation) do
      start = System.monotonic_time()
      result = operation.()
      duration = System.monotonic_time() - start

      Logger.debug("#{name} completed in #{duration}μs")
      result
    end

    @doc """
    Audit logging pattern.
    """
    def audit_log(action, user, details) do
      entry = %{
        action: action,
        user: user,
        details: details,
        timestamp: DateTime.utc_now(),
        id: generate_audit_id()
      }

      Logger.info("AUDIT: #{inspect(entry)}")
      {:ok, entry}
    end

    defp generate_audit_id do
      :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    end
  end

  # Common async patterns
  defmodule AsyncPatterns do
    @moduledoc """
    DRY async processing patterns.
    """

    @doc """
    Parallel map with timeout.
    """
    def parallel_map(collection, fun, timeout \\ 5000) do
      collection
      |> Enum.map(&Task.async(fn -> fun.(&1) end))
      |> Task.await_many(timeout)
    end

    @doc """
    Rate limited processing.
    """
    def rate_limited_process(items, fun, rate_per_second) do
      delay = div(1000, rate_per_second)

      items
      |> Enum.map(fn item ->
        Process.sleep(delay)
        fun.(item)
      end)
    end

    @doc """
    Batch async processing.
    """
    def batch_async(items, batch_size, fun) do
      items
      |> Enum.chunk_every(batch_size)
      |> Enum.flat_map(fn batch ->
        batch
        |> Enum.map(&Task.async(fn -> fun.(&1) end))
        |> Task.await_many()
      end)
    end
  end

  # Common configuration patterns
  defmodule ConfigPatterns do
    @moduledoc """
    DRY configuration patterns.
    """

    @doc """
    Merge configurations with defaults.
    """
    def with_defaults(config, defaults) do
      Map.merge(defaults, config || %{})
    end

    @doc """
    Validate configuration against schema.
    """
    def validate_config(config, schema) do
      schema
      |> Enum.reduce_while({:ok, config}, fn {key, validator}, {:ok, cfg} ->
        case Map.fetch(cfg, key) do
          {:ok, value} ->
            case validator.(value) do
              true -> {:cont, {:ok, cfg}}
              false -> {:halt, {:error, "Invalid config for #{key}"}}
            end

          :error when is_function(validator, 0) ->
            # Optional field
            {:cont, {:ok, cfg}}

          :error ->
            {:halt, {:error, "Missing required config: #{key}"}}
        end
      end)
    end

    @doc """
    Environment-based configuration.
    """
    def from_env(key, default \\ nil, transform \\ &Function.identity/1) do
      case System.get_env(key) do
        nil -> default
        value -> transform.(value)
      end
    end
  end
end
