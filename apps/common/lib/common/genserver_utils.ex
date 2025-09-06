defmodule Common.GenServerUtils do
  @moduledoc """
  Centralized utility module for GenServer calls with configurable timeouts and circuit breaker integration.

  This module provides a standardized way to make GenServer calls with:
  - Configurable timeouts
  - Circuit breaker integration (when available)
  - Telemetry events
  - Comprehensive error handling

  ## Usage

      # Basic call with default timeout
      Common.GenServerUtils.call(MyServer, :get_state)
      
      # Quick call (1 second timeout)
      Common.GenServerUtils.quick_call(MyServer, :get_stats)
      
      # Critical call (30 second timeout)
      Common.GenServerUtils.critical_call(MyServer, {:process, data})
      
      # With circuit breaker
      Common.GenServerUtils.call(MyServer, request,
        circuit_breaker: :my_breaker,
        telemetry_metadata: %{operation: :my_operation}
      )
  """

  require Logger

  # 5 seconds
  @default_timeout 5_000
  # 30 seconds for critical operations
  @critical_timeout 30_000
  # 1 second for quick operations
  @quick_timeout 1_000

  @doc """
  Makes a GenServer call with timeout and optional circuit breaker protection.

  ## Options
  - `:timeout` - Custom timeout in milliseconds (default: 5000)
  - `:circuit_breaker` - Name of circuit breaker to use (optional)
  - `:telemetry_metadata` - Additional metadata for telemetry events
  - `:telemetry_prefix` - Telemetry event prefix (default: [:common, :genserver])
  """
  @spec call(GenServer.server(), term(), keyword()) :: term()
  def call(server, request, opts \\ []) do
    timeout = opts[:timeout] || @default_timeout
    circuit_breaker = opts[:circuit_breaker]
    metadata = opts[:telemetry_metadata] || %{}
    prefix = opts[:telemetry_prefix] || [:common, :genserver]

    start_time = System.monotonic_time()

    # Check if circuit breaker module is available
    if circuit_breaker && circuit_breaker_available?() do
      execute_with_circuit_breaker(
        server,
        request,
        timeout,
        circuit_breaker,
        metadata,
        prefix,
        start_time
      )
    else
      do_call(server, request, timeout, metadata, prefix, start_time)
    end
  end

  @doc """
  Makes a call with quick timeout (1 second).
  Suitable for status checks and simple queries.
  """
  @spec quick_call(GenServer.server(), term(), keyword()) :: term()
  def quick_call(server, request, opts \\ []) do
    call(server, request, Keyword.put(opts, :timeout, @quick_timeout))
  end

  @doc """
  Makes a call with critical timeout (30 seconds).
  Suitable for complex operations that may take longer.
  """
  @spec critical_call(GenServer.server(), term(), keyword()) :: term()
  def critical_call(server, request, opts \\ []) do
    call(server, request, Keyword.put(opts, :timeout, @critical_timeout))
  end

  @doc """
  Returns default timeout values for configuration.
  """
  @spec default_timeouts() :: map()
  def default_timeouts do
    %{
      default: @default_timeout,
      critical: @critical_timeout,
      quick: @quick_timeout
    }
  end

  @doc """
  Configures timeout based on operation type.
  Can be overridden in application config.
  """
  @spec timeout_for(atom()) :: non_neg_integer()
  def timeout_for(operation) do
    # Check if custom timeouts are configured
    custom_timeouts = Application.get_env(:common, :operation_timeouts, %{})

    case Map.get(custom_timeouts, operation) do
      nil -> default_timeout_for(operation)
      timeout -> timeout
    end
  end

  # Private functions

  defp default_timeout_for(operation) do
    case operation do
      # Transaction operations
      :add_transaction -> @default_timeout
      :send_transaction -> @critical_timeout
      :get_pending -> @quick_timeout
      :get_transaction -> @quick_timeout
      :get_next_nonce -> @quick_timeout
      :get_stats -> @quick_timeout
      # Block operations
      :sync_block -> @critical_timeout
      :validate_block -> @critical_timeout
      :import_block -> @critical_timeout
      :get_block -> @default_timeout
      :create_block -> @critical_timeout
      # State operations
      :get_balance -> @quick_timeout
      :get_code -> @default_timeout
      :get_storage_at -> @default_timeout
      :get_proof -> @default_timeout
      :sync_state -> @critical_timeout
      # Network operations
      :peer_count -> @quick_timeout
      :add_peer -> @default_timeout
      :remove_peer -> @default_timeout
      :broadcast -> @default_timeout
      # Default
      _ -> @default_timeout
    end
  end

  defp circuit_breaker_available? do
    Code.ensure_loaded?(Common.CircuitBreaker)
  end

  defp execute_with_circuit_breaker(
         server,
         request,
         timeout,
         circuit_breaker,
         metadata,
         prefix,
         start_time
       ) do
    if Code.ensure_loaded?(Common.CircuitBreaker) do
      case Common.CircuitBreaker.call(circuit_breaker, fn ->
             do_call(server, request, timeout, metadata, prefix, start_time)
           end) do
        {:ok, result} ->
          result

        {:error, :circuit_open} ->
          emit_telemetry(prefix, :circuit_open, start_time, metadata, server, request)
          {:error, :circuit_breaker_open}
      end
    else
      # Circuit breaker not available, execute directly
      do_call(server, request, timeout, metadata, prefix, start_time)
    end
  end

  defp do_call(server, request, timeout, metadata, prefix, start_time) do
    try do
      result = GenServer.call(server, request, timeout)

      # Emit telemetry event for successful call
      emit_telemetry(prefix, :success, start_time, metadata, server, request)

      result
    catch
      :exit, {:timeout, _} ->
        # Emit telemetry event for timeout
        emit_telemetry(prefix, :timeout, start_time, metadata, server, request)

        Logger.error("GenServer call timeout",
          server: server,
          request: inspect(request),
          timeout: timeout
        )

        {:error, :timeout}

      :exit, {:noproc, _} ->
        # Process doesn't exist
        emit_telemetry(prefix, :noproc, start_time, metadata, server, request)

        {:error, :noproc}

      :exit, reason ->
        # Other exit reasons
        emit_telemetry(prefix, :error, start_time, metadata, server, request)

        Logger.error("GenServer call failed",
          server: server,
          request: inspect(request),
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp emit_telemetry(prefix, event, start_time, metadata, server, request) do
    :telemetry.execute(
      prefix ++ [:call, event],
      %{duration: System.monotonic_time() - start_time},
      Map.merge(metadata, %{
        server: server,
        request: inspect(request)
      })
    )
  end
end
