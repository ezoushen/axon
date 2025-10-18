#!/bin/bash
# Zero-Downtime Deployment Script
# Runs from LOCAL MACHINE and orchestrates deployment on Application Server
# Part of the deployment-module - reusable across products
#
# Usage: ./deploy.sh <environment>
# Example: ./deploy.sh production

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Product root directory (parent of deploy module)
PRODUCT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration file
CONFIG_FILE="${PRODUCT_ROOT}/deploy.config.yml"

# Parse command line arguments
ENVIRONMENT=""
FORCE_CLEANUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE_CLEANUP=true
            shift
            ;;
        *)
            ENVIRONMENT=$1
            shift
            ;;
    esac
done

# Validate environment parameter
if [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment parameter required${NC}"
    echo ""
    echo "Usage: $0 <environment> [--force]"
    echo ""
    echo "Options:"
    echo "  --force, -f    Force cleanup of existing containers on target port"
    echo ""
    echo "Examples:"
    echo "  $0 production"
    echo "  $0 staging --force"
    exit 1
fi

# Check if configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Configuration file not found: $CONFIG_FILE${NC}"
    echo ""
    echo "Please create deploy.config.yml in your product root directory."
    echo "You can copy from: $SCRIPT_DIR/config.example.yml"
    exit 1
fi

# Function to parse YAML config
# Simple YAML parser using awk/grep
parse_config() {
    local key=$1
    local default=$2

    # Try to parse using yq if available
    if command -v yq &> /dev/null; then
        # yq requires leading dot for path
        value=$(yq eval ".$key" "$CONFIG_FILE" 2>/dev/null || echo "")
        if [ "$value" != "null" ] && [ -n "$value" ]; then
            echo "$value"
            return
        fi
    fi

    # Fallback to grep/awk parsing
    # This handles simple key: value pairs
    local search_key=$(echo "$key" | sed 's/\./:/g' | awk -F: '{print $NF}')
    value=$(grep -E "^\s*${search_key}:" "$CONFIG_FILE" | head -1 | awk -F: '{print $2}' | sed 's/#.*//' | tr -d ' "' || echo "")

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Load configuration
echo -e "${CYAN}==================================================${NC}"
echo -e "${CYAN}Zero-Downtime Deployment (from Local Machine)${NC}"
echo -e "${CYAN}==================================================${NC}"
echo ""
echo -e "${YELLOW}Running from: $(hostname)${NC}"
echo ""

echo -e "${BLUE}Loading configuration...${NC}"

# Product config
PRODUCT_NAME=$(parse_config "product.name" "my-product")
PRODUCT_DESC=$(parse_config "product.description" "")

# AWS config
AWS_PROFILE=$(parse_config "aws.profile" "default")
AWS_REGION=$(parse_config "aws.region" "ap-northeast-1")
AWS_ACCOUNT_ID=$(parse_config "aws.account_id" "")
ECR_REPOSITORY=$(parse_config "aws.ecr_repository" "$PRODUCT_NAME")

# System Server config
SYSTEM_SERVER_HOST=$(parse_config "servers.system.host" "")
SYSTEM_SERVER_USER=$(parse_config "servers.system.user" "root")
SYSTEM_SSH_KEY=$(parse_config "servers.system.ssh_key" "~/.ssh/system_server_key")
SYSTEM_SSH_KEY="${SYSTEM_SSH_KEY/#\~/$HOME}"  # Expand ~

# Application Server config
APP_SERVER_HOST=$(parse_config "servers.application.host" "")
APP_SERVER_PRIVATE_IP=$(parse_config "servers.application.private_ip" "")
APP_SERVER_USER=$(parse_config "servers.application.user" "ubuntu")
APP_SSH_KEY=$(parse_config "servers.application.ssh_key" "~/.ssh/application_server_key")
APP_DEPLOY_PATH=$(parse_config "servers.application.deploy_path" "/home/ubuntu/app")
APP_SSH_KEY="${APP_SSH_KEY/#\~/$HOME}"  # Expand ~

# Use private IP for nginx upstream (falls back to public host if not set)
APP_UPSTREAM_IP="${APP_SERVER_PRIVATE_IP:-$APP_SERVER_HOST}"

# Environment-specific config
BLUE_PORT=$(parse_config "environments.${ENVIRONMENT}.blue_port" "5100")
GREEN_PORT=$(parse_config "environments.${ENVIRONMENT}.green_port" "5102")
DOMAIN=$(parse_config "environments.${ENVIRONMENT}.domain" "")
NGINX_UPSTREAM_FILE=$(parse_config "environments.${ENVIRONMENT}.nginx_upstream_file" "/etc/nginx/upstreams/${PRODUCT_NAME}-${ENVIRONMENT}.conf")
NGINX_UPSTREAM_NAME=$(parse_config "environments.${ENVIRONMENT}.nginx_upstream_name" "${PRODUCT_NAME}_${ENVIRONMENT}_backend")
ENV_FILE=$(parse_config "environments.${ENVIRONMENT}.env_file" ".env.${ENVIRONMENT}")
IMAGE_TAG=$(parse_config "environments.${ENVIRONMENT}.image_tag" "$ENVIRONMENT")
DOCKER_COMPOSE_FILE=$(parse_config "environments.${ENVIRONMENT}.docker_compose_file" "docker-compose.${ENVIRONMENT}.yml")

# Health check config
HEALTH_ENDPOINT=$(parse_config "health_check.endpoint" "/api/health")
MAX_RETRIES=$(parse_config "health_check.max_retries" "30")
RETRY_INTERVAL=$(parse_config "health_check.retry_interval" "2")

# Deployment config
DRAIN_TIME=$(parse_config "deployment.connection_drain_time" "5")
AUTO_ROLLBACK=$(parse_config "deployment.enable_auto_rollback" "true")

# Validate required configuration
MISSING_CONFIG=()

[ -z "$AWS_ACCOUNT_ID" ] && MISSING_CONFIG+=("aws.account_id")
[ -z "$SYSTEM_SERVER_HOST" ] && MISSING_CONFIG+=("servers.system.host")
[ -z "$APP_SERVER_HOST" ] && MISSING_CONFIG+=("servers.application.host")

if [ ${#MISSING_CONFIG[@]} -gt 0 ]; then
    echo -e "${RED}Error: Missing required configuration:${NC}"
    for key in "${MISSING_CONFIG[@]}"; do
        echo "  - $key"
    done
    exit 1
fi

# Display configuration
echo -e "${BLUE}Configuration loaded:${NC}"
echo -e "  Product:            ${YELLOW}${PRODUCT_NAME}${NC}"
echo -e "  Environment:        ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "  AWS Region:         ${YELLOW}${AWS_REGION}${NC}"
echo -e "  ECR Repository:     ${YELLOW}${ECR_REPOSITORY}${NC}"
echo -e "  System Server:      ${YELLOW}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
echo -e "  Application Server: ${YELLOW}${APP_SERVER_USER}@${APP_SERVER_HOST}${NC}"
echo -e "  Deploy Path:        ${YELLOW}${APP_DEPLOY_PATH}${NC}"
echo -e "  Ports:              ${YELLOW}${BLUE_PORT} (blue) ↔ ${GREEN_PORT} (green)${NC}"
echo ""

# SSH connection strings
SYSTEM_SERVER="${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}"
APP_SERVER="${APP_SERVER_USER}@${APP_SERVER_HOST}"

# ECR URL
ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
FULL_IMAGE="${ECR_URL}/${ECR_REPOSITORY}:${IMAGE_TAG}"

# Check SSH keys exist
if [ ! -f "$SYSTEM_SSH_KEY" ]; then
    echo -e "${RED}Error: System Server SSH key not found: $SYSTEM_SSH_KEY${NC}"
    echo "Please run setup scripts first or check your configuration."
    exit 1
fi

if [ ! -f "$APP_SSH_KEY" ]; then
    echo -e "${RED}Error: Application Server SSH key not found: $APP_SSH_KEY${NC}"
    echo "Please run setup scripts first or check your configuration."
    exit 1
fi

# Step 1: Detect current deployment slot
echo -e "${BLUE}Step 1/10: Detecting current deployment slot...${NC}"

CURRENT_PORT=$(ssh -i "$SYSTEM_SSH_KEY" "$SYSTEM_SERVER" \
    "grep -oP 'server.*:\K\d+' $NGINX_UPSTREAM_FILE 2>/dev/null" || echo "$BLUE_PORT")

echo -e "  Current active port: ${YELLOW}$CURRENT_PORT${NC}"

# Step 2: Determine target slot
if [ "$CURRENT_PORT" == "$BLUE_PORT" ]; then
    export APP_PORT=$GREEN_PORT
    export DEPLOYMENT_SLOT="green"
    CURRENT_SLOT="blue"
else
    export APP_PORT=$BLUE_PORT
    export DEPLOYMENT_SLOT="blue"
    CURRENT_SLOT="green"
fi

echo -e "  Target deployment: ${GREEN}$DEPLOYMENT_SLOT${NC} (port $APP_PORT)"
echo -e "  Current deployment: ${YELLOW}$CURRENT_SLOT${NC} (port $CURRENT_PORT)"
echo ""

# Step 3: Prepare deployment files on Application Server
echo -e "${BLUE}Step 2/10: Preparing deployment files on Application Server...${NC}"

# Create deployment directory if it doesn't exist
ssh -i "$APP_SSH_KEY" "$APP_SERVER" "mkdir -p $APP_DEPLOY_PATH"

# Copy docker-compose file from local machine
echo -e "  Copying docker-compose file..."
if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
    echo -e "${RED}Error: Docker Compose file not found locally: ${DOCKER_COMPOSE_FILE}${NC}"
    exit 1
fi

scp -i "$APP_SSH_KEY" "$DOCKER_COMPOSE_FILE" "${APP_SERVER}:${APP_DEPLOY_PATH}/"
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to copy docker-compose file to Application Server${NC}"
    exit 1
fi
echo -e "  ✓ Docker Compose copied: ${DOCKER_COMPOSE_FILE}"

# Check if .env file exists on Application Server (don't copy - may contain secrets)
ENV_EXISTS=$(ssh -i "$APP_SSH_KEY" "$APP_SERVER" "[ -f '$APP_DEPLOY_PATH/$ENV_FILE' ] && echo 'YES' || echo 'NO'")

if [ "$ENV_EXISTS" = "NO" ]; then
    echo -e "${YELLOW}⚠ Warning: Environment file not found on Application Server: ${APP_DEPLOY_PATH}/${ENV_FILE}${NC}"
    echo -e "${YELLOW}  Please create it manually with your environment variables${NC}"
    echo -e "${YELLOW}  Example: ssh ${APP_SERVER} 'cat > ${APP_DEPLOY_PATH}/${ENV_FILE}'${NC}"
    exit 1
fi
echo -e "  ✓ Environment file exists: ${ENV_FILE}"
echo ""

# Step 4: Authenticate with ECR on Application Server and pull latest image
echo -e "${BLUE}Step 3/10: Pulling latest image from ECR on Application Server...${NC}"
echo -e "  Image: ${YELLOW}${FULL_IMAGE}${NC}"

ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
set -e
aws ecr get-login-password --region "$AWS_REGION" --profile "$AWS_PROFILE" | \
    docker login --username AWS --password-stdin "$ECR_URL" 2>/dev/null

if [ \$? -ne 0 ]; then
    echo "Error: Failed to authenticate with ECR"
    exit 1
fi

docker pull "$FULL_IMAGE"

if [ \$? -ne 0 ]; then
    echo "Error: Failed to pull image"
    exit 1
fi
EOF

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Image pull failed${NC}"
    exit 1
fi

echo -e "  ✓ Image pulled successfully"
echo ""

# Step 4: Force cleanup if requested (optional step)
if [ "$FORCE_CLEANUP" = true ]; then
    echo -e "${YELLOW}Force cleanup enabled - removing containers on port ${APP_PORT}...${NC}"

    ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
# Find containers using the target port
BLOCKING_CONTAINERS=\$(docker ps -a --filter "publish=${APP_PORT}" --format "{{.Names}}")

if [ -n "\$BLOCKING_CONTAINERS" ]; then
    echo "  Found containers blocking port ${APP_PORT}:"
    echo "\$BLOCKING_CONTAINERS" | while read container; do
        echo "    - \$container"
        docker stop "\$container" 2>/dev/null || true
        docker rm "\$container" 2>/dev/null || true
    done
    echo "  ✓ Cleanup completed"
else
    echo "  No containers blocking port ${APP_PORT}"
fi
EOF

    echo ""
fi

# Step 4: Start new container on Application Server
echo -e "${BLUE}Step 4/10: Starting new container on Application Server...${NC}"
echo -e "  Container: ${YELLOW}${PRODUCT_NAME}-${ENVIRONMENT}-${DEPLOYMENT_SLOT}${NC}"
echo -e "  Port: ${YELLOW}${APP_PORT}${NC}"

ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
set -e
cd $APP_DEPLOY_PATH

# Set unique project name per environment to prevent interference
export COMPOSE_PROJECT_NAME="${PRODUCT_NAME}_${ENVIRONMENT}"

# Export variables for docker-compose
export PRODUCT_NAME="$PRODUCT_NAME"
export APP_PORT="$APP_PORT"
export DEPLOYMENT_SLOT="$DEPLOYMENT_SLOT"

# Load environment variables from env file
export \$(cat "$ENV_FILE" | grep -v '^#' | xargs)

# Start container
docker-compose -f "$DOCKER_COMPOSE_FILE" up -d --force-recreate

if [ \$? -ne 0 ]; then
    echo "Error: Failed to start container"
    exit 1
fi
EOF

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to start container${NC}"
    exit 1
fi

echo -e "  ✓ Container started"
echo ""

# Step 6: Wait for health check on Application Server
echo -e "${BLUE}Step 5/10: Waiting for health check on Application Server...${NC}"

RETRY_COUNT=0
HEALTH_URL="http://localhost:${APP_PORT}${HEALTH_ENDPOINT}"

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    HEALTH_CHECK=$(ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
        "curl -f -s --max-time 5 '$HEALTH_URL' > /dev/null 2>&1 && echo 'OK' || echo 'FAIL'")

    if [ "$HEALTH_CHECK" = "OK" ]; then
        echo -e "${GREEN}  ✓ Health check passed!${NC}"
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo -e "  Attempt $RETRY_COUNT/$MAX_RETRIES..."
    sleep $RETRY_INTERVAL
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}Error: Health check failed after $MAX_RETRIES attempts${NC}"
    echo -e "${RED}URL: $HEALTH_URL${NC}"

    if [ "$AUTO_ROLLBACK" == "true" ]; then
        echo -e "${YELLOW}Auto-rollback enabled. Stopping new container...${NC}"

        ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
# Stop and remove the specific failed container
FAILED_CONTAINER="${PRODUCT_NAME}-${ENVIRONMENT}-${DEPLOYMENT_SLOT}"

if docker ps -a --format '{{.Names}}' | grep -q "^\${FAILED_CONTAINER}\$"; then
    echo "  Stopping \${FAILED_CONTAINER}..."
    docker stop "\${FAILED_CONTAINER}" 2>/dev/null || true
    docker rm "\${FAILED_CONTAINER}" 2>/dev/null || true
fi
EOF

        echo -e "${YELLOW}Old container still running. No impact to production.${NC}"
    fi

    exit 1
fi
echo ""

# Step 7: Update nginx upstream on System Server
echo -e "${BLUE}Step 6/10: Updating System Server nginx...${NC}"

UPSTREAM_CONFIG="upstream $NGINX_UPSTREAM_NAME {
    server $APP_UPSTREAM_IP:$APP_PORT;
}"

ssh -i "$SYSTEM_SSH_KEY" "$SYSTEM_SERVER" "echo '$UPSTREAM_CONFIG' | sudo tee $NGINX_UPSTREAM_FILE > /dev/null"

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to update nginx upstream file${NC}"
    exit 1
fi

echo -e "  ✓ nginx upstream updated to port $APP_PORT"
echo ""

# Step 8: Test nginx configuration on System Server
echo -e "${BLUE}Step 7/10: Testing nginx configuration on System Server...${NC}"

ssh -i "$SYSTEM_SSH_KEY" "$SYSTEM_SERVER" "sudo nginx -t" 2>&1 | grep -q "successful"

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: nginx configuration test failed!${NC}"

    # Rollback nginx config
    echo -e "${YELLOW}Rolling back nginx configuration...${NC}"
    ROLLBACK_CONFIG="upstream $NGINX_UPSTREAM_NAME {
    server $APP_UPSTREAM_IP:$CURRENT_PORT;
}"
    ssh -i "$SYSTEM_SSH_KEY" "$SYSTEM_SERVER" "echo '$ROLLBACK_CONFIG' | sudo tee $NGINX_UPSTREAM_FILE > /dev/null"

    # Stop new container
    echo -e "${YELLOW}Stopping new container on Application Server...${NC}"
    ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
# Stop and remove the specific failed container
FAILED_CONTAINER="${PRODUCT_NAME}-${ENVIRONMENT}-${DEPLOYMENT_SLOT}"

if docker ps -a --format '{{.Names}}' | grep -q "^\${FAILED_CONTAINER}\$"; then
    echo "  Stopping \${FAILED_CONTAINER}..."
    docker stop "\${FAILED_CONTAINER}" 2>/dev/null || true
    docker rm "\${FAILED_CONTAINER}" 2>/dev/null || true
fi
EOF

    exit 1
fi

echo -e "  ✓ nginx configuration is valid"
echo ""

# Step 9: Reload nginx (ZERO DOWNTIME!)
echo -e "${BLUE}Step 8/10: Reloading nginx on System Server (zero-downtime)...${NC}"

ssh -i "$SYSTEM_SSH_KEY" "$SYSTEM_SERVER" "sudo nginx -s reload"

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: nginx reload failed!${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ nginx reloaded successfully!${NC}"
echo -e "${GREEN}  ✓ Traffic now flows to ${DEPLOYMENT_SLOT} (port $APP_PORT)${NC}"
echo ""

# Step 10: Connection draining
echo -e "${BLUE}Step 9/10: Waiting for connection draining (${DRAIN_TIME}s)...${NC}"
sleep $DRAIN_TIME
echo ""

# Step 11: Stop old container on Application Server
echo -e "${BLUE}Step 10/10: Stopping old container on Application Server...${NC}"
echo -e "  Old container: ${YELLOW}${PRODUCT_NAME}-${ENVIRONMENT}-${CURRENT_SLOT}${NC} (port $CURRENT_PORT)"

ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
# Stop and remove the specific old container
OLD_CONTAINER="${PRODUCT_NAME}-${ENVIRONMENT}-${CURRENT_SLOT}"

if docker ps -a --format '{{.Names}}' | grep -q "^\${OLD_CONTAINER}\$"; then
    echo "  Stopping \${OLD_CONTAINER}..."
    docker stop "\${OLD_CONTAINER}" 2>/dev/null || true
    docker rm "\${OLD_CONTAINER}" 2>/dev/null || true
    echo "  ✓ Container stopped and removed"
else
    echo "  Container \${OLD_CONTAINER} not found (already removed)"
fi
EOF

echo -e "  ✓ Old container stopped"
echo ""

# Success!
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}✓ Deployment completed successfully!${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""

echo -e "${CYAN}Deployment Summary:${NC}"
echo -e "  Product:          ${YELLOW}${PRODUCT_NAME}${NC}"
echo -e "  Environment:      ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "  Active Slot:      ${GREEN}${DEPLOYMENT_SLOT}${NC} (port $APP_PORT)"
echo -e "  Container:        ${YELLOW}${PRODUCT_NAME}-${ENVIRONMENT}-${DEPLOYMENT_SLOT}${NC}"
echo -e "  Image:            ${YELLOW}${FULL_IMAGE}${NC}"
echo -e "  Downtime:         ${GREEN}0 seconds${NC} ⚡"
echo ""

echo -e "${CYAN}Useful Commands:${NC}"
echo -e "  View logs:        ${BLUE}ssh -i $APP_SSH_KEY $APP_SERVER 'docker logs -f ${PRODUCT_NAME}-${ENVIRONMENT}-${DEPLOYMENT_SLOT}'${NC}"
echo -e "  Container status: ${BLUE}ssh -i $APP_SSH_KEY $APP_SERVER 'docker ps | grep ${PRODUCT_NAME}-${ENVIRONMENT}'${NC}"
echo -e "  nginx upstream:   ${BLUE}ssh -i $SYSTEM_SSH_KEY $SYSTEM_SERVER 'cat $NGINX_UPSTREAM_FILE'${NC}"
echo ""

# Display container status on Application Server
echo -e "${CYAN}Container Status on Application Server:${NC}"
ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
    "docker ps --filter 'name=${PRODUCT_NAME}-${ENVIRONMENT}' \
     --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
echo ""

# Display recent logs from Application Server
echo -e "${CYAN}Recent Logs (last 20 lines):${NC}"
ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
    "if docker ps --filter 'name=${PRODUCT_NAME}-${ENVIRONMENT}-${DEPLOYMENT_SLOT}' --format '{{.Names}}' | grep -q .; then \
        docker logs --tail=20 '${PRODUCT_NAME}-${ENVIRONMENT}-${DEPLOYMENT_SLOT}' 2>&1 | head -20; \
    else \
        echo 'Container ${PRODUCT_NAME}-${ENVIRONMENT}-${DEPLOYMENT_SLOT} not found'; \
    fi"
echo ""

exit 0
