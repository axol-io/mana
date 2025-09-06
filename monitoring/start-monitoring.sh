#!/bin/bash

# Mana Ethereum Monitoring Stack Startup Script
# This script starts the complete monitoring stack for Mana Ethereum

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting Mana Ethereum Monitoring Stack${NC}"

# Check if Docker is installed and running
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker is not installed. Please install Docker first.${NC}"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo -e "${RED}Docker is not running. Please start Docker.${NC}"
    exit 1
fi

# Check if docker-compose is installed
if ! command -v docker-compose &> /dev/null; then
    echo -e "${YELLOW}docker-compose not found, trying docker compose...${NC}"
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# Function to wait for service to be healthy
wait_for_service() {
    local service=$1
    local url=$2
    local max_attempts=30
    local attempt=1
    
    echo -n "Waiting for $service to be ready..."
    
    while [ $attempt -le $max_attempts ]; do
        if curl -s -o /dev/null -w "%{http_code}" "$url" | grep -q "200\|302"; then
            echo -e " ${GREEN}Ready!${NC}"
            return 0
        fi
        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo -e " ${RED}Failed to start!${NC}"
    return 1
}

# Create necessary directories if they don't exist
echo "Creating monitoring directories..."
mkdir -p prometheus/alerts
mkdir -p grafana/{dashboards,provisioning/datasources,provisioning/dashboards}
mkdir -p alertmanager
mkdir -p loki
mkdir -p promtail

# Copy provisioning files for Grafana
if [ -f "grafana/datasources.yml" ]; then
    cp grafana/datasources.yml grafana/provisioning/datasources/
fi

# Create dashboard provisioning config
cat > grafana/provisioning/dashboards/dashboards.yml <<EOF
apiVersion: 1

providers:
  - name: 'Mana Dashboards'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

# Copy dashboards
if [ -d "grafana/dashboards" ]; then
    cp -r grafana/dashboards/* grafana/provisioning/dashboards/ 2>/dev/null || true
fi

# Pull latest images
echo -e "${YELLOW}Pulling latest Docker images...${NC}"
$COMPOSE_CMD pull

# Start the monitoring stack
echo -e "${YELLOW}Starting monitoring services...${NC}"
$COMPOSE_CMD up -d

# Wait for services to be ready
echo -e "${YELLOW}Waiting for services to start...${NC}"

wait_for_service "Prometheus" "http://localhost:9090/-/healthy"
wait_for_service "Grafana" "http://localhost:3000/api/health"
wait_for_service "Alertmanager" "http://localhost:9093/-/healthy"

# Display access information
echo ""
echo -e "${GREEN}=== Monitoring Stack Started Successfully ===${NC}"
echo ""
echo "Access the following services:"
echo -e "  ${GREEN}Grafana:${NC}       http://localhost:3000"
echo -e "                  Username: admin"
echo -e "                  Password: mana-ethereum"
echo ""
echo -e "  ${GREEN}Prometheus:${NC}    http://localhost:9090"
echo ""
echo -e "  ${GREEN}Alertmanager:${NC}  http://localhost:9093"
echo ""
echo -e "  ${GREEN}Node Exporter:${NC} http://localhost:9100/metrics"
echo ""

# Show container status
echo -e "${YELLOW}Container Status:${NC}"
$COMPOSE_CMD ps

echo ""
echo -e "${GREEN}Monitoring stack is ready!${NC}"
echo ""
echo "To view logs:    $COMPOSE_CMD logs -f [service_name]"
echo "To stop:         $COMPOSE_CMD down"
echo "To stop & clean: $COMPOSE_CMD down -v"
echo ""

# Optional: Open Grafana in browser
if command -v open &> /dev/null; then
    echo -n "Would you like to open Grafana in your browser? (y/n): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        open http://localhost:3000
    fi
elif command -v xdg-open &> /dev/null; then
    echo -n "Would you like to open Grafana in your browser? (y/n): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        xdg-open http://localhost:3000
    fi
fi