# Mana-Ethereum Production Deployment Guide

## Overview

Mana-Ethereum is a high-performance distributed Ethereum client built in Elixir, featuring 35x faster Verkle trees, 7.45M ops/sec storage capability, and enterprise-grade security. This guide covers complete production deployment.

## Architecture

### Core Components
- **Blockchain Layer**: State transitions, account management, Verkle trees
- **EVM**: Full Ethereum Virtual Machine with EIP support
- **P2P Network**: Modern LibP2P with GossipSub, Layer 2 integration
- **Storage**: AntidoteDB backend with CRDT-based distributed state
- **Enterprise**: HSM integration, RBAC, compliance frameworks
- **Monitoring**: Prometheus, Grafana, distributed tracing

### Performance Specifications
- **Verkle Trees**: 35x faster than traditional Merkle Patricia Trees
- **Storage Throughput**: 7.45M operations per second
- **Parallel Processing**: Flow-based concurrent attestation processing
- **Native Crypto**: Rust NIFs for BLS12-381 and KZG operations
- **Multi-Datacenter**: CRDT-based state synchronization

## Prerequisites

### System Requirements
- **CPU**: 16+ cores (32+ recommended for high throughput)
- **RAM**: 64GB minimum (128GB+ recommended)
- **Storage**: NVMe SSD with 10,000+ IOPS
- **Network**: 10Gbps connection with low latency

### Software Dependencies
- Docker 24.0+
- Kubernetes 1.27+
- Helm 3.12+
- PostgreSQL 15+ (for metadata)
- AntidoteDB cluster (for state storage)

### Security Prerequisites
- HSM (Hardware Security Module) for production key management
- TLS certificates for all external communications
- VPN or private networking for inter-node communication

## Production Configuration

### Environment Variables
```bash
# Core Configuration
NODE_NAME=mana@production.example.com
PORT=8545
DISCOVERY_ENABLED=true
MAX_PEERS=100

# Database Configuration
ANTIDOTE_NODES=node1.db.internal:8087,node2.db.internal:8087,node3.db.internal:8087
DB_TIMEOUT=10000
DB_CONNECT_TIMEOUT=5000

# Performance Tuning
VERKLE_CACHE_SIZE=1000000
WITNESS_CACHE_SIZE=100000
WITNESS_WORKERS=16

# Security Configuration
HSM_ENABLED=true
PKCS11_LIBRARY=/usr/lib/softhsm/libsofthsm2.so
HSM_SLOT_ID=0
HSM_PIN=secure_pin_from_vault

# Monitoring
TELEMETRY_ENABLED=true
STRUCTURED_LOGGING=true
LOG_LEVEL=info
PROMETHEUS_PORT=9090
METRICS_PORT=9091

# Layer 2 Support
LAYER2_ENABLED=true
OPTIMISM_L1_RPC=https://mainnet.infura.io/v3/YOUR_KEY
ARBITRUM_L1_RPC=https://mainnet.infura.io/v3/YOUR_KEY
L2_BATCH_SIZE=1000

# Security Hardening
RATE_LIMITING=true
MAX_RPS=10000
DDOS_PROTECTION=true
```

## Deployment Process

### 1. Pre-Deployment Validation
```bash
# Run security validation
./scripts/security-validation.sh

# Validate configuration
./scripts/deploy-production.sh check

# Run performance benchmarks
MIX_ENV=prod mix benchmark.verkle
```

### 2. Infrastructure Setup

#### AntidoteDB Cluster Deployment
```yaml
# k8s/antidotedb-values.yaml
replicaCount: 3
resources:
  requests:
    cpu: 4
    memory: 16Gi
  limits:
    cpu: 8
    memory: 32Gi
persistence:
  enabled: true
  size: 1000Gi
  storageClass: fast-ssd
```

#### Kubernetes Namespace Setup
```bash
kubectl create namespace mana-ethereum
kubectl create namespace mana-storage
kubectl create namespace mana-monitoring
```

### 3. Security Configuration

#### HSM Setup
```bash
# Initialize HSM with production keys
softhsm2-util --init-token --slot 0 --label "mana-prod" --pin $HSM_PIN --so-pin $HSM_SO_PIN

# Import signing keys
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so --login --pin $HSM_PIN --write-object mana-signing-key.pem --type privkey --label mana-signing-key
```

#### TLS Certificate Setup
```bash
# Generate production certificates
cert-manager create certificate mana-ethereum-tls \
    --namespace mana-ethereum \
    --dns-names mana-ethereum.example.com,api.mana-ethereum.example.com
```

### 4. Application Deployment

#### Build and Deploy
```bash
# Set registry and version
export DOCKER_REGISTRY=ghcr.io/your-org/mana-ethereum
export VERSION=$(git rev-parse --short HEAD)

# Deploy to production
./scripts/deploy-production.sh deploy
```

#### Helm Configuration
```yaml
# k8s/values-production.yaml
replicaCount: 3
image:
  repository: ghcr.io/your-org/mana-ethereum
  tag: latest
  pullPolicy: Always

resources:
  requests:
    cpu: 8
    memory: 32Gi
  limits:
    cpu: 16
    memory: 64Gi

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80

service:
  type: LoadBalancer
  port: 8545
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"

persistence:
  enabled: true
  size: 500Gi
  storageClass: fast-ssd
```

