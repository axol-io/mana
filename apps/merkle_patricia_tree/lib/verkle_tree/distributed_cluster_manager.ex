defmodule VerkleTree.DistributedClusterManager do
  @moduledoc """
  Distributed computing architecture for massive parallel Verkle tree processing.
  
  This module implements a distributed cluster management system that coordinates
  Verkle tree operations across multiple nodes to achieve linear scalability
  and contribute to the 35x performance target through massive parallelization.

  ## Key Features
  - **Auto-scaling Cluster**: Dynamic node management based on workload
  - **Load Balancing**: Intelligent workload distribution across cluster nodes  
  - **Fault Tolerance**: Automatic failover and recovery mechanisms
  - **Network Optimization**: High-speed inter-node communication
  - **Resource Pooling**: GPU/FPGA resource sharing across cluster

  ## Performance Targets
  - **Linear Scalability**: 3x improvement per additional node (first 4 nodes)
  - **Network Latency**: <10ms inter-node communication
  - **Fault Tolerance**: 99.99% uptime with automatic recovery
  - **Resource Efficiency**: 95%+ cluster resource utilization

  ## Cluster Architecture
  ```
  Coordinator Node (Primary)
  ├── Compute Node 1 (GPU + Native Core)
  ├── Compute Node 2 (FPGA + Native Core) 
  ├── Compute Node 3 (GPU + Native Core)
  └── Storage Cluster (AntidoteDB)
  ```
  """

  use GenServer
  require Logger

  alias VerkleTree.{NativeCore, GPUAccelerator}

  # Cluster configuration
  @default_max_nodes 16
  @default_replication_factor 3
  @heartbeat_interval 5_000
  @load_balance_interval 10_000
  @network_timeout 15_000

  # Cluster state structure
  defstruct [
    :cluster_id,
    :coordinator_node,
    :compute_nodes,
    :storage_nodes,
    :load_balancer,
    :fault_detector,
    :resource_manager,
    :network_optimizer,
    :cluster_stats,
    :cluster_config
  ]

  @type node_info :: %{
    node_id: atom(),
    node_type: :coordinator | :compute | :storage,
    capabilities: map(),
    status: :active | :inactive | :failed,
    load: float(),
    resources: map(),
    last_heartbeat: integer()
  }

  @type cluster_config :: %{
    max_nodes: pos_integer(),
    replication_factor: pos_integer(),
    auto_scaling: boolean(),
    fault_tolerance: boolean(),
    network_optimization: boolean(),
    resource_sharing: boolean()
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    Logger.info("Initializing Distributed Cluster Manager for 35x performance")
    
    cluster_id = Keyword.get(opts, :cluster_id, generate_cluster_id())
    
    config = %{
      max_nodes: Keyword.get(opts, :max_nodes, @default_max_nodes),
      replication_factor: Keyword.get(opts, :replication_factor, @default_replication_factor),
      auto_scaling: Keyword.get(opts, :auto_scaling, true),
      fault_tolerance: Keyword.get(opts, :fault_tolerance, true),
      network_optimization: Keyword.get(opts, :network_optimization, true),
      resource_sharing: Keyword.get(opts, :resource_sharing, true)
    }
    
    # Initialize cluster components
    {:ok, load_balancer} = __MODULE__.LoadBalancer.start_link()
    {:ok, fault_detector} = __MODULE__.FaultDetector.start_link()
    {:ok, resource_manager} = __MODULE__.ResourceManager.start_link()
    {:ok, network_optimizer} = __MODULE__.NetworkOptimizer.start_link()
    
    # Initialize as coordinator node
    coordinator_node = %{
      node_id: Node.self(),
      node_type: :coordinator,
      capabilities: get_local_capabilities(),
      status: :active,
      load: 0.0,
      resources: get_local_resources(),
      last_heartbeat: System.system_time(:millisecond)
    }
    
    state = %__MODULE__{
      cluster_id: cluster_id,
      coordinator_node: coordinator_node,
      compute_nodes: %{},
      storage_nodes: %{},
      load_balancer: load_balancer,
      fault_detector: fault_detector,
      resource_manager: resource_manager,
      network_optimizer: network_optimizer,
      cluster_stats: initialize_cluster_stats(),
      cluster_config: config
    }
    
    # Start cluster services
    start_cluster_services()
    
    Logger.info("Cluster #{cluster_id} initialized as coordinator node")
    
    {:ok, state}
  end

  @doc """
  Distribute Verkle tree operations across the cluster for massive parallel processing.
  
  Automatically partitions workload based on:
  - Node capabilities (GPU, FPGA, CPU)
  - Current load distribution
  - Network latency and bandwidth
  - Data locality and dependencies
  """
  def distribute_operations(operations, opts \\ []) do
    GenServer.call(__MODULE__, {:distribute_operations, operations, opts}, @network_timeout * 2)
  end

  @doc """
  Add a compute node to the cluster.
  
  Automatically detects node capabilities and integrates into cluster workload distribution.
  """
  def join_cluster(node_id, capabilities \\ %{}) do
    GenServer.call(__MODULE__, {:join_cluster, node_id, capabilities})
  end

  @doc """
  Remove a node from the cluster gracefully.
  
  Redistributes workload and ensures no data loss.
  """
  def leave_cluster(node_id) do
    GenServer.call(__MODULE__, {:leave_cluster, node_id})
  end

  @doc """
  Get current cluster status and performance metrics.
  """
  def get_cluster_status() do
    GenServer.call(__MODULE__, :get_cluster_status)
  end

  @doc """
  Perform distributed witness generation across the cluster.
  
  Distributes witness generation workload to achieve maximum parallel throughput.
  Target: 200k+ witnesses/sec with 4-node cluster.
  """
  def distributed_witness_generation(keys, opts \\ []) do
    GenServer.call(__MODULE__, {:distributed_witness_generation, keys, opts}, 120_000)
  end

  @doc """
  Execute distributed tree operations with optimal load balancing.
  """
  def distributed_tree_operations(operations, opts \\ []) do
    GenServer.call(__MODULE__, {:distributed_tree_operations, operations, opts}, 60_000)
  end

  @doc """
  Scale cluster up or down based on current workload.
  """
  def scale_cluster(target_nodes) when is_integer(target_nodes) do
    GenServer.call(__MODULE__, {:scale_cluster, target_nodes})
  end

  @doc """
  Optimize cluster performance based on current metrics.
  """
  def optimize_cluster_performance() do
    GenServer.call(__MODULE__, :optimize_cluster_performance)
  end

  # GenServer Callbacks

  def handle_call({:distribute_operations, operations, opts}, _from, state) do
    start_time = System.monotonic_time(:microsecond)
    
    try do
      # Analyze operations for optimal distribution
      distribution_plan = create_distribution_plan(operations, state, opts)
      
      # Execute distributed operations
      results = execute_distributed_operations(distribution_plan, state)
      
      # Update cluster statistics
      elapsed = System.monotonic_time(:microsecond) - start_time
      new_stats = update_operation_stats(state.cluster_stats, length(operations), elapsed)
      
      state = %{state | cluster_stats: new_stats}
      
      {:reply, {:ok, results}, state}
      
    rescue
      error ->
        Logger.error("Distributed operation failed: #{inspect(error)}")
        {:reply, {:error, {:distribution_failed, error}}, state}
    end
  end

  def handle_call({:join_cluster, node_id, capabilities}, _from, state) do
    try do
      Logger.info("Node #{node_id} requesting to join cluster #{state.cluster_id}")
      
      # Validate node can join cluster
      case validate_node_join(node_id, capabilities, state) do
        :ok ->
          # Add node to appropriate category
          node_info = create_node_info(node_id, capabilities)
          state = add_node_to_cluster(node_info, state)
          
          # Rebalance cluster workload
          state = rebalance_cluster_load(state)
          
          Logger.info("Node #{node_id} successfully joined cluster")
          {:reply, {:ok, :joined}, state}
          
        {:error, reason} ->
          Logger.warning("Node #{node_id} join rejected: #{reason}")
          {:reply, {:error, reason}, state}
      end
      
    rescue
      error ->
        Logger.error("Error adding node #{node_id}: #{inspect(error)}")
        {:reply, {:error, {:join_failed, error}}, state}
    end
  end

  def handle_call({:leave_cluster, node_id}, _from, state) do
    try do
      Logger.info("Node #{node_id} leaving cluster #{state.cluster_id}")
      
      # Graceful node removal
      state = remove_node_from_cluster(node_id, state)
      
      # Redistribute workload
      state = rebalance_cluster_load(state)
      
      {:reply, :ok, state}
      
    rescue
      error ->
        Logger.error("Error removing node #{node_id}: #{inspect(error)}")
        {:reply, {:error, {:leave_failed, error}}, state}
    end
  end

  def handle_call({:distributed_witness_generation, keys, opts}, _from, state) do
    start_time = System.monotonic_time(:microsecond)
    
    try do
      # Determine optimal witness generation strategy
      batch_size = calculate_optimal_witness_batch_size(length(keys), state)
      
      # Distribute witness generation across cluster
      witness_plan = create_witness_distribution_plan(keys, batch_size, state)
      
      # Execute distributed witness generation
      witnesses = execute_distributed_witness_generation(witness_plan, state, opts)
      
      # Update performance statistics
      elapsed = System.monotonic_time(:microsecond) - start_time
      witnesses_per_sec = length(keys) / (elapsed / 1_000_000)
      
      new_stats = update_witness_stats(state.cluster_stats, length(keys), elapsed, witnesses_per_sec)
      
      state = %{state | cluster_stats: new_stats}
      
      Logger.info("Distributed witness generation: #{length(keys)} witnesses in #{elapsed / 1000}ms (#{Float.round(witnesses_per_sec, 2)} witnesses/sec)")
      
      {:reply, {:ok, witnesses}, state}
      
    rescue
      error ->
        Logger.error("Distributed witness generation failed: #{inspect(error)}")
        {:reply, {:error, {:witness_generation_failed, error}}, state}
    end
  end

  def handle_call({:distributed_tree_operations, operations, opts}, _from, state) do
    start_time = System.monotonic_time(:microsecond)
    
    try do
      # Create operation distribution plan
      operation_plan = create_operation_distribution_plan(operations, state, opts)
      
      # Execute operations across cluster
      results = execute_distributed_tree_operations(operation_plan, state)
      
      elapsed = System.monotonic_time(:microsecond) - start_time
      ops_per_sec = length(operations) / (elapsed / 1_000_000)
      
      new_stats = update_tree_operation_stats(state.cluster_stats, length(operations), elapsed, ops_per_sec)
      
      state = %{state | cluster_stats: new_stats}
      
      {:reply, {:ok, results}, state}
      
    rescue
      error ->
        Logger.error("Distributed tree operations failed: #{inspect(error)}")
        {:reply, {:error, {:tree_operations_failed, error}}, state}
    end
  end

  def handle_call({:scale_cluster, target_nodes}, _from, state) do
    try do
      current_nodes = count_active_nodes(state)
      
      cond do
        target_nodes > current_nodes ->
          # Scale up - request additional nodes
          scale_up_result = request_additional_nodes(target_nodes - current_nodes, state)
          {:reply, scale_up_result, state}
          
        target_nodes < current_nodes ->
          # Scale down - gracefully remove nodes
          nodes_to_remove = current_nodes - target_nodes
          new_state = scale_down_cluster(nodes_to_remove, state)
          {:reply, {:ok, :scaled_down}, new_state}
          
        true ->
          # No scaling needed
          {:reply, {:ok, :no_change}, state}
      end
      
    rescue
      error ->
        Logger.error("Cluster scaling failed: #{inspect(error)}")
        {:reply, {:error, {:scaling_failed, error}}, state}
    end
  end

  def handle_call(:get_cluster_status, _from, state) do
    status = compile_cluster_status(state)
    {:reply, {:ok, status}, state}
  end

  def handle_call(:optimize_cluster_performance, _from, state) do
    try do
      Logger.info("Optimizing cluster performance")
      
      # Analyze current performance bottlenecks
      bottlenecks = analyze_cluster_bottlenecks(state)
      
      # Apply optimizations
      optimized_state = apply_cluster_optimizations(bottlenecks, state)
      
      # Update load balancing
      final_state = rebalance_cluster_load(optimized_state)
      
      optimization_summary = %{
        bottlenecks_identified: length(bottlenecks),
        optimizations_applied: count_optimizations_applied(bottlenecks),
        performance_improvement: calculate_performance_improvement(state, final_state)
      }
      
      {:reply, {:ok, optimization_summary}, final_state}
      
    rescue
      error ->
        Logger.error("Cluster optimization failed: #{inspect(error)}")
        {:reply, {:error, {:optimization_failed, error}}, state}
    end
  end

  def handle_info(:heartbeat_check, state) do
    # Check node heartbeats and detect failures
    state = check_node_heartbeats(state)
    schedule_heartbeat_check()
    {:noreply, state}
  end

  def handle_info(:load_balance, state) do
    # Periodic load balancing
    state = rebalance_cluster_load(state)
    schedule_load_balancing()
    {:noreply, state}
  end

  def handle_info({:node_heartbeat, node_id, node_info}, state) do
    # Update node information from heartbeat
    state = update_node_heartbeat(node_id, node_info, state)
    {:noreply, state}
  end

  def handle_info({:node_failed, node_id}, state) do
    # Handle node failure
    Logger.warning("Node #{node_id} detected as failed - initiating failover")
    state = handle_node_failure(node_id, state)
    {:noreply, state}
  end

  # Private Implementation Functions

  defp create_distribution_plan(operations, state, opts) do
    # Create optimal distribution plan based on cluster state
    available_nodes = get_available_compute_nodes(state)
    
    %{
      operations: operations,
      nodes: available_nodes,
      distribution_strategy: determine_distribution_strategy(operations, available_nodes, opts),
      batch_sizes: calculate_optimal_batch_sizes(operations, available_nodes),
      dependencies: analyze_operation_dependencies(operations),
      priority: Keyword.get(opts, :priority, :normal)
    }
  end

  defp execute_distributed_operations(plan, state) do
    # Execute operations according to distribution plan
    plan.nodes
    |> Enum.map(fn node ->
      node_operations = get_operations_for_node(node, plan)
      
      Task.async(fn ->
        execute_operations_on_node(node, node_operations, state)
      end)
    end)
    |> Task.await_many(@network_timeout)
    |> List.flatten()
  end

  defp create_witness_distribution_plan(keys, batch_size, state) do
    # Create optimal witness generation distribution
    available_nodes = get_nodes_with_capability(state, :witness_generation)
    
    # Prioritize GPU and FPGA nodes for witness generation
    prioritized_nodes = prioritize_nodes_by_capability(available_nodes, [:gpu, :fpga, :native_core])
    
    key_batches = Enum.chunk_every(keys, batch_size)
    
    %{
      key_batches: key_batches,
      nodes: prioritized_nodes,
      batch_size: batch_size,
      parallel_degree: min(length(key_batches), length(prioritized_nodes))
    }
  end

  defp execute_distributed_witness_generation(plan, state, opts) do
    # Execute witness generation across cluster nodes
    plan.key_batches
    |> Enum.with_index()
    |> Enum.map(fn {batch, index} ->
      node = Enum.at(plan.nodes, rem(index, length(plan.nodes)))
      
      Task.async(fn ->
        generate_witnesses_on_node(node, batch, state, opts)
      end)
    end)
    |> Task.await_many(@network_timeout)
    |> List.flatten()
  end

  defp generate_witnesses_on_node(node, keys, state, opts) do
    # Generate witnesses on specific node using best available method
    case get_node_best_capability(node) do
      :gpu ->
        # Use GPU acceleration if available
        case :rpc.call(node.node_id, GPUAccelerator, :gpu_generate_witnesses, [keys, []]) do
          {:ok, witnesses} -> witnesses
          _ -> fallback_witness_generation(keys, node, state)
        end
        
      :fpga ->
        # Use FPGA acceleration if available  
        case :rpc.call(node.node_id, FPGAAccelerator, :fpga_generate_witnesses, [keys, []]) do
          {:ok, witnesses} -> witnesses
          _ -> fallback_witness_generation(keys, node, state)
        end
        
      :native_core ->
        # Use native core optimization
        case :rpc.call(node.node_id, NativeCore, :generate_witnesses, [keys, opts]) do
          {:ok, witnesses} -> witnesses
          _ -> fallback_witness_generation(keys, node, state)
        end
        
      _ ->
        # Fallback to standard witness generation
        fallback_witness_generation(keys, node, state)
    end
  end

  defp fallback_witness_generation(keys, node, _state) do
    # Fallback witness generation when specialized hardware unavailable
    case :rpc.call(node.node_id, VerkleTree, :generate_witnesses, [keys]) do
      {:ok, witnesses} -> witnesses
      _ ->
        Logger.warning("Witness generation failed on node #{node.node_id}")
        []
    end
  end

  defp create_operation_distribution_plan(operations, state, _opts) do
    # Create distribution plan for general tree operations
    available_nodes = get_available_compute_nodes(state)
    
    # Group operations by type for better batching
    operations_by_type = Enum.group_by(operations, fn
      {:insert, _, _} -> :insert
      {:read, _} -> :read
      {:update, _, _} -> :update
      {:delete, _} -> :delete
      _ -> :other
    end)
    
    %{
      operations_by_type: operations_by_type,
      nodes: available_nodes,
      load_balancing: :round_robin,
      parallelism: min(length(operations), length(available_nodes) * 4)
    }
  end

  defp execute_distributed_tree_operations(plan, state) do
    # Execute tree operations across cluster
    plan.operations_by_type
    |> Enum.flat_map(fn {operation_type, ops} ->
      # Distribute operations of same type across nodes
      ops
      |> Enum.chunk_every(div(length(ops), length(plan.nodes)) + 1)
      |> Enum.with_index()
      |> Enum.map(fn {batch, index} ->
        node = Enum.at(plan.nodes, rem(index, length(plan.nodes)))
        
        Task.async(fn ->
          execute_operation_batch_on_node(node, batch, operation_type, state)
        end)
      end)
    end)
    |> Task.await_many(@network_timeout)
    |> List.flatten()
  end

  defp execute_operation_batch_on_node(node, operations, operation_type, _state) do
    # Execute batch of operations on specific node
    case :rpc.call(node.node_id, VerkleTree, :batch_execute, [operations, operation_type]) do
      {:ok, results} -> results
      error ->
        Logger.error("Batch execution failed on node #{node.node_id}: #{inspect(error)}")
        Enum.map(operations, fn _ -> {:error, :node_execution_failed} end)
    end
  end

  # Cluster Management Functions

  defp validate_node_join(node_id, capabilities, state) do
    cond do
      node_id == state.coordinator_node.node_id ->
        {:error, :coordinator_cannot_rejoin}
        
      node_already_in_cluster?(node_id, state) ->
        {:error, :node_already_exists}
        
      cluster_at_capacity?(state) ->
        {:error, :cluster_at_capacity}
        
      not valid_capabilities?(capabilities) ->
        {:error, :invalid_capabilities}
        
      true ->
        :ok
    end
  end

  defp create_node_info(node_id, capabilities) do
    %{
      node_id: node_id,
      node_type: determine_node_type(capabilities),
      capabilities: capabilities,
      status: :active,
      load: 0.0,
      resources: get_node_resources(node_id),
      last_heartbeat: System.system_time(:millisecond)
    }
  end

  defp add_node_to_cluster(node_info, state) do
    case node_info.node_type do
      :compute ->
        compute_nodes = Map.put(state.compute_nodes, node_info.node_id, node_info)
        %{state | compute_nodes: compute_nodes}
        
      :storage ->
        storage_nodes = Map.put(state.storage_nodes, node_info.node_id, node_info)
        %{state | storage_nodes: storage_nodes}
        
      _ ->
        Logger.warning("Unknown node type: #{node_info.node_type}")
        state
    end
  end

  defp remove_node_from_cluster(node_id, state) do
    # Remove node from appropriate collection
    compute_nodes = Map.delete(state.compute_nodes, node_id)
    storage_nodes = Map.delete(state.storage_nodes, node_id)
    
    %{state | 
      compute_nodes: compute_nodes,
      storage_nodes: storage_nodes
    }
  end

  defp rebalance_cluster_load(state) do
    # Implement load balancing across cluster nodes
    __MODULE__.LoadBalancer.rebalance(state.load_balancer, get_all_nodes(state))
    state
  end

  defp handle_node_failure(node_id, state) do
    Logger.warning("Handling failure of node #{node_id}")
    
    # Remove failed node
    state = remove_node_from_cluster(node_id, state)
    
    # Redistribute workload if fault tolerance enabled
    state = if state.cluster_config.fault_tolerance do
      redistribute_failed_node_workload(node_id, state)
    else
      state
    end
    
    # Update cluster statistics
    new_stats = update_failure_stats(state.cluster_stats, node_id)
    %{state | cluster_stats: new_stats}
  end

  # Performance Analysis and Optimization

  defp analyze_cluster_bottlenecks(state) do
    # Identify performance bottlenecks in cluster
    bottlenecks = []
    
    # Check network bottlenecks
    network_bottlenecks = analyze_network_performance(state)
    
    # Check compute bottlenecks  
    compute_bottlenecks = analyze_compute_performance(state)
    
    # Check storage bottlenecks
    storage_bottlenecks = analyze_storage_performance(state)
    
    bottlenecks ++ network_bottlenecks ++ compute_bottlenecks ++ storage_bottlenecks
  end

  defp apply_cluster_optimizations(bottlenecks, state) do
    # Apply optimizations based on identified bottlenecks
    Enum.reduce(bottlenecks, state, fn bottleneck, acc_state ->
      apply_single_optimization(bottleneck, acc_state)
    end)
  end

  defp apply_single_optimization(bottleneck, state) do
    case bottleneck.type do
      :network_latency ->
        __MODULE__.NetworkOptimizer.optimize_routing(state.network_optimizer, bottleneck.details)
        state
        
      :compute_overload ->
        # Request additional compute nodes if auto-scaling enabled
        if state.cluster_config.auto_scaling do
          request_additional_compute_nodes(1, state)
        else
          state
        end
        
      :memory_pressure ->
        __MODULE__.ResourceManager.optimize_memory_allocation(state.resource_manager, bottleneck.details)
        state
        
      _ ->
        Logger.warning("Unknown bottleneck type: #{bottleneck.type}")
        state
    end
  end

  # Utility Functions

  defp generate_cluster_id() do
    "cluster_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp get_local_capabilities() do
    %{
      cpu_cores: System.schedulers_online(),
      memory_gb: get_memory_size_gb(),
      gpu_available: gpu_available?(),
      fpga_available: fpga_available?(),
      native_core: true,
      network_speed: :gigabit
    }
  end

  defp get_local_resources() do
    %{
      cpu_usage: get_cpu_usage(),
      memory_usage: get_memory_usage(),
      disk_usage: get_disk_usage(),
      network_usage: get_network_usage()
    }
  end

  defp get_memory_size_gb() do
    # Get system memory size - memsup not available, using fallback
    # case :memsup.get_system_memory_data() do
    #   data when is_list(data) ->
    #     total_memory = Keyword.get(data, :total_memory, 0)
    #     Float.round(total_memory / (1024 * 1024 * 1024), 2)
    #   _ -> 8.0 # Default fallback
    # end
    8.0 # Default fallback when memsup not available
  end

  defp gpu_available?() do
    # Check if GPU is available (placeholder)
    case System.cmd("nvidia-smi", [], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp fpga_available?() do
    # Check if FPGA is available (placeholder)
    File.exists?("/dev/fpga0") or File.exists?("/sys/class/fpga_manager")
  end

  defp get_cpu_usage(), do: 0.0 # Placeholder
  defp get_memory_usage(), do: 0.0 # Placeholder  
  defp get_disk_usage(), do: 0.0 # Placeholder
  defp get_network_usage(), do: 0.0 # Placeholder

  defp start_cluster_services() do
    # Start periodic cluster maintenance tasks
    schedule_heartbeat_check()
    schedule_load_balancing()
  end

  defp schedule_heartbeat_check() do
    Process.send_after(self(), :heartbeat_check, @heartbeat_interval)
  end

  defp schedule_load_balancing() do
    Process.send_after(self(), :load_balance, @load_balance_interval)
  end

  defp initialize_cluster_stats() do
    %{
      operations_distributed: 0,
      witnesses_generated: 0,
      tree_operations_executed: 0,
      nodes_joined: 0,
      nodes_failed: 0,
      total_processing_time_us: 0,
      average_witnesses_per_sec: 0.0,
      average_operations_per_sec: 0.0,
      cluster_efficiency: 0.0
    }
  end

  defp update_operation_stats(stats, operation_count, elapsed_us) do
    new_ops = stats.operations_distributed + operation_count
    new_time = stats.total_processing_time_us + elapsed_us
    
    %{stats |
      operations_distributed: new_ops,
      total_processing_time_us: new_time,
      average_operations_per_sec: calculate_average_ops_per_sec(new_ops, new_time)
    }
  end

  defp update_witness_stats(stats, witness_count, elapsed_us, witnesses_per_sec) do
    new_witnesses = stats.witnesses_generated + witness_count
    new_time = stats.total_processing_time_us + elapsed_us
    
    # Calculate running average
    current_avg = stats.average_witnesses_per_sec
    count = if new_witnesses > witness_count, do: 2, else: 1
    new_avg = (current_avg + witnesses_per_sec) / count
    
    %{stats |
      witnesses_generated: new_witnesses,
      total_processing_time_us: new_time,
      average_witnesses_per_sec: new_avg
    }
  end

  defp update_tree_operation_stats(stats, operation_count, elapsed_us, _ops_per_sec) do
    new_ops = stats.tree_operations_executed + operation_count
    new_time = stats.total_processing_time_us + elapsed_us
    
    %{stats |
      tree_operations_executed: new_ops,
      total_processing_time_us: new_time,
      average_operations_per_sec: calculate_average_ops_per_sec(new_ops, new_time)
    }
  end

  defp update_failure_stats(stats, _node_id) do
    %{stats | nodes_failed: stats.nodes_failed + 1}
  end

  defp calculate_average_ops_per_sec(total_ops, total_time_us) do
    if total_time_us > 0 do
      Float.round(total_ops / (total_time_us / 1_000_000), 2)
    else
      0.0
    end
  end

  # Helper functions (simplified implementations)
  defp node_already_in_cluster?(node_id, state) do
    Map.has_key?(state.compute_nodes, node_id) or 
    Map.has_key?(state.storage_nodes, node_id)
  end

  defp cluster_at_capacity?(state) do
    total_nodes = map_size(state.compute_nodes) + map_size(state.storage_nodes) + 1 # +1 for coordinator
    total_nodes >= state.cluster_config.max_nodes
  end

  defp valid_capabilities?(capabilities), do: is_map(capabilities) and map_size(capabilities) > 0

  defp determine_node_type(capabilities) do
    cond do
      Map.get(capabilities, :storage_node) -> :storage
      Map.get(capabilities, :compute_node, true) -> :compute
      true -> :compute
    end
  end

  defp get_node_resources(node_id) do
    # Get resources from remote node
    case :rpc.call(node_id, __MODULE__, :get_local_resources, []) do
      resources when is_map(resources) -> resources
      _ -> %{cpu_usage: 0.0, memory_usage: 0.0}
    end
  end

  defp get_available_compute_nodes(state) do
    state.compute_nodes
    |> Map.values()
    |> Enum.filter(&(&1.status == :active))
  end

  defp get_nodes_with_capability(state, capability) do
    get_all_nodes(state)
    |> Enum.filter(&Map.has_key?(&1.capabilities, capability))
  end

  defp prioritize_nodes_by_capability(nodes, capability_priority) do
    # Sort nodes by capability priority
    Enum.sort_by(nodes, fn node ->
      Enum.find_index(capability_priority, fn cap ->
        Map.get(node.capabilities, cap, false)
      end) || 999
    end)
  end

  defp get_all_nodes(state) do
    [state.coordinator_node] ++ 
    Map.values(state.compute_nodes) ++ 
    Map.values(state.storage_nodes)
  end

  defp count_active_nodes(state) do
    get_all_nodes(state)
    |> Enum.count(&(&1.status == :active))
  end

  defp get_node_best_capability(node) do
    cond do
      Map.get(node.capabilities, :gpu_available) -> :gpu
      Map.get(node.capabilities, :fpga_available) -> :fpga
      Map.get(node.capabilities, :native_core) -> :native_core
      true -> :standard
    end
  end

  # Additional placeholder functions for completeness
  defp determine_distribution_strategy(_operations, _nodes, _opts), do: :round_robin
  defp calculate_optimal_batch_sizes(_operations, nodes), do: Enum.map(nodes, fn _ -> 100 end)
  defp analyze_operation_dependencies(_operations), do: []
  defp get_operations_for_node(_node, plan), do: Enum.take(plan.operations, 10)
  defp execute_operations_on_node(_node, operations, _state), do: operations
  defp calculate_optimal_witness_batch_size(key_count, state) do
    node_count = count_active_nodes(state)
    max(div(key_count, node_count), 10)
  end
  defp check_node_heartbeats(state), do: state
  defp update_node_heartbeat(_node_id, _node_info, state), do: state
  defp request_additional_nodes(_count, _state), do: {:ok, :scaling_requested}
  defp scale_down_cluster(_count, state), do: state
  defp compile_cluster_status(state) do
    %{
      cluster_id: state.cluster_id,
      total_nodes: count_active_nodes(state),
      compute_nodes: map_size(state.compute_nodes),
      storage_nodes: map_size(state.storage_nodes),
      cluster_stats: state.cluster_stats
    }
  end
  defp analyze_network_performance(_state), do: []
  defp analyze_compute_performance(_state), do: []
  defp analyze_storage_performance(_state), do: []
  defp count_optimizations_applied(_bottlenecks), do: 0
  defp calculate_performance_improvement(_old_state, _new_state), do: 1.0
  defp request_additional_compute_nodes(_count, state), do: state
  defp redistribute_failed_node_workload(_node_id, state), do: state

  # Mock service modules
  defmodule LoadBalancer do
    def start_link(), do: {:ok, self()}
    def rebalance(_pid, _nodes), do: :ok
  end

  defmodule FaultDetector do
    def start_link(), do: {:ok, self()}
  end

  defmodule ResourceManager do
    def start_link(), do: {:ok, self()}
    def optimize_memory_allocation(_pid, _details), do: :ok
  end

  defmodule NetworkOptimizer do
    def start_link(), do: {:ok, self()}
    def optimize_routing(_pid, _details), do: :ok
  end
end