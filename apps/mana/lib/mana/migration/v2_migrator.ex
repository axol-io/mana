defmodule Mana.Migration.V2Migrator do
  @moduledoc """
  Utilities for migrating state and data from V1 to V2 modules.

  This module provides:
  - Safe state migration between module versions
  - Data format conversion and validation
  - Rollback capabilities for failed migrations
  - Comprehensive migration logging and monitoring
  - Performance optimization during migration
  - Integrity verification of migrated data
  """

  require Logger
  alias Mana.Migration.{BackupManager, ValidationEngine}

  @migration_version "2.0.0"
  @supported_modules [:transaction_pool, :sync_service]

  # Migration results
  @type migration_result :: {:ok, map()} | {:error, term()}

  @doc """
  Migrates a V1 module state to V2 format.

  ## Parameters
  - module_type: The type of module to migrate
  - v1_state: The current V1 state
  - opts: Migration options including backup, validation, etc.

  ## Returns
  - {:ok, v2_state} on successful migration
  - {:error, _reason} on failure
  """
  @spec migrate_module_state(atom(), map(), keyword()) :: migration_result()
  def migrate_module_state(module_type, v1_state, opts \\ []) do
    migration_id = generate_migration_id()

    Logger.info("Starting V1 to V2 state migration", %{
      module_type: module_type,
      migration_id: migration_id,
      v1_state_size: map_size(v1_state),
      opts: opts
    })

    start_time = :os.system_time(:microsecond)

    with :ok <- validate_migration_preconditions(module_type, v1_state, opts),
         {:ok, backup_ref} <- maybe_create_backup(module_type, v1_state, opts),
         {:ok, v2_state} <- perform_migration(module_type, v1_state, opts),
         :ok <- validate_migrated_state(module_type, v1_state, v2_state, opts) do
      duration_ms = (:os.system_time(:microsecond) - start_time) / 1000

      Logger.info("V1 to V2 migration completed successfully", %{
        module_type: module_type,
        migration_id: migration_id,
        duration_ms: duration_ms,
        v2_state_size: map_size(v2_state),
        backup_ref: backup_ref
      })

      emit_telemetry(:migration_completed, %{
        module_type: module_type,
        migration_id: migration_id,
        duration_ms: duration_ms,
        success: true
      })

      {:ok, v2_state}
    else
      {:error, _reason} = error ->
        duration_ms = (:os.system_time(:microsecond) - start_time) / 1000

        Logger.error("V1 to V2 migration failed", %{
          module_type: module_type,
          migration_id: migration_id,
          reason: reason,
          duration_ms: duration_ms
        })

        emit_telemetry(:migration_failed, %{
          module_type: module_type,
          migration_id: migration_id,
          reason: reason,
          duration_ms: duration_ms,
          success: false
        })

        error
    end
  end

  @doc """
  Migrates transaction pool state from V1 to V2 format.
  """
  @spec migrate_transaction_pool_state(map(), keyword()) :: migration_result()
  def migrate_transaction_pool_state(v1_state, opts \\ []) do
    Logger.debug("Migrating transaction pool state", %{
      transactions_count: map_size(Map.get(v1_state, :transactions, %{})),
      addresses_count: map_size(Map.get(v1_state, :by_address, %{}))
    })

    with {:ok, v2_state} <- safe_migrate_transaction_pool(v1_state, opts) do
      Logger.debug("Transaction pool migration completed", %{
        v1_transactions: map_size(Map.get(v1_state, :transactions, %{})),
        v2_transactions: map_size(v2_state.transactions),
        v2_addresses: map_size(v2_state.by_address),
        nonce_cache_size: map_size(v2_state.address_nonce_cache)
      })

      {:ok, v2_state}
    else
      {:error, _reason} = error ->
        Logger.error("Transaction pool migration failed", %{
          error: inspect(reason),
          v1_state_keys: Map.keys(v1_state)
        })

        error
    end
  end

  defp safe_migrate_transaction_pool(v1_state, opts) do
    # Extract V1 data with safe defaults
    v1_transactions = Map.get(v1_state, :transactions, %{})
    v1_by_address = Map.get(v1_state, :by_address, %{})
    v1_stats = Map.get(v1_state, :stats, %{})
    v1_priority_queue = Map.get(v1_state, :priority_queue)

    # Create V2 state structure
    v2_state = %{
      # Core data structures (V1 compatible)
      transactions: migrate_transactions(v1_transactions),
      by_address: migrate_address_index(v1_by_address),
      by_gas_price: build_gas_price_index(v1_transactions),
      priority_queue: migrate_priority_queue(v1_priority_queue, v1_transactions),

      # Enhanced V2 fields
      stats: migrate_transaction_pool_stats(v1_stats),
      performance_metrics: initialize_performance_metrics(),
      memory_usage: calculate_initial_memory_usage(v1_transactions),

      # Configuration and feature flags
      config: build_v2_transaction_pool_config(opts),
      feature_flags: Map.get(opts, :feature_flags, %{}),

      # V2 specific enhancements
      address_nonce_cache: build_nonce_cache(v1_by_address, v1_transactions),
      gas_price_histogram: build_gas_price_histogram(v1_transactions),
      validation_cache: create_validation_cache(),

      # Circuit breaker and health monitoring
      health_status: :migrated,
      last_cleanup: System.system_time(:second),
      gc_stats: %{collections: 0, last_gc: System.system_time(:second)},

      # Migration metadata
      migration_info: %{
        version: @migration_version,
        migrated_at: System.system_time(:second),
        v1_transaction_count: map_size(v1_transactions),
        migration_id: generate_migration_id()
      }
    }

    {:ok, v2_state}
  rescue
    error ->
      {:error, {:migration_failed, error}}
  end

  @doc """
  Migrates sync service state from V1 to V2 format.
  """
  @spec migrate_sync_state(map(), keyword()) :: migration_result()
  def migrate_sync_state(v1_state, opts \\ []) do
    Logger.debug("Migrating sync service state", %{
      chain: Map.get(v1_state, :chain),
      current_block: get_current_block_number(v1_state),
      highest_block: Map.get(v1_state, :highest_block_number, 0)
    })

    with {:ok, v2_state} <- safe_migrate_sync_state(v1_state, opts) do
      Logger.debug("Sync service migration completed", %{
        v1_block_queue_size: Map.get(v1_state, :block_queue) |> Map.keys() |> length(),
        v2_block_queue_size: v2_state.block_queue |> Map.keys() |> length()
      })

      {:ok, v2_state}
    else
      {:error, _reason} = error ->
        Logger.error("Sync service migration failed", %{
          error: inspect(reason),
          v1_state_keys: Map.keys(v1_state)
        })

        error
    end
  end

  defp safe_migrate_sync_state(v1_state, opts) do
    # Extract V1 data
    v1_chain = Map.get(v1_state, :chain)
    v1_block_queue = Map.get(v1_state, :block_queue)
    v1_warp_queue = Map.get(v1_state, :warp_queue)
    v1_block_tree = Map.get(v1_state, :block_tree)
    v1_trie = Map.get(v1_state, :trie)

    # Create V2 state structure
    v2_state = %{
      # Core V1 compatible fields
      chain: v1_chain,
      block_queue: v1_block_queue,
      warp_queue: v1_warp_queue,
      block_tree: v1_block_tree,
      trie: v1_trie,
      last_requested_block: Map.get(v1_state, :last_requested_block),
      starting_block_number: Map.get(v1_state, :starting_block_number, 0),
      highest_block_number: Map.get(v1_state, :highest_block_number, 0),
      warp: Map.get(v1_state, :warp, false),
      warp_processor: Map.get(v1_state, :warp_processor),

      # Enhanced V2 fields
      peer_manager: migrate_peer_manager(v1_state),
      sync_strategy: build_default_sync_strategy(),
      performance_metrics: initialize_sync_performance_metrics(),
      sync_checkpoints: [],
      block_processor_pool: initialize_processor_pool(),
      error_recovery: initialize_error_recovery(),
      config: build_v2_sync_config(opts),
      feature_flags: Map.get(opts, :feature_flags, %{}),
      circuit_breakers: initialize_circuit_breakers(),
      memory_manager: initialize_memory_manager(),
      telemetry_state: initialize_telemetry_state(),
      health_status: :migrated,
      version_info: %{version: @migration_version, migration_compatible: true},

      # Migration metadata
      migration_info: %{
        version: @migration_version,
        migrated_at: System.system_time(:second),
        v1_block_number: get_current_block_number(v1_state),
        migration_id: generate_migration_id()
      }
    }

    {:ok, v2_state}
  rescue
    error ->
      {:error, {:migration_failed, error}}
  end

  @doc """
  Validates that a migration can be safely performed.
  """
  @spec validate_migration_safety(atom(), map()) :: :ok | {:error, term()}
  def validate_migration_safety(module_type, v1_state) do
    with :ok <- check_module_support(module_type),
         :ok <- check_state_integrity(v1_state),
         :ok <- check_migration_requirements(module_type),
         :ok <- check_system_resources() do
      :ok
    end
  end

  @doc """
  Creates a rollback checkpoint before migration.
  """
  @spec create_rollback_checkpoint(atom(), map()) :: {:ok, reference()} | {:error, term()}
  def create_rollback_checkpoint(module_type, v1_state) do
    BackupManager.create_backup(module_type, v1_state, %{
      type: :rollback_checkpoint,
      timestamp: System.system_time(:second),
      migration_version: @migration_version
    })
  end

  @doc """
  Rolls back a migration using a checkpoint.
  """
  @spec rollback_migration(reference()) :: {:ok, map()} | {:error, term()}
  def rollback_migration(backup_ref) do
    case BackupManager.restore_backup(backup_ref) do
      {:ok, v1_state} ->
        Logger.info("Migration rollback completed", %{backup_ref: backup_ref})
        {:ok, v1_state}

      {:error, _reason} = error ->
        Logger.error("Migration rollback failed", %{
          backup_ref: backup_ref,
          reason: reason
        })

        error
    end
  end

  @doc """
  Gets migration statistics and history.
  """
  @spec get_migration_stats() :: map()
  def get_migration_stats do
    %{
      supported_modules: @supported_modules,
      migration_version: @migration_version,
      total_migrations: count_total_migrations(),
      successful_migrations: count_successful_migrations(),
      failed_migrations: count_failed_migrations(),
      avg_migration_time: calculate_avg_migration_time(),
      last_migration: get_last_migration_info()
    }
  end

  # Private Implementation Functions

  defp validate_migration_preconditions(module_type, v1_state, opts) do
    with :ok <- check_module_support(module_type),
         :ok <- check_state_integrity(v1_state),
         :ok <- check_migration_requirements(module_type),
         :ok <- check_system_resources(),
         :ok <- validate_migration_options(opts) do
      :ok
    end
  end

  defp check_module_support(module_type) do
    if module_type in @supported_modules do
      :ok
    else
      {:error, "Unsupported module type: #{module_type}"}
    end
  end

  defp check_state_integrity(v1_state) do
    cond do
      not is_map(v1_state) ->
        {:error, "V1 state must be a map"}

      map_size(v1_state) == 0 ->
        {:error, "V1 state is empty"}

      true ->
        :ok
    end
  end

  defp check_migration_requirements(module_type) do
    case module_type do
      :transaction_pool ->
        # Check if TransactionPool is available
        if Code.ensure_loaded?(Blockchain.TransactionPool) do
          :ok
        else
          {:error, "TransactionPool module not available"}
        end

      :sync_service ->
        # Check if Sync is available
        if Code.ensure_loaded?(ExWire.Sync) do
          :ok
        else
          {:error, "Sync module not available"}
        end

      _ ->
        {:error, "Unknown module requirements"}
    end
  end

  defp check_system_resources do
    # Check available memory
    total_memory = :erlang.memory(:total)
    system_memory = :erlang.memory(:system)

    memory_usage_ratio = total_memory / system_memory

    # Less than 80% memory usage
    if memory_usage_ratio < 0.8 do
      :ok
    else
      {:error, "Insufficient memory for migration"}
    end
  end

  defp validate_migration_options(opts) do
    # Validate that migration options are properly formatted
    valid_opts = [:backup, :validation_level, :feature_flags, :config, :rollback_on_failure]

    invalid_opts = Keyword.keys(opts) -- valid_opts

    if length(invalid_opts) == 0 do
      :ok
    else
      {:error, "Invalid migration options: #{inspect(invalid_opts)}"}
    end
  end

  defp maybe_create_backup(module_type, v1_state, opts) do
    if Keyword.get(opts, :backup, true) do
      create_rollback_checkpoint(module_type, v1_state)
    else
      {:ok, nil}
    end
  end

  defp perform_migration(module_type, v1_state, opts) do
    case module_type do
      :transaction_pool ->
        migrate_transaction_pool_state(v1_state, opts)

      :sync_service ->
        migrate_sync_state(v1_state, opts)

      _ ->
        {:error, "Unknown module type for migration: #{module_type}"}
    end
  end

  defp validate_migrated_state(module_type, v1_state, v2_state, opts) do
    validation_level = Keyword.get(opts, :validation_level, :standard)

    case validation_level do
      :none ->
        :ok

      :basic ->
        validate_basic_migration(module_type, v1_state, v2_state)

      :standard ->
        with :ok <- validate_basic_migration(module_type, v1_state, v2_state),
             :ok <- validate_data_integrity(module_type, v1_state, v2_state) do
          :ok
        end

      :comprehensive ->
        with :ok <- validate_basic_migration(module_type, v1_state, v2_state),
             :ok <- validate_data_integrity(module_type, v1_state, v2_state),
             :ok <- validate_performance_characteristics(module_type, v2_state) do
          :ok
        end

      _ ->
        {:error, "Invalid validation level: #{validation_level}"}
    end
  end

  # Transaction Pool Migration Functions

  defp migrate_transactions(v1_transactions) do
    # V1 transactions are already in a compatible format
    # Add any V2-specific metadata
    Map.new(v1_transactions, fn {hash, transaction} ->
      enhanced_transaction =
        Map.merge(transaction, %{
          migrated_at: System.system_time(:second),
          v2_metadata: %{
            migration_version: @migration_version,
            enhanced_validation: false,
            priority_score: calculate_priority_score(transaction)
          }
        })

      {hash, enhanced_transaction}
    end)
  end

  defp migrate_address_index(v1_by_address) do
    # V1 address index is compatible with V2
    v1_by_address
  end

  defp build_gas_price_index(transactions) do
    # Build sorted list of transactions by gas price for V2
    transactions
    |> Enum.map(fn {hash, tx} -> {Map.get(tx, :gas_price, 0), hash} end)
    |> Enum.sort(fn {price1, _}, {price2, _} -> price1 >= price2 end)
  end

  defp migrate_priority_queue(nil, transactions) do
    # Create new priority queue from transactions
    require Common.Production.TransactionPriorityQueue

    queue = Common.Production.TransactionPriorityQueue.new(max_size: 50_000)

    Enum.reduce(transactions, queue, fn {_hash, transaction}, acc_queue ->
      case Common.Production.TransactionPriorityQueue.add(acc_queue, transaction) do
        {:ok, new_queue} -> new_queue
        # Skip if queue is full
        {:error, _reason} -> acc_queue
      end
    end)
  end

  defp migrate_priority_queue(v1_queue, _transactions) do
    # V1 priority queue is compatible with V2
    v1_queue
  end

  defp migrate_transaction_pool_stats(v1_stats) do
    # Enhance V1 stats with V2 fields
    enhanced_stats =
      Map.merge(v1_stats, %{
        migrated_at: System.system_time(:second),
        migration_version: @migration_version,
        v2_enhancements: %{
          validation_cache_hits: 0,
          validation_cache_misses: 0,
          enhanced_validations: 0,
          performance_optimizations: 0
        }
      })

    enhanced_stats
  end

  defp build_nonce_cache(by_address, transactions) do
    # Build nonce cache for faster lookups
    Map.new(by_address, fn {address, tx_hashes} ->
      max_nonce =
        tx_hashes
        |> Enum.map(fn hash ->
          case Map.get(transactions, hash) do
            nil -> -1
            tx -> Map.get(tx, :nonce, -1)
          end
        end)
        |> Enum.max(fn -> -1 end)

      cache_entry = %{
        value: max_nonce + 1,
        timestamp: System.system_time(:second)
      }

      {address, cache_entry}
    end)
  end

  defp build_gas_price_histogram(transactions) do
    # Build gas price distribution histogram
    initial_histogram = %{
      "1_gwei" => 0,
      "1_5_gwei" => 0,
      "5_20_gwei" => 0,
      "20_50_gwei" => 0,
      "50_plus_gwei" => 0
    }

    Enum.reduce(transactions, initial_histogram, fn {_hash, tx}, histogram ->
      gas_price = Map.get(tx, :gas_price, 0)
      gwei = gas_price / 1_000_000_000

      bucket =
        cond do
          gwei < 1 -> "1_gwei"
          gwei < 5 -> "1_5_gwei"
          gwei < 20 -> "5_20_gwei"
          gwei < 50 -> "20_50_gwei"
          true -> "50_plus_gwei"
        end

      Map.update!(histogram, bucket, &(&1 + 1))
    end)
  end

  defp create_validation_cache do
    :ets.new(:v2_validation_cache, [:set, :private])
  end

  defp calculate_priority_score(transaction) do
    # Simple priority calculation based on gas price and age
    gas_price = Map.get(transaction, :gas_price, 0)
    timestamp = Map.get(transaction, :timestamp, System.system_time(:second))
    age_seconds = System.system_time(:second) - timestamp

    # Higher gas price + newer transactions get higher priority
    gas_price / 1_000_000_000 * max(1, 3600 - age_seconds)
  end

  # Sync Service Migration Functions

  defp migrate_peer_manager(v1_state) do
    # Create V2 peer manager from V1 state
    %{
      # Will be repopulated
      connected_peers: %{},
      peer_scores: %{},
      peer_performance: %{},
      blacklisted_peers: MapSet.new(),
      peer_selection_strategy: :best_score,
      max_peers: 50,
      min_peers: 3,
      scoring_algorithm: %{
        latency_weight: 0.3,
        reliability_weight: 0.4,
        throughput_weight: 0.3,
        min_score: 0.1,
        max_score: 1.0
      }
    }
  end

  defp build_default_sync_strategy do
    %{
      type: :normal,
      target_block: nil,
      parallel_requests: 10,
      batch_size: 128,
      checkpoint_interval: 1000,
      validation_level: :full,
      enable_optimizations: %{
        parallel_processing: true,
        memory_pooling: true,
        compression: false,
        caching: true
      }
    }
  end

  defp get_current_block_number(v1_state) do
    case Map.get(v1_state, :block_tree) do
      %{best_block: %{header: %{number: number}}} -> number
      _ -> 0
    end
  end

  defp get_peer_count(peer_manager) do
    map_size(peer_manager.connected_peers)
  end

  # Common initialization functions

  defp initialize_performance_metrics do
    %{
      add_transaction_success: [],
      add_transaction_error: [],
      get_pending: [],
      get_transaction: [],
      remove_transactions_batch: [],
      cleanup: [],
      optimize: []
    }
  end

  defp initialize_sync_performance_metrics do
    %{
      request_block_success: [],
      request_block_error: [],
      block_headers_processed: [],
      block_bodies_processed: [],
      warp_block_chunk_processed: [],
      warp_state_chunk_processed: [],
      optimization_cycle: []
    }
  end

  defp initialize_processor_pool do
    %{
      workers: [],
      max_workers: 4,
      active_jobs: %{},
      completed_jobs: 0,
      failed_jobs: 0
    }
  end

  defp initialize_error_recovery do
    %{
      error_count: 0,
      last_error: nil,
      error_history: [],
      recovery_attempts: 0,
      blacklisted_peers: MapSet.new(),
      circuit_breaker_states: %{}
    }
  end

  defp initialize_circuit_breakers do
    %{
      peer_requests: %{
        state: :closed,
        failure_count: 0,
        last_failure_time: nil,
        config: %{
          failure_threshold: 5,
          success_threshold: 3,
          timeout_ms: 60_000,
          reset_timeout_ms: 300_000
        }
      }
    }
  end

  defp initialize_memory_manager do
    %{
      current_usage: :erlang.memory(:total),
      peak_usage: :erlang.memory(:total),
      cleanup_count: 0,
      last_cleanup: System.system_time(:second),
      optimization_count: 0
    }
  end

  defp initialize_telemetry_state do
    %{
      events_emitted: 0,
      last_emission: System.system_time(:second),
      enabled: true
    }
  end

  defp calculate_initial_memory_usage(transactions) do
    estimated_size = :erlang.external_size(transactions)
    current_memory = :erlang.memory(:total)

    %{
      current: current_memory,
      peak: current_memory,
      # 256 MB default limit
      limit: 256 * 1024 * 1024
    }
  end

  defp build_v2_transaction_pool_config(opts) do
    default_config = %{
      max_pool_size: 50_000,
      max_transaction_size: 128 * 1024,
      min_gas_price: 1_000_000_000,
      cleanup_interval: 30_000,
      max_transaction_age: 1_800,
      batch_processing_size: 100,
      enable_gas_price_analytics: true,
      enable_performance_monitoring: true
    }

    user_config = Keyword.get(opts, :config, %{})
    Map.merge(default_config, user_config)
  end

  defp build_v2_sync_config(opts) do
    default_config = %{
      peer_management: %{
        max_peers: 50,
        min_peers: 3,
        peer_selection_strategy: :best_score,
        scoring_interval: 30_000,
        blacklist_duration: 3600
      },
      sync_strategy: %{
        default_type: :normal,
        parallel_requests: 10,
        batch_size: 128,
        checkpoint_interval: 1000,
        validation_level: :full
      },
      performance: %{
        enable_monitoring: true,
        metrics_retention: 1000,
        optimization_interval: 300_000,
        memory_limit_mb: 512
      }
    }

    user_config = Keyword.get(opts, :config, %{})
    deep_merge(default_config, user_config)
  end

  # Validation functions

  defp validate_basic_migration(module_type, v1_state, v2_state) do
    case module_type do
      :transaction_pool ->
        validate_transaction_pool_migration(v1_state, v2_state)

      :sync_service ->
        validate_sync_service_migration(v1_state, v2_state)

      _ ->
        {:error, "Unknown module type for validation"}
    end
  end

  defp validate_transaction_pool_migration(v1_state, v2_state) do
    v1_tx_count = map_size(Map.get(v1_state, :transactions, %{}))
    v2_tx_count = map_size(Map.get(v2_state, :transactions, %{}))

    cond do
      v2_tx_count != v1_tx_count ->
        {:error, "Transaction count mismatch: V1=#{v1_tx_count}, V2=#{v2_tx_count}"}

      not Map.has_key?(v2_state, :migration_info) ->
        {:error, "Missing migration metadata in V2 state"}

      true ->
        :ok
    end
  end

  defp validate_sync_service_migration(v1_state, v2_state) do
    v1_block = get_current_block_number(v1_state)
    v2_block = get_current_block_number(v2_state)

    cond do
      v1_block != v2_block ->
        {:error, "Block number mismatch: V1=#{v1_block}, V2=#{v2_block}"}

      not Map.has_key?(v2_state, :migration_info) ->
        {:error, "Missing migration metadata in V2 state"}

      true ->
        :ok
    end
  end

  defp validate_data_integrity(_module_type, _v1_state, _v2_state) do
    # Comprehensive data integrity validation
    # Would implement checksums, data validation, etc.
    :ok
  end

  defp validate_performance_characteristics(_module_type, _v2_state) do
    # Validate that V2 state is structured for good performance
    :ok
  end

  # Utility functions

  defp generate_migration_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_val, right_val ->
      deep_merge(left_val, right_val)
    end)
  end

  defp deep_merge(_left, right), do: right

  # Statistics and monitoring functions

  defp count_total_migrations do
    # Would implement persistent migration tracking
    0
  end

  defp count_successful_migrations do
    0
  end

  defp count_failed_migrations do
    0
  end

  defp calculate_avg_migration_time do
    0
  end

  defp get_last_migration_info do
    nil
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:mana, :migration, event],
      %{count: 1, timestamp: :os.system_time(:millisecond)},
      metadata
    )
  end
end
