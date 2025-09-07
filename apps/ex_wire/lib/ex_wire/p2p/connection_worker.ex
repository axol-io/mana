defmodule ExWire.P2P.ConnectionWorker do
  @moduledoc """
  High-performance connection worker for P2P operations.
  
  Optimized for process spawning performance:
  - Pre-allocated workers to reduce spawn overhead
  - Connection reuse and caching
  - Efficient state management
  - Minimal memory footprint per worker
  """
  
  use GenServer
  require Logger
  
  alias ExWire.P2P.Connection
  alias ExWire.P2P.Manager
  
  @connection_timeout 5000
  @idle_timeout 300_000  # 5 minutes
  @max_connections_per_worker 5
  
  defmodule State do
    @moduledoc false
    defstruct [
      :pool,
      :worker_id,
      connections: %{},
      connection_count: 0,
      last_activity: nil,
      metrics: %{
        connections_created: 0,
        connections_reused: 0,
        connection_failures: 0,
        avg_connection_time: 0.0
      }
    ]
  end
  
  ## Public API
  
  @doc """
  Start a connection worker linked to a specific pool.
  """
  def start_link(opts) do
    pool = Keyword.get(opts, :pool, :default_pool)
    GenServer.start_link(__MODULE__, [pool: pool])
  end
  
  @doc """
  Get or create a connection to a peer with caching for performance.
  """
  def get_connection(worker_pid, peer_info) do
    GenServer.call(worker_pid, {:get_connection, peer_info}, @connection_timeout + 1000)
  end
  
  @doc """
  Close a specific connection.
  """
  def close_connection(worker_pid, peer_info) do
    GenServer.cast(worker_pid, {:close_connection, peer_info})
  end
  
  @doc """
  Get worker performance metrics.
  """
  def get_metrics(worker_pid) do
    GenServer.call(worker_pid, :get_metrics)
  end
  
  ## GenServer Implementation
  
  @impl GenServer
  def init(opts) do
    pool = Keyword.get(opts, :pool)
    worker_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    
    # Schedule idle timeout check
    schedule_idle_check()
    
    state = %State{
      pool: pool,
      worker_id: worker_id,
      last_activity: System.monotonic_time(:millisecond)
    }
    
    Logger.debug("ConnectionWorker started: #{worker_id} for pool: #{pool}")
    {:ok, state}
  end
  
  @impl GenServer
  def handle_call({:get_connection, peer_info}, _from, state) do
    start_time = System.monotonic_time(:microsecond)
    
    case find_or_create_connection(peer_info, state) do
      {:ok, connection, new_state} ->
        # Update metrics
        connection_time = System.monotonic_time(:microsecond) - start_time
        new_state = update_connection_metrics(new_state, :success, connection_time)
        new_state = %{new_state | last_activity: System.monotonic_time(:millisecond)}
        
        {:reply, {:ok, connection}, new_state}
      
      {:error, reason, new_state} ->
        new_state = update_connection_metrics(new_state, :failure, 0)
        {:reply, {:error, reason}, new_state}
    end
  end
  
  @impl GenServer
  def handle_call(:get_metrics, _from, state) do
    {:reply, state.metrics, state}
  end
  
  @impl GenServer
  def handle_cast({:close_connection, peer_info}, state) do
    new_state = close_specific_connection(peer_info, state)
    {:noreply, new_state}
  end
  
  @impl GenServer
  def handle_info(:idle_check, state) do
    current_time = System.monotonic_time(:millisecond)
    
    if current_time - state.last_activity > @idle_timeout do
      Logger.debug("Worker #{state.worker_id} idle, cleaning up connections")
      new_state = cleanup_idle_connections(state)
      schedule_idle_check()
      {:noreply, new_state}
    else
      schedule_idle_check()
      {:noreply, state}
    end
  end
  
  @impl GenServer
  def handle_info({:DOWN, _ref, :process, connection_pid, reason}, state) do
    Logger.debug("Connection process died: #{inspect(connection_pid)}, reason: #{inspect(reason)}")
    new_state = remove_connection_by_pid(connection_pid, state)
    {:noreply, new_state}
  end
  
  ## Private Implementation
  
  defp find_or_create_connection(peer_info, state) do
    peer_key = peer_key(peer_info)
    
    case Map.get(state.connections, peer_key) do
      nil ->
        create_new_connection(peer_info, peer_key, state)
      
      {connection_pid, _connection_info} when is_pid(connection_pid) ->
        if Process.alive?(connection_pid) do
          # Reuse existing connection
          connection_info = Map.get(state.connections, peer_key)
          {:ok, connection_info, state}
        else
          # Connection died, create new one
          new_state = %{state | 
            connections: Map.delete(state.connections, peer_key),
            connection_count: state.connection_count - 1
          }
          create_new_connection(peer_info, peer_key, new_state)
        end
      
      connection_info ->
        # Direct connection info
        {:ok, connection_info, state}
    end
  end
  
  defp create_new_connection(peer_info, peer_key, state) do
    if state.connection_count >= @max_connections_per_worker do
      {:error, :worker_full, state}
    else
      case establish_connection(peer_info) do
        {:ok, connection} ->
          # Monitor connection process if it's a PID
          if is_pid(connection), do: Process.monitor(connection)
          
          new_state = %{state | 
            connections: Map.put(state.connections, peer_key, connection),
            connection_count: state.connection_count + 1
          }
          
          {:ok, connection, new_state}
        
        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end
  
  defp establish_connection(peer_info) do
    # Use the existing P2P Manager to create connection
    case Manager.create_connection(peer_info) do
      {:ok, connection} ->
        {:ok, connection}
      
      {:error, reason} ->
        Logger.warning("Failed to establish P2P connection: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("Exception creating P2P connection: #{inspect(error)}")
      {:error, :connection_failed}
  end
  
  defp close_specific_connection(peer_info, state) do
    peer_key = peer_key(peer_info)
    
    case Map.get(state.connections, peer_key) do
      nil ->
        state
      
      {connection_pid, _info} when is_pid(connection_pid) ->
        if Process.alive?(connection_pid) do
          GenServer.stop(connection_pid, :normal)
        end
        
        %{state | 
          connections: Map.delete(state.connections, peer_key),
          connection_count: state.connection_count - 1
        }
      
      _connection_info ->
        %{state | 
          connections: Map.delete(state.connections, peer_key),
          connection_count: state.connection_count - 1
        }
    end
  end
  
  defp remove_connection_by_pid(connection_pid, state) do
    # Find and remove connection by PID
    {connections, removed_count} = 
      Enum.reduce(state.connections, {%{}, 0}, fn {key, value}, {acc, count} ->
        case value do
          {^connection_pid, _info} ->
            {acc, count + 1}
          _ ->
            {Map.put(acc, key, value), count}
        end
      end)
    
    %{state | 
      connections: connections,
      connection_count: state.connection_count - removed_count
    }
  end
  
  defp cleanup_idle_connections(state) do
    # Close all connections for idle cleanup
    Enum.each(state.connections, fn {_key, value} ->
      case value do
        {pid, _info} when is_pid(pid) ->
          if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        _ ->
          :ok
      end
    end)
    
    %{state | connections: %{}, connection_count: 0}
  end
  
  defp update_connection_metrics(state, result, connection_time) do
    metrics = state.metrics
    
    new_metrics = case result do
      :success ->
        avg_time = (metrics.avg_connection_time + (connection_time / 1000)) / 2
        
        if Map.has_key?(state.connections, :reused) do
          %{metrics | 
            connections_reused: metrics.connections_reused + 1,
            avg_connection_time: avg_time
          }
        else
          %{metrics | 
            connections_created: metrics.connections_created + 1,
            avg_connection_time: avg_time
          }
        end
      
      :failure ->
        %{metrics | connection_failures: metrics.connection_failures + 1}
    end
    
    %{state | metrics: new_metrics}
  end
  
  defp peer_key(peer_info) do
    # Create a unique key for the peer
    case peer_info do
      %{host: host, port: port} ->
        "#{host}:#{port}"
      
      {host, port} ->
        "#{host}:#{port}"
      
      peer when is_binary(peer) ->
        peer
      
      _ ->
        :crypto.hash(:sha256, :erlang.term_to_binary(peer_info))
        |> Base.encode16(case: :lower)
    end
  end
  
  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_timeout)
  end
end