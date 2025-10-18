#!/bin/bash
# Application Server Setup Script
# Runs from LOCAL MACHINE and prepares Application Server for zero-downtime deployments
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
echo -e "${CYAN}Application Server Setup (from Local Machine)${NC}"
echo -e "${CYAN}Zero-Downtime Deployment Prerequisites${NC}"
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
APP_SERVER_HOST=$(parse_config ".servers.application.host" "")
APP_SERVER_USER=$(parse_config ".servers.application.user" "ubuntu")
APP_SERVER_SSH_KEY=$(parse_config ".servers.application.ssh_key" "~/.ssh/application_server_key")
APP_SERVER_DEPLOY_PATH=$(parse_config ".servers.application.deploy_path" "/home/ubuntu/app")

SYSTEM_SERVER_HOST=$(parse_config ".servers.system.host" "")
SYSTEM_SERVER_USER=$(parse_config ".servers.system.user" "deploy")
SYSTEM_SERVER_SSH_KEY=$(parse_config ".servers.system.ssh_key" "~/.ssh/deployment_key")

AWS_PROFILE=$(parse_config ".aws.profile" "default")

# Expand tilde in SSH key paths
APP_SERVER_SSH_KEY="${APP_SERVER_SSH_KEY/#\~/$HOME}"
SYSTEM_SERVER_SSH_KEY="${SYSTEM_SERVER_SSH_KEY/#\~/$HOME}"

echo -e "  Application Server: ${CYAN}${APP_SERVER_USER}@${APP_SERVER_HOST}${NC}"
echo -e "  System Server: ${CYAN}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
echo ""

# Step 1: Check local machine prerequisites
echo -e "${BLUE}Step 1/8: Checking local machine prerequisites...${NC}"

if ! command_exists ssh; then
    echo -e "  ${RED}✗ SSH client not found${NC}"
    echo -e "  Please install OpenSSH client"
    exit 1
fi
echo -e "  ${GREEN}✓ SSH client installed${NC}"

if ! command_exists scp; then
    echo -e "  ${RED}✗ SCP not found${NC}"
    echo -e "  Please install OpenSSH client"
    exit 1
fi
echo -e "  ${GREEN}✓ SCP installed${NC}"

echo ""

# Step 2: Generate/check SSH key for Application Server
echo -e "${BLUE}Step 2/8: Checking SSH key for Application Server...${NC}"

if [ -f "$APP_SERVER_SSH_KEY" ]; then
    echo -e "  ${GREEN}✓ SSH key exists${NC}"
    echo -e "  Location: ${CYAN}${APP_SERVER_SSH_KEY}${NC}"

    # Check permissions
    KEY_PERMS=$(stat -c %a "$APP_SERVER_SSH_KEY" 2>/dev/null || stat -f %A "$APP_SERVER_SSH_KEY" 2>/dev/null)
    if [ "$KEY_PERMS" = "600" ]; then
        echo -e "  ${GREEN}✓ Correct permissions (600)${NC}"
    else
        echo -e "  ${YELLOW}⚠ Fixing permissions...${NC}"
        chmod 600 "$APP_SERVER_SSH_KEY"
        echo -e "  ${GREEN}✓ Permissions fixed${NC}"
    fi
else
    echo -e "  ${YELLOW}✗ SSH key not found${NC}"
    echo -e "  ${YELLOW}Generating new SSH key for Application Server...${NC}"

    SSH_KEY_DIR=$(dirname "$APP_SERVER_SSH_KEY")
    mkdir -p "$SSH_KEY_DIR"

    ssh-keygen -t ed25519 -C "application-server-key" -f "$APP_SERVER_SSH_KEY" -N ""
    chmod 600 "$APP_SERVER_SSH_KEY"

    echo -e "  ${GREEN}✓ SSH key generated${NC}"
    echo -e "  Location: ${CYAN}${APP_SERVER_SSH_KEY}${NC}"
    echo ""
    echo -e "  ${YELLOW}IMPORTANT: Add this public key to Application Server:${NC}"
    echo -e "  ${CYAN}$(cat ${APP_SERVER_SSH_KEY}.pub)${NC}"
    echo ""
    echo -e "  Run on Application Server:"
    echo -e "  ${CYAN}echo '$(cat ${APP_SERVER_SSH_KEY}.pub)' >> ~/.ssh/authorized_keys${NC}"
    echo ""
fi

echo ""

