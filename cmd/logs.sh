#!/bin/bash
# View logs for containers on Application Server
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
LOGS_ALL=false
FOLLOW=false
LINES="50"
SINCE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --all)
            LOGS_ALL=true
            shift
            ;;
        --follow|-f)
            FOLLOW=true
            shift
            ;;
        -n|--lines|--tail)
            LINES="$2"
            shift 2
            ;;
        --since)
            SINCE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 <environment|--all> [OPTIONS]"
            echo ""
            echo "View container logs for a specific environment or all environments."
            echo ""
            echo "OPTIONS:"
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
            echo "  --all                View logs for all environments"
            echo "  -f, --follow         Follow log output (stream in real-time)"
            echo "  -n, --lines N        Number of lines to show (default: 50)"
            echo "  --tail N             Same as --lines"
            echo "  --since DURATION     Show logs since duration (e.g., 1h, 30m)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment          Specific environment to check logs for"
            echo ""
            echo "Examples:"
            echo "  $0 production                # Last 50 lines"
            echo "  $0 --all                     # Logs from all environments"
            echo "  $0 staging --follow          # Follow logs in real-time"
            echo "  $0 production --lines 100    # Last 100 lines"
            echo "  $0 staging --since 1h        # Logs from last hour"
            echo "  $0 --all --lines 20          # Last 20 lines from each environment"
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
if [ "$LOGS_ALL" = false ] && [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment is required (or use --all to view all environments)${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Conflict check
if [ "$LOGS_ALL" = true ] && [ -n "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Cannot specify both --all and a specific environment${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Set ENVIRONMENT to 'all' if --all flag is used
if [ "$LOGS_ALL" = true ]; then
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

# Initialize SSH connection multiplexing for performance
ssh_init_multiplexing

# Load product name
PRODUCT_NAME=$(parse_yaml_key "product.name" "")

if [ -z "$PRODUCT_NAME" ]; then
    echo -e "${RED}Error: Product name not configured${NC}"
    exit 1
fi

# Get Application Server SSH details
APPLICATION_SERVER_HOST=$(parse_yaml_key ".servers.application.host" "")
APPLICATION_SERVER_USER=$(parse_yaml_key ".servers.application.user" "")
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

# Validate environment exists if specific environment requested
if [ "$ENVIRONMENT" != "all" ]; then
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
fi

# Build container filter based on environment
if [ "$ENVIRONMENT" == "all" ]; then
    CONTAINER_FILTER="${PRODUCT_NAME}"
    ENV_DISPLAY="All Environments"
else
    CONTAINER_FILTER="${PRODUCT_NAME}-${ENVIRONMENT}"
    # Convert environment to title case (Bash 3.2 compatible)
    ENV_DISPLAY="$(echo "${ENVIRONMENT:0:1}" | tr '[:lower:]' '[:upper:]')${ENVIRONMENT:1}"
fi

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Container Logs - ${PRODUCT_NAME}${NC}"
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

# Build docker logs command
LOGS_CMD="docker logs"

if [ "$FOLLOW" = true ]; then
    LOGS_CMD="$LOGS_CMD -f"
    echo -e "${GREEN}Following logs (Ctrl+C to exit)...${NC}"
    echo ""
fi

if [ -n "$SINCE" ]; then
    LOGS_CMD="$LOGS_CMD --since $SINCE"
fi

LOGS_CMD="$LOGS_CMD --tail $LINES \"$CONTAINER\""

# Execute docker logs command on Application Server
axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" "$LOGS_CMD"
