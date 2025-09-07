defmodule ExWire.Performance.TaskPoolSupervisor do
  @moduledoc """
  Optimized Task supervisor pool for high-performance concurrent operations.
  
  Replaces ad-hoc Task.async spawning with supervised, pooled task execution:
  - Pre-allocated supervised task workers
  - Optimal scheduler utilization
  - Fault tolerance and cleanup
  - Performance monitoring and metrics
  
  Target: Improve process spawning from 0.50K to 5K+ ops/sec.
  """
  
  use DynamicSupervisor
  require Logger
  
  @pool_sizes %{
    p2p_operations: System.schedulers_online() * 2,
    witness_generation: System.schedulers_online(),
    consensus_operations: System.schedulers_online() * 3,
    data_processing: System.schedulers_online() * 4
  }
  
  @max_children_per_pool 1000
  @task_timeout 30_000
  
  ## Public API
  
  @doc """
  Start the task pool supervisor with optimized pools.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end
  
  @doc """
  Execute a high-performance async task with automatic pooling.
  Replaces direct Task.async calls for better resource management.
  """
  def async_execute(pool_type, fun, opts \\ []) when is_function(fun) do
    timeout = Keyword.get(opts, :timeout, @task_timeout)
    supervisor = get_supervisor_for_pool(pool_type)
    
    task_spec = %{
      id: make_ref(),
      start: {Task, :start_link, [fun]},
      restart: :temporary,
      type: :worker
    }
    
    case DynamicSupervisor.start_child(supervisor, task_spec) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:ok, %{pid: pid, ref: ref, timeout: timeout}}
      
      {:error, reason} ->
        Logger.error("Failed to start supervised task: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  @doc """
  Execute batch operations with optimal concurrency.
  Replaces manual Task.async_stream patterns.
  """
  def async_batch(pool_type, items, fun, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, get_optimal_concurrency(pool_type))
    timeout = Keyword.get(opts, :timeout, @task_timeout)
    
    items
    |> Task.async_stream(
      fun, 
      max_concurrency: concurrency,
      timeout: timeout,
      supervisor: get_supervisor_for_pool(pool_type),
      on_timeout: :kill_task,
      ordered: Keyword.get(opts, :ordered, true)
    )
    |> Enum.to_list()
  end

  @doc """
  Execute batch operations with the signature expected by DistributedClusterManager.
  
  This is a compatibility function that matches the async_batch/4 signature
  used throughout the Verkle tree distributed operations.
  """
  def async_batch(tasks, task_args, timeout, opts) do
    pool_type = Keyword.get(opts, :pool_type, :p2p_operations)
    max_concurrency = Keyword.get(opts, :max_concurrency, get_optimal_concurrency(pool_type))
    
    # Convert task functions and args to executable items
    executable_items = if length(task_args) == length(tasks) do
      Enum.zip(tasks, task_args)
    else
      Enum.map(tasks, fn task -> {task, []} end)
    end
    
    # Execute using the optimized task pool
    start_time = System.monotonic_time(:microsecond)
    
    results = executable_items
    |> Task.async_stream(fn {task_fun, args} ->
      if length(args) > 0 do
        apply(task_fun, args)
      else
        task_fun.()
      end
    end, 
      max_concurrency: max_concurrency,
      timeout: timeout,
      supervisor: get_supervisor_for_pool(pool_type),
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end)
    
    end_time = System.monotonic_time(:microsecond)
    execution_time = end_time - start_time
    
    # Log performance
    tasks_per_second = Float.round(length(tasks) * 1_000_000 / execution_time)
    Logger.debug("Batch executed #{length(tasks)} tasks at #{tasks_per_second} tasks/sec")
    
    results
  end
  
  @doc """
  Await task completion with enhanced error handling.
  """
  def await_task(task_info, timeout \\ @task_timeout) do
    receive do
      {:DOWN, ref, :process, pid, :normal} when ref == task_info.ref and pid == task_info.pid ->
        # Task completed successfully
        {:ok, :completed}
      
      {:DOWN, ref, :process, pid, reason} when ref == task_info.ref and pid == task_info.pid ->
        {:error, reason}
    after
      timeout ->
        # Clean up timed-out task
        Process.exit(task_info.pid, :kill)
        {:error, :timeout}
    end
  end
  
  @doc """
  Optimized replacement for distributed operations.
  Used in DistributedClusterManager for witness generation.
  """
  def distribute_work(pool_type, work_items, nodes, fun, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 10)
    timeout = Keyword.get(opts, :timeout, @task_timeout)
    
    # Distribute work across nodes optimally
    work_batches = 
      work_items
      |> Enum.chunk_every(batch_size)
      |> Enum.with_index()
      |> Enum.map(fn {batch, index} ->
        node = Enum.at(nodes, rem(index, length(nodes)))
        {node, batch}
      end)
    
    # Execute with supervised tasks
    async_batch(pool_type, work_batches, fn {node, batch} ->
      execute_on_node(node, batch, fun)
    end, opts)
  end
  
  @doc """
  Get performance metrics for all task pools.
  """
  def get_metrics do
    Enum.map(@pool_sizes, fn {pool_type, _size} ->
      supervisor = get_supervisor_for_pool(pool_type)
      children = DynamicSupervisor.count_children(supervisor)
      
      {pool_type, %{
        active_tasks: children.active,
        total_specs: children.specs,
        supervisors: children.supervisors,
        workers: children.workers
      }}
    end)
    |> Map.new()
  end
  
  ## DynamicSupervisor Implementation
  
  @impl DynamicSupervisor
  def init(opts) do
    # Start individual pool supervisors
    Enum.each(@pool_sizes, fn {pool_type, _size} ->
      start_pool_supervisor(pool_type)
    end)
    
    Logger.info("TaskPoolSupervisor started with optimized pools: #{inspect(Map.keys(@pool_sizes))}")
    
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: @max_children_per_pool,
      max_seconds: 60,
      max_restarts: 10
    )
  end
  
  ## Private Implementation
  
  defp get_supervisor_for_pool(pool_type) do
    # Use registered name for pool supervisor
    :"#{__MODULE__}.#{pool_type}"
  end
  
  defp start_pool_supervisor(pool_type) do
    name = get_supervisor_for_pool(pool_type)
    
    child_spec = %{
      id: name,
      start: {DynamicSupervisor, :start_link, [[
        strategy: :one_for_one,
        name: name,
        max_children: Map.get(@pool_sizes, pool_type, 100),
        max_seconds: 60,
        max_restarts: 10
      ]]},
      type: :supervisor
    }
    
    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, _pid} ->
        Logger.debug("Started pool supervisor for #{pool_type}")
        :ok
      
      {:error, reason} ->
        Logger.error("Failed to start pool supervisor for #{pool_type}: #{inspect(reason)}")
        :error
    end
  end
  
  defp get_optimal_concurrency(pool_type) do
    base_concurrency = Map.get(@pool_sizes, pool_type, System.schedulers_online())
    
    # Adjust based on system load
    case :cpu_sup.avg1() do
      load when load > 800 ->
        # High load - reduce concurrency
        max(1, div(base_concurrency, 2))
      
      load when load > 500 ->
        # Medium load - slight reduction
        max(1, div(base_concurrency * 3, 4))
      
      _ ->
        # Normal load - use full concurrency
        base_concurrency
    end
  end
  
  defp execute_on_node(node, batch, fun) do
    try do
      # Execute function on specific node with batch
      case :rpc.call(node, fun, [batch]) do
        {:ok, result} ->
          {:ok, result}
        
        {:error, reason} ->
          Logger.warning("Node execution failed on #{node}: #{inspect(reason)}")
          {:error, reason}
        
        {:badrpc, reason} ->
          Logger.error("RPC failed to node #{node}: #{inspect(reason)}")
          {:error, {:rpc_failed, reason}}
        
        result ->
          {:ok, result}
      end
    rescue
      error ->
        Logger.error("Exception during node execution: #{inspect(error)}")
        {:error, {:exception, error}}
    end
  end
end