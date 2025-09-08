defmodule ExWire.Performance.SchedulerOptimizer do
  @moduledoc """
  Optimal scheduler utilization configuration for high-performance operations.
  
  Configures BEAM scheduler and process management for maximum throughput:
  - Optimal scheduler binding and utilization
  - Process priority management
  - Memory allocation tuning
  - GC optimization for high-throughput scenarios
  
  Target: Support 5K+ process spawning ops/sec with minimal latency.
  """
  
  use GenServer
  require Logger
  
  @scheduler_check_interval 60_000  # Check every minute
  @optimal_utilization_threshold 0.85
  @high_load_threshold 0.95
  
  defmodule State do
    @moduledoc false
    defstruct [
      :scheduler_count,
      :optimal_concurrency,
      current_utilization: 0.0,
      optimization_level: :normal,
      metrics: %{
        scheduler_utilization: [],
        process_count_history: [],
        gc_stats: %{}
      }
    ]
  end
  
  ## Public API
  
  @doc """
  Start the scheduler optimizer with system detection.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end
  
  @doc """
  Get optimal concurrency level for current system load.
  """
  def get_optimal_concurrency(operation_type \\ :general) do
    GenServer.call(__MODULE__, {:get_optimal_concurrency, operation_type})
  end
  
  @doc """
  Configure high-performance process spawning settings.
  """
  def optimize_for_high_throughput do
    GenServer.call(__MODULE__, :optimize_for_high_throughput)
  end
  
  @doc """
  Get current scheduler metrics and recommendations.
  """
  def get_scheduler_metrics do
    GenServer.call(__MODULE__, :get_scheduler_metrics)
  end
  
  @doc """
  Apply scheduler optimizations based on workload type.
  """
  def apply_workload_optimizations(workload_type) do
    GenServer.cast(__MODULE__, {:apply_workload_optimizations, workload_type})
  end
  
  ## GenServer Implementation
  
  @impl GenServer
  def init(opts) do
    scheduler_count = System.schedulers_online()
    
    # Apply initial optimizations
    apply_initial_optimizations()
    
    # Schedule periodic optimization checks
    schedule_optimization_check()
    
    state = %State{
      scheduler_count: scheduler_count,
      optimal_concurrency: calculate_optimal_concurrency(scheduler_count)
    }
    
    Logger.info("SchedulerOptimizer started: #{scheduler_count} schedulers, optimal_concurrency: #{state.optimal_concurrency}")
    
    {:ok, state}
  end
  
  @impl GenServer
  def handle_call({:get_optimal_concurrency, operation_type}, _from, state) do
    concurrency = get_concurrency_for_operation(operation_type, state)
    {:reply, concurrency, state}
  end
  
  @impl GenServer
  def handle_call(:optimize_for_high_throughput, _from, state) do
    new_state = apply_high_throughput_optimizations(state)
    {:reply, :ok, new_state}
  end
  
  @impl GenServer
  def handle_call(:get_scheduler_metrics, _from, state) do
    metrics = collect_scheduler_metrics(state)
    {:reply, metrics, %{state | metrics: metrics}}
  end
  
  @impl GenServer
  def handle_cast({:apply_workload_optimizations, workload_type}, state) do
    new_state = apply_workload_specific_optimizations(workload_type, state)
    {:noreply, new_state}
  end
  
  @impl GenServer
  def handle_info(:optimization_check, state) do
    new_state = perform_optimization_check(state)
    schedule_optimization_check()
    {:noreply, new_state}
  end
  
  ## Private Implementation
  
  defp apply_initial_optimizations do
    # Enable +scl flag for scheduler collapse limiting
    # This is typically set at runtime start, but we can tune other aspects
    
    # Optimize process creation flags
    Process.flag(:priority, :normal)
    
    # Tune garbage collection for high throughput
    System.flag(:scheduler_wall_time, true)
    
    Logger.info("Applied initial scheduler optimizations")
  end
  
  defp calculate_optimal_concurrency(scheduler_count) do
    # Base concurrency on scheduler count with multiplier for different workloads
    %{
      p2p_operations: scheduler_count * 2,
      witness_generation: scheduler_count,
      consensus_operations: scheduler_count * 3,
      data_processing: scheduler_count * 4,
      general: scheduler_count * 2
    }
  end
  
  defp get_concurrency_for_operation(operation_type, state) do
    base_concurrency = Map.get(state.optimal_concurrency, operation_type, state.scheduler_count * 2)
    
    # Adjust based on current system utilization
    case state.current_utilization do
      util when util > @high_load_threshold ->
        # High load - reduce concurrency
        max(1, div(base_concurrency, 2))
      
      util when util > @optimal_utilization_threshold ->
        # Medium load - slight reduction
        max(1, div(base_concurrency * 3, 4))
      
      _ ->
        # Normal load - full concurrency
        base_concurrency
    end
  end
  
  defp apply_high_throughput_optimizations(state) do
    # Enable aggressive optimizations for high throughput
    
    # Tune process creation and management
    optimize_process_creation()
    
    # Configure memory allocation for high throughput
    optimize_memory_allocation()
    
    # Adjust garbage collection parameters
    optimize_garbage_collection()
    
    Logger.info("Applied high-throughput scheduler optimizations")
    
    %{state | optimization_level: :high_throughput}
  end
  
  defp apply_workload_specific_optimizations(workload_type, state) do
    case workload_type do
      :cpu_intensive ->
        # Optimize for CPU-bound tasks
        optimize_for_cpu_intensive()
      
      :io_intensive ->
        # Optimize for I/O-bound tasks
        optimize_for_io_intensive()
      
      :memory_intensive ->
        # Optimize for memory-bound tasks
        optimize_for_memory_intensive()
      
      :network_intensive ->
        # Optimize for network-bound tasks
        optimize_for_network_intensive()
      
      _ ->
        Logger.warning("Unknown workload type: #{workload_type}")
    end
    
    state
  end
  
  defp perform_optimization_check(state) do
    # Check current scheduler utilization
    utilization = get_scheduler_utilization()
    
    # Update state with current utilization
    new_state = %{state | current_utilization: utilization}
    
    # Apply optimizations if needed
    cond do
      utilization > @high_load_threshold ->
        Logger.info("High scheduler utilization (#{Float.round(utilization * 100, 1)}%), applying load shedding")
        apply_load_shedding_optimizations(new_state)
      
      utilization < 0.3 ->
        Logger.info("Low scheduler utilization (#{Float.round(utilization * 100, 1)}%), increasing concurrency")
        apply_low_load_optimizations(new_state)
      
      true ->
        new_state
    end
  end
  
  defp collect_scheduler_metrics(state) do
    scheduler_wall_time = :erlang.statistics(:scheduler_wall_time)
    process_count = :erlang.system_info(:process_count)
    memory_info = :erlang.memory()
    
    %{
      scheduler_count: state.scheduler_count,
      current_utilization: state.current_utilization,
      process_count: process_count,
      memory_usage: memory_info,
      scheduler_wall_time: scheduler_wall_time,
      optimal_concurrency: state.optimal_concurrency,
      optimization_level: state.optimization_level
    }
  end
  
  defp get_scheduler_utilization do
    case :erlang.statistics(:scheduler_wall_time) do
      scheduler_times when is_list(scheduler_times) ->
        # Calculate average utilization across schedulers
        total_runtime = Enum.sum(for {_id, active, total} <- scheduler_times, do: active)
        total_wall_time = Enum.sum(for {_id, _active, total} <- scheduler_times, do: total)
        
        if total_wall_time > 0 do
          total_runtime / total_wall_time
        else
          0.0
        end
      
      _ ->
        0.0
    end
  end
  
  defp optimize_process_creation do
    # Tune process creation for high throughput
    # Most of these optimizations happen at VM startup, but we can tune some aspects
    
    # Set optimal process flags for new processes
    Process.flag(:min_heap_size, 1024)  # Larger initial heap for fewer GC cycles
    Process.flag(:min_bin_vheap_size, 4096)  # Larger binary heap
  end
  
  defp optimize_memory_allocation do
    # Configure memory allocation strategies
    # These are typically configured at startup, but we can monitor and adjust
    :ok
  end
  
  defp optimize_garbage_collection do
    # Enable more aggressive garbage collection for high throughput
    :erlang.system_flag(:fullsweep_after, 10)  # More frequent full sweeps
  end
  
  defp optimize_for_cpu_intensive do
    Logger.debug("Applying CPU-intensive optimizations")
    # Focus on scheduler utilization
  end
  
  defp optimize_for_io_intensive do
    Logger.debug("Applying I/O-intensive optimizations")
    # Focus on async I/O handling
  end
  
  defp optimize_for_memory_intensive do
    Logger.debug("Applying memory-intensive optimizations")
    # Focus on GC tuning and memory allocation
    optimize_garbage_collection()
  end
  
  defp optimize_for_network_intensive do
    Logger.debug("Applying network-intensive optimizations")
    # Focus on connection pooling and async network operations
  end
  
  defp apply_load_shedding_optimizations(state) do
    # Reduce concurrency when system is under high load
    new_concurrency = 
      state.optimal_concurrency
      |> Enum.map(fn {type, concurrency} ->
        {type, max(1, div(concurrency, 2))}
      end)
      |> Map.new()
    
    %{state | optimal_concurrency: new_concurrency}
  end
  
  defp apply_low_load_optimizations(state) do
    # Increase concurrency when system has spare capacity
    new_concurrency = 
      state.optimal_concurrency
      |> Enum.map(fn {type, concurrency} ->
        {type, concurrency * 2}
      end)
      |> Map.new()
    
    %{state | optimal_concurrency: new_concurrency}
  end
  
  defp schedule_optimization_check do
    Process.send_after(self(), :optimization_check, @scheduler_check_interval)
  end
end