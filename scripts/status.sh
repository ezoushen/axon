#!/bin/bash
# Check status of Docker containers
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

# Load product name
PRODUCT_NAME=$(parse_yaml_key "product.name" "my-product")

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

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Docker Containers Status - ${PRODUCT_NAME}${NC}"
echo -e "${BLUE}On Application Server: ${APP_SERVER}${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

# Get all containers for this product from Application Server
CONTAINERS=$(ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
    "docker ps -a --filter 'name=${PRODUCT_NAME}' --format '{{.Names}}' | sort")

if [ -z "$CONTAINERS" ]; then
    echo -e "${YELLOW}No containers found for ${PRODUCT_NAME}${NC}"
    echo ""
    echo "To deploy:"
    echo "  ./deploy/deploy.sh production"
    echo "  ./deploy/deploy.sh staging"
    exit 0
fi

# Summary
echo -e "${CYAN}Container Summary:${NC}"
echo ""
ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
    "docker ps -a --filter 'name=${PRODUCT_NAME}' \
     --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
echo ""

# Detailed status
echo -e "${CYAN}Detailed Status:${NC}"
echo ""

# Get detailed info for all containers in one SSH call
CONTAINER_DETAILS=$(ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<'EOF_REMOTE'
PRODUCT_NAME="'"$PRODUCT_NAME"'"
CONTAINERS=$(docker ps -a --filter "name=${PRODUCT_NAME}" --format "{{.Names}}" | sort)

for CONTAINER in $CONTAINERS; do
    # Parse environment from container name
    if [[ $CONTAINER == *"production"* ]]; then
        ENV="PRODUCTION"
    elif [[ $CONTAINER == *"staging"* ]]; then
        ENV="STAGING"
    else
        ENV="UNKNOWN"
    fi

    # Get container details
    STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null)
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)
    [ "$HEALTH" == "<no value>" ] && HEALTH="N/A"

    IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER" 2>/dev/null)
    IMAGE_TAG=$(echo "$IMAGE" | cut -d':' -f2)

    STARTED=""
    if [ "$STATUS" == "running" ]; then
        STARTED=$(docker inspect --format='{{.State.StartedAt}}' "$CONTAINER" | cut -d'.' -f1)
    fi

    # Output in parseable format
    echo "CONTAINER:${CONTAINER}|ENV:${ENV}|STATUS:${STATUS}|HEALTH:${HEALTH}|IMAGE_TAG:${IMAGE_TAG}|STARTED:${STARTED}"
done
EOF_REMOTE
)

# Parse and display the details
while IFS= read -r LINE; do
    if [ -z "$LINE" ]; then
        continue
    fi

    # Parse the line
    CONTAINER=$(echo "$LINE" | grep -oP 'CONTAINER:\K[^|]+')
    ENV=$(echo "$LINE" | grep -oP 'ENV:\K[^|]+')
    STATUS=$(echo "$LINE" | grep -oP 'STATUS:\K[^|]+')
    HEALTH=$(echo "$LINE" | grep -oP 'HEALTH:\K[^|]+')
    IMAGE_TAG=$(echo "$LINE" | grep -oP 'IMAGE_TAG:\K[^|]+')
    STARTED=$(echo "$LINE" | grep -oP 'STARTED:\K[^|]+')

    # Environment color
    case "$ENV" in
        PRODUCTION) ENV_COLOR="${GREEN}" ;;
        STAGING) ENV_COLOR="${YELLOW}" ;;
        *) ENV_COLOR="${RED}" ;;
    esac

    # Status color
    if [ "$STATUS" == "running" ]; then
        STATUS_COLOR="${GREEN}"
        STATUS_SYMBOL="●"
    else
        STATUS_COLOR="${RED}"
        STATUS_SYMBOL="●"
    fi

    # Health color
    case "$HEALTH" in
        healthy) HEALTH_COLOR="${GREEN}" ;;
        unhealthy) HEALTH_COLOR="${RED}" ;;
        *) HEALTH_COLOR="${YELLOW}" ;;
    esac

    echo -e "${ENV_COLOR}${ENV} Environment${NC}"
    echo -e "  Container:  ${CYAN}${CONTAINER}${NC}"
    echo -e "  Status:     ${STATUS_COLOR}${STATUS_SYMBOL} ${STATUS}${NC}"
    echo -e "  Health:     ${HEALTH_COLOR}${HEALTH}${NC}"
    echo -e "  Image Tag:  ${CYAN}${IMAGE_TAG}${NC}"

    if [ -n "$STARTED" ]; then
        echo -e "  Started:    ${CYAN}${STARTED}${NC}"
    fi

    echo ""
done <<< "$CONTAINER_DETAILS"

# Resource usage
echo -e "${CYAN}Resource Usage:${NC}"
echo ""
ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
    "docker stats --no-stream --filter 'name=${PRODUCT_NAME}' \
     --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}'"
echo ""
