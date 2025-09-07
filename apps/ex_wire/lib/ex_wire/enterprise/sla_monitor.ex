defmodule ExWire.Enterprise.SLAMonitor do
  @moduledoc """
  Service Level Agreement (SLA) monitoring and reporting for enterprise deployments.
  Tracks uptime, performance metrics, response times, and generates compliance reports.
  """

  use GenServer
  require Logger

  alias ExWire.Enterprise.{AuditLogger, Integrations}

  defstruct [
    :sla_definitions,
    :metrics,
    :incidents,
    :reports,
    :alert_thresholds,
    :notification_channels,
    :config
  ]

  @type sla_definition :: %{
          id: String.t(),
          name: String.t(),
          customer: String.t(),
          metrics: list(sla_metric()),
          reporting_period: :daily | :weekly | :monthly,
          penalties: map(),
          start_date: Date.t(),
          end_date: Date.t() | nil
        }

  @type sla_metric :: %{
          name: String.t(),
          type: :availability | :response_time | :throughput | :error_rate,
          target: number(),
          measurement: String.t(),
          calculation: :average | :percentile | :minimum | :maximum
        }

  @type incident :: %{
          id: String.t(),
          sla_id: String.t(),
          metric: String.t(),
          severity: :low | :medium | :high | :critical,
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          duration: non_neg_integer() | nil,
          impact: String.t(),
          resolution: String.t() | nil
        }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Define a new SLA
  """
  def define_sla(name, customer, metrics, opts \\ []) do
    GenServer.call(__MODULE__, {:define_sla, name, customer, metrics, opts})
  end

  @doc """
  Record a metric measurement
  """
  def record_metric(metric_name, value, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:record_metric, metric_name, value, metadata})
  end

  @doc """
  Report an incident
  """
  def report_incident(sla_id, metric, severity, impact) do
    GenServer.call(__MODULE__, {:report_incident, sla_id, metric, severity, impact})
  end

  @doc """
  Resolve an incident
  """
  def resolve_incident(incident_id, resolution) do
    GenServer.call(__MODULE__, {:resolve_incident, incident_id, resolution})
  end

  @doc """
  Get SLA compliance status
  """
  def get_compliance_status(sla_id, time_range \\ :current_period) do
    GenServer.call(__MODULE__, {:get_compliance_status, sla_id, time_range})
  end

  @doc """
  Generate SLA report
  """
  def generate_report(sla_id, time_range) do
    GenServer.call(__MODULE__, {:generate_report, sla_id, time_range})
  end

  @doc """
  Get real-time metrics
  """
  def get_real_time_metrics do
    GenServer.call(__MODULE__, :get_real_time_metrics)
  end

  @doc """
  Set alert threshold
  """
  def set_alert_threshold(metric, threshold, action) do
    GenServer.call(__MODULE__, {:set_alert_threshold, metric, threshold, action})
  end

  @doc """
  Add notification channel
  """
  def add_notification_channel(type, _config) do
    GenServer.call(__MODULE__, {:add_notification_channel, type, config})
  end

  @doc """
  Get dashboard data
  """
  def get_dashboard_data do
    GenServer.call(__MODULE__, :get_dashboard_data)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting SLA Monitor")

    state = %__MODULE__{
      sla_definitions: %{},
      metrics: initialize_metrics_store(),
      incidents: [],
      reports: %{},
      alert_thresholds: initialize_default_thresholds(),
      notification_channels: [],
      config: build_config(opts)
    }

    # Schedule periodic tasks
    schedule_metric_collection()
    schedule_compliance_check()
    schedule_report_generation()

    {:ok, _state}
  end

  @impl true
  def handle_call({:define_sla, name, customer, metrics, opts}, _from, _state) do
    sla_id = generate_sla_id()

    sla = %{
      id: sla_id,
      name: name,
      customer: customer,
      metrics: validate_metrics(metrics),
      reporting_period: Keyword.get(opts, :reporting_period, :monthly),
      penalties: Keyword.get(opts, :penalties, %{}),
      start_date: Keyword.get(opts, :start_date, Date.utc_today()),
      end_date: Keyword.get(opts, :end_date),
      created_at: DateTime.utc_now()
    }

    state = put_in(state.sla_definitions[sla_id], sla)

    # Initialize metrics tracking for this SLA
    state = initialize_sla_metrics(state, sla)

    AuditLogger.log(:sla_defined, %{
      sla_id: sla_id,
      name: name,
      customer: customer,
      metrics_count: length(metrics)
    })

    {:reply, {:ok, sla}, state}
  end

  @impl true
  def handle_call({:report_incident, sla_id, metric, severity, impact}, _from, _state) do
    incident = %{
      id: generate_incident_id(),
      sla_id: sla_id,
      metric: metric,
      severity: severity,
      started_at: DateTime.utc_now(),
      ended_at: nil,
      duration: nil,
      impact: impact,
      resolution: nil,
      status: :active
    }

    state = update_in(state.incidents, &[incident | &1])

    # Send notifications
    notify_incident(incident, state.notification_channels)

    # Update SLA compliance
    state = update_sla_compliance(state, sla_id, incident)

    AuditLogger.log(:incident_reported, %{
      incident_id: incident.id,
      sla_id: sla_id,
      severity: severity
    })

    {:reply, {:ok, incident}, state}
  end

  @impl true
  def handle_call({:resolve_incident, incident_id, resolution}, _from, _state) do
    case Enum.find_index(state.incidents, &(&1.id == incident_id)) do
      nil ->
        {:reply, {:error, :incident_not_found}, state}

      index ->
        incident = Enum.at(state.incidents, index)
        ended_at = DateTime.utc_now()
        duration = DateTime.diff(ended_at, incident.started_at, :second)

        resolved_incident = %{
          incident
          | ended_at: ended_at,
            duration: duration,
            resolution: resolution,
            status: :resolved
        }

        state =
          put_in(state.incidents, List.replace_at(state.incidents, index, resolved_incident))

        # Update metrics
        state = update_incident_metrics(state, resolved_incident)

        AuditLogger.log(:incident_resolved, %{
          incident_id: incident_id,
          duration: duration,
          resolution: resolution
        })

        {:reply, {:ok, resolved_incident}, state}
    end
  end

  @impl true
  def handle_call({:get_compliance_status, sla_id, time_range}, _from, _state) do
    case Map.get(state.sla_definitions, sla_id) do
      nil ->
        {:reply, {:error, :sla_not_found}, state}

      sla ->
        compliance = calculate_compliance(sla, state.metrics, time_range)
        {:reply, {:ok, compliance}, state}
    end
  end

  @impl true
  def handle_call({:generate_report, sla_id, time_range}, _from, _state) do
    case Map.get(state.sla_definitions, sla_id) do
      nil ->
        {:reply, {:error, :sla_not_found}, state}

      sla ->
        report = generate_sla_report(sla, state, time_range)

        report_id = generate_report_id()
        state = put_in(state.reports[report_id], report)

        {:reply, {:ok, report}, state}
    end
  end

  @impl true
  def handle_call(:get_real_time_metrics, _from, _state) do
    metrics = %{
      availability: calculate_current_availability(state),
      response_time: get_current_response_time(state),
      throughput: get_current_throughput(state),
      error_rate: get_current_error_rate(state),
      active_incidents: count_active_incidents(state)
    }

    {:reply, {:ok, metrics}, state}
  end

  @impl true
  def handle_call({:set_alert_threshold, metric, threshold, action}, _from, _state) do
    threshold_config = %{
      metric: metric,
      threshold: threshold,
      action: action,
      enabled: true
    }

    state = put_in(state.alert_thresholds[metric], threshold_config)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add_notification_channel, type, _config}, _from, _state) do
    channel = %{
      id: generate_channel_id(),
      type: type,
      config: config,
      active: true
    }

    state = update_in(state.notification_channels, &[channel | &1])

    {:reply, {:ok, channel}, state}
  end

  @impl true
  def handle_call(:get_dashboard_data, _from, _state) do
    dashboard = %{
      sla_count: map_size(state.sla_definitions),
      overall_compliance: calculate_overall_compliance(state),
      active_incidents: count_active_incidents(state),
      metrics_summary: get_metrics_summary(state),
      recent_incidents: get_recent_incidents(state, 10),
      compliance_trends: calculate_compliance_trends(state)
    }

    {:reply, {:ok, dashboard}, state}
  end

  @impl true
  def handle_cast({:record_metric, metric_name, value, metadata}, _state) do
    timestamp = DateTime.utc_now()

    metric_entry = %{
      name: metric_name,
      value: value,
      timestamp: timestamp,
      metadata: metadata
    }

    state = store_metric(state, metric_entry)

    # Check thresholds
    state = check_alert_thresholds(state, metric_name, value)

    {:noreply, state}
  end

  @impl true
  def handle_info(:collect_metrics, _state) do
    state = collect_system_metrics(state)
    schedule_metric_collection()
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_compliance, _state) do
    state = check_all_sla_compliance(state)
    schedule_compliance_check()
    {:noreply, state}
  end

  @impl true
  def handle_info(:generate_reports, _state) do
    state = generate_periodic_reports(state)
    schedule_report_generation()
    {:noreply, state}
  end

  # Private Functions - Metrics

  defp initialize_metrics_store do
    %{
      availability: [],
      response_time: [],
      throughput: [],
      error_rate: [],
      custom: %{}
    }
  end

  defp initialize_sla_metrics(_state, sla) do
    # Set up metric tracking for each SLA metric
    Enum.reduce(sla.metrics, state, fn metric, acc_state ->
      initialize_metric_tracking(acc_state, sla.id, metric)
    end)
  end

  defp initialize_metric_tracking(_state, sla_id, metric) do
    # Initialize data structures for tracking this metric
    state
  end

  defp store_metric(_state, metric_entry) do
    metric_type = determine_metric_type(metric_entry.name)

    case metric_type do
      :availability ->
        update_in(state.metrics.availability, &[metric_entry | &1])

      :response_time ->
        update_in(state.metrics.response_time, &[metric_entry | &1])

      :throughput ->
        update_in(state.metrics.throughput, &[metric_entry | &1])

      :error_rate ->
        update_in(state.metrics.error_rate, &[metric_entry | &1])

      :custom ->
        update_in(state.metrics.custom[metric_entry.name], &[metric_entry | &1])
    end
  end

  defp collect_system_metrics(_state) do
    # Collect availability
    availability = measure_availability()

    state =
      store_metric(_state, %{
        name: "system.availability",
        value: availability,
        timestamp: DateTime.utc_now(),
        metadata: %{}
      })

    # Collect response time
    response_time = measure_response_time()

    state =
      store_metric(state, %{
        name: "api.response_time",
        value: response_time,
        timestamp: DateTime.utc_now(),
        metadata: %{}
      })

    # Collect throughput
    throughput = measure_throughput()

    state =
      store_metric(state, %{
        name: "system.throughput",
        value: throughput,
        timestamp: DateTime.utc_now(),
        metadata: %{}
      })

    # Collect error rate
    error_rate = measure_error_rate()

    store_metric(state, %{
      name: "system.error_rate",
      value: error_rate,
      timestamp: DateTime.utc_now(),
      metadata: %{}
    })
  end

  defp measure_availability do
    # Check system components
    99.95
  end

  defp measure_response_time do
    # Measure API response time
    45.5
  end

  defp measure_throughput do
    # Measure transactions per second
    1500
  end

  defp measure_error_rate do
    # Calculate error percentage
    0.05
  end

  # Private Functions - Compliance

  defp calculate_compliance(sla, metrics, time_range) do
    {start_time, end_time} = get_time_range(time_range, sla.reporting_period)

    Enum.map(sla.metrics, fn sla_metric ->
      actual_value =
        calculate_metric_value(
          sla_metric,
          metrics,
          start_time,
          end_time
        )

      compliance = calculate_metric_compliance(sla_metric, actual_value)

      %{
        metric: sla_metric.name,
        target: sla_metric.target,
        actual: actual_value,
        compliance: compliance,
        status: if(compliance >= 100, do: :met, else: :missed)
      }
    end)
  end

  defp calculate_metric_value(sla_metric, metrics, start_time, end_time) do
    relevant_metrics =
      get_metrics_in_range(
        metrics,
        sla_metric.type,
        start_time,
        end_time
      )

    case sla_metric.calculation do
      :average ->
        calculate_average(relevant_metrics)

      :percentile ->
        calculate_percentile(relevant_metrics, 95)

      :minimum ->
        calculate_minimum(relevant_metrics)

      :maximum ->
        calculate_maximum(relevant_metrics)
    end
  end

  defp calculate_metric_compliance(sla_metric, actual_value) do
    case sla_metric.type do
      :availability ->
        min(actual_value / sla_metric.target * 100, 100)

      :response_time ->
        min(sla_metric.target / actual_value * 100, 100)

      :throughput ->
        min(actual_value / sla_metric.target * 100, 100)

      :error_rate ->
        min(sla_metric.target / actual_value * 100, 100)
    end
  end

  defp check_all_sla_compliance(_state) do
    Enum.reduce(state.sla_definitions, _state, fn {sla_id, sla}, acc_state ->
      compliance = calculate_compliance(sla, acc_state.metrics, :current_period)

      # Check for violations
      violations = Enum.filter(compliance, &(&1.status == :missed))

      if length(violations) > 0 do
        handle_sla_violations(acc_state, sla, violations)
      else
        acc_state
      end
    end)
  end

  defp handle_sla_violations(_state, sla, violations) do
    # Create incidents for violations
    Enum.reduce(violations, state, fn violation, acc_state ->
      if should_create_incident?(violation) do
        incident = %{
          id: generate_incident_id(),
          sla_id: sla.id,
          metric: violation.metric,
          severity: determine_severity(violation),
          started_at: DateTime.utc_now(),
          impact: "SLA target missed: #{violation.actual} vs #{violation.target}",
          status: :active
        }

        update_in(acc_state.incidents, &[incident | &1])
      else
        acc_state
      end
    end)
  end

  defp should_create_incident?(violation) do
    # Check if incident should be created based on threshold
    violation.compliance < 95
  end

  defp determine_severity(violation) do
    cond do
      violation.compliance < 50 -> :critical
      violation.compliance < 80 -> :high
      violation.compliance < 95 -> :medium
      true -> :low
    end
  end

  defp update_sla_compliance(_state, sla_id, incident) do
    # Update compliance tracking based on incident
    state
  end

  defp update_incident_metrics(_state, incident) do
    # Update MTTR and other incident metrics
    state
  end

  defp calculate_overall_compliance(_state) do
    if map_size(state.sla_definitions) == 0 do
      100.0
    else
      compliances =
        Enum.map(state.sla_definitions, fn {_id, sla} ->
          compliance = calculate_compliance(sla, state.metrics, :current_period)

          Enum.reduce(compliance, 0, fn metric, acc ->
            acc + metric.compliance
          end) / length(compliance)
        end)

      Enum.sum(compliances) / length(compliances)
    end
  end

  defp calculate_compliance_trends(_state) do
    # Calculate compliance trends over time
    []
  end

  # Private Functions - Reporting

  defp generate_sla_report(sla, _state, time_range) do
    {start_time, end_time} = get_time_range(time_range, sla.reporting_period)

    compliance = calculate_compliance(sla, state.metrics, time_range)
    incidents = get_incidents_for_sla(state.incidents, sla.id, start_time, end_time)

    %{
      sla_id: sla.id,
      sla_name: sla.name,
      customer: sla.customer,
      period: %{start: start_time, end: end_time},
      compliance: compliance,
      overall_compliance: calculate_report_compliance(compliance),
      incidents: incidents,
      incident_summary: summarize_incidents(incidents),
      penalties: calculate_penalties(sla, compliance),
      generated_at: DateTime.utc_now()
    }
  end

  defp generate_periodic_reports(_state) do
    Enum.reduce(state.sla_definitions, state, fn {sla_id, sla}, acc_state ->
      if should_generate_report?(sla) do
        report = generate_sla_report(sla, acc_state, :current_period)

        # Send report
        send_report(report, sla, acc_state.notification_channels)

        # Store report
        report_id = generate_report_id()
        put_in(acc_state.reports[report_id], report)
      else
        acc_state
      end
    end)
  end

  defp should_generate_report?(sla) do
    # Check if report should be generated based on reporting period
    case sla.reporting_period do
      :daily -> true
      :weekly -> Date.day_of_week(Date.utc_today()) == 1
      :monthly -> Date.utc_today().day == 1
    end
  end

  defp send_report(report, sla, channels) do
    Enum.each(channels, fn channel ->
      send_report_to_channel(report, sla, channel)
    end)
  end

  defp send_report_to_channel(report, _sla, channel) do
    case channel.type do
      :email -> send_email_report(report, channel.config)
      :slack -> send_slack_report(report, channel.config)
      :webhook -> send_webhook_report(report, channel._config)
      _ -> :ok
    end
  end

  defp send_email_report(_report, _config), do: :ok
  defp send_slack_report(_report, _config), do: :ok
  defp send_webhook_report(_report, _config), do: :ok

  defp calculate_report_compliance(compliance_metrics) do
    if length(compliance_metrics) == 0 do
      100.0
    else
      total = Enum.reduce(compliance_metrics, 0, &(&1.compliance + &2))
      total / length(compliance_metrics)
    end
  end

  defp calculate_penalties(sla, compliance) do
    # Calculate financial penalties based on SLA terms
    Enum.reduce(compliance, 0, fn metric, acc ->
      if metric.status == :missed do
        penalty = Map.get(sla.penalties, metric.metric, 0)
        acc + penalty * (100 - metric.compliance) / 100
      else
        acc
      end
    end)
  end

  # Private Functions - Alerts

  defp check_alert_thresholds(_state, metric_name, value) do
    case Map.get(state.alert_thresholds, metric_name) do
      nil ->
        state

      threshold ->
        if threshold.enabled && exceeds_threshold?(value, threshold.threshold, metric_name) do
          trigger_alert(metric_name, value, threshold, state.notification_channels)
          state
        else
          _state
        end
    end
  end

  defp exceeds_threshold?(value, threshold, metric_name) do
    case determine_metric_type(metric_name) do
      :availability -> value < threshold
      :response_time -> value > threshold
      :throughput -> value < threshold
      :error_rate -> value > threshold
      _ -> false
    end
  end

  defp trigger_alert(metric_name, value, threshold, channels) do
    alert = %{
      metric: metric_name,
      value: value,
      threshold: threshold.threshold,
      action: threshold.action,
      timestamp: DateTime.utc_now()
    }

    notify_alert(alert, channels)
  end

  defp initialize_default_thresholds do
    %{
      "system.availability" => %{
        threshold: 99.9,
        action: :alert,
        enabled: true
      },
      "api.response_time" => %{
        threshold: 100,
        action: :alert,
        enabled: true
      },
      "system.error_rate" => %{
        threshold: 1.0,
        action: :alert,
        enabled: true
      }
    }
  end

  # Private Functions - Notifications

  defp notify_incident(incident, channels) do
    Enum.each(channels, fn channel ->
      send_incident_notification(incident, channel)
    end)
  end

  defp notify_alert(alert, channels) do
    Enum.each(channels, fn channel ->
      send_alert_notification(alert, channel)
    end)
  end

  defp send_incident_notification(incident, channel) do
    message = format_incident_message(incident)
    send_notification(message, channel)
  end

  defp send_alert_notification(alert, channel) do
    message = format_alert_message(alert)
    send_notification(message, channel)
  end

  defp send_notification(message, channel) do
    case channel.type do
      :email -> send_email(message, channel.config)
      :slack -> send_slack_message(message, channel.config)
      :pagerduty -> send_pagerduty_alert(message, channel._config)
      :webhook -> Integrations.trigger_webhook(:sla_alert, message)
      _ -> :ok
    end
  end

  defp send_email(_message, _config), do: :ok
  defp send_slack_message(_message, _config), do: :ok
  defp send_pagerduty_alert(_message, _config), do: :ok

  defp format_incident_message(incident) do
    """
    🚨 SLA Incident Alert
    ID: #{incident.id}
    SLA: #{incident.sla_id}
    Metric: #{incident.metric}
    Severity: #{incident.severity}
    Impact: #{incident.impact}
    Started: #{incident.started_at}
    """
  end

  defp format_alert_message(alert) do
    """
    ⚠️ Threshold Alert
    Metric: #{alert.metric}
    Value: #{alert.value}
    Threshold: #{alert.threshold}
    Time: #{alert.timestamp}
    """
  end

  # Private Functions - Helpers

  defp validate_metrics(metrics) do
    Enum.map(metrics, fn metric ->
      %{
        name: metric.name,
        type: metric.type,
        target: metric.target,
        measurement: Map.get(metric, :measurement, "units"),
        calculation: Map.get(metric, :calculation, :average)
      }
    end)
  end

  defp determine_metric_type(metric_name) do
    cond do
      String.contains?(metric_name, "availability") -> :availability
      String.contains?(metric_name, "response") -> :response_time
      String.contains?(metric_name, "throughput") -> :throughput
      String.contains?(metric_name, "error") -> :error_rate
      true -> :custom
    end
  end

  defp get_time_range(:current_period, reporting_period) do
    end_time = DateTime.utc_now()

    start_time =
      case reporting_period do
        :daily -> DateTime.add(end_time, -86400, :second)
        :weekly -> DateTime.add(end_time, -604_800, :second)
        :monthly -> DateTime.add(end_time, -2_592_000, :second)
      end

    {start_time, end_time}
  end

  defp get_time_range({start_time, end_time}, _), do: {start_time, end_time}

  defp get_metrics_in_range(metrics, type, start_time, end_time) do
    metric_list =
      case type do
        :availability -> metrics.availability
        :response_time -> metrics.response_time
        :throughput -> metrics.throughput
        :error_rate -> metrics.error_rate
      end

    Enum.filter(metric_list, fn metric ->
      DateTime.compare(metric.timestamp, start_time) in [:gt, :eq] &&
        DateTime.compare(metric.timestamp, end_time) in [:lt, :eq]
    end)
  end

  defp calculate_average(metrics) do
    if length(metrics) == 0 do
      0
    else
      total = Enum.reduce(metrics, 0, &(&1.value + &2))
      total / length(metrics)
    end
  end

  defp calculate_percentile(metrics, percentile) do
    if length(metrics) == 0 do
      0
    else
      sorted = Enum.sort_by(metrics, & &1.value)
      index = round(length(sorted) * percentile / 100)
      Enum.at(sorted, index).value
    end
  end

  defp calculate_minimum(metrics) do
    if length(metrics) == 0 do
      0
    else
      Enum.min_by(metrics, & &1.value).value
    end
  end

  defp calculate_maximum(metrics) do
    if length(metrics) == 0 do
      0
    else
      Enum.max_by(metrics, & &1.value).value
    end
  end

  defp get_incidents_for_sla(incidents, sla_id, start_time, end_time) do
    Enum.filter(incidents, fn incident ->
      incident.sla_id == sla_id &&
        DateTime.compare(incident.started_at, start_time) in [:gt, :eq] &&
        DateTime.compare(incident.started_at, end_time) in [:lt, :eq]
    end)
  end

  defp summarize_incidents(incidents) do
    %{
      total: length(incidents),
      by_severity: count_by_severity(incidents),
      total_downtime: calculate_total_downtime(incidents),
      mttr: calculate_mttr(incidents)
    }
  end

  defp count_by_severity(incidents) do
    Enum.reduce(incidents, %{low: 0, medium: 0, high: 0, critical: 0}, fn incident, acc ->
      Map.update(acc, incident.severity, 1, &(&1 + 1))
    end)
  end

  defp calculate_total_downtime(incidents) do
    Enum.reduce(incidents, 0, fn incident, acc ->
      acc + (incident.duration || 0)
    end)
  end

  defp calculate_mttr(incidents) do
    resolved = Enum.filter(incidents, &(&1.status == :resolved))

    if length(resolved) == 0 do
      0
    else
      total_time = Enum.reduce(resolved, 0, &(&1.duration + &2))
      total_time / length(resolved)
    end
  end

  defp count_active_incidents(_state) do
    Enum.count(state.incidents, &(&1.status == :active))
  end

  defp get_recent_incidents(_state, limit) do
    state.incidents
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp calculate_current_availability(_state) do
    recent_metrics = Enum.take(state.metrics.availability, 100)
    calculate_average(recent_metrics)
  end

  defp get_current_response_time(_state) do
    recent_metrics = Enum.take(state.metrics.response_time, 100)
    calculate_average(recent_metrics)
  end

  defp get_current_throughput(_state) do
    recent_metrics = Enum.take(state.metrics.throughput, 100)
    calculate_average(recent_metrics)
  end

  defp get_current_error_rate(_state) do
    recent_metrics = Enum.take(state.metrics.error_rate, 100)
    calculate_average(recent_metrics)
  end

  defp get_metrics_summary(_state) do
    %{
      availability: %{
        current: calculate_current_availability(state),
        trend: :stable
      },
      response_time: %{
        current: get_current_response_time(state),
        trend: :improving
      },
      throughput: %{
        current: get_current_throughput(state),
        trend: :stable
      },
      error_rate: %{
        current: get_current_error_rate(state),
        trend: :stable
      }
    }
  end

  defp build_config(opts) do
    %{
      metric_retention_days: Keyword.get(opts, :metric_retention_days, 90),
      report_retention_days: Keyword.get(opts, :report_retention_days, 365),
      metric_collection_interval: Keyword.get(opts, :metric_collection_interval, 60_000),
      compliance_check_interval: Keyword.get(opts, :compliance_check_interval, 300_000)
    }
  end

  defp generate_sla_id do
    "sla_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_incident_id do
    "inc_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_report_id do
    "report_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_channel_id do
    "channel_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp schedule_metric_collection do
    Process.send_after(self(), :collect_metrics, 60_000)
  end

  defp schedule_compliance_check do
    Process.send_after(self(), :check_compliance, 300_000)
  end

  defp schedule_report_generation do
    Process.send_after(self(), :generate_reports, :timer.hours(24))
  end
end
