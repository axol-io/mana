# DVT Testnet Validator Deployment Guide

This guide provides comprehensive instructions for deploying DVT (Distributed Validator Technology) validators on Ethereum testnets using the Mana-Ethereum client.

## Overview

DVT enables multiple operators to collectively run a single Ethereum validator, providing improved resilience, security, and decentralization. This implementation supports:

- **Threshold Signatures**: 3-of-5, 5-of-7, etc. signature schemes
- **Byzantine Fault Tolerance**: Continue operating even if minority of nodes fail
- **Automatic Failover**: Seamless recovery from node failures
- **Enterprise Security**: HSM integration, audit logging, RBAC

## Quick Start

### 1. Prerequisites

Ensure you have the following installed:

```bash
# Elixir and Erlang
elixir --version  # >= 1.14
erl -version      # >= 25

# Dependencies
mix deps.get
mix compile

# Beacon node (choose one)
# - Lighthouse, Prysm, Teku, Nimbus, or Lodestar
# - Must be fully synced on your target testnet
```

### 2. Simple Cluster Setup

Create a basic 5-node DVT cluster with 3-of-5 threshold:

```bash
# Set up cluster configuration and keys
mix dvt_testnet_setup \
  --cluster-id "my-first-dvt-cluster" \
  --nodes 5 \
  --threshold 3 \
  --network hoodi \
  --beacon-node "http://localhost:5052"

# This generates:
# - Validator keys distributed across 5 nodes
# - Configuration files for each node
# - Deployment scripts
# - Monitoring setup
```

### 3. Check Status

```bash
# Monitor cluster status
mix dvt_status --cluster-id "my-first-dvt-cluster"

# Watch continuously
mix dvt_status --cluster-id "my-first-dvt-cluster" --watch

# Detailed metrics
mix dvt_status --cluster-id "my-first-dvt-cluster" --detailed
```

## Network Support

### Supported Testnets

| Network | Chain ID | Status | Recommended Use |
|---------|----------|--------|-----------------|
| Hoodi | 17001 | ✅ Active | Primary testnet for DVT |
| Sepolia | 11155111 | ✅ Active | Development |
| Goerli | 5 | ⚠️ Deprecated | Legacy support only |

### Network Configuration

Each testnet has specific configuration in `config/dvt_testnet.exs`:

```elixir
# Hoodi configuration
hoodi: %{
  chain_id: 17001,
  genesis_hash: "0xb5f7f912443c940f21fd611f12828d75b534364ed9e2ddr3c3a2ae00bb07acb3",
  beacon_nodes: [
    "https://hoodi-beacon-api.stakingfacilities.com",
    "https://hoodi.beaconstate.ethstaker.cc"
  ]
}
```

## Deployment Scenarios

### Scenario 1: Development Cluster (Single Machine)

Perfect for testing and development:

```bash
# Create a local 3-node cluster
mix dvt_testnet_setup \
  --cluster-id "dev-cluster" \
  --nodes 3 \
  --threshold 2 \
  --network hoodi \
  --beacon-node "http://localhost:5052"
```

**Requirements:**
- Single machine with 8GB+ RAM
- Local beacon node
- Ports 8080-8083, 9100-9103 available

### Scenario 2: Production Testnet (Multi-Machine)

Distributed across multiple servers:

```bash
# On each machine, generate configs first
mix dvt_testnet_setup \
  --cluster-id "prod-testnet-cluster" \
  --nodes 7 \
  --threshold 5 \
  --network hoodi \
  --beacon-node "https://hoodi-beacon-api.stakingfacilities.com" \
  --config-only

# Then deploy using generated scripts
./scripts/deploy-dvt-prod-testnet-cluster.sh
```

**Requirements:**
- 7 separate machines (recommended)
- Robust network connectivity between nodes
- External beacon node or HA beacon setup
- Proper firewall configuration

### Scenario 3: Cloud Deployment (Kubernetes)

For cloud-native deployments:

