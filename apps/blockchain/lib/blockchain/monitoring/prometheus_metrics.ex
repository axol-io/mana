defmodule Blockchain.Monitoring.PrometheusMetrics do
  @moduledoc """
  Prometheus metrics registry for Mana-Ethereum client.

  This module manages metric definitions and provides a registry
  of all metrics for the monitoring system. Currently implements
  a simple metrics collection system that can be extended with
  full Prometheus integration later.
  """

  use GenServer
  require Logger

  defstruct [
    :metrics_table,
    :last_update
  ]

  @name __MODULE__

  # Metric categories and names
  @blockchain_metrics [
    "mana_blockchain_height",
    "mana_block_processing_seconds",
    "mana_blocks_processed_total"
  ]

  @p2p_metrics [
    "mana_p2p_peers_connected",
    "mana_p2p_messages_total"
  ]

  @system_metrics [
    "mana_memory_usage_bytes",
    "mana_disk_usage_bytes",
    "mana_erlang_processes"
  ]

  # Public API

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Initialize all metrics with default values.
  Should be called during application startup.
  """
  @spec setup() :: :ok
  def setup() do
    GenServer.cast(@name, :setup_metrics)
  end

  @doc """
  Update system metrics (memory, disk usage, etc.).
  """
  @spec update_system_metrics() :: :ok
  def update_system_metrics() do
    GenServer.cast(@name, :update_system_metrics)
  end

  @doc """
  Get current metrics in Prometheus text format.
  """
  @spec get_prometheus_metrics() :: String.t()
  def get_prometheus_metrics() do
    GenServer.call(@name, :get_metrics)
  end

  @doc """
  Set a gauge metric value.
  """
  @spec set_gauge(String.t(), number(), map()) :: :ok
  def set_gauge(metric_name, value, labels \\ %{}) do
    GenServer.cast(@name, {:set_gauge, metric_name, value, labels})
  end

  @doc """
  Increment a counter metric.
  """
  @spec inc_counter(String.t(), number(), map()) :: :ok
  def inc_counter(metric_name, increment \\ 1, labels \\ %{}) do
    GenServer.cast(@name, {:inc_counter, metric_name, increment, labels})
  end

  @doc """
  Observe a value for a histogram metric.
  """
  @spec observe_histogram(String.t(), number(), map()) :: :ok
  def observe_histogram(metric_name, value, labels \\ %{}) do
    GenServer.cast(@name, {:observe_histogram, metric_name, value, labels})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for storing metrics
    metrics_table =
      :ets.new(:prometheus_metrics, [
        :set,
        :public,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    state = %__MODULE__{
      metrics_table: metrics_table,
      last_update: DateTime.utc_now()
    }

    # Initialize with default values
    initialize_default_metrics(metrics_table)

    Logger.info("[PrometheusMetrics] Initialized metrics registry")

    {:ok, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    metrics = collect_all_metrics(state.metrics_table)
    prometheus_text = format_prometheus_metrics(metrics)
    {:reply, prometheus_text, state}
  end

  @impl true
  def handle_cast(:setup_metrics, state) do
    initialize_default_metrics(state.metrics_table)
    {:noreply, state}
  end

  def handle_cast(:update_system_metrics, state) do
    update_system_metrics_in_table(state.metrics_table)
    {:noreply, %{state | last_update: DateTime.utc_now()}}
  end

  def handle_cast({:set_gauge, metric_name, value, labels}, state) do
    key = {metric_name, :gauge, labels}
    :ets.insert(state.metrics_table, {key, value})
    {:noreply, state}
  end

  def handle_cast({:inc_counter, metric_name, increment, labels}, state) do
    key = {metric_name, :counter, labels}

    case :ets.lookup(state.metrics_table, key) do
      [{^key, current_value}] ->
        :ets.insert(state.metrics_table, {key, current_value + increment})

      [] ->
        :ets.insert(state.metrics_table, {key, increment})
    end

    {:noreply, state}
  end

  def handle_cast({:observe_histogram, metric_name, value, labels}, state) do
    # For simplicity, store histogram observations as sum and count
    sum_key = {metric_name <> "_sum", :gauge, labels}
    count_key = {metric_name <> "_count", :counter, labels}

    # Update sum
    case :ets.lookup(state.metrics_table, sum_key) do
      [{^sum_key, current_sum}] ->
        :ets.insert(state.metrics_table, {sum_key, current_sum + value})

      [] ->
        :ets.insert(state.metrics_table, {sum_key, value})
    end

    # Update count
    case :ets.lookup(state.metrics_table, count_key) do
      [{^count_key, current_count}] ->
        :ets.insert(state.metrics_table, {count_key, current_count + 1})

      [] ->
        :ets.insert(state.metrics_table, {count_key, 1})
    end

    {:noreply, state}
  end

  # Private functions

  defp initialize_default_metrics(table) do
    # Initialize blockchain metrics
    Enum.each(@blockchain_metrics, fn metric ->
      case metric do
        "mana_blockchain_height" -> :ets.insert(table, {{metric, :gauge, %{}}, 0})
        "mana_blocks_processed_total" -> :ets.insert(table, {{metric, :counter, %{}}, 0})
        _ -> :ets.insert(table, {{metric, :gauge, %{}}, 0})
      end
    end)

    # Initialize P2P metrics
    Enum.each(@p2p_metrics, fn metric ->
      case metric do
        "mana_p2p_peers_connected" ->
          :ets.insert(table, {{metric, :gauge, %{"protocol" => "eth"}}, 0})
          :ets.insert(table, {{metric, :gauge, %{"protocol" => "libp2p"}}, 0})

        "mana_p2p_messages_total" ->
          :ets.insert(table, {{metric, :counter, %{"direction" => "inbound"}}, 0})
          :ets.insert(table, {{metric, :counter, %{"direction" => "outbound"}}, 0})

        _ ->
          :ets.insert(table, {{metric, :gauge, %{}}, 0})
      end
    end)

    # Initialize system metrics
    Enum.each(@system_metrics, fn metric ->
      :ets.insert(table, {{metric, :gauge, %{}}, 0})
    end)

    update_system_metrics_in_table(table)
  end

  defp update_system_metrics_in_table(table) do
    # Memory usage
    memory_info = :erlang.memory()
    total_memory = Keyword.get(memory_info, :total, 0)
    process_memory = Keyword.get(memory_info, :processes, 0)
    atom_memory = Keyword.get(memory_info, :atom, 0)

    :ets.insert(table, {{"mana_memory_usage_bytes", :gauge, %{"type" => "total"}}, total_memory})

    :ets.insert(
      table,
      {{"mana_memory_usage_bytes", :gauge, %{"type" => "processes"}}, process_memory}
    )

    :ets.insert(table, {{"mana_memory_usage_bytes", :gauge, %{"type" => "atom"}}, atom_memory})

    # Process count
    process_count = :erlang.system_info(:process_count)
    :ets.insert(table, {{"mana_erlang_processes", :gauge, %{}}, process_count})

    # Schedulers
    schedulers = :erlang.system_info(:schedulers)
    :ets.insert(table, {{"mana_erlang_schedulers", :gauge, %{}}, schedulers})

    # Disk usage (if available)
    case get_disk_usage() do
      {available, total} when total > 0 ->
        :ets.insert(
          table,
          {{"mana_disk_usage_bytes", :gauge, %{"type" => "available"}}, available}
        )

        :ets.insert(table, {{"mana_disk_usage_bytes", :gauge, %{"type" => "total"}}, total})
        usage_ratio = (total - available) / total
        :ets.insert(table, {{"mana_disk_usage_ratio", :gauge, %{}}, usage_ratio})

      _ ->
        :ok
    end
  end

  defp get_disk_usage() do
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
    # Group metrics by name
    grouped_metrics =
      metrics
      |> Enum.group_by(fn {{name, _type, _labels}, _value} -> name end)
      |> Enum.sort()

    # Generate Prometheus format
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
    # Determine metric type from first entry
    {{_name, type, _labels}, _value} = List.first(entries)

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
      "mana_blockchain_height" -> "Current blockchain height"
      "mana_blocks_processed_total" -> "Total number of blocks processed"
      "mana_block_processing_seconds_sum" -> "Total time spent processing blocks"
      "mana_block_processing_seconds_count" -> "Number of block processing operations"
      "mana_p2p_peers_connected" -> "Number of connected P2P peers"
      "mana_p2p_messages_total" -> "Total number of P2P messages sent/received"
      "mana_memory_usage_bytes" -> "Memory usage in bytes"
      "mana_disk_usage_bytes" -> "Disk usage in bytes"
      "mana_disk_usage_ratio" -> "Disk usage ratio (0.0 to 1.0)"
      "mana_erlang_processes" -> "Number of Erlang processes"
      "mana_erlang_schedulers" -> "Number of Erlang schedulers"
      _ -> "Metric description not available"
    end
  end
end
