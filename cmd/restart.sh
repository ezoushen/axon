#!/bin/bash
# Restart containers on Application Server
# Runs from LOCAL MACHINE and SSHs to Application Server
# Product-agnostic version - uses axon.config.yml

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
# Use current working directory for PRODUCT_ROOT (where config/Dockerfile live)
PRODUCT_ROOT="${PROJECT_ROOT:-$PWD}"

# Default configuration file
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
ENVIRONMENT=""
RESTART_ALL=false
FORCE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --all)
            RESTART_ALL=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 <environment|--all> [OPTIONS]"
            echo ""
            echo "Restart container for a specific environment or all environments."
            echo ""
            echo "OPTIONS:"
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
            echo "  --all                Restart all environments"
            echo "  -f, --force          Skip confirmation prompt (when using --all)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment          Specific environment to restart"
            echo ""
            echo "Examples:"
            echo "  $0 production        # Restart production container"
            echo "  $0 --all             # Restart all environments (with confirmation)"
            echo "  $0 --all --force     # Restart all without confirmation"
            echo "  $0 staging           # Restart staging container"
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
if [ "$RESTART_ALL" = false ] && [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment is required (or use --all to restart all environments)${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Conflict check
if [ "$RESTART_ALL" = true ] && [ -n "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Cannot specify both --all and a specific environment${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Set ENVIRONMENT to 'all' if --all flag is used
if [ "$RESTART_ALL" = true ]; then
    ENVIRONMENT="all"
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

# Check product type - restart only works for Docker deployments
PRODUCT_TYPE=$(get_product_type "$CONFIG_FILE")
if [ "$PRODUCT_TYPE" = "static" ]; then
    echo -e "${RED}Error: restart command is only available for Docker deployments${NC}"
    echo ""
    echo "Static sites don't have containers to restart."
    echo "To reload nginx configuration, use:"
    echo "  ssh <system-server> 'sudo nginx -s reload'"
    echo ""
    exit 1
fi

# Initialize SSH connection multiplexing for performance
ssh_init_multiplexing

# Handle --all flag (restart all environments)
if [ "$ENVIRONMENT" == "all" ]; then
    # Get all configured environments
    AVAILABLE_ENVS=$(get_configured_environments "$CONFIG_FILE")

    if [ -z "$AVAILABLE_ENVS" ]; then
        echo -e "${YELLOW}No environments configured${NC}"
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
        echo -e "${YELLOW}Warning: You are about to restart ${ENV_COUNT} environment(s).${NC}"
        echo -e "${YELLOW}This will cause brief downtime for all environments.${NC}"
        read -p "Are you sure? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Restart cancelled.${NC}"
            exit 0
        fi
    fi

    # Restart each environment
    SUCCESS_COUNT=0
    FAILED_COUNT=0
    FAILED_ENVS=""

    for env in $AVAILABLE_ENVS; do
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}Restarting environment: ${env}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        # Recursively call this script for each environment
        if "$0" --config "$CONFIG_FILE" "$env"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            echo ""
        else
            FAILED_COUNT=$((FAILED_COUNT + 1))
            FAILED_ENVS="${FAILED_ENVS} ${env}"
            echo ""
        fi
    done

    # Summary
    echo -e "${BLUE}==================================================${NC}"
    echo -e "${BLUE}Restart All Environments - Summary${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo ""
    echo -e "  Total environments: ${ENV_COUNT}"
    echo -e "  ${GREEN}Successful: ${SUCCESS_COUNT}${NC}"
    if [ $FAILED_COUNT -gt 0 ]; then
        echo -e "  ${RED}Failed: ${FAILED_COUNT}${NC}"
        echo -e "  ${YELLOW}Failed environments:${FAILED_ENVS}${NC}"
        exit 1
    fi
    echo ""
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

if [ -z "$APPLICATION_SERVER_HOST" ]; then
    echo -e "${RED}Error: Application Server host not configured${NC}"
    exit 1
fi

if [ ! -f "$APPLICATION_SERVER_SSH_KEY" ]; then
    echo -e "${RED}Error: SSH key not found: $APPLICATION_SERVER_SSH_KEY${NC}"
    exit 1
fi

APP_SERVER="${APPLICATION_SERVER_USER}@${APPLICATION_SERVER_HOST}"

# Validate environment exists
AVAILABLE_ENVS=$(get_configured_environments "$CONFIG_FILE")

if [ -z "$AVAILABLE_ENVS" ]; then
    echo -e "${RED}Error: No environments configured in ${CONFIG_FILE}${NC}"
    exit 1
fi

# Check if requested environment is in the list
ENV_FOUND=false
for env in $AVAILABLE_ENVS; do
    if [ "$env" = "$ENVIRONMENT" ]; then
        ENV_FOUND=true
        break
    fi
done

if [ "$ENV_FOUND" = false ]; then
    echo -e "${RED}Error: Environment '${ENVIRONMENT}' not found in configuration${NC}"
    echo ""
    echo -e "${BLUE}Available environments:${NC}"
    for env in $AVAILABLE_ENVS; do
        echo -e "  - ${env}"
    done
    echo ""
    exit 1
fi

# Build container filter
CONTAINER_FILTER="${PRODUCT_NAME}-${ENVIRONMENT}"

# Convert environment to title case (Bash 3.2 compatible)
ENV_DISPLAY="$(echo "${ENVIRONMENT:0:1}" | tr '[:lower:]' '[:upper:]')${ENVIRONMENT:1}"

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Restart Container - ${PRODUCT_NAME}${NC}"
echo -e "${BLUE}Environment: ${ENV_DISPLAY}${NC}"
echo -e "${BLUE}On Application Server: ${APP_SERVER}${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

# Find the most recent container for this environment
CONTAINER=$(axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
    "docker ps -a --filter 'name=${CONTAINER_FILTER}-' --format '{{.Names}}' | sort -r | head -n 1")

# Check if container exists
if [ -z "$CONTAINER" ]; then
    echo -e "${YELLOW}Warning: No container found for ${ENVIRONMENT} environment${NC}"
    echo -e "${YELLOW}Looking for containers matching: ${CONTAINER_FILTER}-${NC}"
    echo ""
    echo "Available containers:"
    axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
        "docker ps -a --format 'table {{.Names}}\t{{.Status}}' | grep ${PRODUCT_NAME} || echo '  None found'"
    exit 1
fi

echo -e "${CYAN}Container: ${CONTAINER}${NC}"
echo ""

# Restart the container
echo -e "${BLUE}Restarting container...${NC}"

axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" "docker restart \"$CONTAINER\"" > /dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Container restarted successfully${NC}"
    echo ""

    # Wait a moment for container to start
    echo "Waiting for container to be ready..."
    sleep 3
    echo ""

    # Show status
    echo -e "${BLUE}Container status:${NC}"
    axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
        "docker ps --filter 'name=$CONTAINER' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
    echo ""

    # Verify port and sync nginx if needed
    echo -e "${BLUE}Verifying port configuration...${NC}"

    # Get container port from config
    CONTAINER_PORT=$(parse_yaml_key ".docker.container_port" "3000")

    # Get current container port
    CURRENT_CONTAINER_PORT=$(axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
        "docker port '$CONTAINER' '$CONTAINER_PORT' 2>/dev/null | cut -d: -f2")

    if [ -z "$CURRENT_CONTAINER_PORT" ]; then
        echo -e "${YELLOW}  Warning: Could not determine container port${NC}"
    else
        echo -e "  Container port: ${CYAN}${CURRENT_CONTAINER_PORT}${NC}"

        # Get System Server details for nginx sync
        SYSTEM_SERVER_HOST=$(expand_env_vars "$(parse_yaml_key ".servers.system.host" "")")
        SYSTEM_SERVER_USER=$(expand_env_vars "$(parse_yaml_key ".servers.system.user" "")")
        SYSTEM_SSH_KEY=$(parse_yaml_key ".servers.system.ssh_key" "")
        SYSTEM_SSH_KEY="${SYSTEM_SSH_KEY/#\~/$HOME}"

        if [ -n "$SYSTEM_SERVER_HOST" ] && [ -f "$SYSTEM_SSH_KEY" ]; then
            SYSTEM_SERVER="${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}"

            # Get nginx upstream file path
            NGINX_AXON_DIR=$(get_nginx_axon_dir "$CONFIG_FILE")
            NGINX_UPSTREAM_FILENAME=$(get_upstream_filename "$PRODUCT_NAME" "$ENVIRONMENT")
            NGINX_UPSTREAM_FILE="${NGINX_AXON_DIR}/upstreams/${NGINX_UPSTREAM_FILENAME}"

            # Get current nginx port
            NGINX_PORT=$(axon_ssh "system" -i "$SYSTEM_SSH_KEY" "$SYSTEM_SERVER" \
                "grep -oP 'server.*:\K\d+' '$NGINX_UPSTREAM_FILE' 2>/dev/null || echo ''")

            if [ -n "$NGINX_PORT" ]; then
                echo -e "  nginx upstream port: ${CYAN}${NGINX_PORT}${NC}"

                if [ "$NGINX_PORT" = "$CURRENT_CONTAINER_PORT" ]; then
                    echo -e "  ${GREEN}✓ Ports match - no sync needed${NC}"
                else
                    echo -e "  ${YELLOW}⚠ Port mismatch detected!${NC}"
                    echo -e "  ${YELLOW}  nginx: ${NGINX_PORT} → container: ${CURRENT_CONTAINER_PORT}${NC}"
                    echo ""
                    echo -e "${BLUE}Syncing nginx upstream...${NC}"

                    # Get upstream name and IP
                    NGINX_UPSTREAM_NAME=$(get_upstream_name "$PRODUCT_NAME" "$ENVIRONMENT")
                    APP_PRIVATE_IP=$(expand_env_vars "$(parse_yaml_key ".servers.application.private_ip" "")")
                    APP_UPSTREAM_IP="${APP_PRIVATE_IP:-$APPLICATION_SERVER_HOST}"

                    # Determine sudo usage
                    if [ "$SYSTEM_SERVER_USER" = "root" ]; then
                        USE_SUDO=""
                    else
                        USE_SUDO="sudo"
                    fi

                    # Update nginx upstream
                    UPSTREAM_CONFIG="upstream ${NGINX_UPSTREAM_NAME} {
    server ${APP_UPSTREAM_IP}:${CURRENT_CONTAINER_PORT};
}"
                    axon_ssh "system" -i "$SYSTEM_SSH_KEY" "$SYSTEM_SERVER" \
                        "echo '$UPSTREAM_CONFIG' | ${USE_SUDO} tee '$NGINX_UPSTREAM_FILE' > /dev/null && ${USE_SUDO} nginx -t && ${USE_SUDO} nginx -s reload"

                    if [ $? -eq 0 ]; then
                        echo -e "  ${GREEN}✓ nginx upstream synced to port ${CURRENT_CONTAINER_PORT}${NC}"
                    else
                        echo -e "  ${RED}✗ Failed to sync nginx upstream${NC}"
                        echo -e "  ${YELLOW}Run 'axon sync ${ENVIRONMENT}' to manually sync${NC}"
                    fi
                fi
            else
                echo -e "  ${YELLOW}Warning: Could not read nginx upstream port${NC}"
            fi
        else
            echo -e "  ${YELLOW}Skipping nginx sync (System Server not configured or SSH key missing)${NC}"
        fi
    fi
    echo ""
else
    echo -e "${RED}✗ Failed to restart container${NC}"
    exit 1
fi
