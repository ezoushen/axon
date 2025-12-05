#!/bin/bash
# AXON - Port/nginx Synchronization Command
# Syncs nginx upstream configuration with the current container port
# Runs from LOCAL MACHINE and SSHs to Application and System servers
#
# Usage: axon sync <environment>

set -e

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
PRODUCT_ROOT="${PROJECT_ROOT:-$PWD}"

# Default configuration file
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
ENVIRONMENT=""
SYNC_ALL=false
FORCE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --all)
            SYNC_ALL=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 <environment|--all> [OPTIONS]"
            echo ""
            echo "Synchronize nginx upstream with the current container port."
            echo "Use this command when nginx is pointing to a stale port after"
            echo "a container restart or system reboot."
            echo ""
            echo "OPTIONS:"
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
            echo "  --all                Sync all environments"
            echo "  -f, --force          Force sync even if ports match"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment          Specific environment to sync"
            echo ""
            echo "Examples:"
            echo "  $0 production        # Sync production environment"
            echo "  $0 --all             # Sync all environments"
            echo "  $0 production -f     # Force sync production"
            exit 0
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            # Positional argument
            if [ -z "$ENVIRONMENT" ]; then
                ENVIRONMENT="$1"
            else
                echo -e "${RED}Error: Too many positional arguments${NC}"
                echo "Use --help for usage information"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ "$SYNC_ALL" = false ] && [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment is required (or use --all to sync all environments)${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Conflict check
if [ "$SYNC_ALL" = true ] && [ -n "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Cannot specify both --all and a specific environment${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Make CONFIG_FILE absolute path if it's relative
if [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="${PRODUCT_ROOT}/${CONFIG_FILE}"
fi

# Validate config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Source libraries
source "$MODULE_DIR/lib/config-parser.sh"
source "$MODULE_DIR/lib/defaults.sh"
source "$MODULE_DIR/lib/ssh-connection.sh"
source "$MODULE_DIR/lib/nginx-config.sh"

# Check product type - sync only works for Docker deployments
PRODUCT_TYPE=$(get_product_type "$CONFIG_FILE")
if [ "$PRODUCT_TYPE" = "static" ]; then
    echo -e "${RED}Error: sync command is only available for Docker deployments${NC}"
    echo ""
    echo "Static sites don't have container ports to sync."
    exit 1
fi

# Initialize SSH connection multiplexing
ssh_init_multiplexing

# Handle --all flag (sync all environments)
if [ "$SYNC_ALL" = true ]; then
    # Get all configured environments
    AVAILABLE_ENVS=$(get_configured_environments "$CONFIG_FILE")

    if [ -z "$AVAILABLE_ENVS" ]; then
        echo -e "${YELLOW}No environments configured${NC}"
        exit 0
    fi

    echo -e "${BLUE}Syncing all environments...${NC}"
    echo ""

    SUCCESS_COUNT=0
    FAILED_COUNT=0

    for env in $AVAILABLE_ENVS; do
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}Environment: ${env}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        if "$0" --config "$CONFIG_FILE" "$env" ${FORCE:+--force}; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
        echo ""
    done

    # Summary
    echo -e "${BLUE}==================================================${NC}"
    echo -e "${BLUE}Sync Summary${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo -e "  ${GREEN}Successful: ${SUCCESS_COUNT}${NC}"
    if [ $FAILED_COUNT -gt 0 ]; then
        echo -e "  ${RED}Failed: ${FAILED_COUNT}${NC}"
        exit 1
    fi
    exit 0
fi

# Load product name
PRODUCT_NAME=$(parse_yaml_key "product.name" "")

if [ -z "$PRODUCT_NAME" ]; then
    echo -e "${RED}Error: Product name not configured${NC}"
    exit 1
fi

# Get Application Server SSH details
APPLICATION_SERVER_HOST=$(expand_env_vars "$(parse_yaml_key ".servers.application.host" "")")
APPLICATION_SERVER_USER=$(expand_env_vars "$(parse_yaml_key ".servers.application.user" "")")
APPLICATION_SERVER_SSH_KEY=$(parse_yaml_key ".servers.application.ssh_key" "")
APPLICATION_SERVER_SSH_KEY="${APPLICATION_SERVER_SSH_KEY/#\~/$HOME}"
APP_PRIVATE_IP=$(expand_env_vars "$(parse_yaml_key ".servers.application.private_ip" "")")

# Get System Server SSH details
SYSTEM_SERVER_HOST=$(expand_env_vars "$(parse_yaml_key ".servers.system.host" "")")
SYSTEM_SERVER_USER=$(expand_env_vars "$(parse_yaml_key ".servers.system.user" "")")
SYSTEM_SERVER_SSH_KEY=$(parse_yaml_key ".servers.system.ssh_key" "")
SYSTEM_SERVER_SSH_KEY="${SYSTEM_SERVER_SSH_KEY/#\~/$HOME}"

# Validate configuration
if [ -z "$APPLICATION_SERVER_HOST" ]; then
    echo -e "${RED}Error: Application Server host not configured${NC}"
    exit 1
fi

if [ ! -f "$APPLICATION_SERVER_SSH_KEY" ]; then
    echo -e "${RED}Error: Application Server SSH key not found: $APPLICATION_SERVER_SSH_KEY${NC}"
    exit 1
fi

if [ -z "$SYSTEM_SERVER_HOST" ]; then
    echo -e "${RED}Error: System Server host not configured${NC}"
    exit 1
fi

if [ ! -f "$SYSTEM_SERVER_SSH_KEY" ]; then
    echo -e "${RED}Error: System Server SSH key not found: $SYSTEM_SERVER_SSH_KEY${NC}"
    exit 1
fi

APP_SERVER="${APPLICATION_SERVER_USER}@${APPLICATION_SERVER_HOST}"
SYSTEM_SERVER="${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}"
APP_UPSTREAM_IP="${APP_PRIVATE_IP:-$APPLICATION_SERVER_HOST}"

# Get container port from config
CONTAINER_PORT=$(parse_yaml_key ".docker.container_port" "3000")

# Get nginx paths
NGINX_AXON_DIR=$(get_nginx_axon_dir "$CONFIG_FILE")
NGINX_UPSTREAM_FILENAME=$(get_upstream_filename "$PRODUCT_NAME" "$ENVIRONMENT")
NGINX_UPSTREAM_FILE="${NGINX_AXON_DIR}/upstreams/${NGINX_UPSTREAM_FILENAME}"
NGINX_UPSTREAM_NAME=$(get_upstream_name "$PRODUCT_NAME" "$ENVIRONMENT")

# Determine sudo usage for System Server
if [ "$SYSTEM_SERVER_USER" = "root" ]; then
    USE_SUDO=""
else
    USE_SUDO="sudo"
fi

# Convert environment to title case
ENV_DISPLAY="$(echo "${ENVIRONMENT:0:1}" | tr '[:lower:]' '[:upper:]')${ENVIRONMENT:1}"

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}AXON - Port/nginx Sync${NC}"
echo -e "${BLUE}Product: ${PRODUCT_NAME}${NC}"
echo -e "${BLUE}Environment: ${ENV_DISPLAY}${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

# Find the container for this environment
CONTAINER_FILTER="${PRODUCT_NAME}-${ENVIRONMENT}"
CONTAINER=$(axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
    "docker ps --filter 'name=${CONTAINER_FILTER}-' --format '{{.Names}}' | sort -r | head -n 1")

if [ -z "$CONTAINER" ]; then
    echo -e "${RED}Error: No running container found for ${ENVIRONMENT} environment${NC}"
    echo -e "${YELLOW}Looking for containers matching: ${CONTAINER_FILTER}-*${NC}"
    exit 1
fi

echo -e "${CYAN}Container: ${CONTAINER}${NC}"

# Get current container port
CURRENT_CONTAINER_PORT=$(axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
    "docker port '$CONTAINER' '$CONTAINER_PORT' 2>/dev/null | cut -d: -f2")

if [ -z "$CURRENT_CONTAINER_PORT" ]; then
    echo -e "${RED}Error: Could not determine container port${NC}"
    echo -e "${YELLOW}Container may not be running or port mapping not configured${NC}"
    exit 1
fi

echo -e "  Container port: ${GREEN}${CURRENT_CONTAINER_PORT}${NC}"

# Get current nginx port
NGINX_PORT=$(axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
    "grep -oP 'server.*:\K\d+' '$NGINX_UPSTREAM_FILE' 2>/dev/null || echo ''")

if [ -z "$NGINX_PORT" ]; then
    echo -e "  nginx upstream: ${YELLOW}Not configured${NC}"
    NGINX_PORT="(none)"
else
    echo -e "  nginx upstream: ${CYAN}${NGINX_PORT}${NC}"
fi

# Check if sync is needed
if [ "$NGINX_PORT" = "$CURRENT_CONTAINER_PORT" ] && [ "$FORCE" = false ]; then
    echo ""
    echo -e "${GREEN}✓ Ports already match - no sync needed${NC}"
    echo -e "  Use --force to sync anyway"
    exit 0
fi

echo ""

if [ "$NGINX_PORT" != "$CURRENT_CONTAINER_PORT" ]; then
    echo -e "${YELLOW}Port mismatch detected:${NC}"
    echo -e "  nginx: ${NGINX_PORT} → container: ${CURRENT_CONTAINER_PORT}"
else
    echo -e "${YELLOW}Force sync requested${NC}"
fi

echo ""
echo -e "${BLUE}Updating nginx upstream...${NC}"

# Generate new upstream config
UPSTREAM_CONFIG="upstream ${NGINX_UPSTREAM_NAME} {
    server ${APP_UPSTREAM_IP}:${CURRENT_CONTAINER_PORT};
}"

# Update nginx upstream and reload
axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
    "echo '$UPSTREAM_CONFIG' | ${USE_SUDO} tee '$NGINX_UPSTREAM_FILE' > /dev/null"

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to update nginx upstream file${NC}"
    exit 1
fi

echo -e "  ${GREEN}✓ Upstream file updated${NC}"

# Test nginx configuration
TEST_OUTPUT=$(axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
    "${USE_SUDO} nginx -t 2>&1")

if ! echo "$TEST_OUTPUT" | grep -q "successful"; then
    echo -e "${RED}Error: nginx configuration test failed${NC}"
    echo "$TEST_OUTPUT"
    exit 1
fi

echo -e "  ${GREEN}✓ nginx configuration valid${NC}"

# Reload nginx
axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
    "${USE_SUDO} nginx -s reload"

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to reload nginx${NC}"
    exit 1
fi

echo -e "  ${GREEN}✓ nginx reloaded${NC}"

echo ""
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}✓ Sync completed successfully${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
echo -e "  nginx upstream now points to port ${GREEN}${CURRENT_CONTAINER_PORT}${NC}"
