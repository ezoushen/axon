#!/bin/bash
# System Server Setup Script
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

SYSTEM_SERVER_HOST=$(parse_config ".servers.system.host" "")
SYSTEM_SERVER_USER=$(parse_config ".servers.system.user" "deploy")
SYSTEM_SERVER_SSH_KEY=$(parse_config ".servers.system.ssh_key" "~/.ssh/deployment_key")

# Allow environment variable override
DEPLOY_USER=${DEPLOY_USER:-"$SYSTEM_SERVER_USER"}
UPSTREAM_DIR=${UPSTREAM_DIR:-"/etc/nginx/upstreams"}
APPLICATION_SERVER_IP=${APPLICATION_SERVER_IP:-"$APP_SERVER_HOST"}
PRODUCT_NAME=${PRODUCT_NAME:-"$(parse_config ".product.name" "")"}

# Expand tilde in SSH key path
SYSTEM_SERVER_SSH_KEY="${SYSTEM_SERVER_SSH_KEY/#\~/$HOME}"

echo -e "  System Server: ${CYAN}${DEPLOY_USER}@${SYSTEM_SERVER_HOST}${NC}"
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
    echo -e "  Run setup-application-server.sh first to generate SSH keys"
    exit 1
fi
echo -e "  ${GREEN}✓ SSH key found${NC}"

echo ""

# Test SSH connection
echo -e "${BLUE}Testing SSH connection to System Server...${NC}"

# First test with regular user (for initial setup)
echo -e "  Testing connection as root/sudo user..."

# Try connecting - if we can't connect, show instructions
if ! ssh -i "$SYSTEM_SERVER_SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes \
    "root@${SYSTEM_SERVER_HOST}" "echo 'SSH connection successful'" 2>/dev/null; then

    # Try with deploy user
    if ssh -i "$SYSTEM_SERVER_SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes \
        "${DEPLOY_USER}@${SYSTEM_SERVER_HOST}" "echo 'SSH connection successful'" 2>/dev/null; then
        echo -e "  ${GREEN}✓ SSH connection successful as ${DEPLOY_USER}${NC}"
        SSH_USER="$DEPLOY_USER"
        USE_SUDO="sudo"
    else
        echo -e "  ${RED}✗ SSH connection failed${NC}"
        echo ""
        echo -e "  ${YELLOW}To fix:${NC}"
        echo -e "  1. Ensure System Server is running and accessible"
        echo -e "  2. Add public key to System Server root user:"
        echo -e "     ${CYAN}cat ${SYSTEM_SERVER_SSH_KEY}.pub | ssh root@${SYSTEM_SERVER_HOST} \\${NC}"
        echo -e "     ${CYAN}  'cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'${NC}"
        echo -e "  3. Or manually copy the key:"
        echo -e "     ${CYAN}$(cat ${SYSTEM_SERVER_SSH_KEY}.pub)${NC}"
        echo ""
        exit 1
    fi
else
    echo -e "  ${GREEN}✓ SSH connection successful as root${NC}"
    SSH_USER="root"
    USE_SUDO=""
fi

echo ""

# Step 1: Check nginx installation on System Server
echo -e "${BLUE}Step 1/7: Checking nginx installation on System Server...${NC}"

NGINX_CHECK=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
    'nginx -v 2>&1' || echo "NOT_INSTALLED")

if [[ "$NGINX_CHECK" == *"NOT_INSTALLED"* ]] || [[ "$NGINX_CHECK" == *"command not found"* ]]; then
    echo -e "  ${RED}✗ nginx is not installed on System Server${NC}"
    echo ""
    echo -e "  To install nginx on System Server (Ubuntu/Debian):"
    echo -e "  ${CYAN}ssh ${SSH_USER}@${SYSTEM_SERVER_HOST}${NC}"
    echo -e "  ${CYAN}sudo apt update && sudo apt install -y nginx${NC}"
    echo -e "  ${CYAN}sudo systemctl start nginx${NC}"
    echo -e "  ${CYAN}sudo systemctl enable nginx${NC}"
    echo ""
    exit 1
fi

NGINX_VERSION=$(echo "$NGINX_CHECK" | grep -oP 'nginx/\K[0-9.]+' | head -1)
echo -e "  ${GREEN}✓ nginx is installed${NC} (version: ${NGINX_VERSION})"

# Check if nginx is running
NGINX_RUNNING=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
    "${USE_SUDO} systemctl is-active nginx 2>/dev/null || pgrep nginx &>/dev/null && echo 'RUNNING' || echo 'NOT_RUNNING'")

if [[ "$NGINX_RUNNING" == *"RUNNING"* ]]; then
    echo -e "  ${GREEN}✓ nginx is running${NC}"
