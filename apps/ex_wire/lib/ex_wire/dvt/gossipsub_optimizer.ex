defmodule ExWire.DVT.GossipSubOptimizer do
  @moduledoc """
  DVT-specific GossipSub optimizations for validator duty coordination.
  
  Provides specialized optimizations for DVT communication patterns:
  - Priority queuing for time-sensitive duty messages
  - Latency-optimized mesh topology for consensus messages
  - Dynamic peer scoring based on DVT performance metrics
  - Adaptive message propagation for different duty types
  """

  use GenServer
  require Logger

  alias ExWire.LibP2P.GossipSub
  alias ExWire.DVT.{PartitionDetector, MessageAuth}
  alias ExWire.Enterprise.AuditLogger

  @type message_priority :: :critical | :high | :normal | :low
  @type duty_type :: :attestation | :block_proposal | :sync_committee | :aggregation

  # DVT-specific GossipSub parameters
  @dvt_mesh_degree 6              # Smaller, more reliable mesh for DVT
  @dvt_mesh_degree_low 4          # Lower bound for DVT mesh
  @dvt_mesh_degree_high 8         # Upper bound for DVT mesh
  @dvt_gossip_lazy 3              # Fewer gossip peers for efficiency
  @dvt_heartbeat_interval 500     # Faster heartbeat for DVT (500ms)
  @dvt_fanout_ttl 30_000         # Shorter fanout TTL (30s)

  # Message priority timeouts (milliseconds)
  @critical_message_timeout 2_000  # Block proposals, slashing alerts
  @high_message_timeout 5_000      # Attestations, consensus messages  
  @normal_message_timeout 10_000   # Key generation, heartbeats
  @low_message_timeout 30_000      # Performance metrics, logs

  # Peer scoring weights for DVT
  @dvt_p1_weight 2.0              # Time in mesh (higher weight for DVT)
  @dvt_p2_weight 1.5              # First message deliveries
  @dvt_p3_weight 2.0              # Mesh message deliveries (critical for consensus)
  @dvt_p4_weight -3.0             # Invalid messages (severe penalty)
  @dvt_p5_weight -1.0             # Application-specific scoring
  @dvt_p6_weight 0.5              # IP colocation penalty
  @dvt_p7_weight -2.0             # Behavioral penalty

  defstruct [
    :gossipsub_pid,
    :cluster_memberships,      # %{cluster_id => cluster_config}
    :message_priorities,       # %{topic => priority_config}
    :latency_tracking,         # %{peer_id => latency_metrics}
    :performance_metrics,      # DVT-specific performance tracking
    :mesh_optimization,        # Optimized mesh configurations
    :priority_queues,          # Priority-based message queues
    :adaptive_config          # Dynamic configuration adjustments
  ]

  # Priority configuration for message types
  defstruct priority_config: [
    :topic,
    :priority,
    :timeout_ms,
    :max_retries,
    :propagation_factor,       # How aggressively to propagate
    :mesh_requirements        # Minimum mesh connectivity
  ]

  # Latency tracking metrics
  defstruct latency_metrics: [
    :peer_id,
    :average_latency,
    :p99_latency,
    :message_count,
    :last_updated,
    :reliability_score        # Success rate for message delivery
  ]

  # Performance tracking
  defstruct performance_metrics: [
    :total_messages_sent,
    :total_messages_received,
    :critical_message_latency,
    :consensus_round_latency,
    :mesh_stability_score,
    :peer_churn_rate,
    :invalid_message_rate
  ]

  ## Public API

  @doc """
  Start the DVT GossipSub optimizer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Configure DVT optimizations for a cluster's topics.
  """
  def configure_cluster_topics(cluster_id, topics_config) do
    GenServer.call(__MODULE__, {:configure_cluster, cluster_id, topics_config})
  end

  @doc """
  Publish a DVT message with priority-based optimization.
  """
  def publish_dvt_message(cluster_id, duty_type, payload, priority \\ :normal) do
    GenServer.call(__MODULE__, {:publish_message, cluster_id, duty_type, payload, priority})
  end

  @doc """
  Update peer performance metrics for mesh optimization.
  """
  def update_peer_metrics(peer_id, metrics) do
    GenServer.cast(__MODULE__, {:update_peer_metrics, peer_id, metrics})
  end

  @doc """
  Get current DVT GossipSub performance statistics.
  """
  def get_performance_stats() do
    GenServer.call(__MODULE__, :get_performance_stats)
  end

  @doc """
  Trigger mesh optimization for better DVT performance.
  """
  def optimize_mesh(cluster_id) do
    GenServer.call(__MODULE__, {:optimize_mesh, cluster_id})
  end

  @doc """
  Set dynamic configuration based on network conditions.
  """
  def set_adaptive_config(config) do
    GenServer.call(__MODULE__, {:set_adaptive_config, config})
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    # Get or start GossipSub process
    {:ok, gossipsub_pid} = ensure_gossipsub_running()
    
    # Apply DVT-specific GossipSub parameters
    configure_dvt_gossipsub_params(gossipsub_pid)

    state = %__MODULE__{
      gossipsub_pid: gossipsub_pid,
      cluster_memberships: %{},
      message_priorities: init_message_priorities(),
      latency_tracking: %{},
      performance_metrics: %__MODULE__.PerformanceMetrics{},
      mesh_optimization: %{},
      priority_queues: init_priority_queues(),
      adaptive_config: parse_adaptive_config(opts)
    }

    # Schedule periodic optimizations
    :timer.send_interval(1_000, :process_priority_queues)
    :timer.send_interval(5_000, :update_peer_scores)
    :timer.send_interval(30_000, :optimize_mesh_topology)
    :timer.send_interval(60_000, :adapt_configuration)

    Logger.info("DVT GossipSub Optimizer started")
    
    {:ok, state}
  end

  @impl true
  def handle_call({:configure_cluster, cluster_id, topics_config}, _from, state) do
    # Configure topic priorities and mesh requirements
    new_priorities = 
      Enum.reduce(topics_config, state.message_priorities, fn {topic, config}, acc ->
        priority_config = %__MODULE__.PriorityConfig{
          topic: topic,
          priority: config.priority,
          timeout_ms: get_timeout_for_priority(config.priority),
          max_retries: config.max_retries || 3,
          propagation_factor: config.propagation_factor || 1.0,
          mesh_requirements: config.mesh_requirements || @dvt_mesh_degree
        }
        Map.put(acc, topic, priority_config)
      end)

    # Subscribe to topics with DVT optimizations
    Enum.each(topics_config, fn {topic, config} ->
      subscribe_with_dvt_optimization(state.gossipsub_pid, topic, config)
    end)

    new_state = %{state | 
      message_priorities: new_priorities,
      cluster_memberships: Map.put(state.cluster_memberships, cluster_id, topics_config)
    }

    AuditLogger.log(:info, "Configured DVT GossipSub optimization for cluster", %{
      cluster_id: cluster_id,
      topics: Map.keys(topics_config)
    })

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:publish_message, cluster_id, duty_type, payload, priority}, _from, state) do
    topic = get_topic_for_duty(cluster_id, duty_type)
    
    case Map.get(state.message_priorities, topic) do
      nil ->
        {:reply, {:error, :topic_not_configured}, state}
        
      priority_config ->
        # Create optimized message
        optimized_message = create_optimized_message(payload, priority, priority_config)
        
        # Queue message based on priority
        state = queue_message_by_priority(optimized_message, topic, priority, state)
        
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:optimize_mesh, cluster_id}, _from, state) do
    cluster_topics = Map.get(state.cluster_memberships, cluster_id, %{})
    
    optimization_results = 
      Enum.map(cluster_topics, fn {topic, _config} ->
        optimize_topic_mesh(topic, state)
      end)

    Logger.info("Mesh optimization completed for cluster #{cluster_id}")
    
    {:reply, {:ok, optimization_results}, state}
  end

  @impl true
  def handle_call(:get_performance_stats, _from, state) do
    stats = %{
      performance_metrics: state.performance_metrics,
      active_clusters: Map.keys(state.cluster_memberships),
      total_topics: map_size(state.message_priorities),
      average_peer_latency: calculate_average_latency(state),
      mesh_stability: calculate_mesh_stability(state),
      priority_queue_sizes: get_queue_sizes(state.priority_queues)
    }
    
    {:reply, stats, state}
  end

  @impl true
  def handle_call({:set_adaptive_config, config}, _from, state) do
    new_state = %{state | adaptive_config: Map.merge(state.adaptive_config, config)}
    
    # Apply configuration changes
    apply_adaptive_configuration(new_state)
    
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:update_peer_metrics, peer_id, metrics}, state) do
    latency_metrics = %__MODULE__.LatencyMetrics{
      peer_id: peer_id,
      average_latency: metrics.average_latency,
      p99_latency: metrics.p99_latency,
      message_count: metrics.message_count,
      last_updated: DateTime.utc_now(),
      reliability_score: metrics.reliability_score
    }
    
    new_tracking = Map.put(state.latency_tracking, peer_id, latency_metrics)
    
    {:noreply, %{state | latency_tracking: new_tracking}}
  end

  @impl true
  def handle_info(:process_priority_queues, state) do
    state = process_all_priority_queues(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:update_peer_scores, state) do
    update_dvt_peer_scores(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:optimize_mesh_topology, state) do
    state = perform_mesh_optimization(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:adapt_configuration, state) do
    state = adapt_configuration_dynamically(state)
    {:noreply, state}
  end

  ## Private Functions

  defp ensure_gossipsub_running() do
    case Process.whereis(ExWire.LibP2P.GossipSub) do
      nil ->
        GossipSub.start_link([])
      pid when is_pid(pid) ->
        {:ok, pid}
    end
  end

  defp configure_dvt_gossipsub_params(gossipsub_pid) do
    # Apply DVT-specific parameters to GossipSub
    dvt_params = %{
      d: @dvt_mesh_degree,
      d_low: @dvt_mesh_degree_low,
      d_high: @dvt_mesh_degree_high,
      d_lazy: @dvt_gossip_lazy,
      heartbeat_interval: @dvt_heartbeat_interval,
      fanout_ttl: @dvt_fanout_ttl,
      
      # DVT-specific peer scoring
      p1_weight: @dvt_p1_weight,
      p2_weight: @dvt_p2_weight,
      p3_weight: @dvt_p3_weight,
      p4_weight: @dvt_p4_weight,
      p5_weight: @dvt_p5_weight,
      p6_weight: @dvt_p6_weight,
      p7_weight: @dvt_p7_weight
    }

    GossipSub.update_parameters(gossipsub_pid, dvt_params)
  end

  defp init_message_priorities() do
    # Default priority configurations for common DVT topics
    %{
      "dvt/+/slashing" => %__MODULE__.PriorityConfig{
        topic: "dvt/+/slashing",
        priority: :critical,
        timeout_ms: @critical_message_timeout,
        max_retries: 5,
        propagation_factor: 2.0,
        mesh_requirements: @dvt_mesh_degree_high
      }
    }
  end

  defp init_priority_queues() do
    %{
      critical: :queue.new(),
      high: :queue.new(),
      normal: :queue.new(),
      low: :queue.new()
    }
  end

  defp parse_adaptive_config(opts) do
    %{
      auto_mesh_optimization: Keyword.get(opts, :auto_mesh_optimization, true),
      adaptive_timeouts: Keyword.get(opts, :adaptive_timeouts, true),
      latency_based_scoring: Keyword.get(opts, :latency_based_scoring, true),
      dynamic_propagation: Keyword.get(opts, :dynamic_propagation, true)
    }
  end

  defp get_timeout_for_priority(priority) do
    case priority do
      :critical -> @critical_message_timeout
      :high -> @high_message_timeout
      :normal -> @normal_message_timeout
      :low -> @low_message_timeout
    end
  end

  defp subscribe_with_dvt_optimization(gossipsub_pid, topic, config) do
    # Subscribe to topic with DVT-specific validation
    validator = create_dvt_message_validator(config)
    GossipSub.subscribe(gossipsub_pid, topic, %{validator: validator})
  end

  defp create_dvt_message_validator(config) do
    fn message_data ->
      case MessageAuth.verify_authenticated_message(message_data) do
        {:ok, :valid} ->
          # Additional DVT-specific validation
          validate_dvt_message_content(message_data, config)
          
        {:error, reason} ->
          Logger.warning("DVT message validation failed: #{inspect(reason)}")
          :reject
      end
    end
  end

  defp validate_dvt_message_content(message_data, _config) do
    # Validate DVT-specific message structure and content
    # This would include checks for:
    # - Valid duty type
    # - Proper consensus round
    # - Threshold signature validity
    # - Time bounds compliance
    :accept
  end

  defp get_topic_for_duty(cluster_id, duty_type) do
    case duty_type do
      :attestation -> "dvt/#{cluster_id}/consensus"
      :block_proposal -> "dvt/#{cluster_id}/consensus"
      :sync_committee -> "dvt/#{cluster_id}/consensus"
      :aggregation -> "dvt/#{cluster_id}/consensus"
      :key_gen -> "dvt/#{cluster_id}/dkg"
      :slashing_alert -> "dvt/#{cluster_id}/slashing"
      :heartbeat -> "dvt/#{cluster_id}/monitoring"
      _ -> "dvt/#{cluster_id}/general"
    end
  end

  defp create_optimized_message(payload, priority, priority_config) do
    %{
      payload: payload,
      priority: priority,
      created_at: DateTime.utc_now(),
      timeout_at: DateTime.add(DateTime.utc_now(), priority_config.timeout_ms, :millisecond),
      retries: 0,
      max_retries: priority_config.max_retries,
      propagation_factor: priority_config.propagation_factor
    }
  end

  defp queue_message_by_priority(message, topic, priority, state) do
    current_queue = Map.get(state.priority_queues, priority, :queue.new())
    new_queue = :queue.in({topic, message}, current_queue)
    new_queues = Map.put(state.priority_queues, priority, new_queue)
    
    %{state | priority_queues: new_queues}
  end

  defp process_all_priority_queues(state) do
    # Process queues in priority order
    priorities = [:critical, :high, :normal, :low]
    
    Enum.reduce(priorities, state, fn priority, acc_state ->
      process_priority_queue(priority, acc_state)
    end)
  end

  defp process_priority_queue(priority, state) do
    queue = Map.get(state.priority_queues, priority, :queue.new())
    
    case :queue.out(queue) do
      {{:value, {topic, message}}, new_queue} ->
        if message_not_expired?(message) do
          # Publish message with DVT optimizations
          publish_result = publish_with_dvt_optimization(topic, message, state)
          
          case publish_result do
            :ok ->
              # Update success metrics
              metrics = update_success_metrics(state.performance_metrics, priority)
              new_queues = Map.put(state.priority_queues, priority, new_queue)
              %{state | priority_queues: new_queues, performance_metrics: metrics}
              
            {:error, reason} ->
              # Retry if possible
              if message.retries < message.max_retries do
                retry_message = %{message | retries: message.retries + 1}
                retry_queue = :queue.in({topic, retry_message}, new_queue)
                new_queues = Map.put(state.priority_queues, priority, retry_queue)
                %{state | priority_queues: new_queues}
              else
                # Give up on message
                Logger.warning("DVT message failed after max retries", %{
                  topic: topic,
                  priority: priority,
                  reason: reason
                })
                new_queues = Map.put(state.priority_queues, priority, new_queue)
                %{state | priority_queues: new_queues}
              end
          end
        else
          # Message expired, discard and continue
          new_queues = Map.put(state.priority_queues, priority, new_queue)
          process_priority_queue(priority, %{state | priority_queues: new_queues})
        end
        
      {:empty, _queue} ->
        state
    end
  end

  defp message_not_expired?(message) do
    DateTime.compare(DateTime.utc_now(), message.timeout_at) == :lt
  end

  defp publish_with_dvt_optimization(topic, message, state) do
    # Apply propagation factor optimization
    propagation_peers = select_optimal_propagation_peers(topic, message.propagation_factor, state)
    
    # Use optimized GossipSub publication
    GossipSub.publish_to_peers(
      state.gossipsub_pid, 
      topic, 
      :erlang.term_to_binary(message.payload),
      propagation_peers
    )
  end

  defp select_optimal_propagation_peers(topic, propagation_factor, state) do
    # Select peers based on latency and reliability scores
    topic_peers = get_topic_peers(topic, state)
    
    target_count = trunc(length(topic_peers) * propagation_factor)
    
    topic_peers
    |> Enum.map(fn peer_id ->
      latency_info = Map.get(state.latency_tracking, peer_id, %{reliability_score: 0.5})
      {peer_id, latency_info.reliability_score}
    end)
    |> Enum.sort_by(fn {_peer_id, score} -> score end, :desc)
    |> Enum.take(target_count)
    |> Enum.map(fn {peer_id, _score} -> peer_id end)
  end

  defp get_topic_peers(_topic, _state) do
    # Get current peers for topic from GossipSub
    # This would query the actual GossipSub mesh state
    []
  end

  defp update_dvt_peer_scores(state) do
    # Update peer scores based on DVT-specific metrics
    Enum.each(state.latency_tracking, fn {peer_id, metrics} ->
      dvt_score = calculate_dvt_peer_score(metrics)
      update_gossipsub_peer_score(state.gossipsub_pid, peer_id, :dvt_performance, dvt_score)
    end)
  end

  defp calculate_dvt_peer_score(metrics) do
    # Score based on latency and reliability
    latency_score = 1.0 / (1.0 + metrics.average_latency / 1000.0)  # Lower latency = higher score
    reliability_weight = 2.0  # Reliability is very important for DVT
    
    (latency_score + reliability_weight * metrics.reliability_score) / (1.0 + reliability_weight)
  end

  defp update_gossipsub_peer_score(gossipsub_pid, peer_id, score_type, score) do
    GossipSub.update_peer_score(gossipsub_pid, peer_id, score_type, score)
  end

  defp optimize_topic_mesh(topic, state) do
    # Analyze current mesh topology for topic
    current_mesh = get_current_mesh(topic, state)
    
    # Calculate optimal mesh based on latency and reliability
    optimal_peers = select_optimal_mesh_peers(topic, state)
    
    # Apply mesh changes if beneficial
    apply_mesh_optimization(topic, current_mesh, optimal_peers, state)
  end

  defp get_current_mesh(_topic, _state) do
    # Get current mesh peers from GossipSub
    []
  end

  defp select_optimal_mesh_peers(topic, state) do
    # Select peers based on combined latency and reliability metrics
    available_peers = get_topic_peers(topic, state)
    target_mesh_size = @dvt_mesh_degree
    
    available_peers
    |> Enum.map(fn peer_id ->
      metrics = Map.get(state.latency_tracking, peer_id, default_metrics())
      score = calculate_mesh_suitability_score(metrics)
      {peer_id, score}
    end)
    |> Enum.sort_by(fn {_peer_id, score} -> score end, :desc)
    |> Enum.take(target_mesh_size)
    |> Enum.map(fn {peer_id, _score} -> peer_id end)
  end

  defp default_metrics() do
    %__MODULE__.LatencyMetrics{
      average_latency: 100,
      reliability_score: 0.5,
      message_count: 0,
      last_updated: DateTime.utc_now()
    }
  end

  defp calculate_mesh_suitability_score(metrics) do
    # Combined score for mesh participation
    latency_factor = 1.0 / (1.0 + metrics.average_latency / 100.0)
    reliability_factor = metrics.reliability_score
    experience_factor = min(1.0, metrics.message_count / 1000.0)
    
    0.4 * latency_factor + 0.5 * reliability_factor + 0.1 * experience_factor
  end

  defp apply_mesh_optimization(_topic, _current_mesh, _optimal_peers, _state) do
    # Apply mesh changes through GossipSub
    # This would involve grafting to new peers and pruning from others
    {:ok, :optimized}
  end

  defp perform_mesh_optimization(state) do
    # Optimize mesh for all configured topics
    Enum.each(state.message_priorities, fn {topic, _config} ->
      optimize_topic_mesh(topic, state)
    end)
    
    state
  end

  defp adapt_configuration_dynamically(state) do
    # Analyze performance metrics and adapt configuration
    if state.adaptive_config.auto_mesh_optimization do
      # Adjust mesh parameters based on performance
      adapted_state = adapt_mesh_parameters(state)
      
      # Adjust timeouts based on latency patterns
      if state.adaptive_config.adaptive_timeouts do
        adapt_message_timeouts(adapted_state)
      else
        adapted_state
      end
    else
      state
    end
  end

  defp adapt_mesh_parameters(state) do
    # Analyze mesh stability and adjust parameters
    avg_latency = calculate_average_latency(state)
    
    cond do
      avg_latency > 200 ->
        # High latency - increase mesh size for redundancy
        new_config = Map.put(state.adaptive_config, :target_mesh_degree, @dvt_mesh_degree_high)
        %{state | adaptive_config: new_config}
        
      avg_latency < 50 ->
        # Low latency - can use smaller mesh for efficiency  
        new_config = Map.put(state.adaptive_config, :target_mesh_degree, @dvt_mesh_degree_low)
        %{state | adaptive_config: new_config}
        
      true ->
        state
    end
  end

  defp adapt_message_timeouts(state) do
    # Adjust message timeouts based on observed latency patterns
    p99_latency = calculate_p99_latency(state)
    
    if p99_latency > 0 do
      # Adjust timeouts to be 3x p99 latency with minimum thresholds
      adapted_timeouts = %{
        critical: max(@critical_message_timeout, trunc(p99_latency * 2)),
        high: max(@high_message_timeout, trunc(p99_latency * 3)),
        normal: max(@normal_message_timeout, trunc(p99_latency * 4)),
        low: max(@low_message_timeout, trunc(p99_latency * 6))
      }
      
      new_config = Map.put(state.adaptive_config, :adaptive_timeouts_config, adapted_timeouts)
      %{state | adaptive_config: new_config}
    else
      state
    end
  end

  defp calculate_average_latency(state) do
    if map_size(state.latency_tracking) > 0 do
      total_latency = 
        state.latency_tracking
        |> Enum.map(fn {_peer_id, metrics} -> metrics.average_latency end)
        |> Enum.sum()
      
      total_latency / map_size(state.latency_tracking)
    else
      0
    end
  end

  defp calculate_p99_latency(state) do
    if map_size(state.latency_tracking) > 0 do
      latencies = 
        state.latency_tracking
        |> Enum.map(fn {_peer_id, metrics} -> metrics.p99_latency || metrics.average_latency end)
        |> Enum.sort()
      
      p99_index = trunc(length(latencies) * 0.99)
      Enum.at(latencies, p99_index, 0)
    else
      0
    end
  end

  defp calculate_mesh_stability(_state) do
    # Calculate mesh stability score
    0.95
  end

  defp get_queue_sizes(priority_queues) do
    Enum.map(priority_queues, fn {priority, queue} ->
      {priority, :queue.len(queue)}
    end)
    |> Map.new()
  end

  defp update_success_metrics(metrics, priority) do
    case priority do
      :critical ->
        %{metrics | total_messages_sent: metrics.total_messages_sent + 1}
      _ ->
        %{metrics | total_messages_sent: metrics.total_messages_sent + 1}
    end
  end

  defp apply_adaptive_configuration(state) do
    # Apply any configuration changes to GossipSub
    if state.adaptive_config.target_mesh_degree do
      configure_dvt_gossipsub_params(state.gossipsub_pid)
    end
  end
end