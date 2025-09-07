defmodule Blockchain.Monitoring.StructuredLogger do
  @moduledoc """
  Structured logging module for the Mana-Ethereum client.

  Provides consistent, structured logging with proper log levels, context,
  and machine-readable output. Supports both development (human-readable)
  and production (JSON) formats.

  ## Features:
  - Structured log entries with consistent fields
  - Context propagation (request IDs, session IDs, etc.)
  - Performance measurement logging
  - Error tracking with stack traces
  - Component-specific logging
  - Configurable output formats (human/json)
  - Log filtering and sampling
  """

  require Logger
  alias Blockchain.Monitoring.TelemetryIntegrator

  # Log levels following standard conventions
  @log_levels [:trace, :debug, :info, :notice, :warn, :error, :critical, :alert, :emergency]

  # Component identifiers
  @components %{
    blockchain: "blockchain",
    evm: "evm",
    p2p: "p2p",
    rpc: "rpc",
    sync: "sync",
    storage: "storage",
    txpool: "transaction_pool",
    metrics: "metrics",
    system: "system"
  }

  defstruct [
    :node_id,
    :version,
    :format,
    :min_level,
    :context,
    :sampling_rate
  ]

  @type t :: %__MODULE__{
          node_id: String.t(),
          version: String.t(),
          format: :human | :json,
          min_level: atom(),
          context: map(),
          sampling_rate: float()
        }

  @type log_entry :: %{
          timestamp: DateTime.t(),
          level: atom(),
          message: String.t(),
          component: String.t(),
          context: map(),
          metadata: map()
        }

  # Public API

  @doc """
  Initialize the structured logger with configuration.
  """
  @spec init(Keyword.t()) :: :ok
  def init(opts \\ []) do
    config = %__MODULE__{
      node_id: Keyword.get(opts, :node_id, generate_node_id()),
      version: Keyword.get(opts, :version, get_app_version()),
      format: Keyword.get(opts, :format, :human),
      min_level: Keyword.get(opts, :min_level, :info),
      context: Keyword.get(opts, :context, %{}),
      sampling_rate: Keyword.get(opts, :sampling_rate, 1.0)
    }

    # Store config in process dictionary for fast access
    Process.put(:structured_logger_config, config)

    Logger.info(
      "[StructuredLogger] Initialized with format: #{config.format}, min_level: #{config.min_level}"
    )

    :ok
  end

  @doc """
  Log a message with structured context.
  """
  @spec log(atom(), String.t(), String.t(), map(), map()) :: :ok
  def log(level, component, message, context \\ %{}, metadata \\ %{}) do
    if should_log?(level) do
      entry = create_log_entry(level, component, message, context, metadata)
      emit_log_entry(entry)
    end

    :ok
  end

  # Convenience functions for different log levels

  @doc "Log a trace message"
  @spec trace(String.t(), String.t(), map(), map()) :: :ok
  def trace(component, message, context \\ %{}, metadata \\ %{}) do
    log(:trace, component, message, context, metadata)
  end

  @doc "Log a debug message"
  @spec debug(String.t(), String.t(), map(), map()) :: :ok
  def debug(component, message, context \\ %{}, metadata \\ %{}) do
    log(:debug, component, message, context, metadata)
  end

  @doc "Log an info message"
  @spec info(String.t(), String.t(), map(), map()) :: :ok
  def info(component, message, context \\ %{}, metadata \\ %{}) do
    log(:info, component, message, context, metadata)
  end

  @doc "Log a notice message"
  @spec notice(String.t(), String.t(), map(), map()) :: :ok
  def notice(component, message, context \\ %{}, metadata \\ %{}) do
    log(:notice, component, message, context, metadata)
  end

  @doc "Log a warning message"
  @spec warn(String.t(), String.t(), map(), map()) :: :ok
  def warn(component, message, context \\ %{}, metadata \\ %{}) do
    log(:warn, component, message, context, metadata)
  end

  @doc "Log an error message"
  @spec error(String.t(), String.t(), map(), map()) :: :ok
  def error(component, message, context \\ %{}, metadata \\ %{}) do
    log(:error, component, message, context, metadata)
  end

  @doc "Log a critical message"
  @spec critical(String.t(), String.t(), map(), map()) :: :ok
  def critical(component, message, context \\ %{}, metadata \\ %{}) do
    log(:critical, component, message, context, metadata)
  end

  @doc "Log an alert message"
  @spec alert(String.t(), String.t(), map(), map()) :: :ok
  def alert(component, message, context \\ %{}, metadata \\ %{}) do
    log(:alert, component, message, context, metadata)
  end

  @doc "Log an emergency message"
  @spec emergency(String.t(), String.t(), map(), map()) :: :ok
  def emergency(component, message, context \\ %{}, metadata \\ %{}) do
    log(:emergency, component, message, context, metadata)
  end

  # Specialized logging functions

  @doc """
  Log a performance measurement.
  """
  @spec log_performance(String.t(), String.t(), number(), map()) :: :ok
  def log_performance(component, operation, duration_ms, context \\ %{}) do
    log(
      :info,
      component,
      "Performance measurement: #{operation}",
      Map.merge(context, %{
        operation: operation,
        duration_ms: duration_ms,
        performance: true
      })
    )

    # Also emit telemetry for metrics collection
    TelemetryIntegrator.emit_storage_operation(operation, trunc(duration_ms * 1000), %{
      component: component
    })
  end

  @doc """
  Log an error with stack trace.
  """
  @spec log_error(String.t(), String.t(), Exception.t(), list(), map()) :: :ok
  def log_error(component, message, error, stacktrace, context \\ %{}) do
    error_context =
      Map.merge(context, %{
        error_type: error.__struct__,
        error_message: Exception.message(error),
        stacktrace: format_stacktrace(stacktrace)
      })

    log(:error, component, message, error_context)
  end

  @doc """
  Log a request (HTTP, RPC, P2P message, etc.).
  """
  @spec log_request(String.t(), String.t(), String.t(), map(), map()) :: :ok
  def log_request(component, request_type, request_id, request_data, context \\ %{}) do
    request_context =
      Map.merge(context, %{
        request_id: request_id,
        request_type: request_type,
        request_data: sanitize_request_data(request_data)
      })

    log(:info, component, "Request received: #{request_type}", request_context)
  end

  @doc """
  Log a response (HTTP, RPC, P2P message, etc.).
  """
  @spec log_response(String.t(), String.t(), String.t(), map(), number(), map()) :: :ok
  def log_response(
        component,
        request_type,
        request_id,
        response_data,
        duration_ms,
        context \\ %{}
      ) do
    response_context =
      Map.merge(context, %{
        request_id: request_id,
        request_type: request_type,
        response_data: sanitize_response_data(response_data),
        duration_ms: duration_ms
      })

    log(:info, component, "Response sent: #{request_type}", response_context)

    # Also log performance
    log_performance(component, "#{request_type}_response", duration_ms, %{request_id: request_id})
  end

  @doc """
  Log a blockchain event (block processed, transaction executed, etc.).
  """
  @spec log_blockchain_event(String.t(), String.t(), map(), map()) :: :ok
  def log_blockchain_event(event_type, description, event_data, context \\ %{}) do
    blockchain_context =
      Map.merge(context, %{
        event_type: event_type,
        event_data: event_data,
        blockchain: true
      })

    log(:info, @components.blockchain, description, blockchain_context)
  end

  @doc """
  Log a P2P networking event.
  """
  @spec log_p2p_event(String.t(), String.t(), map(), map()) :: :ok
  def log_p2p_event(event_type, description, event_data, context \\ %{}) do
    p2p_context =
      Map.merge(context, %{
        event_type: event_type,
        event_data: sanitize_p2p_data(event_data),
        p2p: true
      })

    log(:info, @components.p2p, description, p2p_context)

    # Emit telemetry for P2P events
    if event_data[:message_type] and event_data[:direction] do
      TelemetryIntegrator.emit_p2p_message(
        event_data.message_type,
        event_data.direction,
        %{peer_id: event_data[:peer_id]}
      )
    end
  end

  @doc """
  Log a security event.
  """
  @spec log_security_event(String.t(), String.t(), map(), map()) :: :ok
  def log_security_event(event_type, description, event_data, context \\ %{}) do
    security_context =
      Map.merge(context, %{
        event_type: event_type,
        event_data: event_data,
        security: true,
        severity: "high"
      })

    # Security events are always logged as warnings or higher
    log(:warn, @components.system, "SECURITY: #{description}", security_context)
  end

  @doc """
  Set context for subsequent log messages in this process.
  """
  @spec set_context(map()) :: :ok
  def set_context(context) when is_map(context) do
    current_context = Process.get(:log_context, %{})
    new_context = Map.merge(current_context, context)
    Process.put(:log_context, new_context)
    :ok
  end

  @doc """
  Clear context for this process.
  """
  @spec clear_context() :: :ok
  def clear_context() do
    Process.put(:log_context, %{})
    :ok
  end

  @doc """
  Get current context for this process.
  """
  @spec get_context() :: map()
  def get_context() do
    Process.get(:log_context, %{})
  end

  # Private functions

  defp should_log?(level) do
    config = get_config()
    level_priority = get_level_priority(level)
    min_level_priority = get_level_priority(config.min_level)

    should_sample = :rand.uniform() <= config.sampling_rate

    level_priority >= min_level_priority and should_sample
  end

  defp get_level_priority(level) do
    Enum.find_index(@log_levels, &(&1 == level)) || 0
  end

  defp create_log_entry(level, component, message, context, metadata) do
    config = get_config()
    process_context = get_context()

    %{
      timestamp: DateTime.utc_now(),
      level: level,
      message: message,
      component: component,
      node_id: config.node_id,
      version: config.version,
      context: Map.merge(process_context, context),
      metadata: metadata
    }
  end

  defp emit_log_entry(entry) do
    config = get_config()

    case config.format do
      :json ->
        emit_json_log(entry)

      :human ->
        emit_human_log(entry)
    end
  end

  defp emit_json_log(entry) do
    json_entry = Jason.encode!(entry)
    log_to_backend(entry.level, json_entry)
  end

  defp emit_human_log(entry) do
    timestamp_str = DateTime.to_iso8601(entry.timestamp)
    level_str = String.upcase(to_string(entry.level))

    # Create human-readable log line
    log_line = "[#{timestamp_str}] #{level_str} [#{entry.component}] #{entry.message}"

    # Add context if present
    log_line =
      if map_size(entry.context) > 0 do
        context_str = format_context_for_human(entry.context)
        "#{log_line} #{context_str}"
      else
        log_line
      end

    log_to_backend(entry.level, log_line)
  end

  defp log_to_backend(level, message) do
    case level do
      :trace -> Logger.debug(message)
      :debug -> Logger.debug(message)
      :info -> Logger.info(message)
      :notice -> Logger.info(message)
      :warn -> Logger.warning(message)
      :error -> Logger.error(message)
      :critical -> Logger.error(message)
      :alert -> Logger.error(message)
      :emergency -> Logger.error(message)
    end
  end

  defp format_context_for_human(context) when map_size(context) == 0, do: ""

  defp format_context_for_human(context) do
    context_pairs =
      context
      |> Enum.map(fn {key, value} -> "#{key}=#{inspect(value)}" end)
      |> Enum.join(" ")

    "[#{context_pairs}]"
  end

  defp format_stacktrace(stacktrace) do
    stacktrace
    # Limit to first 10 frames
    |> Enum.take(10)
    |> Enum.map(&Exception.format_stacktrace_entry/1)
  end

  defp sanitize_request_data(data) do
    # Remove or mask sensitive information
    data
    |> remove_sensitive_keys([:password, :private_key, :secret, :token])
    # Limit size to prevent log bloat
    |> limit_size(1000)
  end

  defp sanitize_response_data(data) do
    data
    |> remove_sensitive_keys([:private_key, :secret])
    |> limit_size(1000)
  end

  defp sanitize_p2p_data(data) do
    data
    |> remove_sensitive_keys([:private_key, :node_key])
    |> limit_size(500)
  end

  defp remove_sensitive_keys(data, keys) when is_map(data) do
    Enum.reduce(keys, data, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        _ -> Map.put(acc, key, "[REDACTED]")
      end
    end)
  end

  defp remove_sensitive_keys(data, _keys), do: data

  defp limit_size(data, max_length) when is_binary(data) do
    if String.length(data) > max_length do
      String.slice(data, 0, max_length) <> "...[TRUNCATED]"
    else
      data
    end
  end

  defp limit_size(data, max_length) when is_map(data) do
    serialized = inspect(data)

    if String.length(serialized) > max_length do
      "[LARGE_MAP:#{map_size(data)}_keys]"
    else
      data
    end
  end

  defp limit_size(data, max_length) when is_list(data) do
    serialized = inspect(data)

    if String.length(serialized) > max_length do
      "[LARGE_LIST:#{length(data)}_items]"
    else
      data
    end
  end

  defp limit_size(data, _max_length), do: data

  defp get_config() do
    Process.get(:structured_logger_config, %__MODULE__{
      node_id: generate_node_id(),
      version: get_app_version(),
      format: :human,
      min_level: :info,
      context: %{},
      sampling_rate: 1.0
    })
  end

  defp generate_node_id() do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp get_app_version() do
    case Application.spec(:blockchain, :vsn) do
      nil -> "unknown"
      version -> List.to_string(version)
    end
  end

  # Component helper functions

  @doc """
  Get available component identifiers.
  """
  @spec get_components() :: map()
  def get_components(), do: @components

  @doc """
  Check if a component identifier is valid.
  """
  @spec valid_component?(String.t()) :: boolean()
  def valid_component?(component) do
    component in Map.values(@components)
  end
end
