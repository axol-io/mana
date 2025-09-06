# Kubernetes Deployment for Mana Ethereum

## Development with Orbstack & k9s

For local development at axol.io, we use **Orbstack** for Kubernetes and **k9s** for cluster management.

### Quick Start with Orbstack

1. **Install Orbstack**: https://orbstack.dev/download
2. **Enable Kubernetes**: Orbstack Settings → Kubernetes → Enable
3. **Install k9s**: `brew install k9s`

### Deploy to Local Orbstack

```bash
# Deploy to local Orbstack cluster
./scripts/deploy-axol.sh development

# Access with k9s
k9s -n mana-ethereum

# Local endpoints (automatically configured by Orbstack)
# RPC: http://mana.orb.local:8545
# WebSocket: ws://mana.orb.local:8546
# Metrics: http://mana.orb.local:9568/metrics
```

### Orbstack Features

- **Automatic DNS**: Services get `*.orb.local` domains
- **Low resource usage**: More efficient than Docker Desktop
- **Fast volume mounts**: Native filesystem performance
- **Built-in LoadBalancer**: Works out of the box

## Production Deployment with Ansible

We use **Ansible** for production deployments at axol.io (no docker-compose).

### Prerequisites

1. **Install Ansible**: `pip install ansible kubernetes`
2. **Configure inventory**: Edit `ansible/inventory.yml`
3. **Set up registry access**: Configure credentials for registry.axol.io

### Deploy to Production

```bash
# Deploy to staging
./scripts/deploy-axol.sh staging v1.0.0

# Deploy to production
./scripts/deploy-axol.sh production v1.0.0

# Or use Ansible directly
cd ansible
ansible-playbook -i inventory.yml -l production playbook.yml
```

## Multi-stage Docker Build

We use a multi-stage Dockerfile for optimal image size and security:

```bash
# Build production image
docker build -f Dockerfile.multistage --target runtime -t mana-ethereum:latest .

# Build development image (includes debugging tools)
docker build -f Dockerfile.multistage --target development -t mana-ethereum:dev .

# Image stages:
# 1. rust-builder: Builds Rust NIFs
# 2. deps: Fetches Elixir dependencies
# 3. builder: Compiles application
# 4. runtime: Minimal production image (~200MB)
# 5. development: Includes dev tools for debugging
```

## Directory Structure

```
k8s/
├── base/                    # Base Kubernetes manifests
│   ├── deployment-fixed.yaml  # Corrected StatefulSet
│   ├── service.yaml
│   ├── configmap.yaml
│   ├── secrets.yaml
│   └── kustomization.yaml
├── overlays/
│   ├── development/         # Local development with Orbstack
│   ├── staging/            # Staging environment
│   └── production/         # Production environment
└── development/
    └── orbstack-values.yaml # Orbstack-specific config
```

## k9s Commands Reference

When using k9s for cluster management:

| Key | Action |
|-----|--------|
| `:` | Command mode |
| `/` | Search |
| `?` | Help |
| `0-9` | Navigate to section |
| `l` | View logs |
| `d` | Describe resource |
| `e` | Edit resource |
| `s` | Shell into pod |
| `ctrl-k` | Kill pod |
| `y` | View YAML |

### Useful k9s Commands

```
:pods                 # View all pods
:svc                  # View services
:pvc                  # View persistent volumes
:events               # View cluster events
:xray deploy/mana     # X-ray deployment
:pulse                # Cluster health
```

## No Docker Compose in Production

As requested, we **don't use docker-compose in production**. Instead:

- **Local Development**: Orbstack Kubernetes + k9s
- **CI/CD**: GitHub Actions builds and pushes images
- **Production**: Ansible deploys to Kubernetes

The monitoring stack can be deployed separately in Kubernetes:

```bash
# Deploy Prometheus/Grafana to Kubernetes (not docker-compose)
kubectl apply -f monitoring/k8s-monitoring-stack.yaml
```

## Ansible Deployment Features

Our Ansible playbook provides:

- **Automated secret generation**: Secure random values
- **Rolling updates**: Zero-downtime deployments
- **Health checks**: Verifies deployment success
- **Multi-environment**: Staging and production configs
- **Idempotent**: Safe to run multiple times

## Environment Variables

Configure via Ansible variables or Kubernetes ConfigMaps:

```yaml
# ansible/group_vars/production.yml
network_id: 1          # Mainnet
chain: mainnet
sync_mode: full
cluster_size: 5
storage_size: 2Ti
```

## Troubleshooting

### Orbstack Issues

```bash
# Reset Orbstack Kubernetes
orb kubernetes reset

# Check Orbstack status
orb status

# View Orbstack logs
orb logs
```

### k9s Tips

```bash
# Connect to specific context
k9s --context orbstack

# Start in specific namespace
k9s -n mana-ethereum

# Read-only mode
k9s --readonly
```

### Ansible Debugging

```bash
# Dry run
ansible-playbook playbook.yml --check

# Verbose output
ansible-playbook playbook.yml -vvv

# Run specific tags
ansible-playbook playbook.yml --tags deploy
```

## Security Notes

1. **No root containers**: All containers run as non-root user (UID 1000)
2. **Read-only root filesystem**: Where possible
3. **Security contexts**: Proper capabilities and restrictions
4. **Network policies**: Restrict inter-pod communication
5. **Secrets management**: Use Ansible Vault or external secret managers

## Support

For deployment issues:
- Local development: Check Orbstack logs and k9s
- Production: Review Ansible playbook output
- Container issues: Check multi-stage build logs

---

**Note**: This setup is optimized for axol.io's infrastructure using Orbstack for development and Ansible for production, without docker-compose.