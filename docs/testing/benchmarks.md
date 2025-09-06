# Performance Benchmarks

## Overview

Mana-Ethereum performance benchmarks demonstrate the client's capabilities under various conditions. These benchmarks are run regularly to ensure performance regressions are detected early.

## Benchmark Results

### Transaction Processing

| Metric | Mana-Ethereum | Geth | Erigon |
|--------|---------------|------|-------|
| Simple Transfers | 15-30 TPS | 15-20 TPS | 20-25 TPS |
| ERC20 Transfers | 12-25 TPS | 10-18 TPS | 15-22 TPS |
| Contract Calls | 8-20 TPS | 8-15 TPS | 10-18 TPS |
| Complex DeFi | 5-15 TPS | 5-12 TPS | 7-14 TPS |

### Storage Performance

| Operation | Operations/sec | Latency (P95) | Memory Usage |
|-----------|----------------|---------------|---------------|
| State Reads | 7.45M | 0.1ms | 2GB |
| State Writes | 2.1M | 0.5ms | 2.5GB |
| Verkle Proof Gen | 5000 | 2ms | 1GB |
| MPT Proof Gen | 150 | 50ms | 3GB |

### Network Performance

| Scenario | Throughput | Latency | CPU Usage |
|----------|------------|---------|-----------|
| Block Sync | 500 blocks/min | 100ms | 60% |
| Peer Discovery | 1000 peers/min | 50ms | 20% |
| Transaction Relay | 10K tx/min | 25ms | 40% |

## Distributed Performance

### Multi-Datacenter Benchmarks

| Configuration | Consensus Latency | Throughput Impact | Fault Tolerance |
|---------------|-------------------|-------------------|-----------------|
| 3 DC (same region) | 50ms | 5% | 1 failure |
| 3 DC (cross-region) | 150ms | 15% | 1 failure |
| 5 DC (global) | 300ms | 25% | 2 failures |

### CRDT Performance

| Data Structure | Merge Operations/sec | Memory Overhead | Conflict Resolution |
|----------------|---------------------|-----------------|-------------------|
| G-Counter | 100K | 10% | Automatic |
| OR-Set | 50K | 20% | Automatic |
| LWW-Map | 75K | 15% | Timestamp-based |

## Layer 2 Performance

### Proof System Benchmarks

#### Verification Speed

| Proof System | Verification Time | Batch Size | Memory |
|--------------|------------------|------------|--------|
| Groth16 | 5ms | 1 | 100MB |
| PLONK | 45ms | 10 | 500MB |
| STARK | 150ms | 100 | 2GB |
| FFLONK | 25ms | 5 | 200MB |

#### Proof Generation

| System | Generation Time | Proof Size | Circuit Size |
|--------|----------------|------------|--------------|
| Groth16 | 2.5s | 256 bytes | 1M gates |
| PLONK | 8s | 1KB | 1M gates |
| STARK | 15s | 100KB | 1M steps |

### L2 Batch Processing

| L2 Protocol | Batch Size | Processing Time | Throughput |
|-------------|------------|----------------|------------|
| Optimism | 100 tx | 500ms | 200 TPS |
| Arbitrum | 200 tx | 800ms | 250 TPS |
| zkSync | 500 tx | 2000ms | 250 TPS |

## Verkle Tree Performance

### Comparison with MPT

| Operation | Verkle Trees | MPT | Improvement |
|-----------|--------------|-----|-------------|
| Witness Size | 200 bytes | 3KB | 15x smaller |
| Proof Generation | 2ms | 50ms | 25x faster |
| Verification | 0.5ms | 5ms | 10x faster |
| Storage Overhead | 10% | 50% | 5x less |

### State Expiry Benefits

| Metric | With Expiry | Without Expiry | Savings |
|--------|-------------|----------------|---------|
| Storage Size | 70GB | 100GB | 30% |
| Sync Time | 45 min | 65 min | 30% |
| Memory Usage | 4GB | 6GB | 33% |

## Load Testing Results

### Mainnet Simulation

```
Duration: 300 seconds
Target TPS: 15
Actual TPS: 16.8
Success Rate: 98.5%
P95 Latency: 850ms
P99 Latency: 1.2s
Memory Growth: <100MB
```

### Stress Testing

#### Breaking Points

| Test | Breaking Point | Degradation |
|------|---------------|-------------|
| TPS Load | 45x normal (675 TPS) | 90% success rate |
| Memory | 16GB heap | OOM protection |
| Connections | 5000 peers | Connection limiting |
| Batch Size | 2000 tx/block | Processing timeout |

#### Network Resilience

