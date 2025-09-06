# Configuration

## Overview

Mana-Ethereum uses Elixir configuration files to manage node settings. Configuration is environment-specific and supports runtime configuration.

## Configuration Files

```
config/
├── config.exs          # Base configuration
├── dev.exs             # Development settings
├── prod.exs            # Production settings
└── test.exs            # Test environment
```

## Basic Configuration

### Network Settings

```elixir
# config/config.exs
config :ex_wire,
  network: [
    # Network interface to bind
    interface: {0, 0, 0, 0},
    
    # P2P port
    port: 30303,
    
    # Discovery settings
    discovery: true,
    
    # Boot nodes
    bootnodes: [
      "enode://d860a01f9722d78051619d1e2351aba3f43f943f6f00718d1b9baa4101932a1f5011f16bb2b1bb35db20d6fe28fa0bf09636d26a87d31de9ec6203eeedb1f666@18.138.108.67:30303"
    ]
  ]
```

### Chain Configuration

```elixir
config :blockchain,
  # Chain to sync (mainnet, goerli, sepolia)
  chain: :mainnet,
  
  # Sync mode (full, fast, light)
  sync_mode: :fast,
  
  # State pruning
  pruning: [
    enabled: true,
    keep_blocks: 1000
  ]
```

### Storage Configuration

```elixir
config :merkle_patricia_tree,
  # Storage backend
  db: [
    # Database type (antidote, ets)
    type: :antidote,
    
    # Connection settings
    connection: [
      host: "localhost",
      port: 8087
    ],
    
    # Performance tuning
    cache_size: 10_000,
    write_batch_size: 1000
  ]
```

## Advanced Configuration

### Layer 2 Settings

```elixir
config :ex_wire, :layer2,
  # Enable Layer 2 support
  enabled: true,
  
  # Optimism configuration
  optimism: [
    enabled: true,
    l1_rpc_url: "https://mainnet.infura.io/v3/YOUR_KEY",
    sequencer_url: "https://mainnet.optimism.io"
  ],
  
  # Arbitrum configuration
  arbitrum: [
    enabled: true,
    l1_rpc_url: "https://mainnet.infura.io/v3/YOUR_KEY",
    sequencer_url: "https://arb1.arbitrum.io/rpc"
  ]
```

### Enterprise Features

```elixir
config :ex_wire, :enterprise,
  # HSM integration
  hsm: [
    enabled: true,
    provider: :softhsm,
    config_file: "/etc/mana/hsm.conf"
  ],
  
  # Role-based access control
  rbac: [
    enabled: true,
    roles_file: "/etc/mana/roles.yml"
  ],
  
  # Compliance
  compliance: [
    enabled: true,
    frameworks: [:sox, :pci_dss],
    audit_log: "/var/log/mana/audit.log"
  ]
```

### Monitoring & Observability

```elixir
config :ex_wire, :monitoring,
  # Enable metrics collection
  enabled: true,
  
  # Prometheus metrics
  prometheus: [
    enabled: true,
    port: 9568
  ],
  
  # Health checks
  health_check: [
    enabled: true,
    port: 8080,
    path: "/health"
  ],
  
  # Logging
  logging: [
    level: :info,
    format: :json
  ]
```

## Environment Variables

Override configuration using environment variables:

```bash
# Network settings
export MANA_NETWORK_PORT=30303
export MANA_NETWORK_INTERFACE="0.0.0.0"

# Chain settings
export MANA_CHAIN=mainnet
export MANA_SYNC_MODE=fast

# Database settings
export MANA_DB_TYPE=antidote
export MANA_DB_HOST=localhost
export MANA_DB_PORT=8087

# Monitoring
export MANA_PROMETHEUS_PORT=9568
export MANA_HEALTH_PORT=8080
```

## Production Configuration

### Recommended Settings

```elixir
# config/prod.exs
import Config

# Network
config :ex_wire,
  network: [
    interface: {0, 0, 0, 0},
    port: 30303,
    discovery: true,
    max_peers: 50
  ]

# Chain
config :blockchain,
  chain: :mainnet,
  sync_mode: :fast,
  pruning: [enabled: true, keep_blocks: 1000]

# Database
config :merkle_patricia_tree,
  db: [
    type: :antidote,
    connection: [
      host: {:system, "ANTIDOTE_HOST", "localhost"},
      port: {:system, :integer, "ANTIDOTE_PORT", 8087}
    ],
    cache_size: 50_000,
    write_batch_size: 5000
  ]

# Monitoring
config :ex_wire, :monitoring,
  enabled: true,
  prometheus: [enabled: true, port: 9568],
  logging: [level: :info, format: :json]
```

### Security Configuration

```elixir
# Restrict network access
config :ex_wire,
  network: [
    # Bind to specific interface
    interface: {192, 168, 1, 100},
    
    # Firewall-friendly ports
    port: 30303,
    
    # Peer restrictions
    trusted_peers_only: true,
    max_peers: 25
  ]

# Enable authentication
config :jsonrpc2,
  auth: [
    enabled: true,
    method: :jwt,
    secret_key: {:system, "MANA_JWT_SECRET"}
  ]
```

## Validation

### Check Configuration

```bash
# Validate configuration
mix run -e "IO.inspect(Application.get_all_env(:ex_wire))"

# Test database connection
mix run -e "MerklePatriciaTree.Test.test_connection()"

# Verify network settings
mix run -e "ExWire.Network.test_connectivity()"
```

### Configuration Migration

```bash
# Migrate from v1 to v2 config
mix mana.config.migrate config/old_config.exs

# Generate default configuration
mix mana.config.generate --env production
```

## Troubleshooting

### Common Issues

**Database Connection Failed**
- Verify AntidoteDB is running
- Check host/port configuration
- Ensure network connectivity

**Network Discovery Issues**
- Check firewall settings
- Verify boot nodes are reachable
- Enable debug logging

**Performance Issues**
- Increase cache sizes
- Tune batch sizes
- Monitor memory usage

### Debug Configuration

```elixir
# Enable debug logging
config :logger, level: :debug

# Extended logging
config :ex_wire, :logging,
  level: :debug,
  modules: [:p2p, :sync, :chain]
```

## Next Steps

- [Quick Start](quick-start.md) - Start your configured node
- [Production Deployment](../deployment/production.md) - Deploy to production
- [Monitoring](../deployment/monitoring.md) - Set up observability