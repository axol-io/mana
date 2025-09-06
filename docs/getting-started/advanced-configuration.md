# Mana-Ethereum Configuration System

## Overview

The Mana-Ethereum client features a comprehensive configuration management system that provides:

- **Centralized Configuration**: All settings in one place with a clear hierarchy
- **Hot-Reload Capability**: Change configuration without restarting the node
- **Environment Overrides**: Different settings for development, test, and production
- **Validation & Type Safety**: Schema-based validation with type checking
- **Migration Tools**: Automated configuration upgrades between versions
- **Real-time Updates**: Watch configuration changes and react dynamically

## Quick Start

### Basic Configuration

The main configuration file is located at `config/mana.yml`. Here's a minimal example:

```yaml
blockchain:
  network: mainnet
  chain_id: 1

p2p:
  max_peers: 50
  port: 30303
  discovery: true

storage:
  db_path: ./db
  pruning: true
```

### Environment-Specific Configuration

Create environment-specific files to override base configuration:

- `config/development.yml` - Development overrides
- `config/test.yml` - Test environment settings
- `config/production.yml` - Production optimizations

Environment files only need to specify values that differ from the base configuration.

## Configuration API

### Reading Configuration

```elixir
# Get a configuration value
network = ConfigManager.get([:blockchain, :network])
max_peers = ConfigManager.get([:p2p, :max_peers], 50)  # with default

# Get required configuration (raises if missing)
db_path = ConfigManager.get!([:storage, :db_path])
```

### Updating Configuration

```elixir
# Set a single value
ConfigManager.set([:p2p, :max_peers], 100)

# Update multiple values atomically
ConfigManager.update(%{
  [:p2p, :max_peers] => 75,
  [:sync, :mode] => "fast",
  [:storage, :cache_size] => 2048
})
```

### Watching Configuration Changes

```elixir
# Register a watcher for configuration changes
{:ok, watcher_id} = ConfigManager.watch([:p2p], fn path, value ->
  IO.puts("Config changed: #{inspect(path)} = #{inspect(value)}")
  # React to configuration changes
end)

# Unregister when done
ConfigManager.unwatch(watcher_id)
```

### Hot-Reload

```elixir
# Enable/disable automatic hot-reload
ConfigManager.set_reload(true)

# Manually trigger reload
ConfigManager.reload()
```

## Configuration Schema

The configuration schema is defined in `config/schema.yml` and provides:

- **Type Validation**: Ensures values are the correct type
- **Range Validation**: Min/max values for numbers
- **Enum Validation**: Allowed values for string fields
- **Format Validation**: Email, URL, IP address formats
- **Required Fields**: Ensures critical configuration exists

Example schema definition:

```yaml
p2p:
  max_peers:
    type: integer
    min: 1
    max: 200
    default: 50
    description: "Maximum number of peer connections"
  
  port:
    type: integer
    min: 1024
    max: 65535
    default: 30303
    description: "P2P listening port"
```

## Configuration Validation

### Validate Current Configuration

```elixir
case ConfigManager.validate() do
  :ok -> 
    IO.puts("Configuration is valid")
  
  {:error, {:validation_failed, errors}} ->
    Enum.each(errors, fn {path, reason} ->
      IO.puts("Error at #{inspect(path)}: #{inspect(reason)}")
    end)
end
```

### Generate Validation Report

```elixir
report = Validator.validation_report(config, schema)

IO.puts("Valid: #{report.valid}")
IO.puts("Errors: #{inspect(report.errors)}")
IO.puts("Warnings: #{inspect(report.warnings)}")
```

## Configuration Migration

### Creating Migrations

```elixir
# Create a new migration file
{:ok, filepath} = Migrator.create_migration("add_new_feature", 
  "Adds configuration for new feature X")
```

This creates a migration file in `priv/config_migrations/` with a template:

```elixir
%{
  version: "20241215120000",
  description: "Adds configuration for new feature X",
  
  up: fn config ->
    config
    |> Map.put(:new_feature, %{enabled: false})
    |> update_in([:p2p, :capabilities], &(&1 ++ ["new/1"]))
  end,
  
  down: fn config ->
    config
    |> Map.delete(:new_feature)
    |> update_in([:p2p, :capabilities], &List.delete(&1, "new/1"))
  end
}
```

### Running Migrations

```elixir
# Check if migrations are needed
if Migrator.needs_migration?(config) do
  # Run all pending migrations
  {:ok, new_config} = Migrator.migrate(config)
  
  # Or migrate to specific version
  {:ok, new_config} = Migrator.migrate(config, to: "20241215120000")
end

# Rollback to previous version
{:ok, old_config} = Migrator.rollback(config, "20241214000000")
```