# Step 3: Generate/check SSH key for System Server
echo -e "${BLUE}Step 3/8: Checking SSH key for System Server...${NC}"

if [ -f "$SYSTEM_SERVER_SSH_KEY" ]; then
    echo -e "  ${GREEN}✓ SSH key exists${NC}"
    echo -e "  Location: ${CYAN}${SYSTEM_SERVER_SSH_KEY}${NC}"

    # Check permissions
    KEY_PERMS=$(stat -c %a "$SYSTEM_SERVER_SSH_KEY" 2>/dev/null || stat -f %A "$SYSTEM_SERVER_SSH_KEY" 2>/dev/null)
    if [ "$KEY_PERMS" = "600" ]; then
        echo -e "  ${GREEN}✓ Correct permissions (600)${NC}"
    else
        echo -e "  ${YELLOW}⚠ Fixing permissions...${NC}"
        chmod 600 "$SYSTEM_SERVER_SSH_KEY"
        echo -e "  ${GREEN}✓ Permissions fixed${NC}"
    fi
else
    echo -e "  ${YELLOW}✗ SSH key not found${NC}"
    echo -e "  ${YELLOW}Generating new SSH key for System Server...${NC}"

    SSH_KEY_DIR=$(dirname "$SYSTEM_SERVER_SSH_KEY")
    mkdir -p "$SSH_KEY_DIR"

    ssh-keygen -t ed25519 -C "system-server-key" -f "$SYSTEM_SERVER_SSH_KEY" -N ""
    chmod 600 "$SYSTEM_SERVER_SSH_KEY"

    echo -e "  ${GREEN}✓ SSH key generated${NC}"
    echo -e "  Location: ${CYAN}${SYSTEM_SERVER_SSH_KEY}${NC}"
    echo ""
    echo -e "  ${YELLOW}IMPORTANT: Add this public key to System Server:${NC}"
    echo -e "  ${CYAN}$(cat ${SYSTEM_SERVER_SSH_KEY}.pub)${NC}"
    echo ""
    echo -e "  Run on System Server (as deploy user):"
    echo -e "  ${CYAN}echo '$(cat ${SYSTEM_SERVER_SSH_KEY}.pub)' >> /home/${SYSTEM_SERVER_USER}/.ssh/authorized_keys${NC}"
    echo ""
fi

echo ""

# Step 4: Test SSH connection to Application Server
echo -e "${BLUE}Step 4/8: Testing SSH connection to Application Server...${NC}"

if [ -z "$APP_SERVER_HOST" ]; then
    echo -e "  ${RED}✗ Application Server host not configured in deploy.config.yml${NC}"
    exit 1
fi

echo -e "  Testing: ${CYAN}${APP_SERVER_USER}@${APP_SERVER_HOST}${NC}"

if ssh -i "$APP_SERVER_SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes \
    "${APP_SERVER_USER}@${APP_SERVER_HOST}" "echo 'SSH connection successful'" 2>/dev/null; then
    echo -e "  ${GREEN}✓ SSH connection successful${NC}"
else
    echo -e "  ${RED}✗ SSH connection failed${NC}"
    echo ""
    echo -e "  ${YELLOW}To fix:${NC}"
    echo -e "  1. Ensure Application Server is running and accessible"
    echo -e "  2. Add the public key to Application Server:"
    echo -e "     ${CYAN}ssh ${APP_SERVER_USER}@${APP_SERVER_HOST}${NC}"
    echo -e "     ${CYAN}mkdir -p ~/.ssh && chmod 700 ~/.ssh${NC}"
    echo -e "     ${CYAN}echo '$(cat ${APP_SERVER_SSH_KEY}.pub)' >> ~/.ssh/authorized_keys${NC}"
    echo -e "     ${CYAN}chmod 600 ~/.ssh/authorized_keys${NC}"
    echo -e "  3. Re-run this setup script"
    echo ""
    exit 1
fi

echo ""

# Step 5: Check Docker on Application Server
echo -e "${BLUE}Step 5/8: Checking Docker on Application Server...${NC}"

DOCKER_CHECK=$(ssh -i "$APP_SERVER_SSH_KEY" "${APP_SERVER_USER}@${APP_SERVER_HOST}" \
    'docker --version 2>&1' || echo "NOT_INSTALLED")

