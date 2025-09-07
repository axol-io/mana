defmodule Blockchain.Monitoring.PrometheusExporter do
  @moduledoc """
  Prometheus metrics exporter for Mana-Ethereum client.

  Exports comprehensive metrics covering:
  - Block processing metrics
  - Transaction pool metrics  
  - P2P network metrics
  - Storage/database metrics
  - EVM execution metrics
  - System performance metrics
  """

  use GenServer
  require Logger

  # Metric names following Prometheus best practices
  @block_height_metric "mana_blockchain_height"
  @block_processing_time_metric "mana_block_processing_seconds"
  @block_processing_total_metric "mana_blocks_processed_total"
  @transaction_pool_size_metric "mana_transaction_pool_size"
  @transaction_processing_time_metric "mana_transaction_processing_seconds"
  @p2p_peers_metric "mana_p2p_peers_connected"
  @p2p_messages_metric "mana_p2p_messages_total"
  @storage_operations_metric "mana_storage_operations_total"
  @storage_operation_time_metric "mana_storage_operation_seconds"
  @evm_execution_time_metric "mana_evm_execution_seconds"
  @evm_gas_used_metric "mana_evm_gas_used_total"
  # @sync_progress_metric "mana_sync_progress_ratio" # TODO: Unused attribute
  @memory_usage_metric "mana_memory_usage_bytes"
  @disk_usage_metric "mana_disk_usage_bytes"

  defstruct [
    :registry,
    :metrics_table,
    :last_collection_time,
    :collection_interval,
    :enabled
  ]

  @type t :: %__MODULE__{
          registry: :telemetry.handler_id(),
          metrics_table: :ets.table(),
          last_collection_time: DateTime.t() | nil,
          collection_interval: pos_integer(),
          enabled: boolean()
        }

  # Default collection interval: 15 seconds
  @default_collection_interval 15_000

  @name __MODULE__

  # Public API

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec get_metrics() :: String.t()
  def get_metrics() do
    GenServer.call(@name, :get_metrics)
  end

  @spec increment_counter(String.t(), map()) :: :ok
  def increment_counter(metric_name, labels \\ %{}) do
    GenServer.cast(@name, {:increment_counter, metric_name, labels})
  end

  @spec set_gauge(String.t(), number(), map()) :: :ok
  def set_gauge(metric_name, value, labels \\ %{}) do
    GenServer.cast(@name, {:set_gauge, metric_name, value, labels})
  end

  @spec observe_histogram(String.t(), number(), map()) :: :ok
  def observe_histogram(metric_name, value, labels \\ %{}) do
    GenServer.cast(@name, {:observe_histogram, metric_name, value, labels})
  end

  @spec record_block_processed(non_neg_integer(), number()) :: :ok
  def record_block_processed(block_number, processing_time_ms) do
    increment_counter(@block_processing_total_metric)
    set_gauge(@block_height_metric, block_number)
    observe_histogram(@block_processing_time_metric, processing_time_ms / 1000.0)
  end

  @spec record_transaction_processed(number()) :: :ok
  def record_transaction_processed(processing_time_ms) do
    observe_histogram(@transaction_processing_time_metric, processing_time_ms / 1000.0)
  end

  @spec update_transaction_pool_size(non_neg_integer()) :: :ok
  def update_transaction_pool_size(pool_size) do
    set_gauge(@transaction_pool_size_metric, pool_size)
  end

  @spec update_peer_count(non_neg_integer()) :: :ok
  def update_peer_count(peer_count) do
    set_gauge(@p2p_peers_metric, peer_count)
  end

  @spec record_p2p_message(String.t(), String.t()) :: :ok
  def record_p2p_message(message_type, direction) do
    increment_counter(@p2p_messages_metric, %{
      "message_type" => message_type,
      "direction" => direction
    })
  end

  @spec record_storage_operation(String.t(), number()) :: :ok
  def record_storage_operation(operation_type, duration_ms) do
    increment_counter(@storage_operations_metric, %{"operation" => operation_type})

    observe_histogram(@storage_operation_time_metric, duration_ms / 1000.0, %{
      "operation" => operation_type
    })
  end

  @spec record_evm_execution(number(), non_neg_integer()) :: :ok
  def record_evm_execution(execution_time_ms, gas_used) do
    observe_histogram(@evm_execution_time_metric, execution_time_ms / 1000.0)
    increment_counter(@evm_gas_used_metric, gas_used)
  end

  @spec update_sync_progress(float()) :: :ok
  def update_sync_progress(progress_ratio) do
    set_gauge(@sync_progress_metric, progress_ratio)
  end

  @spec update_system_metrics() :: :ok
  def update_system_metrics() do
    GenServer.cast(@name, :update_system_metrics)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, true)
    collection_interval = Keyword.get(opts, :collection_interval, @default_collection_interval)

    if enabled do
      # Create ETS table to store metrics
      metrics_table =
        :ets.new(:prometheus_metrics, [
          :set,
          :public,
          :named_table,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

      # Initialize metrics
      initialize_metrics(metrics_table)

      # Schedule periodic system metrics collection
      schedule_system_metrics_collection(collection_interval)

      # Attach telemetry handlers
      attach_telemetry_handlers()

      Logger.info(
        "[PrometheusExporter] Started with collection interval #{collection_interval}ms"
      )

      {:ok,
       %__MODULE__{
         registry: :prometheus_registry,
         metrics_table: metrics_table,
         last_collection_time: nil,
         collection_interval: collection_interval,
         enabled: true
       }}
    else
      Logger.info("[PrometheusExporter] Disabled by configuration")
      {:ok, %__MODULE__{enabled: false}}
    end
  end

  @impl true
  def handle_call(:get_metrics, _from, %{enabled: false} = state) do
    {:reply, "# Prometheus metrics disabled\n", state}
  end

  def handle_call(:get_metrics, _from, state) do
    metrics = collect_all_metrics(state.metrics_table)
    prometheus_format = format_prometheus_metrics(metrics)
    {:reply, prometheus_format, state}
  end

  @impl true
  def handle_cast(_msg, %{enabled: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:increment_counter, metric_name, labels}, state) do
    increment_metric_in_table(state.metrics_table, metric_name, :counter, labels, 1)
    {:noreply, state}
  end

  def handle_cast({:set_gauge, metric_name, value, labels}, state) do
    set_metric_in_table(state.metrics_table, metric_name, :gauge, labels, value)
    {:noreply, state}
  end

  def handle_cast({:observe_histogram, metric_name, value, labels}, state) do
    observe_histogram_in_table(state.metrics_table, metric_name, labels, value)
    {:noreply, state}
  end

  def handle_cast(:update_system_metrics, state) do
    update_system_metrics_in_table(state.metrics_table)
    new_state = %{state | last_collection_time: DateTime.utc_now()}
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:collect_system_metrics, state) do
    update_system_metrics_in_table(state.metrics_table)
    schedule_system_metrics_collection(state.collection_interval)
    new_state = %{state | last_collection_time: DateTime.utc_now()}
    {:noreply, new_state}
  end

  # Private functions

  defp initialize_metrics(table) do
    # Initialize all metrics with zero values
    metrics = [
      {@block_height_metric, :gauge, %{}, 0},
      {@block_processing_total_metric, :counter, %{}, 0},
      {@transaction_pool_size_metric, :gauge, %{}, 0},
      {@p2p_peers_metric, :gauge, %{}, 0},
      {@sync_progress_metric, :gauge, %{}, 0.0},
      {@memory_usage_metric, :gauge, %{}, 0},
      {@disk_usage_metric, :gauge, %{}, 0}
    ]

    Enum.each(metrics, fn {name, type, labels, value} ->
      set_metric_in_table(table, name, type, labels, value)
    end)
  end

  defp increment_metric_in_table(table, metric_name, type, labels, increment) do
    key = {metric_name, type, labels}

    case :ets.lookup(table, key) do
      [{^key, current_value}] ->
        :ets.insert(table, {key, current_value + increment})

      [] ->
        :ets.insert(table, {key, increment})
    end
  end

  defp set_metric_in_table(table, metric_name, type, labels, value) do
    key = {metric_name, type, labels}
    :ets.insert(table, {key, value})
  end

  defp observe_histogram_in_table(table, metric_name, labels, value) do
    # For simplicity, we'll store histogram observations as individual measurements
    # In a production system, you'd want proper histogram buckets
    base_key = {metric_name <> "_sum", :gauge, labels}
    _count_key = {metric_name <> "_count", :counter, labels}

    # Update sum
    case :ets.lookup(table, base_key) do
      [{^base_key, current_sum}] ->
        :ets.insert(table, {base_key, current_sum + value})

      [] ->
        :ets.insert(table, {base_key, value})
    end

    # Update count
    increment_metric_in_table(table, metric_name <> "_count", :counter, labels, 1)
  end

  defp update_system_metrics_in_table(table) do
    # Memory usage
    memory_info = :erlang.memory()
    total_memory = Keyword.get(memory_info, :total, 0)
    set_metric_in_table(table, @memory_usage_metric, :gauge, %{"type" => "total"}, total_memory)

    process_memory = Keyword.get(memory_info, :processes, 0)

    set_metric_in_table(
      table,
      @memory_usage_metric,
      :gauge,
      %{"type" => "processes"},
      process_memory
    )

    atom_memory = Keyword.get(memory_info, :atom, 0)
    set_metric_in_table(table, @memory_usage_metric, :gauge, %{"type" => "atom"}, atom_memory)

    # System info
    process_count = :erlang.system_info(:process_count)
    set_metric_in_table(table, "mana_erlang_processes", :gauge, %{}, process_count)

    schedulers = :erlang.system_info(:schedulers)
    set_metric_in_table(table, "mana_erlang_schedulers", :gauge, %{}, schedulers)

    # Get disk usage if possible
    try do
      {available, total} = get_disk_usage()
      set_metric_in_table(table, @disk_usage_metric, :gauge, %{"type" => "available"}, available)
      set_metric_in_table(table, @disk_usage_metric, :gauge, %{"type" => "total"}, total)
      usage_ratio = if total > 0, do: (total - available) / total, else: 0.0
      set_metric_in_table(table, "mana_disk_usage_ratio", :gauge, %{}, usage_ratio)
    rescue
      _ ->
        # Disk usage collection failed, skip
        :ok
    end
  end

  defp get_disk_usage() do
    # This is platform-specific and simplified
    # In production, you'd want more robust disk usage detection
    case :os.type() do
      {:unix, _} ->
        try do
          {output, 0} = System.cmd("df", ["-B1", "."])
          [_header | lines] = String.split(output, "\n", trim: true)
          [line | _] = lines
          parts = String.split(line, ~r/\s+/)
          [_filesystem, total_str, _used_str, available_str | _] = parts

          total = String.to_integer(total_str)
          available = String.to_integer(available_str)

          {available, total}
        rescue
          _ -> {0, 0}
        end

      _ ->
        # Windows or other systems
        {0, 0}
    end
  end

  defp collect_all_metrics(table) do
    :ets.tab2list(table)
  end

  defp format_prometheus_metrics(metrics) do
    # Group metrics by name for proper Prometheus format
    grouped_metrics =
      metrics
      |> Enum.group_by(fn {{name, _type, _labels}, _value} -> name end)
      |> Enum.sort()

    prometheus_output =
      Enum.map(grouped_metrics, fn {metric_name, metric_entries} ->
        format_metric_family(metric_name, metric_entries)
      end)
      |> Enum.join("\n")

    """
    # HELP mana_up Whether the Mana-Ethereum client is up and running
    # TYPE mana_up gauge
    mana_up 1

    # Generated at #{DateTime.utc_now() |> DateTime.to_iso8601()}
    #{prometheus_output}
    """
  end

  defp format_metric_family(metric_name, entries) do
    # Determine metric type
    {_first_key, type, _first_labels} = elem(List.first(entries), 0)

    type_str =
      case type do
        :counter -> "counter"
        :gauge -> "gauge"
        :histogram -> "histogram"
      end

    help_text = get_help_text(metric_name)

    # Format entries
    formatted_entries =
      entries
      |> Enum.map(fn {{_name, _type, labels}, value} ->
        labels_str = format_labels(labels)
        "#{metric_name}#{labels_str} #{format_value(value)}"
      end)
      |> Enum.join("\n")

    """
    # HELP #{metric_name} #{help_text}
    # TYPE #{metric_name} #{type_str}
    #{formatted_entries}
    """
  end

  defp format_labels(labels) when map_size(labels) == 0, do: ""

  defp format_labels(labels) do
    labels_list =
      labels
      |> Enum.map(fn {key, value} -> "#{key}=\"#{value}\"" end)
      |> Enum.join(",")

    "{#{labels_list}}"
  end

  defp format_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, [{:decimals, 6}])

  defp format_value(value), do: to_string(value)

  defp get_help_text(metric_name) do
    case metric_name do
      @block_height_metric -> "Current blockchain height"
      @block_processing_time_metric -> "Time spent processing blocks in seconds"
      @block_processing_total_metric -> "Total number of blocks processed"
      @transaction_pool_size_metric -> "Current number of transactions in the pool"
      @transaction_processing_time_metric -> "Time spent processing transactions in seconds"
      @p2p_peers_metric -> "Number of connected P2P peers"
      @p2p_messages_metric -> "Total number of P2P messages sent/received"
      @storage_operations_metric -> "Total number of storage operations performed"
      @storage_operation_time_metric -> "Time spent on storage operations in seconds"
      @evm_execution_time_metric -> "Time spent executing EVM code in seconds"
      @evm_gas_used_metric -> "Total gas used in EVM executions"
  # @sync_progress_metric -> "Blockchain synchronization progress (0.0 to 1.0)" # TODO: Unused attribute
      @memory_usage_metric -> "Memory usage in bytes"
      @disk_usage_metric -> "Disk usage in bytes"
      "mana_erlang_processes" -> "Number of Erlang processes"
      "mana_erlang_schedulers" -> "Number of Erlang schedulers"
      "mana_disk_usage_ratio" -> "Disk usage ratio (0.0 to 1.0)"
      _ -> "Metric description not available"
    end
  end

  defp schedule_system_metrics_collection(interval) do
    Process.send_after(self(), :collect_system_metrics, interval)
  end

  defp attach_telemetry_handlers() do
    # Attach telemetry handlers for automatic metric collection
    # This allows other parts of the system to emit telemetry events
    # that get automatically converted to metrics

    events = [
      [:mana, :block, :processed],
      [:mana, :transaction, :processed],
      [:mana, :p2p, :message],
      [:mana, :storage, :operation],
      [:mana, :evm, :execution]
    ]

    Enum.each(events, fn event ->
      :telemetry.attach(
        {__MODULE__, event},
        event,
        &handle_telemetry_event/4,
        nil
      )
    end)
  end

  defp handle_telemetry_event([:mana, :block, :processed], measurements, metadata, _config) do
    block_number = Map.get(metadata, :block_number, 0)
    processing_time = Map.get(measurements, :duration, 0)
    # Convert microseconds to milliseconds
    record_block_processed(block_number, processing_time / 1_000_000)
  end

  defp handle_telemetry_event([:mana, :transaction, :processed], measurements, _metadata, _config) do
    processing_time = Map.get(measurements, :duration, 0)
    # Convert microseconds to milliseconds
    record_transaction_processed(processing_time / 1_000_000)
  end

  defp handle_telemetry_event([:mana, :p2p, :message], _measurements, metadata, _config) do
    message_type = Map.get(metadata, :message_type, "unknown")
    direction = Map.get(metadata, :direction, "unknown")
    record_p2p_message(message_type, direction)
  end

  defp handle_telemetry_event([:mana, :storage, :operation], measurements, metadata, _config) do
    operation_type = Map.get(metadata, :operation_type, "unknown")
    duration = Map.get(measurements, :duration, 0)
    # Convert microseconds to milliseconds
    record_storage_operation(operation_type, duration / 1_000_000)
  end

  defp handle_telemetry_event([:mana, :evm, :execution], measurements, metadata, _config) do
    execution_time = Map.get(measurements, :duration, 0)
    gas_used = Map.get(metadata, :gas_used, 0)
    # Convert microseconds to milliseconds
    record_evm_execution(execution_time / 1_000_000, gas_used)
  end
end
