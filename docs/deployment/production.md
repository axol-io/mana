# Production Deployment

## Overview

This guide covers deploying Mana-Ethereum in production environments with high availability, security, and monitoring.

## Prerequisites

### System Requirements

#### Minimum Requirements
- **CPU**: 8 cores (Intel Xeon or AMD EPYC)
- **RAM**: 16GB
- **Storage**: 1TB NVMe SSD
- **Network**: 1 Gbps bandwidth

#### Recommended Requirements
- **CPU**: 16+ cores
- **RAM**: 32GB+
- **Storage**: 2TB+ NVMe SSD
- **Network**: 10+ Gbps bandwidth

### Operating System

Supported platforms:
- Ubuntu 20.04+ LTS
- CentOS 8+
- Red Hat Enterprise Linux 8+
- Debian 11+

## Deployment Methods

### Docker Deployment

#### Single Node

```bash
# Create data directory
mkdir -p /opt/mana/data

# Run Mana container
docker run -d \
  --name mana-ethereum \
  --restart unless-stopped \
  -p 30303:30303 \
  -p 8545:8545 \
  -p 8546:8546 \
  -p 9568:9568 \
  -v /opt/mana/data:/opt/mana/data \
  -v /opt/mana/config:/opt/mana/config \
  --memory=16g \
  --cpus=8 \
  mana-ethereum:latest
```

#### Docker Compose

```yaml
# docker-compose.yml
version: '3.8'

services:
  mana:
    image: mana-ethereum:latest
    container_name: mana-ethereum
    restart: unless-stopped
    ports:
      - "30303:30303"
      - "8545:8545" 
      - "8546:8546"
      - "9568:9568"
    volumes:
      - mana_data:/opt/mana/data
      - ./config:/opt/mana/config
    environment:
      - MANA_CHAIN=mainnet
      - MANA_NETWORK_PORT=30303
      - MANA_HTTP_PORT=8545
      - MANA_WS_PORT=8546
    deploy:
      resources:
        limits:
          memory: 16G
          cpus: '8'
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  antidote:
    image: antidotedb/antidote:latest
    container_name: antidote-db
    restart: unless-stopped
    ports:
      - "8087:8087"
    volumes:
      - antidote_data:/opt/antidote/data

volumes:
  mana_data:
  antidote_data:
```

### Kubernetes Deployment

#### Namespace Setup

```bash
kubectl create namespace mana-ethereum
kubectl config set-context --current --namespace=mana-ethereum
```

#### Production Configuration

```yaml
# k8s/production.yml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mana-ethereum
  namespace: mana-ethereum
spec:
  serviceName: mana-ethereum
  replicas: 3
  selector:
    matchLabels:
      app: mana-ethereum
  template:
    metadata:
      labels:
        app: mana-ethereum
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        fsGroup: 1001
      containers:
      - name: mana
        image: mana-ethereum:v1.0.0
        ports:
        - containerPort: 30303
          name: p2p
        - containerPort: 8545
          name: http-rpc
        - containerPort: 8546
          name: ws-rpc
        - containerPort: 9568
          name: metrics
        env:
        - name: MANA_DATACENTER_ID
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: MANA_DB_HOST
          value: "antidote-service"
        volumeMounts:
        - name: data
          mountPath: /opt/mana/data
        - name: config
          mountPath: /opt/mana/config
        resources:
          requests:
            memory: "8Gi"
            cpu: "4"
          limits:
            memory: "16Gi"
            cpu: "8"
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /health/live
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 30
      volumes:
      - name: config
        configMap:
          name: mana-config
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: "fast-ssd"
      resources:
        requests:
          storage: 1Ti
```

### Native Installation

#### System Setup

```bash
# Install dependencies
sudo apt update
sudo apt install -y build-essential git curl

# Install Elixir and Erlang
curl -fsSL https://github.com/asdf-vm/asdf/archive/v0.13.1.tar.gz | tar -xz
echo '. $HOME/.asdf/completions/asdf.bash' >> ~/.bashrc
source ~/.bashrc

asdf plugin-add erlang
asdf plugin-add elixir
asdf install erlang 27.2
asdf install elixir 1.18.4
asdf global erlang 27.2
asdf global elixir 1.18.4
```

#### Build and Install

```bash
# Clone repository
git clone --recurse-submodules https://github.com/axol-io/mana.git
cd mana

# Install dependencies
mix deps.get

# Build release
MIX_ENV=prod mix release

# Install to system
sudo cp -r _build/prod/rel/mana /opt/mana
sudo chown -R mana:mana /opt/mana
```

#### Systemd Service

```ini
# /etc/systemd/system/mana-ethereum.service
[Unit]
Description=Mana Ethereum Client
After=network.target
Wants=network.target

[Service]
Type=forking
User=mana
Group=mana
WorkingDirectory=/opt/mana
Environment=HOME=/opt/mana
ExecStart=/opt/mana/bin/mana start
ExecStop=/opt/mana/bin/mana stop
ExecReload=/opt/mana/bin/mana restart
Restart=on-failure
RestartSec=10
KillMode=mixed
KillSignal=SIGTERM
TimeoutSec=60
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

## Configuration

### Production Configuration

```elixir
# config/prod.exs
import Config

