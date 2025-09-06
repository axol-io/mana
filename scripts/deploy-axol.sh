#!/bin/bash

# Deployment script for axol.io using Ansible
# No docker-compose in production, uses multi-stage Docker build

set -euo pipefail

# Configuration
REGISTRY="${REGISTRY:-registry.axol.io}"
IMAGE_NAME="${IMAGE_NAME:-mana-ethereum}"
ENVIRONMENT="${1:-staging}"
VERSION="${2:-$(git describe --tags --always)}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check for required tools
    for tool in docker ansible kubectl; do
        if ! command -v $tool &> /dev/null; then
            log_error "$tool is not installed"
            exit 1
        fi
    done
    
    # Check Orbstack for local development
    if [[ "$ENVIRONMENT" == "development" ]]; then
        if ! command -v orb &> /dev/null; then
            log_warn "Orbstack CLI (orb) not found. Install from https://orbstack.dev"
        fi
    fi
    
    log_info "Prerequisites check passed"
}

# Build Docker image using multi-stage Dockerfile
build_image() {
    log_info "Building Docker image..."
    
    # Use BuildKit for better caching
    export DOCKER_BUILDKIT=1
    
    # Build the image
    docker build \
        --file Dockerfile.multistage \
        --target runtime \
        --tag "${REGISTRY}/${IMAGE_NAME}:${VERSION}" \
        --tag "${REGISTRY}/${IMAGE_NAME}:${ENVIRONMENT}" \
        --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --build-arg VERSION="${VERSION}" \
        --build-arg VCS_REF="$(git rev-parse HEAD)" \
        --cache-from "${REGISTRY}/${IMAGE_NAME}:${ENVIRONMENT}" \
        --platform linux/amd64 \
        .
    
    log_info "Image built successfully: ${REGISTRY}/${IMAGE_NAME}:${VERSION}"
}

# Push image to registry
push_image() {
    log_info "Pushing image to registry..."
    
    # Login to registry if credentials are provided
    if [[ -n "${REGISTRY_USERNAME:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
        echo "${REGISTRY_PASSWORD}" | docker login "${REGISTRY}" -u "${REGISTRY_USERNAME}" --password-stdin
    fi
    
    docker push "${REGISTRY}/${IMAGE_NAME}:${VERSION}"
    docker push "${REGISTRY}/${IMAGE_NAME}:${ENVIRONMENT}"
    
    log_info "Image pushed successfully"
}

# Deploy using Ansible
deploy_with_ansible() {
    log_info "Deploying to ${ENVIRONMENT} using Ansible..."
    
    cd ansible
    
    # Set environment variables for Ansible
    export IMAGE_TAG="${VERSION}"
    export ANSIBLE_HOST_KEY_CHECKING=False
    
    # Run Ansible playbook
    ansible-playbook \
        -i inventory.yml \
        -l "${ENVIRONMENT}" \
        --extra-vars "image_tag=${VERSION}" \
        playbook.yml
    
    cd ..
    
    log_info "Deployment completed successfully"
}

# Local development with Orbstack and k9s
deploy_local_orbstack() {
    log_info "Deploying to local Orbstack cluster..."
    
    # Check if Orbstack Kubernetes is enabled
    if ! kubectl config get-contexts | grep -q orbstack; then
        log_error "Orbstack Kubernetes context not found. Enable Kubernetes in Orbstack."
        exit 1
    fi
    
    # Switch to Orbstack context
    kubectl config use-context orbstack
    
    # Create namespace
    kubectl create namespace mana-ethereum --dry-run=client -o yaml | kubectl apply -f -
    
    # Apply development configuration
    kubectl apply -f k8s/development/orbstack-values.yaml
    
    # Deploy using kustomize
    kubectl apply -k k8s/overlays/development/
    
    # Wait for deployment
    kubectl rollout status statefulset/mana-ethereum -n mana-ethereum
    
    log_info "Local deployment ready. Use 'k9s' to manage."
    log_info "RPC endpoint: http://mana.orb.local:8545"
    log_info "Metrics: http://mana.orb.local:9568/metrics"
}

# Verify deployment
verify_deployment() {
    log_info "Verifying deployment..."
    
    if [[ "$ENVIRONMENT" == "development" ]]; then
        ENDPOINT="http://mana.orb.local:8545"
    else
        # Get endpoint from Kubernetes
        NAMESPACE="mana-ethereum-${ENVIRONMENT}"
        ENDPOINT=$(kubectl get svc mana-ethereum-rpc -n "${NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8545
    fi
    
    # Test RPC endpoint
    RESPONSE=$(curl -s -X POST "${ENDPOINT}" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"web3_clientVersion","params":[],"id":1}' || echo "")
    
    if echo "$RESPONSE" | jq -e '.result' > /dev/null 2>&1; then
        CLIENT_VERSION=$(echo "$RESPONSE" | jq -r '.result')
        log_info "Deployment verified. Client version: ${CLIENT_VERSION}"
    else
        log_error "Failed to verify deployment. RPC endpoint not responding."
        exit 1
    fi
}

# Main execution
main() {
    log_info "Starting deployment process for ${ENVIRONMENT} environment"
    
    check_prerequisites
    
    case "$ENVIRONMENT" in
        development)
            build_image
            deploy_local_orbstack
            ;;
        staging|production)
            build_image
            push_image
            deploy_with_ansible
            ;;
        *)
            log_error "Invalid environment: $ENVIRONMENT"
            echo "Usage: $0 [development|staging|production] [version]"
            exit 1
            ;;
    esac
    
    verify_deployment
    
    log_info "Deployment completed successfully! 🚀"
}

# Run main function
main "$@"