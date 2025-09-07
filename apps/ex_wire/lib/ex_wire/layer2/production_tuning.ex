defmodule ExWire.Layer2.ProductionTuning do
  @moduledoc """
  Production performance tuning system for Layer 2 integration.
  Monitors real-world usage patterns and automatically optimizes performance.
  """

  use GenServer
  require Logger

  alias ExWire.Layer2.PerformanceBenchmark

  defstruct [
    :network,
    :tuning_profile,
    :current_metrics,
    :optimization_history,
    :auto_tuning_enabled,
    :performance_targets,
    :resource_limits
  ]

  @tuning_profiles [:conservative, :balanced, :aggressive, :custom]
  @optimization_categories [:throughput, :latency, :memory, :cpu, :network, :storage]

  @performance_targets %{
    conservative: %{
      min_ops_per_second: 500_000,
      max_latency_ms: 200,
      max_memory_mb: 1024,
      max_cpu_percent: 70
    },
    balanced: %{
      min_ops_per_second: 1_000_000,
      max_latency_ms: 100,
      max_memory_mb: 2048,
      max_cpu_percent: 80
    },
    aggressive: %{
      min_ops_per_second: 2_000_000,
      max_latency_ms: 50,
      max_memory_mb: 4096,
      max_cpu_percent: 90
    }
  }

  ## Client API

  @doc """
  Starts the production tuning system for a specific network.
  """
  def start_link(network, opts \\ []) do
    GenServer.start_link(__MODULE__, {network, opts}, name: via_tuple(network))
  end

  @doc """
  Enables automatic performance tuning.
  """
  def enable_auto_tuning(network, profile \\ :balanced) do
    GenServer.call(via_tuple(network), {:enable_auto_tuning, profile})
  end

  @doc """
  Disables automatic performance tuning.
  """
  def disable_auto_tuning(network) do
    GenServer.call(via_tuple(network), :disable_auto_tuning)
  end

  @doc """
  Runs a full performance analysis and optimization.
  """
  def run_optimization_cycle(network) do
    # 2 minute timeout
    GenServer.call(via_tuple(network), :run_optimization, 120_000)
  end

  @doc """
  Gets current performance metrics and tuning status.
  """
  def get_performance_status(network) do
    GenServer.call(via_tuple(network), :get_status)
  end

  @doc """
  Updates performance targets for custom tuning.
  """
  def update_targets(network, new_targets) do
    GenServer.call(via_tuple(network), {:update_targets, new_targets})
  end

  @doc """
  Gets optimization recommendations based on current performance.
  """
  def get_recommendations(network) do
    GenServer.call(via_tuple(network), :get_recommendations)
  end

  ## Server Callbacks

  @impl true
  def init({network, opts}) do
    profile = Keyword.get(opts, :profile, :balanced)
    auto_tuning = Keyword.get(opts, :auto_tuning, false)

    state = %__MODULE__{
      network: network,
      tuning_profile: profile,
      current_metrics: init_metrics(),
      optimization_history: [],
      auto_tuning_enabled: auto_tuning,
      performance_targets: get_targets_for_profile(profile),
      resource_limits: get_resource_limits()
    }

    # Start performance monitoring
    if auto_tuning do
      schedule_monitoring()
    end

    Logger.info("Production tuning system initialized for #{network} with #{profile} profile")
    {:ok, _state}
  end

  @impl true
  def handle_call({:enable_auto_tuning, profile}, _from, _state) do
    updated_state = %{
      state
      | auto_tuning_enabled: true,
        tuning_profile: profile,
        performance_targets: get_targets_for_profile(profile)
    }

    schedule_monitoring()
    Logger.info("Auto-tuning enabled for #{state.network} with #{profile} profile")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call(:disable_auto_tuning, _from, _state) do
    updated_state = %{state | auto_tuning_enabled: false}
    Logger.info("Auto-tuning disabled for #{state.network}")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call(:run_optimization, _from, _state) do
    Logger.info("Running optimization cycle for #{state.network}")

    # Collect current metrics
    current_metrics = collect_performance_metrics(state.network)

    # Analyze performance bottlenecks
    analysis = analyze_performance(current_metrics, state.performance_targets)

    # Generate optimization recommendations
    recommendations = generate_optimizations(analysis, state.tuning_profile)

    # Apply safe optimizations automatically
    applied_optimizations = apply_safe_optimizations(recommendations, state.network)

    # Update optimization history
    optimization_record = %{
      timestamp: DateTime.utc_now(),
      metrics_before: state.current_metrics,
      metrics_after: current_metrics,
      analysis: analysis,
      recommendations: recommendations,
      applied: applied_optimizations
    }

    updated_state = %{
      state
      | current_metrics: current_metrics,
        optimization_history: [optimization_record | state.optimization_history]
    }

    result = %{
      analysis: analysis,
      recommendations: recommendations,
      applied_optimizations: applied_optimizations,
      performance_improvement: calculate_improvement(state.current_metrics, current_metrics)
    }

    Logger.info("Optimization cycle completed for #{state.network}")
    {:reply, {:ok, result}, updated_state}
  end

  @impl true
  def handle_call(:get_status, _from, _state) do
    status = %{
      network: state.network,
      tuning_profile: state.tuning_profile,
      auto_tuning_enabled: state.auto_tuning_enabled,
      current_metrics: state.current_metrics,
      performance_targets: state.performance_targets,
      optimization_count: length(state.optimization_history),
      last_optimization: get_last_optimization(state.optimization_history)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call({:update_targets, new_targets}, _from, _state) do
    updated_targets = Map.merge(state.performance_targets, new_targets)
    updated_state = %{state | performance_targets: updated_targets, tuning_profile: :custom}

    Logger.info("Updated performance targets for #{state.network}")
    {:reply, :ok, updated_state}
  end

  @impl true
  def handle_call(:get_recommendations, _from, _state) do
    current_metrics = collect_performance_metrics(state.network)
    analysis = analyze_performance(current_metrics, state.performance_targets)
    recommendations = generate_optimizations(analysis, state.tuning_profile)

    {:reply, recommendations, state}
  end

  @impl true
  def handle_info(:monitor_performance, _state) do
    if state.auto_tuning_enabled do
      # Collect metrics and check if optimization is needed
      current_metrics = collect_performance_metrics(state.network)

      if needs_optimization?(current_metrics, state.performance_targets) do
        Logger.info("Performance degradation detected, running auto-optimization")

        # Run optimization asynchronously
        Task.start(fn ->
          GenServer.call(via_tuple(state.network), :run_optimization)
        end)
      end

      # Schedule next monitoring cycle
      schedule_monitoring()

      updated_state = %{state | current_metrics: current_metrics}
      {:noreply, updated_state}
    else
      {:noreply, state}
    end
  end

  ## Private Functions

  defp via_tuple(network) do
    {:via, Registry, {ExWire.Layer2.TuningRegistry, network}}
  end

  defp get_targets_for_profile(profile) do
    Map.get(@performance_targets, profile, @performance_targets.balanced)
  end

  defp get_resource_limits do
    %{
      max_memory_gb: 8,
      max_cpu_cores: System.schedulers_online(),
      max_network_connections: 10_000,
      max_storage_gb: 100
    }
  end

  defp init_metrics do
    %{
      throughput_ops_per_sec: 0,
      avg_latency_ms: 0,
      memory_usage_mb: 0,
      cpu_usage_percent: 0,
      network_connections: 0,
      error_rate: 0.0,
      last_updated: DateTime.utc_now()
    }
  end

  defp schedule_monitoring do
    # Monitor every 30 seconds
    Process.send_after(self(), :monitor_performance, 30_000)
  end

  defp collect_performance_metrics(network) do
    Logger.debug("Collecting performance metrics for #{network}")

    # In a real implementation, these would collect actual system metrics
    # For this implementation, we simulate realistic production metrics

    base_throughput =
      case network do
        :optimism_mainnet -> 1_200_000
        :arbitrum_mainnet -> 1_500_000
        :zksync_era_mainnet -> 900_000
      end

    # Add some realistic variance
    # -10% to +10%
    variance = :rand.uniform(20) - 10
    current_throughput = trunc(base_throughput * (1 + variance / 100))

    %{
      throughput_ops_per_sec: current_throughput,
      # 20-70ms
      avg_latency_ms: :rand.uniform(50) + 20,
      # 500-1500MB
      memory_usage_mb: :rand.uniform(1000) + 500,
      # 30-70%
      cpu_usage_percent: :rand.uniform(40) + 30,
      # 100-600 connections
      network_connections: :rand.uniform(500) + 100,
      # 0.01% max error rate
      error_rate: :rand.uniform(100) / 10000,
      gc_collections: :rand.uniform(10),
      process_count: :rand.uniform(200) + 50,
      beam_memory_total: :rand.uniform(500) + 200,
      last_updated: DateTime.utc_now()
    }
  end

  defp analyze_performance(metrics, targets) do
    analysis = %{
      throughput_status:
        analyze_throughput(metrics.throughput_ops_per_sec, targets.min_ops_per_second),
      latency_status: analyze_latency(metrics.avg_latency_ms, targets.max_latency_ms),
      memory_status: analyze_memory(metrics.memory_usage_mb, targets.max_memory_mb),
      cpu_status: analyze_cpu(metrics.cpu_usage_percent, targets.max_cpu_percent),
      bottlenecks: identify_bottlenecks(metrics, targets),
      overall_health: :healthy
    }

    # Determine overall health
    issues = count_performance_issues(analysis)

    overall_health =
      cond do
        issues == 0 -> :healthy
        issues <= 2 -> :degraded
        true -> :critical
      end

    %{analysis | overall_health: overall_health}
  end

  defp analyze_throughput(current, target) do
    ratio = current / target

    cond do
      ratio >= 1.2 -> :excellent
      ratio >= 1.0 -> :good
      ratio >= 0.8 -> :degraded
      true -> :critical
    end
  end

  defp analyze_latency(current, max_target) do
    cond do
      current <= max_target * 0.5 -> :excellent
      current <= max_target -> :good
      current <= max_target * 1.5 -> :degraded
      true -> :critical
    end
  end

  defp analyze_memory(current, max_target) do
    ratio = current / max_target

    cond do
      ratio <= 0.6 -> :excellent
      ratio <= 0.8 -> :good
      ratio <= 0.9 -> :degraded
      true -> :critical
    end
  end

  defp analyze_cpu(current, max_target) do
    cond do
      current <= max_target * 0.6 -> :excellent
      current <= max_target * 0.8 -> :good
      current <= max_target -> :degraded
      true -> :critical
    end
  end

  defp identify_bottlenecks(metrics, targets) do
    bottlenecks = []

    bottlenecks =
      if metrics.throughput_ops_per_sec < targets.min_ops_per_second do
        [:throughput | bottlenecks]
      else
        bottlenecks
      end

    bottlenecks =
      if metrics.avg_latency_ms > targets.max_latency_ms do
        [:latency | bottlenecks]
      else
        bottlenecks
      end

    bottlenecks =
      if metrics.memory_usage_mb > targets.max_memory_mb * 0.9 do
        [:memory | bottlenecks]
      else
        bottlenecks
      end

    bottlenecks =
      if metrics.cpu_usage_percent > targets.max_cpu_percent * 0.9 do
        [:cpu | bottlenecks]
      else
        bottlenecks
      end

    bottlenecks
  end

  defp generate_optimizations(analysis, profile) do
    optimizations = []

    # Throughput optimizations
    optimizations =
      if analysis.throughput_status in [:degraded, :critical] do
        throughput_optimizations(profile) ++ optimizations
      else
        optimizations
      end

    # Latency optimizations  
    optimizations =
      if analysis.latency_status in [:degraded, :critical] do
        latency_optimizations(profile) ++ optimizations
      else
        optimizations
      end

    # Memory optimizations
    optimizations =
      if analysis.memory_status in [:degraded, :critical] do
        memory_optimizations(profile) ++ optimizations
      else
        optimizations
      end

    # CPU optimizations
    optimizations =
      if analysis.cpu_status in [:degraded, :critical] do
        cpu_optimizations(profile) ++ optimizations
      else
        optimizations
      end

    # Sort by priority and safety
    Enum.sort_by(optimizations, fn opt -> {opt.priority, opt.safety_level} end, :desc)
  end

  defp throughput_optimizations(profile) do
    base_optimizations = [
      %{
        category: :throughput,
        type: :increase_batch_size,
        description: "Increase batch processing size for better throughput",
        impact: :medium,
        safety_level: :safe,
        priority: 8,
        implementation: fn -> increase_batch_size() end
      },
      %{
        category: :throughput,
        type: :optimize_concurrent_processing,
        description: "Optimize concurrent transaction processing",
        impact: :high,
        safety_level: :safe,
        priority: 9,
        implementation: fn -> optimize_concurrency() end
      }
    ]

    # Add profile-specific optimizations
    case profile do
      :aggressive ->
        base_optimizations ++
          [
            %{
              category: :throughput,
              type: :aggressive_caching,
              description: "Enable aggressive proof verification caching",
              impact: :high,
              safety_level: :moderate,
              priority: 7,
              implementation: fn -> enable_aggressive_caching() end
            }
          ]

      _ ->
        base_optimizations
    end
  end

  defp latency_optimizations(_profile) do
    [
      %{
        category: :latency,
        type: :optimize_proof_verification,
        description: "Optimize proof verification pipeline",
        impact: :high,
        safety_level: :safe,
        priority: 9,
        implementation: fn -> optimize_proof_verification() end
      },
      %{
        category: :latency,
        type: :reduce_network_overhead,
        description: "Reduce network protocol overhead",
        impact: :medium,
        safety_level: :safe,
        priority: 7,
        implementation: fn -> reduce_network_overhead() end
      }
    ]
  end

  defp memory_optimizations(_profile) do
    [
      %{
        category: :memory,
        type: :optimize_gc_settings,
        description: "Optimize garbage collection settings",
        impact: :medium,
        safety_level: :safe,
        priority: 6,
        implementation: fn -> optimize_gc_settings() end
      },
      %{
        category: :memory,
        type: :implement_memory_pooling,
        description: "Implement object pooling for frequently used objects",
        impact: :medium,
        safety_level: :safe,
        priority: 5,
        implementation: fn -> implement_memory_pooling() end
      }
    ]
  end

  defp cpu_optimizations(_profile) do
    [
      %{
        category: :cpu,
        type: :optimize_cpu_scheduling,
        description: "Optimize process scheduling and CPU affinity",
        impact: :medium,
        safety_level: :moderate,
        priority: 6,
        implementation: fn -> optimize_cpu_scheduling() end
      },
      %{
        category: :cpu,
        type: :reduce_computation_overhead,
        description: "Reduce unnecessary computational overhead",
        impact: :medium,
        safety_level: :safe,
        priority: 7,
        implementation: fn -> reduce_computation_overhead() end
      }
    ]
  end

  defp apply_safe_optimizations(recommendations, network) do
    Logger.info("Applying safe optimizations for #{network}")

    safe_recommendations =
      Enum.filter(recommendations, fn opt ->
        opt.safety_level == :safe and opt.priority >= 7
      end)

    applied =
      Enum.map(safe_recommendations, fn opt ->
        try do
          Logger.info("Applying optimization: #{opt.description}")
          result = opt.implementation.()

          %{
            type: opt.type,
            description: opt.description,
            result: :applied,
            details: result
          }
        catch
          :error, reason ->
            Logger.error("Failed to apply optimization #{opt.type}: #{inspect(reason)}")

            %{
              type: opt.type,
              description: opt.description,
              result: :failed,
              error: reason
            }
        end
      end)

    Logger.info("Applied #{length(applied)} safe optimizations")
    applied
  end

  defp needs_optimization?(metrics, targets) do
    throughput_degraded = metrics.throughput_ops_per_sec < targets.min_ops_per_second * 0.8
    latency_degraded = metrics.avg_latency_ms > targets.max_latency_ms * 1.2
    memory_critical = metrics.memory_usage_mb > targets.max_memory_mb * 0.95
    cpu_critical = metrics.cpu_usage_percent > targets.max_cpu_percent * 0.95

    throughput_degraded or latency_degraded or memory_critical or cpu_critical
  end

  defp count_performance_issues(analysis) do
    issue_statuses = [:degraded, :critical]

    issues = 0
    issues = if analysis.throughput_status in issue_statuses, do: issues + 1, else: issues
    issues = if analysis.latency_status in issue_statuses, do: issues + 1, else: issues
    issues = if analysis.memory_status in issue_statuses, do: issues + 1, else: issues
    if analysis.cpu_status in issue_statuses, do: issues + 1, else: issues
  end

  defp calculate_improvement(old_metrics, new_metrics) do
    %{
      throughput_change:
        calculate_percentage_change(
          old_metrics.throughput_ops_per_sec,
          new_metrics.throughput_ops_per_sec
        ),
      latency_change:
        calculate_percentage_change(old_metrics.avg_latency_ms, new_metrics.avg_latency_ms),
      memory_change:
        calculate_percentage_change(old_metrics.memory_usage_mb, new_metrics.memory_usage_mb),
      cpu_change:
        calculate_percentage_change(old_metrics.cpu_usage_percent, new_metrics.cpu_usage_percent)
    }
  end

  defp calculate_percentage_change(old_value, new_value) when old_value > 0 do
    (new_value - old_value) / old_value * 100
  end

  defp calculate_percentage_change(_old_value, _new_value), do: 0

  defp get_last_optimization([]), do: nil
  defp get_last_optimization([last | _]), do: last

  # Optimization implementation functions (simplified for this demo)
  defp increase_batch_size, do: %{batch_size_increased: true, new_size: 50}

  defp optimize_concurrency,
    do: %{concurrency_optimized: true, worker_count: System.schedulers_online() * 2}

  defp enable_aggressive_caching, do: %{aggressive_caching_enabled: true}
  defp optimize_proof_verification, do: %{proof_verification_optimized: true}
  defp reduce_network_overhead, do: %{network_overhead_reduced: true}
  defp optimize_gc_settings, do: %{gc_settings_optimized: true}
  defp implement_memory_pooling, do: %{memory_pooling_enabled: true}
  defp optimize_cpu_scheduling, do: %{cpu_scheduling_optimized: true}
  defp reduce_computation_overhead, do: %{computation_overhead_reduced: true}
end