# Network configuration
config :ex_wire,
  network: [
    interface: {0, 0, 0, 0},
    port: 30303,
    discovery: true,
    max_peers: 100,
    bootnode_file: "/opt/mana/config/bootnodes.txt"
  ]

# Blockchain configuration
config :blockchain,
  chain: :mainnet,
  sync_mode: :fast,
  pruning: [
    enabled: true,
    keep_blocks: 1000
  ]

# Database configuration
config :merkle_patricia_tree,
  db: [
    type: :antidote,
    connection: [
      host: {:system, "MANA_DB_HOST", "localhost"},
      port: {:system, :integer, "MANA_DB_PORT", 8087}
    ],
    cache_size: 100_000,
    write_batch_size: 10_000
  ]

# JSON-RPC configuration
config :jsonrpc2,
  http: [
    port: {:system, :integer, "MANA_HTTP_PORT", 8545},
    cors: true,
    max_connections: 1000
  ],
  ws: [
    port: {:system, :integer, "MANA_WS_PORT", 8546},
    max_connections: 500
  ]

# Monitoring configuration
config :ex_wire, :monitoring,
  enabled: true,
  prometheus: [
    enabled: true,
    port: {:system, :integer, "MANA_METRICS_PORT", 9568}
  ]

# Logging configuration
config :logger,
  level: :info,
  backends: [{LoggerFileBackend, :file}],
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

config :logger, :file,
  path: "/opt/mana/logs/mana.log",
  level: :info,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :module]
```

### Security Configuration

```elixir
# config/security.exs
import Config

# Enable authentication
config :jsonrpc2,
  auth: [
    enabled: true,
    method: :jwt,
    secret_key: {:system, "MANA_JWT_SECRET"},
    token_ttl: 3600
  ]

# SSL/TLS configuration
config :ex_wire,
  ssl: [
    enabled: true,
    certfile: "/etc/ssl/certs/mana.pem",
    keyfile: "/etc/ssl/private/mana.key",
    port: 30304
  ]

# Rate limiting
config :ex_wire,
  rate_limiting: [
    enabled: true,
    requests_per_minute: 1000,
    burst_size: 100
  ]
```

## Multi-Datacenter Deployment

### Three-Datacenter Setup

```yaml
# Datacenter A (Primary)
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mana-datacenter-a
spec:
  template:
    spec:
      containers:
      - name: mana
        env:
        - name: MANA_DATACENTER_ID
          value: "datacenter_a"
        - name: MANA_ROLE
          value: "primary"
        - name: MANA_PEERS
          value: "datacenter_b:4369,datacenter_c:4369"

---
# Datacenter B (Secondary)  
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mana-datacenter-b
spec:
  template:
    spec:
      containers:
      - name: mana
        env:
        - name: MANA_DATACENTER_ID
          value: "datacenter_b"
        - name: MANA_ROLE
          value: "secondary"
```

### Network Configuration

```yaml
# Inter-datacenter networking
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: mana-gateway
spec:
  servers:
  - port:
      number: 4369
      name: erlang-distribution
      protocol: TCP
    hosts:
    - mana-datacenter-a.example.com
    - mana-datacenter-b.example.com
    - mana-datacenter-c.example.com
```

## Load Balancing

### HTTP Load Balancer

```nginx
# /etc/nginx/sites-available/mana-ethereum
upstream mana_http {
    least_conn;
    server mana-1:8545 max_fails=3 fail_timeout=30s;
    server mana-2:8545 max_fails=3 fail_timeout=30s;
    server mana-3:8545 max_fails=3 fail_timeout=30s;
}

upstream mana_ws {
    ip_hash;  # Sticky sessions for WebSocket
    server mana-1:8546 max_fails=3 fail_timeout=30s;
    server mana-2:8546 max_fails=3 fail_timeout=30s;
    server mana-3:8546 max_fails=3 fail_timeout=30s;
}