```yaml
# Generated k8s manifests in k8s/dvt-cluster/
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dvt-validator-node
spec:
  replicas: 5  # One per DVT node
  # ... deployment configuration
```

Deploy with:

```bash
# Generate Kubernetes manifests
mix dvt_testnet_setup \
  --cluster-id "k8s-cluster" \
  --nodes 5 \
  --threshold 3 \
  --k8s-manifests

# Deploy to cluster
kubectl apply -f k8s/dvt-cluster/
```

## Security Considerations

### Key Management

DVT keys are generated using secure distributed key generation:

```bash
# Keys are automatically distributed
data/
├── dvt-node-1/keyshare.json  # Node 1's key share
├── dvt-node-2/keyshare.json  # Node 2's key share
└── ...
```

**Security practices:**
- Key shares are encrypted at rest
- Each node only stores its own share
- Minimum threshold required for signing
- Automatic key rotation supported

### Network Security

```elixir
# Network security configuration
network_security: %{
  message_auth: true,
  rate_limiting: %{
    enabled: true,
    max_messages_per_second: 100
  }
}
```

### HSM Integration

For production deployments:

```elixir
security: %{
  hsm: %{
    enabled: true,
    provider: :pkcs11,
    library_path: "/usr/local/lib/softhsm2.so"
  }
}
```

## Monitoring and Observability

### Prometheus Metrics

Each node exposes metrics on port 8080+node_id:

```bash
# Node 1 metrics
curl http://localhost:8081/metrics

# Key metrics:
# - dvt_consensus_latency
# - dvt_message_throughput  
# - dvt_attestation_success_rate
# - dvt_cluster_health
```

### Grafana Dashboard

Auto-generated dashboard includes:

- Cluster health overview
- Individual node status
- Consensus performance
- Network connectivity
- Duty completion rates

### Logging

Structured logging with cluster context:

```bash
# View logs for specific node
tail -f logs/dvt-node-1.log

# Search for consensus events
grep "consensus" logs/dvt-node-*.log

# Monitor attestation duties
grep "attestation" logs/dvt-node-*.log | grep -v "success"
```

## Troubleshooting

### Common Issues

#### 1. Nodes Can't Connect

```bash
# Check P2P connectivity
mix dvt_status --cluster-id "your-cluster" --detailed

# Common fixes:
# - Verify firewall rules for ports 9100-9105
# - Check network connectivity between nodes
# - Ensure bootstrap nodes are accessible
```

#### 2. Beacon Node Connection Failed

```bash
# Test beacon node connectivity
curl http://your-beacon-node:5052/eth/v1/node/health

# Common fixes:
# - Verify beacon node is synced
# - Check beacon node URL in configuration
# - Ensure beacon node API is enabled
```

#### 3. Consensus Timeout

```bash
# Check cluster health
mix dvt_status --cluster-id "your-cluster"

# If nodes are failing consensus:
# - Verify all nodes are online
# - Check network latency between nodes
# - Review consensus timeout settings
```

#### 4. Key Share Issues

```bash
# Verify key shares
ls -la data/dvt-node-*/keyshare.json

# Regenerate if corrupted
mix dvt_testnet_setup --cluster-id "your-cluster" --regenerate-keys
```

### Debug Commands

```bash
# Enable debug logging
MIX_ENV=dev mix dvt_testnet_setup --cluster-id "debug-cluster"

# Check internal state
iex -S mix
iex> ExWire.DVT.TestnetValidator.get_validator_status("cluster-id", 1)

# Network diagnostics
mix dvt_network_test --cluster-id "your-cluster"
```

## Performance Optimization

### Recommended Settings

```elixir
# High-performance configuration
consensus_config: %{
  timeouts: %{
    consensus_timeout: 4_000,    # Faster consensus
    aggregation_timeout: 1_000   # Quick aggregation
  },
  performance: %{
    message_batching: true,
    batch_size: 20,
    parallel_verification: true,
    verification_workers: 8
  }
}
```

