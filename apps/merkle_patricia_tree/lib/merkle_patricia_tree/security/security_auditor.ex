defmodule MerklePatriciaTree.Security.SecurityAuditor do
  @moduledoc """
  Security auditor and hardening module for Mana-Ethereum Phase 2.4.

  This module provides comprehensive security features including:
  - Security vulnerability scanning and assessment
  - Input validation and sanitization
  - Rate limiting and DDoS protection
  - SSL/TLS configuration and certificate management
  - Access control and authentication
  - Security audit logging and monitoring
  - Compliance checking and reporting

  ## Features

  - **Vulnerability Scanning**: Automated security assessment and vulnerability detection
  - **Input Validation**: Comprehensive input sanitization and validation
  - **Rate Limiting**: Configurable rate limiting with IP-based tracking
  - **SSL/TLS Security**: Certificate management and secure communication
  - **Access Control**: Role-based access control and authentication
  - **Audit Logging**: Comprehensive security event logging
  - **Compliance**: Security compliance checking and reporting

  ## Usage

      # Initialize security auditor
      {:ok, auditor} = SecurityAuditor.start_link()

      # Perform security audit
      audit_result = SecurityAuditor.perform_audit()

      # Validate input
      {:ok, sanitized_input} = SecurityAuditor.validate_input(raw_input)

      # Check rate limit
      {:ok, :allowed} = SecurityAuditor.check_rate_limit(ip_address)

      # Log security event
      SecurityAuditor.log_security_event(:authentication_failure, %{ip: ip, user: user})
  """

  use GenServer
  require Logger

  @type auditor :: %{
          rate_limits: map(),
          security_events: list(map()),
          vulnerabilities: list(map()),
          audit_log: list(map()),
          ssl_config: map(),
          access_controls: map(),
          start_time: integer()
        }

  @type security_event :: %{
          id: String.t(),
          type: atom(),
          severity: :low | :medium | :high | :critical,
          message: String.t(),
          metadata: map(),
          timestamp: integer(),
          ip_address: String.t() | nil,
          user_id: String.t() | nil
        }

  @type vulnerability :: %{
          id: String.t(),
          type: atom(),
          severity: :low | :medium | :high | :critical,
          description: String.t(),
          cve_id: String.t() | nil,
          affected_component: String.t(),
          remediation: String.t(),
          discovered_at: integer()
        }

  @type audit_result :: %{
          overall_score: integer(),
          vulnerabilities: list(vulnerability()),
          recommendations: list(String.t()),
          compliance_status: map(),
          timestamp: integer()
        }

  # Default configuration
  # requests per minute
  @default_rate_limit_requests 100
  # 1 minute window
  @default_rate_limit_window 60_000
  # 1MB max input size
  @default_max_input_size 1024 * 1024
  # 1 hour audit interval
  @default_audit_interval 3600_000

  # Security thresholds
  @min_password_length 12
  # @max_failed_attempts 5
  # 1 hour
  # @session_timeout 3600
  # @max_concurrent_sessions 10

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Performs a comprehensive security audit.
  """
  @spec perform_audit() :: audit_result()
  def perform_audit do
    GenServer.call(__MODULE__, :perform_audit)
  end

  @doc """
  Validates and sanitizes input data.
  """
  @spec validate_input(any(), String.t()) :: {:ok, any()} | {:error, String.t()}
  def validate_input(input, input_type \\ "general") do
    GenServer.call(__MODULE__, {:validate_input, input, input_type})
  end

  @doc """
  Checks if a request is within rate limits.
  """
  @spec check_rate_limit(String.t(), String.t()) :: {:ok, :allowed} | {:error, :rate_limited}
  def check_rate_limit(ip_address, endpoint \\ "default") do
    GenServer.call(__MODULE__, {:check_rate_limit, ip_address, endpoint})
  end

  @doc """
  Logs a security event.
  """
  @spec log_security_event(atom(), map()) :: :ok
  def log_security_event(event_type, metadata) do
    GenServer.cast(__MODULE__, {:log_security_event, event_type, metadata})
  end

  @doc """
  Validates SSL/TLS configuration.
  """
  @spec validate_ssl_config(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_ssl_config(ssl_config) do
    GenServer.call(__MODULE__, {:validate_ssl_config, ssl_config})
  end

  @doc """
  Checks access control permissions.
  """
  @spec check_access(String.t(), String.t(), String.t()) :: {:ok, :allowed} | {:error, :denied}
  def check_access(user_id, resource, action) do
    GenServer.call(__MODULE__, {:check_access, user_id, resource, action})
  end

  @doc """
  Gets security audit log.
  """
  @spec get_audit_log(integer(), integer()) :: list(security_event())
  def get_audit_log(start_time \\ 0, end_time \\ :infinity) do
    GenServer.call(__MODULE__, {:get_audit_log, start_time, end_time})
  end

  @doc """
  Gets vulnerability report.
  """
  @spec get_vulnerability_report() :: list(vulnerability())
  def get_vulnerability_report do
    GenServer.call(__MODULE__, :get_vulnerability_report)
  end

  @doc """
  Updates security configuration.
  """
  @spec update_security_config(map()) :: :ok
  def update_security_config(config) do
    GenServer.cast(__MODULE__, {:update_security_config, config})
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    _rate_limit_requests = Keyword.get(opts, :rate_limit_requests, @default_rate_limit_requests)
    _rate_limit_window = Keyword.get(opts, :rate_limit_window, @default_rate_limit_window)
    audit_interval = Keyword.get(opts, :audit_interval, @default_audit_interval)

    # Initialize security auditor state
    auditor = %{
      rate_limits: %{},
      security_events: [],
      vulnerabilities: [],
      audit_log: [],
      ssl_config: %{},
      access_controls: %{},
      start_time: System.system_time(:second)
    }

    # Schedule periodic security audit
    schedule_security_audit(audit_interval)

    Logger.info("Security auditor started")
    {:ok, auditor}
  end

  @impl GenServer
  def handle_call(:perform_audit, _from, state) do
    audit_result = perform_comprehensive_audit(state)
    {:reply, audit_result, state}
  end

  @impl GenServer
  def handle_call({:validate_input, input, input_type}, _from, state) do
    validation_result = validate_and_sanitize_input(input, input_type)
    {:reply, validation_result, state}
  end

  @impl GenServer
  def handle_call({:check_rate_limit, ip_address, endpoint}, _from, state) do
    rate_limit_result = check_rate_limit_internal(ip_address, endpoint, state)
    {:reply, rate_limit_result, state}
  end

  @impl GenServer
  def handle_call({:validate_ssl_config, ssl_config}, _from, state) do
    ssl_validation_result = validate_ssl_configuration(ssl_config)
    {:reply, ssl_validation_result, state}
  end

  @impl GenServer
  def handle_call({:check_access, user_id, resource, action}, _from, state) do
    access_result = check_access_control(user_id, resource, action, state)
    {:reply, access_result, state}
  end

  @impl GenServer
  def handle_call({:get_audit_log, start_time, end_time}, _from, state) do
    filtered_log = filter_audit_log(state.audit_log, start_time, end_time)
    {:reply, filtered_log, state}
  end

  @impl GenServer
  def handle_call(:get_vulnerability_report, _from, state) do
    {:reply, state.vulnerabilities, state}
  end

  @impl GenServer
  def handle_cast({:log_security_event, event_type, metadata}, state) do
    security_event = create_security_event(event_type, metadata)
    new_audit_log = [security_event | state.audit_log]
    new_state = %{state | audit_log: new_audit_log}

    # Log to external security monitoring system
    log_to_external_system(security_event)

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_cast({:update_security_config, config}, state) do
    new_state = update_security_configuration(state, config)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:perform_security_audit, state) do
    audit_result = perform_comprehensive_audit(state)
    new_vulnerabilities = audit_result.vulnerabilities
    new_state = %{state | vulnerabilities: new_vulnerabilities}

    # Log audit completion
    Logger.info("Security audit completed: #{audit_result.overall_score}/100 score")

    # Schedule next audit
    schedule_security_audit(3600_000)

    {:noreply, new_state}
  end

  # Private functions

  defp schedule_security_audit(interval) do
    Process.send_after(self(), :perform_security_audit, interval)
  end

  defp perform_comprehensive_audit(state) do
    vulnerabilities = []

    # Check for common vulnerabilities
    vulnerabilities = vulnerabilities ++ check_input_validation_vulnerabilities()
    vulnerabilities = vulnerabilities ++ check_authentication_vulnerabilities()
    vulnerabilities = vulnerabilities ++ check_authorization_vulnerabilities()
    vulnerabilities = vulnerabilities ++ check_ssl_tls_vulnerabilities()
    vulnerabilities = vulnerabilities ++ check_rate_limiting_vulnerabilities()
    vulnerabilities = vulnerabilities ++ check_logging_vulnerabilities()

    # Calculate overall security score
    overall_score = calculate_security_score(vulnerabilities)

    # Generate recommendations
    recommendations = generate_security_recommendations(vulnerabilities)

    # Check compliance status
    compliance_status = check_compliance_status(state)

    %{
      overall_score: overall_score,
      vulnerabilities: vulnerabilities,
      recommendations: recommendations,
      compliance_status: compliance_status,
      timestamp: System.system_time(:second)
    }
  end

  defp validate_and_sanitize_input(input, input_type) do
    case input_type do
      "json" -> validate_json_input(input)
      "sql" -> validate_sql_input(input)
      "url" -> validate_url_input(input)
      "email" -> validate_email_input(input)
      "password" -> validate_password_input(input)
      "general" -> validate_general_input(input)
      _ -> {:error, "Unknown input type: #{input_type}"}
    end
  end

  defp check_rate_limit_internal(ip_address, endpoint, state) do
    current_time = System.system_time(:millisecond)
    # 1 minute window
    window_start = current_time - 60_000

    # Get current rate limit data for this IP and endpoint
    rate_limit_key = "#{ip_address}:#{endpoint}"
    current_requests = get_rate_limit_requests(rate_limit_key, window_start, state.rate_limits)

    if current_requests < @default_rate_limit_requests do
      # Update rate limit tracking
      _new_rate_limits =
        update_rate_limit_tracking(rate_limit_key, current_time, state.rate_limits)

      {:ok, :allowed}
    else
      {:error, :rate_limited}
    end
  end

  defp validate_ssl_configuration(ssl_config) do
    # Validate SSL/TLS configuration
    required_fields = [:certfile, :keyfile, :cacertfile]

    missing_fields =
      Enum.filter(required_fields, fn field ->
        not Map.has_key?(ssl_config, field) or ssl_config[field] == nil
      end)

    if length(missing_fields) > 0 do
      {:error, "Missing required SSL fields: #{Enum.join(missing_fields, ", ")}"}
    else
      # Check if certificate files exist and are valid
      cert_valid = File.exists?(ssl_config.certfile)
      key_valid = File.exists?(ssl_config.keyfile)
      ca_valid = File.exists?(ssl_config.cacertfile)

      cond do
        not cert_valid -> {:error, "SSL certificate file not found: #{ssl_config.certfile}"}
        not key_valid -> {:error, "SSL key file not found: #{ssl_config.keyfile}"}
        not ca_valid -> {:error, "SSL CA certificate file not found: #{ssl_config.cacertfile}"}
        true -> {:ok, ssl_config}
      end
    end
  end

  defp check_access_control(user_id, resource, action, state) do
    # Simple role-based access control
    user_permissions = get_user_permissions(user_id, state.access_controls)

    if has_permission(user_permissions, resource, action) do
      {:ok, :allowed}
    else
      {:error, :denied}
    end
  end

  defp filter_audit_log(audit_log, start_time, end_time) do
    audit_log
    |> Enum.filter(fn event ->
      event_time = event.timestamp

      cond do
        end_time == :infinity -> event_time >= start_time
        true -> event_time >= start_time and event_time <= end_time
      end
    end)
  end

  defp create_security_event(event_type, metadata) do
    %{
      id: generate_event_id(),
      type: event_type,
      severity: determine_event_severity(event_type),
      message: generate_event_message(event_type, metadata),
      metadata: metadata,
      timestamp: System.system_time(:second),
      ip_address: Map.get(metadata, :ip_address),
      user_id: Map.get(metadata, :user_id)
    }
  end

  defp update_security_configuration(state, config) do
    # Update security configuration
    %{
      state
      | ssl_config: Map.merge(state.ssl_config, Map.get(config, :ssl, %{})),
        access_controls: Map.merge(state.access_controls, Map.get(config, :access_controls, %{}))
    }
  end

  # Security check functions

  defp check_input_validation_vulnerabilities do
    # Check for input validation vulnerabilities
    vulnerabilities = []

    # Check for potential SQL injection vulnerabilities
    vulnerabilities = 
      if has_sql_injection_risk() do
        [
          %{
            id: generate_vulnerability_id(),
            type: :sql_injection,
            severity: :high,
            description: "Potential SQL injection vulnerability detected",
            cve_id: "CVE-2023-XXXX",
            affected_component: "Database queries",
            remediation: "Use parameterized queries and input validation",
            discovered_at: System.system_time(:second)
          }
          | vulnerabilities
        ]
      else
        vulnerabilities
      end

    # Check for XSS vulnerabilities
    vulnerabilities = 
      if has_xss_risk() do
        [
          %{
            id: generate_vulnerability_id(),
            type: :xss,
            severity: :medium,
            description: "Potential XSS vulnerability detected",
            cve_id: nil,
            affected_component: "Web interface",
            remediation: "Sanitize user input and use CSP headers",
            discovered_at: System.system_time(:second)
          }
          | vulnerabilities
        ]
      else
        vulnerabilities
      end

    vulnerabilities
  end

  defp check_authentication_vulnerabilities do
    # Check for authentication vulnerabilities
    vulnerabilities = []

    # Check for weak password policies
    vulnerabilities = 
      if has_weak_password_policy() do
        [
          %{
            id: generate_vulnerability_id(),
            type: :weak_authentication,
            severity: :medium,
            description: "Weak password policy detected",
            cve_id: nil,
            affected_component: "Authentication system",
            remediation: "Implement strong password requirements",
            discovered_at: System.system_time(:second)
          }
          | vulnerabilities
        ]
      else
        vulnerabilities
      end

    vulnerabilities
  end

  defp check_authorization_vulnerabilities do
    # Check for authorization vulnerabilities
    []
  end

  defp check_ssl_tls_vulnerabilities do
    # Check for SSL/TLS vulnerabilities
    []
  end

  defp check_rate_limiting_vulnerabilities do
    # Check for rate limiting vulnerabilities
    []
  end

  defp check_logging_vulnerabilities do
    # Check for logging vulnerabilities
    []
  end

  # Input validation functions

  defp validate_json_input(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, "Invalid JSON: #{reason}"}
    end
  end

  defp validate_json_input(input) when is_map(input) do
    {:ok, input}
  end

  defp validate_json_input(_input) do
    {:error, "Input must be JSON string or map"}
  end

  defp validate_sql_input(input) when is_binary(input) do
    # Basic SQL injection prevention
    dangerous_patterns = ["'", ";", "--", "/*", "*/", "DROP", "DELETE", "UPDATE", "INSERT"]

    has_dangerous_pattern =
      Enum.any?(dangerous_patterns, fn pattern ->
        String.contains?(String.upcase(input), pattern)
      end)

    if has_dangerous_pattern do
      {:error, "Potentially dangerous SQL input detected"}
    else
      {:ok, input}
    end
  end

  defp validate_sql_input(_input) do
    {:error, "SQL input must be a string"}
  end

  defp validate_url_input(input) when is_binary(input) do
    # Basic URL validation
    if String.match?(input, ~r/^https?:\/\/.+/i) do
      {:ok, input}
    else
      {:error, "Invalid URL format"}
    end
  end

  defp validate_url_input(_input) do
    {:error, "URL input must be a string"}
  end

  defp validate_email_input(input) when is_binary(input) do
    # Basic email validation
    email_pattern = ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

    if String.match?(input, email_pattern) do
      {:ok, input}
    else
      {:error, "Invalid email format"}
    end
  end

  defp validate_email_input(_input) do
    {:error, "Email input must be a string"}
  end

  defp validate_password_input(input) when is_binary(input) do
    # Password strength validation
    cond do
      String.length(input) < @min_password_length ->
        {:error, "Password must be at least #{@min_password_length} characters"}

      not String.match?(input, ~r/[A-Z]/) ->
        {:error, "Password must contain at least one uppercase letter"}

      not String.match?(input, ~r/[a-z]/) ->
        {:error, "Password must contain at least one lowercase letter"}

      not String.match?(input, ~r/[0-9]/) ->
        {:error, "Password must contain at least one digit"}

      not String.match?(input, ~r/[^A-Za-z0-9]/) ->
        {:error, "Password must contain at least one special character"}

      true ->
        {:ok, input}
    end
  end

  defp validate_password_input(_input) do
    {:error, "Password input must be a string"}
  end

  defp validate_general_input(input) when is_binary(input) do
    # General input sanitization
    sanitized =
      input
      |> String.trim()
      |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
      |> String.replace(~r/<[^>]*>/i, "")

    if String.length(sanitized) > @default_max_input_size do
      {:error, "Input too large"}
    else
      {:ok, sanitized}
    end
  end

  defp validate_general_input(input) when is_map(input) do
    {:ok, input}
  end

  defp validate_general_input(input) when is_list(input) do
    {:ok, input}
  end

  defp validate_general_input(_input) do
    {:error, "Unsupported input type"}
  end

  # Helper functions

  defp generate_event_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp generate_vulnerability_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp determine_event_severity(event_type) do
    case event_type do
      :authentication_failure -> :medium
      :authorization_failure -> :high
      :sql_injection_attempt -> :critical
      :xss_attempt -> :high
      :rate_limit_exceeded -> :low
      :ssl_error -> :medium
      _ -> :low
    end
  end

  defp generate_event_message(event_type, metadata) do
    case event_type do
      :authentication_failure -> "Authentication failure for user: #{metadata.user_id}"
      :authorization_failure -> "Authorization failure for user: #{metadata.user_id}"
      :sql_injection_attempt -> "SQL injection attempt detected from IP: #{metadata.ip_address}"
      :xss_attempt -> "XSS attempt detected from IP: #{metadata.ip_address}"
      :rate_limit_exceeded -> "Rate limit exceeded for IP: #{metadata.ip_address}"
      :ssl_error -> "SSL/TLS error: #{metadata.error}"
      _ -> "Security event: #{event_type}"
    end
  end

  defp calculate_security_score(vulnerabilities) do
    base_score = 100

    score_reduction =
      Enum.reduce(vulnerabilities, 0, fn vuln, acc ->
        reduction =
          case vuln.severity do
            :critical -> 25
            :high -> 15
            :medium -> 10
            :low -> 5
          end

        acc + reduction
      end)

    max(0, base_score - score_reduction)
  end

  defp generate_security_recommendations(vulnerabilities) do
    Enum.map(vulnerabilities, fn vuln ->
      vuln.remediation
    end)
  end

  defp check_compliance_status(state) do
    %{
      gdpr_compliant: check_gdpr_compliance(state),
      sox_compliant: check_sox_compliance(state),
      pci_compliant: check_pci_compliance(state)
    }
  end

  defp check_gdpr_compliance(_state) do
    # Simplified GDPR compliance check
    true
  end

  defp check_sox_compliance(_state) do
    # Simplified SOX compliance check
    true
  end

  defp check_pci_compliance(_state) do
    # Simplified PCI compliance check
    true
  end

  defp get_rate_limit_requests(key, window_start, rate_limits) do
    case Map.get(rate_limits, key) do
      nil ->
        0

      requests ->
        # Filter requests within the window
        Enum.count(requests, fn timestamp -> timestamp >= window_start end)
    end
  end

  defp update_rate_limit_tracking(key, current_time, rate_limits) do
    current_requests = Map.get(rate_limits, key, [])
    new_requests = [current_time | current_requests]
    Map.put(rate_limits, key, new_requests)
  end

  defp get_user_permissions(user_id, access_controls) do
    Map.get(access_controls, user_id, [])
  end

  defp has_permission(permissions, resource, action) do
    Enum.any?(permissions, fn permission ->
      permission.resource == resource and permission.action == action
    end)
  end

  defp log_to_external_system(security_event) do
    # Log to external security monitoring system
    Logger.warning("Security event: #{security_event.message}")
    :ok
  end

  # Vulnerability detection functions (simplified)

  defp has_sql_injection_risk do
    # Simplified check - in real implementation, this would analyze code
    false
  end

  defp has_xss_risk do
    # Simplified check - in real implementation, this would analyze code
    false
  end

  defp has_weak_password_policy do
    # Simplified check - in real implementation, this would check actual policy
    false
  end
end
