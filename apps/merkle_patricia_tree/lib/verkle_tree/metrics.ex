defmodule VerkleTree.Metrics do
  @moduledoc """
  Comprehensive metrics collection and monitoring for Verkle trees.

  This module provides detailed performance monitoring, operational metrics,
  and production readiness monitoring for all Verkle tree operations.
  It tracks everything needed for production monitoring and alerting.

  Key metrics categories:
  - Performance metrics (throughput, latency, caching efficiency)
  - Operational metrics (error rates, resource usage, queue depths)
  - Business metrics (witness generation, state sync efficiency)
  - Security metrics (verification rates, healing success)
  - Infrastructure metrics (memory, CPU, network efficiency)
  """

  use GenServer
  require Logger

  # 10 seconds
  @metrics_interval 10_000
  @metrics_retention_hours 24
  @alert_thresholds %{
    error_rate_percent: 5.0,
    latency_p99_ms: 1000,
    cache_hit_rate_percent: 85.0,
    witness_verification_success_rate: 95.0,
    memory_usage_mb: 1024
  }

  @type metric_type :: :counter | :gauge | :histogram | :summary
  @type metric_name :: atom()
  @type metric_value :: number()
  @type metric_tags :: map()

  @type metric_entry :: %{
          name: metric_name(),
          type: metric_type(),
          value: metric_value(),
          tags: metric_tags(),
          timestamp: integer()
        }

  @type t :: %__MODULE__{
          metrics_buffer: [metric_entry()],
          aggregated_metrics: %{metric_name() => metric_entry()},
          alert_state: %{metric_name() => boolean()},
          collection_interval: integer(),
          retention_hours: integer(),
          last_collection: integer(),
          performance_baselines: map(),
          prometheus_enabled: boolean(),
          grafana_enabled: boolean()
        }

  defstruct metrics_buffer: [],
            aggregated_metrics: %{},
            alert_state: %{},
            collection_interval: @metrics_interval,
            retention_hours: @metrics_retention_hours,
            last_collection: 0,
            performance_baselines: %{},
            prometheus_enabled: false,
            grafana_enabled: false

  # Client API

  @doc """
  Start the metrics collection system.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a counter metric (monotonically increasing).
  """
  @spec increment_counter(metric_name(), metric_value(), metric_tags()) :: :ok
  def increment_counter(name, value \\ 1, tags \\ %{}) do
    GenServer.cast(__MODULE__, {:metric, :counter, name, value, tags})
  end

  @doc """
  Record a gauge metric (point-in-time value).
  """
  @spec set_gauge(metric_name(), metric_value(), metric_tags()) :: :ok
  def set_gauge(name, value, tags \\ %{}) do
    GenServer.cast(__MODULE__, {:metric, :gauge, name, value, tags})
  end

  @doc """
  Record a histogram metric (distribution of values).
  """
  @spec record_histogram(metric_name(), metric_value(), metric_tags()) :: :ok
  def record_histogram(name, value, tags \\ %{}) do
    GenServer.cast(__MODULE__, {:metric, :histogram, name, value, tags})
  end

  @doc """
  Record timing metrics with automatic duration calculation.
  """
  @spec time_operation(metric_name(), (-> any()), metric_tags()) :: any()
  def time_operation(name, operation, tags \\ %{}) do
    start_time = System.monotonic_time(:microsecond)

    try do
      result = operation.()
      duration_us = System.monotonic_time(:microsecond) - start_time
      record_histogram(name, duration_us, tags)
      increment_counter(:"#{name}_total", 1, Map.put(tags, :status, :success))
      result
    rescue
      e ->
        duration_us = System.monotonic_time(:microsecond) - start_time
        record_histogram(name, duration_us, tags)
        increment_counter(:"#{name}_total", 1, Map.put(tags, :status, :error))
        increment_counter(:"#{name}_errors", 1, Map.put(tags, :error_type, e.__struct__))
        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Get current metrics snapshot.
  """
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @doc """
  Get performance statistics and analysis.
  """
  def get_performance_stats do
    GenServer.call(__MODULE__, :get_performance_stats)
  end

  @doc """
  Get current alert status.
  """
  def get_alerts do
    GenServer.call(__MODULE__, :get_alerts)
  end

  @doc """
  Reset all metrics (useful for testing).
  """
  def reset_metrics do
    GenServer.call(__MODULE__, :reset_metrics)
  end

  @doc """
  Enable/disable external metrics systems.
  """
  def configure_external_metrics(prometheus: prometheus, grafana: grafana) do
    GenServer.call(__MODULE__, {:configure_external, prometheus, grafana})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %__MODULE__{
      collection_interval: Keyword.get(opts, :interval, @metrics_interval),
      retention_hours: Keyword.get(opts, :retention_hours, @metrics_retention_hours),
      prometheus_enabled: Keyword.get(opts, :prometheus, false),
      grafana_enabled: Keyword.get(opts, :grafana, false),
      last_collection: System.system_time(:second)
    }

    Logger.info("Starting Verkle Tree metrics collection system")

    # Initialize performance baselines
    initialize_baselines(state)

    # Schedule periodic metrics collection
    schedule_metrics_collection(state.collection_interval)

    # Setup external metrics systems
    setup_external_metrics(state)

    {:ok, state}
  end

  @impl true
  def handle_cast({:metric, type, name, value, tags}, state) do
    metric_entry = %{
      name: name,
      type: type,
      value: value,
      tags: tags,
      timestamp: System.system_time(:millisecond)
    }

    new_buffer = [metric_entry | state.metrics_buffer]

    # Update external metrics if enabled
    if state.prometheus_enabled do
      update_prometheus_metric(metric_entry)
    end

    if state.grafana_enabled do
      update_grafana_metric(metric_entry)
    end

    {:noreply, %{state | metrics_buffer: new_buffer}}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    current_metrics = build_metrics_snapshot(state)
    {:reply, current_metrics, state}
  end

  @impl true
  def handle_call(:get_performance_stats, _from, state) do
    performance_stats = calculate_performance_stats(state)
    {:reply, performance_stats, state}
  end

  @impl true
  def handle_call(:get_alerts, _from, state) do
    {:reply, state.alert_state, state}
  end

  @impl true
  def handle_call(:reset_metrics, _from, state) do
    new_state = %{state | metrics_buffer: [], aggregated_metrics: %{}, alert_state: %{}}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:configure_external, prometheus, grafana}, _from, state) do
    new_state = %{state | prometheus_enabled: prometheus, grafana_enabled: grafana}

    setup_external_metrics(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:collect_metrics, state) do
    new_state = process_metrics_collection(state)

    # Schedule next collection
    schedule_metrics_collection(state.collection_interval)

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check_alerts, state) do
    new_state = check_alert_conditions(state)

    # Schedule next alert check
    # 30 seconds
    Process.send_after(self(), :check_alerts, 30_000)

    {:noreply, new_state}
  end

  # Private Functions

  defp initialize_baselines(state) do
    # Initialize performance baselines for comparison
    baselines = %{
      # 1ms baseline for MPT inserts
      mpt_insert_latency_us: 1000,
      # Target 30μs for Verkle (35x faster)
      verkle_insert_target_us: 30,
      # 3KB average MPT witness
      mpt_witness_size_bytes: 3072,
      # Target 200 bytes for Verkle
      verkle_witness_target_bytes: 200,
      # 85% cache hit rate baseline
      cache_hit_rate_baseline: 85.0,
      # 99% verification success baseline
      verification_success_baseline: 99.0
    }

    # Store baselines for alerts and performance analysis
    :ets.new(:verkle_baselines, [:set, :public, :named_table])
    :ets.insert(:verkle_baselines, {:baselines, baselines})
  end

  defp process_metrics_collection(state) do
    current_time = System.system_time(:second)

    # Aggregate metrics from buffer
    new_aggregated = aggregate_metrics(state.metrics_buffer, state.aggregated_metrics)

    # Clean old metrics based on retention policy
    cleaned_metrics = clean_old_metrics(new_aggregated, current_time, state.retention_hours)

    # Generate performance reports
    performance_report = generate_performance_report(cleaned_metrics)

    # Log key performance indicators
    log_performance_kpis(performance_report)

    %{
      state
      | metrics_buffer: [],
        aggregated_metrics: cleaned_metrics,
        last_collection: current_time
    }
  end

  defp aggregate_metrics(buffer, existing_aggregated) do
    # Group metrics by name and type, then aggregate
    buffer
    |> Enum.group_by(fn metric -> {metric.name, metric.type} end)
    |> Enum.reduce(existing_aggregated, fn {{name, type}, metrics}, acc ->
      aggregated_value =
        case type do
          :counter ->
            current = Map.get(acc, name, %{value: 0})
            total_value = current.value + Enum.sum(Enum.map(metrics, & &1.value))
            %{hd(metrics) | value: total_value}

          :gauge ->
            # Use the most recent gauge value
            Enum.max_by(metrics, & &1.timestamp)

          :histogram ->
            # Store all histogram values for percentile calculation
            values = Enum.map(metrics, & &1.value)
            existing_values = Map.get(acc, name, %{values: []}).values || []
            %{hd(metrics) | values: values ++ existing_values}

          :summary ->
            # Similar to histogram but with different aggregation
            values = Enum.map(metrics, & &1.value)
            existing_values = Map.get(acc, name, %{values: []}).values || []
            %{hd(metrics) | values: values ++ existing_values}
        end

      Map.put(acc, name, aggregated_value)
    end)
  end

  defp clean_old_metrics(metrics, current_time, retention_hours) do
    cutoff_time = current_time - retention_hours * 3600

    metrics
    |> Enum.filter(fn {_name, metric} ->
      # Convert to milliseconds
      metric.timestamp > cutoff_time * 1000
    end)
    |> Enum.into(%{})
  end

  defp generate_performance_report(metrics) do
    # Calculate key performance indicators
    insert_latency_p99 = calculate_percentile(metrics, :verkle_insert_duration_us, 99)
    read_latency_p99 = calculate_percentile(metrics, :verkle_read_duration_us, 99)

    witness_gen_latency_p99 =
      calculate_percentile(metrics, :verkle_witness_generation_duration_us, 99)

    cache_hit_rate = calculate_cache_hit_rate(metrics)
    witness_verification_success_rate = calculate_verification_success_rate(metrics)

    # Calculate performance vs baselines
    [{_, baselines}] = :ets.lookup(:verkle_baselines, :baselines)

    performance_ratio =
      if insert_latency_p99 > 0 do
        baselines.mpt_insert_latency_us / insert_latency_p99
      else
        0
      end

    %{
      performance_summary: %{
        insert_latency_p99_us: insert_latency_p99,
        read_latency_p99_us: read_latency_p99,
        witness_generation_latency_p99_us: witness_gen_latency_p99,
        cache_hit_rate_percent: cache_hit_rate,
        witness_verification_success_rate_percent: witness_verification_success_rate,
        performance_vs_mpt_ratio: performance_ratio
      },
      throughput_metrics: calculate_throughput_metrics(metrics),
      resource_usage: calculate_resource_usage(metrics),
      error_analysis: calculate_error_analysis(metrics),
      timestamp: System.system_time(:second)
    }
  end

  defp calculate_percentile(metrics, metric_name, percentile) do
    case Map.get(metrics, metric_name) do
      nil ->
        0

      %{values: values} when is_list(values) and length(values) > 0 ->
        sorted_values = Enum.sort(values)
        index = round(length(sorted_values) * percentile / 100) - 1
        index = max(0, min(index, length(sorted_values) - 1))
        Enum.at(sorted_values, index)

      _ ->
        0
    end
  end

  defp calculate_cache_hit_rate(metrics) do
    hits = get_metric_value(metrics, :verkle_cache_hits, 0)
    misses = get_metric_value(metrics, :verkle_cache_misses, 0)
    total = hits + misses

    if total > 0, do: hits / total * 100, else: 0
  end

  defp calculate_verification_success_rate(metrics) do
    successes = get_metric_value(metrics, :verkle_witness_verification_success, 0)
    failures = get_metric_value(metrics, :verkle_witness_verification_failure, 0)
    total = successes + failures

    if total > 0, do: successes / total * 100, else: 0
  end

  defp calculate_throughput_metrics(metrics) do
    %{
      inserts_per_second: get_metric_value(metrics, :verkle_inserts_total, 0) / 60,
      reads_per_second: get_metric_value(metrics, :verkle_reads_total, 0) / 60,
      witness_generations_per_second:
        get_metric_value(metrics, :verkle_witness_generations_total, 0) / 60,
      witness_verifications_per_second:
        get_metric_value(metrics, :verkle_witness_verifications_total, 0) / 60
    }
  end

  defp calculate_resource_usage(metrics) do
    %{
      memory_usage_mb: get_metric_value(metrics, :verkle_memory_usage_bytes, 0) / 1_048_576,
      cpu_usage_percent: get_metric_value(metrics, :verkle_cpu_usage_percent, 0),
      cache_memory_usage_mb: get_metric_value(metrics, :verkle_cache_memory_bytes, 0) / 1_048_576,
      network_bytes_sent: get_metric_value(metrics, :verkle_network_bytes_sent, 0),
      network_bytes_received: get_metric_value(metrics, :verkle_network_bytes_received, 0)
    }
  end

  defp calculate_error_analysis(metrics) do
    total_operations = get_metric_value(metrics, :verkle_operations_total, 0)
    total_errors = get_metric_value(metrics, :verkle_errors_total, 0)

    error_rate =
      if total_operations > 0 do
        total_errors / total_operations * 100
      else
        0
      end

    %{
      total_errors: total_errors,
      error_rate_percent: error_rate,
      crypto_errors: get_metric_value(metrics, :verkle_crypto_errors, 0),
      network_errors: get_metric_value(metrics, :verkle_network_errors, 0),
      storage_errors: get_metric_value(metrics, :verkle_storage_errors, 0)
    }
  end

  defp get_metric_value(metrics, name, default) do
    case Map.get(metrics, name) do
      nil -> default
      %{value: value} -> value
      _ -> default
    end
  end

  defp log_performance_kpis(performance_report) do
    summary = performance_report.performance_summary

    Logger.info("""
    Verkle Tree Performance KPIs:
      Insert Latency P99: #{summary.insert_latency_p99_us}μs
      Read Latency P99: #{summary.read_latency_p99_us}μs  
      Witness Gen P99: #{summary.witness_generation_latency_p99_us}μs
      Cache Hit Rate: #{Float.round(summary.cache_hit_rate_percent, 1)}%
      Verification Success: #{Float.round(summary.witness_verification_success_rate_percent, 1)}%
      Performance vs MPT: #{Float.round(summary.performance_vs_mpt_ratio, 1)}x faster
    """)

    # Log throughput metrics
    throughput = performance_report.throughput_metrics

    Logger.info("""
    Verkle Tree Throughput:
      Inserts/sec: #{Float.round(throughput.inserts_per_second, 1)}
      Reads/sec: #{Float.round(throughput.reads_per_second, 1)}
      Witness Gen/sec: #{Float.round(throughput.witness_generations_per_second, 1)}
      Verifications/sec: #{Float.round(throughput.witness_verifications_per_second, 1)}
    """)
  end

  defp check_alert_conditions(state) do
    _current_metrics = build_metrics_snapshot(state)
    performance_stats = calculate_performance_stats(state)

    new_alert_state =
      @alert_thresholds
      |> Enum.reduce(state.alert_state, fn {metric_name, threshold}, alerts ->
        current_value = get_current_metric_value(performance_stats, metric_name)

        alert_active =
          case metric_name do
            :error_rate_percent -> current_value > threshold
            :latency_p99_ms -> current_value > threshold
            :cache_hit_rate_percent -> current_value < threshold
            :witness_verification_success_rate -> current_value < threshold
            :memory_usage_mb -> current_value > threshold
          end

        previous_state = Map.get(alerts, metric_name, false)

        # Trigger alert if state changed
        if alert_active != previous_state do
          if alert_active do
            trigger_alert(metric_name, current_value, threshold)
          else
            resolve_alert(metric_name, current_value, threshold)
          end
        end

        Map.put(alerts, metric_name, alert_active)
      end)

    %{state | alert_state: new_alert_state}
  end

  defp get_current_metric_value(performance_stats, metric_name) do
    case metric_name do
      :error_rate_percent ->
        performance_stats.error_analysis.error_rate_percent

      :latency_p99_ms ->
        performance_stats.performance_summary.insert_latency_p99_us / 1000

      :cache_hit_rate_percent ->
        performance_stats.performance_summary.cache_hit_rate_percent

      :witness_verification_success_rate ->
        performance_stats.performance_summary.witness_verification_success_rate_percent

      :memory_usage_mb ->
        performance_stats.resource_usage.memory_usage_mb
    end
  end

  defp trigger_alert(metric_name, current_value, threshold) do
    Logger.warning("""
    🚨 VERKLE TREE ALERT: #{metric_name}
    Current Value: #{current_value}
    Threshold: #{threshold}
    Time: #{DateTime.utc_now()}
    """)

    # Here you could integrate with external alerting systems
    # send_to_pagerduty(metric_name, current_value, threshold)
    # send_to_slack(metric_name, current_value, threshold)
  end

  defp resolve_alert(metric_name, current_value, threshold) do
    Logger.info("""
    ✅ VERKLE TREE ALERT RESOLVED: #{metric_name}
    Current Value: #{current_value}
    Threshold: #{threshold}
    Time: #{DateTime.utc_now()}
    """)
  end

  defp build_metrics_snapshot(state) do
    %{
      buffer_size: length(state.metrics_buffer),
      aggregated_count: map_size(state.aggregated_metrics),
      last_collection: state.last_collection,
      current_time: System.system_time(:second),
      collection_interval: state.collection_interval,
      retention_hours: state.retention_hours,
      external_systems: %{
        prometheus_enabled: state.prometheus_enabled,
        grafana_enabled: state.grafana_enabled
      }
    }
  end

  defp calculate_performance_stats(state) do
    generate_performance_report(state.aggregated_metrics)
  end

  defp schedule_metrics_collection(interval) do
    Process.send_after(self(), :collect_metrics, interval)
  end

  defp setup_external_metrics(state) do
    if state.prometheus_enabled do
      setup_prometheus_metrics()
    end

    if state.grafana_enabled do
      setup_grafana_metrics()
    end
  end

  defp update_prometheus_metric(_metric_entry) do
    # Integration with Prometheus would go here
    # :prometheus_counter.inc(:verkle_operations_total)
    # :prometheus_histogram.observe(:verkle_latency, duration)
    :ok
  end

  defp update_grafana_metric(_metric_entry) do
    # Integration with Grafana would go here
    # Push metrics to Grafana via HTTP API
    :ok
  end

  defp setup_prometheus_metrics do
    # Setup Prometheus metrics definitions
    Logger.info("Setting up Prometheus metrics for Verkle trees")
  end

  defp setup_grafana_metrics do
    # Setup Grafana dashboard and alerts
    Logger.info("Setting up Grafana metrics for Verkle trees")
  end
end