else
    echo -e "  ${YELLOW}⚠ nginx is not running${NC}"
    echo -e "  Start nginx: ${CYAN}ssh ${SSH_USER}@${SYSTEM_SERVER_HOST} '${USE_SUDO} systemctl start nginx'${NC}"
fi

echo ""

# Step 2: Create upstream directory
echo -e "${BLUE}Step 2/7: Creating upstream directory on System Server...${NC}"

UPSTREAM_EXISTS=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
    "[ -d '$UPSTREAM_DIR' ] && echo 'EXISTS' || echo 'NOT_EXISTS'")

if [ "$UPSTREAM_EXISTS" = "EXISTS" ]; then
    echo -e "  ${GREEN}✓ Upstream directory exists${NC}"
else
    echo -e "  ${YELLOW}Creating upstream directory...${NC}"
    ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
        "${USE_SUDO} mkdir -p $UPSTREAM_DIR"
    echo -e "  ${GREEN}✓ Upstream directory created${NC}"
fi

echo -e "  Location: ${CYAN}${UPSTREAM_DIR}${NC}"

echo ""

# Step 3: Create deploy user (if not exists)
echo -e "${BLUE}Step 3/7: Creating deploy user on System Server...${NC}"

USER_EXISTS=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
    "id ${DEPLOY_USER} &>/dev/null && echo 'EXISTS' || echo 'NOT_EXISTS'")

if [ "$USER_EXISTS" = "EXISTS" ]; then
    echo -e "  ${GREEN}✓ User '${DEPLOY_USER}' already exists${NC}"
else
    echo -e "  ${YELLOW}Creating user '${DEPLOY_USER}'...${NC}"
    ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
        "${USE_SUDO} useradd -m -s /bin/bash ${DEPLOY_USER}"
    echo -e "  ${GREEN}✓ User '${DEPLOY_USER}' created${NC}"
fi

# Create .ssh directory for deploy user
echo -e "  ${YELLOW}Setting up SSH for deploy user...${NC}"

ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
    "${USE_SUDO} mkdir -p /home/${DEPLOY_USER}/.ssh && \
     ${USE_SUDO} touch /home/${DEPLOY_USER}/.ssh/authorized_keys && \
     ${USE_SUDO} chown -R ${DEPLOY_USER}:${DEPLOY_USER} /home/${DEPLOY_USER}/.ssh && \
     ${USE_SUDO} chmod 700 /home/${DEPLOY_USER}/.ssh && \
     ${USE_SUDO} chmod 600 /home/${DEPLOY_USER}/.ssh/authorized_keys"

echo -e "  ${GREEN}✓ SSH directory configured${NC}"

echo ""

# Step 4: Configure sudo permissions for deploy user
echo -e "${BLUE}Step 4/7: Configuring sudo permissions...${NC}"

SUDOERS_FILE="/etc/sudoers.d/${DEPLOY_USER}"

SUDOERS_EXISTS=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
    "[ -f '$SUDOERS_FILE' ] && echo 'EXISTS' || echo 'NOT_EXISTS'")

if [ "$SUDOERS_EXISTS" = "EXISTS" ]; then
    echo -e "  ${GREEN}✓ Sudoers file exists${NC}"
else
    echo -e "  ${YELLOW}Creating sudoers file...${NC}"

    # Create sudoers file on System Server
    ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
        "${USE_SUDO} bash -c \"echo '${DEPLOY_USER} ALL=(ALL) NOPASSWD: /usr/sbin/nginx -t, /usr/sbin/nginx -s reload' > ${SUDOERS_FILE} && \
                       chmod 440 ${SUDOERS_FILE} && \
                       visudo -c -f ${SUDOERS_FILE}\""

    echo -e "  ${GREEN}✓ Sudoers file created and validated${NC}"
fi

echo -e "  Location: ${CYAN}${SUDOERS_FILE}${NC}"

echo ""

# Step 5: Set ownership of upstream directory
echo -e "${BLUE}Step 5/7: Setting upstream directory ownership...${NC}"

ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
    "${USE_SUDO} chown -R ${DEPLOY_USER}:${DEPLOY_USER} ${UPSTREAM_DIR} && \
     ${USE_SUDO} chmod 755 ${UPSTREAM_DIR}"

echo -e "  ${GREEN}✓ Ownership updated to ${DEPLOY_USER}:${DEPLOY_USER}${NC}"

echo ""

# Step 6: Create upstream configuration files (if product name provided)
echo -e "${BLUE}Step 6/7: Creating upstream configuration files...${NC}"

