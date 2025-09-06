#!/bin/bash

# Mana Ethereum Monitoring Stack Shutdown Script

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Stopping Mana Ethereum Monitoring Stack${NC}"

# Check if docker-compose is installed
if ! command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# Show current status
echo -e "${YELLOW}Current container status:${NC}"
$COMPOSE_CMD ps

echo ""
echo -n "Do you want to remove volumes (this will delete all monitoring data)? (y/n): "
read -r response

if [[ "$response" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Stopping and removing containers with volumes...${NC}"
    $COMPOSE_CMD down -v
    echo -e "${GREEN}Monitoring stack stopped and data removed.${NC}"
else
    echo -e "${YELLOW}Stopping containers (keeping data)...${NC}"
    $COMPOSE_CMD down
    echo -e "${GREEN}Monitoring stack stopped. Data preserved.${NC}"
fi

echo ""
echo "To restart the monitoring stack, run: ./start-monitoring.sh"