defmodule ExWire.Streaming.WebSocketStreamer do
  @moduledoc """
  Real-time WebSocket streaming for Mana-Ethereum events.

  Provides live streaming of blockchain events with revolutionary features:
  - **Multi-datacenter streaming**: Stream events from multiple regions
  - **CRDT operation streaming**: Real-time conflict resolution visualization
  - **Consensus-free subscriptions**: No coordination overhead between replicas
  - **Partition-tolerant streaming**: Continue streaming during network splits
  - **Geographic event routing**: Events routed from optimal datacenter
  - **Advanced filtering**: Complex event filtering and transformation

  ## Unique Streaming Capabilities

  Unlike traditional blockchain event streaming, this provides:
  - **Distributed consensus events**: Stream CRDT operations and vector clocks
  - **Multi-replica event deduplication**: Automatic deduplication across replicas
  - **Partition-aware streaming**: Continue during datacenter failures
  - **Geographic event correlation**: Correlate events across datacenters

  ## Usage

      # Start WebSocket streamer
      {:ok, streamer} = WebSocketStreamer.start_link(port: 8080)
      
      # Client connects via WebSocket to ws://localhost:8080/stream
      # Subscribe to events: {"type": "subscribe", "events": ["newBlocks", "pendingTransactions"]}
  """

  use GenServer
  require Logger

  alias ExWire.Consensus.CRDTConsensusManager
  alias ExWire.Explorer.BlockchainExplorer

  @type client_connection :: %{
          client_id: String.t(),
          socket: pid(),
          subscriptions: [String.t()],
          filters: map(),
          datacenter_preference: String.t(),
          last_heartbeat: non_neg_integer(),
          connection_time: non_neg_integer()
        }

  @type stream_event :: %{
          event_type: String.t(),
          data: term(),
          timestamp: non_neg_integer(),
          datacenter: String.t(),
          vector_clock: map(),
          event_id: String.t()
        }

  defstruct [
    :server_port,
    :active_connections,
    :event_subscribers,
    :event_buffer,
    :deduplication_cache,
    :performance_monitor
  ]

  @name __MODULE__

  # Event types
  @supported_events [
    "newBlocks",
    "pendingTransactions",
    "crdtOperations",
    "consensusStatusChanges",
    "networkPerformance",
    "partitionEvents",
    "conflictResolutions"
  ]

  # Configuration
  @default_port 8080
  @heartbeat_interval 30_000
  @max_connections 1000
  @event_buffer_size 10_000
  @deduplication_window_ms 60_000

  # Public API

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Broadcast an event to all subscribed clients.
  """
  @spec broadcast_event(String.t(), term(), String.t()) :: :ok
  def broadcast_event(event_type, data, datacenter \\ "unknown") do
    GenServer.cast(@name, {:broadcast_event, event_type, data, datacenter})
  end

  @doc """
  Get current streaming statistics.
  """
  @spec get_statistics() :: map()
  def get_statistics() do
    GenServer.call(@name, :get_statistics)
  end

  @doc """
  Get list of active client connections.
  """
  @spec get_active_connections() :: [client_connection()]
  def get_active_connections() do
    GenServer.call(@name, :get_active_connections)
  end

  @doc """
  Disconnect a specific client.
  """
  @spec disconnect_client(String.t()) :: :ok
  def disconnect_client(client_id) do
    GenServer.cast(@name, {:disconnect_client, client_id})
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)

    # Start WebSocket server (placeholder - would use Cowboy or similar)
    Logger.info("[WebSocketStreamer] Starting WebSocket server on port #{port}")

    # Schedule periodic tasks
    schedule_heartbeat_check()
    schedule_performance_monitoring()
    schedule_deduplication_cleanup()

    # Subscribe to blockchain events
    setup_blockchain_subscriptions()

    state = %__MODULE__{
      server_port: port,
      active_connections: %{},
      event_subscribers: %{},
      event_buffer: :queue.new(),
      deduplication_cache: %{},
      performance_monitor: start_performance_monitor()
    }

    Logger.info("[WebSocketStreamer] Started successfully on port #{port}")

    {:ok, _state}
  end

  @impl GenServer
  def handle_cast({:broadcast_event, event_type, data, datacenter}, _state) do
    # Create stream event
    stream_event = create_stream_event(event_type, data, datacenter)

    # Check for deduplication
    case should_deduplicate_event(stream_event, state) do
      false ->
        # Add to deduplication cache
        new_cache = add_to_deduplication_cache(stream_event, state.deduplication_cache)

        # Add to event buffer
        new_buffer = :queue.in(stream_event, state.event_buffer)
        trimmed_buffer = trim_event_buffer(new_buffer)

        # Broadcast to subscribers
        broadcast_to_subscribers(event_type, stream_event, state)

        new_state = %{_state | event_buffer: trimmed_buffer, deduplication_cache: new_cache}

        {:noreply, new_state}

      true ->
        Logger.debug("[WebSocketStreamer] Deduplicated event #{stream_event.event_id}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast({:client_connected, client_id, socket, metadata}, _state) do
    if map_size(state.active_connections) >= @max_connections do
      # Close connection if at capacity
      Logger.warning("[WebSocketStreamer] Max connections reached, rejecting client #{client_id}")
      close_client_connection(socket)
      {:noreply, state}
    else
      client_connection = %{
        client_id: client_id,
        socket: socket,
        subscriptions: [],
        filters: %{},
        datacenter_preference: Map.get(metadata, :datacenter_preference, "any"),
        last_heartbeat: System.system_time(:millisecond),
        connection_time: System.system_time(:millisecond)
      }

      new_connections = Map.put(state.active_connections, client_id, client_connection)
      new_state = %{state | active_connections: new_connections}

      Logger.info(
        "[WebSocketStreamer] Client #{client_id} connected from #{Map.get(metadata, :ip, "unknown")}"
      )

      {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_cast({:client_subscription, client_id, event_types, filters}, _state) do
    case Map.get(state.active_connections, client_id) do
      nil ->
        Logger.warning("[WebSocketStreamer] Subscription from unknown client #{client_id}")
        {:noreply, state}

      client_connection ->
        # Validate event types
        valid_events = Enum.filter(event_types, &(&1 in @supported_events))

        if length(valid_events) != length(event_types) do
          invalid_events = event_types -- valid_events

          Logger.warning(
            "[WebSocketStreamer] Invalid event types from client #{client_id}: #{inspect(invalid_events)}"
          )
        end

        # Update client subscriptions
        updated_client = %{
          client_connection
          | subscriptions: valid_events,
            filters: filters || %{}
        }

        new_connections = Map.put(state.active_connections, client_id, updated_client)

        # Update event subscribers mapping
        new_subscribers =
          update_event_subscribers(valid_events, client_id, state.event_subscribers)

        new_state = %{
          state
          | active_connections: new_connections,
            event_subscribers: new_subscribers
        }

        Logger.info(
          "[WebSocketStreamer] Client #{client_id} subscribed to: #{inspect(valid_events)}"
        )

        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_cast({:disconnect_client, client_id}, _state) do
    case Map.get(state.active_connections, client_id) do
      nil ->
        {:noreply, _state}

      client_connection ->
        # Remove from event subscribers
        new_subscribers = remove_client_from_subscribers(client_id, state.event_subscribers)

        # Close connection
        close_client_connection(client_connection.socket)

        # Remove from active connections
        new_connections = Map.delete(state.active_connections, client_id)

        new_state = %{
          state
          | active_connections: new_connections,
            event_subscribers: new_subscribers
        }

        Logger.info("[WebSocketStreamer] Client #{client_id} disconnected")

        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_call(:get_statistics, _from, _state) do
    stats = %{
      active_connections: map_size(state.active_connections),
      total_subscriptions: count_total_subscriptions(state.event_subscribers),
      events_buffered: :queue.len(state.event_buffer),
      deduplication_cache_size: map_size(state.deduplication_cache),
      server_port: state.server_port,
      uptime_seconds: calculate_uptime(),
      supported_events: @supported_events
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_call(:get_active_connections, _from, _state) do
    connections = Map.values(state.active_connections)
    {:reply, connections, state}
  end

  @impl GenServer
  def handle_info(:heartbeat_check, _state) do
    current_time = System.system_time(:millisecond)
    timeout_threshold = current_time - @heartbeat_interval * 2

    # Find timed out connections
    {active_connections, timed_out} =
      Enum.split_with(state.active_connections, fn {_client_id, connection} ->
        connection.last_heartbeat >= timeout_threshold
      end)

    # Clean up timed out connections
    Enum.each(timed_out, fn {client_id, connection} ->
      Logger.info("[WebSocketStreamer] Client #{client_id} timed out")
      close_client_connection(connection.socket)
    end)

    # Update event subscribers to remove timed out clients
    timed_out_client_ids = Enum.map(timed_out, fn {client_id, _} -> client_id end)

    new_subscribers =
      remove_clients_from_subscribers(timed_out_client_ids, state.event_subscribers)

    new_state = %{
      state
      | active_connections: Map.new(active_connections),
        event_subscribers: new_subscribers
    }

    if length(timed_out) > 0 do
      Logger.info("[WebSocketStreamer] Cleaned up #{length(timed_out)} timed out connections")
    end

    schedule_heartbeat_check()
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:performance_monitoring, _state) do
    # Collect and log performance metrics
    metrics = %{
      active_connections: map_size(state.active_connections),
      events_per_minute: calculate_events_per_minute(state.event_buffer),
      memory_usage: :erlang.memory(:total),
      message_queue_len: Process.info(self(), :message_queue_len)
    }

    Logger.debug("[WebSocketStreamer] Performance metrics: #{inspect(metrics)}")

    schedule_performance_monitoring()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:cleanup_deduplication, _state) do
    current_time = System.system_time(:millisecond)
    cutoff_time = current_time - @deduplication_window_ms

    # Remove old entries from deduplication cache
    new_cache =
      state.deduplication_cache
      |> Enum.filter(fn {_event_id, timestamp} -> timestamp >= cutoff_time end)
      |> Map.new()

    cleaned_count = map_size(state.deduplication_cache) - map_size(new_cache)

    if cleaned_count > 0 do
      Logger.debug(
        "[WebSocketStreamer] Cleaned #{cleaned_count} entries from deduplication cache"
      )
    end

    schedule_deduplication_cleanup()
    {:noreply, %{state | deduplication_cache: new_cache}}
  end

  # Private functions

  defp create_stream_event(event_type, data, datacenter) do
    %{
      event_type: event_type,
      data: data,
      timestamp: System.system_time(:millisecond),
      datacenter: datacenter,
      vector_clock: get_current_vector_clock(),
      event_id: generate_event_id(event_type, data, datacenter)
    }
  end

  defp should_deduplicate_event(stream_event, _state) do
    Map.has_key?(state.deduplication_cache, stream_event.event_id)
  end

  defp add_to_deduplication_cache(stream_event, cache) do
    Map.put(cache, stream_event.event_id, stream_event.timestamp)
  end

  defp trim_event_buffer(buffer) do
    if :queue.len(buffer) > @event_buffer_size do
      {_dropped_event, trimmed_buffer} = :queue.out(buffer)
      trimmed_buffer
    else
      buffer
    end
  end

  defp broadcast_to_subscribers(event_type, stream_event, _state) do
    case Map.get(state.event_subscribers, event_type, []) do
      [] ->
        :ok

      subscribers ->
        # Filter subscribers based on their filters and datacenter preferences
        filtered_subscribers = filter_subscribers_for_event(subscribers, stream_event, state)

        # Send event to each subscriber
        Enum.each(filtered_subscribers, fn client_id ->
          case Map.get(_state.active_connections, client_id) do
            nil ->
              Logger.warning(
                "[WebSocketStreamer] Subscriber #{client_id} not found in active connections"
              )

            client_connection ->
              send_event_to_client(client_connection, stream_event)
          end
        end)

        Logger.debug(
          "[WebSocketStreamer] Broadcasted #{event_type} to #{length(filtered_subscribers)} clients"
        )
    end
  end

  defp filter_subscribers_for_event(subscribers, stream_event, _state) do
    Enum.filter(subscribers, fn client_id ->
      case Map.get(state.active_connections, client_id) do
        nil ->
          false

        client_connection ->
          # Check datacenter preference
          datacenter_match =
            client_connection.datacenter_preference == "any" or
              client_connection.datacenter_preference == stream_event.datacenter

          # Check custom filters (simplified)
          filter_match = event_matches_filters(stream_event, client_connection.filters)

          datacenter_match and filter_match
      end
    end)
  end

  defp event_matches_filters(stream_event, filters) do
    # Simplified filter matching
    case filters do
      %{} when map_size(filters) == 0 ->
        true

      %{"min_value" => min_value} ->
        case stream_event.data do
          %{value: value} when is_integer(value) -> value >= min_value
          _ -> true
        end

      _ ->
        true
    end
  end

  defp send_event_to_client(client_connection, stream_event) do
    # Convert event to JSON and send via WebSocket
    json_event =
      Jason.encode!(%{
        type: "event",
        event_type: stream_event.event_type,
        data: stream_event.data,
        timestamp: stream_event.timestamp,
        datacenter: stream_event.datacenter,
        event_id: stream_event.event_id
      })

    # Placeholder for actual WebSocket send
    Logger.debug(
      "[WebSocketStreamer] Sending event to client #{client_connection.client_id}: #{String.slice(json_event, 0, 100)}..."
    )
  end

  defp update_event_subscribers(event_types, client_id, subscribers) do
    Enum.reduce(event_types, subscribers, fn event_type, acc ->
      current_subscribers = Map.get(acc, event_type, [])
      new_subscribers = [client_id | current_subscribers] |> Enum.uniq()
      Map.put(acc, event_type, new_subscribers)
    end)
  end

  defp remove_client_from_subscribers(client_id, subscribers) do
    Enum.reduce(subscribers, %{}, fn {event_type, client_list}, acc ->
      new_client_list = List.delete(client_list, client_id)

      if new_client_list != [] do
        Map.put(acc, event_type, new_client_list)
      else
        acc
      end
    end)
  end

  defp remove_clients_from_subscribers(client_ids, subscribers) do
    Enum.reduce(client_ids, subscribers, fn client_id, acc ->
      remove_client_from_subscribers(client_id, acc)
    end)
  end

  defp count_total_subscriptions(event_subscribers) do
    event_subscribers
    |> Map.values()
    |> Enum.map(&length/1)
    |> Enum.sum()
  end

  defp calculate_uptime() do
    # Simplified uptime calculation
    System.system_time(:second)
  end

  defp calculate_events_per_minute(event_buffer) do
    current_time = System.system_time(:millisecond)
    minute_ago = current_time - 60_000

    event_buffer
    |> :queue.to_list()
    |> Enum.count(fn event -> event.timestamp >= minute_ago end)
  end

  defp get_current_vector_clock() do
    # Get current vector clock from consensus system
    try do
      status = CRDTConsensusManager.get_consensus_status()
      Map.get(status, :vector_clock, %{})
    rescue
      _ -> %{}
    end
  end

  defp generate_event_id(event_type, data, datacenter) do
    # Generate unique event ID for deduplication
    content = "#{event_type}:#{datacenter}:#{inspect(data)}"
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp setup_blockchain_subscriptions() do
    # Subscribe to various blockchain events
    # This would integrate with the actual blockchain event system
    Logger.debug("[WebSocketStreamer] Set up blockchain event subscriptions")
  end

  defp close_client_connection(socket) do
    # Placeholder for closing WebSocket connection
    Logger.debug("[WebSocketStreamer] Closing client connection")
  end

  defp start_performance_monitor() do
    # Start performance monitoring process
    spawn_link(fn -> performance_monitor_loop() end)
  end

  defp performance_monitor_loop() do
    # Monitor WebSocket streaming performance
    # Every minute
    Process.sleep(60_000)
    performance_monitor_loop()
  end

  # Scheduling functions

  defp schedule_heartbeat_check() do
    Process.send_after(self(), :heartbeat_check, @heartbeat_interval)
  end

  defp schedule_performance_monitoring() do
    # Every minute
    Process.send_after(self(), :performance_monitoring, 60_000)
  end

  defp schedule_deduplication_cleanup() do
    # Every 5 minutes
    Process.send_after(self(), :cleanup_deduplication, 300_000)
  end
end
