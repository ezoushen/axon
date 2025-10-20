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
PRODUCT_ROOT="$PWD"

# Default configuration file
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
ENVIRONMENT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 <environment> [OPTIONS]"
            echo ""
            echo "Restart container for specified environment."
            echo ""
            echo "OPTIONS:"
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment          Environment to restart"
            echo ""
            echo "Examples:"
            echo "  $0 production        # Restart production container"
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

# Validate environment provided
if [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment is required${NC}"
    echo "Usage: $0 <environment> [OPTIONS]"
    echo "Use --help for more information"
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

# Source config parser
source "$MODULE_DIR/lib/config-parser.sh"

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

# Build container filter
CONTAINER_FILTER="${PRODUCT_NAME}-${ENVIRONMENT}"

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Restart Container - ${PRODUCT_NAME}${NC}"
echo -e "${BLUE}Environment: ${ENVIRONMENT^}${NC}"
echo -e "${BLUE}On Application Server: ${APP_SERVER}${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

# Find the most recent container for this environment
CONTAINER=$(ssh -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
    "docker ps -a --filter 'name=${CONTAINER_FILTER}-' --format '{{.Names}}' | sort -r | head -n 1")

# Check if container exists
if [ -z "$CONTAINER" ]; then
    echo -e "${YELLOW}Warning: No container found for ${ENVIRONMENT} environment${NC}"
    echo -e "${YELLOW}Looking for containers matching: ${CONTAINER_FILTER}-${NC}"
    echo ""
    echo "Available containers:"
    ssh -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
        "docker ps -a --format 'table {{.Names}}\t{{.Status}}' | grep ${PRODUCT_NAME} || echo '  None found'"
    exit 1
fi

echo -e "${CYAN}Container: ${CONTAINER}${NC}"
echo ""

# Restart the container
echo -e "${BLUE}Restarting container...${NC}"

ssh -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" "docker restart \"$CONTAINER\"" > /dev/null

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Container restarted successfully${NC}"
    echo ""

    # Wait a moment for container to start
    echo "Waiting for container to be ready..."
    sleep 3
    echo ""

    # Show status
    echo -e "${BLUE}Container status:${NC}"
    ssh -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
        "docker ps --filter 'name=$CONTAINER' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
    echo ""
else
    echo -e "${RED}✗ Failed to restart container${NC}"
    exit 1
fi
