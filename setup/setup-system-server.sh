#!/bin/bash
# AXON - System Server Setup Script
# Runs from LOCAL MACHINE and prepares System Server (nginx) for zero-downtime deployments
# Safe to re-execute (idempotent)

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

# Configuration file
CONFIG_FILE="${CONFIG_FILE:-$DEPLOY_DIR/../deploy.config.yml}"

if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$DEPLOY_DIR/deploy.config.yml"
fi

echo -e "${CYAN}==================================================${NC}"
echo -e "${CYAN}System Server Setup (from Local Machine)${NC}"
echo -e "${CYAN}nginx Configuration for Zero-Downtime Deployments${NC}"
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
    echo ""
    echo -e "Please create deploy.config.yml first:"
    echo -e "${CYAN}cp ${DEPLOY_DIR}/config.example.yml deploy.config.yml${NC}"
    echo -e "${CYAN}vi deploy.config.yml${NC}"
    exit 1
fi

# Load configuration
echo -e "${BLUE}Loading configuration...${NC}"
PRODUCT_NAME=$(parse_config ".product.name" "")
APP_SERVER_HOST=$(parse_config ".servers.application.host" "")
APP_SERVER_PRIVATE_IP=$(parse_config ".servers.application.private_ip" "")

SYSTEM_SERVER_HOST=$(parse_config ".servers.system.host" "")
SYSTEM_SERVER_USER=$(parse_config ".servers.system.user" "root")
SYSTEM_SERVER_SSH_KEY=$(parse_config ".servers.system.ssh_key" "~/.ssh/system_server_key")

# Allow environment variable override
UPSTREAM_DIR=${UPSTREAM_DIR:-"/etc/nginx/upstreams"}
# Use private IP for nginx upstream (falls back to public host if not set)
APPLICATION_SERVER_IP=${APPLICATION_SERVER_IP:-"${APP_SERVER_PRIVATE_IP:-$APP_SERVER_HOST}"}
PRODUCT_NAME=${PRODUCT_NAME:-"$(parse_config ".product.name" "")"}

# Expand tilde in SSH key path
SYSTEM_SERVER_SSH_KEY="${SYSTEM_SERVER_SSH_KEY/#\~/$HOME}"

# Determine if we need sudo
if [ "$SYSTEM_SERVER_USER" = "root" ]; then
    USE_SUDO=""
else
    USE_SUDO="sudo"
fi

echo -e "  System Server: ${CYAN}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
echo -e "  Product Name: ${CYAN}${PRODUCT_NAME}${NC}"
echo -e "  Application Server IP: ${CYAN}${APPLICATION_SERVER_IP}${NC}"
echo ""

# Check prerequisites on local machine
echo -e "${BLUE}Checking local machine prerequisites...${NC}"

if [ -z "$SYSTEM_SERVER_HOST" ]; then
    echo -e "${RED}Error: System Server host not configured in deploy.config.yml${NC}"
    exit 1
fi

if ! command_exists ssh; then
    echo -e "  ${RED}✗ SSH client not found${NC}"
    echo -e "  Please install OpenSSH client"
    exit 1
fi
echo -e "  ${GREEN}✓ SSH client installed${NC}"

# Check SSH key exists
if [ ! -f "$SYSTEM_SERVER_SSH_KEY" ]; then
    echo -e "  ${RED}✗ SSH key not found: ${SYSTEM_SERVER_SSH_KEY}${NC}"
    echo -e "  Run setup-application-server.sh first to validate SSH keys"
    exit 1
fi
echo -e "  ${GREEN}✓ SSH key found${NC}"

echo ""

# Test SSH connection
echo -e "${BLUE}Testing SSH connection to System Server...${NC}"
echo -e "  Testing connection as ${SYSTEM_SERVER_USER}..."

if ! ssh -i "$SYSTEM_SERVER_SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes \
    "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" "echo 'SSH connection successful'" 2>/dev/null; then

    echo -e "  ${RED}✗ SSH connection failed${NC}"
    echo ""
    echo -e "  ${YELLOW}To fix:${NC}"
    echo -e "  1. Ensure System Server is running and accessible"
    echo -e "  2. Add public key to System Server ${SYSTEM_SERVER_USER} user:"
    echo -e "     ${CYAN}ssh-copy-id -i ${SYSTEM_SERVER_SSH_KEY}.pub ${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
    echo -e "  Or manually:"
    echo -e "     ${CYAN}cat ${SYSTEM_SERVER_SSH_KEY}.pub | ssh ${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST} \\${NC}"
    echo -e "     ${CYAN}  'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'${NC}"
    echo ""
    exit 1
