#!/bin/bash
# Restart containers for an environment
# Runs from LOCAL MACHINE and SSHs to Application Server
# Product-agnostic version

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRODUCT_ROOT="$(cd "$MODULE_DIR/.." && pwd)"
CONFIG_FILE="${PRODUCT_ROOT}/deploy.config.yml"

# Source config parser
source "$MODULE_DIR/lib/config-parser.sh"

# Parse arguments
ENVIRONMENT=${1}

if [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment parameter required${NC}"
    echo ""
    echo "Usage: $0 <environment>"
    echo ""
    echo "Examples:"
    echo "  $0 production"
    echo "  $0 staging"
    exit 1
fi

# Load configuration
load_config "$ENVIRONMENT"

# Get Application Server SSH details
APP_SERVER_HOST=$(parse_yaml_key ".servers.application.host" "")
APP_SERVER_USER=$(parse_yaml_key ".servers.application.user" "ubuntu")
APP_SSH_KEY=$(parse_yaml_key ".servers.application.ssh_key" "~/.ssh/application_server_key")
APP_SSH_KEY="${APP_SSH_KEY/#\~/$HOME}"

if [ -z "$APP_SERVER_HOST" ]; then
    echo -e "${RED}Error: Application Server host not configured${NC}"
    exit 1
fi

if [ ! -f "$APP_SSH_KEY" ]; then
    echo -e "${RED}Error: SSH key not found: $APP_SSH_KEY${NC}"
    exit 1
fi

APP_SERVER="${APP_SERVER_USER}@${APP_SERVER_HOST}"

echo -e "${BLUE}Restarting ${PRODUCT_NAME} - ${ENVIRONMENT} (on Application Server)${NC}"
echo ""

# Find and restart containers on Application Server
CONTAINERS=$(ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
    "docker ps --filter 'name=${PRODUCT_NAME}-${ENVIRONMENT}' --format '{{.Names}}'")

if [ -z "$CONTAINERS" ]; then
    echo -e "${YELLOW}No running containers found for ${PRODUCT_NAME}-${ENVIRONMENT}${NC}"
    exit 0
fi

# Restart each container
while IFS= read -r CONTAINER; do
    echo -e "Restarting: ${CYAN}${CONTAINER}${NC}"
    ssh -i "$APP_SSH_KEY" "$APP_SERVER" "docker restart '$CONTAINER'"

    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✓ Restarted successfully${NC}"
    else
        echo -e "  ${RED}✗ Failed to restart${NC}"
    fi
done <<< "$CONTAINERS"

echo ""
echo -e "${GREEN}✓ Restart completed${NC}"
echo ""
