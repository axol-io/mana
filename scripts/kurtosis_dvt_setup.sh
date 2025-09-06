#!/bin/bash

# Kurtosis DVT Local Testing Setup
# Creates a local Ethereum network for DVT testing using Kurtosis

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
KURTOSIS_PACKAGE="${KURTOSIS_PACKAGE:-github.com/ethpandaops/ethereum-package}"
NETWORK_PARAMS="${NETWORK_PARAMS:-$PROJECT_ROOT/scripts/kurtosis-network-params.yaml}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m' 
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check Kurtosis installation
check_kurtosis() {
    log_info "Checking Kurtosis installation..."
    
    if ! command -v kurtosis &> /dev/null; then
        log_error "Kurtosis not found. Please install from https://docs.kurtosis.com/install"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker not running. Please start Docker daemon"
        exit 1
    fi
    
    log_success "Kurtosis and Docker ready"
}

# Create network parameters for DVT testing
create_network_params() {
    log_info "Creating Kurtosis network parameters for DVT testing..."
    
    cat > "$NETWORK_PARAMS" << 'EOF'
# Kurtosis Ethereum Network Parameters for DVT Testing
participants:
  # Execution Layer Clients
  - el_client_type: geth
    el_client_image: ethereum/client-go:latest
    el_extra_params: []
    
  - el_client_type: nethermind
    el_client_image: nethermind/nethermind:latest
    el_extra_params: []
    
  # Consensus Layer Clients  
  - cl_client_type: lighthouse
    cl_client_image: sigp/lighthouse:latest
    cl_extra_params: []
    
  - cl_client_type: prysm
    cl_client_image: prysmaticlabs/prysm-beacon-chain:latest
    cl_extra_params: []

# Network Configuration
network_params:
  # Fast block times for testing
  seconds_per_slot: 4
  slots_per_epoch: 8
  
  # DVT-friendly validator set
  num_validator_keys_per_node: 32
  validators_per_node: 32
  
  # Enable all ETH2 features
  altair_fork_epoch: 0
  bellatrix_fork_epoch: 0
  capella_fork_epoch: 1
  deneb_fork_epoch: 2
  
  # Network timing
  genesis_delay: 20
  
# Additional services for DVT testing
additional_services:
  # Prometheus for metrics
  - prometheus_additional_config: |
      global:
        scrape_interval: 5s
      scrape_configs:
        - job_name: 'dvt-nodes'
          static_configs:
            - targets: ['host.docker.internal:9090']
              
  # Grafana for visualization  
  - grafana_additional_dashboards:
      - name: "DVT Dashboard"
        dashboard: |
          {
            "dashboard": {
              "title": "DVT Cluster Monitoring",
              "panels": [
                {
                  "title": "Consensus Latency",
                  "type": "graph",
                  "targets": [
                    {
                      "expr": "dvt_consensus_latency_seconds",
                      "legendFormat": "{{cluster_id}}"
                    }
                  ]
                },
                {
                  "title": "Message Throughput", 
                  "type": "graph",
                  "targets": [
                    {
                      "expr": "rate(dvt_messages_total[5m])",
                      "legendFormat": "{{message_type}}"
                    }
                  ]
                }
              ]
            }
          }

# Mev-boost configuration for testing
mev_type: "mock"
EOF

    log_success "Network parameters created: $NETWORK_PARAMS"
}

# Start Kurtosis network
start_network() {
    log_info "Starting Kurtosis Ethereum network..."
    
    # Clean any existing enclaves
    kurtosis enclave rm -f dvt-testnet 2>/dev/null || true
    
    # Start the network
    kurtosis run --enclave-name dvt-testnet "$KURTOSIS_PACKAGE" \
        --args-file "$NETWORK_PARAMS"
    
    log_success "Kurtosis network started"
    
    # Get network information
    log_info "Network Information:"
    kurtosis enclave inspect dvt-testnet
}

# Get network endpoints
get_endpoints() {
    log_info "Getting network endpoints..."
    
    # Get beacon and execution endpoints
    local beacon_endpoints
    local execution_endpoints
    
    beacon_endpoints=$(kurtosis service logs dvt-testnet lighthouse-geth-0-cl-0-beacon 2>/dev/null | grep -o "http://.*:4000" | head -1 || echo "http://localhost:4000")
    execution_endpoints=$(kurtosis service logs dvt-testnet lighthouse-geth-0-el-0-geth 2>/dev/null | grep -o "http://.*:8545" | head -1 || echo "http://localhost:8545")
    
    cat > "$PROJECT_ROOT/testnet/kurtosis-endpoints.json" << EOF
{
  "network": "kurtosis",
  "beacon_endpoints": [
    "$beacon_endpoints",
    "http://localhost:4001"
  ],
  "execution_endpoints": [
    "$execution_endpoints", 
    "http://localhost:8546"
  ],
  "explorer": "http://localhost:8080",
  "prometheus": "http://localhost:9090",
  "grafana": "http://localhost:3000"
}
EOF

    log_success "Endpoints saved to testnet/kurtosis-endpoints.json"
    cat "$PROJECT_ROOT/testnet/kurtosis-endpoints.json"
}

