defmodule ExWire.Eth2.PruningScheduler do
  @moduledoc """
  Intelligent pruning scheduler that orchestrates automated cleanup operations.

  Features:
  - Multi-tier scheduling (immediate, incremental, comprehensive)
  - Load-aware scheduling that backs off during high consensus activity
  - Priority-based pruning (critical operations first)
  - Failure recovery and retry logic
  - Integration with system monitoring

  The scheduler operates on three levels:

  1. **Immediate Pruning** - Triggered by storage thresholds or finality events
  2. **Incremental Pruning** - Regular light cleanup (every 1-5 minutes)  
  3. **Comprehensive Pruning** - Deep cleanup during low activity periods
  """

  use GenServer
  require Logger

  alias ExWire.Eth2.{
    PruningManager,
    BeaconChain
  }

  defstruct [
    :config,
    :schedule_state,
    :metrics,
    :load_monitor,
    active_jobs: %{},
    job_queue: [],
    last_comprehensive_prune: nil,
    system_load: :normal,
    pruning_paused: false,
    failure_count: 0
  ]

  # Pruning job priorities
  @priority_immediate 0
  @priority_high 1
  @priority_normal 2
  @priority_low 3
  @priority_maintenance 4

  # System load thresholds
  @load_high_cpu_percent 80
  @load_high_memory_percent 90
  # attestations/minute
  @load_high_consensus_activity 500

  # Retry configuration
  @max_failures_before_pause 5
  # 30 seconds
  @failure_backoff_base_ms 30_000
  # 5 minutes
  @failure_backoff_max_ms 300_000

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Schedule immediate pruning (bypasses normal scheduling)
  """
  def schedule_immediate(data_types, opts \\ []) do
    GenServer.cast(__MODULE__, {:schedule_immediate, data_types, opts})
  end

  @doc """
  Schedule incremental pruning for specific data type
  """
  def schedule_incremental(data_type, opts \\ []) do
    GenServer.cast(__MODULE__, {:schedule_incremental, data_type, opts})
  end

  @doc """
  Schedule comprehensive pruning during next maintenance window
  """
  def schedule_comprehensive(opts \\ []) do
    GenServer.cast(__MODULE__, {:schedule_comprehensive, opts})
  end

  @doc """
  Pause/resume automatic pruning
  """
  def set_pause_state(paused) when is_boolean(paused) do
    GenServer.cast(__MODULE__, {:set_pause_state, paused})
  end

  @doc """
  Get current scheduler status
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Get pruning job queue
  """
  def get_queue do
    GenServer.call(__MODULE__, :get_queue)
  end

  @doc """
  Cancel pending job by ID
  """
  def cancel_job(job_id) do
    GenServer.cast(__MODULE__, {:cancel_job, job_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting PruningScheduler with intelligent load-aware scheduling")

    config = get_scheduler_config(opts)

    state = %__MODULE__{
      config: config,
      schedule_state: :idle,
      metrics: initialize_scheduler_metrics(),
      load_monitor: start_load_monitor(),
      last_comprehensive_prune: DateTime.utc_now()
    }

    # Start scheduling cycles
    schedule_incremental_cycle()
    schedule_comprehensive_cycle()
    schedule_load_monitoring()

    {:ok, _state}
  end

  @impl true
  def handle_cast({:schedule_immediate, data_types, opts}, _state) do
    Logger.info("Scheduling immediate pruning for #{inspect(data_types)}")

    job = create_pruning_job(data_types, @priority_immediate, opts)
    state = enqueue_job(state, job)
    state = maybe_start_next_job(state)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:schedule_incremental, data_type, opts}, _state) do
    Logger.debug("Scheduling incremental pruning for #{data_type}")

    job = create_pruning_job([data_type], @priority_high, Map.put(opts, :incremental, true))
    state = enqueue_job(state, job)
    state = maybe_start_next_job(state)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:schedule_comprehensive, opts}, _state) do
    Logger.info("Scheduling comprehensive pruning")

    # Schedule for next maintenance window
    job = create_pruning_job(:all, @priority_low, opts)
    job = %{job | scheduled_time: next_maintenance_window()}

    state = enqueue_job(state, job)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_pause_state, paused}, _state) do
    Logger.info("Pruning scheduler #{if paused, do: "paused", else: "resumed"}")

    state = %{state | pruning_paused: paused}

    # Resume processing if unpaused
    state =
      if not paused do
        maybe_start_next_job(state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:cancel_job, job_id}, _state) do
    Logger.info("Cancelling pruning job #{job_id}")

    # Remove from queue
    job_queue = Enum.reject(state.job_queue, &(&1.id == job_id))

    # Cancel active job if running
    active_jobs =
      if Map.has_key?(state.active_jobs, job_id) do
        cancel_active_job(job_id)
        Map.delete(state.active_jobs, job_id)
      else
        state.active_jobs
      end

    state = %{state | job_queue: job_queue, active_jobs: active_jobs}

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_status, _from, _state) do
    status = %{
      schedule_state: state.schedule_state,
      system_load: state.system_load,
      pruning_paused: state.pruning_paused,
      active_jobs: Map.keys(state.active_jobs),
      queued_jobs: length(state.job_queue),
      last_comprehensive_prune: state.last_comprehensive_prune,
      failure_count: state.failure_count,
      metrics: state.metrics
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call(:get_queue, _from, _state) do
    queue_info =
      Enum.map(state.job_queue, fn job ->
        %{
          id: job.id,
          data_types: job.data_types,
          priority: job.priority,
          scheduled_time: job.scheduled_time,
          created_at: job.created_at,
          options: job.options
        }
      end)

    {:reply, {:ok, queue_info}, state}
  end

  @impl true
  def handle_info(:incremental_cycle, _state) do
    # Check if incremental pruning is needed
    state =
      if should_run_incremental_pruning?(state) do
        execute_incremental_pruning(state)
      else
        state
      end

    # Schedule next cycle
    schedule_incremental_cycle()

    {:noreply, state}
  end

  @impl true
  def handle_info(:comprehensive_cycle, _state) do
    # Check if comprehensive pruning is needed
    state =
      if should_run_comprehensive_pruning?(state) do
        execute_comprehensive_pruning(state)
      else
        state
      end

    # Schedule next cycle
    schedule_comprehensive_cycle()

    {:noreply, state}
  end

  @impl true
  def handle_info(:load_monitoring, _state) do
    # Update system load assessment
    current_load = assess_system_load()

    state = %{state | system_load: current_load}

    # Adjust scheduling based on load
    state = adjust_scheduling_for_load(state, current_load)

    # Schedule next monitoring
    schedule_load_monitoring()

    {:noreply, state}
  end

  @impl true
  def handle_info({:job_complete, job_id, result}, _state) do
    Logger.info("Pruning job #{job_id} completed: #{inspect(result)}")

    # Remove from active jobs
    active_jobs = Map.delete(state.active_jobs, job_id)

    # Update metrics
    state =
      case result do
        {:ok, _} ->
          update_scheduler_metrics(state, :job_success)
          |> reset_failure_count()

        {:error, _reason} ->
          Logger.error("Pruning job #{job_id} failed: #{inspect(reason)}")

          update_scheduler_metrics(state, :job_failure)
          |> increment_failure_count()
      end

    state = %{state | active_jobs: active_jobs, schedule_state: :idle}

    # Start next job if available
    state = maybe_start_next_job(state)

    {:noreply, state}
  end

  @impl true
  def handle_info({:job_timeout, job_id}, _state) do
    Logger.warning("Pruning job #{job_id} timed out")

    # Cancel the job
    cancel_active_job(job_id)

    # Remove from active jobs and update state
    active_jobs = Map.delete(state.active_jobs, job_id)

    state = %{
      state
      | active_jobs: active_jobs,
        schedule_state: :idle,
        failure_count: state.failure_count + 1
    }

    # Start next job
    state = maybe_start_next_job(state)

    {:noreply, state}
  end

  # Private Functions - Job Management

  defp create_pruning_job(data_types, priority, opts) do
    %{
      id: generate_job_id(),
      data_types: data_types,
      priority: priority,
      options: opts,
      created_at: DateTime.utc_now(),
      scheduled_time: DateTime.utc_now(),
      # 5 minutes default
      timeout_ms: Map.get(opts, :timeout_ms, 300_000),
      retries: 0,
      max_retries: Map.get(opts, :max_retries, 3)
    }
  end

  defp enqueue_job(_state, job) do
    # Insert job in priority order
    job_queue = insert_job_by_priority(state.job_queue, job)
    %{state | job_queue: job_queue}
  end

  defp insert_job_by_priority([], job), do: [job]

  defp insert_job_by_priority([head | tail], job) do
    if job.priority <= head.priority do
      [job, head | tail]
    else
      [head | insert_job_by_priority(tail, job)]
    end
  end

  defp maybe_start_next_job(_state) do
    cond do
      state.pruning_paused ->
        state

      state.schedule_state != :idle ->
        # Already running a job
        state

      state.failure_count >= @max_failures_before_pause ->
        Logger.warning("Too many failures, pausing pruning")
        %{state | pruning_paused: true}

      state.system_load == :critical ->
        Logger.debug("System load critical, deferring pruning")
        state

      state.job_queue == [] ->
        # No jobs to run
        state

      true ->
        start_next_job(state)
    end
  end

  defp start_next_job(_state) do
    [job | remaining_queue] = state.job_queue

    # Check if it's time to run this job
    if DateTime.diff(DateTime.utc_now(), job.scheduled_time, :millisecond) >= 0 do
      Logger.info("Starting pruning job #{job.id} for #{inspect(job.data_types)}")

      # Start the job
      task_pid = start_pruning_task(job)

      # Schedule timeout
      timeout_timer = Process.send_after(self(), {:job_timeout, job.id}, job.timeout_ms)

      job_info =
        Map.put(job, :task_pid, task_pid)
        |> Map.put(:timeout_timer, timeout_timer)

      %{
        state
        | job_queue: remaining_queue,
          active_jobs: Map.put(state.active_jobs, job.id, job_info),
          schedule_state: :running
      }
    else
      # Job not ready, check again later
      state
    end
  end

  defp start_pruning_task(job) do
    parent_pid = self()

    Task.start(fn ->
      result = execute_pruning_job(job)
      send(parent_pid, {:job_complete, job.id, result})
    end)
  end

  defp execute_pruning_job(job) do
    try do
      case job.data_types do
        :all ->
          PruningManager.prune_all()

        data_types when is_list(data_types) ->
          results =
            Enum.map(data_types, fn data_type ->
              PruningManager.prune(data_type, job.options)
            end)

          {:ok, results}

        data_type ->
          PruningManager.prune(data_type, job.options)
      end
    rescue
      error ->
        Logger.error("Pruning job execution failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp cancel_active_job(job_id) do
    # Cancel the task if it's still running
    # Implementation would depend on how tasks are managed
    :ok
  end

  # Private Functions - Scheduling Logic

  defp should_run_incremental_pruning?(state) do
    not state.pruning_paused and
      state.system_load in [:normal, :moderate] and
      incremental_pruning_due?(state)
  end

  defp should_run_comprehensive_pruning?(state) do
    not state.pruning_paused and
      state.system_load == :normal and
      comprehensive_pruning_due?(state) and
      in_maintenance_window?()
  end

  defp incremental_pruning_due?(state) do
    # Check if attestation pool is growing too large
    case get_attestation_pool_size() do
      size when size > 10_000 -> true
      _ -> false
    end
  end

  defp comprehensive_pruning_due?(state) do
    last_prune = _state.last_comprehensive_prune
    hours_since_prune = DateTime.diff(DateTime.utc_now(), last_prune, :hour)

    # Daily comprehensive pruning
    hours_since_prune >= 24
  end

  defp execute_incremental_pruning(_state) do
    Logger.debug("Executing incremental pruning")

    # Light pruning of rapidly growing data
    job = create_pruning_job([:attestations], @priority_high, %{incremental: true})
    enqueue_job(state, job)
  end

  defp execute_comprehensive_pruning(_state) do
    Logger.info("Executing comprehensive pruning")

    job = create_pruning_job(:all, @priority_normal, %{comprehensive: true})
    state = enqueue_job(state, job)

    %{state | last_comprehensive_prune: DateTime.utc_now()}
  end

  defp adjust_scheduling_for_load(_state, load) do
    case load do
      :critical ->
        # Cancel low-priority jobs
        job_queue = Enum.filter(state.job_queue, &(&1.priority <= @priority_normal))
        %{_state | job_queue: job_queue}

      :high ->
        # Delay low-priority jobs
        job_queue =
          Enum.map(state.job_queue, fn job ->
            if job.priority > @priority_normal do
              %{job | scheduled_time: DateTime.add(job.scheduled_time, 300, :second)}
            else
              job
            end
          end)

        %{state | job_queue: job_queue}

      _ ->
        state
    end
  end

  # Private Functions - System Monitoring

  defp assess_system_load do
    cpu_percent = get_cpu_usage_percent()
    memory_percent = get_memory_usage_percent()
    consensus_activity = get_consensus_activity_level()

    cond do
      cpu_percent > 95 or memory_percent > 95 ->
        :critical

      cpu_percent > @load_high_cpu_percent or
        memory_percent > @load_high_memory_percent or
          consensus_activity > @load_high_consensus_activity ->
        :high

      cpu_percent > 60 or memory_percent > 70 ->
        :moderate

      true ->
        :normal
    end
  end

  defp in_maintenance_window? do
    # Define maintenance window (e.g., 2-4 AM local time)
    current_hour = DateTime.utc_now().hour
    current_hour >= 2 and current_hour <= 4
  end

  defp next_maintenance_window do
    now = DateTime.utc_now()

    # Next 2 AM
    tomorrow_2am =
      now
      |> DateTime.to_date()
      |> Date.add(1)
      |> DateTime.new!(~T[02:00:00])

    tomorrow_2am
  end

  # Private Functions - Helpers

  defp get_scheduler_config(opts) do
    Map.merge(
      %{
        # 1 minute
        incremental_interval_ms: 60_000,
        # 1 hour
        comprehensive_interval_ms: 3_600_000,
        # 30 seconds
        load_monitoring_interval_ms: 30_000,
        max_concurrent_jobs: 2,
        enable_load_aware_scheduling: true
      },
      Keyword.get(opts, :config, %{})
    )
  end

  defp generate_job_id do
    "prune_#{System.unique_integer([:positive])}"
  end

  defp start_load_monitor do
    # Initialize system monitoring
    :ok
  end

  defp get_cpu_usage_percent do
    # Get current CPU usage
    # Placeholder
    50
  end

  defp get_memory_usage_percent do
    # Get current memory usage
    # Placeholder
    60
  end

  defp get_consensus_activity_level do
    # Get attestations per minute or similar metric
    # Placeholder
    200
  end

  defp get_attestation_pool_size do
    case BeaconChain.get_state() do
      {:ok, _state} ->
        Enum.reduce(state.attestation_pool || %{}, 0, fn {_slot, attestations}, acc ->
          acc + length(attestations)
        end)

      _ ->
        0
    end
  end

  defp initialize_scheduler_metrics do
    %{
      jobs_scheduled: 0,
      jobs_completed: 0,
      jobs_failed: 0,
      total_runtime_ms: 0,
      average_job_time_ms: 0,
      load_adjustments: 0
    }
  end

  defp update_scheduler_metrics(_state, metric_type) do
    metrics =
      case metric_type do
        :job_success ->
          completed = state.metrics.jobs_completed + 1
          %{_state.metrics | jobs_completed: completed}

        :job_failure ->
          %{state.metrics | jobs_failed: state.metrics.jobs_failed + 1}

        :load_adjustment ->
          %{state.metrics | load_adjustments: state.metrics.load_adjustments + 1}
      end

    %{state | metrics: metrics}
  end

  defp reset_failure_count(_state) do
    %{state | failure_count: 0}
  end

  defp increment_failure_count(_state) do
    %{state | failure_count: state.failure_count + 1}
  end

  defp schedule_incremental_cycle do
    # 1 minute
    Process.send_after(self(), :incremental_cycle, 60_000)
  end

  defp schedule_comprehensive_cycle do
    # 1 hour
    Process.send_after(self(), :comprehensive_cycle, 3_600_000)
  end

  defp schedule_load_monitoring do
    # 30 seconds
    Process.send_after(self(), :load_monitoring, 30_000)
  end
end
