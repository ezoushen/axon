#!/bin/bash
# AXON - System Server Uninstall Script
# Runs from LOCAL MACHINE and removes AXON nginx configurations from System Server
# WARNING: This removes ALL AXON-managed nginx configs for this product

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
echo -e "${CYAN}System Server Uninstallation${NC}"
echo -e "${CYAN}Removing AXON nginx Configurations${NC}"
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
SYSTEM_SERVER_HOST=$(parse_config ".servers.system.host" "")
SYSTEM_SERVER_USER=$(parse_config ".servers.system.user" "")
SYSTEM_SERVER_SSH_KEY=$(parse_config ".servers.system.ssh_key" "")
PRODUCT_NAME=$(parse_config ".product.name" "")
NGINX_AXON_DIR=$(parse_config ".nginx.paths.axon_dir" "/etc/nginx/axon.d")

# Expand tilde in SSH key path
SYSTEM_SERVER_SSH_KEY="${SYSTEM_SERVER_SSH_KEY/#\~/$HOME}"

echo -e "  System Server: ${CYAN}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
echo -e "  Product: ${CYAN}${PRODUCT_NAME}${NC}"
echo -e "  nginx AXON Directory: ${CYAN}${NGINX_AXON_DIR}${NC}"
echo ""

# Warning
echo -e "${YELLOW}WARNING: This will remove:${NC}"
echo -e "  - All nginx site configs for this product"
echo -e "  - All nginx upstream configs for this product"
echo -e "  - Files matching: ${NGINX_AXON_DIR}/sites/${PRODUCT_NAME}-*.conf"
echo -e "  - Files matching: ${NGINX_AXON_DIR}/upstreams/${PRODUCT_NAME}-*.conf"
echo ""
echo -e "${YELLOW}This will NOT remove:${NC}"
echo -e "  - nginx itself"
echo -e "  - AXON directory structure (${NGINX_AXON_DIR})"
echo -e "  - Other products' nginx configs"
echo -e "  - nginx.conf include directives"
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
echo -e "${BLUE}Step 1/3: Checking SSH connectivity...${NC}"

if ! ssh -i "$SYSTEM_SERVER_SSH_KEY" -o ConnectTimeout=10 \
    "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" "echo 'SSH OK'" > /dev/null 2>&1; then
    echo -e "  ${RED}✗ Cannot connect to System Server${NC}"
    echo -e "  Host: ${SYSTEM_SERVER_HOST}"
    echo -e "  User: ${SYSTEM_SERVER_USER}"
    echo -e "  Key: ${SYSTEM_SERVER_SSH_KEY}"
    exit 1
fi
echo -e "  ${GREEN}✓ SSH connection successful${NC}"
echo ""

# Step 2: Remove nginx site configs
echo -e "${BLUE}Step 2/3: Removing nginx site configurations...${NC}"

ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
    "bash -s" <<EOF
set -e

# Check if nginx is installed
if ! command -v nginx > /dev/null 2>&1; then
    echo "  nginx not installed on system (nothing to remove)"
    exit 0
fi

# Check if AXON directory exists
if [ ! -d "${NGINX_AXON_DIR}/sites" ]; then
    echo "  AXON sites directory not found (nothing to remove)"
else
    # Find all site configs for this product
    SITE_CONFIGS=\$(ls ${NGINX_AXON_DIR}/sites/${PRODUCT_NAME}-*.conf 2>/dev/null || true)

    if [ -z "\$SITE_CONFIGS" ]; then
        echo "  No site configs found for product: ${PRODUCT_NAME}"
    else
        echo "  Found site configs:"
        echo "\$SITE_CONFIGS" | sed 's/^/    - /'
        echo ""
        echo "  Removing site configs..."
        sudo rm -f ${NGINX_AXON_DIR}/sites/${PRODUCT_NAME}-*.conf
        echo "  ✓ Site configs removed"
    fi
fi
EOF

echo -e "  ${GREEN}✓ Site configurations cleaned up${NC}"
echo ""

# Step 3: Remove nginx upstream configs
echo -e "${BLUE}Step 3/3: Removing nginx upstream configurations...${NC}"

ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
    "bash -s" <<EOF
set -e

# Check if AXON directory exists
if [ ! -d "${NGINX_AXON_DIR}/upstreams" ]; then
    echo "  AXON upstreams directory not found (nothing to remove)"
else
    # Find all upstream configs for this product
    UPSTREAM_CONFIGS=\$(ls ${NGINX_AXON_DIR}/upstreams/${PRODUCT_NAME}-*.conf 2>/dev/null || true)

    if [ -z "\$UPSTREAM_CONFIGS" ]; then
        echo "  No upstream configs found for product: ${PRODUCT_NAME}"
    else
        echo "  Found upstream configs:"
        echo "\$UPSTREAM_CONFIGS" | sed 's/^/    - /'
        echo ""
        echo "  Removing upstream configs..."
        sudo rm -f ${NGINX_AXON_DIR}/upstreams/${PRODUCT_NAME}-*.conf
        echo "  ✓ Upstream configs removed"
    fi
fi

# Test nginx config
echo ""
echo "  Testing nginx configuration..."
if sudo nginx -t 2>&1 | grep -q 'successful'; then
    echo "  ✓ nginx configuration valid"
    echo ""
    echo "  Reloading nginx..."
    sudo nginx -s reload
    echo "  ✓ nginx reloaded"
else
    echo "  ${RED}✗ nginx configuration test failed${NC}"
    echo "  Please check nginx configuration manually"
    exit 1
fi
EOF

echo -e "  ${GREEN}✓ Upstream configurations cleaned up${NC}"
echo ""

# Success
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}System Server Uninstallation Complete${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
echo -e "${BLUE}Summary:${NC}"
echo -e "  Product: ${YELLOW}${PRODUCT_NAME}${NC}"
echo -e "  Server: ${YELLOW}${SYSTEM_SERVER_HOST}${NC}"
echo -e "  Status: ${GREEN}✓ All AXON nginx configs removed${NC}"
echo ""
echo -e "${YELLOW}Note: nginx and AXON infrastructure remain for other products.${NC}"
echo ""
