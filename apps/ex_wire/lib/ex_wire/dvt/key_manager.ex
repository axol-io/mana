defmodule ExWire.DVT.KeyManager do
  @moduledoc """
  DVT Key Share Management and Storage System.

  Manages the lifecycle of DVT clusters, key shares, rotation, and enterprise
  integration with RBAC, HSM, and audit logging.
  """

  use GenServer
  require Logger

  alias ExWire.DVT.Crypto
  alias ExWire.Enterprise.AuditLogger

  @type cluster_id :: String.t()
  @type validator_pubkey :: String.t()
  @type node_id :: pos_integer()

  # State structure for the KeyManager GenServer
  defstruct [
    # %{cluster_id => cluster_config}
    :clusters,
    # %{cluster_id => %{node_id => key_share_data}}
    :key_shares,
    # HSM configuration
    :hsm_config,
    # Audit logging configuration
    :audit_config,
    # RBAC configuration
    :rbac_config,
    # Key rotation schedule
    :rotation_schedule,
    # Monitoring process PID
    :monitoring_pid
  ]

  # Type definitions for nested structures
  @type cluster_config :: %{
          cluster_id: String.t(),
          validator_pubkey: String.t(),
          threshold: pos_integer(),
          total_nodes: pos_integer(),
          # %{node_id => node_info}
          participants: map(),
          # :initializing | :active | :rotating | :archived
          status: :initializing | :active | :rotating | :archived,
          created_at: pos_integer(),
          last_rotation: pos_integer(),
          next_rotation: pos_integer(),
          # List of backup storage locations
          backup_locations: list(String.t()),
          # :standard | :enterprise | :regulated
          compliance_level: :standard | :enterprise | :regulated
        }

  @type node_info :: %{
          node_id: String.t(),
          operator_id: String.t(),
          endpoint: String.t(),
          public_key: binary(),
          # :online | :offline | :syncing | :faulty
          status: :online | :offline | :syncing | :faulty,
          last_seen: pos_integer(),
          performance_metrics: map(),
          security_level: atom()
        }

  @type key_share_data :: %{
          node_id: String.t(),
          cluster_id: String.t(),
          # Encrypted key share or HSM reference
          share_data: binary(),
          public_key_set: map(),
          verification_data: map(),
          created_at: pos_integer(),
          last_used: pos_integer(),
          # :backed_up | :pending | :failed
          backup_status: :backed_up | :pending | :failed,
          # HSM key identifier if using HSM
          hsm_key_id: String.t()
        }

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Create a new DVT cluster with specified configuration.
  """
  @spec create_cluster(
          cluster_id(),
          validator_pubkey(),
          pos_integer(),
          pos_integer(),
          list(map()),
          keyword()
        ) :: {:ok, map()} | {:error, atom()}
  def create_cluster(
        cluster_id,
        validator_pubkey,
        threshold,
        total_nodes,
        participants,
        opts \\ []
      ) do
    GenServer.call(
      __MODULE__,
      {:create_cluster,
       {
         cluster_id,
         validator_pubkey,
         threshold,
         total_nodes,
         participants,
         opts
       }},
      30_000
    )
  end

  @doc """
  Initialize DKG for a cluster.
  """
  @spec initialize_dkg(cluster_id(), keyword()) :: {:ok, map()} | {:error, atom()}
  def initialize_dkg(cluster_id, opts \\ []) do
    GenServer.call(__MODULE__, {:initialize_dkg, cluster_id, opts}, 60_000)
  end

  @doc """
  Get cluster information.
  """
  @spec get_cluster(cluster_id()) :: {:ok, map()} | {:error, :not_found}
  def get_cluster(cluster_id) do
    GenServer.call(__MODULE__, {:get_cluster, cluster_id})
  end

  @doc """
  List all clusters with optional filtering.
  """
  @spec list_clusters(keyword()) :: list(map())
  def list_clusters(filters \\ []) do
    GenServer.call(__MODULE__, {:list_clusters, filters})
  end

  @doc """
  Sign a message using DVT cluster.
  """
  @spec sign_message(cluster_id(), binary(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def sign_message(cluster_id, message, opts \\ []) do
    GenServer.call(__MODULE__, {:sign_message, cluster_id, message, opts}, 30_000)
  end

  @doc """
  Rotate keys for a cluster.
  """
  @spec rotate_keys(cluster_id(), keyword()) :: {:ok, map()} | {:error, atom()}
  def rotate_keys(cluster_id, opts \\ []) do
    GenServer.call(__MODULE__, {:rotate_keys, cluster_id, opts}, 300_000)
  end

  @doc """
  Archive a cluster (for decommissioned validators).
  """
  @spec archive_cluster(cluster_id(), keyword()) :: {:ok, map()} | {:error, atom()}
  def archive_cluster(cluster_id, opts \\ []) do
    GenServer.call(__MODULE__, {:archive_cluster, cluster_id, opts})
  end

  @doc """
  Get cluster health status.
  """
  @spec get_cluster_health(cluster_id()) :: {:ok, map()} | {:error, atom()}
  def get_cluster_health(cluster_id) do
    GenServer.call(__MODULE__, {:get_cluster_health, cluster_id})
  end

  @doc """
  Update node status in a cluster.
  """
  @spec update_node_status(cluster_id(), node_id(), atom(), map()) :: :ok | {:error, atom()}
  def update_node_status(cluster_id, node_id, status, metrics \\ %{}) do
    GenServer.call(__MODULE__, {:update_node_status, cluster_id, node_id, status, metrics})
  end

  ## GenServer Implementation

  @impl true
  def init(opts) do
    hsm_config = Keyword.get(opts, :hsm_config, %{})
    audit_config = Keyword.get(opts, :audit_config, %{})
    rbac_config = Keyword.get(opts, :rbac_config, %{})

    # Initialize ETS table for fast cluster lookups
    :ets.new(:dvt_clusters, [:set, :named_table, :protected])
    :ets.new(:dvt_key_shares, [:set, :named_table, :protected])

    state = %__MODULE__{
      clusters: %{},
      key_shares: %{},
      hsm_config: hsm_config,
      audit_config: audit_config,
      rbac_config: rbac_config,
      rotation_schedule: %{},
      monitoring_pid: nil
    }

    # Start monitoring process
    {:ok, monitoring_pid} = start_monitoring_process()

    # Schedule periodic tasks
    schedule_health_checks()
    schedule_key_rotation_checks()

    {:ok, %{state | monitoring_pid: monitoring_pid}}
  end

  @impl true
  def handle_call(
        {:create_cluster,
         {cluster_id, validator_pubkey, threshold, total_nodes, participants, opts}},
        _from,
        state
      ) do
    case validate_cluster_creation(cluster_id, threshold, total_nodes, participants, state) do
      :ok ->
        case create_cluster_impl(
               cluster_id,
               validator_pubkey,
               threshold,
               total_nodes,
               participants,
               opts,
               state
             ) do
          {:ok, cluster_config, new_state} ->
            # Audit log cluster creation
            audit_cluster_event(
              :cluster_created,
              cluster_id,
              %{
                validator_pubkey: validator_pubkey,
                threshold: threshold,
                total_nodes: total_nodes,
                participants: length(participants)
              },
              state.audit_config
            )

            {:reply, {:ok, cluster_config}, new_state}

          {:error, reason} = error ->
            audit_cluster_event(
              :cluster_creation_failed,
              cluster_id,
              %{reason: reason},
              state.audit_config
            )

            {:reply, error, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:initialize_dkg, cluster_id, opts}, _from, state) do
    case Map.get(state.clusters, cluster_id) do
      nil ->
        {:reply, {:error, :cluster_not_found}, state}

      cluster_config ->
        case initialize_dkg_impl(cluster_config, opts, state) do
          {:ok, dkg_data, new_state} ->
            audit_cluster_event(
              :dkg_initialized,
              cluster_id,
              %{
                participants: length(cluster_config.participants),
                threshold: cluster_config.threshold
              },
              state.audit_config
            )

            {:reply, {:ok, dkg_data}, new_state}

          {:error, reason} = error ->
            audit_cluster_event(
              :dkg_initialization_failed,
              cluster_id,
              %{reason: reason},
              state.audit_config
            )

            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call({:sign_message, cluster_id, message, opts}, _from, state) do
    with {:ok, cluster_config} <- get_cluster_config(cluster_id, state),
         {:ok, _} <- check_signing_permissions(cluster_id, opts, state),
         {:ok, signature} <- perform_threshold_signing(cluster_config, message, opts, state) do
      # Audit log signing operation
      audit_cluster_event(
        :message_signed,
        cluster_id,
        %{
          message_hash: :crypto.hash(:sha256, message) |> Base.encode16(),
          signature_length: byte_size(signature)
        },
        state.audit_config
      )

      {:reply, {:ok, signature}, state}
    else
      {:error, reason} = error ->
        audit_cluster_event(
          :signing_failed,
          cluster_id,
          %{
            reason: reason,
            message_hash: :crypto.hash(:sha256, message) |> Base.encode16()
          },
          state.audit_config
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:rotate_keys, cluster_id, opts}, _from, state) do
    with {:ok, cluster_config} <- get_cluster_config(cluster_id, state),
         {:ok, _} <- check_rotation_permissions(cluster_id, opts, state),
         {:ok, new_cluster_config, new_state} <- perform_key_rotation(cluster_config, opts, state) do
      audit_cluster_event(
        :keys_rotated,
        cluster_id,
        %{
          old_key_created: cluster_config.created_at,
          new_key_created: new_cluster_config.created_at
        },
        state.audit_config
      )

      {:reply, {:ok, new_cluster_config}, new_state}
    else
      {:error, reason} = error ->
        audit_cluster_event(
          :key_rotation_failed,
          cluster_id,
          %{reason: reason},
          state.audit_config
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_cluster, cluster_id}, _from, state) do
    case Map.get(state.clusters, cluster_id) do
      nil -> {:reply, {:error, :not_found}, state}
      cluster_config -> {:reply, {:ok, cluster_config}, state}
    end
  end

  @impl true
  def handle_call({:get_cluster_health, cluster_id}, _from, state) do
    case get_cluster_config(cluster_id, state) do
      {:ok, cluster_config} ->
        health_status = calculate_cluster_health(cluster_config, state)
        {:reply, {:ok, health_status}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_node_public_key, cluster_id, node_id}, _from, state) do
    case get_cluster_config(cluster_id, state) do
      {:ok, cluster_config} ->
        case Map.get(cluster_config.participants, node_id) do
          nil -> {:reply, {:error, :not_found}, state}
          node_info -> {:reply, {:ok, node_info.public_key}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  # Periodic health check
  @impl true
  def handle_info(:health_check, state) do
    perform_cluster_health_checks(state)
    schedule_health_checks()
    {:noreply, state}
  end

  # Periodic key rotation check
  @impl true
  def handle_info(:rotation_check, state) do
    check_and_perform_scheduled_rotations(state)
    schedule_key_rotation_checks()
    {:noreply, state}
  end

  ## Private Implementation Functions

  defp validate_cluster_creation(cluster_id, threshold, total_nodes, participants, state) do
    cond do
      Map.has_key?(state.clusters, cluster_id) ->
        {:error, :cluster_already_exists}

      threshold < 1 or threshold > total_nodes ->
        {:error, :invalid_threshold}

      length(participants) != total_nodes ->
        {:error, :participant_count_mismatch}

      threshold < div(total_nodes, 2) + 1 ->
        {:error, :threshold_too_low}

      true ->
        :ok
    end
  end

  defp create_cluster_impl(
         cluster_id,
         validator_pubkey,
         threshold,
         total_nodes,
         participants,
         opts,
         state
       ) do
    compliance_level = Keyword.get(opts, :compliance_level, :standard)

    # Create participant map with node information
    participant_map =
      participants
      |> Enum.with_index()
      |> Enum.into(%{}, fn {participant, index} ->
        {index,
         %{
           node_id: index,
           operator_id: Map.get(participant, :operator_id),
           endpoint: Map.get(participant, :endpoint),
           public_key: Map.get(participant, :public_key),
           status: :offline,
           last_seen: nil,
           performance_metrics: %{},
           security_level: Map.get(participant, :security_level, :standard)
         }}
      end)

    cluster_config = %{
      cluster_id: cluster_id,
      validator_pubkey: validator_pubkey,
      threshold: threshold,
      total_nodes: total_nodes,
      participants: participant_map,
      status: :initializing,
      created_at: DateTime.utc_now(),
      last_rotation: nil,
      next_rotation: calculate_next_rotation(compliance_level),
      backup_locations: Keyword.get(opts, :backup_locations, []),
      compliance_level: compliance_level
    }

    # Store in ETS for fast access
    :ets.insert(:dvt_clusters, {cluster_id, cluster_config})

    new_state = %{state | clusters: Map.put(state.clusters, cluster_id, cluster_config)}

    {:ok, cluster_config, new_state}
  end

  defp initialize_dkg_impl(cluster_config, _opts, state) do
    cluster_id = cluster_config.cluster_id
    participants = Map.keys(cluster_config.participants)
    threshold = cluster_config.threshold

    # Generate unique round ID
    round_id = "#{cluster_id}_#{DateTime.utc_now() |> DateTime.to_unix()}"

    case Crypto.initialize_dkg(0, participants, threshold, round_id) do
      {:ok, {dkg_participant, initial_shares}} ->
        dkg_data = %{
          round_id: round_id,
          participant_data: dkg_participant,
          initial_shares: initial_shares,
          cluster_id: cluster_id,
          status: :in_progress,
          started_at: DateTime.utc_now()
        }

        # Store DKG state
        new_state = put_in(state, [:clusters, cluster_id, :dkg_state], dkg_data)

        {:ok, dkg_data, new_state}

      error ->
        error
    end
  end

  defp perform_threshold_signing(cluster_config, message, _opts, state) do
    cluster_id = cluster_config.cluster_id
    threshold = cluster_config.threshold

    # Get key shares for this cluster
    case get_cluster_key_shares(cluster_id, state) do
      {:ok, key_shares} when length(key_shares) >= threshold ->
        # Create signature shares from available nodes
        signature_shares =
          key_shares
          |> Enum.take(threshold)
          |> Enum.map(fn {_node_id, key_share} ->
            case Crypto.create_dvt_signature_share(
                   key_share.share_data,
                   message,
                   state.hsm_config
                 ) do
              {:ok, signature_share} -> signature_share
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        if length(signature_shares) >= threshold do
          # Get public key set
          public_key_set = get_cluster_public_key_set(cluster_id, state)

          # Aggregate signatures
          Crypto.aggregate_dvt_signatures(public_key_set, signature_shares, threshold)
        else
          {:error, :insufficient_signature_shares}
        end

      _ ->
        {:error, :insufficient_key_shares}
    end
  end

  defp perform_key_rotation(cluster_config, opts, state) do
    cluster_id = cluster_config.cluster_id

    # Generate new keys using DKG
    with {:ok, dkg_data, intermediate_state} <- initialize_dkg_impl(cluster_config, opts, state),
         {:ok, new_key_shares} <- complete_dkg_rotation(dkg_data, intermediate_state) do
      # Archive old keys
      {:ok, _} = archive_old_keys(cluster_id, intermediate_state)

      # Update cluster configuration
      new_cluster_config = %{
        cluster_config
        | last_rotation: DateTime.utc_now(),
          next_rotation: calculate_next_rotation(cluster_config.compliance_level),
          status: :active
      }

      # Update state with new keys and configuration
      new_state = %{
        intermediate_state
        | clusters: Map.put(intermediate_state.clusters, cluster_id, new_cluster_config),
          key_shares: Map.put(intermediate_state.key_shares, cluster_id, new_key_shares)
      }

      {:ok, new_cluster_config, new_state}
    end
  end

  defp get_cluster_config(cluster_id, state) do
    case Map.get(state.clusters, cluster_id) do
      nil -> {:error, :cluster_not_found}
      config -> {:ok, config}
    end
  end

  defp get_cluster_key_shares(cluster_id, state) do
    case Map.get(state.key_shares, cluster_id) do
      nil -> {:error, :no_key_shares}
      shares -> {:ok, Map.to_list(shares)}
    end
  end

  defp get_cluster_public_key_set(_cluster_id, _state) do
    # This would retrieve the public key set from the cluster configuration
    # For now, return a placeholder
    <<0::256>>
  end

  @doc """
  Get the public key for a specific node in a cluster.
  """
  @spec get_node_public_key(cluster_id(), node_id()) :: {:ok, binary()} | {:error, term()}
  def get_node_public_key(cluster_id, node_id) do
    case GenServer.call(__MODULE__, {:get_node_public_key, cluster_id, node_id}) do
      {:ok, public_key} -> {:ok, public_key}
      error -> error
    end
  end

  defp check_signing_permissions(cluster_id, opts, state) do
    case state.rbac_config do
      %{} = config when map_size(config) > 0 ->
        operator_id = Keyword.get(opts, :operator_id)
        RBAC.check_permission(operator_id, :dvt_sign, %{cluster_id: cluster_id}, config)

      _ ->
        {:ok, :allowed}
    end
  end

  defp check_rotation_permissions(cluster_id, opts, state) do
    case state.rbac_config do
      %{} = config when map_size(config) > 0 ->
        operator_id = Keyword.get(opts, :operator_id)
        RBAC.check_permission(operator_id, :dvt_rotate_keys, %{cluster_id: cluster_id}, config)

      _ ->
        {:ok, :allowed}
    end
  end

  defp calculate_cluster_health(cluster_config, state) do
    participants = cluster_config.participants
    online_nodes = Enum.count(participants, fn {_id, info} -> info.status == :online end)
    total_nodes = cluster_config.total_nodes
    threshold = cluster_config.threshold

    health_status =
      cond do
        online_nodes >= threshold -> :healthy
        online_nodes >= div(threshold, 2) -> :degraded
        true -> :critical
      end

    %{
      status: health_status,
      online_nodes: online_nodes,
      total_nodes: total_nodes,
      threshold: threshold,
      uptime_percentage: calculate_uptime_percentage(cluster_config, state),
      last_health_check: DateTime.utc_now()
    }
  end

  defp calculate_uptime_percentage(_cluster_config, _state) do
    # Placeholder implementation
    99.95
  end

  defp calculate_next_rotation(compliance_level) do
    rotation_interval =
      case compliance_level do
        # 90 days
        :standard -> 90
        # 30 days  
        :enterprise -> 30
        # 14 days
        :regulated -> 14
      end

    DateTime.utc_now() |> DateTime.add(rotation_interval, :day)
  end

  defp complete_dkg_rotation(_dkg_data, _state) do
    # Placeholder for DKG completion logic
    {:ok, %{}}
  end

  defp archive_old_keys(_cluster_id, _state) do
    # Placeholder for key archival logic
    {:ok, :archived}
  end

  defp audit_cluster_event(event_type, cluster_id, metadata, audit_config) do
    case audit_config do
      %{} = config when map_size(config) > 0 ->
        AuditLogger.log_event(
          :dvt_operation,
          event_type,
          %{
            cluster_id: cluster_id,
            timestamp: DateTime.utc_now(),
            metadata: metadata
          },
          config
        )

      _ ->
        Logger.info("DVT Event: #{event_type} for cluster #{cluster_id}", metadata: metadata)
    end
  end

  defp start_monitoring_process do
    # Start a separate process for monitoring cluster health
    {:ok, spawn_link(fn -> monitoring_loop() end)}
  end

  defp monitoring_loop do
    # Monitor cluster health, node status, etc.
    # Check every 30 seconds
    Process.sleep(30_000)
    monitoring_loop()
  end

  defp schedule_health_checks do
    # Every minute
    Process.send_after(self(), :health_check, 60_000)
  end

  defp schedule_key_rotation_checks do
    # Every hour
    Process.send_after(self(), :rotation_check, 3_600_000)
  end

  defp perform_cluster_health_checks(_state) do
    # Implement cluster health checking logic
    :ok
  end

  defp check_and_perform_scheduled_rotations(_state) do
    # Check for clusters that need key rotation
    :ok
  end
end