if [[ "$DOCKER_CHECK" == *"NOT_INSTALLED"* ]] || [[ "$DOCKER_CHECK" == *"command not found"* ]]; then
    echo -e "  ${RED}✗ Docker is not installed on Application Server${NC}"
    echo ""
    echo -e "  To install Docker on Application Server:"
    echo -e "  ${CYAN}ssh ${APP_SERVER_USER}@${APP_SERVER_HOST}${NC}"
    echo -e "  ${CYAN}curl -fsSL https://get.docker.com -o get-docker.sh${NC}"
    echo -e "  ${CYAN}sudo sh get-docker.sh${NC}"
    echo -e "  ${CYAN}sudo usermod -aG docker ${APP_SERVER_USER}${NC}"
    echo -e "  ${CYAN}# Log out and log back in${NC}"
    echo ""
    exit 1
else
    DOCKER_VERSION=$(echo "$DOCKER_CHECK" | grep -oP 'version \K[0-9.]+' | head -1)
    echo -e "  ${GREEN}✓ Docker is installed${NC} (version: ${DOCKER_VERSION})"
fi

# Check if Docker daemon is running
DOCKER_RUNNING=$(ssh -i "$APP_SERVER_SSH_KEY" "${APP_SERVER_USER}@${APP_SERVER_HOST}" \
    'docker info &>/dev/null && echo "RUNNING" || echo "NOT_RUNNING"')

if [ "$DOCKER_RUNNING" = "RUNNING" ]; then
    echo -e "  ${GREEN}✓ Docker daemon is running${NC}"
else
    echo -e "  ${YELLOW}⚠ Docker daemon is not running${NC}"
    echo -e "  Start Docker: ${CYAN}ssh ${APP_SERVER_USER}@${APP_SERVER_HOST} 'sudo systemctl start docker'${NC}"
fi

echo ""

# Step 6: Check Docker Compose on Application Server
echo -e "${BLUE}Step 6/8: Checking Docker Compose on Application Server...${NC}"

COMPOSE_CHECK=$(ssh -i "$APP_SERVER_SSH_KEY" "${APP_SERVER_USER}@${APP_SERVER_HOST}" \
    'docker compose version 2>&1 || docker-compose --version 2>&1' || echo "NOT_INSTALLED")

if [[ "$COMPOSE_CHECK" == *"NOT_INSTALLED"* ]] || [[ "$COMPOSE_CHECK" == *"command not found"* ]]; then
    echo -e "  ${RED}✗ Docker Compose is not installed on Application Server${NC}"
    echo ""
    echo -e "  To install Docker Compose on Application Server:"
    echo -e "  ${CYAN}ssh ${APP_SERVER_USER}@${APP_SERVER_HOST}${NC}"
    echo -e "  ${CYAN}DOCKER_CONFIG=\${DOCKER_CONFIG:-\$HOME/.docker}${NC}"
    echo -e "  ${CYAN}mkdir -p \$DOCKER_CONFIG/cli-plugins${NC}"
    echo -e "  ${CYAN}curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \\${NC}"
    echo -e "  ${CYAN}  -o \$DOCKER_CONFIG/cli-plugins/docker-compose${NC}"
    echo -e "  ${CYAN}chmod +x \$DOCKER_CONFIG/cli-plugins/docker-compose${NC}"
    echo ""
    exit 1
else
    COMPOSE_VERSION=$(echo "$COMPOSE_CHECK" | grep -oP 'version \K[^ ,]+' | head -1)
    echo -e "  ${GREEN}✓ Docker Compose is installed${NC} (version: ${COMPOSE_VERSION})"
fi

echo ""

# Step 7: Check AWS CLI on Application Server
echo -e "${BLUE}Step 7/8: Checking AWS CLI on Application Server...${NC}"

AWS_CHECK=$(ssh -i "$APP_SERVER_SSH_KEY" "${APP_SERVER_USER}@${APP_SERVER_HOST}" \
    'aws --version 2>&1' || echo "NOT_INSTALLED")

if [[ "$AWS_CHECK" == *"NOT_INSTALLED"* ]] || [[ "$AWS_CHECK" == *"command not found"* ]]; then
    echo -e "  ${RED}✗ AWS CLI is not installed on Application Server${NC}"
    echo ""
    echo -e "  To install AWS CLI on Application Server:"
    echo -e "  ${CYAN}ssh ${APP_SERVER_USER}@${APP_SERVER_HOST}${NC}"
    echo -e "  ${CYAN}curl \"https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip\" -o \"awscliv2.zip\"${NC}"
    echo -e "  ${CYAN}unzip awscliv2.zip${NC}"
    echo -e "  ${CYAN}sudo ./aws/install${NC}"
    echo -e "  ${CYAN}aws configure --profile ${AWS_PROFILE}${NC}"
    echo ""
    exit 1