## Monitoring Setup

### Prometheus Configuration
```yaml
# monitoring/prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "alerts/*.yml"

scrape_configs:
  - job_name: 'mana-ethereum'
    static_configs:
      - targets: ['mana-ethereum:9091']
    scrape_interval: 5s
    
  - job_name: 'antidotedb'
    static_configs:
      - targets: ['antidote-cluster:9100']
```

### Grafana Dashboards
Key metrics to monitor:
- **Performance**: Verkle tree operations/sec, witness generation time
- **Storage**: AntidoteDB throughput, cache hit rates  
- **Network**: P2P peer count, sync status, Layer 2 batch processing
- **Security**: HSM status, failed authentication attempts, rate limiting
- **System**: CPU, memory, disk usage, network I/O

## Security Hardening

### Network Security
```bash
# Configure firewall rules
ufw allow 8545/tcp  # JSON-RPC
ufw allow 30303/tcp # P2P
ufw allow 30303/udp # P2P discovery
ufw deny 8087/tcp   # Restrict AntidoteDB to internal
```

### Access Controls
```yaml
# RBAC configuration
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: mana-ethereum
  name: mana-operator
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
```

### Compliance Features
- **SOX Compliance**: Audit logging, segregation of duties
- **Data Retention**: Automated data lifecycle management
- **Regulatory Reporting**: Automated compliance reports

## Performance Optimization

### Verkle Tree Tuning
```elixir
# Runtime optimization
config :merkle_patricia_tree,
  verkle_cache_size: 1_000_000,
  witness_workers: System.schedulers_online() * 4,
  batch_optimization: true,
  native_crypto: true
```

### AntidoteDB Optimization
```erlang
% antidotedb.config
{antidote, [
    {txn_cert, true},
    {recover_from_log, true},
    {recover_meta_data_on_start, true},
    {sync_log, false}, % Async for performance
    {enable_logging, true}
]}.
```

## Monitoring and Alerting

### Critical Alerts
```yaml
# prometheus/alerts/mana-alerts.yml
groups:
  - name: mana-ethereum
    rules:
      - alert: HighVerkleTreeLatency
        expr: verkle_tree_operation_duration_seconds > 0.1
        for: 2m
        
      - alert: AntidoteDBDown
        expr: up{job="antidotedb"} == 0
        for: 1m
        
      - alert: HSMConnectionFailed
        expr: hsm_connection_status == 0
        for: 30s
```

### Performance Benchmarks
Expected production performance:
- **Verkle Operations**: >100k ops/sec per node
- **Storage Throughput**: >7.45M ops/sec cluster-wide
- **P2P Sync**: <30s for recent blocks
- **Layer 2 Processing**: >10k transactions/sec

## Disaster Recovery

### Backup Strategy
```bash
# Automated backup script
#!/bin/bash
kubectl exec -n mana-storage antidote-0 -- antidote-admin backup /backup/$(date +%Y%m%d_%H%M%S)
aws s3 sync /backup/ s3://mana-ethereum-backups/
```

### Recovery Procedures
1. **Node Failure**: Automatic pod restart and state sync
2. **Data Corruption**: Restore from latest AntidoteDB snapshot
3. **Complete Disaster**: Deploy new cluster and restore from S3

## Maintenance

### Regular Tasks
- **Daily**: Performance monitoring review
- **Weekly**: Security log analysis, dependency updates
- **Monthly**: Disaster recovery testing, capacity planning
- **Quarterly**: Security audit, performance optimization review

### Upgrade Process
```bash
# Rolling update procedure
helm upgrade mana-ethereum k8s/helm-chart \
    --set image.tag=NEW_VERSION \
    --wait --timeout=15m
```

## Troubleshooting

### Common Issues

#### High Latency
```bash
# Check Verkle tree performance
kubectl exec -n mana-ethereum mana-0 -- mix run -e "VerkleTree.Metrics.report()"

# Optimize cache settings
kubectl patch configmap mana-config -p '{"data":{"VERKLE_CACHE_SIZE":"2000000"}}'
```

#### Storage Issues
```bash
# Check AntidoteDB status
kubectl exec -n mana-storage antidote-0 -- antidote-admin status

# Monitor storage metrics
kubectl top pods -n mana-storage --containers
```

#### HSM Problems
```bash
# Test HSM connectivity
kubectl exec -n mana-ethereum mana-0 -- mix run -e "ExWire.Enterprise.HSMIntegration.test_connection()"

# Check PKCS#11 status
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so --list-slots
```

## Support and Contacts

### Emergency Contacts
- **Infrastructure**: ops-team@example.com
- **Security**: security@example.com  
- **Development**: dev-team@example.com

### Documentation Links
- [Architecture Guide](docs/architecture/overview.md)
- [API Reference](docs/api/)
- [Security Guide](docs/enterprise/)
- [Performance Tuning](docs/performance/)

---

For additional support, consult the comprehensive documentation in the `docs/` directory or contact the development team.