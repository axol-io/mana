defmodule ExWire.Eth2.PruningMetrics do
  @moduledoc """
  Comprehensive metrics collection and monitoring for pruning operations.

  Tracks:
  - Space savings from different pruning strategies
  - Pruning operation performance and timing
  - Storage tier utilization and migration patterns
  - Error rates and failure recovery
  - System impact during pruning operations
  - Long-term storage trends and efficiency

  Provides both real-time metrics and historical trend analysis to optimize
  pruning strategies and maintain system health.
  """

  use GenServer
  require Logger

  defstruct [
    :metrics_store,
    :config,
    :collectors,
    operation_history: [],
    space_tracking: %{},
    performance_stats: %{},
    error_counts: %{},
    system_impact: %{},
    storage_tiers: %{},
    trend_analysis: %{}
  ]

  # Metric collection intervals
  # 30 seconds
  @metric_collection_interval 30_000
  # 5 minutes
  @trend_analysis_interval 300_000
  # 3 days
  @history_retention_hours 72
  @performance_sample_size 100

  # Metric categories
  @space_metrics [
    :total_freed_mb,
    :fork_choice_freed_mb,
    :state_freed_mb,
    :attestation_freed_mb,
    :block_freed_mb,
    :trie_freed_mb
  ]
  @performance_metrics [
    :operation_duration_ms,
    :throughput_items_per_sec,
    :cpu_usage_percent,
    :memory_usage_mb,
    :io_wait_percent
  ]
  @error_metrics [:operation_failures, :timeout_count, :recovery_attempts, :partial_failures]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Record a pruning operation result
  """
  def record_operation(operation_type, result, duration_ms, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:record_operation, operation_type, result, duration_ms, metadata})
  end

  @doc """
  Record space freed by pruning operation
  """
  def record_space_freed(data_type, freed_mb, before_size_mb, after_size_mb) do
    GenServer.cast(
      __MODULE__,
      {:record_space_freed, data_type, freed_mb, before_size_mb, after_size_mb}
    )
  end

  @doc """
  Record system performance impact during pruning
  """
  def record_system_impact(cpu_percent, memory_mb, io_wait_percent, consensus_latency_ms) do
    GenServer.cast(
      __MODULE__,
      {:record_system_impact, cpu_percent, memory_mb, io_wait_percent, consensus_latency_ms}
    )
  end

  @doc """
  Record storage tier migration statistics
  """
  def record_tier_migration(from_tier, to_tier, items_moved, size_mb) do
    GenServer.cast(__MODULE__, {:record_tier_migration, from_tier, to_tier, items_moved, size_mb})
  end

  @doc """
  Get current metrics summary
  """
  def get_metrics_summary do
    GenServer.call(__MODULE__, :get_metrics_summary)
  end

  @doc """
  Get detailed metrics for specific time range
  """
  def get_metrics(from_time, to_time, categories \\ :all) do
    GenServer.call(__MODULE__, {:get_metrics, from_time, to_time, categories})
  end

  @doc """
  Get pruning efficiency analysis
  """
  def get_efficiency_analysis do
    GenServer.call(__MODULE__, :get_efficiency_analysis)
  end

  @doc """
  Get storage tier utilization report
  """
  def get_storage_report do
    GenServer.call(__MODULE__, :get_storage_report)
  end

  @doc """
  Get recommendations for pruning optimization
  """
  def get_optimization_recommendations do
    GenServer.call(__MODULE__, :get_recommendations)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting PruningMetrics with comprehensive monitoring")

    config = Keyword.get(opts, :config, %{})

    # Initialize ETS tables for metrics storage
    :ets.new(:pruning_operations, [:ordered_set, :public, :named_table])
    :ets.new(:space_tracking, [:set, :public, :named_table])
    :ets.new(:performance_samples, [:ordered_set, :public, :named_table])
    :ets.new(:system_impact_log, [:ordered_set, :public, :named_table])
    :ets.new(:tier_migrations, [:ordered_set, :public, :named_table])

    state = %__MODULE__{
      metrics_store: %{
        operations: :pruning_operations,
        space: :space_tracking,
        performance: :performance_samples,
        system: :system_impact_log,
        tiers: :tier_migrations
      },
      config: config,
      collectors: start_collectors(),
      space_tracking: initialize_space_tracking(),
      performance_stats: initialize_performance_stats(),
      error_counts: initialize_error_counts(),
      system_impact: initialize_system_impact(),
      storage_tiers: initialize_storage_tiers()
    }

    # Schedule periodic collection and analysis
    schedule_metric_collection()
    schedule_trend_analysis()
    schedule_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_cast({:record_operation, operation_type, result, duration_ms, metadata}, state) do
    timestamp = DateTime.utc_now()

    # Store operation record
    operation_record = %{
      timestamp: timestamp,
      operation_type: operation_type,
      result: result,
      duration_ms: duration_ms,
      metadata: metadata
    }

    :ets.insert(
      :pruning_operations,
      {DateTime.to_unix(timestamp, :microsecond), operation_record}
    )

    # Update running statistics
    state = update_operation_stats(state, operation_type, result, duration_ms)

    # Track operation in history (limited size)
    history =
      [operation_record | state.operation_history]
      |> Enum.take(@performance_sample_size)

    state = %{state | operation_history: history}

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:record_space_freed, data_type, freed_mb, before_size_mb, after_size_mb},
        state
      ) do
    timestamp = DateTime.utc_now()

    # Record space metrics
    space_record = %{
      timestamp: timestamp,
      data_type: data_type,
      freed_mb: freed_mb,
      before_size_mb: before_size_mb,
      after_size_mb: after_size_mb,
      efficiency_percent: if(before_size_mb > 0, do: freed_mb / before_size_mb * 100, else: 0)
    }

    key = "#{data_type}_#{DateTime.to_unix(timestamp, :second)}"
    :ets.insert(:space_tracking, {key, space_record})

    # Update cumulative tracking
    state = update_space_tracking(state, data_type, freed_mb)

    {:noreply, state}
  end

  @impl true
  def handle_cast(
        {:record_system_impact, cpu_percent, memory_mb, io_wait_percent, consensus_latency_ms},
        state
      ) do
    timestamp = DateTime.utc_now()

    impact_record = %{
      timestamp: timestamp,
      cpu_percent: cpu_percent,
      memory_mb: memory_mb,
      io_wait_percent: io_wait_percent,
      consensus_latency_ms: consensus_latency_ms,
      overall_impact:
        calculate_impact_score(cpu_percent, memory_mb, io_wait_percent, consensus_latency_ms)
    }

    :ets.insert(:system_impact_log, {DateTime.to_unix(timestamp, :microsecond), impact_record})

    # Update system impact tracking
    state = update_system_impact(state, impact_record)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_tier_migration, from_tier, to_tier, items_moved, size_mb}, state) do
    timestamp = DateTime.utc_now()

    migration_record = %{
      timestamp: timestamp,
      from_tier: from_tier,
      to_tier: to_tier,
      items_moved: items_moved,
      size_mb: size_mb,
      migration_type: classify_migration(from_tier, to_tier)
    }

    :ets.insert(:tier_migrations, {DateTime.to_unix(timestamp, :microsecond), migration_record})

    # Update tier statistics
    state = update_tier_stats(state, from_tier, to_tier, items_moved, size_mb)

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_metrics_summary, _from, state) do
    summary = %{
      operations: get_operation_summary(state),
      space_savings: get_space_summary(state),
      performance: get_performance_summary(state),
      system_impact: get_system_impact_summary(state),
      storage_tiers: get_storage_tier_summary(state),
      last_updated: DateTime.utc_now()
    }

    {:reply, {:ok, summary}, state}
  end

  @impl true
  def handle_call({:get_metrics, from_time, to_time, categories}, _from, state) do
    metrics = collect_metrics_for_period(from_time, to_time, categories)
    {:reply, {:ok, metrics}, state}
  end

  @impl true
  def handle_call(:get_efficiency_analysis, _from, state) do
    analysis = perform_efficiency_analysis(state)
    {:reply, {:ok, analysis}, state}
  end

  @impl true
  def handle_call(:get_storage_report, _from, state) do
    report = generate_storage_report(state)
    {:reply, {:ok, report}, state}
  end

  @impl true
  def handle_call(:get_recommendations, _from, state) do
    recommendations = generate_optimization_recommendations(state)
    {:reply, {:ok, recommendations}, state}
  end

  @impl true
  def handle_info(:collect_metrics, state) do
    # Collect current system metrics
    state = collect_current_metrics(state)

    schedule_metric_collection()
    {:noreply, state}
  end

  @impl true
  def handle_info(:analyze_trends, state) do
    # Perform trend analysis
    state = analyze_pruning_trends(state)

    schedule_trend_analysis()
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_old_metrics, state) do
    # Remove old metrics beyond retention period
    cleanup_old_data()

    schedule_cleanup()
    {:noreply, state}
  end

  # Private Functions - Statistics Updates

  defp update_operation_stats(state, operation_type, result, duration_ms) do
    stats = state.performance_stats

    # Update operation counts
    operation_key = {operation_type, result}
    current_count = Map.get(stats, operation_key, 0)
    stats = Map.put(stats, operation_key, current_count + 1)

    # Update duration statistics
    duration_key = "#{operation_type}_duration_ms"
    durations = Map.get(stats, duration_key, [])
    updated_durations = [duration_ms | Enum.take(durations, @performance_sample_size - 1)]
    stats = Map.put(stats, duration_key, updated_durations)

    # Update error tracking
    error_counts =
      if result in [:error, :timeout, :partial_failure] do
        error_type = "#{operation_type}_#{result}"
        current_errors = Map.get(state.error_counts, error_type, 0)
        Map.put(state.error_counts, error_type, current_errors + 1)
      else
        state.error_counts
      end

    %{state | performance_stats: stats, error_counts: error_counts}
  end

  defp update_space_tracking(state, data_type, freed_mb) do
    tracking = state.space_tracking

    # Update total freed space
    total_key = "#{data_type}_total_freed_mb"
    current_total = Map.get(tracking, total_key, 0.0)
    tracking = Map.put(tracking, total_key, current_total + freed_mb)

    # Update daily tracking
    today = Date.utc_today()
    daily_key = "#{data_type}_#{today}_freed_mb"
    daily_total = Map.get(tracking, daily_key, 0.0)
    tracking = Map.put(tracking, daily_key, daily_total + freed_mb)

    %{state | space_tracking: tracking}
  end

  defp update_system_impact(state, impact_record) do
    impact = state.system_impact

    # Track average impact over recent samples
    recent_impacts = Map.get(impact, :recent_samples, [])
    # Keep 100 samples
    updated_impacts = [impact_record | Enum.take(recent_impacts, 99)]

    # Calculate moving averages
    avg_cpu = calculate_average(updated_impacts, :cpu_percent)
    avg_memory = calculate_average(updated_impacts, :memory_mb)
    avg_io_wait = calculate_average(updated_impacts, :io_wait_percent)
    avg_latency = calculate_average(updated_impacts, :consensus_latency_ms)

    impact =
      Map.merge(impact, %{
        recent_samples: updated_impacts,
        avg_cpu_percent: avg_cpu,
        avg_memory_mb: avg_memory,
        avg_io_wait_percent: avg_io_wait,
        avg_consensus_latency_ms: avg_latency,
        impact_trend: determine_impact_trend(updated_impacts)
      })

    %{state | system_impact: impact}
  end

  defp update_tier_stats(state, from_tier, to_tier, items_moved, size_mb) do
    tiers = state.storage_tiers

    # Update migration counts
    migration_key = "#{from_tier}_to_#{to_tier}"
    current_migrations = Map.get(tiers, "#{migration_key}_count", 0)
    current_size = Map.get(tiers, "#{migration_key}_size_mb", 0.0)

    tiers =
      Map.merge(tiers, %{
        "#{migration_key}_count" => current_migrations + 1,
        "#{migration_key}_size_mb" => current_size + size_mb,
        "#{migration_key}_items" => Map.get(tiers, "#{migration_key}_items", 0) + items_moved
      })

    # Update tier utilization
    tiers = update_tier_utilization(tiers, from_tier, to_tier, size_mb)

    %{state | storage_tiers: tiers}
  end

  # Private Functions - Analysis

  defp perform_efficiency_analysis(state) do
    # Analyze pruning efficiency across different strategies
    space_stats = state.space_tracking
    perf_stats = state.performance_stats

    strategies = [:fork_choice, :states, :attestations, :blocks, :trie]

    efficiency_by_strategy =
      Enum.map(strategies, fn strategy ->
        total_freed = Map.get(space_stats, "#{strategy}_total_freed_mb", 0.0)
        duration_key = "#{strategy}_duration_ms"
        durations = Map.get(perf_stats, duration_key, [])

        avg_duration =
          if length(durations) > 0 do
            Enum.sum(durations) / length(durations)
          else
            0
          end

        efficiency_score =
          if avg_duration > 0 do
            # MB per second
            total_freed / (avg_duration / 1000)
          else
            0
          end

        %{
          strategy: strategy,
          total_freed_mb: total_freed,
          avg_duration_ms: avg_duration,
          efficiency_mb_per_sec: efficiency_score,
          operations_count: length(durations)
        }
      end)
      |> Enum.sort_by(& &1.efficiency_mb_per_sec, :desc)

    # Overall efficiency metrics
    total_freed = Enum.sum(Enum.map(efficiency_by_strategy, & &1.total_freed_mb))
    total_duration = Enum.sum(Enum.map(efficiency_by_strategy, & &1.avg_duration_ms))

    %{
      strategy_efficiency: efficiency_by_strategy,
      overall_efficiency_mb_per_sec:
        if(total_duration > 0, do: total_freed / (total_duration / 1000), else: 0),
      total_space_freed_mb: total_freed,
      most_efficient_strategy:
        case List.first(efficiency_by_strategy) do
          %{strategy: strategy} -> strategy
          _ -> nil
        end,
      least_efficient_strategy:
        case List.last(efficiency_by_strategy) do
          %{strategy: strategy} -> strategy
          _ -> nil
        end
    }
  end

  defp generate_storage_report(state) do
    # Generate comprehensive storage utilization report
    tiers = state.storage_tiers
    space_tracking = state.space_tracking

    tier_utilization = %{
      hot_storage: %{
        current_size_mb: get_current_tier_size(:hot),
        utilization_percent: get_tier_utilization_percent(:hot),
        avg_access_time_ms: get_avg_access_time(:hot),
        items_count: get_tier_item_count(:hot)
      },
      warm_storage: %{
        current_size_mb: get_current_tier_size(:warm),
        utilization_percent: get_tier_utilization_percent(:warm),
        avg_access_time_ms: get_avg_access_time(:warm),
        items_count: get_tier_item_count(:warm)
      },
      cold_storage: %{
        current_size_mb: get_current_tier_size(:cold),
        utilization_percent: get_tier_utilization_percent(:cold),
        avg_access_time_ms: get_avg_access_time(:cold),
        items_count: get_tier_item_count(:cold)
      }
    }

    migration_stats = calculate_migration_statistics(tiers)

    %{
      tier_utilization: tier_utilization,
      migration_statistics: migration_stats,
      storage_trends: analyze_storage_trends(space_tracking),
      optimization_opportunities:
        identify_storage_optimizations(tier_utilization, migration_stats)
    }
  end

  defp generate_optimization_recommendations(state) do
    efficiency = perform_efficiency_analysis(state)
    storage_report = generate_storage_report(state)
    system_impact = state.system_impact
    error_counts = state.error_counts

    recommendations = []

    # Performance recommendations
    # Less than 50 MB/s
    recommendations =
      if efficiency.overall_efficiency_mb_per_sec < 50 do
        [
          %{
            type: :performance,
            priority: :high,
            title: "Improve pruning efficiency",
            description:
              "Current pruning efficiency is #{Float.round(efficiency.overall_efficiency_mb_per_sec, 2)} MB/s. Consider increasing parallel workers or optimizing strategies.",
            suggested_config: %{max_concurrent_pruners: 6, pruning_batch_size: 2000}
          }
          | recommendations
        ]
      else
        recommendations
      end

    # Storage tier optimization
    hot_utilization = storage_report.tier_utilization.hot_storage.utilization_percent

    recommendations =
      if hot_utilization > 90 do
        [
          %{
            type: :storage,
            priority: :medium,
            title: "Hot storage tier is near capacity",
            description:
              "Hot storage is #{hot_utilization}% full. Consider reducing hot retention or increasing tier migration frequency.",
            suggested_config: %{hot_slots: 32, incremental_interval_ms: 30_000}
          }
          | recommendations
        ]
      else
        recommendations
      end

    # Error rate recommendations
    total_errors = Enum.sum(Map.values(error_counts))
    total_operations = Map.get(state.performance_stats, :total_operations, 1)
    error_rate = total_errors / total_operations * 100

    # More than 5% error rate
    recommendations =
      if error_rate > 5 do
        [
          %{
            type: :reliability,
            priority: :high,
            title: "High pruning error rate detected",
            description:
              "#{Float.round(error_rate, 1)}% of pruning operations are failing. Review error logs and consider adjusting retry policies.",
            suggested_config: %{max_retries: 5, failure_backoff_base_ms: 60_000}
          }
          | recommendations
        ]
      else
        recommendations
      end

    # System impact recommendations
    avg_cpu = Map.get(system_impact, :avg_cpu_percent, 0)
    # More than 20% CPU during pruning
    recommendations =
      if avg_cpu > 20 do
        [
          %{
            type: :system_impact,
            priority: :medium,
            title: "High CPU usage during pruning",
            description:
              "Pruning operations are using #{avg_cpu}% CPU on average. Consider reducing concurrency or scheduling during low-activity periods.",
            suggested_config: %{max_concurrent_pruners: 2, enable_load_aware_scheduling: true}
          }
          | recommendations
        ]
      else
        recommendations
      end

    %{
      recommendations:
        Enum.sort_by(recommendations, fn rec ->
          case rec.priority do
            :high -> 1
            :medium -> 2
            :low -> 3
          end
        end),
      overall_health_score:
        calculate_overall_health_score(efficiency, storage_report, system_impact, error_counts),
      # 24 hours
      next_review_date: DateTime.add(DateTime.utc_now(), 24 * 60 * 60, :second)
    }
  end

  # Private Functions - Summaries

  defp get_operation_summary(state) do
    history = state.operation_history

    if length(history) == 0 do
      %{total_operations: 0, success_rate: 0, avg_duration_ms: 0}
    else
      successful = Enum.count(history, &(&1.result == :ok))
      total = length(history)
      avg_duration = Enum.sum(Enum.map(history, & &1.duration_ms)) / total

      %{
        total_operations: total,
        successful_operations: successful,
        failed_operations: total - successful,
        success_rate: successful / total * 100,
        avg_duration_ms: Float.round(avg_duration, 2),
        recent_operations: Enum.take(history, 5)
      }
    end
  end

  defp get_space_summary(state) do
    tracking = state.space_tracking

    total_freed =
      Enum.reduce(@space_metrics, 0.0, fn metric, acc ->
        key = String.replace_suffix(Atom.to_string(metric), "_freed_mb", "_total_freed_mb")
        acc + Map.get(tracking, key, 0.0)
      end)

    today = Date.utc_today()

    today_freed =
      Enum.reduce(@space_metrics, 0.0, fn metric, acc ->
        strategy = String.replace_suffix(Atom.to_string(metric), "_freed_mb", "")
        key = "#{strategy}_#{today}_freed_mb"
        acc + Map.get(tracking, key, 0.0)
      end)

    %{
      total_space_freed_mb: Float.round(total_freed, 2),
      space_freed_today_mb: Float.round(today_freed, 2),
      avg_daily_savings_mb: Float.round(total_freed / max(Date.diff(today, ~D[2024-01-01]), 1), 2)
    }
  end

  defp get_performance_summary(state) do
    stats = state.performance_stats

    # Calculate average durations for each operation type
    operation_types = [:fork_choice, :states, :attestations, :blocks, :trie, :comprehensive]

    avg_durations =
      Enum.map(operation_types, fn op_type ->
        duration_key = "#{op_type}_duration_ms"
        durations = Map.get(stats, duration_key, [])

        avg =
          if length(durations) > 0 do
            Enum.sum(durations) / length(durations)
          else
            0
          end

        {op_type, Float.round(avg, 2)}
      end)
      |> Enum.into(%{})

    %{
      average_operation_durations_ms: avg_durations,
      total_pruning_time_min: calculate_total_pruning_time(state) / 60,
      performance_trend: determine_performance_trend(state)
    }
  end

  defp get_system_impact_summary(state) do
    impact = state.system_impact

    %{
      avg_cpu_usage_percent: Map.get(impact, :avg_cpu_percent, 0) |> Float.round(1),
      avg_memory_usage_mb: Map.get(impact, :avg_memory_mb, 0) |> Float.round(1),
      avg_io_wait_percent: Map.get(impact, :avg_io_wait_percent, 0) |> Float.round(1),
      avg_consensus_latency_ms: Map.get(impact, :avg_consensus_latency_ms, 0) |> Float.round(1),
      impact_trend: Map.get(impact, :impact_trend, :stable)
    }
  end

  defp get_storage_tier_summary(state) do
    tiers = state.storage_tiers

    %{
      hot_to_warm_migrations: Map.get(tiers, "hot_to_warm_count", 0),
      warm_to_cold_migrations: Map.get(tiers, "warm_to_cold_count", 0),
      total_data_migrated_mb: calculate_total_migrated_size(tiers),
      migration_efficiency: calculate_migration_efficiency(tiers)
    }
  end

  # Private Functions - Helpers

  defp initialize_space_tracking do
    Enum.reduce(@space_metrics, %{}, fn metric, acc ->
      key = String.replace_suffix(Atom.to_string(metric), "_freed_mb", "_total_freed_mb")
      Map.put(acc, key, 0.0)
    end)
  end

  defp initialize_performance_stats do
    %{total_operations: 0}
  end

  defp initialize_error_counts do
    %{}
  end

  defp initialize_system_impact do
    %{recent_samples: [], impact_trend: :stable}
  end

  defp initialize_storage_tiers do
    %{}
  end

  defp start_collectors do
    # Start background metric collectors if needed
    %{system_monitor: nil, storage_monitor: nil}
  end

  defp calculate_impact_score(cpu_percent, memory_mb, io_wait_percent, consensus_latency_ms) do
    # Weighted impact score (0-100)
    cpu_weight = 0.3
    memory_weight = 0.2
    io_weight = 0.3
    latency_weight = 0.2

    # Normalize values to 0-100 scale
    cpu_score = min(cpu_percent, 100)
    # Assume 1GB = 100 points
    memory_score = min(memory_mb / 10, 100)
    io_score = min(io_wait_percent, 100)
    # 1000ms = 100 points
    latency_score = min(consensus_latency_ms / 10, 100)

    cpu_weight * cpu_score + memory_weight * memory_score +
      io_weight * io_score + latency_weight * latency_score
  end

  defp classify_migration(from_tier, to_tier) do
    case {from_tier, to_tier} do
      {:hot, :warm} -> :normal_aging
      {:warm, :cold} -> :archival
      {:hot, :cold} -> :fast_archival
      {:cold, :warm} -> :retrieval
      {:warm, :hot} -> :promotion
      _ -> :other
    end
  end

  defp calculate_average(samples, field) do
    if length(samples) == 0 do
      0
    else
      values = Enum.map(samples, &Map.get(&1, field, 0))
      Enum.sum(values) / length(values)
    end
  end

  defp determine_impact_trend(samples) do
    if length(samples) < 10 do
      :insufficient_data
    else
      recent = Enum.take(samples, 5)
      older = Enum.slice(samples, 5, 5)

      recent_avg = calculate_average(recent, :overall_impact)
      older_avg = calculate_average(older, :overall_impact)

      diff_percent =
        if older_avg > 0 do
          (recent_avg - older_avg) / older_avg * 100
        else
          0
        end

      cond do
        diff_percent > 10 -> :increasing
        diff_percent < -10 -> :decreasing
        true -> :stable
      end
    end
  end

  defp update_tier_utilization(tiers, from_tier, to_tier, size_mb) do
    # Update tier size tracking
    from_key = "#{from_tier}_current_size_mb"
    to_key = "#{to_tier}_current_size_mb"

    current_from = Map.get(tiers, from_key, 0.0)
    current_to = Map.get(tiers, to_key, 0.0)

    Map.merge(tiers, %{
      from_key => max(0.0, current_from - size_mb),
      to_key => current_to + size_mb
    })
  end

  # Placeholder functions for tier operations (would integrate with actual storage)
  defp get_current_tier_size(_tier), do: 100.0
  defp get_tier_utilization_percent(_tier), do: 75.0
  defp get_avg_access_time(_tier), do: 10.0
  defp get_tier_item_count(_tier), do: 1000

  defp calculate_migration_statistics(_tiers) do
    %{total_migrations: 100, avg_migration_size_mb: 50.0}
  end

  defp analyze_storage_trends(_space_tracking) do
    %{trend: :stable, growth_rate_mb_per_day: 100.0}
  end

  defp identify_storage_optimizations(_tier_utilization, _migration_stats) do
    ["Consider increasing warm storage capacity", "Optimize cold storage access patterns"]
  end

  defp calculate_total_pruning_time(_state), do: 0.0
  defp determine_performance_trend(_state), do: :stable
  defp calculate_total_migrated_size(_tiers), do: 0.0
  defp calculate_migration_efficiency(_tiers), do: 85.0
  defp calculate_overall_health_score(_efficiency, _storage, _impact, _errors), do: 85.0

  defp collect_current_metrics(state) do
    # Collect current system metrics
    state
  end

  defp analyze_pruning_trends(state) do
    # Analyze trends in pruning performance
    state
  end

  defp collect_metrics_for_period(_from_time, _to_time, _categories) do
    %{collected_metrics: []}
  end

  defp cleanup_old_data do
    # Remove metrics older than retention period
    cutoff_time = DateTime.add(DateTime.utc_now(), -@history_retention_hours * 3600, :second)
    cutoff_unix = DateTime.to_unix(cutoff_time, :microsecond)

    :ets.select_delete(:pruning_operations, [
      {{:"$1", :_}, [{:<, :"$1", cutoff_unix}], [true]}
    ])

    :ets.select_delete(:performance_samples, [
      {{:"$1", :_}, [{:<, :"$1", cutoff_unix}], [true]}
    ])

    :ets.select_delete(:system_impact_log, [
      {{:"$1", :_}, [{:<, :"$1", cutoff_unix}], [true]}
    ])

    :ets.select_delete(:tier_migrations, [
      {{:"$1", :_}, [{:<, :"$1", cutoff_unix}], [true]}
    ])
  end

  defp schedule_metric_collection do
    Process.send_after(self(), :collect_metrics, @metric_collection_interval)
  end

  defp schedule_trend_analysis do
    Process.send_after(self(), :analyze_trends, @trend_analysis_interval)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_old_metrics, @history_retention_hours * 3600 * 1000)
  end
end
