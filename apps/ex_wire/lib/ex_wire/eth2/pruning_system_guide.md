# Ethereum 2.0 Pruning System Guide

## Overview

The Mana Ethereum 2.0 client includes a comprehensive pruning system designed to manage disk usage while maintaining the minimum data required for consensus operations. The system achieves **3-5x storage efficiency** improvements while maintaining full validation capabilities.

## Architecture Components

### Core Modules

1. **PruningManager** - Orchestrates all pruning operations
2. **PruningStrategies** - Implements specific algorithms for each data type
3. **PruningScheduler** - Intelligent load-aware scheduling
4. **PruningConfig** - Configuration management with presets
5. **PruningMetrics** - Comprehensive monitoring and analytics
6. **PruningDashboard** - Real-time visibility and alerting

### Data Types Managed

- **Fork Choice Data** - Non-finalized blocks and cached data
- **Beacon States** - Historical state snapshots  
- **Attestation Pool** - Old attestations beyond inclusion window
- **Block Storage** - Block bodies vs headers retention
- **State Trie** - Unreferenced trie nodes
- **Execution Logs** - Historical execution layer data

## Quick Start

### Basic Configuration

```elixir
# Start with a preset configuration
config = PruningConfig.get_preset(:mainnet)
{:ok, _} = PruningManager.start_link(config: config)
{:ok, _} = PruningScheduler.start_link(config: config)
{:ok, _} = PruningMetrics.start_link(config: config)
```

### Manual Pruning

```elixir
# Prune all data types
{:ok, results} = PruningManager.prune_all()

# Prune specific data type
{:ok, result} = PruningManager.prune(:attestations, incremental: true)

# Get current status
{:ok, status} = PruningManager.get_status()
```

## Configuration Presets

### Development Mode
- **Use Case**: Local development and debugging
- **Retention**: 1-2 weeks of data
- **Pruning**: Minimal, time-based disabled
- **Storage Target**: ~50GB

```elixir
config = PruningConfig.get_preset(:development)
```

### Testnet Mode  
- **Use Case**: Testnet validation and testing
- **Retention**: 3-7 days of data
- **Pruning**: Balanced approach
- **Storage Target**: ~100GB

```elixir
config = PruningConfig.get_preset(:testnet)
```

### Mainnet Mode
- **Use Case**: Production mainnet node
- **Retention**: 1-3 days of data
- **Pruning**: Aggressive, optimized for efficiency
- **Storage Target**: ~200GB

```elixir
config = PruningConfig.get_preset(:mainnet)
```

### Archive Mode
- **Use Case**: Full historical data retention
- **Retention**: Unlimited (no pruning)
- **Pruning**: Disabled except for critical situations
- **Storage Target**: Unlimited

```elixir
config = PruningConfig.get_preset(:archive)
```

## Custom Configuration

### Creating Custom Config

```elixir
custom_config = %{
  # Data retention (in slots)
  finalized_block_retention: 32 * 256 * 2,    # 2 days
  state_retention: 32 * 256 * 5,              # 5 days
  attestation_retention: 32 * 3,              # 3 epochs
  
  # Performance settings
  max_concurrent_pruners: 3,
  pruning_batch_size: 1500,
  pruning_interval_ms: 240_000,               # 4 minutes
  
  # Storage optimization
  enable_cold_storage: true,
  cold_storage_threshold: 32 * 256 * 14,      # 2 weeks
  aggressive_pruning: true
}

{:ok, validated_config} = PruningConfig.validate_config(custom_config)
```

### Storage-Constrained Configuration

```elixir
# Get recommended config for specific storage limit
constraints = %{
  max_storage_gb: 100,
  network: :mainnet,
  node_type: :full
}

{:ok, optimized_config} = PruningConfig.recommend_config(constraints)
```

## Monitoring and Metrics

### Real-time Dashboard

