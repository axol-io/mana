defmodule Blockchain.ErrorHandler do
  @moduledoc """
  Centralized error handling with proper context propagation.
  Replaces generic error swallowing with structured error handling.

  Features:
  - Structured error types
  - Context preservation
  - Error categorization
  - Telemetry integration
  - Circuit breaker integration
  """

  require Logger

  @type error_category :: :validation | :network | :storage | :crypto | :consensus | :internal

  @type error_context :: %{
          optional(:module) => module(),
          optional(:function) => atom(),
          optional(:line) => non_neg_integer(),
          optional(:request_id) => String.t(),
          optional(:user_data) => map(),
          optional(:timestamp) => DateTime.t()
        }

  @type structured_error :: %{
          category: error_category(),
          message: String.t(),
          details: term(),
          context: error_context(),
          recoverable: boolean(),
          retry_after: non_neg_integer() | nil
        }

  @doc """
  Wraps a function call with comprehensive error handling.

  ## Examples

      with_error_handling(:network, fn ->
        make_network_call()
      end)
  """
  @spec with_error_handling(error_category(), (-> any()), keyword()) ::
          {:ok, any()} | {:error, structured_error()}
  def with_error_handling(category, fun, opts \\ []) do
    context = build_context(opts)

    try do
      result = fun.()
      {:ok, result}
    rescue
      e in [ArgumentError, KeyError, MatchError] ->
        handle_validation_error(e, category, context)

      e in [RuntimeError, ErlangError] ->
        handle_runtime_error(e, category, context)

      e ->
        handle_generic_error(e, category, context)
    catch
      :exit, reason ->
        handle_exit(reason, category, context)

      kind, reason ->
        handle_throw(kind, reason, category, context)
    end
  end

  @doc """
  Enhanced error handling for GenServer calls with timeout protection.
  """
  @spec safe_call(atom() | pid(), term(), timeout(), keyword()) ::
          {:ok, any()} | {:error, structured_error()}
  def safe_call(server, request, timeout \\ 5000, opts \\ []) do
    context = build_context(opts)

    try do
      result = GenServer.call(server, request, timeout)
      {:ok, result}
    catch
      :exit, {:timeout, _} ->
        error =
          build_error(
            :network,
            "GenServer call timeout",
            {:timeout, server, request},
            context,
            true,
            calculate_backoff(1)
          )

        emit_telemetry(:timeout, error)
        {:error, error}

      :exit, {:noproc, _} ->
        error =
          build_error(
            :internal,
            "Process not found",
            {:noproc, server},
            context,
            false,
            nil
          )

        emit_telemetry(:noproc, error)
        {:error, error}

      :exit, reason ->
        handle_exit(reason, :internal, context)
    end
  end

  @doc """
  Converts traditional {:ok, result} | {:error, reason} to structured errors.
  """
  @spec normalize_error({:ok, any()} | {:error, any()}, error_category(), keyword()) ::
          {:ok, any()} | {:error, structured_error()}
  def normalize_error({:ok, _} = result, _category, _opts), do: result

  def normalize_error({:error, reason}, category, opts) do
    context = build_context(opts)

    error =
      case reason do
        %{__struct__: _} = struct_error ->
          build_error(
            category,
            inspect(struct_error),
            struct_error,
            context,
            is_recoverable?(struct_error),
            nil
          )

        binary when is_binary(binary) ->
          build_error(category, binary, nil, context, true, nil)

        atom when is_atom(atom) ->
          build_error(category, to_string(atom), atom, context, true, nil)

        other ->
          build_error(category, inspect(other), other, context, false, nil)
      end

    {:error, error}
  end

  @doc """
  Chain multiple operations with error handling.
  Similar to `with` but with structured error handling.
  """
  defmacro pipeline(category, do: block) do
    quote do
      context =
        Blockchain.ErrorHandler.build_context(
          module: __MODULE__,
          function: elem(__ENV__.function, 0),
          line: __ENV__.line
        )

      try do
        unquote(block)
      rescue
        e ->
          Blockchain.ErrorHandler.handle_generic_error(
            e,
            unquote(category),
            context
          )
      end
    end
  end

  @doc """
  Retry logic with exponential backoff and circuit breaker integration.
  """
  @spec with_retry(error_category(), (-> any()), keyword()) ::
          {:ok, any()} | {:error, structured_error()}
  def with_retry(category, fun, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    backoff_base = Keyword.get(opts, :backoff_base, 100)
    circuit_breaker = Keyword.get(opts, :circuit_breaker, nil)

    do_retry(category, fun, opts, max_retries, backoff_base, 0, circuit_breaker)
  end

  # Private Functions

  defp do_retry(_category, _fun, opts, max_retries, _backoff, attempt, _cb)
       when attempt >= max_retries do
    context = build_context(opts)

    error =
      build_error(
        :internal,
        "Max retries exceeded",
        {:max_retries, max_retries},
        context,
        false,
        nil
      )

    {:error, error}
  end

  defp do_retry(category, fun, opts, max_retries, backoff_base, attempt, circuit_breaker) do
    # Check circuit breaker if provided
    # Note: Current CircuitBreaker implementation always returns {:ok, :closed}
    # This is a stub that can be enhanced in the future
    if circuit_breaker do
      case Common.CircuitBreaker.get_state(circuit_breaker) do
        {:ok, :closed} -> :ok
        # Future-proof for other states
        _ -> :ok
      end
    end

    case with_error_handling(category, fun, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, %{recoverable: true} = _error} ->
        backoff_time = calculate_backoff(attempt, backoff_base)
        Logger.warning("Retrying after #{backoff_time}ms (attempt #{attempt + 1}/#{max_retries})")
        Process.sleep(backoff_time)

        do_retry(category, fun, opts, max_retries, backoff_base, attempt + 1, circuit_breaker)

      {:error, %{recoverable: false} = error} ->
        {:error, error}
    end
  end

  defp build_context(opts) do
    %{
      module: Keyword.get(opts, :module),
      function: Keyword.get(opts, :function),
      line: Keyword.get(opts, :line),
      request_id: Keyword.get(opts, :request_id),
      user_data: Keyword.get(opts, :user_data, %{}),
      timestamp: DateTime.utc_now()
    }
  end

  defp build_error(category, message, details, context, recoverable, retry_after) do
    %{
      category: category,
      message: message,
      details: details,
      context: context,
      recoverable: recoverable,
      retry_after: retry_after
    }
  end

  defp handle_validation_error(error, category, context) do
    error_struct =
      build_error(
        category,
        Exception.message(error),
        error,
        context,
        false,
        nil
      )

    Logger.error("Validation error: #{inspect(error_struct)}")
    emit_telemetry(:validation_error, error_struct)
    {:error, error_struct}
  end

  defp handle_runtime_error(error, category, context) do
    error_struct =
      build_error(
        category,
        Exception.message(error),
        error,
        context,
        true,
        calculate_backoff(1)
      )

    Logger.error("Runtime error: #{inspect(error_struct)}")
    emit_telemetry(:runtime_error, error_struct)
    {:error, error_struct}
  end

  defp handle_generic_error(error, category, context) do
    error_struct =
      build_error(
        category,
        inspect(error),
        error,
        context,
        false,
        nil
      )

    Logger.error("Generic error: #{inspect(error_struct)}")
    emit_telemetry(:generic_error, error_struct)
    {:error, error_struct}
  end

  defp handle_exit(reason, category, context) do
    error_struct =
      build_error(
        category,
        "Process exit: #{inspect(reason)}",
        {:exit, reason},
        context,
        is_recoverable_exit?(reason),
        nil
      )

    Logger.error("Process exit: #{inspect(error_struct)}")
    emit_telemetry(:process_exit, error_struct)
    {:error, error_struct}
  end

  defp handle_throw(kind, reason, category, context) do
    error_struct =
      build_error(
        category,
        "Caught #{kind}: #{inspect(reason)}",
        {kind, reason},
        context,
        false,
        nil
      )

    Logger.error("Caught throw: #{inspect(error_struct)}")
    emit_telemetry(:caught_throw, error_struct)
    {:error, error_struct}
  end

  defp is_recoverable?(%{recoverable: recoverable}), do: recoverable
  defp is_recoverable?(_), do: false

  defp is_recoverable_exit?({:timeout, _}), do: true
  defp is_recoverable_exit?({:normal, _}), do: false
  defp is_recoverable_exit?({:shutdown, _}), do: false
  defp is_recoverable_exit?(_), do: false

  defp calculate_backoff(attempt, base \\ 100) do
    min(base * :math.pow(2, attempt), 30_000) |> trunc()
  end

  defp emit_telemetry(event_type, error) do
    :telemetry.execute(
      [:blockchain, :error, event_type],
      %{count: 1},
      %{
        category: error.category,
        recoverable: error.recoverable,
        module: error.context[:module],
        function: error.context[:function]
      }
    )
  end
end
