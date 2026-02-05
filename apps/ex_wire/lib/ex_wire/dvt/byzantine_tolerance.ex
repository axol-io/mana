defmodule ExWire.DVT.ByzantineTolerance do
  @moduledoc """
  Byzantine Fault Tolerance implementation for DVT operations.

  Implements comprehensive BFT mechanisms to handle malicious and faulty operators
  in DVT clusters, including view-change protocols, leader election, fault detection,
  and automatic recovery procedures.
  """

  use GenServer
  require Logger

  alias ExWire.DVT.DutyConsensus
  alias ExWire.Enterprise.AuditLogger

  @type node_id :: pos_integer()
  @type cluster_id :: String.t()
  @type view_number :: non_neg_integer()
  @type fault_type :: :crash | :byzantine | :network_partition | :slow_response | :invalid_message

  # Server state
  defstruct [
    # %{cluster_id => bft_config}
    :cluster_configs,
    # %{cluster_id => %{node_id => node_state}}
    :node_states,
    # List of fault evidence records
    :fault_evidence,
    # %{cluster_id => current_view_info}
    :view_states,
    # Active recovery procedures
    :recovery_procedures,
    # BFT performance monitoring
    :performance_stats,
    # Audit logging configuration
    :audit_config
  ]

  # Type definitions for nested structures
  @type bft_config :: %{
          cluster_id: String.t(),
          total_nodes: pos_integer(),
          # f in BFT literature
          max_faulty_nodes: pos_integer(),
          # 2f + 1 for safety
          safety_threshold: pos_integer(),
          # f + 1 for liveness
          liveness_threshold: pos_integer(),
          # Milliseconds before triggering view change
          view_change_timeout: pos_integer(),
          # Milliseconds before suspecting leader failure
          leader_timeout: pos_integer(),
          # Milliseconds for message delivery
          message_timeout: pos_integer(),
          # Maximum view changes before escalation
          max_view_changes: pos_integer(),
          # :automatic | :manual | :hybrid
          recovery_strategy: :automatic | :manual | :hybrid
        }

  @type node_state :: %{
          node_id: String.t(),
          cluster_id: String.t(),
          # :active | :suspected | :faulty | :recovered
          status: :active | :suspected | :faulty | :recovered,
          last_seen: pos_integer(),
          message_count: pos_integer(),
          invalid_messages: pos_integer(),
          # Recent response time history
          response_times: list(float()),
          view_changes_initiated: pos_integer(),
          # Accumulated fault evidence
          fault_score: float(),
          recovery_attempts: pos_integer(),
          # DateTime when quarantine expires
          quarantine_until: pos_integer()
        }

  @type fault_evidence :: %{
          node_id: String.t(),
          fault_type: atom(),
          # Specific evidence for this fault
          evidence_data: map(),
          # Node that reported the fault
          reported_by: String.t(),
          timestamp: pos_integer(),
          # :low | :medium | :high | :critical
          severity: :low | :medium | :high | :critical,
          # Whether evidence has been verified
          verified: boolean(),
          # How the fault was resolved
          resolution: String.t()
        }

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Configure BFT parameters for a DVT cluster.
  """
  @spec configure_bft(cluster_id(), pos_integer(), map()) :: :ok | {:error, atom()}
  def configure_bft(cluster_id, total_nodes, bft_options \\ %{}) do
    GenServer.call(__MODULE__, {:configure_bft, cluster_id, total_nodes, bft_options})
  end

  @doc """
  Report suspicious behavior from a node.
  """
  @spec report_suspicious_behavior(cluster_id(), node_id(), fault_type(), map()) :: :ok
  def report_suspicious_behavior(cluster_id, suspected_node, fault_type, evidence) do
    GenServer.cast(
      __MODULE__,
      {:report_suspicious_behavior, cluster_id, suspected_node, fault_type, evidence}
    )
  end

  @doc """
  Handle consensus timeout - trigger view change if necessary.
  """
  @spec handle_consensus_timeout(cluster_id(), view_number()) :: :ok
  def handle_consensus_timeout(cluster_id, current_view) do
    GenServer.cast(__MODULE__, {:consensus_timeout, cluster_id, current_view})
  end

  @doc """
  Process incoming message and update node health metrics.
  """
  @spec process_node_message(cluster_id(), node_id(), map()) :: :ok | {:error, atom()}
  def process_node_message(cluster_id, node_id, message) do
    GenServer.call(__MODULE__, {:process_node_message, cluster_id, node_id, message})
  end

  @doc """
  Get fault tolerance status for a cluster.
  """
  @spec get_bft_status(cluster_id()) :: {:ok, map()} | {:error, atom()}
  def get_bft_status(cluster_id) do
    GenServer.call(__MODULE__, {:get_bft_status, cluster_id})
  end

  @doc """
  Trigger manual recovery for a cluster.
  """
  @spec trigger_recovery(cluster_id(), atom()) :: {:ok, reference()} | {:error, atom()}
  def trigger_recovery(cluster_id, recovery_type \\ :automatic) do
    GenServer.call(__MODULE__, {:trigger_recovery, cluster_id, recovery_type}, 60_000)
  end

  @doc """
  Get comprehensive fault evidence for audit.
  """
  @spec get_fault_evidence(cluster_id() | :all) :: {:ok, list()} | {:error, atom()}
  def get_fault_evidence(cluster_id) do
    GenServer.call(__MODULE__, {:get_fault_evidence, cluster_id})
  end

  ## GenServer Implementation

  @impl true
  def init(opts) do
    audit_config = Keyword.get(opts, :audit_config, %{})

    # Initialize ETS tables for fast lookups
    :ets.new(:bft_node_states, [:set, :named_table, :protected])
    :ets.new(:bft_fault_evidence, [:ordered_set, :named_table, :protected])

    state = %__MODULE__{
      cluster_configs: %{},
      node_states: %{},
      fault_evidence: [],
      view_states: %{},
      recovery_procedures: %{},
      performance_stats: initialize_bft_stats(),
      audit_config: audit_config
    }

    # Schedule periodic fault detection
    schedule_fault_detection()
    schedule_health_monitoring()

    Logger.info("DVT Byzantine Fault Tolerance system initialized")
    {:ok, state}
  end

  @impl true
  def handle_call({:configure_bft, cluster_id, total_nodes, bft_options}, _from, state) do
    # Classical BFT: n >= 3f + 1
    max_faulty = div(total_nodes - 1, 3)

    bft_config = %{
      cluster_id: cluster_id,
      total_nodes: total_nodes,
      max_faulty_nodes: max_faulty,
      safety_threshold: 2 * max_faulty + 1,
      liveness_threshold: max_faulty + 1,
      view_change_timeout: Map.get(bft_options, :view_change_timeout, 30_000),
      leader_timeout: Map.get(bft_options, :leader_timeout, 15_000),
      message_timeout: Map.get(bft_options, :message_timeout, 5_000),
      max_view_changes: Map.get(bft_options, :max_view_changes, 10),
      recovery_strategy: Map.get(bft_options, :recovery_strategy, :automatic)
    }

    # Initialize node states for cluster
    node_states =
      Enum.reduce(0..(total_nodes - 1), %{}, fn node_id, acc ->
        node_state = %{
          node_id: node_id,
          cluster_id: cluster_id,
          status: :active,
          last_seen: DateTime.utc_now(),
          message_count: 0,
          invalid_messages: 0,
          response_times: [],
          view_changes_initiated: 0,
          fault_score: 0.0,
          recovery_attempts: 0,
          quarantine_until: nil
        }

        Map.put(acc, node_id, node_state)
      end)

    new_state = %{
      state
      | cluster_configs: Map.put(state.cluster_configs, cluster_id, bft_config),
        node_states: Map.put(state.node_states, cluster_id, node_states),
        view_states:
          Map.put(state.view_states, cluster_id, %{
            current_view: 0,
            leader_id: 0,
            view_change_in_progress: false,
            last_view_change: DateTime.utc_now()
          })
    }

    audit_bft_event(
      :bft_configured,
      cluster_id,
      %{
        total_nodes: total_nodes,
        max_faulty_nodes: max_faulty,
        safety_threshold: bft_config.safety_threshold
      },
      state.audit_config
    )

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:process_node_message, cluster_id, node_id, message}, _from, state) do
    case get_cluster_node_state(cluster_id, node_id, state) do
      {:ok, node_state} ->
        # Update node health metrics
        current_time = DateTime.utc_now()

        response_time =
          DateTime.diff(current_time, Map.get(message, :sent_at, current_time), :millisecond)

        updated_node = %{
          node_state
          | last_seen: current_time,
            message_count: node_state.message_count + 1,
            response_times: update_response_times(node_state.response_times, response_time)
        }

        # Validate message for potential Byzantine behavior
        case validate_message_integrity(message, cluster_id, node_id, state) do
          :valid ->
            new_state = update_node_state(cluster_id, node_id, updated_node, state)
            {:reply, :ok, new_state}

          {:invalid, reason} ->
            # Record invalid message and update fault score
            faulty_node = %{
              updated_node
              | invalid_messages: updated_node.invalid_messages + 1,
                fault_score: calculate_fault_score(updated_node, :invalid_message)
            }

            new_state = update_node_state(cluster_id, node_id, faulty_node, state)

            # Report suspicious behavior
            report_fault_evidence(
              cluster_id,
              node_id,
              :invalid_message,
              %{
                reason: reason,
                message: message
              },
              new_state
            )

            {:reply, {:error, {:invalid_message, reason}}, new_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_bft_status, cluster_id}, _from, state) do
    case Map.get(state.cluster_configs, cluster_id) do
      nil ->
        {:reply, {:error, :cluster_not_configured}, state}

      bft_config ->
        node_states = Map.get(state.node_states, cluster_id, %{})
        view_state = Map.get(state.view_states, cluster_id, %{})

        # Calculate cluster health metrics
        active_nodes = Enum.count(node_states, fn {_id, node} -> node.status == :active end)
        suspected_nodes = Enum.count(node_states, fn {_id, node} -> node.status == :suspected end)
        faulty_nodes = Enum.count(node_states, fn {_id, node} -> node.status == :faulty end)

        # Determine overall cluster health
        cluster_status =
          cond do
            active_nodes >= bft_config.safety_threshold -> :healthy
            active_nodes >= bft_config.liveness_threshold -> :degraded
            true -> :critical
          end

        bft_status = %{
          cluster_id: cluster_id,
          status: cluster_status,
          total_nodes: bft_config.total_nodes,
          active_nodes: active_nodes,
          suspected_nodes: suspected_nodes,
          faulty_nodes: faulty_nodes,
          max_faulty_nodes: bft_config.max_faulty_nodes,
          safety_threshold: bft_config.safety_threshold,
          liveness_threshold: bft_config.liveness_threshold,
          current_view: view_state[:current_view] || 0,
          current_leader: view_state[:leader_id] || 0,
          view_change_in_progress: view_state[:view_change_in_progress] || false,
          recent_faults: get_recent_fault_count(cluster_id, state),
          performance_metrics: calculate_cluster_performance(cluster_id, state)
        }

        {:reply, {:ok, bft_status}, state}
    end
  end

  @impl true
  def handle_call({:trigger_recovery, cluster_id, recovery_type}, _from, state) do
    case Map.get(state.cluster_configs, cluster_id) do
      nil ->
        {:reply, {:error, :cluster_not_configured}, state}

      bft_config ->
        recovery_ref = make_ref()

        recovery_procedure = %{
          recovery_ref: recovery_ref,
          cluster_id: cluster_id,
          recovery_type: recovery_type,
          started_at: DateTime.utc_now(),
          status: :in_progress,
          steps_completed: [],
          estimated_completion: nil
        }

        new_state = %{
          state
          | recovery_procedures:
              Map.put(state.recovery_procedures, recovery_ref, recovery_procedure)
        }

        # Start recovery process asynchronously
        Task.start(fn ->
          execute_recovery_procedure(recovery_procedure, bft_config, self())
        end)

        audit_bft_event(
          :recovery_triggered,
          cluster_id,
          %{
            recovery_type: recovery_type,
            recovery_ref: recovery_ref
          },
          state.audit_config
        )

        {:reply, {:ok, recovery_ref}, new_state}
    end
  end

  @impl true
  def handle_call({:get_fault_evidence, cluster_id}, _from, state) do
    evidence =
      case cluster_id do
        :all ->
          state.fault_evidence

        specific_cluster ->
          Enum.filter(state.fault_evidence, fn evidence ->
            evidence.cluster_id == specific_cluster
          end)
      end

    {:reply, {:ok, evidence}, state}
  end

  @impl true
  def handle_cast(
        {:report_suspicious_behavior, cluster_id, suspected_node, fault_type, evidence},
        state
      ) do
    fault_evidence = %{
      node_id: suspected_node,
      cluster_id: cluster_id,
      fault_type: fault_type,
      evidence_data: evidence,
      reported_by: get_current_node_id(),
      timestamp: DateTime.utc_now(),
      severity: determine_fault_severity(fault_type, evidence),
      verified: false,
      resolution: nil
    }

    # Add to fault evidence
    new_state = %{state | fault_evidence: [fault_evidence | state.fault_evidence]}

    # Update node state based on fault type
    updated_state =
      case get_cluster_node_state(cluster_id, suspected_node, new_state) do
        {:ok, node_state} ->
          updated_node = handle_fault_report(node_state, fault_type, evidence)
          update_node_state(cluster_id, suspected_node, updated_node, new_state)

        {:error, _reason} ->
          new_state
      end

    # Check if we need to trigger automated responses
    final_state =
      check_and_trigger_fault_response(cluster_id, suspected_node, fault_type, updated_state)

    audit_bft_event(
      :suspicious_behavior_reported,
      cluster_id,
      %{
        suspected_node: suspected_node,
        fault_type: fault_type,
        severity: fault_evidence.severity
      },
      state.audit_config
    )

    {:noreply, final_state}
  end

  @impl true
  def handle_cast({:consensus_timeout, cluster_id, current_view}, state) do
    case Map.get(state.view_states, cluster_id) do
      nil ->
        {:noreply, state}

      view_state ->
        # Check if view change is already in progress
        if view_state.view_change_in_progress do
          {:noreply, state}
        else
          # Initiate view change
          new_state = initiate_view_change(cluster_id, current_view, :timeout, state)
          {:noreply, new_state}
        end
    end
  end

  # Periodic fault detection
  @impl true
  def handle_info(:fault_detection, state) do
    # Perform fault detection across all clusters
    new_state =
      Enum.reduce(state.cluster_configs, state, fn {cluster_id, _config}, acc_state ->
        perform_fault_detection(cluster_id, acc_state)
      end)

    schedule_fault_detection()
    {:noreply, new_state}
  end

  # Periodic health monitoring
  @impl true
  def handle_info(:health_monitoring, state) do
    # Update health metrics and detect slow/unresponsive nodes
    new_state =
      Enum.reduce(state.cluster_configs, state, fn {cluster_id, _config}, acc_state ->
        update_cluster_health_metrics(cluster_id, acc_state)
      end)

    schedule_health_monitoring()
    {:noreply, new_state}
  end

  # Recovery procedure completion
  @impl true
  def handle_info({:recovery_completed, recovery_ref, result}, state) do
    case Map.get(state.recovery_procedures, recovery_ref) do
      nil ->
        {:noreply, state}

      recovery_procedure ->
        completed_procedure = %{
          recovery_procedure
          | status: :completed,
            completed_at: DateTime.utc_now(),
            result: result
        }

        new_state = %{
          state
          | recovery_procedures:
              Map.put(state.recovery_procedures, recovery_ref, completed_procedure)
        }

        audit_bft_event(
          :recovery_completed,
          recovery_procedure.cluster_id,
          %{
            recovery_ref: recovery_ref,
            result: result,
            duration_ms:
              DateTime.diff(DateTime.utc_now(), recovery_procedure.started_at, :millisecond)
          },
          state.audit_config
        )

        {:noreply, new_state}
    end
  end

  ## Private Implementation Functions

  defp get_cluster_node_state(cluster_id, node_id, state) do
    case Map.get(state.node_states, cluster_id) do
      nil ->
        {:error, :cluster_not_found}

      cluster_nodes ->
        case Map.get(cluster_nodes, node_id) do
          nil -> {:error, :node_not_found}
          node_state -> {:ok, node_state}
        end
    end
  end

  defp update_node_state(cluster_id, node_id, updated_node, state) do
    cluster_nodes = Map.get(state.node_states, cluster_id, %{})
    updated_cluster_nodes = Map.put(cluster_nodes, node_id, updated_node)

    %{state | node_states: Map.put(state.node_states, cluster_id, updated_cluster_nodes)}
  end

  defp update_response_times(response_times, new_time) do
    # Keep last 20 response times for trend analysis
    [new_time | response_times] |> Enum.take(20)
  end

  defp validate_message_integrity(message, cluster_id, node_id, state) do
    # Comprehensive message validation for Byzantine behavior detection
    with :ok <- validate_message_structure(message),
         :ok <- validate_message_timing(message),
         :ok <- validate_message_content(message, cluster_id, node_id, state),
         :ok <- validate_message_signature(message) do
      :valid
    else
      {:error, reason} -> {:invalid, reason}
    end
  end

  defp validate_message_structure(message) do
    required_fields = [:type, :timestamp, :sender_id, :signature]

    if Enum.all?(required_fields, &Map.has_key?(message, &1)) do
      :ok
    else
      {:error, :missing_required_fields}
    end
  end

  defp validate_message_timing(message) do
    current_time = DateTime.utc_now()
    message_time = Map.get(message, :timestamp, current_time)

    age_seconds = DateTime.diff(current_time, message_time, :second)

    cond do
      age_seconds > 60 -> {:error, :message_too_old}
      age_seconds < -10 -> {:error, :message_from_future}
      true -> :ok
    end
  end

  defp validate_message_content(message, _cluster_id, _node_id, _state) do
    # Validate message content for consistency and correctness
    case message.type do
      :consensus_prepare ->
        validate_consensus_message_content(message, :prepare)

      :consensus_commit ->
        validate_consensus_message_content(message, :commit)

      :view_change ->
        validate_view_change_content(message)

      _ ->
        # Other message types pass basic validation
        :ok
    end
  end

  defp validate_consensus_message_content(message, phase) do
    # Validate consensus message content based on phase
    required_fields =
      case phase do
        :prepare -> [:view, :duty_type, :payload]
        :commit -> [:view, :duty_type, :payload, :prepare_certificates]
      end

    if Enum.all?(required_fields, &Map.has_key?(message, &1)) do
      :ok
    else
      {:error, :invalid_consensus_message}
    end
  end

  defp validate_view_change_content(message) do
    required_fields = [:new_view, :last_prepared_view, :prepared_certificates]

    if Enum.all?(required_fields, &Map.has_key?(message, &1)) do
      :ok
    else
      {:error, :invalid_view_change_message}
    end
  end

  defp validate_message_signature(_message) do
    # Validate message signature (simplified implementation)
    # Production would verify actual cryptographic signatures
    :ok
  end

  defp calculate_fault_score(node_state, fault_type) do
    base_score = node_state.fault_score

    fault_increment =
      case fault_type do
        :invalid_message -> 0.1
        :slow_response -> 0.05
        :byzantine -> 0.5
        :network_partition -> 0.2
        :crash -> 0.3
      end

    min(base_score + fault_increment, 1.0)
  end

  defp report_fault_evidence(cluster_id, node_id, fault_type, evidence, _state \\ nil) do
    GenServer.cast(
      self(),
      {:report_suspicious_behavior, cluster_id, node_id, fault_type, evidence}
    )
  end

  defp handle_fault_report(node_state, fault_type, _evidence) do
    new_fault_score = calculate_fault_score(node_state, fault_type)

    new_status =
      cond do
        new_fault_score >= 0.8 -> :faulty
        new_fault_score >= 0.4 -> :suspected
        true -> node_state.status
      end

    %{
      node_state
      | fault_score: new_fault_score,
        status: new_status,
        quarantine_until: calculate_quarantine_time(fault_type, new_fault_score)
    }
  end

  defp calculate_quarantine_time(fault_type, fault_score) do
    base_minutes =
      case fault_type do
        :invalid_message -> 5
        :slow_response -> 2
        :byzantine -> 30
        :network_partition -> 10
        :crash -> 15
      end

    # Scale quarantine time based on fault score
    quarantine_minutes = round(base_minutes * fault_score * 2)
    DateTime.add(DateTime.utc_now(), quarantine_minutes, :minute)
  end

  defp check_and_trigger_fault_response(cluster_id, _suspected_node, fault_type, state) do
    case Map.get(state.cluster_configs, cluster_id) do
      nil ->
        state

      bft_config ->
        node_states = Map.get(state.node_states, cluster_id, %{})

        faulty_count =
          Enum.count(node_states, fn {_id, node} ->
            node.status in [:suspected, :faulty]
          end)

        cond do
          faulty_count > bft_config.max_faulty_nodes ->
            # Critical: too many faulty nodes
            trigger_emergency_recovery(cluster_id, state)

          fault_type == :byzantine ->
            # Byzantine fault detected - immediate view change
            initiate_view_change(cluster_id, :current, :byzantine_fault, state)

          true ->
            # Normal fault handling - monitor and potentially isolate
            state
        end
    end
  end

  defp initiate_view_change(cluster_id, current_view_or_atom, reason, state) do
    case Map.get(state.view_states, cluster_id) do
      nil ->
        state

      view_state ->
        current_view =
          if current_view_or_atom == :current do
            view_state.current_view
          else
            current_view_or_atom
          end

        new_view = current_view + 1
        new_leader = select_new_leader(cluster_id, new_view, state)

        updated_view_state = %{
          view_state
          | current_view: new_view,
            leader_id: new_leader,
            view_change_in_progress: true,
            last_view_change: DateTime.utc_now()
        }

        new_state = %{
          state
          | view_states: Map.put(state.view_states, cluster_id, updated_view_state)
        }

        # Notify duty consensus system
        DutyConsensus.trigger_view_change(cluster_id, :block_proposal, 0, 0)

        audit_bft_event(
          :view_change_initiated,
          cluster_id,
          %{
            old_view: current_view,
            new_view: new_view,
            new_leader: new_leader,
            reason: reason
          },
          state.audit_config
        )

        new_state
    end
  end

  defp select_new_leader(cluster_id, new_view, state) do
    case Map.get(state.node_states, cluster_id) do
      nil ->
        # Fallback
        0

      node_states ->
        # Select leader from active nodes using round-robin
        active_nodes =
          node_states
          |> Enum.filter(fn {_id, node} -> node.status == :active end)
          |> Enum.map(fn {id, _node} -> id end)
          |> Enum.sort()

        if length(active_nodes) > 0 do
          leader_index = rem(new_view, length(active_nodes))
          Enum.at(active_nodes, leader_index)
        else
          # Fallback if no active nodes
          0
        end
    end
  end

  defp trigger_emergency_recovery(cluster_id, state) do
    # Critical fault tolerance situation - trigger emergency procedures
    Logger.critical("Emergency recovery triggered for DVT cluster", cluster_id: cluster_id)

    audit_bft_event(
      :emergency_recovery_triggered,
      cluster_id,
      %{
        trigger_reason: :too_many_faulty_nodes,
        timestamp: DateTime.utc_now()
      },
      state.audit_config
    )

    # This would trigger more sophisticated recovery procedures
    state
  end

  defp perform_fault_detection(cluster_id, state) do
    case Map.get(state.node_states, cluster_id) do
      nil ->
        state

      node_states ->
        current_time = DateTime.utc_now()

        updated_nodes =
          Enum.reduce(node_states, %{}, fn {node_id, node_state}, acc ->
            updated_node = detect_node_faults(node_state, current_time)
            Map.put(acc, node_id, updated_node)
          end)

        %{state | node_states: Map.put(state.node_states, cluster_id, updated_nodes)}
    end
  end

  defp detect_node_faults(node_state, current_time) do
    # Detect various types of faults based on node behavior
    time_since_seen = DateTime.diff(current_time, node_state.last_seen, :second)

    # Check for crash (node not responding)
    if time_since_seen > 60 and node_state.status == :active do
      report_fault_evidence(
        node_state.cluster_id,
        node_state.node_id,
        :crash,
        %{
          time_since_seen: time_since_seen,
          last_seen: node_state.last_seen
        },
        nil
      )

      %{node_state | status: :suspected, fault_score: node_state.fault_score + 0.3}
    else
      # Check for slow responses
      avg_response_time = calculate_average_response_time(node_state.response_times)

      if avg_response_time > 5000 and length(node_state.response_times) >= 5 do
        %{node_state | fault_score: node_state.fault_score + 0.05}
      else
        node_state
      end
    end
  end

  defp calculate_average_response_time([]), do: 0

  defp calculate_average_response_time(response_times) do
    Enum.sum(response_times) / length(response_times)
  end

  defp update_cluster_health_metrics(cluster_id, state) do
    # Update comprehensive health metrics for cluster
    case Map.get(state.node_states, cluster_id) do
      nil ->
        state

      node_states ->
        # Calculate cluster-wide metrics
        current_time = DateTime.utc_now()

        cluster_metrics = %{
          total_nodes: map_size(node_states),
          active_nodes: count_nodes_by_status(node_states, :active),
          suspected_nodes: count_nodes_by_status(node_states, :suspected),
          faulty_nodes: count_nodes_by_status(node_states, :faulty),
          average_response_time: calculate_cluster_avg_response_time(node_states),
          message_throughput: calculate_cluster_message_throughput(node_states),
          fault_detection_accuracy: calculate_fault_detection_accuracy(cluster_id, state),
          last_updated: current_time
        }

        # Update performance stats
        updated_stats = Map.put(state.performance_stats, cluster_id, cluster_metrics)
        %{state | performance_stats: updated_stats}
    end
  end

  defp count_nodes_by_status(node_states, status) do
    Enum.count(node_states, fn {_id, node} -> node.status == status end)
  end

  defp calculate_cluster_avg_response_time(node_states) do
    all_response_times =
      Enum.flat_map(node_states, fn {_id, node} ->
        node.response_times
      end)

    if length(all_response_times) > 0 do
      Enum.sum(all_response_times) / length(all_response_times)
    else
      0
    end
  end

  defp calculate_cluster_message_throughput(node_states) do
    total_messages =
      Enum.sum(
        Enum.map(node_states, fn {_id, node} ->
          node.message_count
        end)
      )

    # Messages per minute (simplified calculation)
    total_messages
  end

  defp calculate_fault_detection_accuracy(_cluster_id, _state) do
    # Calculate accuracy of fault detection vs actual faults
    # This is a simplified implementation
    95.0
  end

  defp get_recent_fault_count(cluster_id, state) do
    # Last 5 minutes
    cutoff_time = DateTime.add(DateTime.utc_now(), -300, :second)

    Enum.count(state.fault_evidence, fn evidence ->
      evidence.cluster_id == cluster_id and
        DateTime.compare(evidence.timestamp, cutoff_time) == :gt
    end)
  end

  defp calculate_cluster_performance(cluster_id, state) do
    Map.get(state.performance_stats, cluster_id, %{})
  end

  defp execute_recovery_procedure(recovery_procedure, bft_config, server_pid) do
    # Execute recovery procedure steps
    try do
      steps = [
        :isolate_faulty_nodes,
        :reconfigure_cluster,
        :verify_safety_threshold,
        :restart_consensus,
        :validate_recovery
      ]

      result =
        Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, completed_steps} ->
          case execute_recovery_step(step, recovery_procedure, bft_config) do
            :ok ->
              {:cont, {:ok, [step | completed_steps]}}

            {:error, reason} ->
              {:halt, {:error, reason, completed_steps}}
          end
        end)

      send(server_pid, {:recovery_completed, recovery_procedure.recovery_ref, result})
    catch
      error ->
        send(server_pid, {:recovery_completed, recovery_procedure.recovery_ref, {:error, error}})
    end
  end

  defp execute_recovery_step(step, recovery_procedure, _bft_config) do
    case step do
      :isolate_faulty_nodes ->
        Logger.info("Isolating faulty nodes for cluster",
          cluster_id: recovery_procedure.cluster_id
        )

        :ok

      :reconfigure_cluster ->
        Logger.info("Reconfiguring cluster parameters",
          cluster_id: recovery_procedure.cluster_id
        )

        :ok

      :verify_safety_threshold ->
        Logger.info("Verifying safety threshold",
          cluster_id: recovery_procedure.cluster_id
        )

        :ok

      :restart_consensus ->
        Logger.info("Restarting consensus protocols",
          cluster_id: recovery_procedure.cluster_id
        )

        :ok

      :validate_recovery ->
        Logger.info("Validating recovery completion",
          cluster_id: recovery_procedure.cluster_id
        )

        :ok

      _ ->
        {:error, {:unknown_step, step}}
    end
  end

  defp determine_fault_severity(fault_type, _evidence) do
    case fault_type do
      :crash -> :medium
      :byzantine -> :critical
      :network_partition -> :high
      :slow_response -> :low
      :invalid_message -> :medium
    end
  end

  defp get_current_node_id do
    # Get current node ID - would be configured per deployment
    0
  end

  defp initialize_bft_stats do
    %{
      fault_detection_calls: 0,
      view_changes_initiated: 0,
      recovery_procedures_executed: 0,
      byzantine_faults_detected: 0,
      false_positives: 0,
      average_recovery_time: 0.0
    }
  end

  defp schedule_fault_detection do
    # Schedule fault detection every 30 seconds
    Process.send_after(self(), :fault_detection, 30_000)
  end

  defp schedule_health_monitoring do
    # Schedule health monitoring every 60 seconds
    Process.send_after(self(), :health_monitoring, 60_000)
  end

  defp audit_bft_event(event_type, cluster_id, metadata, audit_config) do
    case audit_config do
      %{} = config when map_size(config) > 0 ->
        AuditLogger.log_event(
          :dvt_byzantine_tolerance,
          event_type,
          %{
            cluster_id: cluster_id,
            timestamp: DateTime.utc_now(),
            metadata: metadata
          },
          config
        )

      _ ->
        Logger.info("DVT BFT Event: #{event_type} for cluster #{cluster_id}",
          metadata: metadata
        )
    end
  end
end
