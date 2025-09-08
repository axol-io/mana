defmodule ExWire.Monitoring.NetworkMonitor do
  @moduledoc """
  Advanced network monitoring system for P2P connections, peer health,
  protocol performance, and network topology analysis.
  """

  use GenServer
  require Logger

  alias ExWire.P2P.{ConnectionPool, PeerReputation}
  alias ExWire.Struct.Peer

  @typedoc "Network monitoring state"
  @type t :: %__MODULE__{
          metrics: network_metrics(),
          peer_stats: %{Peer.t() => peer_stats()},
          topology_info: topology_info(),
          alerts: [alert()],
          config: monitor_config()
        }

  @typedoc "Network-wide metrics"
  @type network_metrics :: %{
          # Connection metrics
          total_peers_ever: non_neg_integer(),
          current_peer_count: non_neg_integer(),
          avg_peer_lifetime: float(),
          connection_churn_rate: float(),

          # Protocol metrics
          total_messages_sent: non_neg_integer(),
          total_messages_received: non_neg_integer(),
          message_loss_rate: float(),
          avg_response_time: float(),

          # Sync metrics
          blocks_received: non_neg_integer(),
          blocks_validated: non_neg_integer(),
          sync_speed_bps: float(),

          # Network health
          network_partition_detected: boolean(),
          consensus_disagreements: non_neg_integer(),
          protocol_violations: non_neg_integer()
        }

  @typedoc "Per-peer statistics"
  @type peer_stats :: %{
          first_seen: DateTime.t(),
          last_seen: DateTime.t(),
          total_uptime: non_neg_integer(),
          message_stats: message_stats(),
          performance_stats: performance_stats(),
          protocol_info: protocol_info()
        }

  @typedoc "Message statistics for a peer"
  @type message_stats :: %{
          sent: non_neg_integer(),
          received: non_neg_integer(),
          failed: non_neg_integer(),
          avg_size: float(),
          types: %{String.t() => non_neg_integer()}
        }

  @typedoc "Performance statistics for a peer"
  @type performance_stats :: %{
          avg_response_time: float(),
          throughput_mbps: float(),
          reliability_score: float(),
          last_performance_check: DateTime.t()
        }

  @typedoc "Protocol information for a peer"
  @type protocol_info :: %{
          version: integer() | nil,
          capabilities: [String.t()],
          client_id: String.t() | nil,
          supported_protocols: [String.t()]
        }

  @typedoc "Network topology information"
  @type topology_info :: %{
          peer_clusters: [[Peer.t()]],
          network_diameter: integer(),
          clustering_coefficient: float(),
          avg_path_length: float(),
          isolated_nodes: [Peer.t()],
          super_nodes: [Peer.t()]
        }

  @typedoc "Network alert"
  @type alert :: %{
          id: String.t(),
          type: alert_type(),
          severity: :info | :warning | :critical,
          message: String.t(),
          timestamp: DateTime.t(),
          acknowledged: boolean(),
          data: map()
        }

  @typedoc "Alert types"
  @type alert_type ::
          :peer_churn_high
          | :network_partition
          | :consensus_disagreement
          | :protocol_violation
          | :performance_degradation
          | :connection_failure_spike
          | :suspicious_peer_behavior
          | :sync_stalled

  @typedoc "Monitor configuration"
  @type monitor_config :: %{
          collection_interval: non_neg_integer(),
          alert_thresholds: %{atom() => number()},
          peer_timeout: non_neg_integer(),
          performance_check_interval: non_neg_integer(),
          topology_analysis_interval: non_neg_integer()
        }

  defstruct [
    :metrics,
    :peer_stats,
    :topology_info,
    :alerts,
    :config
  ]

  # Default configuration
  @default_config %{
    # 30 seconds
    collection_interval: 30_000,
    # 1 minute
    performance_check_interval: 60_000,
    # 5 minutes
    topology_analysis_interval: 300_000,
    # 2 minutes
    peer_timeout: 120_000,
    alert_thresholds: %{
      peer_churn_rate: 0.3,
      message_loss_rate: 0.1,
      # 5 seconds
      avg_response_time: 5000,
      consensus_disagreement_rate: 0.05
    }
  }

  @name __MODULE__

  # Public API

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec get_network_metrics() :: network_metrics()
  def get_network_metrics() do
    GenServer.call(@name, :get_network_metrics)
  end

  @spec get_peer_stats(Peer.t()) :: peer_stats() | nil
  def get_peer_stats(peer) do
    GenServer.call(@name, {:get_peer_stats, peer})
  end

  @spec get_topology_info() :: topology_info()
  def get_topology_info() do
    GenServer.call(@name, :get_topology_info)
  end

  @spec get_active_alerts() :: [alert()]
  def get_active_alerts() do
    GenServer.call(@name, :get_active_alerts)
  end

  @spec acknowledge_alert(String.t()) :: :ok
  def acknowledge_alert(alert_id) do
    GenServer.cast(@name, {:acknowledge_alert, alert_id})
  end

  @spec record_peer_message(Peer.t(), :sent | :received, String.t(), non_neg_integer()) :: :ok
  def record_peer_message(peer, direction, message_type, size) do
    GenServer.cast(@name, {:record_peer_message, peer, direction, message_type, size})
  end

  @spec record_performance_metric(Peer.t(), String.t(), number()) :: :ok
  def record_performance_metric(peer, metric_name, value) do
    GenServer.cast(@name, {:record_performance_metric, peer, metric_name, value})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    config = Map.merge(@default_config, Map.new(opts))

    state = %__MODULE__{
      metrics: initial_network_metrics(),
      peer_stats: %{},
      topology_info: initial_topology_info(),
      alerts: [],
      config: config
    }

    # Schedule periodic tasks
    schedule_metrics_collection(config.collection_interval)
    schedule_performance_check(config.performance_check_interval)
    schedule_topology_analysis(config.topology_analysis_interval)

    Logger.info(
      "[NetworkMonitor] Started with collection interval: #{config.collection_interval}ms"
    )

    {:ok, _state}
  end

  @impl true
  def handle_call(:get_network_metrics, _from, _state) do
    {:reply, state.metrics, state}
  end

  def handle_call({:get_peer_stats, peer}, _from, _state) do
    stats = Map.get(state.peer_stats, peer)
    {:reply, stats, state}
  end

  def handle_call(:get_topology_info, _from, _state) do
    {:reply, state.topology_info, state}
  end

  def handle_call(:get_active_alerts, _from, _state) do
    active_alerts = Enum.filter(state.alerts, &(not &1.acknowledged))
    {:reply, active_alerts, state}
  end

  @impl true
  def handle_cast({:record_peer_message, peer, direction, message_type, size}, _state) do
    new_state = update_peer_message_stats(state, peer, direction, message_type, size)
    {:noreply, new_state}
  end

  def handle_cast({:record_performance_metric, peer, metric_name, value}, _state) do
    new_state = update_peer_performance_stats(state, peer, metric_name, value)
    {:noreply, new_state}
  end

  def handle_cast({:acknowledge_alert, alert_id}, _state) do
    new_alerts =
      Enum.map(state.alerts, fn alert ->
        if alert.id == alert_id do
          %{alert | acknowledged: true}
        else
          alert
        end
      end)

    {:noreply, %{state | alerts: new_alerts}}
  end

  @impl true
  def handle_info(:collect_metrics, _state) do
    new_state = collect_network_metrics(state)
    schedule_metrics_collection(state.config.collection_interval)
    {:noreply, new_state}
  end

  def handle_info(:performance_check, _state) do
    new_state = perform_performance_checks(state)
    schedule_performance_check(state.config.performance_check_interval)
    {:noreply, new_state}
  end

  def handle_info(:topology_analysis, _state) do
    new_state = analyze_network_topology(state)
    schedule_topology_analysis(state.config.topology_analysis_interval)
    {:noreply, new_state}
  end

  # Private functions

  defp initial_network_metrics() do
    %{
      total_peers_ever: 0,
      current_peer_count: 0,
      avg_peer_lifetime: 0.0,
      connection_churn_rate: 0.0,
      total_messages_sent: 0,
      total_messages_received: 0,
      message_loss_rate: 0.0,
      avg_response_time: 0.0,
      blocks_received: 0,
      blocks_validated: 0,
      sync_speed_bps: 0.0,
      network_partition_detected: false,
      consensus_disagreements: 0,
      protocol_violations: 0
    }
  end

  defp initial_topology_info() do
    %{
      peer_clusters: [],
      network_diameter: 0,
      clustering_coefficient: 0.0,
      avg_path_length: 0.0,
      isolated_nodes: [],
      super_nodes: []
    }
  end

  defp collect_network_metrics(_state) do
    # Get current connection pool stats
    pool_stats = ConnectionPool.get_pool_stats()

    # Update network metrics
    new_metrics = %{
      state.metrics
      | current_peer_count: pool_stats.active,
        total_peers_ever: max(state.metrics.total_peers_ever, pool_stats.active)
    }

    # Calculate churn rate
    churn_rate = calculate_connection_churn_rate(state.peer_stats)
    updated_metrics = %{new_metrics | connection_churn_rate: churn_rate}

    # Check for alerts
    new_alerts = check_metric_alerts(state.alerts, updated_metrics, state.config.alert_thresholds)

    %{state | metrics: updated_metrics, alerts: new_alerts}
  end

  defp update_peer_message_stats(_state, peer, direction, message_type, size) do
    now = DateTime.utc_now()

    # Get or create peer stats
    peer_stats =
      Map.get(state.peer_stats, peer, %{
        first_seen: now,
        last_seen: now,
        total_uptime: 0,
        message_stats: %{
          sent: 0,
          received: 0,
          failed: 0,
          avg_size: 0.0,
          types: %{}
        },
        performance_stats: %{
          avg_response_time: 0.0,
          throughput_mbps: 0.0,
          reliability_score: 1.0,
          last_performance_check: now
        },
        protocol_info: %{
          version: nil,
          capabilities: [],
          client_id: nil,
          supported_protocols: []
        }
      })

    # Update message stats
    message_stats = peer_stats.message_stats

    updated_message_stats =
      case direction do
        :sent ->
          %{
            message_stats
            | sent: message_stats.sent + 1,
              avg_size:
                calculate_avg_size(
                  message_stats.avg_size,
                  message_stats.sent + message_stats.received,
                  size
                ),
              types: Map.update(message_stats.types, message_type, 1, &(&1 + 1))
          }

        :received ->
          %{
            message_stats
            | received: message_stats.received + 1,
              avg_size:
                calculate_avg_size(
                  message_stats.avg_size,
                  message_stats.sent + message_stats.received,
                  size
                ),
              types: Map.update(message_stats.types, message_type, 1, &(&1 + 1))
          }
      end

    updated_peer_stats = %{peer_stats | message_stats: updated_message_stats, last_seen: now}

    # Update global message counters
    new_metrics =
      case direction do
        :sent ->
          %{state.metrics | total_messages_sent: _state.metrics.total_messages_sent + 1}

        :received ->
          %{state.metrics | total_messages_received: state.metrics.total_messages_received + 1}
      end

    %{
      state
      | peer_stats: Map.put(state.peer_stats, peer, updated_peer_stats),
        metrics: new_metrics
    }
  end

  defp update_peer_performance_stats(_state, peer, metric_name, value) do
    now = DateTime.utc_now()

    case Map.get(state.peer_stats, peer) do
      # Ignore metrics for unknown peers
      nil ->
        _state

      peer_stats ->
        performance_stats = peer_stats.performance_stats

        updated_performance_stats =
          case metric_name do
            "response_time" ->
              new_avg =
                if performance_stats.avg_response_time > 0 do
                  performance_stats.avg_response_time * 0.9 + value * 0.1
                else
                  value
                end

              %{performance_stats | avg_response_time: new_avg, last_performance_check: now}

            "throughput" ->
              %{performance_stats | throughput_mbps: value, last_performance_check: now}

            "reliability" ->
              %{performance_stats | reliability_score: value, last_performance_check: now}

            _ ->
              performance_stats
          end

        updated_peer_stats = %{peer_stats | performance_stats: updated_performance_stats}

        %{state | peer_stats: Map.put(state.peer_stats, peer, updated_peer_stats)}
    end
  end

  defp perform_performance_checks(_state) do
    Logger.debug(
      "[NetworkMonitor] Performing performance checks on #{map_size(state.peer_stats)} peers"
    )

    # Update global average response time
    avg_response_time = calculate_global_avg_response_time(state.peer_stats)
    new_metrics = %{state.metrics | avg_response_time: avg_response_time}

    # Check for performance alerts
    new_alerts =
      check_performance_alerts(state.alerts, state.peer_stats, state.config.alert_thresholds)

    %{state | metrics: new_metrics, alerts: new_alerts}
  end

  defp analyze_network_topology(_state) do
    Logger.debug("[NetworkMonitor] Analyzing network topology")

    connected_peers = ConnectionPool.get_connected_peers()

    # Basic topology analysis
    topology_info = %{
      state.topology_info
      | peer_clusters: identify_peer_clusters(connected_peers),
        isolated_nodes: identify_isolated_nodes(connected_peers),
        super_nodes: identify_super_nodes(state.peer_stats)
    }

    %{state | topology_info: topology_info}
  end

  defp calculate_connection_churn_rate(peer_stats) do
    if map_size(peer_stats) == 0 do
      0.0
    else
      now = DateTime.utc_now()

      recent_disconnections =
        Enum.count(peer_stats, fn {_peer, stats} ->
          # 5 minutes
          DateTime.diff(now, stats.last_seen, :second) < 300
        end)

      recent_disconnections / max(1, map_size(peer_stats))
    end
  end

  defp calculate_avg_size(current_avg, message_count, new_size) do
    if message_count > 0 do
      (current_avg * message_count + new_size) / (message_count + 1)
    else
      new_size
    end
  end

  defp calculate_global_avg_response_time(peer_stats) do
    response_times =
      peer_stats
      |> Map.values()
      |> Enum.map(& &1.performance_stats.avg_response_time)
      |> Enum.filter(&(&1 > 0))

    if length(response_times) > 0 do
      Enum.sum(response_times) / length(response_times)
    else
      0.0
    end
  end

  defp check_metric_alerts(current_alerts, metrics, thresholds) do
    new_alerts = []

    # Check churn rate
    new_alerts =
      if metrics.connection_churn_rate > Map.get(thresholds, :peer_churn_rate, 0.3) do
        [
          create_alert(
            :peer_churn_high,
            :warning,
            "High peer churn rate detected: #{Float.round(metrics.connection_churn_rate * 100, 1)}%",
            %{churn_rate: metrics.connection_churn_rate}
          )
          | new_alerts
        ]
      else
        new_alerts
      end

    # Check average response time
    new_alerts =
      if metrics.avg_response_time > Map.get(thresholds, :avg_response_time, 5000) do
        [
          create_alert(
            :performance_degradation,
            :warning,
            "Network response time degraded: #{Float.round(metrics.avg_response_time, 1)}ms",
            %{avg_response_time: metrics.avg_response_time}
          )
          | new_alerts
        ]
      else
        new_alerts
      end

    current_alerts ++ new_alerts
  end

  defp check_performance_alerts(current_alerts, peer_stats, thresholds) do
    # Check for peers with consistently poor performance
    poor_performers =
      peer_stats
      |> Enum.filter(fn {_peer, stats} ->
        stats.performance_stats.avg_response_time > Map.get(thresholds, :avg_response_time, 5000) or
          stats.performance_stats.reliability_score < 0.5
      end)
      |> Enum.map(fn {peer, _stats} -> peer end)

    if length(poor_performers) > 0 do
      alert =
        create_alert(
          :performance_degradation,
          :info,
          "#{length(poor_performers)} peer(s) showing poor performance",
          %{poor_performers: poor_performers}
        )

      [alert | current_alerts]
    else
      current_alerts
    end
  end

  defp identify_peer_clusters(peers) do
    # Simple clustering based on peer connections (would need more sophisticated algorithm in production)
    [peers]
  end

  defp identify_isolated_nodes(peers) do
    # For now, return empty list (would implement based on connection patterns)
    []
  end

  defp identify_super_nodes(peer_stats) do
    # Identify nodes with high message throughput or many connections
    peer_stats
    |> Enum.filter(fn {_peer, stats} ->
      total_messages = stats.message_stats.sent + stats.message_stats.received
      # Threshold for super node
      total_messages > 1000
    end)
    |> Enum.map(fn {peer, _stats} -> peer end)
  end

  defp create_alert(type, severity, message, data) do
    %{
      id: generate_alert_id(),
      type: type,
      severity: severity,
      message: message,
      timestamp: DateTime.utc_now(),
      acknowledged: false,
      data: data
    }
  end

  defp generate_alert_id() do
    :crypto.strong_rand_bytes(8) |> Base.encode16()
  end

  defp schedule_metrics_collection(interval) do
    Process.send_after(self(), :collect_metrics, interval)
  end

  defp schedule_performance_check(interval) do
    Process.send_after(self(), :performance_check, interval)
  end

  defp schedule_topology_analysis(interval) do
    Process.send_after(self(), :topology_analysis, interval)
  end
end
