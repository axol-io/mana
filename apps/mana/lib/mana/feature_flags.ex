defmodule Mana.FeatureFlags do
  @moduledoc """
  Feature flags system for controlling V2 rollout and other feature toggles.

  This module provides:
  - Dynamic feature flag evaluation
  - Environment-based configuration
  - Runtime flag updates
  - A/B testing support
  - User/session-based targeting
  - Comprehensive logging and monitoring
  """

  require Logger

  @doc """
  Checks if V2 is enabled for a specific module.

  ## Parameters
  - module_type: The module to check (:transaction_pool, :sync_service, etc.)
  - context: Optional context for targeting (user_id, session_id, etc.)

  ## Returns
  - true if V2 is enabled
  - false if V1 should be used
  """
  @spec v2_enabled?(atom(), map()) :: boolean()
  def v2_enabled?(module_type, context \\ %{}) do
    case get_module_version(module_type) do
      "v2" ->
        # V2 is enabled, check additional conditions
        check_additional_conditions(module_type, context)

      _ ->
        # V2 not enabled or explicitly disabled
        false
    end
  end

  @doc """
  Gets the configured version for a module.

  ## Parameters
  - module_type: The module to check

  ## Returns
  - "v1" | "v2" | "auto"
  """
  @spec get_module_version(atom()) :: String.t()
  def get_module_version(module_type) do
    # Check environment variable first
    env_var_name = (module_type |> Atom.to_string() |> String.upcase()) <> "_VERSION"

    case System.get_env(env_var_name) do
      version when version in ["v1", "v2", "auto"] ->
        version

      nil ->
        # Fall back to application configuration
        :mana
        |> Application.get_env(:module_versions, %{})
        |> Map.get(module_type, "v1")

      invalid_version ->
        Logger.warning("Invalid version in environment variable", %{
          env_var: env_var_name,
          value: invalid_version,
          module_type: module_type
        })

        # Safe default
        "v1"
    end
  end

  @doc """
  Gets the traffic split percentage for a module.

  ## Parameters
  - module_type: The module to check

  ## Returns
  - Integer between 0-100 representing percentage of traffic to route to V2
  """
  @spec get_traffic_split(atom()) :: non_neg_integer()
  def get_traffic_split(module_type) do
    # Check environment variable first
    env_var_name = (module_type |> Atom.to_string() |> String.upcase()) <> "_TRAFFIC"

    case System.get_env(env_var_name) do
      nil ->
        # Fall back to application configuration
        :mana
        |> Application.get_env(:traffic_splits, %{})
        |> Map.get(module_type, 0)

      traffic_str ->
        case Integer.parse(traffic_str) do
          {traffic, ""} when traffic >= 0 and traffic <= 100 ->
            traffic

          _ ->
            Logger.warning("Invalid traffic split in environment variable", %{
              env_var: env_var_name,
              value: traffic_str,
              module_type: module_type
            })

            # Safe default
            0
        end
    end
  end

  @doc """
  Checks if a specific feature flag is enabled.

  ## Parameters
  - flag_name: The name of the feature flag
  - context: Optional context for targeting

  ## Returns
  - true if the flag is enabled
  - false if the flag is disabled
  """
  @spec enabled?(atom(), map()) :: boolean()
  def enabled?(flag_name, context \\ %{}) do
    flag_config = get_flag_config(flag_name)

    case flag_config do
      nil ->
        # Flag not configured, default to disabled
        false

      config ->
        evaluate_flag(config, context)
    end
  end

  @doc """
  Sets a feature flag value (for testing/debugging).

  ## Parameters
  - flag_name: The name of the feature flag
  - enabled: Whether the flag should be enabled

  ## Returns
  - :ok
  """
  @spec set_flag(atom(), boolean()) :: :ok
  def set_flag(flag_name, enabled) when is_boolean(enabled) do
    current_overrides = Application.get_env(:mana, :feature_flag_overrides, %{})
    new_overrides = Map.put(current_overrides, flag_name, enabled)

    Application.put_env(:mana, :feature_flag_overrides, new_overrides)

    Logger.info("Feature flag override set", %{
      flag_name: flag_name,
      enabled: enabled
    })

    emit_telemetry(:flag_override_set, %{flag_name: flag_name, enabled: enabled})

    :ok
  end

  @doc """
  Clears a feature flag override.

  ## Parameters
  - flag_name: The name of the feature flag to clear

  ## Returns
  - :ok
  """
  @spec clear_flag_override(atom()) :: :ok
  def clear_flag_override(flag_name) do
    current_overrides = Application.get_env(:mana, :feature_flag_overrides, %{})
    new_overrides = Map.delete(current_overrides, flag_name)

    Application.put_env(:mana, :feature_flag_overrides, new_overrides)

    Logger.info("Feature flag override cleared", %{flag_name: flag_name})
    emit_telemetry(:flag_override_cleared, %{flag_name: flag_name})

    :ok
  end

  @doc """
  Gets all active feature flags and their states.

  ## Returns
  - Map of flag_name => enabled_status
  """
  @spec get_all_flags() :: map()
  def get_all_flags do
    base_flags = Application.get_env(:mana, :feature_flags, %{})
    overrides = Application.get_env(:mana, :feature_flag_overrides, %{})

    Map.merge(base_flags, overrides)
  end

  @doc """
  Evaluates multiple flags at once for efficiency.

  ## Parameters
  - flag_names: List of flag names to evaluate
  - context: Optional context for targeting

  ## Returns
  - Map of flag_name => enabled_status
  """
  @spec evaluate_flags([atom()], map()) :: map()
  def evaluate_flags(flag_names, context \\ %{}) when is_list(flag_names) do
    Map.new(flag_names, fn flag_name ->
      {flag_name, enabled?(flag_name, context)}
    end)
  end

  # Private Implementation

  defp check_additional_conditions(module_type, context) do
    # Check if there are any additional conditions that should disable V2
    conditions = [
      &check_maintenance_mode/2,
      &check_user_targeting/2,
      &check_session_targeting/2,
      &check_time_based_conditions/2,
      &check_load_conditions/2
    ]

    Enum.all?(conditions, fn condition ->
      condition.(module_type, context)
    end)
  end

  defp check_maintenance_mode(_module_type, _context) do
    # Check if system is in maintenance mode
    not Application.get_env(:mana, :maintenance_mode, false)
  end

  defp check_user_targeting(module_type, context) do
    case Map.get(context, :user_id) do
      nil ->
        # No user targeting
        true

      user_id ->
        # Check if this user is in the target group for V2
        target_config = get_user_targeting_config(module_type)
        evaluate_user_targeting(user_id, target_config)
    end
  end

  defp check_session_targeting(module_type, context) do
    case Map.get(context, :session_id) do
      nil ->
        # No session targeting
        true

      session_id ->
        # Check if this session is in the target group for V2
        target_config = get_session_targeting_config(module_type)
        evaluate_session_targeting(session_id, target_config)
    end
  end

  defp check_time_based_conditions(module_type, _context) do
    # Check if current time is within allowed V2 window
    time_config = get_time_based_config(module_type)
    evaluate_time_conditions(time_config)
  end

  defp check_load_conditions(module_type, _context) do
    # Check if system load allows V2 usage
    load_config = get_load_based_config(module_type)
    evaluate_load_conditions(load_config)
  end

  defp get_flag_config(flag_name) do
    # Check for override first
    overrides = Application.get_env(:mana, :feature_flag_overrides, %{})

    case Map.get(overrides, flag_name) do
      nil ->
        # Get from normal configuration
        :mana
        |> Application.get_env(:feature_flags, %{})
        |> Map.get(flag_name)

      override_value ->
        # Return simple override config
        %{enabled: override_value, type: :override}
    end
  end

  defp evaluate_flag(config, context) do
    case config do
      %{enabled: enabled, type: :override} ->
        enabled

      %{enabled: enabled} when is_boolean(enabled) ->
        enabled

      %{percentage: percentage} when is_number(percentage) ->
        evaluate_percentage_flag(percentage, context)

      %{conditions: conditions} when is_list(conditions) ->
        evaluate_conditional_flag(conditions, context)

      %{enabled: enabled, conditions: conditions} ->
        enabled and evaluate_conditional_flag(conditions, context)

      _ ->
        Logger.warning("Invalid flag configuration", %{config: config})
        false
    end
  end

  defp evaluate_percentage_flag(percentage, context) do
    # Use consistent hashing for percentage-based flags
    hash_input =
      case context do
        %{user_id: user_id} when not is_nil(user_id) ->
          user_id

        %{session_id: session_id} when not is_nil(session_id) ->
          session_id

        %{caller_id: caller_id} when not is_nil(caller_id) ->
          caller_id

        _ ->
          # Fallback to random for anonymous contexts
          :rand.uniform(100)
      end

    hash_value = :erlang.phash2(hash_input)
    bucket = rem(abs(hash_value), 100) + 1

    bucket <= percentage
  end

  defp evaluate_conditional_flag(conditions, context) do
    Enum.all?(conditions, fn condition ->
      evaluate_single_condition(condition, context)
    end)
  end

  defp evaluate_single_condition(condition, context) do
    case condition do
      {:user_id_in, user_ids} ->
        Map.get(context, :user_id) in user_ids

      {:user_id_not_in, user_ids} ->
        Map.get(context, :user_id) not in user_ids

      {:session_type, session_type} ->
        Map.get(context, :session_type) == session_type

      {:time_window, start_hour, end_hour} ->
        current_hour = DateTime.utc_now().hour
        current_hour >= start_hour and current_hour <= end_hour

      {:day_of_week, days} ->
        current_day = Date.day_of_week(Date.utc_today())
        current_day in days

      {:environment, env} ->
        Application.get_env(:mana, :environment) == env

      _ ->
        Logger.warning("Unknown flag condition", %{condition: condition})
        false
    end
  end

  # Targeting configuration getters

  defp get_user_targeting_config(module_type) do
    :mana
    |> Application.get_env(:user_targeting, %{})
    |> Map.get(module_type, %{})
  end

  defp get_session_targeting_config(module_type) do
    :mana
    |> Application.get_env(:session_targeting, %{})
    |> Map.get(module_type, %{})
  end

  defp get_time_based_config(module_type) do
    :mana
    |> Application.get_env(:time_based_config, %{})
    |> Map.get(module_type, %{})
  end

  defp get_load_based_config(module_type) do
    :mana
    |> Application.get_env(:load_based_config, %{})
    |> Map.get(module_type, %{})
  end

  # Targeting evaluation functions

  defp evaluate_user_targeting(user_id, config) do
    case config do
      %{whitelist: whitelist} when is_list(whitelist) ->
        user_id in whitelist

      %{blacklist: blacklist} when is_list(blacklist) ->
        user_id not in blacklist

      %{percentage: percentage} ->
        hash_value = :erlang.phash2(user_id)
        bucket = rem(abs(hash_value), 100) + 1
        bucket <= percentage

      _ ->
        # No targeting configured
        true
    end
  end

  defp evaluate_session_targeting(session_id, config) do
    case config do
      %{prefix_whitelist: prefixes} when is_list(prefixes) ->
        Enum.any?(prefixes, fn prefix ->
          String.starts_with?(session_id, prefix)
        end)

      %{percentage: percentage} ->
        hash_value = :erlang.phash2(session_id)
        bucket = rem(abs(hash_value), 100) + 1
        bucket <= percentage

      _ ->
        # No targeting configured
        true
    end
  end

  defp evaluate_time_conditions(config) do
    case config do
      %{allowed_hours: {start_hour, end_hour}} ->
        current_hour = DateTime.utc_now().hour

        if end_hour >= start_hour do
          current_hour >= start_hour and current_hour <= end_hour
        else
          # Handle overnight window (e.g., 22:00 to 06:00)
          current_hour >= start_hour or current_hour <= end_hour
        end

      %{blocked_hours: blocked_hours} when is_list(blocked_hours) ->
        current_hour = DateTime.utc_now().hour
        current_hour not in blocked_hours

      %{allowed_days: allowed_days} when is_list(allowed_days) ->
        current_day = Date.day_of_week(Date.utc_today())
        current_day in allowed_days

      _ ->
        # No time restrictions
        true
    end
  end

  defp evaluate_load_conditions(config) do
    case config do
      %{max_cpu_percent: max_cpu} ->
        current_cpu = get_current_cpu_usage()
        current_cpu <= max_cpu

      %{max_memory_percent: max_memory} ->
        current_memory = get_current_memory_usage()
        current_memory <= max_memory

      %{max_concurrent_requests: max_requests} ->
        current_requests = get_current_request_count()
        current_requests <= max_requests

      _ ->
        # No load restrictions
        true
    end
  end

  # System metrics helpers (simplified implementations)

  defp get_current_cpu_usage do
    # Simplified CPU usage check
    # In production, would use proper system monitoring
    case :cpu_sup.avg1() do
      {ok, avg} when is_number(avg) -> avg
      _ -> 0
    end
  rescue
    # Fallback if cpu_sup not available
    _ -> 0
  end

  defp get_current_memory_usage do
    # Simplified memory usage check
    total_memory = :erlang.memory(:total)
    system_memory = :erlang.memory(:system)

    if system_memory > 0 do
      total_memory / system_memory * 100
    else
      0
    end
  rescue
    _ -> 0
  end

  defp get_current_request_count do
    # Get current request count from router metrics
    case Mana.ModuleRouter.get_routing_stats() do
      %{total_requests: total} -> total
      _ -> 0
    end
  rescue
    _ -> 0
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:mana, :feature_flags, event],
      %{count: 1, timestamp: :os.system_time(:millisecond)},
      metadata
    )
  end
end