fi

echo -e "  ${GREEN}✓ SSH connection successful as ${SYSTEM_SERVER_USER}${NC}"

echo ""

# Step 1: Check nginx installation on System Server
echo -e "${BLUE}Step 1/5: Checking nginx installation on System Server...${NC}"

NGINX_CHECK=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
    'nginx -v 2>&1' || echo "NOT_INSTALLED")

if [[ "$NGINX_CHECK" == *"NOT_INSTALLED"* ]] || [[ "$NGINX_CHECK" == *"command not found"* ]]; then
    echo -e "  ${RED}✗ nginx is not installed on System Server${NC}"
    echo ""
    echo -e "  To install nginx on System Server (Ubuntu/Debian):"
    echo -e "  ${CYAN}ssh ${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
    echo -e "  ${CYAN}${USE_SUDO} apt update && ${USE_SUDO} apt install -y nginx${NC}"
    echo -e "  ${CYAN}${USE_SUDO} systemctl start nginx${NC}"
    echo -e "  ${CYAN}${USE_SUDO} systemctl enable nginx${NC}"
    echo ""
    exit 1
fi

NGINX_VERSION=$(echo "$NGINX_CHECK" | grep -o 'nginx/[0-9.]*' | head -1 | cut -d'/' -f2)
echo -e "  ${GREEN}✓ nginx is installed${NC} (version: ${NGINX_VERSION})"

# Check if nginx is running
NGINX_RUNNING=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
    "${USE_SUDO} systemctl is-active nginx 2>/dev/null || pgrep nginx &>/dev/null && echo 'RUNNING' || echo 'NOT_RUNNING'")

if [[ "$NGINX_RUNNING" == *"RUNNING"* ]]; then
    echo -e "  ${GREEN}✓ nginx is running${NC}"
else
    echo -e "  ${YELLOW}⚠ nginx is not running${NC}"
    echo -e "  Start nginx: ${CYAN}ssh ${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST} '${USE_SUDO} systemctl start nginx'${NC}"
fi

echo ""

# Step 2: Create upstream directory
echo -e "${BLUE}Step 2/5: Creating upstream directory on System Server...${NC}"

UPSTREAM_EXISTS=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
    "[ -d '$UPSTREAM_DIR' ] && echo 'EXISTS' || echo 'NOT_EXISTS'")

if [ "$UPSTREAM_EXISTS" = "EXISTS" ]; then
    echo -e "  ${GREEN}✓ Upstream directory exists${NC}"
else
    echo -e "  ${YELLOW}Creating upstream directory...${NC}"
    ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
        "${USE_SUDO} mkdir -p $UPSTREAM_DIR"
    echo -e "  ${GREEN}✓ Upstream directory created${NC}"
fi

echo -e "  Location: ${CYAN}${UPSTREAM_DIR}${NC}"

echo ""

# Step 3: Set permissions on upstream directory
echo -e "${BLUE}Step 3/5: Setting upstream directory permissions...${NC}"

ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
    "${USE_SUDO} chmod 755 ${UPSTREAM_DIR}"

echo -e "  ${GREEN}✓ Permissions set to 755${NC}"

echo ""

# Step 4: Create upstream configuration files (if product name provided)
echo -e "${BLUE}Step 4/5: Creating upstream configuration files...${NC}"

