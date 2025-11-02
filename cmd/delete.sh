#!/bin/bash
# AXON - Delete Environment Configuration Script
# Removes environment-specific Docker containers and nginx configs
# Runs from LOCAL MACHINE

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AXON_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRODUCT_ROOT="$(cd "$AXON_DIR/.." && pwd)"

# Source libraries
source "$AXON_DIR/lib/defaults.sh"
source "$AXON_DIR/lib/ssh-batch.sh"

# Initialize SSH connection multiplexing for performance
if type ssh_init_multiplexing >/dev/null 2>&1; then
    ssh_init_multiplexing
fi

# Default values
CONFIG_FILE="axon.config.yml"
ENVIRONMENT=""
FORCE=false
DELETE_ALL=false

# Early product type detection - scan for -c/--config before full parsing
next_is_config=""
for arg in "$@"; do
    if [ "$next_is_config" = "1" ]; then
        CONFIG_FILE="$arg"
        next_is_config=""
        break
    fi
    if [ "$arg" = "-c" ] || [ "$arg" = "--config" ]; then
        next_is_config="1"
    fi
done

# Make CONFIG_FILE absolute if relative
if [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="${PRODUCT_ROOT}/${CONFIG_FILE}"
fi

# Check product type and delegate to static handler if needed
if [ -f "$CONFIG_FILE" ]; then
    source "$AXON_DIR/lib/config-parser.sh"
    PRODUCT_TYPE=$(get_product_type "$CONFIG_FILE" 2>/dev/null || echo "docker")

    if [ "$PRODUCT_TYPE" = "static" ]; then
        # Delegate to static site deletion handler with intact $@
        exec "$AXON_DIR/cmd/delete-static.sh" "$@"
    fi
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        --all)
            DELETE_ALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 --config CONFIG_FILE [OPTIONS] [ENVIRONMENT|--all]"
            echo ""
            echo "Options:"
            echo "  -c, --config FILE    Configuration file (default: axon.config.yml)"
            echo "  -f, --force          Skip confirmation prompt"
            echo "  --all                Delete all configured environments"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --config axon.config.yml staging         # Delete staging environment"
            echo "  $0 --force production                       # Delete production without confirmation"
            echo "  $0 --all                                    # Delete all environments"
            echo "  $0 --all --force                            # Delete all without confirmations"
            exit 0
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            exit 1
            ;;
        *)
            if [ -z "$ENVIRONMENT" ]; then
                ENVIRONMENT="$1"
            else
                echo -e "${RED}Error: Too many positional arguments${NC}"
                exit 1
            fi
            shift
            ;;
    esac
done