else
    AWS_VERSION=$(echo "$AWS_CHECK" | grep -oP 'aws-cli/\K[^ ]+' | head -1)
    echo -e "  ${GREEN}✓ AWS CLI is installed${NC} (version: ${AWS_VERSION})"
fi

# Check AWS credentials
AWS_CREDS_CHECK=$(ssh -i "$APP_SERVER_SSH_KEY" "${APP_SERVER_USER}@${APP_SERVER_HOST}" \
    "aws sts get-caller-identity --profile ${AWS_PROFILE} 2>&1" || echo "NOT_CONFIGURED")

if [[ "$AWS_CREDS_CHECK" == *"NOT_CONFIGURED"* ]] || [[ "$AWS_CREDS_CHECK" == *"could not be found"* ]]; then
    echo -e "  ${YELLOW}⚠ AWS credentials not configured for profile: ${AWS_PROFILE}${NC}"
    echo -e "  Configure with: ${CYAN}ssh ${APP_SERVER_USER}@${APP_SERVER_HOST} 'aws configure --profile ${AWS_PROFILE}'${NC}"
else
    AWS_ACCOUNT=$(echo "$AWS_CREDS_CHECK" | grep -oP '"Account": "\K[0-9]+'  | head -1)
    echo -e "  ${GREEN}✓ AWS credentials configured${NC} (profile: ${AWS_PROFILE}, account: ${AWS_ACCOUNT})"
fi

echo ""

# Step 8: Test SSH connection to System Server
echo -e "${BLUE}Step 8/8: Testing SSH connection to System Server...${NC}"

if [ -z "$SYSTEM_SERVER_HOST" ]; then
    echo -e "  ${YELLOW}⚠ System Server host not configured in deploy.config.yml${NC}"
    echo -e "  You'll need to configure this before deployment"
else
    echo -e "  Testing: ${CYAN}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"

    if ssh -i "$SYSTEM_SERVER_SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes \
        "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" "echo 'SSH connection successful'" 2>/dev/null; then
        echo -e "  ${GREEN}✓ SSH connection successful${NC}"
    else
        echo -e "  ${YELLOW}⚠ SSH connection failed${NC}"
        echo ""
        echo -e "  ${YELLOW}To fix (run System Server setup first):${NC}"
        echo -e "  1. Copy and run System Server setup script"
        echo -e "  2. Add the public key to System Server deploy user:"
        echo -e "     ${CYAN}echo '$(cat ${SYSTEM_SERVER_SSH_KEY}.pub)' | ssh root@${SYSTEM_SERVER_HOST} \\${NC}"
        echo -e "     ${CYAN}  'tee -a /home/${SYSTEM_SERVER_USER}/.ssh/authorized_keys'${NC}"
        echo ""
    fi
fi

echo ""

# Summary
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}✓ Application Server setup complete!${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""

echo -e "${CYAN}Configuration Summary:${NC}"
echo -e "  Local Machine:     ${YELLOW}$(hostname)${NC}"
echo -e "  Application Server: ${YELLOW}${APP_SERVER_USER}@${APP_SERVER_HOST}${NC}"
echo -e "  System Server:      ${YELLOW}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
echo -e "  App SSH Key:        ${YELLOW}${APP_SERVER_SSH_KEY}${NC}"
echo -e "  System SSH Key:     ${YELLOW}${SYSTEM_SERVER_SSH_KEY}${NC}"
echo ""

echo -e "${CYAN}Next steps:${NC}"
echo ""
echo -e "1. Run System Server setup (if not done yet):"
echo -e "   ${CYAN}scp ${SCRIPT_DIR}/setup-system-server.sh ${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}:/tmp/${NC}"
echo -e "   ${CYAN}ssh ${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
echo -e "   ${CYAN}sudo PRODUCT_NAME=my-product APPLICATION_SERVER_IP=${APP_SERVER_HOST} /tmp/setup-system-server.sh${NC}"
echo ""
echo -e "2. Ensure code is deployed to Application Server at:"
echo -e "   ${YELLOW}${APP_SERVER_DEPLOY_PATH}${NC}"
echo ""
echo -e "3. Test deployment from local machine:"
echo -e "   ${CYAN}./deploy/deploy.sh staging${NC}"
echo ""
