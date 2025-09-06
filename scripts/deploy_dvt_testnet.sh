#!/bin/bash

# DVT Testnet Deployment Script
# Deploys a complete DVT validator cluster to Holesky testnet

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DEPLOYMENT_ENV="${DEPLOYMENT_ENV:-testnet}"
CLUSTER_SIZE="${CLUSTER_SIZE:-5}"
THRESHOLD="${THRESHOLD:-3}"
NETWORK="${NETWORK:-hoodi}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check dependencies
check_dependencies() {
    log_info "Checking deployment dependencies..."
    
    local deps=("docker" "docker-compose" "mix" "elixir" "openssl")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_error "Please install missing dependencies and retry."
        exit 1
    fi
    
    log_success "All dependencies present"
}

# Generate validator keys for DVT cluster
generate_validator_keys() {
    log_info "Generating DVT validator keys..."
    
    local keys_dir="$PROJECT_ROOT/testnet/keys"
    mkdir -p "$keys_dir"
    
    # Generate threshold BLS keys using staking-deposit-cli equivalent
    cd "$keys_dir"
    
    log_info "Generating validator withdrawal credentials..."
    
    # Use Elixir to generate proper BLS keys
    mix run -e "
    alias ExWire.DVT.KeyManager
    
    # Generate validator key
    validator_key = :crypto.strong_rand_bytes(32)
    withdrawal_key = :crypto.strong_rand_bytes(32)
    
    # Create DVT cluster configuration
    cluster_config = %{
      cluster_id: \"testnet_cluster_001\",
      validator_pubkey: Base.encode16(validator_key),
      threshold: $THRESHOLD,
      total_nodes: $CLUSTER_SIZE,
      network: :$NETWORK
    }
    
    # Generate threshold key shares
    {:ok, key_shares} = KeyManager.generate_threshold_keys(
      cluster_config.cluster_id,
      validator_key,
      cluster_config.threshold,
      cluster_config.total_nodes
    )
    
    # Save configuration
    config_json = Jason.encode!(cluster_config, pretty: true)
    File.write!(\"cluster_config.json\", config_json)
    
    # Save key shares
    Enum.with_index(key_shares, 1)
    |> Enum.each(fn {share, index} ->
      share_data = %{
        node_id: index,
        key_share: Base.encode64(share.private_share),
        public_key: Base.encode64(share.public_key),
        verification_vector: Enum.map(share.verification_vector, &Base.encode64/1)
      }
      
      share_json = Jason.encode!(share_data, pretty: true)
      File.write!(\"node_#{index}_keyshare.json\", share_json)
    end)
    
    IO.puts(\"DVT keys generated successfully\")
    "
    
    log_success "DVT validator keys generated in $keys_dir"
}

# Setup AntidoteDB cluster for distributed state
setup_antidote_cluster() {
    log_info "Setting up AntidoteDB cluster for DVT state..."
    
    local antidote_dir="$PROJECT_ROOT/testnet/antidote"
    mkdir -p "$antidote_dir"
    
    # Create docker-compose for AntidoteDB cluster
    cat > "$antidote_dir/docker-compose.yml" << 'EOF'
version: '3.8'

services:
  antidote-1:
    image: antidotedb/antidote:latest
    hostname: antidote-1
    ports:
      - "8087:8087"
      - "8085:8085"
    environment:
      - NODE_NAME=antidote@antidote-1
      - SHORT_NAME_BOOL=true
    volumes:
      - antidote-1-data:/opt/antidote/data
    networks:
      - dvt-network
    restart: unless-stopped

  antidote-2:
    image: antidotedb/antidote:latest
    hostname: antidote-2
    ports:
      - "8088:8087"
      - "8086:8085"
    environment:
      - NODE_NAME=antidote@antidote-2
      - SHORT_NAME_BOOL=true
    volumes:
      - antidote-2-data:/opt/antidote/data
    networks:
      - dvt-network
    restart: unless-stopped
    depends_on:
      - antidote-1

  antidote-3:
    image: antidotedb/antidote:latest
    hostname: antidote-3
    ports:
      - "8089:8087"
      - "8087:8085"
    environment:
      - NODE_NAME=antidote@antidote-3
      - SHORT_NAME_BOOL=true
    volumes:
      - antidote-3-data:/opt/antidote/data
    networks:
      - dvt-network
    restart: unless-stopped
    depends_on:
      - antidote-1

volumes:
  antidote-1-data:
  antidote-2-data:
  antidote-3-data:

networks:
  dvt-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
EOF

    # Start AntidoteDB cluster
    cd "$antidote_dir"
    docker-compose up -d
    
    # Wait for cluster to be ready
    log_info "Waiting for AntidoteDB cluster to be ready..."
    sleep 30
    
    # Form the cluster
    docker exec antidote-antidote-1-1 /opt/antidote/bin/env connect_dcs '['"'"'antidote@antidote-2'"'"', '"'"'antidote@antidote-3'"'"']'
    
    log_success "AntidoteDB cluster ready"
}

# Deploy DVT nodes
deploy_dvt_nodes() {
    log_info "Deploying DVT validator nodes..."
    
    local nodes_dir="$PROJECT_ROOT/testnet/nodes"
    mkdir -p "$nodes_dir"
    
    # Create deployment configuration for each node
    for ((i=1; i<=CLUSTER_SIZE; i++)); do
        local node_dir="$nodes_dir/node-$i"
        mkdir -p "$node_dir"
        
        # Create node-specific configuration
        cat > "$node_dir/runtime.exs" << EOF
import Config

# Load base testnet configuration
import_config "../../../config/dvt_testnet.exs"

# Node-specific overrides
config :ex_wire, :dvt,
  node_id: $i,
  
  # Load key share for this node
  key_share_path: Path.join([__DIR__, "..", "..", "keys", "node_${i}_keyshare.json"]),
  
  # Node-specific P2P settings
  p2p_config: %{
    listen_port: $((9000 + i - 1)),
    node_key_path: Path.join([__DIR__, "node_key_$i"])
  }

# Node-specific database settings
config :merkle_patricia_tree,
  antidote_config: %{
    hosts: [
      {"localhost", 8087},
      {"localhost", 8088}, 
      {"localhost", 8089}
    ],
    bucket: "dvt_testnet_node_$i"
  }
EOF

        # Generate node-specific P2P key
        openssl rand -hex 32 > "$node_dir/node_key_$i"
        
        # Create systemd service file for this node
        cat > "$node_dir/dvt-node-$i.service" << EOF
[Unit]
Description=DVT Validator Node $i
After=network.target
Wants=network.target

[Service]
Type=exec
User=dvt
Group=dvt
WorkingDirectory=$PROJECT_ROOT
Environment=MIX_ENV=prod
Environment=ELIXIR_ERL_OPTIONS="+K true +A 64 +P 1048576"
ExecStart=$PROJECT_ROOT/_build/prod/rel/mana/bin/mana start
ExecStop=$PROJECT_ROOT/_build/prod/rel/mana/bin/mana stop
KillMode=process
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=dvt-node-$i

[Install]
WantedBy=multi-user.target
EOF

        log_info "Node $i configuration created"
    done
    
    log_success "DVT nodes configured"
}

# Build and prepare release
build_release() {
    log_info "Building DVT release for testnet..."
    
    cd "$PROJECT_ROOT"
    
    # Clean previous builds
    mix clean
    
    # Get dependencies
    MIX_ENV=prod mix deps.get --only prod
    
    # Compile with production optimizations
    MIX_ENV=prod mix compile --force --warnings-as-errors
    
    # Build release
    MIX_ENV=prod mix release --overwrite
    
    log_success "Release built successfully"
}

# Start DVT cluster
start_dvt_cluster() {
    log_info "Starting DVT validator cluster..."
    
    # Load cluster configuration
    local cluster_config="$PROJECT_ROOT/testnet/keys/cluster_config.json"
    if [[ ! -f "$cluster_config" ]]; then
        log_error "Cluster configuration not found: $cluster_config"
        exit 1
    fi
    
    local cluster_id
    cluster_id=$(jq -r '.cluster_id' "$cluster_config")
    
    # Start nodes in sequence
    for ((i=1; i<=CLUSTER_SIZE; i++)); do
        log_info "Starting DVT node $i..."
        
        # Set node-specific environment
        export DVT_NODE_ID="$i"
        export DVT_CLUSTER_ID="$cluster_id"
        export DVT_CONFIG_PATH="$PROJECT_ROOT/testnet/nodes/node-$i/runtime.exs"
        
        # Start node in background
        cd "$PROJECT_ROOT"
        MIX_ENV=prod RELEASE_CONFIG_PATH="$DVT_CONFIG_PATH" \
            _build/prod/rel/mana/bin/mana daemon_iex &
        
        local node_pid=$!
        echo "$node_pid" > "$PROJECT_ROOT/testnet/nodes/node-$i/node.pid"
        
        # Wait a bit between node starts
        sleep 5
        
        log_success "DVT node $i started (PID: $node_pid)"
    done
    
    # Wait for cluster formation
    log_info "Waiting for DVT cluster formation..."
    sleep 30
    
    # Verify cluster status
    verify_cluster_health
}

# Verify cluster health
verify_cluster_health() {
    log_info "Verifying DVT cluster health..."
    
    # Check cluster status via API
    local api_response
    api_response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"dvt_getClusterStatus","params":[],"id":1}' \
        http://localhost:8545 || echo "")
    
    if [[ -z "$api_response" ]]; then
        log_warn "Could not connect to DVT API - nodes may still be starting"
        return
    fi
    
    local cluster_status
    cluster_status=$(echo "$api_response" | jq -r '.result.status' 2>/dev/null || echo "unknown")
    
    if [[ "$cluster_status" == "healthy" ]]; then
        log_success "DVT cluster is healthy and operational"
    else
        log_warn "DVT cluster status: $cluster_status"
    fi
    
    # Display cluster information
    log_info "Cluster Information:"
    echo "  - Cluster ID: $(echo "$api_response" | jq -r '.result.cluster_id' 2>/dev/null || echo "N/A")"
    echo "  - Active Nodes: $(echo "$api_response" | jq -r '.result.active_nodes' 2>/dev/null || echo "N/A")/$CLUSTER_SIZE"
    echo "  - Threshold: $THRESHOLD"
    echo "  - Network: $NETWORK"
}

# Stop DVT cluster
stop_dvt_cluster() {
    log_info "Stopping DVT cluster..."
    
    for ((i=1; i<=CLUSTER_SIZE; i++)); do
        local pid_file="$PROJECT_ROOT/testnet/nodes/node-$i/node.pid"
        if [[ -f "$pid_file" ]]; then
            local pid
            pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                log_info "Stopping node $i (PID: $pid)..."
                kill "$pid"
                rm "$pid_file"
            fi
        fi
    done
    
    log_success "DVT cluster stopped"
}

# Cleanup deployment
cleanup_deployment() {
    log_info "Cleaning up deployment..."
    
    # Stop DVT cluster
    stop_dvt_cluster
    
    # Stop AntidoteDB
    local antidote_dir="$PROJECT_ROOT/testnet/antidote"
    if [[ -d "$antidote_dir" ]]; then
        cd "$antidote_dir"
        docker-compose down -v
    fi
    
    # Remove testnet directory
    if [[ "$1" == "--full" ]]; then
        rm -rf "$PROJECT_ROOT/testnet"
        log_success "Full cleanup completed"
    else
        log_success "Deployment stopped (use --full for complete cleanup)"
    fi
}

# Display help
show_help() {
    cat << EOF
DVT Testnet Deployment Script

Usage: $0 [COMMAND] [OPTIONS]

Commands:
  deploy      Full deployment (keys, database, nodes)
  start       Start DVT cluster
  stop        Stop DVT cluster
  restart     Restart DVT cluster
  status      Check cluster status
  cleanup     Clean up deployment
  help        Show this help

Options:
  --cluster-size N    Number of DVT nodes (default: 5)
  --threshold N       Threshold for consensus (default: 3)  
  --network NAME      Testnet network (default: hoodi, options: hoodi|ephemery|kurtosis)

Examples:
  $0 deploy --cluster-size 7 --threshold 5
  $0 start
  $0 status
  $0 cleanup --full

EOF
}

# Parse command line arguments
COMMAND="${1:-help}"
shift || true

while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster-size)
            CLUSTER_SIZE="$2"
            shift 2
            ;;
        --threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        --network)
            NETWORK="$2"
            shift 2
            ;;
        --full)
            FULL_CLEANUP=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate parameters
if [[ $THRESHOLD -ge $CLUSTER_SIZE ]]; then
    log_error "Threshold ($THRESHOLD) must be less than cluster size ($CLUSTER_SIZE)"
    exit 1
fi

# Main execution
case $COMMAND in
    deploy)
        log_info "Starting full DVT testnet deployment..."
        log_info "Configuration: $CLUSTER_SIZE nodes, threshold $THRESHOLD, network $NETWORK"
        
        check_dependencies
        generate_validator_keys
        setup_antidote_cluster
        deploy_dvt_nodes
        build_release
        start_dvt_cluster
        
        log_success "DVT testnet deployment completed successfully!"
        log_info "Use '$0 status' to check cluster health"
        ;;
        
    start)
        start_dvt_cluster
        ;;
        
    stop)
        stop_dvt_cluster
        ;;
        
    restart)
        stop_dvt_cluster
        sleep 5
        start_dvt_cluster
        ;;
        
    status)
        verify_cluster_health
        ;;
        
    cleanup)
        cleanup_deployment "${FULL_CLEANUP:+--full}"
        ;;
        
    help)
        show_help
        ;;
        
    *)
        log_error "Unknown command: $COMMAND"
        show_help
        exit 1
        ;;
esac