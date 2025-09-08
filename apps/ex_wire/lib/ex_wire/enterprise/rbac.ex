defmodule ExWire.Enterprise.RBAC do
  @moduledoc """
  Role-Based Access Control system for enterprise Ethereum operations.
  Provides fine-grained permissions, role hierarchies, and dynamic authorization.
  """

  use GenServer
  require Logger

  alias ExWire.Enterprise.AuditLogger

  defstruct [
    :roles,
    :users,
    :permissions,
    :sessions,
    :policies,
    :config
  ]

  @type role :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          permissions: list(permission()),
          parent_role: String.t() | nil,
          metadata: map(),
          created_at: DateTime.t()
        }

  @type user :: %{
          id: String.t(),
          username: String.t(),
          roles: list(String.t()),
          direct_permissions: list(permission()),
          attributes: map(),
          status: :active | :suspended | :locked,
          last_login: DateTime.t() | nil,
          mfa_enabled: boolean()
        }

  @type permission :: %{
          resource: String.t(),
          action: atom(),
          conditions: map()
        }

  @type policy :: %{
          id: String.t(),
          name: String.t(),
          effect: :allow | :deny,
          principals: list(String.t()),
          resources: list(String.t()),
          actions: list(atom()),
          conditions: map()
        }

  # Predefined permissions
  @permissions %{
    # Blockchain operations
    send_transaction: %{resource: "blockchain", action: :send_transaction},
    approve_transaction: %{resource: "blockchain", action: :approve_transaction},
    cancel_transaction: %{resource: "blockchain", action: :cancel_transaction},

    # Node management
    manage_node: %{resource: "node", action: :manage},
    view_node_status: %{resource: "node", action: :view_status},
    configure_node: %{resource: "node", action: :configure},

    # Wallet operations
    create_wallet: %{resource: "wallet", action: :create},
    manage_wallet: %{resource: "wallet", action: :manage},
    view_wallet: %{resource: "wallet", action: :view},

    # Compliance operations
    generate_reports: %{resource: "compliance", action: :generate_reports},
    review_alerts: %{resource: "compliance", action: :review_alerts},
    submit_sar: %{resource: "compliance", action: :submit_sar},

    # Admin operations
    manage_users: %{resource: "admin", action: :manage_users},
    manage_roles: %{resource: "admin", action: :manage_roles},
    view_audit_logs: %{resource: "admin", action: :view_audit_logs},

    # HSM operations
    manage_hsm_keys: %{resource: "hsm", action: :manage_keys},
    use_hsm_keys: %{resource: "hsm", action: :use_keys}
  }

  # Predefined roles
  @default_roles %{
    "super_admin" => %{
      name: "Super Administrator",
      description: "Full system access",
      permissions: Map.values(@permissions),
      parent_role: nil
    },
    "admin" => %{
      name: "Administrator",
      description: "Administrative access",
      permissions: [
        @permissions.manage_node,
        @permissions.view_node_status,
        @permissions.configure_node,
        @permissions.manage_users,
        @permissions.manage_roles,
        @permissions.view_audit_logs
      ],
      parent_role: nil
    },
    "compliance_officer" => %{
      name: "Compliance Officer",
      description: "Compliance and reporting access",
      permissions: [
        @permissions.generate_reports,
        @permissions.review_alerts,
        @permissions.submit_sar,
        @permissions.view_audit_logs
      ],
      parent_role: nil
    },
    "operator" => %{
      name: "Operator",
      description: "Operational access",
      permissions: [
        @permissions.send_transaction,
        @permissions.approve_transaction,
        @permissions.view_node_status,
        @permissions.view_wallet
      ],
      parent_role: nil
    },
    "viewer" => %{
      name: "Viewer",
      description: "Read-only access",
      permissions: [
        @permissions.view_node_status,
        @permissions.view_wallet
      ],
      parent_role: nil
    }
  }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Create a new user
  """
  def create_user(username, roles, attributes \\ %{}) do
    GenServer.call(__MODULE__, {:create_user, username, roles, attributes})
  end

  @doc """
  Update user roles
  """
  def update_user_roles(user_id, roles) do
    GenServer.call(__MODULE__, {:update_user_roles, user_id, roles})
  end

  @doc """
  Create a custom role
  """
  def create_role(name, description, permissions, opts \\ []) do
    GenServer.call(__MODULE__, {:create_role, name, description, permissions, opts})
  end

  @doc """
  Check if user has permission
  """
  def has_permission?(user_id, resource, action, context \\ %{}) do
    GenServer.call(__MODULE__, {:check_permission, user_id, resource, action, context})
  end

  @doc """
  Authorize an operation
  """
  def authorize(user_id, operation, _params \\ %{}) do
    GenServer.call(__MODULE__, {:authorize, user_id, operation, params})
  end

  @doc """
  Create a new session for user
  """
  def create_session(user_id, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:create_session, user_id, metadata})
  end

  @doc """
  Revoke a session
  """
  def revoke_session(session_id) do
    GenServer.call(__MODULE__, {:revoke_session, session_id})
  end

  @doc """
  Get user details
  """
  def get_user(user_id) do
    GenServer.call(__MODULE__, {:get_user, user_id})
  end

  @doc """
  List all users
  """
  def list_users do
    GenServer.call(__MODULE__, :list_users)
  end

  @doc """
  List all roles
  """
  def list_roles do
    GenServer.call(__MODULE__, :list_roles)
  end

  @doc """
  Add a policy
  """
  def add_policy(policy) do
    GenServer.call(__MODULE__, {:add_policy, policy})
  end

  @doc """
  Enable MFA for user
  """
  def enable_mfa(user_id, secret) do
    GenServer.call(__MODULE__, {:enable_mfa, user_id, secret})
  end

  @doc """
  Verify MFA token
  """
  def verify_mfa(user_id, token) do
    GenServer.call(__MODULE__, {:verify_mfa, user_id, token})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting RBAC system")

    state = %__MODULE__{
      roles: initialize_roles(),
      users: %{},
      permissions: @permissions,
      sessions: %{},
      policies: [],
      config: build_config(opts)
    }

    # Create default admin user if specified
    state =
      if opts[:default_admin] do
        create_default_admin(state, opts[:default_admin])
      else
        state
      end

    schedule_session_cleanup()
    {:ok, _state}
  end

  @impl true
  def handle_call({:create_user, username, roles, attributes}, _from, _state) do
    user_id = generate_user_id()

    user = %{
      id: user_id,
      username: username,
      roles: validate_roles(roles, state.roles),
      direct_permissions: [],
      attributes: attributes,
      status: :active,
      last_login: nil,
      mfa_enabled: false,
      created_at: DateTime.utc_now()
    }

    state = put_in(state.users[user_id], user)

    AuditLogger.log(:user_created, %{
      user_id: user_id,
      username: username,
      roles: roles
    })

    {:reply, {:ok, user}, state}
  end

  @impl true
  def handle_call({:update_user_roles, user_id, new_roles}, _from, _state) do
    case Map.get(state.users, user_id) do
      nil ->
        {:reply, {:error, :user_not_found}, state}

      user ->
        old_roles = user.roles
        updated_user = %{user | roles: validate_roles(new_roles, state.roles)}
        state = put_in(state.users[user_id], updated_user)

        AuditLogger.log(:user_roles_updated, %{
          user_id: user_id,
          old_roles: old_roles,
          new_roles: new_roles
        })

        {:reply, {:ok, updated_user}, state}
    end
  end

  @impl true
  def handle_call({:create_role, name, description, permissions, opts}, _from, _state) do
    role_id = generate_role_id()

    role = %{
      id: role_id,
      name: name,
      description: description,
      permissions: validate_permissions(permissions),
      parent_role: Keyword.get(opts, :parent_role),
      metadata: Keyword.get(opts, :metadata, %{}),
      created_at: DateTime.utc_now()
    }

    state = put_in(state.roles[role_id], role)

    AuditLogger.log(:role_created, %{
      role_id: role_id,
      name: name,
      permissions_count: length(permissions)
    })

    {:reply, {:ok, role}, state}
  end

  @impl true
  def handle_call({:check_permission, user_id, resource, action, context}, _from, _state) do
    case Map.get(state.users, user_id) do
      nil ->
        {:reply, false, _state}

      user ->
        has_permission = check_user_permission(user, resource, action, context, state)

        if has_permission do
          AuditLogger.log(:permission_granted, %{
            user_id: user_id,
            resource: resource,
            action: action
          })
        else
          AuditLogger.log(:permission_denied, %{
            user_id: user_id,
            resource: resource,
            action: action
          })
        end

        {:reply, has_permission, state}
    end
  end

  @impl true
  def handle_call({:authorize, user_id, operation, _params}, _from, _state) do
    case Map.get(state.users, user_id) do
      nil ->
        {:reply, {:error, :unauthorized}, state}

      user ->
        case authorize_operation(user, operation, params, state) do
          :ok ->
            AuditLogger.log(:operation_authorized, %{
              user_id: user_id,
              operation: operation,
              params: sanitize_params(_params)
            })

            {:reply, :ok, state}

          {:error, _reason} ->
            AuditLogger.log(:operation_denied, %{
              user_id: user_id,
              operation: operation,
              reason: reason
            })

            {:reply, {:error, _reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:create_session, user_id, metadata}, _from, _state) do
    case Map.get(state.users, user_id) do
      nil ->
        {:reply, {:error, :user_not_found}, state}

      user ->
        if user.status != :active do
          {:reply, {:error, :user_not_active}, state}
        else
          session_id = generate_session_id()

          session = %{
            id: session_id,
            user_id: user_id,
            created_at: DateTime.utc_now(),
            expires_at: DateTime.add(DateTime.utc_now(), state.config.session_timeout, :second),
            metadata: metadata,
            permissions_cache: compute_user_permissions(user, state)
          }

          state = put_in(state.sessions[session_id], session)

          # Update last login
          updated_user = %{user | last_login: DateTime.utc_now()}
          state = put_in(state.users[user_id], updated_user)

          AuditLogger.log(:session_created, %{
            session_id: session_id,
            user_id: user_id
          })

          {:reply, {:ok, session}, state}
        end
    end
  end

  @impl true
  def handle_call({:revoke_session, session_id}, _from, _state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :session_not_found}, state}

      session ->
        state = update_in(state.sessions, &Map.delete(&1, session_id))

        AuditLogger.log(:session_revoked, %{
          session_id: session_id,
          user_id: session.user_id
        })

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:get_user, user_id}, _from, _state) do
    case Map.get(state.users, user_id) do
      nil -> {:reply, {:error, :user_not_found}, state}
      user -> {:reply, {:ok, sanitize_user(user)}, state}
    end
  end

  @impl true
  def handle_call(:list_users, _from, _state) do
    users = Enum.map(state.users, fn {_id, user} -> sanitize_user(user) end)
    {:reply, {:ok, users}, state}
  end

  @impl true
  def handle_call(:list_roles, _from, _state) do
    roles = Map.values(state.roles)
    {:reply, {:ok, roles}, state}
  end

  @impl true
  def handle_call({:add_policy, policy}, _from, _state) do
    policy = Map.put(policy, :id, generate_policy_id())
    state = update_in(state.policies, &[policy | &1])

    AuditLogger.log(:policy_added, %{
      policy_id: policy.id,
      name: policy.name,
      effect: policy.effect
    })

    {:reply, {:ok, policy}, state}
  end

  @impl true
  def handle_call({:enable_mfa, user_id, secret}, _from, _state) do
    case Map.get(state.users, user_id) do
      nil ->
        {:reply, {:error, :user_not_found}, state}

      user ->
        updated_user = %{
          user
          | mfa_enabled: true,
            attributes: Map.put(user.attributes, :mfa_secret, secret)
        }

        state = put_in(state.users[user_id], updated_user)

        AuditLogger.log(:mfa_enabled, %{user_id: user_id})

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:verify_mfa, user_id, token}, _from, _state) do
    case Map.get(state.users, user_id) do
      nil ->
        {:reply, {:error, :user_not_found}, state}

      user ->
        if user.mfa_enabled do
          secret = user.attributes[:mfa_secret]
          valid = verify_totp(secret, token)

          if valid do
            AuditLogger.log(:mfa_verified, %{user_id: user_id})
          else
            AuditLogger.log(:mfa_failed, %{user_id: user_id})
          end

          {:reply, valid, state}
        else
          {:reply, {:error, :mfa_not_enabled}, state}
        end
    end
  end

  @impl true
  def handle_info(:cleanup_sessions, _state) do
    now = DateTime.utc_now()

    active_sessions =
      Enum.filter(state.sessions, fn {_id, session} ->
        DateTime.compare(session.expires_at, now) == :gt
      end)
      |> Enum.into(%{})

    expired_count = map_size(state.sessions) - map_size(active_sessions)

    if expired_count > 0 do
      Logger.info("Cleaned up #{expired_count} expired sessions")
    end

    schedule_session_cleanup()
    {:noreply, %{state | sessions: active_sessions}}
  end

  # Private Functions

  defp check_user_permission(user, resource, action, context, _state) do
    # Check if user is suspended or locked
    if user.status != :active do
      false
    else
      # Collect all permissions from roles
      role_permissions = collect_role_permissions(user.roles, state.roles)

      # Add direct permissions
      all_permissions = role_permissions ++ user.direct_permissions

      # Check permissions
      has_permission =
        Enum.any?(all_permissions, fn perm ->
          perm.resource == resource && perm.action == action &&
            check_conditions(perm.conditions, context)
        end)

      # Check policies
      if not has_permission do
        check_policies(user.id, resource, action, context, state.policies)
      else
        has_permission
      end
    end
  end

  defp collect_role_permissions(role_ids, all_roles) do
    Enum.flat_map(role_ids, fn role_id ->
      case Map.get(all_roles, role_id) do
        nil ->
          []

        role ->
          parent_perms =
            if role.parent_role do
              collect_role_permissions([role.parent_role], all_roles)
            else
              []
            end

          role.permissions ++ parent_perms
      end
    end)
    |> Enum.uniq()
  end

  defp check_conditions(conditions, context) when map_size(conditions) == 0, do: true

  defp check_conditions(conditions, context) do
    Enum.all?(conditions, fn {key, expected} ->
      Map.get(context, key) == expected
    end)
  end

  defp check_policies(user_id, resource, action, context, policies) do
    Enum.any?(policies, fn policy ->
      user_id in policy.principals &&
        resource_matches?(resource, policy.resources) &&
        action in policy.actions &&
        check_conditions(policy.conditions, context) &&
        policy.effect == :allow
    end)
  end

  defp resource_matches?(resource, patterns) do
    Enum.any?(patterns, fn pattern ->
      if String.contains?(pattern, "*") do
        regex = String.replace(pattern, "*", ".*") |> Regex.compile!()
        Regex.match?(regex, resource)
      else
        resource == pattern
      end
    end)
  end

  defp authorize_operation(user, operation, _params, _state) do
    case operation do
      :send_transaction ->
        if check_user_permission(user, "blockchain", :send_transaction, params, _state) do
          check_transaction_limits(user, _params)
        else
          {:error, :insufficient_permissions}
        end

      :create_wallet ->
        if check_user_permission(user, "wallet", :create, params, state) do
          :ok
        else
          {:error, :insufficient_permissions}
        end

      _ ->
        {:error, :unknown_operation}
    end
  end

  defp check_transaction_limits(user, _params) do
    # Check daily limits, value thresholds, etc.
    max_value = get_user_limit(user, :max_transaction_value)

    if params[:value] && params[:value] > max_value do
      {:error, :exceeds_limit}
    else
      :ok
    end
  end

  defp get_user_limit(user, limit_type) do
    # Get limit from user attributes or role
    case limit_type do
      # 100 ETH default
      :max_transaction_value -> 100_000_000_000_000_000_000
      _ -> nil
    end
  end

  defp compute_user_permissions(user, _state) do
    role_permissions = collect_role_permissions(user.roles, _state.roles)
    (role_permissions ++ user.direct_permissions) |> Enum.uniq()
  end

  defp verify_totp(secret, token) do
    # TOTP verification implementation
    # This would use a proper TOTP library
    true
  end

  defp initialize_roles do
    Enum.map(@default_roles, fn {id, role_data} ->
      {id,
       Map.merge(role_data, %{
         id: id,
         created_at: DateTime.utc_now()
       })}
    end)
    |> Enum.into(%{})
  end

  defp validate_roles(role_ids, existing_roles) do
    Enum.filter(role_ids, fn role_id ->
      Map.has_key?(existing_roles, role_id)
    end)
  end

  defp validate_permissions(permissions) do
    Enum.map(permissions, fn perm ->
      %{
        resource: perm.resource,
        action: perm.action,
        conditions: Map.get(perm, :conditions, %{})
      }
    end)
  end

  defp create_default_admin(_state, admin_config) do
    user_id = "admin"

    user = %{
      id: user_id,
      username: admin_config[:username] || "admin",
      roles: ["super_admin"],
      direct_permissions: [],
      attributes: %{},
      status: :active,
      last_login: nil,
      mfa_enabled: admin_config[:require_mfa] || false,
      created_at: DateTime.utc_now()
    }

    put_in(state.users[user_id], user)
  end

  defp sanitize_user(user) do
    Map.drop(user, [:attributes])
    |> Map.put(:permissions_count, length(user.direct_permissions))
  end

  defp sanitize_params(_params) do
    Map.drop(params, [:private_key, :password, :secret])
  end

  defp build_config(opts) do
    %{
      session_timeout: Keyword.get(opts, :session_timeout, 3600),
      max_sessions_per_user: Keyword.get(opts, :max_sessions_per_user, 5),
      require_mfa: Keyword.get(opts, :require_mfa, false),
      password_policy: Keyword.get(opts, :password_policy, default_password_policy())
    }
  end

  defp default_password_policy do
    %{
      min_length: 12,
      require_uppercase: true,
      require_lowercase: true,
      require_numbers: true,
      require_special: true,
      max_age_days: 90
    }
  end

  defp generate_user_id do
    "user_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_role_id do
    "role_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_session_id do
    Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
  end

  defp generate_policy_id do
    "policy_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp schedule_session_cleanup do
    Process.send_after(self(), :cleanup_sessions, :timer.minutes(5))
  end
end
