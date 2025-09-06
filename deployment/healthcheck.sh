#!/bin/bash

# Mana Health Check Script
# Validates node health across multiple dimensions

set -euo pipefail

# Configuration
HEALTH_ENDPOINT="http://localhost:9090"
METRICS_ENDPOINT="http://localhost:9090/metrics"
RPC_ENDPOINT="http://localhost:8545"
TIMEOUT=10

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

check_http_endpoint() {
    local endpoint=$1
    local name=$2
    
    if curl -f -s --max-time "$TIMEOUT" "$endpoint" > /dev/null; then
        log "${GREEN}✓${NC} $name endpoint healthy"
        return 0
    else
        log "${RED}✗${NC} $name endpoint failed"
        return 1
    fi
}

check_json_rpc() {
    local payload='{"jsonrpc":"2.0","method":"web3_clientVersion","params":[],"id":1}'
    
    local response
    if response=$(curl -f -s --max-time "$TIMEOUT" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$RPC_ENDPOINT" 2>/dev/null); then
        
        if echo "$response" | jq -e '.result' > /dev/null 2>&1; then
            log "${GREEN}✓${NC} JSON-RPC endpoint responding"
            return 0
        fi
    fi
    
    log "${RED}✗${NC} JSON-RPC endpoint failed"
    return 1
}

check_performance_metrics() {
    local metrics
    if ! metrics=$(curl -f -s --max-time "$TIMEOUT" "$METRICS_ENDPOINT" 2>/dev/null); then
        log "${RED}✗${NC} Unable to fetch metrics"
        return 1
    fi
    
    # Check for key performance indicators
    local checks=0
    local passed=0
    
    # Verkle tree operations
    if echo "$metrics" | grep -q "verkle_tree_operations_total"; then
        ((passed++))
    fi
    ((checks++))
    
    # EVM execution metrics
    if echo "$metrics" | grep -q "evm_opcodes_executed_total"; then
        ((passed++))
    fi
    ((checks++))
    
    # Network metrics
    if echo "$metrics" | grep -q "libp2p_peers_connected"; then
        ((passed++))
    fi
    ((checks++))
    
    # HSM metrics (optional)
    if echo "$metrics" | grep -q "hsm_operations_total"; then
        ((passed++))
    fi
    ((checks++))
    
    if [ "$passed" -ge 2 ]; then
        log "${GREEN}✓${NC} Performance metrics available ($passed/$checks)"
        return 0
    else
        log "${YELLOW}!${NC} Limited performance metrics ($passed/$checks)"
        return 1
    fi
}

check_memory_usage() {
    local memory_info
    if memory_info=$(cat /proc/meminfo 2>/dev/null); then
        local total_mem
        local available_mem
        
        total_mem=$(echo "$memory_info" | grep "MemTotal:" | awk '{print $2}')
        available_mem=$(echo "$memory_info" | grep "MemAvailable:" | awk '{print $2}')
        
        if [ -n "$total_mem" ] && [ -n "$available_mem" ]; then
            local usage_percent=$((100 * (total_mem - available_mem) / total_mem))
            
            if [ "$usage_percent" -lt 90 ]; then
                log "${GREEN}✓${NC} Memory usage acceptable ($usage_percent%)"
                return 0
            else
                log "${YELLOW}!${NC} High memory usage ($usage_percent%)"
                return 1
            fi
        fi
    fi
    
    log "${YELLOW}!${NC} Unable to check memory usage"
    return 1
}

check_disk_space() {
    local data_dir="/opt/mana/data"
    if [ -d "$data_dir" ]; then
        local usage
        usage=$(df -h "$data_dir" | awk 'NR==2 {print $5}' | sed 's/%//')
        
        if [ -n "$usage" ] && [ "$usage" -lt 85 ]; then
            log "${GREEN}✓${NC} Disk space sufficient ($usage% used)"
            return 0
        else
            log "${YELLOW}!${NC} Disk space limited ($usage% used)"
            return 1
        fi
    fi
    
    log "${YELLOW}!${NC} Unable to check disk space"
    return 1
}

main() {
    log "Starting Mana health check..."
    
    local exit_code=0
    local checks=0
    local passed=0
    
    # Essential checks (failure = unhealthy)
    essential_checks=(
        "check_http_endpoint $HEALTH_ENDPOINT Health"
        "check_json_rpc"
    )
    
    for check in "${essential_checks[@]}"; do
        ((checks++))
        if eval "$check"; then
            ((passed++))
        else
            exit_code=1
        fi
    done
    
    # Performance checks (warnings only)
    performance_checks=(
        "check_performance_metrics"
        "check_memory_usage"
        "check_disk_space"
    )
    
    for check in "${performance_checks[@]}"; do
        ((checks++))
        if eval "$check"; then
            ((passed++))
        fi
    done
    
    # Summary
    if [ "$exit_code" -eq 0 ]; then
        log "${GREEN}✓${NC} Health check passed ($passed/$checks checks)"
    else
        log "${RED}✗${NC} Health check failed ($passed/$checks checks)"
    fi
    
    exit "$exit_code"
}

main "$@"