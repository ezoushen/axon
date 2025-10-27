#!/bin/bash
# AXON - Application Server Uninstall Script
# Runs from LOCAL MACHINE and removes AXON artifacts from Application Server
# WARNING: This removes deployment artifacts but NOT Docker itself

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
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRODUCT_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"

# Default configuration file
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
FORCE=false

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
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
            echo "  -f, --force          Skip confirmation prompts"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Example:"
            echo "  $0 --config custom.yml"
            echo "  $0 --force"
            exit 0
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            echo -e "${RED}Error: Unexpected argument: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Make CONFIG_FILE absolute path if it's relative
if [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="${PRODUCT_ROOT}/${CONFIG_FILE}"
fi

echo -e "${CYAN}==================================================${NC}"
echo -e "${CYAN}Application Server Uninstallation${NC}"
echo -e "${CYAN}Removing AXON Deployment Artifacts${NC}"
echo -e "${CYAN}==================================================${NC}"
echo ""
echo -e "${YELLOW}Running from: $(hostname)${NC}"
echo -e "${YELLOW}Config file: ${CONFIG_FILE}${NC}"
echo ""

# Function to check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Function to parse YAML configuration
parse_config() {
    local key=$1
    local default=$2

    # Try yq if available
    if command_exists yq; then
        value=$(yq eval "$key" "$CONFIG_FILE" 2>/dev/null || echo "")
        if [ "$value" != "null" ] && [ -n "$value" ]; then
            echo "$value"
            return
        fi
    fi

    # Fallback: Simple grep/awk parser
    local search_key=$(echo "$key" | awk -F'.' '{print $NF}')
    value=$(grep -E "^\s*${search_key}:" "$CONFIG_FILE" | head -1 | \
            awk -F': ' '{print $2}' | sed 's/["'\''"]//g' | sed 's/#.*//' | tr -d ' ')
    echo "${value:-$default}"
}

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Configuration file not found: ${CONFIG_FILE}${NC}"
    exit 1
fi

# Load configuration
echo -e "${BLUE}Loading configuration...${NC}"
APP_SERVER_HOST=$(parse_config ".servers.application.host" "")
APP_SERVER_USER=$(parse_config ".servers.application.user" "")
APP_SERVER_SSH_KEY=$(parse_config ".servers.application.ssh_key" "")
APP_SERVER_DEPLOY_PATH=$(parse_config ".servers.application.deploy_path" "")
PRODUCT_NAME=$(parse_config ".product.name" "")
SHUTDOWN_TIMEOUT=$(parse_config ".docker.shutdown_timeout" "30")

# Expand tilde in SSH key path
APP_SERVER_SSH_KEY="${APP_SERVER_SSH_KEY/#\~/$HOME}"

echo -e "  Application Server: ${CYAN}${APP_SERVER_USER}@${APP_SERVER_HOST}${NC}"
echo -e "  Product: ${CYAN}${PRODUCT_NAME}${NC}"
echo -e "  Deploy Path: ${CYAN}${APP_SERVER_DEPLOY_PATH}${NC}"
echo -e "  Shutdown Timeout: ${CYAN}${SHUTDOWN_TIMEOUT}s${NC}"
echo ""

# Warning
echo -e "${YELLOW}WARNING: This will remove:${NC}"
echo -e "  - Product deployment directory: ${APP_SERVER_DEPLOY_PATH}"
echo -e "  - All Docker containers for this product"
echo -e "  - Product Docker images"
echo ""
echo -e "${YELLOW}This will NOT remove:${NC}"
echo -e "  - Docker itself"
echo -e "  - Other products' containers/images"
echo ""

# Confirm unless --force
if [ "$FORCE" = false ]; then
    read -p "Do you want to continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Uninstallation cancelled.${NC}"
        exit 0
    fi
fi

# Step 1: Check SSH connectivity
echo ""
echo -e "${BLUE}Step 1/4: Checking SSH connectivity...${NC}"

if ! ssh -i "$APP_SERVER_SSH_KEY" -o ConnectTimeout=10 \
    "${APP_SERVER_USER}@${APP_SERVER_HOST}" "echo 'SSH OK'" > /dev/null 2>&1; then
    echo -e "  ${RED}✗ Cannot connect to Application Server${NC}"
    echo -e "  Host: ${APP_SERVER_HOST}"
    echo -e "  User: ${APP_SERVER_USER}"
    echo -e "  Key: ${APP_SERVER_SSH_KEY}"
    exit 1
fi
echo -e "  ${GREEN}✓ SSH connection successful${NC}"
echo ""

# Step 2: Stop and remove all containers for this product
echo -e "${BLUE}Step 2/4: Stopping and removing product containers...${NC}"

ssh -i "$APP_SERVER_SSH_KEY" "${APP_SERVER_USER}@${APP_SERVER_HOST}" \
    "bash -s" <<EOF
set -e

# Find all containers for this product
CONTAINERS=\$(docker ps -a --filter "name=${PRODUCT_NAME}-" --format "{{.Names}}" 2>/dev/null || true)

if [ -z "\$CONTAINERS" ]; then
    echo "  No containers found for product: ${PRODUCT_NAME}"
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

echo -e "  ${GREEN}✓ Product containers cleaned up${NC}"
echo ""

# Step 3: Remove product images
echo -e "${BLUE}Step 3/4: Removing product Docker images...${NC}"

ssh -i "$APP_SERVER_SSH_KEY" "${APP_SERVER_USER}@${APP_SERVER_HOST}" \
    "bash -s" <<EOF
set -e

# Find all images for this product
IMAGES=\$(docker images --filter "reference=*${PRODUCT_NAME}*" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null || true)

if [ -z "\$IMAGES" ]; then
    echo "  No images found for product: ${PRODUCT_NAME}"
else
    echo "  Found images:"
    echo "\$IMAGES" | sed 's/^/    - /'
    echo ""
    echo "  Removing images..."
    echo "\$IMAGES" | xargs -r docker rmi -f > /dev/null 2>&1
    echo "  ✓ Images removed"
fi
EOF

echo -e "  ${GREEN}✓ Product images cleaned up${NC}"
echo ""

# Step 4: Remove deployment directory
echo -e "${BLUE}Step 4/4: Removing deployment directory...${NC}"

ssh -i "$APP_SERVER_SSH_KEY" "${APP_SERVER_USER}@${APP_SERVER_HOST}" \
    "bash -s" <<EOF
set -e

if [ -d "${APP_SERVER_DEPLOY_PATH}" ]; then
    echo "  Removing: ${APP_SERVER_DEPLOY_PATH}"
    rm -rf "${APP_SERVER_DEPLOY_PATH}"
    echo "  ✓ Directory removed"
else
    echo "  Directory not found: ${APP_SERVER_DEPLOY_PATH}"
fi
EOF

echo -e "  ${GREEN}✓ Deployment directory cleaned up${NC}"
echo ""

# Success
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}Application Server Uninstallation Complete${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
echo -e "${BLUE}Summary:${NC}"
echo -e "  Product: ${YELLOW}${PRODUCT_NAME}${NC}"
echo -e "  Server: ${YELLOW}${APP_SERVER_HOST}${NC}"
echo -e "  Status: ${GREEN}✓ All AXON artifacts removed${NC}"
echo ""
echo -e "${YELLOW}Note: Docker and other products remain untouched.${NC}"
echo ""
