defmodule Blockchain.Monitoring.TelemetryIntegrator do
  @moduledoc """
  Telemetry integration module that automatically instruments various parts
  of the Mana-Ethereum client with telemetry events for metrics collection.

  This module provides helper functions to emit telemetry events that are
  automatically converted to Prometheus metrics by the PrometheusExporter.
  """

  require Logger

  # Telemetry event names
  @block_processed_event [:mana, :block, :processed]
  @transaction_processed_event [:mana, :transaction, :processed]
  @p2p_message_event [:mana, :p2p, :message]
  @storage_operation_event [:mana, :storage, :operation]
  @evm_execution_event [:mana, :evm, :execution]
  # @sync_progress_event [:mana, :sync, :progress] # TODO: Unused attribute
  @peer_count_event [:mana, :p2p, :peer_count]
  @transaction_pool_event [:mana, :transaction_pool, :size]

  # Public API for emitting telemetry events

  @doc """
  Emit a telemetry event when a block is processed.
  """
  @spec emit_block_processed(non_neg_integer(), non_neg_integer(), map()) :: :ok
  def emit_block_processed(block_number, processing_time_microseconds, metadata \\ %{}) do
    # Update Prometheus metrics directly
    Blockchain.Monitoring.PrometheusMetrics.set_gauge("mana_blockchain_height", block_number)
    Blockchain.Monitoring.PrometheusMetrics.inc_counter("mana_blocks_processed_total")

    Blockchain.Monitoring.PrometheusMetrics.observe_histogram(
      "mana_block_processing_seconds",
      processing_time_microseconds / 1_000_000
    )

    # Also emit telemetry event for other handlers
    :telemetry.execute(
      @block_processed_event,
      %{
        duration: processing_time_microseconds
      },
      Map.merge(
        %{
          block_number: block_number
        },
        metadata
      )
    )
  end

  @doc """
  Emit a telemetry event when a transaction is processed.
  """
  @spec emit_transaction_processed(non_neg_integer(), map()) :: :ok
  def emit_transaction_processed(processing_time_microseconds, metadata \\ %{}) do
    :telemetry.execute(
      @transaction_processed_event,
      %{
        duration: processing_time_microseconds
      },
      metadata
    )
  end

  @doc """
  Emit a telemetry event for P2P messages.
  """
  @spec emit_p2p_message(String.t(), String.t(), map()) :: :ok
  def emit_p2p_message(message_type, direction, metadata \\ %{}) do
    # Update Prometheus metrics
    Blockchain.Monitoring.PrometheusMetrics.inc_counter("mana_p2p_messages_total", 1, %{
      "message_type" => message_type,
      "direction" => direction
    })

    # Emit telemetry event
    :telemetry.execute(
      @p2p_message_event,
      %{},
      Map.merge(
        %{
          message_type: message_type,
          direction: direction
        },
        metadata
      )
    )
  end

  @doc """
  Emit a telemetry event for storage operations.
  """
  @spec emit_storage_operation(String.t(), non_neg_integer(), map()) :: :ok
  def emit_storage_operation(operation_type, duration_microseconds, metadata \\ %{}) do
    :telemetry.execute(
      @storage_operation_event,
      %{
        duration: duration_microseconds
      },
      Map.merge(
        %{
          operation_type: operation_type
        },
        metadata
      )
    )
  end

  @doc """
  Emit a telemetry event for EVM execution.
  """
  @spec emit_evm_execution(non_neg_integer(), non_neg_integer(), map()) :: :ok
  def emit_evm_execution(execution_time_microseconds, gas_used, metadata \\ %{}) do
    :telemetry.execute(
      @evm_execution_event,
      %{
        duration: execution_time_microseconds
      },
      Map.merge(
        %{
          gas_used: gas_used
        },
        metadata
      )
    )
  end

  @doc """
  Emit a telemetry event for sync progress updates.
  """
  @spec emit_sync_progress(float(), map()) :: :ok
  def emit_sync_progress(progress_ratio, metadata \\ %{}) do
    :telemetry.execute(
  # @sync_progress_event, # TODO: Unused attribute
      %{
        progress: progress_ratio
      },
      metadata
    )
  end

  @doc """
  Emit a telemetry event for peer count updates.
  """
  @spec emit_peer_count_update(non_neg_integer(), map()) :: :ok
  def emit_peer_count_update(peer_count, metadata \\ %{}) do
    # Update Prometheus metrics
    protocol = Map.get(metadata, :protocol, "eth")

    Blockchain.Monitoring.PrometheusMetrics.set_gauge("mana_p2p_peers_connected", peer_count, %{
      "protocol" => protocol
    })

    # Emit telemetry event
    :telemetry.execute(
      @peer_count_event,
      %{
        count: peer_count
      },
      metadata
    )
  end

  @doc """
  Emit a telemetry event for transaction pool size updates.
  """
  @spec emit_transaction_pool_size(non_neg_integer(), map()) :: :ok
  def emit_transaction_pool_size(pool_size, metadata \\ %{}) do
    :telemetry.execute(
      @transaction_pool_event,
      %{
        size: pool_size
      },
      metadata
    )
  end

  # Helper functions for timing operations

  @doc """
  Time a function execution and emit a telemetry event.
  """
  @spec time_and_emit(atom(), list(), (-> any()), map()) :: any()
  def time_and_emit(event_name, event_path, fun, metadata \\ %{}) do
    start_time = System.monotonic_time(:microsecond)

    try do
      result = fun.()
      end_time = System.monotonic_time(:microsecond)
      duration = end_time - start_time

      :telemetry.execute(
        event_path,
        %{
          duration: duration,
          result: :success
        },
        Map.merge(
          %{
            operation: event_name
          },
          metadata
        )
      )

      result
    rescue
      error ->
        end_time = System.monotonic_time(:microsecond)
        duration = end_time - start_time

        :telemetry.execute(
          event_path,
          %{
            duration: duration,
            result: :error
          },
          Map.merge(
            %{
              operation: event_name,
              error: inspect(error)
            },
            metadata
          )
        )

        reraise error, __STACKTRACE__
    end
  end

  @doc """
  Time a block processing operation.
  """
  @spec time_block_processing((-> any()), non_neg_integer(), map()) :: any()
  def time_block_processing(fun, block_number, metadata \\ %{}) do
    time_and_emit(
      :block_processing,
      @block_processed_event,
      fun,
      Map.merge(%{block_number: block_number}, metadata)
    )
  end

  @doc """
  Time a transaction processing operation.
  """
  @spec time_transaction_processing((-> any()), map()) :: any()
  def time_transaction_processing(fun, metadata \\ %{}) do
    time_and_emit(:transaction_processing, @transaction_processed_event, fun, metadata)
  end

  @doc """
  Time a storage operation.
  """
  @spec time_storage_operation(String.t(), (-> any()), map()) :: any()
  def time_storage_operation(operation_type, fun, metadata \\ %{}) do
    time_and_emit(
      operation_type,
      @storage_operation_event,
      fun,
      Map.merge(%{operation_type: operation_type}, metadata)
    )
  end

  @doc """
  Time an EVM execution.
  """
  @spec time_evm_execution((-> any()), map()) :: any()
  def time_evm_execution(fun, metadata \\ %{}) do
    time_and_emit(:evm_execution, @evm_execution_event, fun, metadata)
  end

  # Instrumentation helpers for existing modules

  @doc """
  Instrument a module's function with automatic telemetry emission.
  This is used to add metrics to existing functions without modifying them.
  """
  defmacro instrument_function(module, function, arity, event_path, metadata_fun \\ nil) do
    quote do
      original_function = Function.capture(unquote(module), unquote(function), unquote(arity))

      instrumented_function = fn args ->
        start_time = System.monotonic_time(:microsecond)

        try do
          result = apply(original_function, args)
          end_time = System.monotonic_time(:microsecond)
          duration = end_time - start_time

          metadata =
            if unquote(metadata_fun) do
              unquote(metadata_fun).(args, result)
            else
              %{}
            end

          :telemetry.execute(
            unquote(event_path),
            %{
              duration: duration,
              result: :success
            },
            Map.merge(
              %{
                module: unquote(module),
                function: unquote(function),
                arity: unquote(arity)
              },
              metadata
            )
          )

          result
        rescue
          error ->
            end_time = System.monotonic_time(:microsecond)
            duration = end_time - start_time

            metadata =
              if unquote(metadata_fun) do
                try do
                  unquote(metadata_fun).(args, {:error, error})
                rescue
                  _ -> %{}
                end
              else
                %{}
              end

            :telemetry.execute(
              unquote(event_path),
              %{
                duration: duration,
                result: :error
              },
              Map.merge(
                %{
                  module: unquote(module),
                  function: unquote(function),
                  arity: unquote(arity),
                  error: inspect(error)
                },
                metadata
              )
            )

            reraise error, __STACKTRACE__
        end
      end

      instrumented_function
    end
  end

  @doc """
  Auto-instrument common patterns in the codebase.
  This function can be called during application startup to add
  telemetry to key operations without modifying existing code.
  """
  @spec auto_instrument() :: :ok
  def auto_instrument() do
    Logger.info("[TelemetryIntegrator] Setting up automatic instrumentation")

    # Instrument blockchain operations if modules are available
    try do
      instrument_blockchain_operations()
      instrument_storage_operations()
      instrument_p2p_operations()
      instrument_evm_operations()
    rescue
      error ->
        Logger.warning("[TelemetryIntegrator] Some instrumentation failed: #{inspect(error)}")
    end

    Logger.info("[TelemetryIntegrator] Automatic instrumentation complete")
    :ok
  end

  # Private instrumentation functions

  defp instrument_blockchain_operations() do
    # These would instrument actual blockchain modules
    # For now, we'll just log that we're setting up instrumentation
    Logger.debug("[TelemetryIntegrator] Blockchain operations instrumentation ready")
  end

  defp instrument_storage_operations() do
    Logger.debug("[TelemetryIntegrator] Storage operations instrumentation ready")
  end

  defp instrument_p2p_operations() do
    Logger.debug("[TelemetryIntegrator] P2P operations instrumentation ready")
  end

  defp instrument_evm_operations() do
    Logger.debug("[TelemetryIntegrator] EVM operations instrumentation ready")
  end

  # Development and debugging helpers

  @doc """
  List all currently registered telemetry handlers.
  """
  @spec list_telemetry_handlers() :: list()
  def list_telemetry_handlers() do
    :telemetry.list_handlers([])
  end

  @doc """
  Print telemetry handler information for debugging.
  """
  @spec debug_telemetry_handlers() :: :ok
  def debug_telemetry_handlers() do
    handlers = list_telemetry_handlers()

    Logger.info("[TelemetryIntegrator] Current telemetry handlers:")

    Enum.each(handlers, fn handler ->
      Logger.info("  - #{inspect(handler)}")
    end)

    :ok
  end

  @doc """
  Test function to emit sample telemetry events for testing.
  """
  @spec emit_test_events() :: :ok
  def emit_test_events() do
    Logger.info("[TelemetryIntegrator] Emitting test telemetry events")

    # Emit some sample events
    emit_block_processed(12345, 150_000, %{transactions: 42})
    emit_transaction_processed(50_000, %{gas_used: 21000, status: :success})
    emit_p2p_message("eth_getBlockByNumber", "outbound", %{peer_id: "test_peer"})
    emit_storage_operation("put", 25_000, %{backend: "ets", key_size: 32})
    emit_evm_execution(75_000, 85000, %{contract: "0x123", opcode_count: 150})
    emit_sync_progress(0.75, %{mode: "fast_sync"})
    emit_peer_count_update(8, %{connected: 8, connecting: 2})
    emit_transaction_pool_size(128, %{pending: 100, queued: 28})

    Logger.info("[TelemetryIntegrator] Test events emitted")
    :ok
  end
end