if [ -n "$PRODUCT_NAME" ] && [ -n "$APPLICATION_SERVER_IP" ]; then
    # Production upstream
    PROD_UPSTREAM="${UPSTREAM_DIR}/${PRODUCT_NAME}-production.conf"
    PROD_EXISTS=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
        "[ -f '$PROD_UPSTREAM' ] && echo 'EXISTS' || echo 'NOT_EXISTS'")

    if [ "$PROD_EXISTS" = "EXISTS" ]; then
        echo -e "  ${GREEN}✓ Production upstream exists${NC}"
    else
        echo -e "  ${YELLOW}Creating production upstream...${NC}"

        PROD_UPSTREAM_CONTENT="upstream ${PRODUCT_NAME}_production_backend {
    server ${APPLICATION_SERVER_IP}:5100;
}"

        ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
            "${USE_SUDO} bash -c \"echo '$PROD_UPSTREAM_CONTENT' > $PROD_UPSTREAM && \
                           chown ${DEPLOY_USER}:${DEPLOY_USER} $PROD_UPSTREAM\""

        echo -e "  ${GREEN}✓ Created: ${PROD_UPSTREAM}${NC}"
    fi

    # Staging upstream
    STAGING_UPSTREAM="${UPSTREAM_DIR}/${PRODUCT_NAME}-staging.conf"
    STAGING_EXISTS=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
        "[ -f '$STAGING_UPSTREAM' ] && echo 'EXISTS' || echo 'NOT_EXISTS'")

    if [ "$STAGING_EXISTS" = "EXISTS" ]; then
        echo -e "  ${GREEN}✓ Staging upstream exists${NC}"
    else
        echo -e "  ${YELLOW}Creating staging upstream...${NC}"

        STAGING_UPSTREAM_CONTENT="upstream ${PRODUCT_NAME}_staging_backend {
    server ${APPLICATION_SERVER_IP}:5101;
}"

        ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
            "${USE_SUDO} bash -c \"echo '$STAGING_UPSTREAM_CONTENT' > $STAGING_UPSTREAM && \
                           chown ${DEPLOY_USER}:${DEPLOY_USER} $STAGING_UPSTREAM\""

        echo -e "  ${GREEN}✓ Created: ${STAGING_UPSTREAM}${NC}"
    fi
else
    echo -e "  ${YELLOW}⚠ Skipping upstream creation${NC}"
    echo -e "  Set PRODUCT_NAME and APPLICATION_SERVER_IP to auto-create upstreams"
fi

echo ""

# Step 7: Test nginx configuration
echo -e "${BLUE}Step 7/7: Testing nginx configuration...${NC}"

NGINX_TEST=$(ssh -i "$SYSTEM_SERVER_SSH_KEY" "${SSH_USER}@${SYSTEM_SERVER_HOST}" \
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
echo -e "  System Server:      ${YELLOW}${DEPLOY_USER}@${SYSTEM_SERVER_HOST}${NC}"
echo -e "  Deploy User:        ${YELLOW}${DEPLOY_USER}${NC}"
echo -e "  Upstream Dir:       ${YELLOW}${UPSTREAM_DIR}${NC}"
echo -e "  Sudoers File:       ${YELLOW}${SUDOERS_FILE}${NC}"

if [ -n "$PRODUCT_NAME" ]; then
echo -e "  Product:            ${YELLOW}${PRODUCT_NAME}${NC}"
echo -e "  Prod Upstream:      ${YELLOW}${UPSTREAM_DIR}/${PRODUCT_NAME}-production.conf${NC}"
echo -e "  Staging Upstream:   ${YELLOW}${UPSTREAM_DIR}/${PRODUCT_NAME}-staging.conf${NC}"
fi

echo ""

echo -e "${CYAN}Next steps:${NC}"
echo ""

echo -e "1. Add SSH public key to System Server deploy user:"
echo -e "   ${CYAN}cat ${SYSTEM_SERVER_SSH_KEY}.pub | ssh ${SSH_USER}@${SYSTEM_SERVER_HOST} \\${NC}"
echo -e "   ${CYAN}  '${USE_SUDO} tee -a /home/${DEPLOY_USER}/.ssh/authorized_keys && \\${NC}"
echo -e "   ${CYAN}   ${USE_SUDO} chmod 600 /home/${DEPLOY_USER}/.ssh/authorized_keys'${NC}"
echo ""

echo -e "2. Update nginx site configuration to include upstreams:"
echo -e "   ${CYAN}ssh ${SSH_USER}@${SYSTEM_SERVER_HOST}${NC}"
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

echo -e "3. Test and reload nginx:"
echo -e "   ${CYAN}ssh ${SSH_USER}@${SYSTEM_SERVER_HOST} '${USE_SUDO} nginx -t && ${USE_SUDO} nginx -s reload'${NC}"
echo ""

echo -e "4. Test deployment from local machine:"
echo -e "   ${CYAN}./deploy/deploy.sh staging${NC}"
echo ""

echo -e "${GREEN}System Server is ready for zero-downtime deployments!${NC}"
echo ""
