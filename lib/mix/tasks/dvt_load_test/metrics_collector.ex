defmodule Mix.Tasks.DvtLoadTest.MetricsCollector do
  @moduledoc """
  Metrics collection for DVT load testing.
  
  Collects and aggregates performance metrics during load testing
  including latency, throughput, error rates, and system resources.
  """

  use GenServer
  require Logger

  alias ExWire.DVT.{P2PProtocol, PartitionDetector, GossipSubOptimizer}

  defstruct [
    :cluster_id,
    :start_time,
    :metrics_timer,
    :collection_interval,
    :metrics_history,
    :current_metrics
  ]

  @collection_interval 1_000  # Collect metrics every second

  ## Public API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  def get_metrics(pid) do
    GenServer.call(pid, :get_metrics)
  end

  def get_realtime_metrics(pid) do
    GenServer.call(pid, :get_realtime_metrics)
  end

  ## GenServer Callbacks

  @impl true
  def init(config) do
    state = %__MODULE__{
      cluster_id: config.cluster_id,
      start_time: config.start_time,
      collection_interval: @collection_interval,
      metrics_history: [],
      current_metrics: initialize_metrics()
    }

    # Start metrics collection timer
    {:ok, timer_ref} = :timer.send_interval(@collection_interval, :collect_metrics)

    Logger.debug("Metrics collector started for cluster #{config.cluster_id}")

    {:ok, %{state | metrics_timer: timer_ref}}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    final_metrics = calculate_final_metrics(state)
    {:reply, final_metrics, state}
  end

  @impl true
  def handle_call(:get_realtime_metrics, _from, state) do
    {:reply, state.current_metrics, state}
  end

  @impl true
  def handle_info(:collect_metrics, state) do
    # Collect current metrics snapshot
    metrics_snapshot = collect_metrics_snapshot(state)
    
    # Update current metrics
    updated_current = update_current_metrics(state.current_metrics, metrics_snapshot)
    
    # Add to history
    new_history = [metrics_snapshot | Enum.take(state.metrics_history, 299)]  # Keep last 5 minutes
    
    new_state = %{state | 
      current_metrics: updated_current,
      metrics_history: new_history
    }
    
    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.metrics_timer do
      :timer.cancel(state.metrics_timer)
    end
    
    Logger.debug("Metrics collector stopped")
    :ok
  end

  ## Private Functions

  defp initialize_metrics() do
    %{
      messages_sent: 0,
      messages_received: 0,
      consensus_rounds: 0,
      average_latency: 0.0,
      error_count: 0,
      partition_events: 0,
      byzantine_detections: 0,
      throughput: 0.0,
      system_metrics: %{
        cpu_usage: 0.0,
        memory_usage: 0.0,
        network_io: 0,
        disk_io: 0
      }
    }
  end

  defp collect_metrics_snapshot(state) do
    timestamp = DateTime.utc_now()
    
    # Collect DVT-specific metrics
    dvt_metrics = collect_dvt_metrics(state.cluster_id)
    
    # Collect system metrics
    system_metrics = collect_system_metrics()
    
    # Collect network metrics
    network_metrics = collect_network_metrics(state.cluster_id)
    
    %{
      timestamp: timestamp,
      elapsed_seconds: DateTime.diff(timestamp, state.start_time, :second),
      dvt: dvt_metrics,
      system: system_metrics,
      network: network_metrics
    }
  end

  defp collect_dvt_metrics(cluster_id) do
    # Collect metrics from DVT components
    try do
      # P2P Protocol metrics
      p2p_status = P2PProtocol.get_network_status() || %{}
      
      # Partition detector metrics
      partition_status = PartitionDetector.get_partition_status() || %{}
      
      # GossipSub optimizer metrics
      gossipsub_stats = GossipSubOptimizer.get_performance_stats() || %{}
      
      %{
        cluster_id: cluster_id,
        active_peers: Map.get(p2p_status, :active_peers, 0),
        peer_count: Map.get(p2p_status, :peer_count, 0),
        messages_sent: get_nested_value(p2p_status, [:metrics, :messages_sent], 0),
        messages_received: get_nested_value(p2p_status, [:metrics, :messages_received], 0),
        partition_events: Map.get(partition_status, :partitioned_clusters, 0),
        consensus_latency: get_nested_value(gossipsub_stats, [:performance_metrics, :critical_message_latency], 0),
        throughput: calculate_current_throughput(gossipsub_stats),
        error_rate: calculate_error_rate(p2p_status)
      }
    catch
      :exit, {:noproc, _} ->
        Logger.warning("DVT process not available for metrics collection")
        %{cluster_id: cluster_id, error: :process_unavailable}
      
      error ->
        Logger.warning("Error collecting DVT metrics: #{inspect(error)}")
        %{cluster_id: cluster_id, error: :collection_failed}
    end
  end

  defp collect_system_metrics() do
    try do
      # Get system information
      {cpu_usage, memory_info} = get_system_resources()
      
      %{
        cpu_usage: cpu_usage,
        memory_total: Map.get(memory_info, :total, 0),
        memory_used: Map.get(memory_info, :used, 0),
        memory_usage_percent: calculate_memory_percent(memory_info),
        process_count: get_process_count(),
        load_average: get_load_average()
      }
    catch
      error ->
        Logger.warning("Error collecting system metrics: #{inspect(error)}")
        %{error: :system_metrics_failed}
    end
  end

  defp collect_network_metrics(cluster_id) do
    try do
      # Network I/O statistics
      network_stats = get_network_statistics()
      
      %{
        cluster_id: cluster_id,
        bytes_sent: Map.get(network_stats, :bytes_sent, 0),
        bytes_received: Map.get(network_stats, :bytes_received, 0),
        packets_sent: Map.get(network_stats, :packets_sent, 0),
        packets_received: Map.get(network_stats, :packets_received, 0),
        connection_count: get_connection_count(),
        average_latency: calculate_network_latency()
      }
    catch
      error ->
        Logger.warning("Error collecting network metrics: #{inspect(error)}")
        %{cluster_id: cluster_id, error: :network_metrics_failed}
    end
  end

  defp update_current_metrics(current, snapshot) do
    dvt = snapshot.dvt || %{}
    system = snapshot.system || %{}
    network = snapshot.network || %{}
    
    %{
      messages_sent: Map.get(dvt, :messages_sent, current.messages_sent),
      messages_received: Map.get(dvt, :messages_received, current.messages_received),
      consensus_rounds: current.consensus_rounds + 1,
      average_latency: Map.get(dvt, :consensus_latency, current.average_latency),
      error_count: current.error_count + count_errors(snapshot),
      partition_events: current.partition_events + Map.get(dvt, :partition_events, 0),
      byzantine_detections: current.byzantine_detections,
      throughput: Map.get(dvt, :throughput, current.throughput),
      system_metrics: %{
        cpu_usage: Map.get(system, :cpu_usage, current.system_metrics.cpu_usage),
        memory_usage: Map.get(system, :memory_usage_percent, current.system_metrics.memory_usage),
        network_io: Map.get(network, :bytes_sent, 0) + Map.get(network, :bytes_received, 0),
        disk_io: get_disk_io_current()
      }
    }
  end

  defp calculate_final_metrics(state) do
    if length(state.metrics_history) == 0 do
      state.current_metrics
    else
      # Calculate aggregated metrics from history
      total_duration = DateTime.diff(DateTime.utc_now(), state.start_time, :second)
      
      # Get metrics from history for calculations
      history_metrics = Enum.map(state.metrics_history, & &1.dvt)
      
      %{
        test_duration_seconds: total_duration,
        messages_sent: state.current_metrics.messages_sent,
        messages_received: state.current_metrics.messages_received,
        consensus_rounds: state.current_metrics.consensus_rounds,
        average_latency: calculate_average_latency(history_metrics),
        p99_latency: calculate_p99_latency(history_metrics),
        throughput: calculate_average_throughput(history_metrics, total_duration),
        error_count: state.current_metrics.error_count,
        error_rate: calculate_final_error_rate(state.current_metrics),
        partition_events: state.current_metrics.partition_events,
        byzantine_detections: state.current_metrics.byzantine_detections,
        system_metrics: calculate_system_averages(state.metrics_history),
        network_metrics: calculate_network_totals(state.metrics_history)
      }
    end
  end

  # Helper functions for metrics calculations
  defp get_nested_value(map, keys, default) when is_map(map) do
    Enum.reduce(keys, map, fn key, acc ->
      if is_map(acc) do
        Map.get(acc, key)
      else
        nil
      end
    end) || default
  end
  defp get_nested_value(_, _, default), do: default

  defp calculate_current_throughput(stats) do
    get_nested_value(stats, [:performance_metrics, :total_messages_sent], 0) / 
    max(1, get_nested_value(stats, [:elapsed_time, :seconds], 1))
  end

  defp calculate_error_rate(status) do
    messages_sent = get_nested_value(status, [:metrics, :messages_sent], 0)
    errors = get_nested_value(status, [:metrics, :errors], 0)
    
    if messages_sent > 0 do
      errors / messages_sent * 100
    else
      0.0
    end
  end

  defp get_system_resources() do
    # Simplified system resource collection
    cpu_usage = :rand.uniform(100) * 0.6  # Simulate 0-60% CPU usage
    
    memory_info = %{
      total: 8_589_934_592,  # 8GB
      used: :rand.uniform(4_294_967_296) + 2_147_483_648  # 2-6GB used
    }
    
    {cpu_usage, memory_info}
  end

  defp calculate_memory_percent(memory_info) do
    total = Map.get(memory_info, :total, 1)
    used = Map.get(memory_info, :used, 0)
    
    used / total * 100
  end

  defp get_process_count() do
    length(Process.list())
  end

  defp get_load_average() do
    # Simulate load average
    :rand.uniform(400) / 100.0
  end

  defp get_network_statistics() do
    # Mock network statistics
    %{
      bytes_sent: :rand.uniform(1_000_000),
      bytes_received: :rand.uniform(1_000_000),
      packets_sent: :rand.uniform(10_000),
      packets_received: :rand.uniform(10_000)
    }
  end

  defp get_connection_count() do
    :rand.uniform(50) + 10
  end

  defp calculate_network_latency() do
    # Simulate network latency in milliseconds
    :rand.uniform(50) + 5
  end

  defp count_errors(snapshot) do
    errors = 0
    
    # Count DVT errors
    errors = if Map.has_key?(snapshot.dvt || %{}, :error), do: errors + 1, else: errors
    
    # Count system errors
    errors = if Map.has_key?(snapshot.system || %{}, :error), do: errors + 1, else: errors
    
    # Count network errors
    errors = if Map.has_key?(snapshot.network || %{}, :error), do: errors + 1, else: errors
    
    errors
  end

  defp get_disk_io_current() do
    # Mock disk I/O
    :rand.uniform(100_000)
  end

  defp calculate_average_latency(history_metrics) do
    latencies = Enum.map(history_metrics, &Map.get(&1, :consensus_latency, 0))
    non_zero_latencies = Enum.filter(latencies, &(&1 > 0))
    
    if length(non_zero_latencies) > 0 do
      Enum.sum(non_zero_latencies) / length(non_zero_latencies)
    else
      0.0
    end
  end

  defp calculate_p99_latency(history_metrics) do
    latencies = Enum.map(history_metrics, &Map.get(&1, :consensus_latency, 0))
    |> Enum.filter(&(&1 > 0))
    |> Enum.sort()
    
    if length(latencies) > 0 do
      p99_index = trunc(length(latencies) * 0.99)
      Enum.at(latencies, p99_index, 0)
    else
      0.0
    end
  end

  defp calculate_average_throughput(history_metrics, duration) do
    if duration > 0 do
      total_messages = Enum.map(history_metrics, &Map.get(&1, :messages_sent, 0))
      |> Enum.max(fn -> 0 end)
      
      total_messages / duration
    else
      0.0
    end
  end

  defp calculate_final_error_rate(current_metrics) do
    total_messages = current_metrics.messages_sent + current_metrics.messages_received
    
    if total_messages > 0 do
      current_metrics.error_count / total_messages * 100
    else
      0.0
    end
  end

  defp calculate_system_averages(metrics_history) do
    if length(metrics_history) == 0 do
      %{cpu_usage: 0, memory_usage: 0}
    else
      system_metrics = Enum.map(metrics_history, & &1.system)
      
      %{
        avg_cpu_usage: average_field(system_metrics, :cpu_usage),
        avg_memory_usage: average_field(system_metrics, :memory_usage_percent),
        peak_cpu: max_field(system_metrics, :cpu_usage),
        peak_memory: max_field(system_metrics, :memory_usage_percent)
      }
    end
  end

  defp calculate_network_totals(metrics_history) do
    if length(metrics_history) == 0 do
      %{total_bytes: 0, total_packets: 0}
    else
      network_metrics = Enum.map(metrics_history, & &1.network)
      
      %{
        total_bytes_sent: sum_field(network_metrics, :bytes_sent),
        total_bytes_received: sum_field(network_metrics, :bytes_received),
        total_packets_sent: sum_field(network_metrics, :packets_sent),
        total_packets_received: sum_field(network_metrics, :packets_received),
        avg_latency: average_field(network_metrics, :average_latency)
      }
    end
  end

  defp average_field(metrics_list, field) do
    values = Enum.map(metrics_list, &Map.get(&1, field, 0))
    |> Enum.filter(&is_number/1)
    
    if length(values) > 0 do
      Enum.sum(values) / length(values)
    else
      0.0
    end
  end

  defp max_field(metrics_list, field) do
    Enum.map(metrics_list, &Map.get(&1, field, 0))
    |> Enum.filter(&is_number/1)
    |> Enum.max(fn -> 0 end)
  end

  defp sum_field(metrics_list, field) do
    Enum.map(metrics_list, &Map.get(&1, field, 0))
    |> Enum.filter(&is_number/1)
    |> Enum.sum()
  end
end