```elixir
# Start dashboard on port 8080
{:ok, _} = PruningDashboard.start_link(http_port: 8080)

# Get dashboard data
{:ok, dashboard_data} = PruningDashboard.get_dashboard_data()

# Get active alerts
{:ok, alerts} = PruningDashboard.get_alerts()
```

### Metrics Collection

```elixir
# Get comprehensive metrics
{:ok, summary} = PruningMetrics.get_metrics_summary()

# Efficiency analysis
{:ok, analysis} = PruningMetrics.get_efficiency_analysis()

# Storage utilization report
{:ok, report} = PruningMetrics.get_storage_report()

# Optimization recommendations
{:ok, recommendations} = PruningMetrics.get_optimization_recommendations()
```

### Key Metrics Tracked

- **Space Savings**: Total freed space by data type
- **Operation Performance**: Duration, throughput, efficiency
- **System Impact**: CPU, memory, I/O during pruning
- **Error Rates**: Success/failure ratios and recovery
- **Storage Tiers**: Hot/warm/cold utilization and migrations
- **Trend Analysis**: Performance trends over time

## Load-Aware Scheduling

The scheduler automatically adapts based on system conditions:

### System Load Assessment

```elixir
# Manual scheduling control
PruningScheduler.schedule_immediate([:attestations], force: true)
PruningScheduler.schedule_incremental(:states)
PruningScheduler.schedule_comprehensive()

# Pause/resume scheduling
PruningScheduler.set_pause_state(true)   # Pause
PruningScheduler.set_pause_state(false)  # Resume

# Get scheduler status
{:ok, status} = PruningScheduler.get_status()
```

### Load Levels and Behavior

- **Normal Load**: Full pruning operations allowed
- **Moderate Load**: Incremental pruning only
- **High Load**: Delay low-priority operations
- **Critical Load**: Pause all non-essential pruning

## Storage Tier Management

### Three-Tier Architecture

1. **Hot Storage** (RAM) - Last 2 epochs (~12 minutes)
2. **Warm Storage** (ETS/SSD) - Last ~10 hours  
3. **Cold Storage** (Network/Archive) - Historical data

### Automatic Migration

Data automatically migrates through tiers based on:
- Age and access patterns
- Storage capacity thresholds
- Configuration policies

## Performance Optimization

### Tuning for Different Workloads

#### High-Performance Node
```elixir
config = %{
  max_concurrent_pruners: 6,
  pruning_batch_size: 3000,
  pruning_interval_ms: 120_000,  # 2 minutes
  aggressive_pruning: true,
  enable_trie_pruning: true
}
```

#### Resource-Constrained Environment
```elixir
config = %{
  max_concurrent_pruners: 2,
  pruning_batch_size: 500,
  pruning_interval_ms: 600_000,  # 10 minutes
  aggressive_pruning: false,
  enable_load_aware_scheduling: true
}
```

### Expected Performance

- **Throughput**: 50-200 MB/s pruning rate
- **Space Savings**: 70-90% reduction in storage requirements
- **System Impact**: <5% CPU overhead during normal operation
- **I/O Impact**: Bursty pattern, <100 MB/min average

## Monitoring and Alerting

### Alert Thresholds

The system monitors and alerts on:

- **Error Rate** > 5% of operations failing
- **CPU Usage** > 25% during pruning operations  
- **Memory Usage** > 2GB during pruning
- **Storage Usage** > 90% of available space
- **Operation Duration** > 30 seconds for individual operations
- **Low Efficiency** < 10 MB/s pruning rate

### Alert Configuration

```elixir
thresholds = %{
  error_rate_percent: 3.0,        # Lower threshold
  cpu_usage_percent: 20.0,        # More sensitive
  storage_usage_percent: 85.0     # Earlier warning
}

PruningDashboard.update_thresholds(thresholds)
```

## Troubleshooting

### Common Issues

#### High CPU Usage
```elixir
# Reduce concurrent workers
PruningManager.update_config(%{max_concurrent_pruners: 2})

# Enable load-aware scheduling
PruningScheduler.update_config(%{enable_load_aware_scheduling: true})
```