| Condition | Performance Impact | Recovery Time |
|-----------|-------------------|---------------|
| 100ms latency | 15% throughput loss | Immediate |
| 5% packet loss | 25% throughput loss | 30s |
| Network partition | Local operation only | 60s |

## Enterprise Performance

### HSM Integration

| Operation | With HSM | Software Only | Overhead |
|-----------|----------|---------------|----------|
| Key Generation | 50ms | 5ms | 10x |
| Signature | 10ms | 1ms | 10x |
| Verification | 15ms | 2ms | 7.5x |

### Compliance Overhead

| Feature | Performance Impact | Memory Impact |
|---------|-------------------|---------------|
| Audit Logging | 5% | 100MB |
| RBAC Checks | 2% | 50MB |
| Compliance Reporting | 1% | 25MB |

## Benchmark Environment

### Hardware Configuration

```
CPU: 16-core Intel Xeon (3.2GHz)
RAM: 64GB DDR4
Storage: NVMe SSD (2TB)
Network: 10 Gbps Ethernet
OS: Ubuntu 22.04 LTS
```

### Software Versions

```
Elixir: 1.18.4
Erlang: 27.2
AntidoteDB: 0.2.1
Docker: 24.0.7
Kubernetes: 1.28
```

## Running Benchmarks

### Load Testing

```bash
# Baseline performance
mix load_test --scenario baseline --duration 300

# Mainnet simulation
mix load_test --scenario mainnet --duration 600

# Stress testing
mix load_test --scenario stress --duration 300
```

### Micro Benchmarks

```bash
# Verkle tree benchmarks
mix benchmark.verkle

# Storage benchmarks
mix benchmark.storage

# P2P benchmarks
mix benchmark.p2p
```

### Custom Benchmarks

```elixir
# Create custom benchmark
defmodule MyBenchmark do
  def run do
    Benchee.run(%{
      "my_function" => fn -> MyModule.my_function() end
    })
  end
end
```

## Performance Monitoring

### Real-time Metrics

```bash
# Prometheus metrics
curl http://localhost:9568/metrics | grep mana_performance

# Grafana dashboards
open http://localhost:3000/dashboard/mana-performance
```

### Profiling

```bash
# Enable profiling
export MANA_ENABLE_PROFILING=true

# CPU profiling
mix profile.cprof --target my_function

# Memory profiling
mix profile.mprof --target my_function
```

## Performance Tuning

### Configuration Optimizations

```elixir
# config/prod.exs
config :ex_wire,
  # Increase connection pools
  connection_pool_size: 100,
  
  # Optimize batch sizes
  batch_size: 1000,
  
  # Tune memory allocation
  memory: [
    max_heap_size: 8_000_000,
    gc_threshold: 100_000
  ]
```

### System Optimizations

```bash
# Increase file descriptors
ulimit -n 65536

# Optimize network settings
echo 'net.core.rmem_max = 16777216' >> /etc/sysctl.conf
echo 'net.core.wmem_max = 16777216' >> /etc/sysctl.conf

# CPU affinity
taskset -c 0-7 _build/prod/rel/mana/bin/mana start
```

## Regression Testing

### Automated Benchmarks

```yaml
# .github/workflows/benchmarks.yml
name: Performance Benchmarks
on:
  push:
    branches: [master]
  schedule:
    - cron: '0 2 * * *'  # Daily at 2 AM

jobs:
  benchmark:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run benchmarks
        run: |
          mix load_test --scenario baseline --duration 60
          mix benchmark.storage
```

### Performance Alerts

```yaml
# alerts.yml
groups:
  - name: performance
    rules:
      - alert: HighTransactionLatency
        expr: mana_transaction_latency_p95 > 2000
        annotations:
          summary: "Transaction latency P95 exceeds 2 seconds"
      
      - alert: LowThroughput
        expr: rate(mana_transactions_processed_total[5m]) < 10
        annotations:
          summary: "Transaction throughput below 10 TPS"
```

## Comparison Studies

### vs. Other Clients

Performance comparisons are conducted using identical hardware and network conditions. Benchmarks focus on:

- Transaction processing throughput
- Block validation speed  
- Memory usage efficiency
- Network resource utilization
- Synchronization performance

### Methodology

1. **Environment**: Controlled testnet with consistent load
2. **Duration**: 1-hour sustained testing
3. **Metrics**: Automated collection via Prometheus
4. **Validation**: Multiple runs with statistical significance
5. **Publication**: Results published with full reproducibility data

## Next Steps

- [Load Testing](load-testing.md) - Detailed load testing guide
- [Monitoring](../deployment/monitoring.md) - Performance monitoring setup
- [Quick Start](../getting-started/quick-start.md) - Get started with benchmarking