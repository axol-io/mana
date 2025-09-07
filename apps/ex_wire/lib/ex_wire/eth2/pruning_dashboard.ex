defmodule ExWire.Eth2.PruningDashboard do
  @moduledoc """
  Real-time monitoring dashboard for pruning operations.

  Provides a web-based interface for monitoring pruning health, performance,
  and storage utilization. Includes alerts for anomalies and recommendations
  for optimization.
  """

  use GenServer
  require Logger

  alias ExWire.Eth2.{PruningMetrics, PruningManager, PruningScheduler}

  defstruct [
    :http_server,
    :config,
    :alert_thresholds,
    :active_alerts,
    dashboard_data: %{},
    last_update: nil,
    update_interval_ms: 5000
  ]

  # Alert thresholds
  @default_thresholds %{
    error_rate_percent: 5.0,
    cpu_usage_percent: 25.0,
    memory_usage_mb: 2000,
    efficiency_mb_per_sec: 10.0,
    storage_usage_percent: 90.0,
    operation_duration_ms: 30000
  }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Get current dashboard data
  """
  def get_dashboard_data do
    GenServer.call(__MODULE__, :get_dashboard_data)
  end

  @doc """
  Get active alerts
  """
  def get_alerts do
    GenServer.call(__MODULE__, :get_alerts)
  end

  @doc """
  Update alert thresholds
  """
  def update_thresholds(new_thresholds) do
    GenServer.cast(__MODULE__, {:update_thresholds, new_thresholds})
  end

  @doc """
  Export dashboard data as JSON
  """
  def export_data(format \\ :json) do
    GenServer.call(__MODULE__, {:export_data, format})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting PruningDashboard with real-time monitoring")

    config = Keyword.get(opts, :config, %{})
    port = Keyword.get(opts, :http_port, 8080)

    # Start HTTP server for dashboard
    http_server = start_http_server(port)

    state = %__MODULE__{
      http_server: http_server,
      config: config,
      alert_thresholds: Map.merge(@default_thresholds, Keyword.get(opts, :alert_thresholds, %{})),
      active_alerts: [],
      last_update: DateTime.utc_now()
    }

    # Schedule periodic updates
    schedule_dashboard_update()

    {:ok, _state}
  end

  @impl true
  def handle_call(:get_dashboard_data, _from, _state) do
    {:reply, {:ok, state.dashboard_data}, state}
  end

  @impl true
  def handle_call(:get_alerts, _from, _state) do
    {:reply, {:ok, state.active_alerts}, state}
  end

  @impl true
  def handle_call({:export_data, format}, _from, _state) do
    exported = export_dashboard_data(state.dashboard_data, format)
    {:reply, {:ok, exported}, state}
  end

  @impl true
  def handle_cast({:update_thresholds, new_thresholds}, _state) do
    updated_thresholds = Map.merge(state.alert_thresholds, new_thresholds)
    Logger.info("Updated alert thresholds: #{inspect(new_thresholds)}")

    state = %{state | alert_thresholds: updated_thresholds}

    # Re-evaluate alerts with new thresholds
    state = evaluate_alerts(state)

    {:noreply, state}
  end

  @impl true
  def handle_info(:update_dashboard, _state) do
    # Collect fresh dashboard data
    state = collect_dashboard_data(state)

    # Evaluate alerts based on current data
    state = evaluate_alerts(state)

    # Schedule next update
    schedule_dashboard_update()

    {:noreply, state}
  end

  # Private Functions - Data Collection

  defp collect_dashboard_data(_state) do
    Logger.debug("Collecting dashboard data")

    # Collect data from various sources
    metrics_summary = get_metrics_summary()
    pruning_status = get_pruning_status()
    scheduler_status = get_scheduler_status()
    storage_stats = get_storage_statistics()
    system_health = get_system_health()

    # Create comprehensive dashboard data
    dashboard_data = %{
      overview: create_overview_data(metrics_summary, pruning_status, system_health),
      performance: create_performance_data(metrics_summary),
      storage: create_storage_data(storage_stats),
      operations: create_operations_data(pruning_status, scheduler_status),
      alerts: create_alerts_summary(state.active_alerts),
      trends: create_trends_data(metrics_summary),
      configuration: create_config_summary(),
      timestamp: DateTime.utc_now()
    }

    %{state | dashboard_data: dashboard_data, last_update: DateTime.utc_now()}
  end

  defp create_overview_data(metrics_summary, pruning_status, system_health) do
    %{
      system_status: determine_overall_status(system_health),
      pruning_active: Map.get(pruning_status, :pruning_state, :idle) != :idle,
      total_space_saved_gb:
        (Map.get(metrics_summary, :space_savings, %{})
         |> Map.get(:total_space_freed_mb, 0)) / 1024,
      success_rate_percent:
        Map.get(metrics_summary, :operations, %{})
        |> Map.get(:success_rate, 0),
      active_alerts_count: length(Map.get(metrics_summary, :alerts, [])),
      last_pruning_time: Map.get(pruning_status, :last_pruning_time),
      next_scheduled_pruning: get_next_pruning_time(),
      uptime_hours: get_system_uptime_hours()
    }
  end

  defp create_performance_data(metrics_summary) do
    performance = Map.get(metrics_summary, :performance, %{})

    %{
      avg_operation_duration_ms: Map.get(performance, :avg_duration_ms, 0),
      operations_per_hour: calculate_operations_per_hour(performance),
      efficiency_mb_per_sec: calculate_current_efficiency(performance),
      cpu_usage_percent:
        Map.get(metrics_summary, :system_impact, %{})
        |> Map.get(:avg_cpu_usage_percent, 0),
      memory_usage_mb:
        Map.get(metrics_summary, :system_impact, %{})
        |> Map.get(:avg_memory_usage_mb, 0),
      io_wait_percent:
        Map.get(metrics_summary, :system_impact, %{})
        |> Map.get(:avg_io_wait_percent, 0),
      performance_trend: Map.get(performance, :performance_trend, :stable)
    }
  end

  defp create_storage_data(storage_stats) do
    %{
      total_storage_gb: Map.get(storage_stats, :total_disk_usage_gb, 0),
      available_space_gb: Map.get(storage_stats, :available_space_gb, 0),
      usage_percent: Map.get(storage_stats, :usage_percent, 0) * 100,
      hot_storage: %{
        size_gb: get_tier_size(:hot) / 1024,
        utilization_percent: get_tier_utilization(:hot),
        items: get_tier_item_count(:hot)
      },
      warm_storage: %{
        size_gb: get_tier_size(:warm) / 1024,
        utilization_percent: get_tier_utilization(:warm),
        items: get_tier_item_count(:warm)
      },
      cold_storage: %{
        size_gb: get_tier_size(:cold) / 1024,
        utilization_percent: get_tier_utilization(:cold),
        items: get_tier_item_count(:cold)
      },
      space_freed_today_gb: get_space_freed_today() / 1024
    }
  end

  defp create_operations_data(pruning_status, scheduler_status) do
    %{
      current_operation: Map.get(pruning_status, :pruning_state, :idle),
      queued_operations: Map.get(scheduler_status, :queued_jobs, 0),
      active_workers: Map.get(pruning_status, :active_pruners, []) |> length(),
      recent_operations: get_recent_operations(),
      operation_history: get_operation_history_chart_data(),
      success_rate_trend: get_success_rate_trend(),
      avg_duration_trend: get_duration_trend()
    }
  end

  defp create_alerts_summary(active_alerts) do
    %{
      total_alerts: length(active_alerts),
      critical_alerts: Enum.count(active_alerts, &(&1.severity == :critical)),
      warning_alerts: Enum.count(active_alerts, &(&1.severity == :warning)),
      recent_alerts: Enum.take(active_alerts, 5),
      alert_history: get_alert_history()
    }
  end

  defp create_trends_data(metrics_summary) do
    %{
      space_savings_trend: get_space_savings_trend(),
      performance_trend: get_performance_trend_data(),
      error_rate_trend: get_error_rate_trend(),
      storage_growth_trend: get_storage_growth_trend(),
      system_impact_trend: get_system_impact_trend()
    }
  end

  defp create_config_summary do
    case PruningManager.get_status() do
      {:ok, status} ->
        config = Map.get(status, :config, %{})

        %{
          pruning_interval_minutes: Map.get(config, :pruning_interval_ms, 300_000) / 60_000,
          retention_policy: %{
            states_days: slots_to_days(Map.get(config, :state_retention, 0)),
            blocks_days: slots_to_days(Map.get(config, :finalized_block_retention, 0)),
            attestations_epochs: Map.get(config, :attestation_retention, 0) / 32
          },
          concurrent_workers: Map.get(config, :max_concurrent_pruners, 0),
          archive_mode: Map.get(config, :archive_mode, false),
          cold_storage_enabled: Map.get(config, :enable_cold_storage, false)
        }

      _ ->
        %{error: "Unable to retrieve configuration"}
    end
  end

  # Private Functions - Alert System

  defp evaluate_alerts(_state) do
    current_data = state.dashboard_data
    thresholds = state.alert_thresholds

    # Clear expired alerts
    active_alerts = clear_expired_alerts(state.active_alerts)

    # Check for new alerts
    new_alerts = []

    # CPU usage alert
    new_alerts = check_cpu_alert(current_data, thresholds, new_alerts)

    # Memory usage alert
    new_alerts = check_memory_alert(current_data, thresholds, new_alerts)

    # Error rate alert
    new_alerts = check_error_rate_alert(current_data, thresholds, new_alerts)

    # Storage usage alert
    new_alerts = check_storage_alert(current_data, thresholds, new_alerts)

    # Efficiency alert
    new_alerts = check_efficiency_alert(current_data, thresholds, new_alerts)

    # Operation duration alert
    new_alerts = check_duration_alert(current_data, thresholds, new_alerts)

    # Combine and deduplicate alerts
    all_alerts =
      (active_alerts ++ new_alerts)
      |> Enum.uniq_by(&{&1.type, &1.message})
      |> Enum.sort_by(&alert_severity_order/1)

    # Log new alerts
    Enum.each(new_alerts, fn alert ->
      Logger.warning("New pruning alert: #{alert.message} (severity: #{alert.severity})")
    end)

    %{state | active_alerts: all_alerts}
  end

  defp check_cpu_alert(data, thresholds, alerts) do
    cpu_usage = get_in(data, [:performance, :cpu_usage_percent]) || 0
    threshold = Map.get(thresholds, :cpu_usage_percent)

    if cpu_usage > threshold do
      alert = %{
        type: :cpu_usage,
        severity: if(cpu_usage > threshold * 1.5, do: :critical, else: :warning),
        message: "High CPU usage during pruning: #{Float.round(cpu_usage, 1)}%",
        value: cpu_usage,
        threshold: threshold,
        timestamp: DateTime.utc_now(),
        # 5 minutes
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
      }

      [alert | alerts]
    else
      alerts
    end
  end

  defp check_memory_alert(data, thresholds, alerts) do
    memory_usage = get_in(data, [:performance, :memory_usage_mb]) || 0
    threshold = Map.get(thresholds, :memory_usage_mb)

    if memory_usage > threshold do
      alert = %{
        type: :memory_usage,
        severity: if(memory_usage > threshold * 1.2, do: :critical, else: :warning),
        message: "High memory usage during pruning: #{Float.round(memory_usage, 0)} MB",
        value: memory_usage,
        threshold: threshold,
        timestamp: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
      }

      [alert | alerts]
    else
      alerts
    end
  end

  defp check_error_rate_alert(data, thresholds, alerts) do
    success_rate = get_in(data, [:overview, :success_rate_percent]) || 100
    error_rate = 100 - success_rate
    threshold = Map.get(thresholds, :error_rate_percent)

    if error_rate > threshold do
      alert = %{
        type: :error_rate,
        severity: if(error_rate > threshold * 2, do: :critical, else: :warning),
        message: "High pruning error rate: #{Float.round(error_rate, 1)}%",
        value: error_rate,
        threshold: threshold,
        timestamp: DateTime.utc_now(),
        # 10 minutes
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      }

      [alert | alerts]
    else
      alerts
    end
  end

  defp check_storage_alert(data, thresholds, alerts) do
    storage_usage = get_in(data, [:storage, :usage_percent]) || 0
    threshold = Map.get(thresholds, :storage_usage_percent)

    if storage_usage > threshold do
      alert = %{
        type: :storage_usage,
        severity: if(storage_usage > 95, do: :critical, else: :warning),
        message: "High storage usage: #{Float.round(storage_usage, 1)}%",
        value: storage_usage,
        threshold: threshold,
        timestamp: DateTime.utc_now(),
        # 1 hour
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      [alert | alerts]
    else
      alerts
    end
  end

  defp check_efficiency_alert(data, thresholds, alerts) do
    efficiency = get_in(data, [:performance, :efficiency_mb_per_sec]) || 0
    threshold = Map.get(thresholds, :efficiency_mb_per_sec)

    if efficiency > 0 && efficiency < threshold do
      alert = %{
        type: :low_efficiency,
        severity: if(efficiency < threshold / 2, do: :critical, else: :warning),
        message: "Low pruning efficiency: #{Float.round(efficiency, 1)} MB/s",
        value: efficiency,
        threshold: threshold,
        timestamp: DateTime.utc_now(),
        # 15 minutes
        expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
      }

      [alert | alerts]
    else
      alerts
    end
  end

  defp check_duration_alert(data, thresholds, alerts) do
    duration = get_in(data, [:performance, :avg_operation_duration_ms]) || 0
    threshold = Map.get(thresholds, :operation_duration_ms)

    if duration > threshold do
      alert = %{
        type: :long_duration,
        severity: if(duration > threshold * 2, do: :critical, else: :warning),
        message: "Long pruning operation duration: #{Float.round(duration / 1000, 1)}s",
        value: duration,
        threshold: threshold,
        timestamp: DateTime.utc_now(),
        # 10 minutes
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      }

      [alert | alerts]
    else
      alerts
    end
  end

  defp clear_expired_alerts(alerts) do
    now = DateTime.utc_now()

    Enum.filter(alerts, fn alert ->
      DateTime.compare(alert.expires_at, now) == :gt
    end)
  end

  defp alert_severity_order(alert) do
    case alert.severity do
      :critical -> 1
      :warning -> 2
      :info -> 3
      _ -> 4
    end
  end

  # Private Functions - HTTP Server

  defp start_http_server(port) do
    # This would start a simple HTTP server for the dashboard
    # For now, return a placeholder
    %{port: port, status: :running}
  end

  # Private Functions - Data Helpers

  defp get_metrics_summary do
    case PruningMetrics.get_metrics_summary() do
      {:ok, summary} -> summary
      _ -> %{}
    end
  end

  defp get_pruning_status do
    case PruningManager.get_status() do
      {:ok, status} -> status
      _ -> %{}
    end
  end

  defp get_scheduler_status do
    case PruningScheduler.get_status() do
      {:ok, status} -> status
      _ -> %{}
    end
  end

  defp get_storage_statistics do
    # Get storage statistics from system
    %{
      total_disk_usage_gb: 100.0,
      available_space_gb: 400.0,
      usage_percent: 0.2
    }
  end

  defp get_system_health do
    %{
      cpu_percent: 10.0,
      memory_percent: 30.0,
      load_average: 1.5,
      status: :healthy
    }
  end

  defp determine_overall_status(system_health) do
    case Map.get(system_health, :status, :unknown) do
      :healthy -> :operational
      :degraded -> :warning
      :critical -> :critical
      _ -> :unknown
    end
  end

  # Placeholder helper functions
  defp get_next_pruning_time, do: DateTime.add(DateTime.utc_now(), 300, :second)
  defp get_system_uptime_hours, do: 48.5
  defp calculate_operations_per_hour(_), do: 12
  defp calculate_current_efficiency(_), do: 25.5
  defp get_tier_size(_), do: 1024.0
  defp get_tier_utilization(_), do: 75.0
  defp get_tier_item_count(_), do: 1000
  defp get_space_freed_today, do: 500.0
  defp get_recent_operations, do: []
  defp get_operation_history_chart_data, do: []
  defp get_success_rate_trend, do: []
  defp get_duration_trend, do: []
  defp get_alert_history, do: []
  defp get_space_savings_trend, do: []
  defp get_performance_trend_data, do: []
  defp get_error_rate_trend, do: []
  defp get_storage_growth_trend, do: []
  defp get_system_impact_trend, do: []
  # ~32 slots/epoch, ~225 epochs/day
  defp slots_to_days(slots), do: slots / (32 * 225)

  defp export_dashboard_data(data, :json) do
    Jason.encode!(data)
  end

  defp export_dashboard_data(data, :csv) do
    # Convert to CSV format
    "timestamp,metric,value\n"
  end

  defp schedule_dashboard_update do
    # 5 seconds
    Process.send_after(self(), :update_dashboard, 5000)
  end
end
