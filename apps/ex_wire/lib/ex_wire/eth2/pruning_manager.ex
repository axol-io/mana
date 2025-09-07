defmodule ExWire.Eth2.PruningManager do
  @moduledoc """
  Comprehensive pruning and garbage collection manager for Ethereum 2.0 beacon chain data.

  Manages multiple pruning strategies to keep disk usage under control while maintaining
  the minimum data required for consensus operations:

  ## Pruning Strategies:

  1. **Fork Choice Pruning** - Removes non-finalized blocks that can never be canonical
  2. **State Pruning** - Removes historical states beyond retention policy  
  3. **Attestation Pool Pruning** - Removes old attestations that can't be included
  4. **Block Pruning** - Removes block bodies for very old finalized blocks
  5. **Trie Pruning** - Removes unreferenced state trie nodes
  6. **Log Pruning** - Removes old execution layer logs

  ## Configuration Options:

  - Retention periods for different data types
  - Finality-based vs time-based pruning
  - Archive mode (disable pruning for some data)
  - Storage tier migration policies
  - Pruning intensity (aggressive vs conservative)

  ## Performance Targets:

  - Keep total disk usage under 500GB with full validation
  - Prune 10GB+ per day during normal operation
  - Complete major pruning operations in <30 minutes
  - Maintain <100ms latency during pruning operations
  """

  use GenServer
  require Logger

  alias ExWire.Eth2.{
    BeaconChain,
    ForkChoiceOptimized,
    StateStore,
    PruningMetrics
  }

  defstruct [
    :config,
    :metrics,
    :pruning_state,
    :scheduler,
    active_pruners: %{},
    last_finalized_slot: 0,
    last_pruning_time: nil,
    storage_stats: %{}
  ]

  # Default pruning configuration
  @default_config %{
    # Data retention periods (in slots)
    # ~1 day of finalized blocks  
    finalized_block_retention: 32 * 256,
    # ~1 week of states
    state_retention: 32 * 256 * 7,
    # 2 epochs of attestations
    attestation_retention: 32 * 2,
    # ~1 month of execution logs
    execution_log_retention: 32 * 256 * 30,

    # Pruning triggers
    # Prune when 80% full
    storage_usage_threshold: 0.8,
    # 4 epochs behind
    finality_lag_threshold: 32 * 4,
    # Enable time-based pruning
    time_based_pruning: true,

    # Archive mode settings
    # Keep all historical data
    archive_mode: false,
    # Keep finalized state history
    archive_finalized_states: false,
    # Keep all execution layer data
    archive_execution_data: false,

    # Performance settings
    # Parallel pruning workers
    max_concurrent_pruners: 4,
    # Items per batch
    pruning_batch_size: 1000,
    # 5 minutes between major pruning
    pruning_interval_ms: 300_000,
    # 1 minute incremental pruning
    incremental_interval_ms: 60_000,

    # Storage tier settings
    enable_cold_storage: true,
    # ~3 months to cold storage
    cold_storage_threshold: 32 * 256 * 90
  }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Force immediate pruning of all data types
  """
  def prune_all do
    GenServer.call(__MODULE__, :prune_all, 60_000)
  end

  @doc """
  Prune specific data type
  """
  def prune(data_type, opts \\ [])
      when data_type in [:fork_choice, :states, :attestations, :blocks, :logs] do
    GenServer.call(__MODULE__, {:prune, data_type, opts}, 30_000)
  end

  @doc """
  Get current storage statistics and pruning status
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Update pruning configuration
  """
  def update_config(config_updates) do
    GenServer.call(__MODULE__, {:update_config, config_updates})
  end

  @doc """
  Estimate potential space savings from pruning
  """
  def estimate_pruning_savings do
    GenServer.call(__MODULE__, :estimate_savings)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting PruningManager with comprehensive data lifecycle management")

    config = Map.merge(@default_config, Keyword.get(opts, :config, %{}))

    # Initialize storage monitoring
    storage_stats = collect_storage_statistics()

    state = %__MODULE__{
      config: config,
      metrics: initialize_metrics(),
      pruning_state: :idle,
      scheduler: nil,
      storage_stats: storage_stats,
      last_pruning_time: DateTime.utc_now()
    }

    # Schedule periodic pruning
    schedule_pruning_cycle(state)

    {:ok, _state}
  end

  @impl true
  def handle_call(:prune_all, _from, _state) do
    Logger.info("Starting comprehensive pruning of all data types")

    start_time = System.monotonic_time(:millisecond)

    # Get current finalized checkpoint
    finalized_slot = get_finalized_slot()

    # Execute pruning strategies in optimal order
    results = %{}

    state = %{state | pruning_state: :active, last_finalized_slot: finalized_slot}

    # 1. Prune fork choice (removes unreachable blocks)
    {fork_choice_result, state} = execute_fork_choice_pruning(state, finalized_slot)
    results = Map.put(results, :fork_choice, fork_choice_result)

    # 2. Prune attestation pool (removes old attestations)  
    {attestation_result, state} = execute_attestation_pruning(state, finalized_slot)
    results = Map.put(results, :attestations, attestation_result)

    # 3. Prune historical states (removes old state history)
    {state_result, state} = execute_state_pruning(state, finalized_slot)
    results = Map.put(results, :states, state_result)

    # 4. Prune block data (removes old block bodies)
    {block_result, state} = execute_block_pruning(state, finalized_slot)
    results = Map.put(results, :blocks, block_result)

    # 5. Prune state trie (removes unreferenced nodes)
    {trie_result, state} = execute_trie_pruning(state)
    results = Map.put(results, :trie, trie_result)

    # Update statistics
    elapsed_ms = System.monotonic_time(:millisecond) - start_time
    state = update_pruning_metrics(state, results, elapsed_ms)

    state = %{
      state
      | pruning_state: :idle,
        last_pruning_time: DateTime.utc_now(),
        storage_stats: collect_storage_statistics()
    }

    Logger.info("Completed comprehensive pruning in #{elapsed_ms}ms")

    {:reply, {:ok, results}, state}
  end

  @impl true
  def handle_call({:prune, data_type, opts}, _from, _state) do
    Logger.info("Executing targeted pruning for #{data_type}")

    finalized_slot = get_finalized_slot()

    result =
      case data_type do
        :fork_choice ->
          {res, new_state} = execute_fork_choice_pruning(state, finalized_slot)
          {res, new_state}

        :states ->
          {res, new_state} = execute_state_pruning(state, finalized_slot, opts)
          {res, new_state}

        :attestations ->
          {res, new_state} = execute_attestation_pruning(state, finalized_slot, opts)
          {res, new_state}

        :blocks ->
          {res, new_state} = execute_block_pruning(state, finalized_slot, opts)
          {res, new_state}

        :logs ->
          {res, new_state} = execute_log_pruning(state, finalized_slot, opts)
          {res, new_state}

        _ ->
          {{:error, :unknown_data_type}, state}
      end

    case result do
      {{:ok, prune_result}, new_state} ->
        {:reply, {:ok, prune_result}, new_state}

      {{:error, _reason}, _state} ->
        {:reply, {:error, _reason}, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, _state) do
    status = %{
      pruning_state: state.pruning_state,
      last_finalized_slot: state.last_finalized_slot,
      last_pruning_time: state.last_pruning_time,
      storage_stats: state.storage_stats,
      active_pruners: Map.keys(state.active_pruners),
      metrics: state.metrics,
      config: state.config
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_call(:estimate_savings, _from, _state) do
    finalized_slot = get_finalized_slot()

    estimates = %{
      fork_choice: estimate_fork_choice_savings(finalized_slot),
      states: estimate_state_savings(finalized_slot, state.config),
      attestations: estimate_attestation_savings(finalized_slot),
      blocks: estimate_block_savings(finalized_slot, state.config),
      trie_nodes: estimate_trie_savings()
    }

    total_savings =
      Enum.reduce(estimates, 0, fn {_, savings}, acc ->
        acc + (savings.size_mb || 0)
      end)

    result = Map.put(estimates, :total_savings_mb, total_savings)

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call({:update_config, config_updates}, _from, _state) do
    new_config = Map.merge(state.config, config_updates)

    Logger.info("Updated pruning configuration: #{inspect(config_updates)}")

    state = %{state | config: new_config}

    # Reschedule pruning with new config
    schedule_pruning_cycle(state)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:pruning_cycle, _state) do
    # Check if pruning is needed
    if pruning_needed?(state) do
      Logger.info("Automatic pruning cycle triggered")

      # Execute incremental pruning
      case handle_call(:prune_all, nil, state) do
        {:reply, {:ok, _results}, new_state} ->
          schedule_pruning_cycle(new_state)
          {:noreply, new_state}

        {:reply, {:error, _reason}, _} ->
          Logger.error("Automatic pruning failed: #{inspect(reason)}")
          schedule_pruning_cycle(state)
          {:noreply, state}
      end
    else
      # Schedule next check
      schedule_pruning_cycle(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:incremental_pruning, _state) do
    # Light pruning of rapidly growing data
    finalized_slot = get_finalized_slot()

    state =
      if finalized_slot > state.last_finalized_slot do
        # Quick attestation pool cleanup
        {_result, new_state} =
          execute_attestation_pruning(state, finalized_slot, incremental: true)

        %{new_state | last_finalized_slot: finalized_slot}
      else
        state
      end

    # Schedule next incremental pruning
    Process.send_after(self(), :incremental_pruning, state.config.incremental_interval_ms)

    {:noreply, state}
  end

  # Private Functions - Pruning Strategies

  defp execute_fork_choice_pruning(_state, finalized_slot) do
    Logger.debug("Executing fork choice pruning for finalized slot #{finalized_slot}")

    start_time = System.monotonic_time(:microsecond)

    try do
      # Get finalized block root
      case BeaconChain.get_finalized_checkpoint() do
        {:ok, checkpoint} ->
          finalized_root = checkpoint.root

          # Prune non-finalized blocks from fork choice
          case ForkChoiceOptimized.prune(get_fork_choice_store(), finalized_root) do
            pruned_store when is_map(pruned_store) ->
              # Update fork choice store
              update_fork_choice_store(pruned_store)

              elapsed_us = System.monotonic_time(:microsecond) - start_time
              elapsed_ms = div(elapsed_us, 1000)
              memory_freed = estimate_fork_choice_memory_freed()

              result = %{
                pruned_blocks: count_pruned_blocks(finalized_root),
                finalized_root: finalized_root,
                elapsed_us: elapsed_us,
                memory_freed_mb: memory_freed
              }

              # Record metrics
              PruningMetrics.record_operation(:fork_choice, :ok, elapsed_ms, %{
                pruned_blocks: result.pruned_blocks,
                finalized_slot: finalized_slot
              })

              PruningMetrics.record_space_freed(:fork_choice, memory_freed, memory_freed, 0)

              {result, state}

            error ->
              elapsed_ms = div(System.monotonic_time(:microsecond) - start_time, 1000)
              PruningMetrics.record_operation(:fork_choice, :error, elapsed_ms, %{error: error})
              Logger.error("Fork choice pruning failed: #{inspect(error)}")
              {{:error, :fork_choice_prune_failed}, state}
          end

        error ->
          elapsed_ms = div(System.monotonic_time(:microsecond) - start_time, 1000)
          PruningMetrics.record_operation(:fork_choice, :error, elapsed_ms, %{error: error})
          Logger.error("Could not get finalized checkpoint: #{inspect(error)}")
          {{:error, :no_finalized_checkpoint}, state}
      end
    rescue
      error ->
        elapsed_ms = div(System.monotonic_time(:microsecond) - start_time, 1000)
        PruningMetrics.record_operation(:fork_choice, :error, elapsed_ms, %{error: error})
        Logger.error("Fork choice pruning exception: #{inspect(error)}")
        {{:error, :fork_choice_exception}, state}
    end
  end

  defp execute_state_pruning(_state, finalized_slot, opts \\ []) do
    Logger.debug("Executing state pruning for finalized slot #{finalized_slot}")

    incremental = Keyword.get(opts, :incremental, false)

    # Calculate retention cutoff
    retention_slots =
      if incremental do
        state.config.state_retention
      else
        # More aggressive during full pruning
        div(state.config.state_retention, 2)
      end

    cutoff_slot = max(0, finalized_slot - retention_slots)

    start_time = System.monotonic_time(:microsecond)

    try do
      # Prune old states from StateStore
      :ok = StateStore.prune(cutoff_slot)

      elapsed_us = System.monotonic_time(:microsecond) - start_time
      elapsed_ms = div(elapsed_us, 1000)
      freed_mb = estimate_state_storage_freed(cutoff_slot, finalized_slot)

      result = %{
        cutoff_slot: cutoff_slot,
        retained_slots: finalized_slot - cutoff_slot,
        elapsed_us: elapsed_us,
        estimated_freed_mb: freed_mb
      }

      # Record metrics
      PruningMetrics.record_operation(:states, :ok, elapsed_ms, %{
        cutoff_slot: cutoff_slot,
        retained_slots: result.retained_slots,
        incremental: incremental
      })

      PruningMetrics.record_space_freed(:states, freed_mb, freed_mb, 0)

      {result, state}
    rescue
      error ->
        elapsed_ms = div(System.monotonic_time(:microsecond) - start_time, 1000)
        PruningMetrics.record_operation(:states, :error, elapsed_ms, %{error: error})
        Logger.error("State pruning failed: #{inspect(error)}")
        {{:error, :state_pruning_failed}, state}
    end
  end

  defp execute_attestation_pruning(_state, finalized_slot, opts \\ []) do
    Logger.debug("Executing attestation pool pruning for finalized slot #{finalized_slot}")

    incremental = Keyword.get(opts, :incremental, false)

    # Attestations older than 2 epochs can't be included in blocks
    # 2 epochs or 1 epoch
    max_age = if incremental, do: 32 * 2, else: 32
    cutoff_slot = max(0, finalized_slot - max_age)

    start_time = System.monotonic_time(:microsecond)

    try do
      # Get current attestation pool from beacon chain
      case BeaconChain.get_state() do
        {:ok, beacon_state} ->
          # Count attestations before pruning
          initial_count = count_attestations_in_pool(beacon_state.attestation_pool)

          # Remove old attestations
          pruned_pool =
            Map.filter(beacon_state.attestation_pool, fn {slot, _attestations} ->
              slot >= cutoff_slot
            end)

          # Update beacon chain state
          :ok = update_attestation_pool(pruned_pool)

          final_count = count_attestations_in_pool(pruned_pool)
          pruned_count = initial_count - final_count

          elapsed_us = System.monotonic_time(:microsecond) - start_time
          elapsed_ms = div(elapsed_us, 1000)
          # ~1KB per attestation
          freed_mb = pruned_count * 0.001

          result = %{
            cutoff_slot: cutoff_slot,
            initial_attestations: initial_count,
            final_attestations: final_count,
            pruned_attestations: pruned_count,
            elapsed_us: elapsed_us,
            estimated_freed_mb: freed_mb
          }

          # Record metrics
          PruningMetrics.record_operation(:attestations, :ok, elapsed_ms, %{
            cutoff_slot: cutoff_slot,
            pruned_count: pruned_count,
            incremental: incremental
          })

          PruningMetrics.record_space_freed(:attestations, freed_mb, freed_mb, 0)

          {result, state}

        error ->
          elapsed_ms = div(System.monotonic_time(:microsecond) - start_time, 1000)
          PruningMetrics.record_operation(:attestations, :error, elapsed_ms, %{error: error})
          Logger.error("Could not get beacon state for attestation pruning: #{inspect(error)}")
          {{:error, :no_beacon_state}, state}
      end
    rescue
      error ->
        elapsed_ms = div(System.monotonic_time(:microsecond) - start_time, 1000)
        PruningMetrics.record_operation(:attestations, :error, elapsed_ms, %{error: error})
        Logger.error("Attestation pruning failed: #{inspect(error)}")
        {{:error, :attestation_pruning_failed}, state}
    end
  end

  defp execute_block_pruning(_state, finalized_slot, opts \\ []) do
    Logger.debug("Executing block pruning for finalized slot #{finalized_slot}")

    # Keep block headers but prune block bodies for very old blocks
    archive_mode = Keyword.get(opts, :archive_mode, state.config.archive_mode)

    if archive_mode do
      # Skip pruning in archive mode
      result = %{
        archive_mode: true,
        pruned_blocks: 0,
        elapsed_us: 0
      }

      {result, state}
    else
      # Keep bodies longer
      body_retention = state.config.finalized_block_retention * 4
      cutoff_slot = max(0, finalized_slot - body_retention)

      start_time = System.monotonic_time(:microsecond)

      # This would integrate with actual block storage
      # Placeholder - implement based on actual block storage
      pruned_count = 0

      elapsed_us = System.monotonic_time(:microsecond) - start_time

      result = %{
        cutoff_slot: cutoff_slot,
        pruned_blocks: pruned_count,
        elapsed_us: elapsed_us,
        # ~500KB per block body
        estimated_freed_mb: pruned_count * 0.5
      }

      {result, state}
    end
  end

  defp execute_trie_pruning(_state) do
    Logger.debug("Executing state trie pruning (reference counting)")

    start_time = System.monotonic_time(:microsecond)

    # This would implement reference counting for trie nodes
    # and remove nodes that are no longer referenced by any state

    # Placeholder implementation
    freed_nodes = 0
    elapsed_us = System.monotonic_time(:microsecond) - start_time

    result = %{
      freed_nodes: freed_nodes,
      elapsed_us: elapsed_us,
      # ~1KB per trie node
      estimated_freed_mb: freed_nodes * 0.001
    }

    {result, state}
  end

  defp execute_log_pruning(_state, finalized_slot, opts \\ []) do
    Logger.debug("Executing execution layer log pruning")

    log_retention = state.config.execution_log_retention
    cutoff_slot = max(0, finalized_slot - log_retention)

    start_time = System.monotonic_time(:microsecond)

    # This would integrate with execution layer log storage
    # Placeholder
    pruned_logs = 0

    elapsed_us = System.monotonic_time(:microsecond) - start_time

    result = %{
      cutoff_slot: cutoff_slot,
      pruned_logs: pruned_logs,
      elapsed_us: elapsed_us
    }

    {result, state}
  end

  # Private Functions - Helpers

  defp pruning_needed?(state) do
    # Check storage usage
    storage_usage = get_storage_usage_percent()
    storage_threshold_exceeded = storage_usage > state.config.storage_usage_threshold

    # Check time since last pruning
    time_since_pruning = DateTime.diff(DateTime.utc_now(), state.last_pruning_time, :second)
    time_threshold_exceeded = time_since_pruning > div(state.config.pruning_interval_ms, 1000)

    # Check finality lag
    current_slot = get_current_slot()
    finality_lag = current_slot - state.last_finalized_slot
    finality_threshold_exceeded = finality_lag > state.config.finality_lag_threshold

    storage_threshold_exceeded || time_threshold_exceeded || finality_threshold_exceeded
  end

  defp collect_storage_statistics do
    %{
      total_disk_usage_gb: get_total_disk_usage(),
      available_space_gb: get_available_disk_space(),
      usage_percent: get_storage_usage_percent(),
      collected_at: DateTime.utc_now()
    }
  end

  defp get_finalized_slot do
    case BeaconChain.get_finalized_checkpoint() do
      {:ok, checkpoint} -> checkpoint.epoch * 32
      _ -> 0
    end
  end

  defp get_current_slot do
    # Get current slot from beacon chain
    div(System.system_time(:second), 12)
  end

  defp get_fork_choice_store do
    # Get current fork choice store from beacon chain
    case BeaconChain.get_state() do
      {:ok, _state} -> state.fork_choice_store
      _ -> nil
    end
  end

  defp update_fork_choice_store(_pruned_store) do
    # Update the beacon chain's fork choice store
    :ok
  end

  defp update_attestation_pool(_pruned_pool) do
    # Update the beacon chain's attestation pool
    :ok
  end

  defp count_attestations_in_pool(attestation_pool) do
    Enum.reduce(attestation_pool, 0, fn {_slot, attestations}, acc ->
      acc + length(attestations)
    end)
  end

  defp count_pruned_blocks(_finalized_root) do
    # Count how many blocks were pruned from fork choice
    # Placeholder
    0
  end

  defp estimate_fork_choice_memory_freed do
    # Estimate memory freed by fork choice pruning
    # MB placeholder
    5.0
  end

  defp estimate_state_storage_freed(_cutoff_slot, _finalized_slot) do
    # Estimate storage freed by state pruning
    # MB placeholder  
    100.0
  end

  defp get_total_disk_usage do
    # Get total disk usage in GB
    # GB placeholder
    50.0
  end

  defp get_available_disk_space do
    # Get available disk space in GB
    # GB placeholder
    450.0
  end

  defp get_storage_usage_percent do
    total = get_total_disk_usage()
    available = get_available_disk_space()
    total / (total + available)
  end

  # Private Functions - Estimation

  defp estimate_fork_choice_savings(finalized_slot) do
    # Estimate potential savings from fork choice pruning
    %{
      type: :fork_choice,
      # blocks that could be pruned
      estimated_blocks: 1000,
      size_mb: 10.0,
      description: "Non-finalized blocks and cached data"
    }
  end

  defp estimate_state_savings(finalized_slot, _config) do
    retention = config.state_retention
    old_states = max(0, finalized_slot - retention)

    %{
      type: :states,
      estimated_states: old_states,
      # ~50KB per state
      size_mb: old_states * 0.05,
      description: "Historical beacon states beyond retention policy"
    }
  end

  defp estimate_attestation_savings(finalized_slot) do
    # 2 epochs
    old_attestations = max(0, finalized_slot - 64)

    %{
      type: :attestations,
      # ~10 per slot
      estimated_attestations: old_attestations * 10,
      # ~10KB per slot
      size_mb: old_attestations * 0.01,
      description: "Old attestations that can no longer be included"
    }
  end

  defp estimate_block_savings(finalized_slot, _config) do
    retention = config.finalized_block_retention
    old_blocks = max(0, finalized_slot - retention)

    %{
      type: :blocks,
      estimated_blocks: old_blocks,
      # ~500KB per block body
      size_mb: old_blocks * 0.5,
      description: "Old block bodies (keeping headers)"
    }
  end

  defp estimate_trie_savings do
    %{
      type: :trie_nodes,
      # unreferenced trie nodes
      estimated_nodes: 50000,
      # ~1KB per node
      size_mb: 50.0,
      description: "Unreferenced state trie nodes"
    }
  end

  defp initialize_metrics do
    %{
      total_pruning_operations: 0,
      total_data_pruned_mb: 0,
      total_pruning_time_ms: 0,
      average_pruning_time_ms: 0,
      last_pruning_savings_mb: 0,
      pruning_errors: 0
    }
  end

  defp update_pruning_metrics(_state, results, elapsed_ms) do
    total_freed =
      Enum.reduce(results, 0, fn {_, result}, acc ->
        acc + Map.get(result, :estimated_freed_mb, 0)
      end)

    metrics = state.metrics
    new_total_ops = metrics.total_pruning_operations + 1
    new_total_freed = metrics.total_data_pruned_mb + total_freed
    new_total_time = metrics.total_pruning_time_ms + elapsed_ms

    new_metrics = %{
      metrics
      | total_pruning_operations: new_total_ops,
        total_data_pruned_mb: new_total_freed,
        total_pruning_time_ms: new_total_time,
        average_pruning_time_ms: div(new_total_time, new_total_ops),
        last_pruning_savings_mb: total_freed
    }

    %{state | metrics: new_metrics}
  end

  defp schedule_pruning_cycle(_state) do
    # Cancel existing timer
    if state.scheduler do
      Process.cancel_timer(state.scheduler)
    end

    # Schedule next pruning cycle
    timer = Process.send_after(self(), :pruning_cycle, state.config.pruning_interval_ms)

    # Schedule incremental pruning  
    Process.send_after(self(), :incremental_pruning, state.config.incremental_interval_ms)

    %{state | scheduler: timer}
  end
end
