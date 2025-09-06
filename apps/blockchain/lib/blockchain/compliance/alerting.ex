defmodule Blockchain.Compliance.Alerting do
  @moduledoc """
  Real-time compliance violation detection and alerting system.

  This module provides comprehensive monitoring and alerting for compliance
  violations across all regulatory frameworks. It integrates with the compliance
  framework, audit engine, and external notification systems to ensure immediate
  response to compliance issues.

  Alert Categories:
  - Control failures and deficiencies
  - Audit trail integrity violations
  - Data retention policy violations
  - Access control violations
  - Cryptographic security violations
  - Regulatory deadline violations
  - System availability violations
  - Data privacy violations

  Alert Channels:
  - Email notifications to compliance officers
  - SMS alerts for critical violations
  - Dashboard notifications
  - Slack/Teams integration
  - SIEM system integration
  - Ticketing system integration (ServiceNow, Jira)
  - Regulatory reporting (automated submissions)

  Features:
  - Real-time violation detection
  - Severity-based escalation
  - Alert deduplication and correlation
  - Automated remediation workflows
  - Compliance officer dashboards
  - Audit trail of all alerts
  - Integration with incident response
  - Regulatory notification requirements
  """

  use GenServer
  require Logger

  alias Blockchain.Compliance.{Framework, AuditEngine}

  @type alert_severity :: :info | :low | :medium | :high | :critical | :emergency
  @type alert_category ::
          :control_failure
          | :audit_integrity
          | :data_retention_violation
          | :access_violation
          | :crypto_violation
          | :regulatory_deadline
          | :system_availability
          | :data_privacy
          | :configuration_drift

  @type alert_channel ::
          :email | :sms | :dashboard | :slack | :teams | :siem | :ticket | :regulatory

  @type alert :: %{
          id: String.t(),
          severity: alert_severity(),
          category: alert_category(),
          title: String.t(),
          description: String.t(),
          details: map(),
          compliance_standards: [atom()],
          detected_at: DateTime.t(),
          acknowledged_at: DateTime.t() | nil,
          resolved_at: DateTime.t() | nil,
          assigned_to: String.t() | nil,
          escalated: boolean(),
          channels_notified: [alert_channel()],
          correlation_id: String.t() | nil,
          remediation_actions: [map()],
          metadata: map()
        }

  @type notification_config :: %{
          channel: alert_channel(),
          enabled: boolean(),
          severity_threshold: alert_severity(),
          recipients: [String.t()],
          template: String.t(),
          escalation_delay: non_neg_integer(),
          rate_limit: map(),
          authentication: map()
        }

  @type alerting_state :: %{
          active_alerts: %{String.t() => alert()},
          alert_history: [alert()],
          notification_configs: %{alert_channel() => notification_config()},
          violation_rules: %{String.t() => map()},
          escalation_policies: [map()],
          correlation_engine: map(),
          stats: map()
        }

  # Alert severity levels with escalation thresholds
  @severity_levels %{
    info: 0,
    low: 1,
    medium: 2,
    high: 3,
    critical: 4,
    emergency: 5
  }

  # Violation detection rules for different compliance standards
  @violation_rules %{
    "sox_control_failure" => %{
      description: "SOX internal control testing failure",
      category: :control_failure,
      severity: :high,
      compliance_standards: [:sox],
      detection_query: :check_sox_control_failures,
      remediation_actions: [
        %{action: "notify_cfo", priority: :immediate},
        %{action: "escalate_audit_committee", priority: :urgent},
        %{action: "document_deficiency", priority: :high}
      ]
    },
    "pci_data_exposure" => %{
      description: "Potential PCI cardholder data exposure",
      category: :data_privacy,
      severity: :critical,
      compliance_standards: [:pci_dss],
      detection_query: :check_pci_data_exposure,
      remediation_actions: [
        %{action: "isolate_affected_systems", priority: :immediate},
        %{action: "notify_acquiring_bank", priority: :urgent},
        %{action: "conduct_forensic_analysis", priority: :high}
      ]
    },
    "fips_crypto_failure" => %{
      description: "FIPS 140-2 cryptographic module failure",
      category: :crypto_violation,
      severity: :critical,
      compliance_standards: [:fips_140_2],
      detection_query: :check_fips_crypto_failures,
      remediation_actions: [
        %{action: "disable_affected_crypto_operations", priority: :immediate},
        %{action: "notify_security_team", priority: :urgent},
        %{action: "initiate_incident_response", priority: :high}
      ]
    },
    "gdpr_data_breach" => %{
      description: "GDPR personal data breach detected",
      category: :data_privacy,
      severity: :emergency,
      compliance_standards: [:gdpr],
      detection_query: :check_gdpr_data_breaches,
      remediation_actions: [
        %{action: "contain_breach", priority: :immediate},
        %{action: "notify_dpo", priority: :immediate},
        %{action: "prepare_72hour_notification", priority: :urgent}
      ]
    },
    "audit_trail_tampering" => %{
      description: "Audit trail integrity violation detected",
      category: :audit_integrity,
      severity: :emergency,
      compliance_standards: [:sox, :pci_dss, :gdpr],
      detection_query: :check_audit_integrity_violations,
      remediation_actions: [
        %{action: "secure_audit_systems", priority: :immediate},
        %{action: "notify_ciso", priority: :immediate},
        %{action: "initiate_forensic_investigation", priority: :urgent}
      ]
    }
  }

  # Default notification configurations
  @default_notification_configs %{
    email: %{
      channel: :email,
      enabled: true,
      severity_threshold: :medium,
      recipients: ["compliance@company.com", "ciso@company.com"],
      template: "compliance_alert_email",
      # 1 hour
      escalation_delay: 3600_000,
      rate_limit: %{max_per_hour: 10},
      authentication: %{}
    },
    sms: %{
      channel: :sms,
      enabled: true,
      severity_threshold: :critical,
      recipients: ["+1555COMPLIANCE", "+1555SECURITY"],
      template: "compliance_alert_sms",
      # 15 minutes
      escalation_delay: 900_000,
      rate_limit: %{max_per_hour: 5},
      authentication: %{}
    },
    dashboard: %{
      channel: :dashboard,
      enabled: true,
      severity_threshold: :info,
      recipients: ["all_compliance_users"],
      template: "compliance_alert_dashboard",
      escalation_delay: 0,
      rate_limit: %{max_per_hour: 100},
      authentication: %{}
    },
    slack: %{
      channel: :slack,
      enabled: false,
      severity_threshold: :medium,
      recipients: ["#compliance", "#security-alerts"],
      template: "compliance_alert_slack",
      # 30 minutes
      escalation_delay: 1800_000,
      rate_limit: %{max_per_hour: 20},
      authentication: %{webhook_url: nil}
    }
  }

  ## GenServer API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    notification_configs = Keyword.get(opts, :notification_configs, @default_notification_configs)

    state = %{
      active_alerts: %{},
      alert_history: [],
      notification_configs: notification_configs,
      violation_rules: @violation_rules,
      escalation_policies: [],
      correlation_engine: %{
        # 5 minutes
        correlation_window: 300_000,
        similarity_threshold: 0.8
      },
      stats: %{
        alerts_generated: 0,
        alerts_resolved: 0,
        false_positives: 0,
        average_resolution_time: 0,
        escalations_triggered: 0
      }
    }

    # Schedule periodic violation checks
    schedule_violation_check()

    # Schedule alert correlation and cleanup
    schedule_alert_maintenance()

    Logger.info("Compliance Alerting system initialized")
    {:ok, state}
  end

  def handle_call({:raise_alert, alert_params}, _from, state) do
    case create_and_process_alert(alert_params, state) do
      {:ok, alert, new_state} ->
        Logger.info("Compliance alert raised: #{alert.id} (#{alert.severity})")
        {:reply, {:ok, alert.id}, new_state}

      {:error, reason} ->
        Logger.error("Failed to raise compliance alert: #{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:acknowledge_alert, alert_id, acknowledger}, _from, state) do
    case Map.get(state.active_alerts, alert_id) do
      nil ->
        {:reply, {:error, "Alert not found: #{alert_id}"}, state}

      alert ->
        acknowledged_alert = %{
          alert
          | acknowledged_at: DateTime.utc_now(),
            assigned_to: acknowledger.user_id
        }

        new_active_alerts = Map.put(state.active_alerts, alert_id, acknowledged_alert)
        new_state = %{state | active_alerts: new_active_alerts}

        # Log acknowledgment
        AuditEngine.log_event(%{
          category: :administrative_action,
          action: "compliance_alert_acknowledged",
          actor: acknowledger,
          resource: %{alert_id: alert_id},
          details: %{
            alert_severity: alert.severity,
            alert_category: alert.category
          },
          compliance_tags: ["ALERT_MANAGEMENT"] ++ alert.compliance_standards
        })

        Logger.info("Compliance alert acknowledged: #{alert_id} by #{acknowledger.user_id}")
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:resolve_alert, alert_id, resolution_info}, _from, state) do
    case Map.get(state.active_alerts, alert_id) do
      nil ->
        {:reply, {:error, "Alert not found: #{alert_id}"}, state}

      alert ->
        resolved_alert = %{
          alert
          | resolved_at: DateTime.utc_now(),
            metadata: Map.put(alert.metadata, :resolution_info, resolution_info)
        }

        # Move to history and remove from active
        new_active_alerts = Map.delete(state.active_alerts, alert_id)
        new_alert_history = [resolved_alert | state.alert_history] |> Enum.take(1000)

        # Update statistics
        resolution_time =
          DateTime.diff(resolved_alert.resolved_at, resolved_alert.detected_at, :second)

        updated_stats = update_resolution_stats(state.stats, resolution_time)

        new_state = %{
          state
          | active_alerts: new_active_alerts,
            alert_history: new_alert_history,
            stats: updated_stats
        }

        # Log resolution
        AuditEngine.log_event(%{
          category: :administrative_action,
          action: "compliance_alert_resolved",
          resource: %{alert_id: alert_id},
          details: %{
            resolution_time_seconds: resolution_time,
            resolution_method: resolution_info.method
          },
          compliance_tags: ["ALERT_MANAGEMENT"] ++ alert.compliance_standards
        })

        Logger.info("Compliance alert resolved: #{alert_id} (#{resolution_time}s)")
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:get_alerts, filters}, _from, state) do
    filtered_alerts = filter_alerts(Map.values(state.active_alerts), filters)
    {:reply, {:ok, filtered_alerts}, state}
  end

  def handle_call({:configure_notifications, channel, config}, _from, state) do
    case validate_notification_config(config) do
      :ok ->
        new_configs = Map.put(state.notification_configs, channel, config)
        new_state = %{state | notification_configs: new_configs}

        Logger.info("Notification configuration updated for channel: #{channel}")
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_statistics, _from, state) do
    enhanced_stats =
      Map.merge(state.stats, %{
        active_alerts: map_size(state.active_alerts),
        critical_alerts: count_alerts_by_severity(state.active_alerts, :critical),
        unacknowledged_alerts: count_unacknowledged_alerts(state.active_alerts),
        notification_channels: map_size(state.notification_configs),
        violation_rules: map_size(state.violation_rules)
      })

    {:reply, {:ok, enhanced_stats}, state}
  end

  def handle_info(:check_violations, state) do
    Logger.debug("Performing compliance violation check")

    # Check each violation rule
    new_state =
      Enum.reduce(state.violation_rules, state, fn {rule_id, rule}, acc_state ->
        case execute_violation_check(rule) do
          {:violation, violation_details} ->
            Logger.warning("Compliance violation detected: #{rule_id}")

            alert_params = %{
              category: rule.category,
              severity: rule.severity,
              title: rule.description,
              description: "Automated violation detection: #{rule.description}",
              details: violation_details,
              compliance_standards: rule.compliance_standards,
              remediation_actions: rule.remediation_actions,
              metadata: %{
                rule_id: rule_id,
                automated_detection: true
              }
            }

            case create_and_process_alert(alert_params, acc_state) do
              {:ok, _alert, updated_state} ->
                updated_state

              {:error, reason} ->
                Logger.error("Failed to create alert for violation #{rule_id}: #{reason}")
                acc_state
            end

          :no_violation ->
            acc_state

          {:error, reason} ->
            Logger.error("Violation check failed for #{rule_id}: #{reason}")
            acc_state
        end
      end)

    # Schedule next check
    schedule_violation_check()

    {:noreply, new_state}
  end

  def handle_info(:alert_maintenance, state) do
    Logger.debug("Performing alert correlation and maintenance")

    # Correlate related alerts
    correlated_state = correlate_alerts(state)

    # Check for escalations
    escalated_state = check_escalations(correlated_state)

    # Clean up old resolved alerts
    cleaned_state = cleanup_old_alerts(escalated_state)

    # Schedule next maintenance
    schedule_alert_maintenance()

    {:noreply, cleaned_state}
  end

  ## Public API

  @doc """
  Raise a compliance alert manually or from external systems.
  """
  @spec raise_alert(map()) :: {:ok, String.t()} | {:error, String.t()}
  def raise_alert(alert_params) do
    GenServer.call(__MODULE__, {:raise_alert, alert_params})
  end

  @doc """
  Acknowledge an active alert.
  """
  @spec acknowledge_alert(String.t(), map()) :: :ok | {:error, String.t()}
  def acknowledge_alert(alert_id, acknowledger) do
    GenServer.call(__MODULE__, {:acknowledge_alert, alert_id, acknowledger})
  end

  @doc """
  Resolve an alert with resolution information.
  """
  @spec resolve_alert(String.t(), map()) :: :ok | {:error, String.t()}
  def resolve_alert(alert_id, resolution_info) do
    GenServer.call(__MODULE__, {:resolve_alert, alert_id, resolution_info})
  end

  @doc """
  Get active alerts with optional filtering.
  """
  @spec get_alerts(map()) :: {:ok, [alert()]}
  def get_alerts(filters \\ %{}) do
    GenServer.call(__MODULE__, {:get_alerts, filters})
  end

  @doc """
  Configure notification settings for a channel.
  """
  @spec configure_notifications(alert_channel(), notification_config()) ::
          :ok | {:error, String.t()}
  def configure_notifications(channel, config) do
    GenServer.call(__MODULE__, {:configure_notifications, channel, config})
  end

  @doc """
  Get alerting system statistics.
  """
  @spec get_statistics() :: {:ok, map()}
  def get_statistics() do
    GenServer.call(__MODULE__, :get_statistics)
  end

  ## Convenience functions for common alerts

  @doc """
  Raise SOX internal control failure alert.
  """
  @spec alert_sox_control_failure(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def alert_sox_control_failure(control_id, details) do
    raise_alert(%{
      category: :control_failure,
      severity: :high,
      title: "SOX Internal Control Failure",
      description: "Control #{control_id} has failed testing requirements",
      details: details,
      compliance_standards: [:sox]
    })
  end

  @doc """
  Raise PCI-DSS data exposure alert.
  """
  @spec alert_pci_data_exposure(map()) :: {:ok, String.t()} | {:error, String.t()}
  def alert_pci_data_exposure(details) do
    raise_alert(%{
      category: :data_privacy,
      severity: :critical,
      title: "PCI Cardholder Data Exposure",
      description: "Potential exposure of cardholder data detected",
      details: details,
      compliance_standards: [:pci_dss]
    })
  end

  @doc """
  Raise GDPR data breach alert.
  """
  @spec alert_gdpr_breach(map()) :: {:ok, String.t()} | {:error, String.t()}
  def alert_gdpr_breach(details) do
    raise_alert(%{
      category: :data_privacy,
      severity: :emergency,
      title: "GDPR Personal Data Breach",
      description: "Personal data breach requiring 72-hour notification",
      details: details,
      compliance_standards: [:gdpr]
    })
  end

  @doc """
  Raise audit trail integrity violation alert.
  """
  @spec alert_audit_integrity_violation(map()) :: {:ok, String.t()} | {:error, String.t()}
  def alert_audit_integrity_violation(details) do
    raise_alert(%{
      category: :audit_integrity,
      severity: :emergency,
      title: "Audit Trail Integrity Violation",
      description: "Audit trail tampering or corruption detected",
      details: details,
      compliance_standards: [:sox, :pci_dss, :gdpr]
    })
  end

  ## Private Implementation

  defp create_and_process_alert(alert_params, state) do
    try do
      # Generate unique alert ID
      alert_id = generate_alert_id()

      # Create alert structure
      alert = %{
        id: alert_id,
        severity: Map.get(alert_params, :severity, :medium),
        category: Map.get(alert_params, :category, :configuration_drift),
        title: Map.get(alert_params, :title, "Compliance Alert"),
        description: Map.get(alert_params, :description, ""),
        details: Map.get(alert_params, :details, %{}),
        compliance_standards: Map.get(alert_params, :compliance_standards, []),
        detected_at: DateTime.utc_now(),
        acknowledged_at: nil,
        resolved_at: nil,
        assigned_to: nil,
        escalated: false,
        channels_notified: [],
        correlation_id: generate_correlation_id(alert_params),
        remediation_actions: Map.get(alert_params, :remediation_actions, []),
        metadata: Map.get(alert_params, :metadata, %{})
      }

      # Check for duplicates and correlation
      case find_duplicate_or_correlated_alert(alert, state.active_alerts) do
        nil ->
          # New unique alert - process normally
          process_new_alert(alert, state)

        correlated_alert_id ->
          # Update existing correlated alert
          process_correlated_alert(alert, correlated_alert_id, state)
      end
    rescue
      error ->
        {:error, "Failed to create alert: #{inspect(error)}"}
    end
  end

  defp process_new_alert(alert, state) do
    # Add to active alerts
    new_active_alerts = Map.put(state.active_alerts, alert.id, alert)

    # Send notifications
    {notification_results, notified_channels} =
      send_notifications(alert, state.notification_configs)

    # Update alert with notification results
    updated_alert = %{alert | channels_notified: notified_channels}
    final_active_alerts = Map.put(new_active_alerts, alert.id, updated_alert)

    # Update statistics
    updated_stats = Map.update(state.stats, :alerts_generated, 1, &(&1 + 1))

    # Log alert creation
    AuditEngine.log_event(%{
      category: :compliance_violation,
      action: "compliance_alert_raised",
      resource: %{alert_id: alert.id},
      details: %{
        severity: alert.severity,
        category: alert.category,
        compliance_standards: alert.compliance_standards,
        channels_notified: notified_channels
      },
      compliance_tags: ["ALERT_RAISED"] ++ alert.compliance_standards
    })

    new_state = %{
      state
      | active_alerts: final_active_alerts,
        stats: updated_stats
    }

    # Log notification results
    if Enum.any?(notification_results, fn {_, result} -> match?({:error, _}, result) end) do
      Logger.warning(
        "Some notifications failed for alert #{alert.id}: #{inspect(notification_results)}"
      )
    end

    {:ok, updated_alert, new_state}
  end

  defp process_correlated_alert(alert, correlated_alert_id, state) do
    # Update existing alert with new information
    existing_alert = Map.get(state.active_alerts, correlated_alert_id)

    # Merge details and increase severity if needed
    merged_details = Map.merge(existing_alert.details, alert.details)
    new_severity = escalate_severity(existing_alert.severity, alert.severity)

    updated_alert = %{
      existing_alert
      | details: merged_details,
        severity: new_severity,
        metadata:
          Map.put(
            existing_alert.metadata,
            :correlation_count,
            Map.get(existing_alert.metadata, :correlation_count, 1) + 1
          )
    }

    new_active_alerts = Map.put(state.active_alerts, correlated_alert_id, updated_alert)
    new_state = %{state | active_alerts: new_active_alerts}

    Logger.info("Alert correlated with existing alert: #{correlated_alert_id}")

    {:ok, updated_alert, new_state}
  end

  defp send_notifications(alert, notification_configs) do
    notification_results =
      Enum.map(notification_configs, fn {channel, config} ->
        if should_notify?(alert, config) do
          case send_notification(alert, channel, config) do
            :ok -> {channel, :ok}
            {:error, reason} -> {channel, {:error, reason}}
          end
        else
          {channel, :skipped}
        end
      end)

    # Extract successfully notified channels
    notified_channels =
      notification_results
      |> Enum.filter(fn {_, result} -> result == :ok end)
      |> Enum.map(fn {channel, _} -> channel end)

    {notification_results, notified_channels}
  end

  defp should_notify?(alert, config) do
    config.enabled and
      severity_meets_threshold?(alert.severity, config.severity_threshold) and
      within_rate_limit?(config)
  end

  defp send_notification(alert, channel, config) do
    case channel do
      :email -> send_email_notification(alert, config)
      :sms -> send_sms_notification(alert, config)
      :dashboard -> send_dashboard_notification(alert, config)
      :slack -> send_slack_notification(alert, config)
      :teams -> send_teams_notification(alert, config)
      :siem -> send_siem_notification(alert, config)
      :ticket -> create_ticket(alert, config)
      :regulatory -> send_regulatory_notification(alert, config)
      _ -> {:error, "Unknown notification channel: #{channel}"}
    end
  end

  defp send_email_notification(alert, config) do
    # Email notification implementation
    Logger.info(
      "Sending email notification for alert #{alert.id} to #{inspect(config.recipients)}"
    )

    _subject = "[#{String.upcase(to_string(alert.severity))}] #{alert.title}"
    _body = format_alert_for_email(alert)

    # Simulate email sending - in production would use actual email service
    :ok
  end

  defp send_sms_notification(alert, config) do
    # SMS notification implementation  
    Logger.info("Sending SMS notification for alert #{alert.id} to #{inspect(config.recipients)}")

    _message = format_alert_for_sms(alert)

    # Simulate SMS sending - in production would use SMS service
    :ok
  end

  defp send_dashboard_notification(alert, _config) do
    # Dashboard notification implementation
    Logger.info("Sending dashboard notification for alert #{alert.id}")

    # In production, would update dashboard state or send websocket message
    :ok
  end

  defp send_slack_notification(alert, config) do
    # Slack notification implementation
    if config.authentication.webhook_url do
      Logger.info("Sending Slack notification for alert #{alert.id}")

      # Format message for Slack
      _message = format_alert_for_slack(alert)

      # Simulate Slack webhook call
      :ok
    else
      {:error, "Slack webhook URL not configured"}
    end
  end

  defp send_teams_notification(alert, _config) do
    # Microsoft Teams notification implementation
    Logger.info("Sending Teams notification for alert #{alert.id}")
    :ok
  end

  defp send_siem_notification(alert, _config) do
    # SIEM integration
    Logger.info("Sending SIEM event for alert #{alert.id}")

    # Format as structured log event for SIEM ingestion
    siem_event = %{
      timestamp: alert.detected_at,
      event_type: "compliance_alert",
      severity: alert.severity,
      category: alert.category,
      alert_id: alert.id,
      compliance_standards: alert.compliance_standards,
      details: alert.details
    }

    Logger.info("SIEM_EVENT: #{Jason.encode!(siem_event)}")
    :ok
  end

  defp create_ticket(alert, _config) do
    # Ticketing system integration (ServiceNow, Jira, etc.)
    Logger.info("Creating ticket for alert #{alert.id}")

    _ticket_data = %{
      title: "[Compliance] #{alert.title}",
      description: alert.description,
      severity: map_severity_to_ticket_priority(alert.severity),
      category: "Compliance Violation",
      details: alert.details,
      compliance_standards: alert.compliance_standards
    }

    # Simulate ticket creation
    :ok
  end

  defp send_regulatory_notification(alert, _config) do
    # Regulatory notification for specific violations (e.g., GDPR 72-hour breach notification)
    if requires_regulatory_notification?(alert) do
      Logger.warning("Regulatory notification required for alert #{alert.id}")

      # In production, would format and submit to regulatory systems
      :ok
    else
      :ok
    end
  end

  # Violation detection implementations

  defp execute_violation_check(rule) do
    try do
      case rule.detection_query do
        atom when is_atom(atom) ->
          apply(__MODULE__, atom, [])

        func when is_function(func) ->
          func.()

        _ ->
          {:error, "Invalid detection_query type"}
      end
    rescue
      error ->
        {:error, "Violation check failed: #{inspect(error)}"}
    catch
      _, error ->
        {:error, "Violation check failed: #{inspect(error)}"}
    end
  end

  @doc """
  Run all compliance checks and return any violations found.
  This function is typically called by scheduled monitoring jobs.
  """
  def run_compliance_checks do
    checks = [
      {:sox, &check_sox_control_failures/0},
      {:pci, &check_pci_data_exposure/0},
      {:gdpr, &check_gdpr_data_breaches/0},
      {:fips, &check_fips_crypto_failures/0},
      {:audit, &check_audit_integrity_violations/0},
      {:segregation, &check_segregation_of_duties/0},
      {:access, &check_privileged_access_review/0},
      {:logs, &check_log_completeness/0},
      {:key_rotation, &check_key_rotation_schedule/0},
      {:hsm, &check_hsm_key_storage/0},
      {:comprehensive, &check_comprehensive_logging/0}
    ]

    Enum.reduce(checks, %{violations: [], passed: []}, fn {name, check_fn}, acc ->
      case check_fn.() do
        :no_violation ->
          %{acc | passed: [name | acc.passed]}

        {:violation, details} ->
          %{acc | violations: [{name, details} | acc.violations]}
      end
    end)
  end

  defp check_sox_control_failures() do
    # Check SOX internal control compliance
    case Framework.get_violations(%{standard: :sox}) do
      {:ok, violations} when violations != [] ->
        {:violation, %{sox_violations: violations, violation_count: length(violations)}}

      {:ok, []} ->
        :no_violation

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> :no_violation
  end

  defp check_pci_data_exposure() do
    # Check for PCI cardholder data exposure indicators
    # This would integrate with data loss prevention and monitoring systems
    :no_violation
  end

  defp check_fips_crypto_failures() do
    # Check FIPS 140-2 cryptographic module status
    case Application.get_env(:exth_crypto, :hsm, %{}) do
      %{enabled: true} ->
        # Check HSM health
        case ExthCrypto.HSM.Monitor.get_health_status() do
          {:ok, %{overall_status: :unhealthy}} ->
            {:violation, %{hsm_status: :unhealthy, issue: "HSM module failure"}}

          {:ok, %{overall_status: :critical}} ->
            {:violation, %{hsm_status: :critical, issue: "Critical HSM failure"}}

          {:ok, _} ->
            :no_violation

          {:error, reason} ->
            {:violation, %{hsm_status: :error, issue: reason}}
        end

      _ ->
        :no_violation
    end
  end

  defp check_gdpr_data_breaches() do
    # Check for GDPR data breach indicators
    # This would integrate with data monitoring and incident detection systems
    :no_violation
  end

  defp check_audit_integrity_violations() do
    # Check audit trail integrity
    case AuditEngine.verify_integrity(%{full_chain: false}) do
      {:ok, %{integrity_verified: false, violations: violations}} ->
        {:violation, %{integrity_violations: violations}}

      {:ok, %{integrity_verified: true}} ->
        :no_violation

      {:error, reason} ->
        {:violation, %{integrity_check_failed: reason}}
    end
  end

  defp check_segregation_of_duties() do
    # Check if critical operations have proper segregation
    case Framework.get_violations(%{standard: :sox, control: :segregation_of_duties}) do
      {:ok, violations} when violations != [] ->
        {:violation, %{segregation_violations: violations}}

      _ ->
        :no_violation
    end
  end

  defp check_privileged_access_review() do
    # Check if privileged access is being properly reviewed
    case Framework.get_violations(%{standard: :sox, control: :privileged_access}) do
      {:ok, violations} when violations != [] ->
        {:violation, %{access_review_violations: violations}}

      _ ->
        :no_violation
    end
  end

  defp check_log_completeness() do
    # Check if logging is complete and unmodified
    case AuditEngine.verify_log_integrity() do
      {:ok, :verified} ->
        :no_violation

      {:error, reason} ->
        {:violation, %{log_integrity_issue: reason}}

      _ ->
        :no_violation
    end
  end

  defp check_key_rotation_schedule() do
    # Check if cryptographic keys are rotated on schedule
    # In production, this would check actual key rotation dates
    :no_violation
  end

  defp check_hsm_key_storage() do
    # Check if sensitive keys are properly stored in HSM
    # In production, this would verify HSM usage for critical keys
    :no_violation
  end

  defp check_comprehensive_logging() do
    # Check if all required events are being logged
    case AuditEngine.check_logging_completeness() do
      {:ok, :complete} ->
        :no_violation

      {:ok, {:missing, events}} ->
        {:violation, %{missing_logs: events}}

      _ ->
        :no_violation
    end
  end

  # Helper functions

  defp find_duplicate_or_correlated_alert(new_alert, active_alerts) do
    # Simple correlation based on category and timeframe
    # 5 minutes
    correlation_window = 300_000
    cutoff_time = DateTime.add(DateTime.utc_now(), -correlation_window, :millisecond)

    Enum.find_value(active_alerts, fn {alert_id, existing_alert} ->
      if existing_alert.category == new_alert.category and
           DateTime.compare(existing_alert.detected_at, cutoff_time) == :gt do
        alert_id
      else
        nil
      end
    end)
  end

  defp generate_correlation_id(alert_params) do
    # Generate correlation ID based on alert characteristics
    correlation_data = "#{alert_params[:category]}_#{alert_params[:severity]}"

    correlation_data
    |> :crypto.hash(:md5)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end

  defp escalate_severity(current_severity, new_severity) do
    current_level = Map.get(@severity_levels, current_severity, 0)
    new_level = Map.get(@severity_levels, new_severity, 0)

    if new_level > current_level do
      new_severity
    else
      current_severity
    end
  end

  defp severity_meets_threshold?(alert_severity, threshold_severity) do
    alert_level = Map.get(@severity_levels, alert_severity, 0)
    threshold_level = Map.get(@severity_levels, threshold_severity, 0)

    alert_level >= threshold_level
  end

  defp within_rate_limit?(_config) do
    # Simple rate limiting - in production would use more sophisticated logic
    true
  end

  defp correlate_alerts(state) do
    # Correlation logic would be more sophisticated in production
    state
  end

  defp check_escalations(state) do
    # Check for alerts that need escalation
    state
  end

  defp cleanup_old_alerts(state) do
    # Keep only last 1000 resolved alerts
    cleaned_history = Enum.take(state.alert_history, 1000)
    %{state | alert_history: cleaned_history}
  end

  defp format_alert_for_email(alert) do
    """
    Compliance Alert: #{alert.title}

    Severity: #{String.upcase(to_string(alert.severity))}
    Category: #{alert.category}
    Detected: #{alert.detected_at}

    Description:
    #{alert.description}

    Compliance Standards:
    #{Enum.join(alert.compliance_standards, ", ")}

    Details:
    #{inspect(alert.details, pretty: true)}

    Alert ID: #{alert.id}
    """
  end

  defp format_alert_for_sms(alert) do
    "COMPLIANCE ALERT [#{String.upcase(to_string(alert.severity))}]: #{alert.title}. Alert ID: #{alert.id}"
  end

  defp format_alert_for_slack(alert) do
    severity_emoji =
      case alert.severity do
        :emergency -> "🚨"
        :critical -> "🔴"
        :high -> "🟠"
        :medium -> "🟡"
        :low -> "🔵"
        :info -> "ℹ️"
      end

    "#{severity_emoji} *#{alert.title}*\n" <>
      "Severity: #{alert.severity}\n" <>
      "Category: #{alert.category}\n" <>
      "Standards: #{Enum.join(alert.compliance_standards, ", ")}\n" <>
      "Alert ID: `#{alert.id}`"
  end

  defp map_severity_to_ticket_priority(severity) do
    case severity do
      :emergency -> "Critical"
      :critical -> "High"
      :high -> "Medium"
      :medium -> "Low"
      :low -> "Low"
      :info -> "Low"
    end
  end

  defp requires_regulatory_notification?(alert) do
    # Check if alert requires immediate regulatory notification
    alert.severity in [:emergency, :critical] and
      :gdpr in alert.compliance_standards
  end

  defp filter_alerts(alerts, filters) when map_size(filters) == 0, do: alerts

  defp filter_alerts(alerts, filters) do
    Enum.filter(alerts, fn alert ->
      Enum.all?(filters, fn {key, value} ->
        Map.get(alert, key) == value
      end)
    end)
  end

  defp count_alerts_by_severity(active_alerts, severity) do
    active_alerts
    |> Map.values()
    |> Enum.count(fn alert -> alert.severity == severity end)
  end

  defp count_unacknowledged_alerts(active_alerts) do
    active_alerts
    |> Map.values()
    |> Enum.count(fn alert -> is_nil(alert.acknowledged_at) end)
  end

  defp update_resolution_stats(stats, resolution_time_seconds) do
    current_count = Map.get(stats, :alerts_resolved, 0)
    current_avg = Map.get(stats, :average_resolution_time, 0)

    new_avg =
      if current_count == 0 do
        resolution_time_seconds
      else
        (current_avg * current_count + resolution_time_seconds) / (current_count + 1)
      end

    %{
      stats
      | alerts_resolved: current_count + 1,
        average_resolution_time: new_avg
    }
  end

  defp validate_notification_config(config) do
    required_fields = [:channel, :enabled, :severity_threshold, :recipients]

    missing_fields =
      Enum.filter(required_fields, fn field ->
        not Map.has_key?(config, field)
      end)

    if Enum.empty?(missing_fields) do
      :ok
    else
      {:error, "Missing required fields: #{inspect(missing_fields)}"}
    end
  end

  defp generate_alert_id() do
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "alert_#{timestamp}_#{random}"
  end

  defp schedule_violation_check() do
    # Check every 5 minutes for violations
    Process.send_after(self(), :check_violations, 300_000)
  end

  defp schedule_alert_maintenance() do
    # Maintenance every 10 minutes
    Process.send_after(self(), :alert_maintenance, 600_000)
  end
end