## Configuration Reference

### Blockchain Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `blockchain.network` | string | mainnet | Network to connect to (mainnet, goerli, sepolia) |
| `blockchain.chain_id` | integer | 1 | Chain ID for transaction signing |
| `blockchain.eip1559` | boolean | true | Enable EIP-1559 transaction support |

### P2P Networking

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `p2p.max_peers` | integer | 50 | Maximum peer connections |
| `p2p.port` | integer | 30303 | P2P listening port |
| `p2p.discovery` | boolean | true | Enable peer discovery |
| `p2p.protocol_version` | integer | 67 | Ethereum wire protocol version |
| `p2p.capabilities` | list | ["eth/66", "eth/67"] | Supported protocols |

### Synchronization

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `sync.mode` | string | fast | Sync mode (full, fast, warp) |
| `sync.checkpoint_sync` | boolean | true | Enable checkpoint sync |
| `sync.parallel_downloads` | integer | 10 | Parallel block downloads |

### Storage

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `storage.db_path` | string | ./db | Database directory |
| `storage.pruning` | boolean | true | Enable state pruning |
| `storage.pruning_mode` | string | balanced | Pruning strategy |
| `storage.cache_size` | integer | 1024 | Cache size in MB |

### Monitoring

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `monitoring.metrics_enabled` | boolean | true | Enable Prometheus metrics |
| `monitoring.metrics_port` | integer | 9090 | Metrics server port |
| `monitoring.grafana_enabled` | boolean | false | Enable Grafana dashboards |

### Security

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `security.private_key` | string | random | Private key source |
| `security.bls_signatures` | boolean | true | Enable BLS signatures |
| `security.slashing_protection` | boolean | true | Enable slashing protection |
| `security.rate_limiting` | boolean | true | Enable rate limiting |

## Best Practices

### 1. Use Environment-Specific Files

Keep base configuration minimal and use environment files for specific settings:

```yaml
# config/mana.yml - Base configuration
blockchain:
  network: mainnet

# config/development.yml - Development overrides
blockchain:
  network: goerli  # Use testnet in development
```

### 2. Watch Critical Configuration

Monitor important configuration changes:

```elixir
ConfigManager.watch([:p2p, :max_peers], fn _path, new_value ->
  PeerManager.adjust_connections(new_value)
end)
```

### 3. Validate Before Deployment

Always validate configuration before deploying:

```elixir
# In deployment script
config = load_config()
case Validator.validate_config(config, schema) do
  :ok -> deploy()
  {:error, errors} -> abort_deployment(errors)
end
```

### 4. Use Migrations for Updates

Create migrations for configuration structure changes:

```elixir
# When adding new features
Migrator.create_migration("add_feature_x", "Adds feature X configuration")

# In application startup
if Migrator.needs_migration?(config) do
  {:ok, config} = Migrator.migrate(config)
  ConfigManager.reload()
end
```

### 5. Document Configuration Changes

Always document new configuration options:

```yaml
# In schema.yml
new_feature:
  enabled:
    type: boolean
    default: false
    description: "Enable experimental feature X"
    since: "1.2.0"  # Version when added
```

## Troubleshooting

### Configuration Not Loading

1. Check file exists at `config/mana.yml`
2. Verify YAML syntax is valid
3. Check file permissions
4. Review logs for parsing errors

### Validation Failures

1. Run validation report to identify issues
2. Check schema definition for constraints
3. Verify data types match schema
4. Look for required fields

### Hot-Reload Not Working

1. Ensure `ConfigManager.set_reload(true)` is called
2. Check file modification times
3. Verify no file permission issues
4. Check logs for reload errors

### Migration Failures

1. Test migrations in development first
2. Ensure rollback functions work
3. Backup configuration before migrating
4. Check migration order and dependencies

## Advanced Features

### Custom Validators

Add custom validation logic:

```elixir
schema = %{
  p2p: %{
    port: %{
      type: :integer,
      validator: fn port ->
        if port_available?(port) do
          :ok
        else
          {:error, "Port #{port} is already in use"}
        end
      end
    }
  }
}
```

### Configuration Transformations

Transform configuration during load:

```elixir
config = ConfigManager.get([:p2p])
|> transform_legacy_format()
|> apply_network_defaults()
|> validate_and_sanitize()
```

### Multi-Source Configuration

Combine configuration from multiple sources:

```elixir
config = %{}
|> deep_merge(load_file_config())
|> deep_merge(load_env_config())
|> deep_merge(load_cli_config())
|> deep_merge(load_runtime_config())
```

---

*For more information, see the [Configuration API documentation](./api/configuration.md)*