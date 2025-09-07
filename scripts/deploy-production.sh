#!/bin/bash

# Mana-Ethereum Production Deployment Script
# Optimized for multi-datacenter deployment with zero-downtime

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOYMENT_ENV="${DEPLOYMENT_ENV:-production}"
REGION="${REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-mana-ethereum-cluster}"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-ghcr.io/mana-ethereum}"
VERSION="${VERSION:-$(git rev-parse --short HEAD)}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Pre-deployment checks
check_requirements() {
    log_step "Checking deployment requirements..."
    
    # Check required tools
    for cmd in docker kubectl helm jq; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required tool $cmd is not installed"
            exit 1
        fi
    done
    
    # Check environment variables
    if [[ -z "${DOCKER_REGISTRY:-}" ]]; then
        log_error "DOCKER_REGISTRY environment variable is required"
        exit 1
    fi
    
    # Check Git status
    if [[ -n "$(git status --porcelain)" ]]; then
        log_warn "Working directory has uncommitted changes"
        read -p "Continue anyway? (y/N): " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    log_info "All requirements satisfied"
}

# Build and push Docker images
build_and_push() {
    log_step "Building Docker images..."
    
    cd "$PROJECT_DIR"
    
    # Build main application image
    docker build -f Dockerfile \
        --target production \
        -t "${DOCKER_REGISTRY}/mana-ethereum:${VERSION}" \
        -t "${DOCKER_REGISTRY}/mana-ethereum:latest" \
        .
    
    # Build monitoring image
    docker build -f monitoring/Dockerfile \
        -t "${DOCKER_REGISTRY}/mana-monitoring:${VERSION}" \
        -t "${DOCKER_REGISTRY}/mana-monitoring:latest" \
        ./monitoring
    
    log_info "Images built successfully"
    
    # Push images
    log_step "Pushing images to registry..."
    docker push "${DOCKER_REGISTRY}/mana-ethereum:${VERSION}"
    docker push "${DOCKER_REGISTRY}/mana-ethereum:latest"
    docker push "${DOCKER_REGISTRY}/mana-monitoring:${VERSION}"
    docker push "${DOCKER_REGISTRY}/mana-monitoring:latest"
    
    log_info "Images pushed successfully"
}

# Deploy AntidoteDB cluster
deploy_antidotedb() {
    log_step "Deploying AntidoteDB cluster..."
    
    helm repo add antidote https://charts.antidotedb.eu || true
    helm repo update
    
    helm upgrade --install antidote-cluster antidote/antidotedb \
        --namespace mana-storage \
        --create-namespace \
        --values k8s/antidotedb-values.yaml \
        --wait \
        --timeout=10m
    
    log_info "AntidoteDB cluster deployed"
}

# Deploy main application
deploy_application() {
    log_step "Deploying Mana-Ethereum application..."
    
    # Create namespace if it doesn't exist
    kubectl create namespace mana-ethereum --dry-run=client -o yaml | kubectl apply -f -
    
    # Update deployment with new image
    helm upgrade --install mana-ethereum k8s/helm-chart \
        --namespace mana-ethereum \
        --set image.repository="${DOCKER_REGISTRY}/mana-ethereum" \
        --set image.tag="${VERSION}" \
        --set deployment.environment="${DEPLOYMENT_ENV}" \
        --set deployment.region="${REGION}" \
        --values k8s/values-${DEPLOYMENT_ENV}.yaml \
        --wait \
        --timeout=15m
    
    log_info "Application deployed successfully"
}

# Deploy monitoring stack
deploy_monitoring() {
    log_step "Deploying monitoring stack..."
    
    # Create monitoring namespace
    kubectl create namespace mana-monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # Deploy Prometheus operator
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
    helm repo update
    
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace mana-monitoring \
        --values k8s/monitoring-values.yaml \
        --wait \
        --timeout=10m
    
    # Deploy custom Grafana dashboards
    kubectl apply -f k8s/monitoring/ -n mana-monitoring
    
    log_info "Monitoring stack deployed"
}

# Health checks
health_check() {
    log_step "Performing health checks..."
    
    # Wait for pods to be ready
    kubectl wait --for=condition=ready pod -l app=mana-ethereum -n mana-ethereum --timeout=300s
    
    # Check application health endpoint
    HEALTH_URL=$(kubectl get svc mana-ethereum -n mana-ethereum -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8545/health
    
    for i in {1..30}; do
        if curl -f -s "http://${HEALTH_URL}" > /dev/null; then
            log_info "Health check passed"
            break
        fi
        
        if [ $i -eq 30 ]; then
            log_error "Health check failed after 30 attempts"
            exit 1
        fi
        
        log_warn "Health check attempt $i/30 failed, retrying in 10s..."
        sleep 10
    done
}

# Performance validation
validate_performance() {
    log_step "Validating performance benchmarks..."
    
    # Run performance tests against the deployed application
    kubectl run performance-test \
        --image="${DOCKER_REGISTRY}/mana-ethereum:${VERSION}" \
        --rm -i --restart=Never \
        --namespace=mana-ethereum \
        -- mix run -e "
            # Run verkle benchmarks
            Mix.Task.run('benchmark.verkle')
            
            # Validate 7.45M ops/sec capability
            results = ExWire.Layer2.PerformanceBenchmark.run_full_benchmark()
            
            if results.ops_per_second < 7_000_000 do
              IO.puts('Performance validation FAILED')
              System.halt(1)
            else
              IO.puts('Performance validation PASSED: #{results.ops_per_second} ops/sec')
            end
        "
    
    log_info "Performance validation completed"
}

# Rollback function
rollback() {
    log_error "Deployment failed, initiating rollback..."
    
    helm rollback mana-ethereum -n mana-ethereum
    
    log_info "Rollback completed"
    exit 1
}

# Main deployment function
main() {
    log_info "Starting Mana-Ethereum production deployment..."
    log_info "Version: ${VERSION}"
    log_info "Environment: ${DEPLOYMENT_ENV}"
    log_info "Region: ${REGION}"
    
    # Set up error handling
    trap rollback ERR
    
    # Execute deployment steps
    check_requirements
    build_and_push
    deploy_antidotedb
    deploy_application
    deploy_monitoring
    health_check
    validate_performance
    
    log_info "🎉 Deployment completed successfully!"
    log_info "Application is available at: $(kubectl get svc mana-ethereum -n mana-ethereum -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8545"
    log_info "Monitoring available at: $(kubectl get svc prometheus-grafana -n mana-monitoring -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):3000"
}

# Command line argument handling
case "${1:-deploy}" in
    deploy)
        main
        ;;
    check)
        check_requirements
        ;;
    build)
        build_and_push
        ;;
    health)
        health_check
        ;;
    rollback)
        rollback
        ;;
    *)
        echo "Usage: $0 {deploy|check|build|health|rollback}"
        exit 1
        ;;
esac