# Make CONFIG_FILE absolute if relative
if [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="${PRODUCT_ROOT}/${CONFIG_FILE}"
fi

# Validate required arguments
if [ "$DELETE_ALL" = false ] && [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment is required (or use --all to delete all environments)${NC}"
    echo "Usage: $0 --config CONFIG_FILE [OPTIONS] [ENVIRONMENT|--all]"
    exit 1
fi

# Conflict check
if [ "$DELETE_ALL" = true ] && [ -n "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Cannot specify both --all and a specific environment${NC}"
    exit 1
fi

# Check config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found: ${CONFIG_FILE}${NC}"
    exit 1
fi

# Source config parser (if not already loaded)
if ! type get_product_type >/dev/null 2>&1; then
    source "$AXON_DIR/lib/config-parser.sh"
fi

# Handle --all flag
if [ "$DELETE_ALL" = true ]; then
    echo -e "${CYAN}===========================================================${NC}"
    echo -e "${CYAN}AXON - Delete All Environments${NC}"
    echo -e "${CYAN}Removing Docker containers and nginx configurations${NC}"
    echo -e "${CYAN}===========================================================${NC}"
    echo ""

    # Get all configured environments
    AVAILABLE_ENVS=$(get_configured_environments "$CONFIG_FILE")

    if [ -z "$AVAILABLE_ENVS" ]; then
        echo -e "${YELLOW}No environments configured in ${CONFIG_FILE}${NC}"
        exit 0
    fi

    echo -e "${BLUE}Found environments:${NC}"
    for env in $AVAILABLE_ENVS; do
        echo -e "  - ${env}"
    done
    echo ""

    # Confirm unless --force
    if [ "$FORCE" = false ]; then
        ENV_COUNT=$(echo "$AVAILABLE_ENVS" | wc -w | tr -d ' ')
        read -p "Delete all ${ENV_COUNT} environment(s)? This action cannot be undone. (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Deletion cancelled.${NC}"
            exit 0
        fi
        echo ""
    fi

    # Delete each environment
    SUCCESS_COUNT=0
    FAILED_COUNT=0
    FAILED_ENVS=""

    for env in $AVAILABLE_ENVS; do
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}Deleting environment: ${env}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        # Recursively call this script for each environment
        if "$0" --config "$CONFIG_FILE" --force "$env"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            echo -e "${GREEN}✓ Environment '${env}' deleted successfully${NC}"
        else
            FAILED_COUNT=$((FAILED_COUNT + 1))
            FAILED_ENVS="${FAILED_ENVS} ${env}"
            echo -e "${RED}✗ Failed to delete environment '${env}'${NC}"
        fi
        echo ""
    done

    # Summary
    echo -e "${CYAN}===========================================================${NC}"
    echo -e "${CYAN}Deletion Summary${NC}"
    echo -e "${CYAN}===========================================================${NC}"
    echo ""
    echo -e "  Total environments: ${ENV_COUNT}"
    echo -e "  ${GREEN}Successful: ${SUCCESS_COUNT}${NC}"
    if [ $FAILED_COUNT -gt 0 ]; then
        echo -e "  ${RED}Failed: ${FAILED_COUNT}${NC}"
        echo -e "  ${YELLOW}Failed environments:${FAILED_ENVS}${NC}"
        exit 1
    fi
    echo ""
    echo -e "${GREEN}All environments deleted successfully!${NC}"
    exit 0
fi

# Single environment deletion
echo -e "${CYAN}===========================================================${NC}"
echo -e "${CYAN}AXON - Delete Environment: ${ENVIRONMENT}${NC}"
echo -e "${CYAN}Removing Docker containers and nginx configurations${NC}"
echo -e "${CYAN}===========================================================${NC}"
echo ""

# Load configuration
PRODUCT_NAME=$(get_config_with_default ".product.name" "" "$CONFIG_FILE")
APP_SERVER=$(expand_env_vars "$(get_config_with_default ".servers.application.host" "" "$CONFIG_FILE")")
APP_USER=$(expand_env_vars "$(get_config_with_default ".servers.application.user" "" "$CONFIG_FILE")")
APP_SSH_KEY=$(get_config_with_default ".servers.application.ssh_key" "" "$CONFIG_FILE")
SYSTEM_SERVER=$(expand_env_vars "$(get_config_with_default ".servers.system.host" "" "$CONFIG_FILE")")
SYSTEM_USER=$(expand_env_vars "$(get_config_with_default ".servers.system.user" "" "$CONFIG_FILE")")
SYSTEM_SSH_KEY=$(get_config_with_default ".servers.system.ssh_key" "" "$CONFIG_FILE")
NGINX_AXON_DIR=$(get_nginx_axon_dir "$CONFIG_FILE")
SHUTDOWN_TIMEOUT=$(get_config_with_default ".docker.shutdown_timeout" "30" "$CONFIG_FILE")

# Expand tilde in SSH key paths
APP_SSH_KEY="${APP_SSH_KEY/#\~/$HOME}"
SYSTEM_SSH_KEY="${SYSTEM_SSH_KEY/#\~/$HOME}"

# Determine if we need sudo
USE_SUDO=$(get_config_with_default ".servers.system.use_sudo" "true" "$CONFIG_FILE")
if [ "$USE_SUDO" = "true" ]; then
    USE_SUDO="sudo"
else
    USE_SUDO=""
fi

# Get filenames for this environment
NORMALIZED_ENV=$(normalize_env_name "$ENVIRONMENT")
SITE_FILENAME=$(get_site_filename "$PRODUCT_NAME" "$ENVIRONMENT")
UPSTREAM_FILENAME=$(get_upstream_filename "$PRODUCT_NAME" "$ENVIRONMENT")
NGINX_SITE_FILE="${NGINX_AXON_DIR}/sites/${SITE_FILENAME}"
NGINX_UPSTREAM_FILE="${NGINX_AXON_DIR}/upstreams/${UPSTREAM_FILENAME}"
CONTAINER_PATTERN="${PRODUCT_NAME}-${NORMALIZED_ENV}"

echo -e "${YELLOW}Configuration:${NC}"
echo -e "  Product: ${CYAN}${PRODUCT_NAME}${NC}"
echo -e "  Environment: ${CYAN}${ENVIRONMENT}${NC}"
echo -e "  Container Pattern: ${CYAN}${CONTAINER_PATTERN}-*${NC}"
echo -e "  Site Config: ${CYAN}${NGINX_SITE_FILE}${NC}"
echo -e "  Upstream Config: ${CYAN}${NGINX_UPSTREAM_FILE}${NC}"
echo -e "  Shutdown Timeout: ${CYAN}${SHUTDOWN_TIMEOUT}s${NC}"
echo ""

# Warning
# Step 0: Check if environment exists
echo -e "${BLUE}Checking if environment '${ENVIRONMENT}' exists...${NC}"
echo ""

# Check for containers on Application Server
CONTAINERS_EXIST=$(ssh -i "$APP_SSH_KEY" "${APP_USER}@${APP_SERVER}" \
    "docker ps -a --filter 'name=${CONTAINER_PATTERN}-' --format '{{.Names}}' 2>/dev/null || true")

# Check for nginx configs on System Server
SITE_EXISTS=$(ssh -i "$SYSTEM_SSH_KEY" "${SYSTEM_USER}@${SYSTEM_SERVER}" \
    "[ -f '${NGINX_SITE_FILE}' ] && echo 'yes' || echo 'no'")
UPSTREAM_EXISTS=$(ssh -i "$SYSTEM_SSH_KEY" "${SYSTEM_USER}@${SYSTEM_SERVER}" \
    "[ -f '${NGINX_UPSTREAM_FILE}' ] && echo 'yes' || echo 'no'")

# Check if anything exists
if [ -z "$CONTAINERS_EXIST" ] && [ "$SITE_EXISTS" = "no" ] && [ "$UPSTREAM_EXISTS" = "no" ]; then
    echo -e "${YELLOW}Warning: Environment '${ENVIRONMENT}' not found.${NC}"
    echo ""
    echo -e "No resources found:"
    echo -e "  - No Docker containers matching: ${CONTAINER_PATTERN}-*"
    echo -e "  - nginx site config not found: ${NGINX_SITE_FILE}"
    echo -e "  - nginx upstream config not found: ${NGINX_UPSTREAM_FILE}"
    echo ""

    # Get available environments
    echo -e "${BLUE}Available environments in config:${NC}"
    AVAILABLE_ENVS=$(get_configured_environments "$CONFIG_FILE")
    if [ -n "$AVAILABLE_ENVS" ]; then
        for env in $AVAILABLE_ENVS; do
            echo -e "  - ${env}"
        done
    else
        echo -e "  ${YELLOW}(no environments configured)${NC}"
    fi
    echo ""

    if [ "$FORCE" = false ]; then
        echo -e "${RED}Environment does not exist. Nothing to delete.${NC}"
        exit 1
    else
        echo -e "${YELLOW}Force mode: Continuing anyway...${NC}"
        echo ""
    fi
fi

# Show what exists
echo -e "${GREEN}Environment found:${NC}"
if [ -n "$CONTAINERS_EXIST" ]; then
    CONTAINER_COUNT=$(echo "$CONTAINERS_EXIST" | wc -l | tr -d ' ')
    echo -e "  ✓ ${CONTAINER_COUNT} container(s) on Application Server"
fi
if [ "$SITE_EXISTS" = "yes" ]; then
    echo -e "  ✓ nginx site configuration"
fi
if [ "$UPSTREAM_EXISTS" = "yes" ]; then
    echo -e "  ✓ nginx upstream configuration"
fi
echo ""

echo -e "${YELLOW}WARNING: This will remove:${NC}"
echo -e "  - All Docker containers matching: ${CONTAINER_PATTERN}-*"
echo -e "  - Docker images for this environment"
echo -e "  - nginx site configuration: ${SITE_FILENAME}"
echo -e "  - nginx upstream configuration: ${UPSTREAM_FILENAME}"
echo ""
echo -e "${YELLOW}Other environments will NOT be affected.${NC}"
echo ""

# Confirm unless --force
if [ "$FORCE" = false ]; then
    read -p "Are you sure you want to delete environment '${ENVIRONMENT}'? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Deletion cancelled.${NC}"
        exit 0
    fi
    echo ""
fi

# Step 1: Remove Docker containers from Application Server
echo -e "${BLUE}Step 1/4: Removing Docker containers from Application Server...${NC}"

ssh -i "$APP_SSH_KEY" "${APP_USER}@${APP_SERVER}" "bash -s" <<EOF
set -e

# Find all containers for this environment
CONTAINERS=\$(docker ps -a --filter "name=${CONTAINER_PATTERN}-" --format "{{.Names}}" 2>/dev/null || true)

if [ -z "\$CONTAINERS" ]; then
    echo "  No containers found for environment: ${ENVIRONMENT}"
else
    echo "  Found containers:"
    echo "\$CONTAINERS" | sed 's/^/    - /'
    echo ""
    echo "  Stopping containers gracefully (timeout: ${SHUTDOWN_TIMEOUT}s)..."

    # Stop each container with timeout for graceful shutdown
    for container in \$CONTAINERS; do
        echo "    Stopping \$container..."
        docker stop -t ${SHUTDOWN_TIMEOUT} "\$container" > /dev/null 2>&1 || true
    done

    echo "  ✓ Containers stopped gracefully"
    echo ""
    echo "  Removing containers..."
    echo "\$CONTAINERS" | xargs -r docker rm > /dev/null 2>&1
    echo "  ✓ Containers removed"
fi
EOF

echo -e "  ${GREEN}✓ Containers cleaned up${NC}"
echo ""

# Step 2: Remove Docker images from Application Server
echo -e "${BLUE}Step 2/4: Removing Docker images from Application Server...${NC}"

ssh -i "$APP_SSH_KEY" "${APP_USER}@${APP_SERVER}" "bash -s" <<EOF
set -e

# Find images matching the environment pattern
# Images are typically tagged as: {product}:{env} or {registry}/{product}:{env}
IMAGES=\$(docker images --filter "reference=*${PRODUCT_NAME}*:*${NORMALIZED_ENV}*" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null || true)

if [ -z "\$IMAGES" ]; then
    echo "  No images found for environment: ${ENVIRONMENT}"
else
    echo "  Found images:"
    echo "\$IMAGES" | sed 's/^/    - /'
    echo ""
    echo "  Removing images..."
    echo "\$IMAGES" | xargs -r docker rmi -f > /dev/null 2>&1
    echo "  ✓ Images removed"
fi
EOF

echo -e "  ${GREEN}✓ Images cleaned up${NC}"
echo ""

# Step 3: Remove nginx site configuration from System Server
echo -e "${BLUE}Step 3/4: Removing nginx site configuration...${NC}"

ssh -i "$SYSTEM_SSH_KEY" "${SYSTEM_USER}@${SYSTEM_SERVER}" "bash -s" <<EOF
set -e

if [ -f "${NGINX_SITE_FILE}" ]; then
    echo "  Removing: ${NGINX_SITE_FILE}"
    ${USE_SUDO} rm -f "${NGINX_SITE_FILE}"
    echo "  ✓ Site config removed"
else
    echo "  Site config not found (already removed or never created)"
fi
EOF

echo -e "  ${GREEN}✓ Site configuration cleaned up${NC}"
echo ""

# Step 4: Remove nginx upstream configuration and reload nginx
echo -e "${BLUE}Step 4/4: Removing nginx upstream configuration...${NC}"

ssh -i "$SYSTEM_SSH_KEY" "${SYSTEM_USER}@${SYSTEM_SERVER}" "bash -s" <<EOF
set -e

if [ -f "${NGINX_UPSTREAM_FILE}" ]; then
    echo "  Removing: ${NGINX_UPSTREAM_FILE}"
    ${USE_SUDO} rm -f "${NGINX_UPSTREAM_FILE}"
    echo "  ✓ Upstream config removed"
else
    echo "  Upstream config not found (already removed or never created)"
fi

echo ""
echo "  Testing nginx configuration..."
if ${USE_SUDO} nginx -t 2>&1 | grep -q 'successful'; then
    echo "  ✓ nginx configuration valid"
    echo ""
    echo "  Reloading nginx..."
    ${USE_SUDO} nginx -s reload
    echo "  ✓ nginx reloaded"
else
    echo "  ${RED}✗ nginx configuration test failed${NC}"
    echo "  Please check nginx configuration manually"
    exit 1
fi
EOF

echo -e "  ${GREEN}✓ Upstream configuration cleaned up${NC}"
echo ""

# Success
echo -e "${GREEN}===========================================================${NC}"
echo -e "${GREEN}✓ Environment '${ENVIRONMENT}' Deleted Successfully${NC}"
echo -e "${GREEN}===========================================================${NC}"
echo ""
echo -e "${BLUE}Summary:${NC}"
echo -e "  Product: ${YELLOW}${PRODUCT_NAME}${NC}"
echo -e "  Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "  Status: ${GREEN}✓ All configs and containers removed${NC}"
echo ""
