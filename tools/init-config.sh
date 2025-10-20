#!/bin/bash
# AXON - Initialize Configuration File
# Generates axon.config.yml with optional interactive mode

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

# Default values
OUTPUT_FILE="axon.config.yml"
INTERACTIVE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -i|--interactive)
            INTERACTIVE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -f, --file FILE      Output file name (default: axon.config.yml)"
            echo "  -i, --interactive    Interactive mode - configure field by field"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                              # Copy example config"
            echo "  $0 --interactive                # Interactive configuration"
            echo "  $0 --file my-config.yml         # Custom filename"
            echo "  $0 -i --file production.yml     # Interactive + custom filename"
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

# Make OUTPUT_FILE relative to product root
if [[ "$OUTPUT_FILE" != /* ]]; then
    OUTPUT_FILE="${PRODUCT_ROOT}/${OUTPUT_FILE}"
fi

echo -e "${CYAN}==================================================${NC}"
echo -e "${CYAN}AXON - Configuration Generator${NC}"
echo -e "${CYAN}==================================================${NC}"
echo ""

# Check if output file already exists
if [ -f "$OUTPUT_FILE" ]; then
    echo -e "${YELLOW}Warning: Configuration file already exists: ${OUTPUT_FILE}${NC}"
    echo ""
    read -p "Overwrite existing file? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Cancelled. No changes made.${NC}"
        exit 0
    fi
    echo ""
fi

if [ "$INTERACTIVE" = true ]; then
    echo -e "${BLUE}Interactive Configuration Mode${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "I'll guide you through creating your configuration file."
    echo "Press Enter to use default values shown in [brackets]."
    echo ""

    # Product Information
    echo -e "${GREEN}Product Information${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "Product name (lowercase, no spaces) [my-product]: " PRODUCT_NAME
    PRODUCT_NAME=${PRODUCT_NAME:-my-product}

    read -p "Product description [My Product]: " PRODUCT_DESC
    PRODUCT_DESC=${PRODUCT_DESC:-My Product}
    echo ""

    # AWS Configuration
    echo -e "${GREEN}AWS Configuration${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "AWS profile name [default]: " AWS_PROFILE
    AWS_PROFILE=${AWS_PROFILE:-default}

    read -p "AWS region [ap-northeast-1]: " AWS_REGION
    AWS_REGION=${AWS_REGION:-ap-northeast-1}

    read -p "AWS account ID (12 digits): " AWS_ACCOUNT_ID
    while [[ ! "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; do
        echo -e "${YELLOW}Please enter a valid 12-digit AWS account ID${NC}"
        read -p "AWS account ID: " AWS_ACCOUNT_ID
    done

    read -p "ECR repository name [$PRODUCT_NAME]: " ECR_REPO
    ECR_REPO=${ECR_REPO:-$PRODUCT_NAME}
    echo ""

    # Server Configuration
    echo -e "${GREEN}System Server (nginx + SSL)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "System server host (e.g., system.example.com): " SYS_HOST

    read -p "System server user [ubuntu]: " SYS_USER
    SYS_USER=${SYS_USER:-ubuntu}

    read -p "System server SSH key path [~/.ssh/id_rsa]: " SYS_KEY
    SYS_KEY=${SYS_KEY:-~/.ssh/id_rsa}
    echo ""

    echo -e "${GREEN}Application Server (Docker)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "Application server public host/IP (for SSH): " APP_HOST

    read -p "Application server private IP (for nginx upstream): " APP_PRIVATE_IP

    read -p "Application server user [ubuntu]: " APP_USER
    APP_USER=${APP_USER:-ubuntu}

    read -p "Application server SSH key path [~/.ssh/id_rsa]: " APP_KEY
    APP_KEY=${APP_KEY:-~/.ssh/id_rsa}
    echo ""

    # Environment Paths
    echo -e "${GREEN}Environment Configuration${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "Production .env file path on app server [/home/ubuntu/apps/$PRODUCT_NAME/.env.production]: " PROD_ENV
    PROD_ENV=${PROD_ENV:-/home/ubuntu/apps/$PRODUCT_NAME/.env.production}

    read -p "Staging .env file path on app server [/home/ubuntu/apps/$PRODUCT_NAME/.env.staging]: " STAGING_ENV
    STAGING_ENV=${STAGING_ENV:-/home/ubuntu/apps/$PRODUCT_NAME/.env.staging}
    echo ""

    # Docker Configuration
    echo -e "${GREEN}Docker Configuration${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -p "Container internal port [3000]: " CONTAINER_PORT
    CONTAINER_PORT=${CONTAINER_PORT:-3000}

    read -p "Health check endpoint [/api/health]: " HEALTH_ENDPOINT
    HEALTH_ENDPOINT=${HEALTH_ENDPOINT:-/api/health}
    echo ""

    # Generate configuration file
    cat > "$OUTPUT_FILE" <<EOF
# AXON Deployment Configuration
# Generated by: axon init-config --interactive
# Date: $(date +"%Y-%m-%d %H:%M:%S")

# Product Information
product:
  name: "${PRODUCT_NAME}"
  description: "${PRODUCT_DESC}"

# AWS Configuration
aws:
  profile: "${AWS_PROFILE}"
  region: "${AWS_REGION}"
  account_id: "${AWS_ACCOUNT_ID}"
  ecr_repository: "${ECR_REPO}"

# Server Configuration
servers:
  # System Server (nginx + SSL)
  system:
    host: "${SYS_HOST}"
    user: "${SYS_USER}"
    ssh_key: "${SYS_KEY}"

  # Application Server (Docker containers)
  application:
    host: "${APP_HOST}"
    private_ip: "${APP_PRIVATE_IP}"
    user: "${APP_USER}"
    ssh_key: "${APP_KEY}"

# Environment Configurations
environments:
  production:
    env_path: "${PROD_ENV}"
    image_tag: "production"

  staging:
    env_path: "${STAGING_ENV}"
    image_tag: "staging"

# Health Check Configuration
health_check:
  endpoint: "${HEALTH_ENDPOINT}"
  interval: "30s"
  timeout: "10s"
  retries: 3
  start_period: "40s"
  max_retries: 30
  retry_interval: 2

# Deployment Options
deployment:
  graceful_shutdown_timeout: 30
  enable_auto_rollback: true

# Docker Configuration
docker:
  image_template: "\${AWS_ACCOUNT_ID}.dkr.ecr.\${AWS_REGION}.amazonaws.com/\${ECR_REPOSITORY}:\${IMAGE_TAG}"
  container_port: ${CONTAINER_PORT}
  restart_policy: "unless-stopped"
  network_name: "\${PRODUCT_NAME}-\${ENVIRONMENT}-network"
  network_driver: "bridge"
  network_alias: "app"
  env_vars:
    NODE_ENV: "production"
    PORT: "${CONTAINER_PORT}"
  extra_hosts:
    - "host.docker.internal:host-gateway"
  logging:
    driver: "json-file"
    max_size: "10m"
    max_file: 3
EOF

else
    # Non-interactive mode - copy example config
    echo -e "${BLUE}Copying example configuration...${NC}"
    echo ""

    if [ ! -f "${MODULE_DIR}/config.example.yml" ]; then
        echo -e "${RED}Error: config.example.yml not found in AXON module${NC}"
        exit 1
    fi

    cp "${MODULE_DIR}/config.example.yml" "$OUTPUT_FILE"
fi

echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}Configuration file created successfully!${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
echo -e "File: ${YELLOW}${OUTPUT_FILE}${NC}"
echo ""

# Add to .gitignore if not already there
GITIGNORE_FILE="${PRODUCT_ROOT}/.gitignore"
CONFIG_BASENAME=$(basename "$OUTPUT_FILE")

if [ -f "$GITIGNORE_FILE" ]; then
    if ! grep -qF "$CONFIG_BASENAME" "$GITIGNORE_FILE"; then
        echo "" >> "$GITIGNORE_FILE"
        echo "# AXON deployment configuration (contains secrets)" >> "$GITIGNORE_FILE"
        echo "$CONFIG_BASENAME" >> "$GITIGNORE_FILE"
        echo -e "${GREEN}✓ Added ${CONFIG_BASENAME} to .gitignore${NC}"
    else
        echo -e "${YELLOW}Note: ${CONFIG_BASENAME} already in .gitignore${NC}"
    fi
else
    cat > "$GITIGNORE_FILE" <<EOF
# AXON deployment configuration (contains secrets)
$CONFIG_BASENAME
EOF
    echo -e "${GREEN}✓ Created .gitignore with ${CONFIG_BASENAME}${NC}"
fi

echo ""
echo "Next steps:"
if [ "$INTERACTIVE" = false ]; then
    echo "  1. Edit ${CONFIG_BASENAME} with your server details"
    echo "  2. Update AWS credentials and server information"
    echo "  3. Validate: axon validate --config ${CONFIG_BASENAME}"
else
    echo "  1. Validate: axon validate --config ${CONFIG_BASENAME}"
    echo "  2. Setup servers: axon setup app-server && axon setup system-server"
    echo "  3. Deploy: axon run staging"
fi
echo ""