# Create DVT validator keys for Kurtosis
create_dvt_validators() {
    log_info "Creating DVT validators on Kurtosis network..."
    
    # Create a simple validator creation script
    cat > "$PROJECT_ROOT/scripts/create_kurtosis_validators.py" << 'EOF'
#!/usr/bin/env python3

import requests
import json
import time
from eth_account import Account
from eth_utils import to_checksum_address

# Kurtosis network configuration
EXECUTION_URL = "http://localhost:8545"
BEACON_URL = "http://localhost:4000"

def create_validator_keys(count=5):
    """Create validator keys for DVT testing"""
    validators = []
    
    for i in range(count):
        # Generate validator keypair
        private_key = Account.create().key.hex()
        account = Account.from_key(private_key)
        
        validator = {
            "index": i + 1,
            "private_key": private_key,
            "public_key": account.address,
            "withdrawal_credentials": f"0x01{'0' * 22}{account.address[2:]}",
        }
        validators.append(validator)
        
    return validators

def submit_deposit(validator_data):
    """Submit validator deposit to local network"""
    # This would normally interact with the deposit contract
    # For Kurtosis testing, we'll use the pre-funded validators
    print(f"Validator {validator_data['index']} ready for DVT cluster")
    return True

if __name__ == "__main__":
    print("Creating DVT validators for Kurtosis network...")
    
    validators = create_validator_keys(5)
    
    # Save validator data
    with open("../testnet/kurtosis-validators.json", "w") as f:
        json.dump(validators, f, indent=2)
        
    print(f"Created {len(validators)} validators for DVT testing")
    print("Validator data saved to testnet/kurtosis-validators.json")
EOF

    # Run validator creation
    python3 "$PROJECT_ROOT/scripts/create_kurtosis_validators.py"
    
    log_success "DVT validators created for Kurtosis network"
}

# Setup DVT cluster on Kurtosis
setup_dvt_cluster() {
    log_info "Setting up DVT cluster on Kurtosis network..."
    
    # Deploy DVT with Kurtosis-specific configuration
    cd "$PROJECT_ROOT"
    
    # Use Kurtosis network configuration
    ./scripts/deploy_dvt_testnet.sh deploy \
        --network kurtosis \
        --cluster-size 5 \
        --threshold 3
    
    log_success "DVT cluster deployed on Kurtosis network"
}

# Monitor DVT cluster
monitor_cluster() {
    log_info "Starting DVT cluster monitoring..."
    
    # Open monitoring dashboards
    if command -v open &> /dev/null; then
        # macOS
        open "http://localhost:3000"  # Grafana
        open "http://localhost:9090"  # Prometheus
    elif command -v xdg-open &> /dev/null; then
        # Linux
        xdg-open "http://localhost:3000" &
        xdg-open "http://localhost:9090" &
    fi
    
    # Show cluster status
    ./scripts/deploy_dvt_testnet.sh status
}

# Stop Kurtosis network
stop_network() {
    log_info "Stopping Kurtosis network..."
    
    # Stop DVT cluster first
    ./scripts/deploy_dvt_testnet.sh stop 2>/dev/null || true
    
    # Stop Kurtosis enclave
    kurtosis enclave stop dvt-testnet 2>/dev/null || true
    kurtosis enclave rm dvt-testnet 2>/dev/null || true
    
    log_success "Kurtosis network stopped"
}

# Show help
show_help() {
    cat << EOF
Kurtosis DVT Local Testing Setup

Usage: $0 [COMMAND]

Commands:
  start       Start Kurtosis network with DVT cluster
  stop        Stop Kurtosis network
  status      Show cluster status  
  monitor     Open monitoring dashboards
  endpoints   Show network endpoints
  help        Show this help

Examples:
  $0 start        # Start full DVT testing environment
  $0 monitor      # Open Grafana and Prometheus
  $0 status       # Check DVT cluster health
  $0 stop         # Clean shutdown

EOF
}

# Main execution
case "${1:-help}" in
    start)
        check_kurtosis
        create_network_params
        start_network
        get_endpoints
        create_dvt_validators
        setup_dvt_cluster
        
        log_success "Kurtosis DVT environment ready!"
        log_info "Use '$0 monitor' to open dashboards"
        log_info "Use '$0 status' to check cluster health"
        ;;
        
    stop)
        stop_network
        ;;
        
    status)
        ./scripts/deploy_dvt_testnet.sh status
        ;;
        
    monitor)
        monitor_cluster
        ;;
        
    endpoints)
        if [[ -f "$PROJECT_ROOT/testnet/kurtosis-endpoints.json" ]]; then
            cat "$PROJECT_ROOT/testnet/kurtosis-endpoints.json"
        else
            log_error "Network not started. Run '$0 start' first."
        fi
        ;;
        
    help)
        show_help
        ;;
        
    *)
        log_error "Unknown command: ${1:-}"
        show_help
        exit 1
        ;;
esac