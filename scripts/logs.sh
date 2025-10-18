#!/bin/bash
# View logs for specific environment
# Runs from LOCAL MACHINE and SSHs to Application Server
# Product-agnostic version - uses deploy.config.yml

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
FOLLOW=${2}

if [ -z "$ENVIRONMENT" ]; then
    echo -e "${BLUE}View Docker Container Logs${NC}"
    echo ""
    echo "Usage: $0 <environment> [follow]"
    echo ""
    echo "Examples:"
    echo "  $0 production           # Last 50 lines"
    echo "  $0 staging              # Last 50 lines"
    echo "  $0 production follow    # Follow in real-time"
    exit 0
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

echo -e "${BLUE}Logs for ${PRODUCT_NAME} - ${ENVIRONMENT} (from Application Server):${NC}"
echo ""

if [ "$FOLLOW" == "follow" ]; then
    echo -e "${GREEN}Following logs (Ctrl+C to exit)...${NC}"
    echo ""

    # Follow logs from Application Server
    # Find first matching container and follow it
    ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
        "CONTAINER=\$(docker ps -a --filter 'name=${PRODUCT_NAME}-${ENVIRONMENT}' --format '{{.Names}}' | head -1); \
         if [ -z \"\$CONTAINER\" ]; then \
             echo 'No containers found for ${PRODUCT_NAME}-${ENVIRONMENT}'; \
             exit 1; \
         fi; \
         docker logs -f --tail=100 \"\$CONTAINER\""
else
    # Show last 50 lines from all matching containers
    CONTAINERS=$(ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
        "docker ps -a --filter 'name=${PRODUCT_NAME}-${ENVIRONMENT}' --format '{{.Names}}'")

    if [ -z "$CONTAINERS" ]; then
        echo -e "${YELLOW}No containers found for ${PRODUCT_NAME}-${ENVIRONMENT}${NC}"
        exit 0
    fi

    # Show logs for each container
    while IFS= read -r CONTAINER; do
        echo -e "${CYAN}Container: ${CONTAINER}${NC}"
        ssh -i "$APP_SSH_KEY" "$APP_SERVER" "docker logs --tail=50 '$CONTAINER'"
        echo ""
    done <<< "$CONTAINERS"
fi
