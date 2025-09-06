#!/bin/bash

# Mana Staging Environment Deployment Script
# Deploys ultra-performance Mana to staging with full monitoring

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
DEPLOYMENT_DIR="$PROJECT_ROOT/deployment/staging"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

check_prerequisites() {
    log "Checking deployment prerequisites..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        error "Docker not found. Please install Docker."
        exit 1
    fi
    
    # Check Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        error "Docker Compose not found. Please install Docker Compose."
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        error "Docker daemon not running. Please start Docker."
        exit 1
    fi
    
    # Check available resources
    TOTAL_RAM=$(free -m | awk 'NR==2{printf "%.0f", $2}')
    if [ "$TOTAL_RAM" -lt 16384 ]; then
        warn "Less than 16GB RAM detected. Staging may not perform optimally."
    fi
    
    success "Prerequisites check passed"
}

prepare_deployment() {
    log "Preparing staging deployment..."
    
    cd "$DEPLOYMENT_DIR"
    
    # Create necessary directories
    mkdir -p config monitoring/grafana/{provisioning,dashboards} nginx/ssl logs
    
    # Create staging configuration
    cat > config/staging.config << 'EOF'
# Mana Staging Configuration
export MIX_ENV=prod
export NODE_ENV=staging
export MANA_ULTRA_PERFORMANCE=true
export VERKLE_SIMD_ENABLED=true
export EVM_SIMD_ENABLED=true
export LIBP2P_MESH_OPTIMIZATION=true
export HSM_ULTRA_OPTIMIZATION=false
export ENABLE_TELEMETRY=true
export PROMETHEUS_ENABLED=true
export LOG_LEVEL=info
export DATACENTER_ID=staging-dc1
export REGION=us-west-2
export MAX_PEER_CONNECTIONS=1000
export NETWORK_BUFFER_SIZE=524288
EOF
    
    # Create nginx configuration
    cat > nginx/nginx.conf << 'EOF'
events {
    worker_connections 1024;
}

http {
    upstream mana_jsonrpc {
        server mana-node:8545;
    }
    
    upstream mana_websocket {
        server mana-node:8546;
    }
    
    server {
        listen 80;
        server_name staging.mana.local;
        
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }
        
        location / {
            proxy_pass http://mana_jsonrpc;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_connect_timeout 10s;
            proxy_send_timeout 30s;
            proxy_read_timeout 30s;
        }
        
        location /ws {
            proxy_pass http://mana_websocket;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
    }
    
    server {
        listen 80;
        server_name monitoring.staging.mana.local;
        
        location / {
            proxy_pass http://grafana:3000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
        
        location /prometheus/ {
            proxy_pass http://prometheus:9090/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
        
        location /alertmanager/ {
            proxy_pass http://alertmanager:9093/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
EOF
    
    success "Deployment preparation completed"
}

build_images() {
    log "Building Mana Docker images..."
    
    cd "$PROJECT_ROOT"
    
    # Build the main application image
    docker build \
        -f deployment/Dockerfile \
        -t mana:staging-ultra \
        --build-arg BUILD_ENV=staging \
        --build-arg ULTRA_PERFORMANCE=true \
        .
    
    success "Docker images built successfully"
}

deploy_infrastructure() {
    log "Deploying infrastructure components..."
    
    cd "$DEPLOYMENT_DIR"
    
    # Stop any existing deployment
    docker-compose down -v --remove-orphans || true
    
    # Start infrastructure services first
    docker-compose up -d antidote prometheus grafana alertmanager
    
    # Wait for infrastructure to be ready
    log "Waiting for infrastructure services..."
    sleep 30
    
    # Verify infrastructure health
    local retries=10
    while [ $retries -gt 0 ]; do
        if docker-compose exec -T antidote curl -f http://localhost:8087/metrics > /dev/null 2>&1 && \
           docker-compose exec -T prometheus curl -f http://localhost:9090/-/healthy > /dev/null 2>&1; then
            success "Infrastructure services ready"
            break
        fi
        log "Waiting for infrastructure services to be ready... ($retries retries left)"
        sleep 10
        ((retries--))
    done
    
    if [ $retries -eq 0 ]; then
        error "Infrastructure services failed to start"
        return 1
    fi
}

deploy_application() {
    log "Deploying Mana application..."
    
    cd "$DEPLOYMENT_DIR"
    
    # Start the main application
    docker-compose up -d mana-node nginx
    
    # Wait for application to be ready
    log "Waiting for Mana node to start..."
    local retries=20
    while [ $retries -gt 0 ]; do
        if curl -f http://localhost/health > /dev/null 2>&1; then
            success "Mana application is ready"
            break
        fi
        log "Waiting for Mana application... ($retries retries left)"
        sleep 15
        ((retries--))
    done
    
    if [ $retries -eq 0 ]; then
        error "Mana application failed to start"
        return 1
    fi
}

run_deployment_tests() {
    log "Running deployment validation tests..."
    
    # Test JSON-RPC endpoint
    local rpc_response
    if rpc_response=$(curl -s -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"web3_clientVersion","params":[],"id":1}' \
        http://localhost/); then
        if echo "$rpc_response" | jq -e '.result' > /dev/null; then
            success "JSON-RPC endpoint test passed"
        else
            error "JSON-RPC endpoint test failed: invalid response"
            return 1
        fi
    else
        error "JSON-RPC endpoint test failed: connection error"
        return 1
    fi
    
    # Test metrics endpoint
    if curl -f http://localhost:9091/metrics > /dev/null 2>&1; then
        success "Metrics endpoint test passed"
    else
        error "Metrics endpoint test failed"
        return 1
    fi
    
    # Test Grafana
    if curl -f http://localhost:3001/api/health > /dev/null 2>&1; then
        success "Grafana health check passed"
    else
        warn "Grafana health check failed (may still be starting)"
    fi
    
    success "Deployment validation completed"
}

show_deployment_status() {
    log "Deployment Status Summary"
    echo "========================"
    
    # Service status
    cd "$DEPLOYMENT_DIR"
    echo "Service Status:"
    docker-compose ps
    echo
    
    # Access URLs
    echo "Access URLs:"
    echo "  JSON-RPC Endpoint: http://localhost/"
    echo "  WebSocket Endpoint: ws://localhost/ws"
    echo "  Grafana Dashboard: http://localhost:3001 (admin/staging123)"
    echo "  Prometheus: http://localhost:9091"
    echo "  Alertmanager: http://localhost:9094"
    echo
    
    # Performance metrics
    echo "Ultra-Performance Features:"
    echo "  ✅ SIMD Vectorization (Verkle, EVM)"
    echo "  ✅ Network Mesh Optimization"
    echo "  ✅ Advanced Caching"
    echo "  ✅ Performance Monitoring"
    echo "  ✅ Auto-scaling Ready"
    echo
    
    # Logs
    echo "View logs:"
    echo "  docker-compose -f $DEPLOYMENT_DIR/docker-compose.yml logs -f mana-node"
    echo
    
    echo "Staging deployment completed successfully!"
}

cleanup_on_failure() {
    error "Deployment failed. Cleaning up..."
    cd "$DEPLOYMENT_DIR"
    docker-compose down -v --remove-orphans || true
    exit 1
}

main() {
    log "Starting Mana Staging Deployment"
    
    # Set trap for cleanup on failure
    trap cleanup_on_failure ERR
    
    check_prerequisites
    prepare_deployment
    build_images
    deploy_infrastructure
    deploy_application
    run_deployment_tests
    show_deployment_status
    
    success "Mana staging deployment completed successfully!"
}

main "$@"