if [ -n "$PRODUCT_NAME" ] && [ -n "$APPLICATION_SERVER_IP" ]; then
    # Production upstream
    PROD_UPSTREAM="${UPSTREAM_DIR}/${PRODUCT_NAME}-production.conf"
    PROD_EXISTS=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
        "[ -f '$PROD_UPSTREAM' ] && echo 'EXISTS' || echo 'NOT_EXISTS'")

    if [ "$PROD_EXISTS" = "EXISTS" ]; then
        echo -e "  ${GREEN}✓ Production upstream exists${NC}"
    else
        echo -e "  ${YELLOW}Creating production upstream...${NC}"

        # Convert hyphens to underscores in upstream name
        PROD_UPSTREAM_NAME="${PRODUCT_NAME//-/_}_production_backend"
        PROD_UPSTREAM_CONTENT="upstream ${PROD_UPSTREAM_NAME} {
    server ${APPLICATION_SERVER_IP}:5100;
}"

        ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
            "${USE_SUDO} bash -c \"echo '$PROD_UPSTREAM_CONTENT' > $PROD_UPSTREAM\""

        echo -e "  ${GREEN}✓ Created: ${PROD_UPSTREAM}${NC}"
    fi

    # Staging upstream
    STAGING_UPSTREAM="${UPSTREAM_DIR}/${PRODUCT_NAME}-staging.conf"
    STAGING_EXISTS=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
        "[ -f '$STAGING_UPSTREAM' ] && echo 'EXISTS' || echo 'NOT_EXISTS'")

    if [ "$STAGING_EXISTS" = "EXISTS" ]; then
        echo -e "  ${GREEN}✓ Staging upstream exists${NC}"
    else
        echo -e "  ${YELLOW}Creating staging upstream...${NC}"

        # Convert hyphens to underscores in upstream name
        STAGING_UPSTREAM_NAME="${PRODUCT_NAME//-/_}_staging_backend"
        STAGING_UPSTREAM_CONTENT="upstream ${STAGING_UPSTREAM_NAME} {
    server ${APPLICATION_SERVER_IP}:5101;
}"

        ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
            "${USE_SUDO} bash -c \"echo '$STAGING_UPSTREAM_CONTENT' > $STAGING_UPSTREAM\""

        echo -e "  ${GREEN}✓ Created: ${STAGING_UPSTREAM}${NC}"
    fi
else
    echo -e "  ${YELLOW}⚠ Skipping upstream creation${NC}"
    echo -e "  Set PRODUCT_NAME and APPLICATION_SERVER_IP to auto-create upstreams"
fi

echo ""

# Step 5: Test nginx configuration
echo -e "${BLUE}Step 5/5: Testing nginx configuration...${NC}"

NGINX_TEST=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
    "${USE_SUDO} nginx -t 2>&1")

if echo "$NGINX_TEST" | grep -q "successful"; then
    echo -e "  ${GREEN}✓ nginx configuration is valid${NC}"
else
    echo -e "  ${YELLOW}⚠ nginx configuration warnings/errors:${NC}"
    echo "$NGINX_TEST"
fi

echo ""

# Summary
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}✓ System Server setup complete!${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""

echo -e "${CYAN}Configuration Summary:${NC}"
echo -e "  Local Machine:      ${YELLOW}$(hostname)${NC}"
echo -e "  System Server:      ${YELLOW}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
echo -e "  Upstream Dir:       ${YELLOW}${UPSTREAM_DIR}${NC}"

if [ -n "$PRODUCT_NAME" ]; then
echo -e "  Product:            ${YELLOW}${PRODUCT_NAME}${NC}"
echo -e "  Prod Upstream:      ${YELLOW}${UPSTREAM_DIR}/${PRODUCT_NAME}-production.conf${NC}"
echo -e "  Staging Upstream:   ${YELLOW}${UPSTREAM_DIR}/${PRODUCT_NAME}-staging.conf${NC}"
fi

echo ""

echo -e "${CYAN}Next steps:${NC}"
echo ""

echo -e "1. Update nginx site configuration to include upstreams:"
echo -e "   ${CYAN}ssh ${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
echo -e "   ${CYAN}${USE_SUDO} vi /etc/nginx/sites-available/your-site.conf${NC}"
echo ""
echo -e "   Add to your site config:"
echo -e "   ${YELLOW}include ${UPSTREAM_DIR}/${PRODUCT_NAME:-myapp}-production.conf;${NC}"
echo -e "   ${YELLOW}server {${NC}"
echo -e "   ${YELLOW}    server_name production.yourdomain.com;${NC}"
echo -e "   ${YELLOW}    location / {${NC}"
echo -e "   ${YELLOW}        proxy_pass http://${PRODUCT_NAME:-myapp}_production_backend;${NC}"
echo -e "   ${YELLOW}    }${NC}"
echo -e "   ${YELLOW}}${NC}"
echo ""

echo -e "2. Test and reload nginx:"
echo -e "   ${CYAN}ssh ${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST} '${USE_SUDO} nginx -t && ${USE_SUDO} nginx -s reload'${NC}"
echo ""

echo -e "3. Test deployment from local machine:"
echo -e "   ${CYAN}./tools/deploy.sh staging${NC}"
echo ""

echo -e "${GREEN}System Server is ready for zero-downtime deployments!${NC}"
echo ""