### Hardware Recommendations

| Deployment | CPU | RAM | Storage | Network |
|------------|-----|-----|---------|---------|
| Development | 2 cores | 4GB | 50GB SSD | 100Mbps |
| Testnet | 4 cores | 8GB | 100GB SSD | 1Gbps |
| Production | 8 cores | 16GB | 500GB NVMe | 10Gbps |

### Performance Tuning

```bash
# System optimizations
echo 'net.core.rmem_max = 134217728' >> /etc/sysctl.conf
echo 'net.core.wmem_max = 134217728' >> /etc/sysctl.conf

# Elixir VM optimizations
export ERL_FLAGS="+P 1048576 +Q 65536"

# Start with performance flags
MIX_ENV=prod elixir --erl "+SPL true" -S mix dvt_testnet_validator
```

## Advanced Configuration

### Custom Consensus Parameters

```elixir
# Fine-tuned consensus settings
consensus_config: %{
  # Adjust based on network conditions
  timeouts: %{
    consensus_timeout: 6_000,      # Time to reach consensus
    view_change_timeout: 12_000,   # Leader election timeout
    aggregation_timeout: 2_000     # Signature aggregation
  },
  
  # Byzantine tolerance settings
  byzantine_tolerance: %{
    max_faulty_nodes: 2,           # For 7-node cluster
    recovery_strategy: :immediate,  # Quick recovery
    isolation_threshold: 3         # Isolate after failures
  }
}
```

### Multi-Network Operation

```elixir
# Support multiple testnets simultaneously
multi_network_config: %{
  enabled: true,
  networks: [:hoodi, :sepolia],
  resource_allocation: %{
    hoodi: 0.7,  # 70% resources to Hoodi
    sepolia: 0.3   # 30% resources to Sepolia
  }
}
```

## Production Checklist

Before deploying to production testnet:

### Pre-deployment

- [ ] All nodes have stable network connectivity
- [ ] Beacon nodes are fully synced and reliable
- [ ] Monitoring and alerting configured
- [ ] Backup and recovery procedures tested
- [ ] Security review completed
- [ ] Performance benchmarks passed

### Security Checklist

- [ ] Key shares properly encrypted and distributed
- [ ] HSM integration tested (if applicable)
- [ ] Network communication encrypted
- [ ] Access controls and RBAC configured
- [ ] Audit logging enabled
- [ ] Incident response plan in place

### Operational Checklist

- [ ] Documentation updated
- [ ] Team trained on operations procedures
- [ ] Runbook for common scenarios created
- [ ] Automated deployment tested
- [ ] Rollback procedures verified
- [ ] 24/7 monitoring coverage established

## API Reference

### Cluster Management

```bash
# Create new cluster
POST /api/v1/dvt/clusters
{
  "cluster_id": "new-cluster",
  "nodes": 5,
  "threshold": 3,
  "network": "hoodi"
}

# Get cluster status
GET /api/v1/dvt/clusters/{cluster_id}/status

# Update cluster configuration
PATCH /api/v1/dvt/clusters/{cluster_id}
```

### Node Operations

```bash
# Start node
POST /api/v1/dvt/nodes/{node_id}/start

# Stop node gracefully
POST /api/v1/dvt/nodes/{node_id}/stop

# Get node metrics
GET /api/v1/dvt/nodes/{node_id}/metrics
```

## Support and Community

### Getting Help

- **Documentation**: This guide and inline code documentation
- **Issues**: Report bugs at [GitHub Issues](https://github.com/poanetwork/mana/issues)
- **Discussions**: [Community Forum](https://forum.mana-ethereum.org)

### Contributing

- **Bug Reports**: Include logs, configuration, and reproduction steps
- **Feature Requests**: Describe use case and expected behavior
- **Pull Requests**: Follow coding standards and include tests

---

*For additional help or advanced configuration questions, please refer to the community resources or contact the development team.*