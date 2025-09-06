defmodule Blockchain.Compliance.Supervisor do
  @moduledoc """
  Supervisor for all compliance-related processes.

  This supervisor coordinates the lifecycle of all compliance components:
  - Compliance Framework (policy management and validation)
  - Audit Engine (immutable audit trails)
  - Reporting System (automated compliance reports)
  - Data Retention (lifecycle management and archival)
  - Alerting System (violation detection and notifications)

  It handles startup order, dependencies, and graceful shutdown while ensuring
  compliance processes continue operating even during system stress.
  """

  use Supervisor
  require Logger

  alias Blockchain.Compliance.{Framework, AuditEngine, Reporting, DataRetention, Alerting}

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    compliance_config = get_compliance_config()

    # Only start compliance system if enabled
    if compliance_config.enabled do
      children = [
        # Audit Engine starts first - all other components depend on it
        {AuditEngine, [config: compliance_config.audit_engine]},

        # Framework manages policies and validation
        {Framework,
         [
           config: compliance_config.framework,
           enabled_standards: compliance_config.enabled_standards
         ]},

        # Data Retention manages lifecycle of compliance data
        {DataRetention, [config: compliance_config.data_retention]},

        # Reporting generates compliance reports
        {Reporting, [global_settings: compliance_config.reporting]},

        # Alerting monitors for violations (starts last)
        {Alerting, [notification_configs: compliance_config.alerting.notifications]}
      ]

      # Use :rest_for_one strategy so dependent services restart if audit engine fails
      opts = [strategy: :rest_for_one, name: __MODULE__]

      Logger.info("Starting Compliance Supervisor with #{length(children)} components")
      Supervisor.init(children, opts)
    else
      Logger.info("Compliance system disabled - not starting compliance processes")
      # Return empty supervisor
      Supervisor.init([], strategy: :one_for_one, name: __MODULE__)
    end
  end

  @doc """
  Get the current status of all compliance processes.
  """
  def status() do
    children = Supervisor.which_children(__MODULE__)

    status_map =
      Enum.into(children, %{}, fn {name, pid, type, modules} ->
        process_status =
          if is_pid(pid) and Process.alive?(pid) do
            :running
          else
            :not_running
          end

        {name,
         %{
           pid: pid,
           type: type,
           modules: modules,
           status: process_status
         }}
      end)

    overall_status =
      if Enum.all?(status_map, fn {_name, info} -> info.status == :running end) do
        :healthy
      else
        :degraded
      end

    %{
      overall_status: overall_status,
      processes: status_map,
      compliance_enabled: compliance_enabled?(),
      started_at: get_supervisor_start_time()
    }
  end

  @doc """
  Gracefully restart a specific compliance component.
  """
  def restart_component(component) do
    case Supervisor.restart_child(__MODULE__, component) do
      {:ok, _pid} ->
        Logger.info("Compliance component #{component} restarted successfully")
        :ok

      {:ok, _pid, _info} ->
        Logger.info("Compliance component #{component} restarted successfully")
        :ok

      {:error, reason} ->
        Logger.error("Failed to restart compliance component #{component}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get comprehensive compliance system health information.
  """
  def health_check() do
    base_status = status()

    # Get detailed health from each component if running
    detailed_health =
      if base_status.overall_status == :healthy do
        %{
          framework: get_component_health(:framework),
          audit_engine: get_component_health(:audit_engine),
          reporting: get_component_health(:reporting),
          data_retention: get_component_health(:data_retention),
          alerting: get_component_health(:alerting)
        }
      else
        %{}
      end

    Map.merge(base_status, %{
      component_health: detailed_health,
      last_health_check: DateTime.utc_now()
    })
  end

  @doc """
  Get compliance configuration status.
  """
  def config_status() do
    config = get_compliance_config()

    %{
      enabled: config.enabled,
      enabled_standards: config.enabled_standards,
      audit_engine_enabled: config.audit_engine.enabled,
      reporting_enabled: config.reporting.enabled,
      data_retention_enabled: config.data_retention.enabled,
      alerting_enabled: config.alerting.enabled,
      configuration_valid: validate_compliance_config(config)
    }
  end

  ## Private Implementation

  defp compliance_enabled?() do
    get_compliance_config().enabled
  end

  defp get_compliance_config() do
    # Get compliance configuration from application environment
    base_config = Application.get_env(:blockchain, :compliance, %{})

    # Provide comprehensive defaults
    default_config = %{
      enabled: false,
      enabled_standards: [:sox, :pci_dss, :fips_140_2],
      audit_engine: %{
        enabled: true,
        batch_size: 100,
        storage_backend: :crdt_distributed,
        encryption_enabled: true,
        integrity_check_interval: 3600_000
      },
      framework: %{
        enabled: true,
        assessment_interval: 3600_000,
        validation_enabled: true
      },
      reporting: %{
        enabled: true,
        output_directory: "/var/lib/mana/compliance/reports",
        temp_directory: "/tmp/mana_compliance",
        encryption_enabled: true,
        digital_signatures_enabled: true,
        # 7 years
        retention_default_days: 2555
      },
      data_retention: %{
        enabled: true,
        lifecycle_check_interval: 3600_000,
        archival_batch_size: 100,
        deletion_batch_size: 50
      },
      alerting: %{
        enabled: true,
        notifications: %{
          email: %{
            enabled: false,
            recipients: []
          },
          dashboard: %{
            enabled: true,
            severity_threshold: :info
          }
        }
      }
    }

    # Merge with defaults
    deep_merge(default_config, base_config)
  end

  defp get_component_health(component) do
    case component do
      :framework ->
        case Framework.get_compliance_status() do
          {:ok, status} -> %{status: :healthy, details: status}
          {:error, reason} -> %{status: :unhealthy, reason: reason}
        end

      :audit_engine ->
        case AuditEngine.get_statistics() do
          {:ok, stats} -> %{status: :healthy, stats: stats}
          {:error, reason} -> %{status: :unhealthy, reason: reason}
        end

      :reporting ->
        case Reporting.get_statistics() do
          {:ok, stats} -> %{status: :healthy, stats: stats}
          {:error, reason} -> %{status: :unhealthy, reason: reason}
        end

      :data_retention ->
        case DataRetention.get_retention_status() do
          {:ok, status} -> %{status: :healthy, details: status}
          {:error, reason} -> %{status: :unhealthy, reason: reason}
        end

      :alerting ->
        case Alerting.get_statistics() do
          {:ok, stats} -> %{status: :healthy, stats: stats}
          {:error, reason} -> %{status: :unhealthy, reason: reason}
        end

      _ ->
        %{status: :unknown, reason: "Unknown component"}
    end
  rescue
    error ->
      %{status: :error, error: inspect(error)}
  end

  defp validate_compliance_config(config) do
    # Basic configuration validation
    required_sections = [:audit_engine, :framework, :reporting, :data_retention, :alerting]

    missing_sections =
      Enum.filter(required_sections, fn section ->
        not Map.has_key?(config, section)
      end)

    validation_results = %{
      missing_sections: missing_sections,
      valid: Enum.empty?(missing_sections)
    }

    # Additional validation could be added here
    validation_results
  end

  defp get_supervisor_start_time() do
    # This is a simplified implementation - in production you'd track this
    DateTime.utc_now()
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, &deep_resolve/3)
  end

  defp deep_resolve(_key, left, right) when is_map(left) and is_map(right) do
    deep_merge(left, right)
  end

  defp deep_resolve(_key, _left, right) do
    right
  end
end