#### Storage Not Being Freed
```elixir
# Check pruning status
{:ok, status} = PruningManager.get_status()

# Force immediate pruning
PruningManager.prune_all()

# Verify configuration
{:ok, _config} = PruningConfig.validate_config(current_config)
```

#### Poor Pruning Performance
```elixir
# Get efficiency analysis
{:ok, analysis} = PruningMetrics.get_efficiency_analysis()

# Check system impact
{:ok, summary} = PruningMetrics.get_metrics_summary()
IO.inspect(summary.system_impact)

# Get optimization recommendations
{:ok, recommendations} = PruningMetrics.get_optimization_recommendations()
```

### Diagnostic Commands

```elixir
# Comprehensive health check
{:ok, status} = PruningManager.get_status()
{:ok, metrics} = PruningMetrics.get_metrics_summary()
{:ok, scheduler} = PruningScheduler.get_status()

# Storage analysis
{:ok, storage_estimate} = PruningConfig.estimate_storage_usage(current_config, 30)
{:ok, savings_estimate} = PruningManager.estimate_pruning_savings()

# Performance analysis
{:ok, efficiency} = PruningMetrics.get_efficiency_analysis()
{:ok, impact} = PruningConfig.assess_performance_impact(current_config)
```

## Integration with Beacon Chain

### Automatic Integration

The pruning system automatically integrates with:
- Finality updates from the beacon chain
- Fork choice updates and reorg handling
- Attestation pool management
- State transition processing

### Manual Hooks

```elixir
# Trigger pruning on finality
def handle_finality_update(finalized_checkpoint) do
  PruningScheduler.schedule_immediate([:fork_choice, :attestations])
end

# Trigger pruning on storage thresholds  
def handle_storage_warning(usage_percent) when usage_percent > 85 do
  PruningManager.prune_all()
end
```

## Best Practices

### Production Deployment

1. **Start with a preset**: Use `:mainnet` or `:testnet` presets
2. **Monitor initially**: Watch metrics for 24-48 hours
3. **Tune gradually**: Adjust based on observed performance
4. **Set up alerting**: Configure appropriate thresholds
5. **Regular reviews**: Check recommendations weekly

### Development Environment

1. **Use development preset**: Minimal pruning for debugging
2. **Manual control**: Disable automatic scheduling
3. **Verbose logging**: Enable debug-level logging
4. **Regular cleanup**: Manual pruning between test runs

### Maintenance Windows

```elixir
# Schedule comprehensive pruning during low activity
PruningScheduler.schedule_comprehensive()

# Or manually during maintenance
PruningManager.prune_all()
```

## API Reference

### PruningManager
- `start_link/1` - Start the pruning manager
- `prune_all/0` - Execute comprehensive pruning
- `prune/2` - Prune specific data type
- `get_status/0` - Get current status
- `update_config/1` - Update configuration
- `estimate_pruning_savings/0` - Estimate potential savings

### PruningScheduler  
- `start_link/1` - Start the scheduler
- `schedule_immediate/2` - Schedule immediate pruning
- `schedule_incremental/2` - Schedule incremental pruning
- `schedule_comprehensive/1` - Schedule comprehensive pruning
- `set_pause_state/1` - Pause/resume scheduling
- `get_status/0` - Get scheduler status

### PruningMetrics
- `start_link/1` - Start metrics collection
- `get_metrics_summary/0` - Get summary metrics
- `get_efficiency_analysis/0` - Get efficiency analysis
- `get_storage_report/0` - Get storage utilization report
- `get_optimization_recommendations/0` - Get optimization suggestions

### PruningConfig
- `get_preset/1` - Get configuration preset
- `validate_config/1` - Validate configuration
- `merge_config/2` - Merge user overrides with preset
- `recommend_config/1` - Get recommended config for constraints
- `estimate_storage_usage/2` - Estimate storage requirements