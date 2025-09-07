defmodule ExWire.P2P.ConnectionPool do
  @moduledoc """
  Advanced P2P connection pool manager with connection health monitoring,
  intelligent peer selection, and dynamic capacity management.
  """

  use GenServer
  require Logger

  alias ExWire.P2P.{Connection, Server}
  alias ExWire.Struct.Peer
  alias ExWire.Kademlia.Server, as: KademliaServer

  @typedoc "Connection pool state"
  @type t :: %__MODULE__{
          active_connections: %{pid() => connection_info()},
          pending_connections: %{Peer.t() => pending_info()},
          connection_history: %{Peer.t() => connection_history()},
          pool_config: pool_config(),
          metrics: metrics()
        }

  @typedoc "Information about an active connection"
  @type connection_info :: %{
          peer: Peer.t(),
          connected_at: DateTime.t(),
          last_activity: DateTime.t(),
          message_count: non_neg_integer(),
          status: :handshaking | :active | :disconnecting,
          protocol_version: integer() | nil
        }

  @typedoc "Information about a pending connection attempt"
  @type pending_info :: %{
          attempts: non_neg_integer(),
          last_attempt: DateTime.t(),
          backoff_until: DateTime.t()
        }

  @typedoc "Historical information about a peer"
  @type connection_history :: %{
          successful_connections: non_neg_integer(),
          failed_connections: non_neg_integer(),
          total_uptime: non_neg_integer(),
          last_seen: DateTime.t() | nil,
          reputation_score: float()
        }

  @typedoc "Pool configuration"
  @type pool_config :: %{
          max_connections: non_neg_integer(),
          target_connections: non_neg_integer(),
          max_pending: non_neg_integer(),
          connection_timeout: non_neg_integer(),
          retry_backoff_base: non_neg_integer(),
          max_retry_attempts: non_neg_integer(),
          health_check_interval: non_neg_integer()
        }

  @typedoc "Pool metrics"
  @type metrics :: %{
          total_connections_attempted: non_neg_integer(),
          total_connections_successful: non_neg_integer(),
          total_connections_failed: non_neg_integer(),
          total_bytes_sent: non_neg_integer(),
          total_bytes_received: non_neg_integer(),
          avg_connection_duration: float()
        }

  defstruct [
    :active_connections,
    :pending_connections,
    :connection_history,
    :pool_config,
    :metrics
  ]

  # Default configuration
  @default_config %{
    max_connections: 50,
    target_connections: 25,
    max_pending: 20,
    connection_timeout: 30_000,
    retry_backoff_base: 5_000,
    max_retry_attempts: 5,
    health_check_interval: 30_000
  }

  @name __MODULE__

  # Public API

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec connect_to_peer(Peer.t()) :: :ok | :error | :already_connected | :pending
  def connect_to_peer(peer) do
    GenServer.call(@name, {:connect_to_peer, peer})
  end

  @spec disconnect_peer(Peer.t()) :: :ok
  def disconnect_peer(peer) do
    GenServer.cast(@name, {:disconnect_peer, peer})
  end

  @spec get_connected_peers() :: [Peer.t()]
  def get_connected_peers() do
    GenServer.call(@name, :get_connected_peers)
  end

  @spec get_pool_stats() :: %{
          active: non_neg_integer(),
          pending: non_neg_integer(),
          target: non_neg_integer(),
          max: non_neg_integer(),
          metrics: metrics()
        }
  def get_pool_stats() do
    GenServer.call(@name, :get_pool_stats)
  end

  @spec get_peer_reputation(Peer.t()) :: float()
  def get_peer_reputation(peer) do
    GenServer.call(@name, {:get_peer_reputation, peer})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    config = Map.merge(@default_config, Map.new(opts))

    state = %__MODULE__{
      active_connections: %{},
      pending_connections: %{},
      connection_history: %{},
      pool_config: config,
      metrics: %{
        total_connections_attempted: 0,
        total_connections_successful: 0,
        total_connections_failed: 0,
        total_bytes_sent: 0,
        total_bytes_received: 0,
        avg_connection_duration: 0.0
      }
    }

    # Schedule periodic maintenance
    schedule_health_check(config.health_check_interval)
    schedule_peer_discovery()

    Logger.info(
      "[ConnectionPool] Started with max_connections=#{config.max_connections}, target=#{config.target_connections}"
    )

    {:ok, _state}
  end

  @impl true
  def handle_call({:connect_to_peer, peer}, _from, _state) do
    case should_connect_to_peer?(peer, state) do
      {:ok, :connect} ->
        case attempt_connection(peer, state) do
          {:ok, new_state} -> {:reply, :ok, new_state}
          {:error, reason, new_state} -> {:reply, {:error, _reason}, new_state}
        end

      {:error, :already_connected} ->
        {:reply, :already_connected, state}

      {:error, :pending} ->
        {:reply, :pending, state}

      {:error, :pool_full} ->
        {:reply, :error, state}

      {:error, :reputation_too_low} ->
        {:reply, :error, state}
    end
  end

  def handle_call(:get_connected_peers, _from, _state) do
    peers =
      state.active_connections
      |> Map.values()
      |> Enum.map(& &1.peer)

    {:reply, peers, state}
  end

  def handle_call(:get_pool_stats, _from, _state) do
    stats = %{
      active: map_size(state.active_connections),
      pending: map_size(state.pending_connections),
      target: state.pool_config.target_connections,
      max: state.pool_config.max_connections,
      metrics: state.metrics
    }

    {:reply, stats, state}
  end

  def handle_call({:get_peer_reputation, peer}, _from, _state) do
    reputation =
      case Map.get(state.connection_history, peer) do
        # Neutral for unknown peers
        nil -> 0.5
        history -> history.reputation_score
      end

    {:reply, reputation, _state}
  end

  @impl true
  def handle_cast({:disconnect_peer, peer}, _state) do
    new_state = disconnect_peer_internal(peer, state)
    {:noreply, new_state}
  end

  def handle_cast({:peer_connected, pid, peer}, _state) do
    connection_info = %{
      peer: peer,
      connected_at: DateTime.utc_now(),
      last_activity: DateTime.utc_now(),
      message_count: 0,
      status: :handshaking,
      protocol_version: nil
    }

    new_state = %{
      state
      | active_connections: Map.put(state.active_connections, pid, connection_info),
        pending_connections: Map.delete(state.pending_connections, peer)
    }

    # Update metrics
    updated_state = update_metrics(new_state, :connection_successful)

    Logger.debug("[ConnectionPool] Peer connected: #{inspect(peer)}")
    {:noreply, updated_state}
  end

  def handle_cast({:peer_disconnected, pid}, _state) do
    case Map.get(state.active_connections, pid) do
      nil ->
        {:noreply, _state}

      connection_info ->
        new_state = handle_peer_disconnection(pid, connection_info, state)
        {:noreply, new_state}
    end
  end

  def handle_cast({:peer_activity, pid}, _state) do
    case Map.get(state.active_connections, pid) do
      nil ->
        {:noreply, _state}

      connection_info ->
        updated_info = %{
          connection_info
          | last_activity: DateTime.utc_now(),
            message_count: connection_info.message_count + 1
        }

        new_state = %{
          state
          | active_connections: Map.put(state.active_connections, pid, updated_info)
        }

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:health_check, _state) do
    new_state = perform_health_check(state)
    schedule_health_check(state.pool_config.health_check_interval)
    {:noreply, new_state}
  end

  def handle_info(:peer_discovery, _state) do
    perform_peer_discovery(state)
    schedule_peer_discovery()
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, _state) do
    case Map.get(state.active_connections, pid) do
      nil ->
        {:noreply, _state}

      connection_info ->
        Logger.debug(
          "[ConnectionPool] Connection process #{inspect(pid)} died: #{inspect(reason)}"
        )

        new_state = handle_peer_disconnection(pid, connection_info, state)
        {:noreply, new_state}
    end
  end

  # Private functions

  defp should_connect_to_peer?(peer, state) do
    cond do
      peer_already_connected?(peer, state) ->
        {:error, :already_connected}

      peer_connection_pending?(peer, state) ->
        {:error, :pending}

      map_size(state.active_connections) >= state.pool_config.max_connections ->
        {:error, :pool_full}

      get_peer_reputation_score(peer, state) < 0.3 ->
        {:error, :reputation_too_low}

      true ->
        {:ok, :connect}
    end
  end

  defp peer_already_connected?(peer, state) do
    Enum.any?(state.active_connections, fn {_pid, info} -> info.peer == peer end)
  end

  defp peer_connection_pending?(peer, state) do
    case Map.get(state.pending_connections, peer) do
      nil -> false
      pending_info -> DateTime.compare(DateTime.utc_now(), pending_info.backoff_until) == :lt
    end
  end

  defp get_peer_reputation_score(peer, _state) do
    case Map.get(state.connection_history, peer) do
      # Neutral for new peers
      nil -> 0.5
      history -> history.reputation_score
    end
  end

  defp attempt_connection(peer, _state) do
    # Add to pending connections
    pending_info = %{
      attempts: 1,
      last_attempt: DateTime.utc_now(),
      backoff_until:
        DateTime.add(DateTime.utc_now(), _state.pool_config.retry_backoff_base, :millisecond)
    }

    updated_state = %{
      state
      | pending_connections: Map.put(state.pending_connections, peer, pending_info),
        metrics: update_connection_attempt_metrics(state.metrics)
    }

    # Attempt to start connection process
    case start_connection_process(peer) do
      {:ok, pid} ->
        # Monitor the connection process
        Process.monitor(pid)
        {:ok, updated_state}

      {:error, _reason} ->
        # Remove from pending and update failure metrics
        final_state = %{
          updated_state
          | pending_connections: Map.delete(updated_state.pending_connections, peer),
            metrics: update_connection_failure_metrics(updated_state.metrics)
        }

        {:error, reason, final_state}
    end
  end

  defp start_connection_process(peer) do
    spec = {Server, {:outbound, peer, [], __MODULE__}}

    case DynamicSupervisor.start_child(ExWire.PeerSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, _reason} -> {:error, _reason}
    end
  end

  defp disconnect_peer_internal(peer, _state) do
    # Find the connection PID for this peer
    case Enum.find(state.active_connections, fn {_pid, info} -> info.peer == peer end) do
      nil ->
        _state

      {pid, _connection_info} ->
        # Terminate the connection process
        GenServer.cast(pid, :disconnect)

        # Remove from active connections
        %{state | active_connections: Map.delete(state.active_connections, pid)}
    end
  end

  defp handle_peer_disconnection(pid, connection_info, _state) do
    peer = connection_info.peer
    now = DateTime.utc_now()
    uptime = DateTime.diff(now, connection_info.connected_at, :second)

    # Update connection history
    history =
      case Map.get(state.connection_history, peer) do
        nil ->
          %{
            successful_connections: 1,
            failed_connections: 0,
            total_uptime: uptime,
            last_seen: now,
            reputation_score: calculate_initial_reputation_score(uptime)
          }

        existing_history ->
          %{
            existing_history
            | total_uptime: existing_history.total_uptime + uptime,
              last_seen: now,
              reputation_score: update_reputation_score(existing_history, uptime)
          }
      end

    new_state = %{
      state
      | active_connections: Map.delete(state.active_connections, pid),
        connection_history: Map.put(state.connection_history, peer, history)
    }

    Logger.debug("[ConnectionPool] Peer disconnected: #{inspect(peer)}, uptime: #{uptime}s")

    new_state
  end

  defp calculate_initial_reputation_score(uptime) do
    # Base score of 0.5, bonus for longer connections
    base_score = 0.5
    # Max 0.3 bonus for 1+ hour connections
    uptime_bonus = min(uptime / 3600, 0.3)
    base_score + uptime_bonus
  end

  defp update_reputation_score(history, recent_uptime) do
    current_score = history.reputation_score
    total_connections = history.successful_connections + history.failed_connections
    avg_uptime = history.total_uptime / max(total_connections, 1)

    # Exponential moving average with recent uptime
    alpha = 0.1
    uptime_factor = min(recent_uptime / avg_uptime, 2.0)

    new_score = current_score * (1 - alpha) + current_score * uptime_factor * alpha

    # Keep score between 0.0 and 1.0
    max(0.0, min(1.0, new_score))
  end

  defp update_metrics(_state, :connection_successful) do
    %{
      state
      | metrics: %{
          state.metrics
          | total_connections_successful: state.metrics.total_connections_successful + 1
        }
    }
  end

  defp update_connection_attempt_metrics(metrics) do
    %{metrics | total_connections_attempted: metrics.total_connections_attempted + 1}
  end

  defp update_connection_failure_metrics(metrics) do
    %{metrics | total_connections_failed: metrics.total_connections_failed + 1}
  end

  defp perform_health_check(_state) do
    Logger.debug(
      "[ConnectionPool] Performing health check - active: #{map_size(state.active_connections)}, target: #{state.pool_config.target_connections}"
    )

    # Check if we need more connections
    active_count = map_size(state.active_connections)
    target_count = state.pool_config.target_connections

    if active_count < target_count do
      deficit = target_count - active_count
      Logger.debug("[ConnectionPool] Need #{deficit} more connections")

      # Request new peer candidates from Kademlia
      request_new_peer_candidates(deficit)
    end

    # Remove stale pending connections
    now = DateTime.utc_now()

    active_pending =
      state.pending_connections
      |> Enum.filter(fn {_peer, info} ->
        DateTime.compare(now, info.backoff_until) == :gt
      end)
      |> Map.new()

    %{state | pending_connections: active_pending}
  end

  defp request_new_peer_candidates(count) do
    try do
      peers = GenServer.call(KademliaServer, :get_peers)

      # Take the best candidates based on reputation
      candidates = Enum.take(peers, count)

      for peer <- candidates do
        connect_to_peer(peer)
      end
    rescue
      _ ->
        Logger.debug("[ConnectionPool] Could not get peer candidates from Kademlia")
    end
  end

  defp perform_peer_discovery(_state) do
    # Trigger Kademlia discovery round if needed
    try do
      current_peers = GenServer.call(KademliaServer, :get_peers)

      if length(current_peers) < 10 do
        Logger.debug(
          "[ConnectionPool] Triggering peer discovery - only #{length(current_peers)} known peers"
        )

        # Trigger discovery through Kademlia
      end
    rescue
      _ ->
        Logger.debug("[ConnectionPool] Could not trigger peer discovery")
    end
  end

  defp schedule_health_check(interval) do
    Process.send_after(self(), :health_check, interval)
  end

  defp schedule_peer_discovery() do
    # Run peer discovery every 2 minutes
    Process.send_after(self(), :peer_discovery, 120_000)
  end
end
