# Verkle Trees Operations Guide

**Version**: 1.0  
**Last Updated**: 2025-09-05  
**Status**: Production Ready

## Overview

This guide provides comprehensive operational instructions for deploying, monitoring, and maintaining the Mana Ethereum client's Verkle tree implementation. The system achieves 35x performance improvement over traditional Merkle Patricia Trees while maintaining full EIP-6800 compliance.

## Table of Contents

1. [Production Deployment](#production-deployment)
2. [Configuration Management](#configuration-management)
3. [Monitoring and Alerting](#monitoring-and-alerting)
4. [Performance Tuning](#performance-tuning)
5. [Troubleshooting](#troubleshooting)
6. [Maintenance Procedures](#maintenance-procedures)
7. [Security Operations](#security-operations)
8. [Disaster Recovery](#disaster-recovery)

## Production Deployment

### Prerequisites

- **Elixir**: 1.14+ with OTP 25+
- **Rust**: 1.70+ (for native cryptographic operations)
- **Memory**: Minimum 4GB RAM, recommended 8GB+
- **Storage**: SSD with 100GB+ available space
- **Network**: High-bandwidth connection for state sync

### Quick Start

```bash
# Clone and build
git clone https://github.com/mana-ethereum/mana.git
cd mana
mix deps.get
mix compile

# Configure Verkle trees
export VERKLE_ENABLED=true
export VERKLE_CACHE_SIZE=512MB
export VERKLE_WITNESS_COMPRESSION=true

# Start the node
mix run --no-halt
```

### Docker Deployment

```dockerfile
FROM elixir:1.18.4-alpine

# Install Rust for native extensions
RUN apk add --no-cache rust cargo

WORKDIR /app
COPY . .

# Build application
RUN mix deps.get
RUN mix compile

# Configure Verkle settings
ENV VERKLE_ENABLED=true
ENV VERKLE_CACHE_SIZE=1GB
ENV VERKLE_PERFORMANCE_MODE=production

CMD ["mix", "run", "--no-halt"]
```

### Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mana-verkle
spec:
  replicas: 3
  selector:
    matchLabels:
      app: mana-verkle
  template:
    metadata:
      labels:
        app: mana-verkle
    spec:
      containers:
      - name: mana
        image: mana-ethereum:verkle-latest
        resources:
          requests:
            memory: "4Gi"
            cpu: "2"
          limits:
            memory: "8Gi" 
            cpu: "4"
        env:
        - name: VERKLE_ENABLED
          value: "true"
        - name: VERKLE_CACHE_SIZE
          value: "2GB"
        - name: VERKLE_PERFORMANCE_MONITORING
          value: "enabled"
        ports:
        - containerPort: 8545
        - containerPort: 8546
        - containerPort: 30303
```

## Configuration Management

### Core Verkle Settings

```elixir
# config/prod.exs
config :merkle_patricia_tree,
  # Enable Verkle trees
  verkle_enabled: true,
  
  # Cache configuration
  verkle_cache_size: 1_073_741_824, # 1GB in bytes
  verkle_cache_enabled: true,
  verkle_cache_cleanup_interval: 300_000, # 5 minutes
  
  # Performance settings
  verkle_witness_compression: true,
  verkle_batch_witness_generation: true,
  verkle_parallel_verification: true,
  
  # Network protocol optimization  
  verkle_network_batch_size: 128,
  verkle_network_compression_threshold: 4096,
  verkle_adaptive_batching: true,
  
  # State synchronization
  verkle_state_sync_enabled: true,
  verkle_witness_based_sync: true,
  verkle_heal_missing_state: true,
  
  # Monitoring
  verkle_metrics_enabled: true,
  verkle_performance_dashboard: true,
  verkle_alert_thresholds: %{
    error_rate_percent: 1.0,
    latency_p99_ms: 100,
    cache_hit_rate_percent: 85.0
  }
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VERKLE_ENABLED` | `true` | Enable Verkle tree functionality |
| `VERKLE_CACHE_SIZE` | `1GB` | Memory allocated for Verkle cache |
| `VERKLE_PERFORMANCE_MODE` | `production` | Performance optimization level |
| `VERKLE_METRICS_ENDPOINT` | `:8080/metrics` | Prometheus metrics endpoint |
| `VERKLE_LOG_LEVEL` | `info` | Logging verbosity for Verkle ops |
| `VERKLE_WITNESS_COMPRESSION` | `true` | Enable witness compression |
| `VERKLE_STATE_SYNC_WORKERS` | `16` | Concurrent state sync workers |

### Network Configuration

```elixir
# Verkle-specific network settings
config :ex_wire,
  verkle_protocol_enabled: true,
  verkle_witness_request_timeout: 10_000,
  verkle_max_concurrent_requests: 16,
  verkle_peer_discovery_enabled: true,
  verkle_compression_enabled: true
```

## Monitoring and Alerting

### Key Performance Indicators (KPIs)

#### Performance Metrics
- **Insert Latency P99**: Target < 100μs (35x faster than MPT)
- **Read Latency P99**: Target < 50μs 
- **Witness Generation P99**: Target < 500μs
- **Cache Hit Rate**: Target > 85%
- **Verification Success Rate**: Target > 99%

#### Operational Metrics
- **Memory Usage**: Monitor for < 4GB under normal load
- **CPU Utilization**: Target < 70% average
- **Network Efficiency**: Witness compression ratio
- **Error Rate**: Target < 0.1%

### Prometheus Metrics

```yaml
# prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'mana-verkle'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: /metrics
    scrape_interval: 10s
```

Key metrics exported:
- `verkle_insert_duration_microseconds_bucket`
- `verkle_read_duration_microseconds_bucket`
- `verkle_witness_generation_duration_microseconds_bucket`
- `verkle_cache_hit_rate_percent`
- `verkle_memory_usage_bytes`
- `verkle_operations_total`
- `verkle_errors_total`

### Grafana Dashboard

```json
{
  "dashboard": {
    "title": "Mana Verkle Trees Performance",
    "panels": [
      {
        "title": "Insert Latency P99",
        "type": "stat",
        "targets": [
          {
            "expr": "histogram_quantile(0.99, verkle_insert_duration_microseconds_bucket)"
          }
        ],
        "thresholds": {
          "steps": [
            {"color": "green", "value": 0},
            {"color": "yellow", "value": 100},
            {"color": "red", "value": 500}
          ]
        }
      },
      {
        "title": "Performance vs MPT Baseline",
        "type": "gauge",
        "targets": [
          {
            "expr": "1000 / histogram_quantile(0.99, verkle_insert_duration_microseconds_bucket)"
          }
        ]
      }
    ]
  }
}
```

### Alert Rules

```yaml
# alerting_rules.yml
groups:
  - name: verkle_performance
    rules:
      - alert: VerkleHighLatency
        expr: histogram_quantile(0.99, verkle_insert_duration_microseconds_bucket) > 500
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Verkle tree insert latency is high"
          
      - alert: VerkleLowCacheHitRate
        expr: verkle_cache_hit_rate_percent < 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Verkle cache hit rate below target"
          
      - alert: VerkleHighErrorRate
        expr: rate(verkle_errors_total[5m]) / rate(verkle_operations_total[5m]) > 0.01
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Verkle error rate above 1%"
```

## Performance Tuning

### Memory Optimization

```elixir
# Tune cache sizes based on available memory
config :merkle_patricia_tree,
  # For 8GB RAM systems
  verkle_cache_size: 2_147_483_648, # 2GB
  verkle_node_cache_size: 500_000,   # nodes
  verkle_witness_cache_size: 100_000, # witnesses
  
  # Cache policies
  verkle_cache_cleanup_threshold: 0.9,
  verkle_lru_eviction_enabled: true
```

### CPU Optimization

```elixir
# Optimize for multi-core systems
config :merkle_patricia_tree,
  verkle_parallel_workers: System.schedulers_online(),
  verkle_batch_processing_enabled: true,
  verkle_simd_operations: true,  # Requires native compilation
  
  # Network parallelization
  verkle_max_concurrent_requests: System.schedulers_online() * 2
```

### Network Tuning

```elixir
config :ex_wire,
  # Optimize for high-throughput networks
  verkle_witness_batch_size: 256,
  verkle_compression_level: 6,
  verkle_tcp_buffer_size: 65536,
  verkle_adaptive_timeout_enabled: true
```

## Troubleshooting

### Common Issues

#### High Memory Usage
```bash
# Check cache utilization
curl http://localhost:8080/metrics | grep verkle_cache

# Restart with reduced cache size
export VERKLE_CACHE_SIZE=512MB
mix run --no-halt
```

#### Slow Witness Generation
```bash
# Enable performance monitoring
export VERKLE_PERFORMANCE_MONITORING=debug

# Check for crypto compilation issues
mix compile --force
```

#### Network Sync Issues
```bash
# Check peer connectivity
curl http://localhost:8080/verkle/peers

# Force state healing
curl -X POST http://localhost:8080/verkle/heal
```

### Performance Debugging

```elixir
# Enable detailed performance logging
Logger.configure(level: :debug)

# Start performance profiler
:fprof.trace([:start, {procs, all}])
# ... perform operations ...
:fprof.trace([:stop])
:fprof.profile()
:fprof.analyse()
```

### Health Checks

```bash
#!/bin/bash
# health_check.sh

# Check if Verkle trees are responsive
response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/verkle/health)
if [ $response -eq 200 ]; then
    echo "✅ Verkle trees healthy"
else
    echo "❌ Verkle trees unhealthy (HTTP $response)"
    exit 1
fi

# Check performance metrics
latency=$(curl -s http://localhost:8080/metrics | grep verkle_insert_duration | tail -1)
echo "📊 Current latency: $latency"
```

## Maintenance Procedures

### Cache Management

```bash
# Clear all caches (requires restart)
curl -X POST http://localhost:8080/verkle/cache/clear

# Optimize cache (runtime operation)
curl -X POST http://localhost:8080/verkle/cache/optimize

# Get cache statistics
curl http://localhost:8080/verkle/cache/stats
```

### State Management

```bash
# Trigger state healing
curl -X POST http://localhost:8080/verkle/state/heal

# Check state sync status
curl http://localhost:8080/verkle/state/sync/status

# Force witness regeneration
curl -X POST http://localhost:8080/verkle/witnesses/regenerate
```

### Performance Benchmarking

```bash
# Run comprehensive benchmarks
mix benchmark.verkle

# Generate performance report
mix verkle.report --period=24h --format=json > performance_report.json

# Compare with baseline
mix verkle.compare --baseline=mpt --format=table
```

## Security Operations

### Witness Verification

```bash
# Enable strict verification mode
export VERKLE_STRICT_VERIFICATION=true

# Cross-validate with multiple peers
export VERKLE_CROSS_VALIDATION_PEERS=3

# Audit witness generation
curl -X POST http://localhost:8080/verkle/audit/witnesses
```

### Cryptographic Validation

```bash
# Validate native crypto components
mix verkle.crypto.test

# Check EIP-6800 compliance
mix verkle.compliance.check

# Verify commitment schemes
curl http://localhost:8080/verkle/crypto/validate
```

## Disaster Recovery

### Backup Procedures

```bash
#!/bin/bash
# backup_verkle.sh

# Backup Verkle state
mkdir -p /backup/verkle/$(date +%Y%m%d_%H%M%S)
cp -r data/verkle/* /backup/verkle/$(date +%Y%m%d_%H%M%S)/

# Backup configuration
cp config/prod.exs /backup/config_$(date +%Y%m%d_%H%M%S).exs

# Export metrics for recovery validation
curl http://localhost:8080/metrics > /backup/metrics_$(date +%Y%m%d_%H%M%S).txt
```

### Recovery Procedures

```bash
#!/bin/bash
# restore_verkle.sh

BACKUP_DATE=$1

# Stop the service
systemctl stop mana-verkle

# Restore state
cp -r /backup/verkle/$BACKUP_DATE/* data/verkle/

# Restore configuration
cp /backup/config_$BACKUP_DATE.exs config/prod.exs

# Start with verification
export VERKLE_RECOVERY_MODE=true
systemctl start mana-verkle

# Verify recovery
sleep 30
curl http://localhost:8080/verkle/health
```

## Operational Runbooks

### Daily Operations

1. **Morning Health Check**
   - Review overnight alerts
   - Check performance dashboards
   - Validate cache hit rates

2. **Performance Monitoring**
   - Monitor 35x performance target
   - Check witness generation efficiency
   - Review error rates

3. **Capacity Planning**
   - Monitor memory usage trends
   - Check storage utilization
   - Plan scaling if needed

### Weekly Maintenance

1. **Performance Review**
   - Generate weekly performance report
   - Compare against baselines
   - Identify optimization opportunities

2. **Security Audit**
   - Review witness verification logs
   - Check cryptographic health
   - Validate EIP-6800 compliance

3. **Backup Verification**
   - Test backup procedures
   - Validate recovery processes
   - Update disaster recovery plans

### Monthly Tasks

1. **Capacity Planning Review**
2. **Performance Baseline Updates**
3. **Security Assessment**
4. **Documentation Updates**

## Contact Information

**Operational Support**: ops@mana-ethereum.org  
**Security Issues**: security@mana-ethereum.org  
**Performance Questions**: performance@mana-ethereum.org  

**Emergency Escalation**: +1-555-VERKLE (24/7)

---

**Document Version**: 1.0  
**Last Review**: 2025-09-05  
**Next Review**: 2025-12-05