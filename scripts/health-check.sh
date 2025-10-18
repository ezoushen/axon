#!/bin/bash
# Health check script for deployed containers
# Runs from LOCAL MACHINE and checks via domain or SSHs to Application Server
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

# Get Application Server SSH details
APP_SERVER_HOST=$(parse_yaml_key ".servers.application.host" "")
APP_SERVER_USER=$(parse_yaml_key ".servers.application.user" "ubuntu")
APP_SSH_KEY=$(parse_yaml_key ".servers.application.ssh_key" "~/.ssh/application_server_key")
APP_SSH_KEY="${APP_SSH_KEY/#\~/$HOME}"

# Parse arguments
ENVIRONMENT=${1:-all}

check_environment() {
    local env=$1

    load_config "$env"

    echo -e "${BLUE}Checking ${PRODUCT_NAME} - ${env}:${NC}"

    # Check via domain if configured (public endpoint)
    if [ -n "$DOMAIN" ]; then
        URL="https://${DOMAIN}${HEALTH_ENDPOINT}"
        echo -e "  URL: ${CYAN}${URL}${NC} (public)"

        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$URL" 2>/dev/null)

        if [ "$HTTP_CODE" == "200" ]; then
            echo -e "  Status: ${GREEN}✓ Healthy (HTTP $HTTP_CODE)${NC}"
            return 0
        else
            echo -e "  Status: ${RED}✗ Unhealthy (HTTP $HTTP_CODE)${NC}"
            return 1
        fi
    else
        # Check via Application Server (internal check)
        if [ -z "$APP_SERVER_HOST" ]; then
            echo -e "  ${YELLOW}⚠ Application Server not configured, cannot perform internal health check${NC}"
            return 1
        fi

        if [ ! -f "$APP_SSH_KEY" ]; then
            echo -e "  ${RED}✗ SSH key not found: $APP_SSH_KEY${NC}"
            return 1
        fi

        APP_SERVER="${APP_SERVER_USER}@${APP_SERVER_HOST}"

        # Get port from running container via SSH
        PORT=$(ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
            "docker ps --filter 'name=${PRODUCT_NAME}-${env}' --format '{{.Ports}}' | grep -oP '\d+(?=->)' | head -1" 2>/dev/null)

        if [ -z "$PORT" ]; then
            echo -e "  Status: ${YELLOW}⚠ Container not found on Application Server${NC}"
            return 1
        fi

        URL="http://localhost:${PORT}${HEALTH_ENDPOINT}"
        echo -e "  URL: ${CYAN}${URL}${NC} (via Application Server)"

        # Perform health check via SSH
        HTTP_CODE=$(ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
            "curl -s -o /dev/null -w '%{http_code}' --max-time 5 '$URL' 2>/dev/null")

        if [ "$HTTP_CODE" == "200" ]; then
            echo -e "  Status: ${GREEN}✓ Healthy (HTTP $HTTP_CODE)${NC}"
            return 0
        else
            echo -e "  Status: ${RED}✗ Unhealthy (HTTP $HTTP_CODE)${NC}"
            return 1
        fi
    fi
}

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Health Check${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

if [ "$ENVIRONMENT" == "all" ]; then
    # Check all configured environments
    ENVS=$(grep -E "^\s+[a-z]+:" "$CONFIG_FILE" | grep -A1 "environments:" | tail -n +2 | awk '{print $1}' | tr -d ':')

    FAILED=0
    for env in $ENVS; do
        check_environment "$env"
        [ $? -ne 0 ] && FAILED=$((FAILED + 1))
        echo ""
    done

    if [ $FAILED -eq 0 ]; then
        echo -e "${GREEN}✓ All environments healthy${NC}"
        exit 0
    else
        echo -e "${RED}✗ ${FAILED} environment(s) unhealthy${NC}"
        exit 1
    fi
else
    check_environment "$ENVIRONMENT"
    exit $?
fi