server {
    listen 80;
    listen 443 ssl http2;
    server_name ethereum-api.example.com;
    
    # SSL configuration
    ssl_certificate /etc/ssl/certs/mana.pem;
    ssl_certificate_key /etc/ssl/private/mana.key;
    
    # HTTP JSON-RPC
    location / {
        proxy_pass http://mana_http;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_connect_timeout 30s;
        proxy_read_timeout 60s;
    }
    
    # WebSocket
    location /ws {
        proxy_pass http://mana_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
    
    # Health check
    location /health {
        access_log off;
        return 200 "healthy\n";
    }
}
```

## Monitoring and Alerting

### Prometheus Configuration

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "alert_rules.yml"

scrape_configs:
  - job_name: 'mana-ethereum'
    static_configs:
      - targets:
        - 'mana-1:9568'
        - 'mana-2:9568' 
        - 'mana-3:9568'
    scrape_interval: 15s
    metrics_path: /metrics

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - alertmanager:9093
```

### Alert Rules

```yaml
# alert_rules.yml
groups:
  - name: mana-ethereum
    rules:
      - alert: NodeDown
        expr: up{job="mana-ethereum"} == 0
        for: 1m
        annotations:
          summary: "Mana node {{ $labels.instance }} is down"
      
      - alert: HighMemoryUsage
        expr: mana_memory_usage_bytes / mana_memory_limit_bytes > 0.9
        for: 5m
        annotations:
          summary: "High memory usage on {{ $labels.instance }}"
      
      - alert: SyncLagging
        expr: mana_sync_current_block < mana_sync_highest_block - 100
        for: 10m
        annotations:
          summary: "Node {{ $labels.instance }} is lagging in sync"
```

## Backup and Recovery

### Data Backup

```bash
#!/bin/bash
# backup-mana.sh

BACKUP_DIR="/backups/mana-$(date +%Y%m%d-%H%M%S)"
DATA_DIR="/opt/mana/data"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Stop Mana service
systemctl stop mana-ethereum

# Backup blockchain data
tar -czf "$BACKUP_DIR/blockchain.tar.gz" "$DATA_DIR/blockchain"

# Backup configuration
cp -r /opt/mana/config "$BACKUP_DIR/"

# Start Mana service
systemctl start mana-ethereum

# Cleanup old backups (keep 7 days)
find /backups -name "mana-*" -mtime +7 -exec rm -rf {} \;
```

### Disaster Recovery

```bash
#!/bin/bash
# restore-mana.sh

BACKUP_FILE="$1"
DATA_DIR="/opt/mana/data"

if [ -z "$BACKUP_FILE" ]; then
    echo "Usage: $0 <backup-file>"
    exit 1
fi

# Stop service
systemctl stop mana-ethereum

# Clear existing data
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"

# Restore from backup
tar -xzf "$BACKUP_FILE" -C "$DATA_DIR"

# Start service
systemctl start mana-ethereum
```

## Maintenance

### Rolling Updates

```bash
#!/bin/bash
# rolling-update.sh

NODES=("mana-1" "mana-2" "mana-3")
NEW_VERSION="$1"

for node in "${NODES[@]}"; do
    echo "Updating $node to version $NEW_VERSION"
    
    # Drain node
    kubectl drain "$node" --ignore-daemonsets
    
    # Update container image
    kubectl set image statefulset/mana-ethereum \
        mana="mana-ethereum:$NEW_VERSION"
    
    # Wait for rollout
    kubectl rollout status statefulset/mana-ethereum
    
    # Uncordon node
    kubectl uncordon "$node"
    
    # Wait for node to be ready
    sleep 60
done
```

### Health Monitoring

```bash
#!/bin/bash
# health-check.sh

NODES=("http://mana-1:8080" "http://mana-2:8080" "http://mana-3:8080")

for node in "${NODES[@]}"; do
    if ! curl -f "$node/health" > /dev/null 2>&1; then
        echo "CRITICAL: $node is unhealthy"
        # Send alert
        curl -X POST "https://hooks.slack.com/YOUR/WEBHOOK" \
            -d "{\"text\":\"Mana node $node is unhealthy\"}"
    fi
done
```

## Troubleshooting

### Common Issues

#### Node Won't Start

```bash
# Check logs
journalctl -u mana-ethereum -n 100

# Check configuration
/opt/mana/bin/mana eval "Application.get_all_env(:ex_wire)"

# Test database connection
/opt/mana/bin/mana eval "MerklePatriciaTree.test_connection()"
```

#### Sync Issues

```bash
# Check sync status
curl -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
    http://localhost:8545

# Force resync
/opt/mana/bin/mana eval "Blockchain.resync()"
```

#### Performance Issues

```bash
# Check resource usage
htop
iotop
nethogs

# Check Erlang VM stats
/opt/mana/bin/mana eval "erlang:memory()"
/opt/mana/bin/mana eval "erlang:system_info(process_count)"
```

## Security Hardening

### System Security

```bash
# Firewall configuration
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp      # SSH
ufw allow 30303/tcp   # P2P
ufw allow 8545/tcp    # HTTP RPC (restricted)
ufw allow 8546/tcp    # WebSocket RPC (restricted)
ufw enable

# User security
useradd -r -s /bin/false mana
chown -R mana:mana /opt/mana
```

### Application Security

```elixir
# Enable security features
config :ex_wire,
  security: [
    # Rate limiting
    rate_limit_enabled: true,
    max_requests_per_minute: 1000,
    
    # Authentication
    require_auth: true,
    auth_timeout: 3600,
    
    # Network restrictions
    allowed_origins: ["https://yourdapp.com"],
    cors_max_age: 86400
  ]
```

## Next Steps

- [Kubernetes Deployment](kubernetes.md) - Detailed K8s setup
- [Monitoring](monitoring.md) - Complete observability setup
- [Security](security.md) - Advanced security configuration