defmodule Mana.ModuleRouter do
  @moduledoc """
  Routes requests to V1 or V2 modules based on configuration and feature flags.
  Enables zero-downtime migration and instant rollback capabilities.

  This module provides:
  - Dynamic routing between V1 and V2 implementations
  - Traffic splitting for gradual rollout
  - Circuit breaker integration for fault tolerance
  - Comprehensive monitoring and telemetry
  - Automatic fallback to V1 on V2 failures
  - Performance metrics collection
  """

  require Logger
  alias Mana.FeatureFlags
  alias Mana.Monitoring.CircuitBreaker

  @behaviour Mana.ModuleRouter.Behaviour

  # Module mapping configuration
  @module_mappings %{
    transaction_pool: %{
      v1: Blockchain.TransactionPool,
      v2: Blockchain.TransactionPool
    },
    sync_service: %{
      v1: ExWire.Sync,
      v2: ExWire.Sync
    }
    # Can add more modules as they get V2 implementations:
    # filter_manager: %{
    #   v1: JSONRPC2.FilterManager,
    #   v2: JSONRPC2.FilterManagerV2
    # },
    # subscription_manager: %{
    #   v1: JSONRPC2.SubscriptionManager,
    #   v2: JSONRPC2.SubscriptionManagerV2
    # }
  }

  # Default circuit breaker configuration
  @default_circuit_breaker_config %{
    failure_threshold: 5,
    success_threshold: 3,
    timeout_ms: 60_000,
    reset_timeout_ms: 300_000
  }

  # Client API

  @doc """
  Routes a module request to the appropriate V1 or V2 implementation.

  ## Parameters
  - module_type: :transaction_pool, :sync_service, etc.
  - operation: The operation to perform (:add_transaction, :get_sync_status, etc.)
  - args: Arguments for the operation
  - opts: Options including caller info, timeout, etc.

  ## Returns
  - {:ok, result} on success
  - {:error, reason} on failure
  """
  @spec route_request(atom(), atom(), list(), keyword()) :: {:ok, term()} | {:error, term()}
  def route_request(module_type, operation, args, opts \\ []) do
    start_time = :os.system_time(:microsecond)
    caller_info = Keyword.get(opts, :caller_info, %{})

    try do
      case determine_target_module(module_type, caller_info) do
        {:v2, target_module} ->
          result = route_to_v2_with_fallback(target_module, operation, args, opts)
          record_routing_metric(module_type, :v2, operation, start_time, result)
          result

        {:v1, target_module} ->
          result = route_to_v1(target_module, operation, args, opts)
          record_routing_metric(module_type, :v1, operation, start_time, result)
          result

        {:error, reason} ->
          Logger.error("Module routing failed", %{
            module_type: module_type,
            operation: operation,
            reason: reason,
            caller: caller_info
          })

          {:error, reason}
      end
    rescue
      error ->
        Logger.error("Module routing exception", %{
          module_type: module_type,
          operation: operation,
          error: inspect(error),
          caller: caller_info
        })

        # Always fallback to V1 on routing errors
        fallback_to_v1(module_type, operation, args, opts)
    end
  end

  @doc """
  Gets the current routing configuration for all modules.
  """
  @spec get_routing_config() :: map()
  def get_routing_config do
    Map.new(@module_mappings, fn {module_type, _mappings} ->
      {module_type,
       %{
         version: get_version(module_type),
         traffic_split: get_traffic_split(module_type),
         circuit_breaker_state: get_circuit_breaker_state(module_type),
         last_fallback: get_last_fallback_time(module_type)
       }}
    end)
  end

  @doc """
  Gets comprehensive routing statistics.
  """
  @spec get_routing_stats() :: map()
  def get_routing_stats do
    %{
      total_requests: get_total_requests(),
      v1_requests: get_v1_requests(),
      v2_requests: get_v2_requests(),
      v2_fallbacks: get_v2_fallbacks(),
      success_rate_v1: calculate_success_rate(:v1),
      success_rate_v2: calculate_success_rate(:v2),
      avg_latency_v1: calculate_avg_latency(:v1),
      avg_latency_v2: calculate_avg_latency(:v2),
      circuit_breaker_states: get_all_circuit_breaker_states(),
      last_updated: System.system_time(:second)
    }
  end

  @doc """
  Forces a specific module to use a particular version (for testing/debugging).
  """
  @spec force_version(atom(), :v1 | :v2) :: :ok | {:error, term()}
  def force_version(module_type, version) when version in [:v1, :v2] do
    case Map.has_key?(@module_mappings, module_type) do
      true ->
        Application.put_env(:mana, :forced_versions, %{
          Map.get(Application.get_env(:mana, :forced_versions, %{}), module_type, version) =>
            version
        })

        Logger.info("Forced module version", %{
          module_type: module_type,
          version: version
        })

        emit_telemetry(:version_forced, %{module_type: module_type, version: version})
        :ok

      false ->
        {:error, "Unknown module type: #{module_type}"}
    end
  end

  @doc """
  Clears version forcing for a module (returns to normal routing).
  """
  @spec clear_forced_version(atom()) :: :ok
  def clear_forced_version(module_type) do
    forced_versions = Application.get_env(:mana, :forced_versions, %{})
    new_forced_versions = Map.delete(forced_versions, module_type)

    Application.put_env(:mana, :forced_versions, new_forced_versions)

    Logger.info("Cleared forced version", %{module_type: module_type})
    emit_telemetry(:version_force_cleared, %{module_type: module_type})

    :ok
  end

  @doc """
  Manually triggers fallback to V1 for a specific module type.
  """
  @spec trigger_fallback(atom(), term()) :: :ok
  def trigger_fallback(module_type, reason) do
    Logger.warning("Manual fallback triggered", %{
      module_type: module_type,
      reason: reason
    })

    # Open circuit breaker to force V1 routing
    CircuitBreaker.open(circuit_breaker_name(module_type), reason)

    # Record fallback event
    record_fallback_event(module_type, :manual, reason)

    emit_telemetry(:manual_fallback_triggered, %{
      module_type: module_type,
      reason: reason
    })

    :ok
  end

  # Private Implementation

  defp determine_target_module(module_type, caller_info) do
    case Map.get(@module_mappings, module_type) do
      nil ->
        {:error, "Unknown module type: #{module_type}"}

      module_mapping ->
        version = select_version(module_type, caller_info)
        target_module = Map.get(module_mapping, version)

        case {version, target_module} do
          {:v2, nil} ->
            Logger.warning("V2 module not available, falling back to V1", %{
              module_type: module_type
            })

            {:v1, module_mapping.v1}

          {selected_version, module} when not is_nil(module) ->
            {selected_version, module}

          _ ->
            {:error, "No valid module found for #{module_type}"}
        end
    end
  end

  defp select_version(module_type, caller_info) do
    # Check for forced version first (for testing/debugging)
    forced_versions = Application.get_env(:mana, :forced_versions, %{})

    case Map.get(forced_versions, module_type) do
      version when version in [:v1, :v2] ->
        version

      nil ->
        select_version_based_on_config(module_type, caller_info)
    end
  end

  defp select_version_based_on_config(module_type, caller_info) do
    # Check circuit breaker state first
    case CircuitBreaker.state(circuit_breaker_name(module_type)) do
      :open ->
        Logger.debug("Circuit breaker open, routing to V1", %{module_type: module_type})
        :v1

      :half_open ->
        # In half-open state, allow some traffic to V2 for testing
        if should_try_v2_in_half_open?(module_type) do
          :v2
        else
          :v1
        end

      :closed ->
        # Normal version selection based on feature flags and traffic splitting
        select_version_normal_mode(module_type, caller_info)
    end
  end

  defp select_version_normal_mode(module_type, caller_info) do
    # Check if V2 is enabled for this module
    case get_version(module_type) do
      "v2" ->
        # V2 is enabled, check traffic splitting
        traffic_percentage = get_traffic_split(module_type)

        if should_route_to_v2?(traffic_percentage, caller_info) do
          :v2
        else
          :v1
        end

      _ ->
        # V2 not enabled or explicitly set to V1
        :v1
    end
  end

  defp should_route_to_v2?(traffic_percentage, caller_info) do
    cond do
      traffic_percentage >= 100 ->
        true

      traffic_percentage <= 0 ->
        false

      true ->
        # Use consistent hashing based on caller info for sticky routing
        hash_value = calculate_caller_hash(caller_info)
        random_percentage = rem(hash_value, 100) + 1

        random_percentage <= traffic_percentage
    end
  end

  defp calculate_caller_hash(caller_info) do
    # Create consistent hash from caller information
    hash_input =
      case caller_info do
        %{pid: pid} when is_pid(pid) ->
          # Use PID for process-based stickiness
          :erlang.phash2(pid)

        %{user_id: user_id} when not is_nil(user_id) ->
          # Use user ID for user-based stickiness
          :erlang.phash2(user_id)

        %{session_id: session_id} when not is_nil(session_id) ->
          # Use session ID for session-based stickiness
          :erlang.phash2(session_id)

        _ ->
          # Fallback to random selection
          :rand.uniform(100)
      end

    abs(hash_input)
  end

  defp should_try_v2_in_half_open?(module_type) do
    # Allow 10% of traffic to V2 in half-open state
    :rand.uniform(100) <= 10
  end

  defp route_to_v2_with_fallback(target_module, operation, args, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    try do
      # Attempt V2 operation with circuit breaker protection
      case apply_with_circuit_breaker(target_module, operation, args, timeout) do
        {:ok, result} = success ->
          # V2 success - record positive outcome
          CircuitBreaker.record_success(circuit_breaker_name_from_module(target_module))
          success

        {:error, reason} = error ->
          Logger.warning("V2 operation failed, attempting fallback", %{
            module: target_module,
            operation: operation,
            reason: reason
          })

          # Record failure and attempt fallback
          CircuitBreaker.record_failure(circuit_breaker_name_from_module(target_module), reason)
          attempt_v1_fallback(target_module, operation, args, opts, reason)
      end
    rescue
      error ->
        Logger.error("V2 operation exception, attempting fallback", %{
          module: target_module,
          operation: operation,
          error: inspect(error)
        })

        # Record critical failure
        CircuitBreaker.record_failure(circuit_breaker_name_from_module(target_module), error)
        attempt_v1_fallback(target_module, operation, args, opts, error)
    end
  end

  defp attempt_v1_fallback(v2_module, operation, args, opts, failure_reason) do
    module_type = get_module_type_from_v2_module(v2_module)
    v1_module = get_v1_module(module_type)

    record_fallback_event(module_type, :automatic, failure_reason)

    case v1_module do
      nil ->
        Logger.error("No V1 fallback available", %{
          v2_module: v2_module,
          operation: operation
        })

        {:error, "V2 failed and no V1 fallback available: #{inspect(failure_reason)}"}

      fallback_module ->
        Logger.info("Falling back to V1", %{
          v2_module: v2_module,
          v1_module: fallback_module,
          operation: operation,
          failure_reason: failure_reason
        })

        emit_telemetry(:fallback_executed, %{
          module_type: module_type,
          v2_module: v2_module,
          v1_module: fallback_module,
          failure_reason: failure_reason
        })

        route_to_v1(fallback_module, operation, args, opts)
    end
  end

  defp route_to_v1(target_module, operation, args, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    try do
      case apply_with_timeout(target_module, operation, args, timeout) do
        {:ok, result} = success ->
          success

        {:error, reason} = error ->
          Logger.error("V1 operation failed", %{
            module: target_module,
            operation: operation,
            reason: reason
          })

          error
      end
    rescue
      error ->
        Logger.error("V1 operation exception", %{
          module: target_module,
          operation: operation,
          error: inspect(error)
        })

        {:error, "V1 operation failed: #{inspect(error)}"}
    end
  end

  defp fallback_to_v1(module_type, operation, args, opts) do
    case get_v1_module(module_type) do
      nil ->
        {:error, "No V1 module available for #{module_type}"}

      v1_module ->
        Logger.info("Emergency fallback to V1", %{
          module_type: module_type,
          v1_module: v1_module,
          operation: operation
        })

        route_to_v1(v1_module, operation, args, opts)
    end
  end

  defp apply_with_circuit_breaker(module, operation, args, timeout) do
    circuit_breaker_name = circuit_breaker_name_from_module(module)

    CircuitBreaker.call(
      circuit_breaker_name,
      fn ->
        apply_with_timeout(module, operation, args, timeout)
      end,
      @default_circuit_breaker_config
    )
  end

  defp apply_with_timeout(module, operation, args, timeout) do
    # Use Task for timeout control
    task =
      Task.async(fn ->
        case length(args) do
          0 -> apply(module, operation, [])
          1 -> apply(module, operation, args)
          _ -> apply(module, operation, args)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} ->
        {:ok, result}

      nil ->
        {:error, :timeout}

      {:exit, reason} ->
        {:error, {:exit, reason}}
    end
  rescue
    error ->
      {:error, error}
  end

  # Configuration helper functions

  defp get_version(module_type) do
    :mana
    |> Application.get_env(:module_versions, %{})
    |> Map.get(module_type, "v1")
  end

  defp get_traffic_split(module_type) do
    :mana
    |> Application.get_env(:traffic_splits, %{})
    |> Map.get(module_type, 0)
  end

  defp get_v1_module(module_type) do
    @module_mappings
    |> Map.get(module_type, %{})
    |> Map.get(:v1)
  end

  defp get_module_type_from_v2_module(v2_module) do
    @module_mappings
    |> Enum.find_value(fn {module_type, %{v2: mapped_v2_module}} ->
      if mapped_v2_module == v2_module do
        module_type
      else
        nil
      end
    end)
  end

  defp circuit_breaker_name(module_type) do
    :"#{module_type}_v2_circuit_breaker"
  end

  defp circuit_breaker_name_from_module(module) do
    case get_module_type_from_v2_module(module) do
      nil -> :unknown_circuit_breaker
      module_type -> circuit_breaker_name(module_type)
    end
  end

  defp get_circuit_breaker_state(module_type) do
    CircuitBreaker.state(circuit_breaker_name(module_type))
  end

  # Metrics and monitoring functions

  defp record_routing_metric(module_type, version, operation, start_time, result) do
    duration_us = :os.system_time(:microsecond) - start_time

    success =
      case result do
        {:ok, _} -> true
        _ -> false
      end

    # Store metrics in ETS table for fast access
    metrics_table = ensure_metrics_table()

    metric_key = {module_type, version, operation}
    current_time = System.system_time(:second)

    # Update or insert metric
    case :ets.lookup(metrics_table, metric_key) do
      [{^metric_key, existing_metrics}] ->
        updated_metrics = update_metric_data(existing_metrics, duration_us, success, current_time)
        :ets.insert(metrics_table, {metric_key, updated_metrics})

      [] ->
        new_metrics = create_initial_metric_data(duration_us, success, current_time)
        :ets.insert(metrics_table, {metric_key, new_metrics})
    end

    # Emit telemetry
    emit_telemetry(:request_routed, %{
      module_type: module_type,
      version: version,
      operation: operation,
      duration_ms: duration_us / 1000,
      success: success
    })
  end

  defp record_fallback_event(module_type, fallback_type, reason) do
    fallback_table = ensure_fallback_table()
    current_time = System.system_time(:second)

    fallback_event = %{
      module_type: module_type,
      fallback_type: fallback_type,
      reason: reason,
      timestamp: current_time
    }

    # Store fallback event
    :ets.insert(fallback_table, {current_time, fallback_event})

    # Clean old events (keep last 1000)
    cleanup_old_fallback_events(fallback_table)

    # Update last fallback time
    Application.put_env(
      :mana,
      :last_fallback_times,
      Map.put(
        Application.get_env(:mana, :last_fallback_times, %{}),
        module_type,
        current_time
      )
    )
  end

  defp ensure_metrics_table do
    table_name = :mana_router_metrics

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set])

      _ ->
        table_name
    end
  end

  defp ensure_fallback_table do
    table_name = :mana_router_fallbacks

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :ordered_set])

      _ ->
        table_name
    end
  end

  defp create_initial_metric_data(duration_us, success, timestamp) do
    %{
      total_requests: 1,
      successful_requests: if(success, do: 1, else: 0),
      total_duration_us: duration_us,
      min_duration_us: duration_us,
      max_duration_us: duration_us,
      last_request_time: timestamp,
      created_at: timestamp
    }
  end

  defp update_metric_data(existing, duration_us, success, timestamp) do
    %{
      existing
      | total_requests: existing.total_requests + 1,
        successful_requests: existing.successful_requests + if(success, do: 1, else: 0),
        total_duration_us: existing.total_duration_us + duration_us,
        min_duration_us: min(existing.min_duration_us, duration_us),
        max_duration_us: max(existing.max_duration_us, duration_us),
        last_request_time: timestamp
    }
  end

  defp cleanup_old_fallback_events(table) do
    all_events = :ets.tab2list(table)

    if length(all_events) > 1000 do
      # Keep only the most recent 1000 events
      events_to_delete =
        all_events
        |> Enum.sort_by(fn {timestamp, _} -> timestamp end)
        |> Enum.take(length(all_events) - 1000)

      Enum.each(events_to_delete, fn {timestamp, _} ->
        :ets.delete(table, timestamp)
      end)
    end
  end

  # Statistics calculation functions

  defp get_total_requests do
    metrics_table = ensure_metrics_table()

    :ets.foldl(
      fn {_key, metrics}, acc ->
        acc + metrics.total_requests
      end,
      0,
      metrics_table
    )
  end

  defp get_v1_requests do
    get_requests_by_version(:v1)
  end

  defp get_v2_requests do
    get_requests_by_version(:v2)
  end

  defp get_requests_by_version(version) do
    metrics_table = ensure_metrics_table()

    :ets.foldl(
      fn {{_module_type, metric_version, _operation}, metrics}, acc ->
        if metric_version == version do
          acc + metrics.total_requests
        else
          acc
        end
      end,
      0,
      metrics_table
    )
  end

  defp get_v2_fallbacks do
    fallback_table = ensure_fallback_table()

    :ets.foldl(
      fn {_timestamp, event}, acc ->
        if event.fallback_type in [:automatic, :circuit_breaker] do
          acc + 1
        else
          acc
        end
      end,
      0,
      fallback_table
    )
  end

  defp calculate_success_rate(version) do
    metrics_table = ensure_metrics_table()

    {total, successful} =
      :ets.foldl(
        fn {{_module_type, metric_version, _operation}, metrics}, {total_acc, success_acc} ->
          if metric_version == version do
            {total_acc + metrics.total_requests, success_acc + metrics.successful_requests}
          else
            {total_acc, success_acc}
          end
        end,
        {0, 0},
        metrics_table
      )

    if total > 0 do
      successful / total * 100
    else
      0
    end
  end

  defp calculate_avg_latency(version) do
    metrics_table = ensure_metrics_table()

    {total_duration, total_requests} =
      :ets.foldl(
        fn {{_module_type, metric_version, _operation}, metrics}, {duration_acc, requests_acc} ->
          if metric_version == version do
            {duration_acc + metrics.total_duration_us, requests_acc + metrics.total_requests}
          else
            {duration_acc, requests_acc}
          end
        end,
        {0, 0},
        metrics_table
      )

    if total_requests > 0 do
      # Convert to milliseconds
      total_duration / total_requests / 1000
    else
      0
    end
  end

  defp get_all_circuit_breaker_states do
    Map.new(@module_mappings, fn {module_type, _} ->
      {module_type, get_circuit_breaker_state(module_type)}
    end)
  end

  defp get_last_fallback_time(module_type) do
    Application.get_env(:mana, :last_fallback_times, %{})
    |> Map.get(module_type)
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:mana, :module_router, event],
      %{count: 1, timestamp: :os.system_time(:millisecond)},
      metadata
    )
  end
end
