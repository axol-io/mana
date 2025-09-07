defmodule ExWire.Eth2.PruningConfig do
  @moduledoc """
  Configuration management for pruning policies and strategies.

  Provides flexible configuration for different deployment scenarios:
  - Development (minimal pruning for debugging)
  - Testnet (moderate pruning for validation)  
  - Mainnet (aggressive pruning for production)
  - Archive (no pruning, keep all data)

  Configuration can be dynamically updated and includes validation
  to ensure safe pruning parameters.
  """

  require Logger

  # Configuration presets for different deployment types
  @development_config %{
    name: "Development",
    description: "Minimal pruning for local development and debugging",

    # Data retention (in slots)
    # 1 week
    finalized_block_retention: 32 * 256 * 7,
    # 2 weeks  
    state_retention: 32 * 256 * 14,
    # 8 epochs
    attestation_retention: 32 * 8,
    # 2 weeks
    execution_log_retention: 32 * 256 * 14,

    # Pruning triggers
    # 95% full before pruning
    storage_usage_threshold: 0.95,
    # 8 epochs behind
    finality_lag_threshold: 32 * 8,
    # Disable automatic pruning
    time_based_pruning: false,

    # Archive mode
    archive_mode: false,
    # Keep finalized states
    archive_finalized_states: true,
    archive_execution_data: false,

    # Performance 
    max_concurrent_pruners: 2,
    pruning_batch_size: 500,
    # 10 minutes
    pruning_interval_ms: 600_000,
    # 5 minutes
    incremental_interval_ms: 300_000,

    # Storage tiers
    enable_cold_storage: false,
    # 1 month
    cold_storage_threshold: 32 * 256 * 30,

    # Safety settings
    # 2 epochs safety margin
    safety_margin_slots: 64,
    require_finality_confirmation: true,
    # Always keep 1 day
    minimum_retention_slots: 32 * 256,

    # Pruning intensity
    aggressive_pruning: false,
    # Disable expensive operations
    enable_trie_pruning: false,
    enable_log_pruning: true,
    enable_deduplication: true
  }

  @testnet_config %{
    name: "Testnet",
    description: "Balanced pruning for testnet validation and testing",

    # Data retention
    # 3 days
    finalized_block_retention: 32 * 256 * 3,
    # 1 week
    state_retention: 32 * 256 * 7,
    # 4 epochs  
    attestation_retention: 32 * 4,
    # 1 week
    execution_log_retention: 32 * 256 * 7,

    # Pruning triggers
    # 85% full
    storage_usage_threshold: 0.85,
    # 4 epochs behind
    finality_lag_threshold: 32 * 4,
    time_based_pruning: true,

    # Archive mode
    archive_mode: false,
    archive_finalized_states: false,
    archive_execution_data: false,

    # Performance
    max_concurrent_pruners: 3,
    pruning_batch_size: 1000,
    # 5 minutes
    pruning_interval_ms: 300_000,
    # 1 minute
    incremental_interval_ms: 60_000,

    # Storage tiers
    enable_cold_storage: true,
    # 2 weeks
    cold_storage_threshold: 32 * 256 * 14,

    # Safety settings
    # 1 epoch safety margin
    safety_margin_slots: 32,
    require_finality_confirmation: true,
    # Always keep 2 hours
    minimum_retention_slots: 32 * 64,

    # Pruning intensity
    aggressive_pruning: false,
    enable_trie_pruning: true,
    enable_log_pruning: true,
    enable_deduplication: true
  }

  @mainnet_config %{
    name: "Mainnet",
    description: "Production pruning for mainnet with storage efficiency",

    # Data retention (aggressive)
    # 1 day
    finalized_block_retention: 32 * 256,
    # 3 days
    state_retention: 32 * 256 * 3,
    # 2 epochs
    attestation_retention: 32 * 2,
    # 3 days
    execution_log_retention: 32 * 256 * 3,

    # Pruning triggers
    # 80% full
    storage_usage_threshold: 0.80,
    # 2 epochs behind
    finality_lag_threshold: 32 * 2,
    time_based_pruning: true,

    # Archive mode
    archive_mode: false,
    archive_finalized_states: false,
    archive_execution_data: false,

    # Performance (optimized for production)
    max_concurrent_pruners: 4,
    pruning_batch_size: 2000,
    # 3 minutes
    pruning_interval_ms: 180_000,
    # 30 seconds
    incremental_interval_ms: 30_000,

    # Storage tiers
    enable_cold_storage: true,
    # 1 week
    cold_storage_threshold: 32 * 256 * 7,

    # Safety settings
    # 16 slots safety margin
    safety_margin_slots: 16,
    require_finality_confirmation: true,
    # Always keep 1 hour
    minimum_retention_slots: 32 * 32,

    # Pruning intensity (aggressive)
    aggressive_pruning: true,
    enable_trie_pruning: true,
    enable_log_pruning: true,
    enable_deduplication: true
  }

  @archive_config %{
    name: "Archive",
    description: "Full archive mode - no pruning, keep all historical data",

    # Data retention (unlimited)
    finalized_block_retention: :unlimited,
    state_retention: :unlimited,
    attestation_retention: :unlimited,
    execution_log_retention: :unlimited,

    # Pruning triggers (disabled)
    # Only prune when critically full
    storage_usage_threshold: 0.99,
    finality_lag_threshold: :unlimited,
    # Disabled
    time_based_pruning: false,

    # Archive mode (full)
    archive_mode: true,
    archive_finalized_states: true,
    archive_execution_data: true,

    # Performance (minimal)
    max_concurrent_pruners: 1,
    pruning_batch_size: 100,
    # 1 hour (rarely used)
    pruning_interval_ms: 3_600_000,
    # 10 minutes
    incremental_interval_ms: 600_000,

    # Storage tiers (all enabled)
    enable_cold_storage: true,
    # 3 months to cold
    cold_storage_threshold: 32 * 256 * 90,

    # Safety settings (maximum safety)
    # 8 epochs safety margin
    safety_margin_slots: 256,
    require_finality_confirmation: true,
    # Always keep 1 year
    minimum_retention_slots: 32 * 256 * 365,

    # Pruning intensity (minimal)
    aggressive_pruning: false,
    # Disabled - keep all trie data
    enable_trie_pruning: false,
    # Disabled - keep all logs
    enable_log_pruning: false,
    # Disabled - keep duplicates for analysis
    enable_deduplication: false
  }

  @doc """
  Get configuration preset by name
  """
  def get_preset(preset_name) do
    case preset_name do
      :development ->
        {:ok, @development_config}

      :testnet ->
        {:ok, @testnet_config}

      :mainnet ->
        {:ok, @mainnet_config}

      :archive ->
        {:ok, @archive_config}

      name when is_binary(name) ->
        get_preset(String.to_atom(name))

      _ ->
        {:error, :unknown_preset}
    end
  end

  @doc """
  List all available presets
  """
  def list_presets do
    [
      {:development, @development_config.name, @development_config.description},
      {:testnet, @testnet_config.name, @testnet_config.description},
      {:mainnet, @mainnet_config.name, @mainnet_config.description},
      {:archive, @archive_config.name, @archive_config.description}
    ]
  end

  @doc """
  Validate pruning configuration
  """
  def validate_config(_config) do
    with :ok <- validate_retention_settings(config),
         :ok <- validate_performance_settings(config),
         :ok <- validate_safety_settings(config),
         :ok <- validate_consistency(config) do
      {:ok, _config}
    else
      {:error, _reason} -> {:error, _reason}
    end
  end

  @doc """
  Merge user configuration with preset, validating the result
  """
  def merge_config(preset, user_overrides) do
    case get_preset(preset) do
      {:ok, base_config} ->
        merged = Map.merge(base_config, user_overrides)
        validate_config(merged)

      {:error, _reason} ->
        {:error, _reason}
    end
  end

  @doc """
  Create custom configuration with validation
  """
  def custom_config(config_map) do
    # Start with development config as base
    {:ok, base} = get_preset(:development)
    merged = Map.merge(base, config_map)
    validate_config(merged)
  end

  @doc """
  Get recommended configuration for specific constraints
  """
  def recommend_config(constraints) do
    storage_gb = Map.get(constraints, :max_storage_gb, 500)
    network = Map.get(constraints, :network, :mainnet)
    node_type = Map.get(constraints, :node_type, :full)

    base_preset =
      case {network, node_type} do
        {:mainnet, :archive} -> :archive
        {:mainnet, :full} -> :mainnet
        {:testnet, _} -> :testnet
        {_, :dev} -> :development
        _ -> :mainnet
      end

    {:ok, base_config} = get_preset(base_preset)

    # Adjust based on storage constraints
    adjusted_config = adjust_for_storage_limit(base_config, storage_gb)

    # Validate the result
    validate_config(adjusted_config)
  end

  @doc """
  Calculate estimated storage usage for a configuration
  """
  def estimate_storage_usage(_config, days \\ 30) do
    # ~32 slots per epoch, ~225 epochs per day
    slots_per_day = 32 * 225
    total_slots = days * slots_per_day

    # Estimate storage for each data type
    estimates = %{
      blocks: estimate_block_storage(config, total_slots),
      states: estimate_state_storage(config, total_slots),
      attestations: estimate_attestation_storage(config, total_slots),
      logs: estimate_log_storage(config, total_slots),
      trie_nodes: estimate_trie_storage(config, total_slots),
      overhead: estimate_overhead_storage(config)
    }

    total_gb = Enum.reduce(estimates, 0, fn {_, gb}, acc -> acc + gb end)

    Map.put(estimates, :total_gb, total_gb)
  end

  @doc """
  Get performance impact assessment for configuration
  """
  def assess_performance_impact(_config) do
    %{
      pruning_overhead: assess_pruning_overhead(config),
      storage_io_impact: assess_storage_io_impact(config),
      memory_usage: assess_memory_usage(config),
      cpu_usage: assess_cpu_usage(config),
      network_impact: assess_network_impact(config)
    }
  end

  # Private Functions - Validation

  defp validate_retention_settings(_config) do
    cond do
      config.finalized_block_retention != :unlimited and config.finalized_block_retention < 32 ->
        {:error, "finalized_block_retention must be at least 32 slots (1 epoch)"}

      config.state_retention != :unlimited and config.state_retention < 64 ->
        {:error, "state_retention must be at least 64 slots (2 epochs)"}

      config.attestation_retention != :unlimited and config.attestation_retention < 32 ->
        {:error, "attestation_retention must be at least 32 slots (1 epoch)"}

      true ->
        :ok
    end
  end

  defp validate_performance_settings(_config) do
    cond do
      config.max_concurrent_pruners < 1 or config.max_concurrent_pruners > 16 ->
        {:error, "max_concurrent_pruners must be between 1 and 16"}

      config.pruning_batch_size < 100 or config.pruning_batch_size > 10000 ->
        {:error, "pruning_batch_size must be between 100 and 10000"}

      config.pruning_interval_ms < 30_000 ->
        {:error, "pruning_interval_ms must be at least 30 seconds"}

      true ->
        :ok
    end
  end

  defp validate_safety_settings(_config) do
    cond do
      config.storage_usage_threshold < 0.5 or config.storage_usage_threshold > 0.99 ->
        {:error, "storage_usage_threshold must be between 0.5 and 0.99"}

      config.safety_margin_slots < 8 ->
        {:error, "safety_margin_slots must be at least 8 slots"}

      config.minimum_retention_slots > config.state_retention and
          config.state_retention != :unlimited ->
        {:error, "minimum_retention_slots cannot exceed state_retention"}

      true ->
        :ok
    end
  end

  defp validate_consistency(_config) do
    cond do
      # Archive mode should have minimal pruning
      config.archive_mode and config.aggressive_pruning ->
        {:error, "cannot use aggressive_pruning in archive_mode"}

      # Cold storage requires reasonable thresholds
      config.enable_cold_storage and config.cold_storage_threshold < config.state_retention and
          config.state_retention != :unlimited ->
        {:error, "cold_storage_threshold should be greater than state_retention"}

      # Incremental interval should be shorter than main interval
      config.incremental_interval_ms >= config.pruning_interval_ms ->
        {:error, "incremental_interval_ms should be less than pruning_interval_ms"}

      true ->
        :ok
    end
  end

  # Private Functions - Storage Estimation

  defp adjust_for_storage_limit(_config, storage_limit_gb) do
    # Calculate current estimated usage
    current_estimate = estimate_storage_usage(config)

    if current_estimate.total_gb > storage_limit_gb do
      # Need to reduce retention periods
      reduction_factor = storage_limit_gb / current_estimate.total_gb

      %{
        config
        | finalized_block_retention:
            scale_retention(config.finalized_block_retention, reduction_factor),
          state_retention: scale_retention(config.state_retention, reduction_factor),
          execution_log_retention:
            scale_retention(config.execution_log_retention, reduction_factor),
          aggressive_pruning: true,
          enable_cold_storage: true
      }
    else
      config
    end
  end

  defp scale_retention(:unlimited, _factor), do: :unlimited

  defp scale_retention(slots, factor) when is_integer(slots) do
    # Never go below 1 epoch
    max(32, round(slots * factor))
  end

  defp estimate_block_storage(_config, total_slots) do
    if config.finalized_block_retention == :unlimited do
      # 500KB per block -> GB
      total_slots * 0.5 / 1024
    else
      min(total_slots, config.finalized_block_retention) * 0.5 / 1024
    end
  end

  defp estimate_state_storage(_config, total_slots) do
    if config.state_retention == :unlimited do
      # 50MB per state -> GB
      total_slots * 50 / 1024
    else
      min(total_slots, config.state_retention) * 50 / 1024
    end
  end

  defp estimate_attestation_storage(_config, total_slots) do
    if config.attestation_retention == :unlimited do
      # 10KB per slot worth of attestations -> GB
      total_slots * 0.01
    else
      min(total_slots, config.attestation_retention) * 0.01 / 1024
    end
  end

  defp estimate_log_storage(_config, total_slots) do
    if config.execution_log_retention == :unlimited do
      # 1MB per slot of logs -> GB
      total_slots * 1 / 1024
    else
      min(total_slots, config.execution_log_retention) * 1 / 1024
    end
  end

  defp estimate_trie_storage(_config, total_slots) do
    # State trie grows over time but gets pruned
    # 10GB base trie size
    base_trie_size = 10.0

    if config.enable_trie_pruning do
      # 20% overhead with pruning
      base_trie_size * 1.2
    else
      # 100% overhead without pruning
      base_trie_size * 2.0
    end
  end

  defp estimate_overhead_storage(_config) do
    # 5GB for indexes, caches, etc.
    5.0
  end

  # Private Functions - Performance Assessment

  defp assess_pruning_overhead(_config) do
    # 5% base overhead
    base_overhead = 0.05

    adjustments = [
      if(config.aggressive_pruning, do: 0.02, else: 0),
      if(config.enable_trie_pruning, do: 0.03, else: 0),
      config.max_concurrent_pruners * 0.01,
      if(config.enable_cold_storage, do: 0.01, else: 0)
    ]

    total_overhead = Enum.reduce(adjustments, base_overhead, &+/2)

    %{
      cpu_overhead_percent: total_overhead * 100,
      memory_overhead_mb: total_overhead * 1000,
      io_overhead_percent: total_overhead * 50
    }
  end

  defp assess_storage_io_impact(_config) do
    # More aggressive pruning = more I/O
    # MB/min baseline
    base_io = 100

    multiplier =
      cond do
        config.aggressive_pruning -> 2.0
        config.archive_mode -> 0.2
        true -> 1.0
      end

    %{
      average_io_mb_per_min: base_io * multiplier,
      peak_io_mb_per_min: base_io * multiplier * 3,
      io_pattern: if(config.aggressive_pruning, do: :bursty, else: :steady)
    }
  end

  defp assess_memory_usage(_config) do
    # MB
    base_memory = 512

    additional = [
      # MB per pruner
      config.max_concurrent_pruners * 50,
      if(config.enable_trie_pruning, do: 200, else: 0),
      if(config.enable_cold_storage, do: 100, else: 0)
    ]

    total = Enum.reduce(additional, base_memory, &+/2)

    %{
      baseline_mb: base_memory,
      peak_mb: total,
      pruning_workers_mb: config.max_concurrent_pruners * 50
    }
  end

  defp assess_cpu_usage(_config) do
    # 2% baseline
    base_cpu = 2.0

    additional = [
      if(config.aggressive_pruning, do: 3.0, else: 1.0),
      if(config.enable_trie_pruning, do: 5.0, else: 0),
      config.max_concurrent_pruners * 0.5
    ]

    total = Enum.reduce(additional, base_cpu, &+/2)

    %{
      average_cpu_percent: total,
      peak_cpu_percent: total * 2,
      pruning_impact: if(config.aggressive_pruning, do: :high, else: :low)
    }
  end

  defp assess_network_impact(_config) do
    # Cold storage may involve network I/O
    network_mb =
      if config.enable_cold_storage do
        # MB/hour for archiving
        100
      else
        0
      end

    %{
      cold_storage_mb_per_hour: network_mb,
      network_dependency: config.enable_cold_storage,
      bandwidth_requirements: if(config.enable_cold_storage, do: :moderate, else: :none)
    }
  end
end
