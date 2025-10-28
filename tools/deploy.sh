#!/bin/bash
# AXON - Zero-Downtime Deployment Script
# Runs from LOCAL MACHINE and orchestrates deployment on Application Server
# Part of AXON - reusable across products
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
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Use current working directory for PRODUCT_ROOT (where config/Dockerfile live)
PRODUCT_ROOT="${PROJECT_ROOT:-$PWD}"

# Source SSH batch execution library for performance optimization
source "$MODULE_DIR/lib/ssh-batch.sh"

# Source defaults library for nginx configuration functions
source "$MODULE_DIR/lib/defaults.sh"

# Default values
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
ENVIRONMENT=""
FORCE_CLEANUP=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --force|-f)
            FORCE_CLEANUP=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] <environment>"
            echo ""
            echo "Options:"
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
            echo "  --force, -f          Force cleanup of existing containers on target port"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment          Target environment (e.g., production, staging)"
            echo ""
            echo "Examples:"
            echo "  $0 production"
            echo "  $0 --config custom.yml staging"
            echo "  $0 --force production"
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

# Make CONFIG_FILE absolute path if it's relative
if [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="${PRODUCT_ROOT}/${CONFIG_FILE}"
fi

# Validate environment parameter
if [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment parameter required${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Check if configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Configuration file not found: $CONFIG_FILE${NC}"
    echo ""
    echo "Please create axon.config.yml in your product root directory."
    echo "You can copy from: $MODULE_DIR/config.example.yml"
    exit 1
fi

# Source the shared config parser library
source "$MODULE_DIR/lib/config-parser.sh"

# Wrapper function for backward compatibility (parse_config uses different syntax than parse_yaml_key)
# Still needed for Docker-specific config that's not in load_config
parse_config() {
    local key=$1
    local default=$2
    parse_yaml_key "$key" "$default" "$CONFIG_FILE"
}

# Function to generate temporary docker-compose.yml from config
generate_docker_compose_from_config() {
    local container_name=$1
    local app_port=$2
    local full_image=$3
    local env_file=$4
    local network_name=$5
    local network_alias=$6
    local container_port=$7

    # Create temporary docker-compose file
    local temp_compose=$(mktemp /tmp/docker-compose.XXXXXX)

    # Build docker-compose.yml content
    cat > "$temp_compose" <<EOF
version: '3.8'

services:
  app:
    container_name: ${container_name}
    image: ${full_image}

    # Port mapping
EOF

    # Add port mapping
    if [ "$app_port" = "auto" ]; then
        echo "    ports:" >> "$temp_compose"
        echo "      - \"${container_port}\"" >> "$temp_compose"
    else
        echo "    ports:" >> "$temp_compose"
        echo "      - \"${app_port}:${container_port}\"" >> "$temp_compose"
    fi

    # Add env_file
    echo "" >> "$temp_compose"
    echo "    env_file:" >> "$temp_compose"
    echo "      - ${env_file}" >> "$temp_compose"

    # Add common environment variables from config
    local common_env_vars=$(parse_config ".docker.env_vars" "")
    if [ -n "$common_env_vars" ]; then
        echo "" >> "$temp_compose"
        echo "    environment:" >> "$temp_compose"

        local env_keys=$(echo "$common_env_vars" | grep -E "^[A-Z_]+:" | sed 's/://' || true)
        for key in $env_keys; do
            local value=$(parse_config ".docker.env_vars.$key" "")
            if [ -n "$value" ]; then
                echo "      - ${key}=${value}" >> "$temp_compose"
            fi
        done
    fi

    # Add restart policy
    local restart_policy=$(parse_config ".docker.restart_policy" "unless-stopped")
    echo "" >> "$temp_compose"
    echo "    restart: ${restart_policy}" >> "$temp_compose"

    # Add extra hosts
    local extra_hosts=$(parse_config ".docker.extra_hosts" "" | grep -E "^\s*-\s*" | sed 's/^\s*-\s*//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)
    if [ -n "$extra_hosts" ]; then
        echo "" >> "$temp_compose"
        echo "    extra_hosts:" >> "$temp_compose"
        while IFS= read -r host_mapping; do
            if [ -n "$host_mapping" ]; then
                # Remove quotes if already present in config
                host_mapping=$(echo "$host_mapping" | sed 's/^"//; s/"$//')
                echo "      - \"${host_mapping}\"" >> "$temp_compose"
            fi
        done <<< "$extra_hosts"
    fi

    # Add health check
    local health_endpoint=$(parse_config ".health_check.endpoint" "")
    if [ -n "$health_endpoint" ]; then
        echo "" >> "$temp_compose"
        echo "    healthcheck:" >> "$temp_compose"

        # Generate health check test command from endpoint
        # Using wget to test the health endpoint inside the container
        echo "      test: [\"CMD\", \"wget\", \"--quiet\", \"--tries=1\", \"--spider\", \"http://127.0.0.1:${container_port}${health_endpoint}\"]" >> "$temp_compose"

        local health_interval=$(parse_config ".health_check.interval" "30s")
        local health_timeout=$(parse_config ".health_check.timeout" "10s")
        local health_retries=$(parse_config ".health_check.retries" "3")
        local health_start_period=$(parse_config ".health_check.start_period" "40s")

        echo "      interval: ${health_interval}" >> "$temp_compose"
        echo "      timeout: ${health_timeout}" >> "$temp_compose"
        echo "      retries: ${health_retries}" >> "$temp_compose"
        echo "      start_period: ${health_start_period}" >> "$temp_compose"
    fi

    # Add logging
    local log_driver=$(parse_config ".docker.logging.driver" "json-file")
    local log_max_size=$(parse_config ".docker.logging.max_size" "10m")
    local log_max_file=$(parse_config ".docker.logging.max_file" "3")

    echo "" >> "$temp_compose"
    echo "    logging:" >> "$temp_compose"
    echo "      driver: ${log_driver}" >> "$temp_compose"
    echo "      options:" >> "$temp_compose"
    echo "        max-size: \"${log_max_size}\"" >> "$temp_compose"
    echo "        max-file: \"${log_max_file}\"" >> "$temp_compose"

    echo "" >> "$temp_compose"
    echo "    networks:" >> "$temp_compose"
    if [ -n "$network_alias" ]; then
        echo "      ${network_name}:" >> "$temp_compose"
        echo "        aliases:" >> "$temp_compose"
        echo "          - ${network_alias}" >> "$temp_compose"
    else
        echo "      - ${network_name}" >> "$temp_compose"
    fi

    # Add custom docker-compose overrides (raw YAML)
    # This allows users to add any Docker feature without modifying this script
    local compose_override=$(parse_config ".docker.compose_override" "")
    if [ -n "$compose_override" ]; then
        echo "" >> "$temp_compose"
        echo "    # Custom overrides from axon.config.yml" >> "$temp_compose"
        # Indent the override content by 4 spaces to match service-level
        echo "$compose_override" | sed 's/^/    /' >> "$temp_compose"
    fi

    # Add networks section
    echo "" >> "$temp_compose"
    echo "networks:" >> "$temp_compose"
    echo "  ${network_name}:" >> "$temp_compose"
    echo "    external: true" >> "$temp_compose"

    echo "$temp_compose"
}

# Function to build docker run command from axon.config.yml using decomposerize
# This generates a temporary docker-compose.yml and converts it to docker run
build_docker_run_command() {
    local container_name=$1
    local app_port=$2
    local full_image=$3
    local env_file=$4
    local network_name=$5
    local network_alias=$6
    local container_port=$7

    # Check if decomposerize is available (optional but recommended)
    if ! command -v decomposerize &> /dev/null; then
        echo -e "${RED}Error: decomposerize not found${NC}" >&2
        echo -e "${RED}Install decomposerize for full Docker feature support:${NC}" >&2
        echo -e "${RED}  npm install -g decomposerize${NC}" >&2
        return 1
    fi

    # Generate temporary docker-compose.yml from config
    local temp_compose=$(generate_docker_compose_from_config \
        "$container_name" \
        "$app_port" \
        "$full_image" \
        "$env_file" \
        "$network_name" \
        "$network_alias" \
        "$container_port")

    # Debug: Show generated compose file
    if [ -n "$DEBUG" ]; then
        echo "Generated docker-compose.yml:" >&2
        cat "$temp_compose" >&2
    fi

    # Use decomposerize to convert to docker run command
    local docker_run_cmd=$(decomposerize < "$temp_compose" 2>&1 | grep "^docker run")

    # Clean up temp file
    rm -f "$temp_compose"

    if [ -z "$docker_run_cmd" ]; then
        echo -e "${RED}Error: decomposerize failed to generate docker run command${NC}" >&2
        return 1
    fi

    # Post-process the generated command for our specific requirements

    # Ensure detached mode (-d)
    if ! echo "$docker_run_cmd" | grep -q " -d "; then
        docker_run_cmd=$(echo "$docker_run_cmd" | sed 's/^docker run /docker run -d /')
    fi

    # Fix port mapping for auto-assignment if needed
    if [ "$app_port" = "auto" ]; then
        # Ensure no host port is specified (decomposerize might add one)
        docker_run_cmd=$(echo "$docker_run_cmd" | sed "s/-p [0-9]*:${container_port}/-p ${container_port}/")
    fi

    # Fix health check format (decomposerize outputs CMD,wget,... but docker expects space-separated)
    if echo "$docker_run_cmd" | grep -q -- "--health-cmd"; then
        local health_value=$(echo "$docker_run_cmd" | sed -n 's/.*--health-cmd \([^ ]*\).*/\1/p' | sed 's/^CMD,//' | tr ',' ' ')
        docker_run_cmd=$(echo "$docker_run_cmd" | sed "s|--health-cmd [^ ]*|--health-cmd \"$health_value\"|")
    fi

    # Fix log options (decomposerize may output: --log-opt max-file=3,max-size=10m)
    docker_run_cmd=$(echo "$docker_run_cmd" | sed 's/--log-opt \([^,]*\),\([a-z-]*=\)/--log-opt \1 --log-opt \2/g')

    echo "$docker_run_cmd"
}

# Load configuration
echo -e "${CYAN}==================================================${NC}"
echo -e "${CYAN}AXON - Zero-Downtime Deployment${NC}"
echo -e "${CYAN}==================================================${NC}"
echo ""

# Show context info if using context mode
if [ "$CONTEXT_MODE" = "context" ] && [ -n "$CONTEXT_NAME" ]; then
    echo -e "${BLUE}Context: ${YELLOW}${CONTEXT_NAME}${NC}"
fi

echo -e "${YELLOW}Running from: $(hostname)${NC}"
echo ""

echo -e "${BLUE}Loading configuration...${NC}"

# Validate environment exists in config
if ! validate_environment "$ENVIRONMENT" "$CONFIG_FILE"; then
    exit 1
fi

if [ "${VERBOSE:-false}" = "true" ]; then
    echo "[VERBOSE] deploy.sh: Calling load_config..." >&2
fi

# Load all common configuration using load_config
load_config "$ENVIRONMENT"

if [ "${VERBOSE:-false}" = "true" ]; then
    echo "[VERBOSE] deploy.sh: load_config completed, parsing product description..." >&2
fi

# Additional product-specific config not in load_config
PRODUCT_DESC=$(parse_config ".product.description" "")

# Detect product type
PRODUCT_TYPE=$(get_product_type "$CONFIG_FILE")
if [ "$PRODUCT_TYPE" != "docker" ] && [ "$PRODUCT_TYPE" != "static" ]; then
    echo -e "${RED}Error: Invalid product.type: ${PRODUCT_TYPE}${NC}"
    echo "Must be 'docker' or 'static'"
    exit 1
fi

# ==============================================================================
# Docker Deployment Function
# ==============================================================================
deploy_docker() {
    # Use consistent variable names with load_config (for backward compatibility with this script)
    APP_SERVER_HOST="$APPLICATION_SERVER_HOST"
    APP_SERVER_USER="$APPLICATION_SERVER_USER"
    APP_SSH_KEY="$APPLICATION_SERVER_SSH_KEY"
    APP_SERVER_PRIVATE_IP="$APPLICATION_SERVER_PRIVATE_IP"

    # Use private IP for nginx upstream (falls back to public host if not set)
    APP_UPSTREAM_IP="${APP_SERVER_PRIVATE_IP:-$APP_SERVER_HOST}"

    # Get nginx paths and names from defaults library
    NGINX_AXON_DIR=$(get_nginx_axon_dir "$CONFIG_FILE")
    NGINX_UPSTREAM_FILENAME=$(get_upstream_filename "$PRODUCT_NAME" "$ENVIRONMENT")
    NGINX_UPSTREAM_FILE="${NGINX_AXON_DIR}/upstreams/${NGINX_UPSTREAM_FILENAME}"
    NGINX_UPSTREAM_NAME=$(get_upstream_name "$PRODUCT_NAME" "$ENVIRONMENT")
    NGINX_SITE_FILENAME=$(get_site_filename "$PRODUCT_NAME" "$ENVIRONMENT")
    NGINX_SITE_FILE="${NGINX_AXON_DIR}/sites/${NGINX_SITE_FILENAME}"

    # Use ENV_FILE_PATH from load_config, rename to ENV_PATH for this script
    ENV_PATH="$ENV_FILE_PATH"

    # Extract directory from env_path for deployment operations
    APP_DEPLOY_PATH=$(dirname "$ENV_PATH")

    # Validate required registry configuration
    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] deploy.sh: Validating registry configuration..." >&2
    fi

    REGISTRY_PROVIDER=$(get_registry_provider)
    if [ -z "$REGISTRY_PROVIDER" ]; then
        echo -e "${RED}Error: Registry provider not configured${NC}"
        echo "Please set 'registry.provider' in $CONFIG_FILE"
        exit 1
    fi

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] deploy.sh: Registry provider validated, building image URI..." >&2
    fi

    # Build image URI
    FULL_IMAGE=$(build_image_uri "$IMAGE_TAG")
    if [ $? -ne 0 ] || [ -z "$FULL_IMAGE" ]; then
        echo -e "${RED}Error: Could not build image URI${NC}"
        echo "Check your registry configuration in $CONFIG_FILE"
        exit 1
    fi

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] deploy.sh: Image URI built successfully: $FULL_IMAGE" >&2
    fi

    # Validate required server configuration
    MISSING_CONFIG=()
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
    echo -e "  Registry:           ${YELLOW}${REGISTRY_PROVIDER}${NC}"
    echo -e "  Image:              ${YELLOW}${FULL_IMAGE}${NC}"
    echo -e "  System Server:      ${YELLOW}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
    echo -e "  Application Server: ${YELLOW}${APP_SERVER_USER}@${APP_SERVER_HOST}${NC}"
    echo -e "  Deploy Path:        ${YELLOW}${APP_DEPLOY_PATH}${NC}"
    echo -e "  Port Assignment:    ${YELLOW}Auto (Docker assigns)${NC}"
    echo ""
    
    # SSH connection strings
    SYSTEM_SERVER="${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}"
    APP_SERVER="${APP_SERVER_USER}@${APP_SERVER_HOST}"
    
    # Check SSH keys exist
    if [ ! -f "$SSH_KEY" ]; then
        echo -e "${RED}Error: System Server SSH key not found: $SSH_KEY${NC}"
        echo "Please run setup scripts first or check your configuration."
        exit 1
    fi
    
    if [ ! -f "$APP_SSH_KEY" ]; then
        echo -e "${RED}Error: Application Server SSH key not found: $APP_SSH_KEY${NC}"
        echo "Please run setup scripts first or check your configuration."
        exit 1
    fi
    
    # Step 0: Pre-flight nginx validation on System Server
    echo -e "${BLUE}Step 0/9: Validating nginx setup on System Server...${NC}"
    
    # Determine sudo usage
    if [ "$SYSTEM_SERVER_USER" = "root" ]; then
        USE_SUDO=""
    else
        USE_SUDO="sudo"
    fi
    
    # Batch pre-flight checks on System Server
    ssh_batch_start
    ssh_batch_add "command -v nginx > /dev/null 2>&1 && echo 'INSTALLED' || echo 'NOT_INSTALLED'" "nginx_installed"
    ssh_batch_add "${USE_SUDO} systemctl is-active nginx 2>/dev/null || (pgrep nginx > /dev/null 2>&1 && echo 'active' || echo 'inactive')" "nginx_running"
    ssh_batch_add "[ -d '${NGINX_AXON_DIR}/upstreams' ] && echo 'EXISTS' || echo 'MISSING'" "upstreams_dir"
    ssh_batch_add "[ -d '${NGINX_AXON_DIR}/sites' ] && echo 'EXISTS' || echo 'MISSING'" "sites_dir"
    ssh_batch_add "${USE_SUDO} nginx -t 2>&1 | grep -q 'successful' && echo 'VALID' || echo 'INVALID'" "nginx_config_valid"
    ssh_batch_add "grep -qF 'include ${NGINX_AXON_DIR}/upstreams/*.conf' /etc/nginx/nginx.conf && echo 'INCLUDED' || echo 'MISSING'" "upstreams_included"
    ssh_batch_add "grep -qF 'include ${NGINX_AXON_DIR}/sites/*.conf' /etc/nginx/nginx.conf && echo 'INCLUDED' || echo 'MISSING'" "sites_included"
    ssh_batch_execute "$SSH_KEY" "$SYSTEM_SERVER"
    
    # Check nginx installation
    NGINX_INSTALLED=$(ssh_batch_result "nginx_installed" | tr -d '[:space:]')
    if [ "$NGINX_INSTALLED" != "INSTALLED" ]; then
        echo -e "  ${RED}✗ nginx is not installed on System Server${NC}"
        echo -e ""
        echo -e "  Please install nginx first:"
        echo -e "  ${CYAN}ssh $SYSTEM_SERVER '${USE_SUDO} apt update && ${USE_SUDO} apt install -y nginx'${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ nginx is installed${NC}"
    
    # Check nginx is running
    NGINX_RUNNING=$(ssh_batch_result "nginx_running" | tr -d '[:space:]')
    if [ "$NGINX_RUNNING" != "active" ]; then
        echo -e "  ${YELLOW}⚠ nginx is not running${NC}"
        echo -e "  ${YELLOW}  Start nginx: ssh $SYSTEM_SERVER '${USE_SUDO} systemctl start nginx'${NC}"
    fi
    
    # Check AXON directories exist
    UPSTREAMS_DIR=$(ssh_batch_result "upstreams_dir" | tr -d '[:space:]')
    SITES_DIR=$(ssh_batch_result "sites_dir" | tr -d '[:space:]')
    
    if [ "$UPSTREAMS_DIR" != "EXISTS" ] || [ "$SITES_DIR" != "EXISTS" ]; then
        echo -e "  ${RED}✗ AXON directories not found on System Server${NC}"
        echo -e ""
        echo -e "  Please run setup first:"
        echo -e "  ${CYAN}axon setup system-server${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ AXON directories exist${NC}"
    
    # Check nginx config validity
    NGINX_CONFIG_VALID=$(ssh_batch_result "nginx_config_valid" | tr -d '[:space:]')
    if [ "$NGINX_CONFIG_VALID" != "VALID" ]; then
        echo -e "  ${RED}✗ nginx configuration is invalid${NC}"
        echo -e ""
        echo -e "  Please fix nginx configuration on System Server:"
        echo -e "  ${CYAN}ssh $SYSTEM_SERVER '${USE_SUDO} nginx -t'${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ nginx configuration is valid${NC}"
    
    # Check AXON includes in nginx.conf
    UPSTREAMS_INCLUDED=$(ssh_batch_result "upstreams_included" | tr -d '[:space:]')
    SITES_INCLUDED=$(ssh_batch_result "sites_included" | tr -d '[:space:]')
    
    if [ "$UPSTREAMS_INCLUDED" != "INCLUDED" ] || [ "$SITES_INCLUDED" != "INCLUDED" ]; then
        echo -e "  ${RED}✗ AXON includes not found in nginx.conf${NC}"
        echo -e ""
        echo -e "  Please run setup first:"
        echo -e "  ${CYAN}axon setup system-server${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ AXON includes are configured${NC}"
    
    echo -e "  ${GREEN}✓ All pre-flight checks passed${NC}"
    echo ""
    
    # Step 1: Detect current deployment (PARALLELIZED)
    echo -e "${BLUE}Step 1/9: Detecting current deployment...${NC}"
    
    # PARALLEL: Query System Server and App Server simultaneously
    # Batch 1: Get current port from System Server
    ssh_batch_start
    ssh_batch_add "grep -oP 'server.*:\K\d+' $NGINX_UPSTREAM_FILE 2>/dev/null || echo ''" "current_port"
    ssh_batch_execute_async "$SSH_KEY" "$SYSTEM_SERVER" "system_check"
    
    # Batch 2: App Server pre-checks
    ssh_batch_start
    ssh_batch_add "docker ps --format '{{.Names}}\t{{.Ports}}' | grep '${PRODUCT_NAME}-${ENVIRONMENT}' || true" "list_containers"
    ssh_batch_add "mkdir -p $APP_DEPLOY_PATH" "create_dir"
    ssh_batch_add "[ -f '$ENV_PATH' ] && echo 'YES' || echo 'NO'" "check_env"
    ssh_batch_execute_async "$APP_SSH_KEY" "$APP_SERVER" "app_check"
    
    # Wait for both to complete
    ssh_batch_wait "system_check" "app_check"
    
    # Extract results from System Server
    CURRENT_PORT=$(ssh_batch_result_from "system_check" "current_port")
    CURRENT_PORT=$(echo "$CURRENT_PORT" | tr -d '[:space:]')  # Trim whitespace
    
    # Extract results from App Server
    CONTAINER_LIST=$(ssh_batch_result_from "app_check" "list_containers")
    
    # Find current container by port if we have one
    CURRENT_CONTAINER=""
    if [ -n "$CURRENT_PORT" ]; then
        # Parse container list to find one using current port
        CURRENT_CONTAINER=$(echo "$CONTAINER_LIST" | grep ":${CURRENT_PORT}->" | awk '{print $1}' | head -1)
        echo -e "  Current active port: ${YELLOW}$CURRENT_PORT${NC}"
        if [ -n "$CURRENT_CONTAINER" ]; then
            echo -e "  Current container:   ${YELLOW}$CURRENT_CONTAINER${NC}"
        fi
    else
        echo -e "  No active deployment detected (first deployment)"
    fi
    
    # Step 2: Generate new container name (timestamp-based for uniqueness)
    TIMESTAMP=$(date +%s)
    NEW_CONTAINER="${PRODUCT_NAME}-${ENVIRONMENT}-${TIMESTAMP}"
    
    echo -e "  New container:       ${GREEN}$NEW_CONTAINER${NC}"
    echo -e "  Port:                ${GREEN}Auto-assigned by Docker${NC}"
    echo ""
    
    # Step 2: Check deployment files on Application Server
    echo -e "${BLUE}Step 2/9: Checking deployment files on Application Server...${NC}"
    
    # Check if .env file exists (already checked in parallel batch above)
    ENV_EXISTS=$(ssh_batch_result_from "app_check" "check_env")
    
    if [ "$ENV_EXISTS" = "NO" ]; then
        echo -e "${YELLOW}⚠ Warning: Environment file not found on Application Server: ${ENV_PATH}${NC}"
        echo -e "${YELLOW}  Please create it manually with your environment variables${NC}"
        echo -e "${YELLOW}  Example: ssh ${APP_SERVER} 'cat > ${ENV_PATH}'${NC}"
        ssh_batch_cleanup "system_check" "app_check"
        exit 1
    fi
    echo -e "  ✓ Environment file exists: ${ENV_PATH}"
    echo ""
    
    # Clean up async batch resources from Step 1
    ssh_batch_cleanup "system_check" "app_check"
    
    # Step 4: Authenticate with registry on Application Server and pull latest image
    echo -e "${BLUE}Step 3/9: Authenticating and pulling image on Application Server...${NC}"
    echo -e "  Registry: ${YELLOW}${REGISTRY_PROVIDER}${NC}"
    echo -e "  Image:    ${YELLOW}${FULL_IMAGE}${NC}"
    
    # Generate registry-specific authentication commands for remote execution
    case $REGISTRY_PROVIDER in
        docker_hub)
            REGISTRY_USERNAME=$(get_registry_config "username")
            REGISTRY_TOKEN=$(get_registry_config "access_token")
            REGISTRY_TOKEN=$(expand_env_vars "$REGISTRY_TOKEN")
    
            ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    echo "$REGISTRY_TOKEN" | docker login -u "$REGISTRY_USERNAME" --password-stdin
    docker pull "$FULL_IMAGE"
EOF
            ;;
    
        aws_ecr)
            AWS_PROFILE=$(get_registry_config "profile")
            AWS_REGION=$(get_registry_config "region")
            REGISTRY_URL=$(build_registry_url)
    
            ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    aws ecr get-login-password --region "$AWS_REGION" --profile "$AWS_PROFILE" | \
        docker login --username AWS --password-stdin "$REGISTRY_URL" 2>/dev/null
    docker pull "$FULL_IMAGE"
EOF
            ;;
    
        google_gcr)
            SERVICE_ACCOUNT_KEY=$(get_registry_config "service_account_key")
            if [ -n "$SERVICE_ACCOUNT_KEY" ]; then
                SERVICE_ACCOUNT_KEY="${SERVICE_ACCOUNT_KEY/#\~/$HOME}"
                REMOTE_KEY="/tmp/gcp-key-$$.json"
                scp -i "$APP_SSH_KEY" "$SERVICE_ACCOUNT_KEY" "$APP_SERVER:$REMOTE_KEY"
    
                ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    cat "$REMOTE_KEY" | docker login -u _json_key --password-stdin https://gcr.io
    rm -f "$REMOTE_KEY"
    docker pull "$FULL_IMAGE"
EOF
            else
                ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    gcloud auth configure-docker --quiet
    docker pull "$FULL_IMAGE"
EOF
            fi
            ;;
    
        azure_acr)
            SP_ID=$(get_registry_config "service_principal_id")
            SP_PASSWORD=$(get_registry_config "service_principal_password")
            ADMIN_USER=$(get_registry_config "admin_username")
            ADMIN_PASSWORD=$(get_registry_config "admin_password")
            REGISTRY_NAME=$(get_registry_config "registry_name")
            REGISTRY_URL="${REGISTRY_NAME}.azurecr.io"
    
            if [ -n "$SP_ID" ] && [ -n "$SP_PASSWORD" ]; then
                SP_PASSWORD=$(expand_env_vars "$SP_PASSWORD")
                ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    echo "$SP_PASSWORD" | docker login "$REGISTRY_URL" --username "$SP_ID" --password-stdin
    docker pull "$FULL_IMAGE"
EOF
            elif [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASSWORD" ]; then
                ADMIN_PASSWORD=$(expand_env_vars "$ADMIN_PASSWORD")
                ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    echo "$ADMIN_PASSWORD" | docker login "$REGISTRY_URL" --username "$ADMIN_USER" --password-stdin
    docker pull "$FULL_IMAGE"
EOF
            else
                ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    az acr login --name "$REGISTRY_NAME"
    docker pull "$FULL_IMAGE"
EOF
            fi
            ;;
    
        *)
            echo -e "${RED}Error: Unknown registry provider: $REGISTRY_PROVIDER${NC}"
            exit 1
            ;;
    esac
    
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
    echo -e "${BLUE}Step 4/9: Starting new container on Application Server...${NC}"
    echo -e "  Container: ${YELLOW}${NEW_CONTAINER}${NC}"
    echo -e "  Port: ${YELLOW}Auto-assigned by Docker${NC}"
    
    # Build docker run command from axon.config.yml
    # FULL_IMAGE already defined earlier using build_image_uri()
    CONTAINER_NAME="${NEW_CONTAINER}"
    
    # Get network name from config with template substitution
    NETWORK_NAME_TEMPLATE=$(parse_config ".docker.network_name" "")
    eval "NETWORK_NAME=\"$NETWORK_NAME_TEMPLATE\""
    
    # Add network alias if configured
    NETWORK_ALIAS_TEMPLATE=$(parse_config ".docker.network_alias" "")
    eval "NETWORK_ALIAS=\"$NETWORK_ALIAS_TEMPLATE\""
    
    # Build the docker run command from axon.config.yml (single source of truth)
    # Note: We pass "auto" for app_port to let Docker assign a random port
    DOCKER_RUN_CMD=$(build_docker_run_command \
        "$CONTAINER_NAME" \
        "auto" \
        "$FULL_IMAGE" \
        "$ENV_PATH" \
        "$NETWORK_NAME" \
        "$NETWORK_ALIAS" \
        "$CONTAINER_PORT")
    
    ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    set -e
    cd $APP_DEPLOY_PATH
    
    FULL_IMAGE="${FULL_IMAGE}"
    CONTAINER_NAME="${CONTAINER_NAME}"
    NETWORK_NAME="${NETWORK_NAME}"
    
    # Create network if it doesn't exist
    if ! docker network ls | grep -q "\${NETWORK_NAME}"; then
        docker network create "\${NETWORK_NAME}"
    fi
    
    # Remove container if it already exists (for retries)
    if docker ps -a --format '{{.Names}}' | grep -q "^\${CONTAINER_NAME}\$"; then
        echo "  Removing existing container \${CONTAINER_NAME}..."
        docker stop "\${CONTAINER_NAME}" 2>/dev/null || true
        docker rm "\${CONTAINER_NAME}" 2>/dev/null || true
    fi
    
    # Start new container using docker run command built from docker-compose.yml
    # This ensures we don't interfere with the old container and maintains docker-compose.yml as source of truth
    echo "  Running docker run command: ${DOCKER_RUN_CMD}"
    ${DOCKER_RUN_CMD}
    
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
    
    # Query Docker for the assigned port
    APP_PORT=$(ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
        "docker port ${CONTAINER_NAME} ${CONTAINER_PORT} | cut -d: -f2")
    
    if [ -z "$APP_PORT" ]; then
        echo -e "${RED}Error: Could not determine assigned port${NC}"
        echo -e "${YELLOW}Stopping new container...${NC}"
        ssh -i "$APP_SSH_KEY" "$APP_SERVER" "docker stop ${CONTAINER_NAME} && docker rm ${CONTAINER_NAME}"
        exit 1
    fi
    
    echo -e "  ${GREEN}✓ Docker assigned port: ${APP_PORT}${NC}"
    echo ""
    
    # Step 5: Wait for Docker health check on Application Server
    echo -e "${BLUE}Step 5/9: Waiting for health check on Application Server...${NC}"
    
    RETRY_COUNT=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        # Query Docker's health status for the container
        HEALTH_STATUS=$(ssh -i "$APP_SSH_KEY" "$APP_SERVER" \
            "docker inspect --format='{{.State.Health.Status}}' ${CONTAINER_NAME} 2>/dev/null || echo 'none'")
    
        if [ "$HEALTH_STATUS" = "healthy" ]; then
            echo -e "${GREEN}  ✓ Health check passed!${NC}"
            break
        elif [ "$HEALTH_STATUS" = "none" ]; then
            echo -e "${YELLOW}  Warning: Container has no health check configured${NC}"
            echo -e "${YELLOW}  Proceeding anyway...${NC}"
            break
        fi
    
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ "$HEALTH_STATUS" = "unhealthy" ]; then
            echo -e "  ${RED}Attempt $RETRY_COUNT/$MAX_RETRIES (status: unhealthy)${NC}"
        else
            echo -e "  Attempt $RETRY_COUNT/$MAX_RETRIES (status: $HEALTH_STATUS)..."
        fi
        sleep $RETRY_INTERVAL
    done
    
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo -e "${RED}Error: Container failed to become healthy after $MAX_RETRIES attempts${NC}"
        echo -e "${RED}Final status: $HEALTH_STATUS${NC}"
    
        if [ "$AUTO_ROLLBACK" == "true" ]; then
            echo -e "${YELLOW}Auto-rollback enabled. Stopping new container...${NC}"
    
            ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    # Stop and remove the failed container
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
        echo "  Stopping ${CONTAINER_NAME}..."
        docker stop "${CONTAINER_NAME}" 2>/dev/null || true
        docker rm "${CONTAINER_NAME}" 2>/dev/null || true
    fi
EOF
    
            echo -e "${YELLOW}Old container still running. No impact to production.${NC}"
        fi
    
        exit 1
    fi
    echo ""
    
    # Step 6: Generate nginx configs (site + upstream)
    echo -e "${BLUE}Step 6/9: Generating nginx configurations for ${ENVIRONMENT}...${NC}"
    
    # Get nginx settings for this environment
    DOMAIN=$(get_nginx_domain "$ENVIRONMENT" "$CONFIG_FILE")
    PROXY_TIMEOUT=$(get_nginx_proxy_setting "timeout" "$CONFIG_FILE")
    PROXY_BUFFER_SIZE=$(get_nginx_proxy_setting "buffer_size" "$CONFIG_FILE")
    PROXY_BUFFERS=$(get_nginx_proxy_setting "buffers" "$CONFIG_FILE")
    PROXY_BUSY_BUFFERS=$(get_nginx_proxy_setting "busy_buffers_size" "$CONFIG_FILE")
    CUSTOM_PROPS=$(get_nginx_custom_properties "$CONFIG_FILE")
    HAS_SSL=$(has_ssl_config "$ENVIRONMENT" "$CONFIG_FILE")
    SSL_CERT=$(get_ssl_certificate "$ENVIRONMENT" "$CONFIG_FILE")
    SSL_KEY=$(get_ssl_certificate_key "$ENVIRONMENT" "$CONFIG_FILE")
    
    # Normalize timeout value (strip any existing 's' suffix to avoid duplication)
    PROXY_TIMEOUT=$(echo "$PROXY_TIMEOUT" | sed 's/s$//')
    
    # Generate site config
    echo -e "  Generating site config..."
    TEMP_SITE_FILE="/tmp/${NGINX_SITE_FILENAME%.conf}-site.conf"
    cat > "$TEMP_SITE_FILE" <<EOFSITE
    # AXON-managed site configuration for ${PRODUCT_NAME} - ${ENVIRONMENT}
    # Auto-generated by AXON deployment
    # Last updated: $(date)
    
    # HTTP Server
    server {
        listen 80;
        server_name ${DOMAIN};
    
        # Access logging
        access_log /var/log/nginx/${PRODUCT_NAME}-${ENVIRONMENT}.log combined;
    
        # To redirect HTTP to HTTPS, uncomment the line below and comment out the location block:
        # return 301 https://\$server_name\$request_uri;
    
        location / {
            proxy_pass http://${NGINX_UPSTREAM_NAME};
    
            # Proxy protocol and headers
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Host \$host:\$server_port;
            proxy_set_header X-Forwarded-Proto \$scheme;
    
            # WebSocket support
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
    
            # Proxy timeouts
            proxy_connect_timeout ${PROXY_TIMEOUT}s;
            proxy_send_timeout ${PROXY_TIMEOUT}s;
            proxy_read_timeout ${PROXY_TIMEOUT}s;
    
            # Buffer sizes
            proxy_buffer_size ${PROXY_BUFFER_SIZE};
            proxy_buffers ${PROXY_BUFFERS};
            proxy_busy_buffers_size ${PROXY_BUSY_BUFFERS};
EOFSITE
    
    # Add custom properties if present
    if [ -n "$CUSTOM_PROPS" ]; then
        echo "" >> "$TEMP_SITE_FILE"
        echo "        # Custom nginx properties from config" >> "$TEMP_SITE_FILE"
        echo "$CUSTOM_PROPS" | sed 's/^/        /' >> "$TEMP_SITE_FILE"
    fi
    
    # Close HTTP location and server block
    cat >> "$TEMP_SITE_FILE" <<'EOFSITE2'
        }
    
        # Health check endpoint (optional, no logging)
        location /health {
            access_log off;
            proxy_pass http://UPSTREAM_NAME_PLACEHOLDER/health;
        }
    }
EOFSITE2
    
    # Generate HTTPS server block if SSL is configured
    if [ "$HAS_SSL" = "true" ]; then
        cat >> "$TEMP_SITE_FILE" <<EOFHTTPS
    
    # HTTPS Server
    server {
        listen 443 ssl http2;
        server_name ${DOMAIN};
    
        # Access logging
        access_log /var/log/nginx/${PRODUCT_NAME}-${ENVIRONMENT}.log combined;
    
        # SSL certificates
        ssl_certificate ${SSL_CERT};
        ssl_certificate_key ${SSL_KEY};
    
        # SSL configuration
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;
    
        location / {
            proxy_pass http://${NGINX_UPSTREAM_NAME};
    
            # Proxy protocol and headers
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Host \$host:\$server_port;
            proxy_set_header X-Forwarded-Proto \$scheme;
    
            # WebSocket support
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
    
            # Proxy timeouts
            proxy_connect_timeout ${PROXY_TIMEOUT}s;
            proxy_send_timeout ${PROXY_TIMEOUT}s;
            proxy_read_timeout ${PROXY_TIMEOUT}s;
    
            # Buffer sizes
            proxy_buffer_size ${PROXY_BUFFER_SIZE};
            proxy_buffers ${PROXY_BUFFERS};
            proxy_busy_buffers_size ${PROXY_BUSY_BUFFERS};
EOFHTTPS
    
        # Add custom properties to HTTPS block if present
        if [ -n "$CUSTOM_PROPS" ]; then
            echo "" >> "$TEMP_SITE_FILE"
            echo "        # Custom nginx properties from config" >> "$TEMP_SITE_FILE"
            echo "$CUSTOM_PROPS" | sed 's/^/        /' >> "$TEMP_SITE_FILE"
        fi
    
        # Close HTTPS location and server block
        cat >> "$TEMP_SITE_FILE" <<'EOFHTTPS2'
        }
    
        # Health check endpoint (optional, no logging)
        location /health {
            access_log off;
            proxy_pass http://UPSTREAM_NAME_PLACEHOLDER/health;
        }
    }
EOFHTTPS2
    fi
    
    # Replace placeholders
    sed -i.bak "s|UPSTREAM_NAME_PLACEHOLDER|${NGINX_UPSTREAM_NAME}|g" "$TEMP_SITE_FILE"
    rm -f "${TEMP_SITE_FILE}.bak"
    
    echo -e "  ✓ Site config generated: ${NGINX_SITE_FILENAME}"
    
    # Generate upstream config
    echo -e "  Generating upstream config..."
    TEMP_UPSTREAM_FILE="/tmp/${NGINX_UPSTREAM_FILENAME%.conf}-upstream.conf"
    cat > "$TEMP_UPSTREAM_FILE" <<EOFUPSTREAM
    # AXON-managed upstream for ${PRODUCT_NAME} - ${ENVIRONMENT}
    # Auto-generated by AXON deployment
    # Last updated: $(date)
    
    upstream ${NGINX_UPSTREAM_NAME} {
        server ${APP_UPSTREAM_IP}:${APP_PORT};
    }
EOFUPSTREAM
    
    echo -e "  ✓ Upstream config generated: ${NGINX_UPSTREAM_FILENAME}"
    
    # Step 7: Upload and apply nginx configs
    echo -e "${BLUE}Step 7/9: Updating System Server nginx...${NC}"
    
    # Batch: Ensure directories, upload configs, test, and reload nginx
    ssh_batch_start
    ssh_batch_add "${USE_SUDO} mkdir -p ${NGINX_AXON_DIR}/upstreams ${NGINX_AXON_DIR}/sites" "ensure_dirs"
    ssh_batch_execute "$SSH_KEY" "$SYSTEM_SERVER"
    
    # Upload both configs (using distinct temp names on both local and remote)
    REMOTE_TEMP_SITE="/tmp/${NGINX_SITE_FILENAME%.conf}-site.conf"
    REMOTE_TEMP_UPSTREAM="/tmp/${NGINX_UPSTREAM_FILENAME%.conf}-upstream.conf"
    
    scp -i "$SSH_KEY" "$TEMP_SITE_FILE" \
        "${SYSTEM_SERVER}:${REMOTE_TEMP_SITE}" > /dev/null 2>&1
    scp -i "$SSH_KEY" "$TEMP_UPSTREAM_FILE" \
        "${SYSTEM_SERVER}:${REMOTE_TEMP_UPSTREAM}" > /dev/null 2>&1
    
    # Move to final locations and validate
    ssh_batch_start
    ssh_batch_add "${USE_SUDO} mv ${REMOTE_TEMP_SITE} ${NGINX_SITE_FILE}" "move_site"
    ssh_batch_add "${USE_SUDO} mv ${REMOTE_TEMP_UPSTREAM} ${NGINX_UPSTREAM_FILE}" "move_upstream"
    ssh_batch_add "${USE_SUDO} nginx -t 2>&1" "test_nginx"
    ssh_batch_add "${USE_SUDO} nginx -s reload" "reload_nginx"
    ssh_batch_execute "$SSH_KEY" "$SYSTEM_SERVER"
    
    # Check if upload succeeded
    if [ $(ssh_batch_exitcode "move_site") -ne 0 ] || [ $(ssh_batch_exitcode "move_upstream") -ne 0 ]; then
        echo -e "${RED}Error: Failed to update nginx configuration files${NC}"
        # Cleanup local temp files
        rm -f "$TEMP_SITE_FILE" "$TEMP_UPSTREAM_FILE"
        exit 1
    fi
    
    echo -e "  ✓ Site config: ${NGINX_SITE_FILE}"
    echo -e "  ✓ Upstream config: ${NGINX_UPSTREAM_FILE} (port $APP_PORT)"
    
    # Cleanup local temp files
    rm -f "$TEMP_SITE_FILE" "$TEMP_UPSTREAM_FILE"
    echo ""
    
    # Step 8: Test nginx configuration
    echo -e "${BLUE}Step 8/9: Testing nginx configuration on System Server...${NC}"
    
    NGINX_TEST_OUTPUT=$(ssh_batch_result "test_nginx")
    
    if ! echo "$NGINX_TEST_OUTPUT" | grep -q "successful"; then
        echo -e "${RED}Error: nginx configuration test failed!${NC}"
        echo ""
        echo -e "${YELLOW}nginx -t output:${NC}"
        echo "$NGINX_TEST_OUTPUT"
        echo ""
    
        # Rollback nginx config
        echo -e "${YELLOW}Rolling back nginx configuration...${NC}"
        ROLLBACK_CONFIG="upstream $NGINX_UPSTREAM_NAME {
        server $APP_UPSTREAM_IP:$CURRENT_PORT;
    }"
        ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "echo '$ROLLBACK_CONFIG' | ${USE_SUDO} tee $NGINX_UPSTREAM_FILE > /dev/null"
    
        # Stop new container
        echo -e "${YELLOW}Stopping new container on Application Server...${NC}"
        ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    # Stop and remove the specific failed container
    FAILED_CONTAINER="${PRODUCT_NAME}-${ENVIRONMENT}-${APP_PORT}"
    
    if docker ps -a --format '{{.Names}}' | grep -q "^\${FAILED_CONTAINER}\$"; then
        echo "  Stopping \${FAILED_CONTAINER}..."
        docker stop "\${FAILED_CONTAINER}" 2>/dev/null || true
        docker rm "\${FAILED_CONTAINER}" 2>/dev/null || true
    fi
EOF
    
        exit 1
    fi
    
    echo -e "  ✓ nginx configuration is valid"
    
    # Check reload result from batch (reload happened during Step 7)
    if [ $(ssh_batch_exitcode "reload_nginx") -ne 0 ]; then
        echo -e "${RED}Error: nginx reload failed!${NC}"
        exit 1
    fi
    
    echo -e "  ${GREEN}✓ nginx reloaded successfully (zero-downtime)${NC}"
    echo -e "  ${GREEN}✓ Traffic now flows to new container (port $APP_PORT)${NC}"
    echo ""
    
    # Step 9: Graceful shutdown of old containers (BACKGROUND)
    echo -e "${BLUE}Step 9/9: Gracefully shutting down old containers (timeout: ${GRACEFUL_SHUTDOWN_TIMEOUT}s)...${NC}"
    
    # Run cleanup in background - deployment is already successful
    {
        ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
    # Find all containers for this product/environment except the new one
    NEW_CONTAINER="${CONTAINER_NAME}"
    PRODUCT_ENV_PREFIX="${PRODUCT_NAME}-${ENVIRONMENT}"
    TIMEOUT="${GRACEFUL_SHUTDOWN_TIMEOUT}"
    
    # Get list of all containers for this product/environment
    OLD_CONTAINERS=\$(docker ps -a --filter "name=\${PRODUCT_ENV_PREFIX}" --format '{{.Names}}' | grep -v "^\${NEW_CONTAINER}\$" || true)
    
    if [ -n "\$OLD_CONTAINERS" ]; then
        # Silently cleanup old containers in background
        for container in \$OLD_CONTAINERS; do
            docker stop --time "\${TIMEOUT}" "\$container" 2>/dev/null || true
            docker rm "\$container" 2>/dev/null || true
        done
    fi
EOF
    } &
    
    # Store cleanup PID for reference
    CLEANUP_PID=$!
    
    echo -e "  ${GREEN}✓ Cleanup initiated in background (PID: $CLEANUP_PID)${NC}"
    echo -e "  ${CYAN}Note: Old containers are being removed asynchronously${NC}"
    echo ""
    
    # Success!
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}✓ Deployment completed successfully!${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo ""
    
    echo -e "${CYAN}Deployment Summary:${NC}"
    echo -e "  Product:          ${YELLOW}${PRODUCT_NAME}${NC}"
    echo -e "  Environment:      ${YELLOW}${ENVIRONMENT}${NC}"
    echo -e "  Active Port:      ${GREEN}${APP_PORT}${NC}"
    echo -e "  Container:        ${YELLOW}${CONTAINER_NAME}${NC}"
    echo -e "  Image:            ${YELLOW}${FULL_IMAGE}${NC}"
    echo ""
    
    echo -e "${CYAN}Useful Commands:${NC}"
    echo -e "  View logs:        ${BLUE}ssh -i $APP_SSH_KEY $APP_SERVER 'docker logs -f ${CONTAINER_NAME}'${NC}"
    echo -e "  Container status: ${BLUE}ssh -i $APP_SSH_KEY $APP_SERVER 'docker ps | grep ${PRODUCT_NAME}-${ENVIRONMENT}'${NC}"
    echo -e "  nginx upstream:   ${BLUE}ssh -i $SSH_KEY $SYSTEM_SERVER 'cat $NGINX_UPSTREAM_FILE'${NC}"
    echo ""
    
    # Batch: Display container status and logs (App Server)
    ssh_batch_start
    ssh_batch_add "docker ps --filter 'name=${PRODUCT_NAME}-${ENVIRONMENT}' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" "container_status"
    ssh_batch_add "if docker ps --filter 'name=${CONTAINER_NAME}' --format '{{.Names}}' | grep -q .; then docker logs --tail=20 '${CONTAINER_NAME}' 2>&1 | head -20; else echo 'Container not found'; fi" "container_logs"
    ssh_batch_execute "$APP_SSH_KEY" "$APP_SERVER"
    
    # Display container status on Application Server
    echo -e "${CYAN}Container Status on Application Server:${NC}"
    ssh_batch_result "container_status"
    echo ""
    
    # Display recent logs from Application Server
    echo -e "${CYAN}Recent Logs (last 20 lines):${NC}"
    LOGS_OUTPUT=$(ssh_batch_result "container_logs")
    if [ "$LOGS_OUTPUT" != "Container not found" ]; then
        echo "$LOGS_OUTPUT"
    else
        echo "Container ${CONTAINER_NAME} not found"
    fi
    echo ""
}

# ==============================================================================
# Static Site Deployment Function
# ==============================================================================
deploy_static() {
    # Get per-environment deployment configuration
    DEPLOY_PATH=$(get_deploy_path "$ENVIRONMENT" "$CONFIG_FILE")
    DOMAIN=$(get_domain "$ENVIRONMENT" "$CONFIG_FILE")

    # Get global static configuration
    DEPLOY_USER=$(get_static_deploy_user "$CONFIG_FILE")
    KEEP_RELEASES=$(get_static_keep_releases "$CONFIG_FILE")

    # Get nginx paths and names from defaults library
    NGINX_AXON_DIR=$(get_nginx_axon_dir "$CONFIG_FILE")
    NGINX_SITE_FILENAME=$(get_site_filename "$PRODUCT_NAME" "$ENVIRONMENT")
    NGINX_SITE_FILE="${NGINX_AXON_DIR}/sites/${NGINX_SITE_FILENAME}"

    # Validate required per-environment configuration
    if [ -z "$DEPLOY_PATH" ]; then
        echo -e "${RED}Error: environments.${ENVIRONMENT}.deploy_path not configured${NC}"
        echo "Please set 'environments.${ENVIRONMENT}.deploy_path' in $CONFIG_FILE"
        exit 1
    fi

    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}Error: environments.${ENVIRONMENT}.domain not configured${NC}"
        echo "Please set 'environments.${ENVIRONMENT}.domain' in $CONFIG_FILE"
        exit 1
    fi

    # Validate System Server configuration
    if ! require_system_server "$CONFIG_FILE"; then
        exit 1
    fi

    # Display configuration
    echo -e "${BLUE}Configuration loaded:${NC}"
    echo -e "  Product:            ${YELLOW}${PRODUCT_NAME}${NC}"
    echo -e "  Environment:        ${YELLOW}${ENVIRONMENT}${NC}"
    echo -e "  Deploy Type:        ${YELLOW}Static Site${NC}"
    echo -e "  System Server:      ${YELLOW}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
    echo -e "  Deploy Path:        ${YELLOW}${DEPLOY_PATH}/${ENVIRONMENT}${NC}"
    echo -e "  Keep Releases:      ${YELLOW}${KEEP_RELEASES}${NC}"
    echo ""

    # SSH connection strings
    SYSTEM_SERVER="${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}"

    # Check SSH key exists
    if [ ! -f "$SSH_KEY" ]; then
        echo -e "${RED}Error: System Server SSH key not found: $SSH_KEY${NC}"
        echo "Please check your configuration."
        exit 1
    fi

    # Determine sudo usage
    if [ "$SYSTEM_SERVER_USER" = "root" ]; then
        USE_SUDO=""
    else
        USE_SUDO="sudo"
    fi

    # Step 1: Find latest build archive
    echo -e "${BLUE}Step 1/12: Finding build archive on System Server...${NC}"

    LATEST_ARCHIVE=$(ssh -i "$SSH_KEY" "$SYSTEM_SERVER" \
        "ls -t /tmp/static-build-*.tar.gz 2>/dev/null | head -n 1")

    if [ -z "$LATEST_ARCHIVE" ]; then
        echo -e "${RED}Error: No build archive found in /tmp/ on System Server${NC}"
        echo "Please run build and push first:"
        echo "  axon build ${ENVIRONMENT}"
        echo "  axon push ${ENVIRONMENT}"
        exit 1
    fi

    # Extract release name from archive filename
    ARCHIVE_BASENAME=$(basename "$LATEST_ARCHIVE")
    RELEASE_NAME=$(echo "$ARCHIVE_BASENAME" | sed 's/static-build-\(.*\)\.tar\.gz/\1/')

    ARCHIVE_SIZE=$(ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "du -sh '$LATEST_ARCHIVE' | cut -f1")

    echo -e "  Archive:         ${YELLOW}${LATEST_ARCHIVE}${NC}"
    echo -e "  Release Name:    ${YELLOW}${RELEASE_NAME}${NC}"
    echo -e "  Archive Size:    ${YELLOW}${ARCHIVE_SIZE}${NC}"
    echo ""

    # Step 2: Create directory structure
    echo -e "${BLUE}Step 2/12: Creating release directory structure...${NC}"

    RELEASE_PATH=$(get_release_path "$DEPLOY_PATH" "$ENVIRONMENT" "$RELEASE_NAME")
    SHARED_PATH=$(get_shared_path "$DEPLOY_PATH" "$ENVIRONMENT")
    CURRENT_SYMLINK=$(get_current_symlink_path "$DEPLOY_PATH" "$ENVIRONMENT")

    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" bash <<EOF
set -e
# Create directories
$USE_SUDO mkdir -p "$RELEASE_PATH"
$USE_SUDO mkdir -p "$SHARED_PATH"
$USE_SUDO mkdir -p "$(dirname "$CURRENT_SYMLINK")"
echo "✓ Directories created"
EOF

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to create directory structure${NC}"
        exit 1
    fi

    echo -e "  Release Path:    ${YELLOW}${RELEASE_PATH}${NC}"
    echo -e "  Shared Path:     ${YELLOW}${SHARED_PATH}${NC}"
    echo -e "  Current Symlink: ${YELLOW}${CURRENT_SYMLINK}${NC}"
    echo ""

    # Step 3: Extract archive
    echo -e "${BLUE}Step 3/12: Extracting build archive...${NC}"

    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" bash <<EOF
set -e
cd "$RELEASE_PATH"
$USE_SUDO tar -xzf "$LATEST_ARCHIVE"
if [ \$? -eq 0 ]; then
    echo "✓ Archive extracted successfully"
else
    echo "Error: Failed to extract archive"
    exit 1
fi
EOF

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to extract archive${NC}"
        exit 1
    fi
    echo ""

    # Step 4: Setup shared directories
    echo -e "${BLUE}Step 4/12: Setting up shared directories...${NC}"

    SHARED_DIRS=$(get_static_shared_dirs "$CONFIG_FILE")
    if [ -n "$SHARED_DIRS" ]; then
        while IFS= read -r shared_dir; do
            if [ -n "$shared_dir" ]; then
                ssh -i "$SSH_KEY" "$SYSTEM_SERVER" bash <<EOF
set -e
# Create shared directory if it doesn't exist
$USE_SUDO mkdir -p "${SHARED_PATH}/${shared_dir}"

# Remove directory from release if it exists
$USE_SUDO rm -rf "${RELEASE_PATH}/${shared_dir}"

# Create symlink
$USE_SUDO ln -s "${SHARED_PATH}/${shared_dir}" "${RELEASE_PATH}/${shared_dir}"

echo "✓ Linked: ${shared_dir} -> ${SHARED_PATH}/${shared_dir}"
EOF
            fi
        done <<< "$SHARED_DIRS"
    else
        echo "  No shared directories configured"
    fi
    echo ""

    # Step 5: Set file ownership and permissions
    echo -e "${BLUE}Step 5/12: Setting file permissions...${NC}"

    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" bash <<EOF
set -e
${USE_SUDO} chown -R ${DEPLOY_USER}:${DEPLOY_USER} "$RELEASE_PATH"
${USE_SUDO} chmod -R 755 "$RELEASE_PATH"
echo "✓ Permissions set (owner: ${DEPLOY_USER})"
EOF

    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}Warning: Failed to set permissions (continuing anyway)${NC}"
    fi
    echo ""

    # Step 6: Validate required files
    echo -e "${BLUE}Step 6/12: Validating required files...${NC}"

    REQUIRED_FILES=$(get_static_required_files "$CONFIG_FILE")
    if [ -n "$REQUIRED_FILES" ]; then
        VALIDATION_FAILED=false
        while IFS= read -r required_file; do
            if [ -n "$required_file" ]; then
                if ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "[ -f '${RELEASE_PATH}/${required_file}' ]"; then
                    echo -e "  ${GREEN}✓${NC} ${required_file}"
                else
                    echo -e "  ${RED}✗${NC} ${required_file}"
                    VALIDATION_FAILED=true
                fi
            fi
        done <<< "$REQUIRED_FILES"

        if [ "$VALIDATION_FAILED" = true ]; then
            echo -e "${RED}Error: Required files missing${NC}"
            exit 1
        fi
    else
        echo "  No required files configured"
    fi
    echo ""

    # Step 7: Detect current deployment
    echo -e "${BLUE}Step 7/12: Detecting current deployment...${NC}"

    CURRENT_RELEASE=$(ssh -i "$SSH_KEY" "$SYSTEM_SERVER" \
        "if [ -L '$CURRENT_SYMLINK' ]; then readlink '$CURRENT_SYMLINK' | xargs basename; else echo ''; fi")

    if [ -n "$CURRENT_RELEASE" ]; then
        echo -e "  Current Release: ${YELLOW}${CURRENT_RELEASE}${NC}"
    else
        echo -e "  No current deployment (first deployment)"
    fi
    echo ""

    # Step 8: Atomic symlink switch
    echo -e "${BLUE}Step 8/12: Switching to new release (atomic operation)...${NC}"

    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" bash <<EOF
set -e
# Create temporary symlink
TEMP_SYMLINK="${CURRENT_SYMLINK}.tmp.\$\$"
$USE_SUDO ln -s "$RELEASE_PATH" "\$TEMP_SYMLINK"

# Atomic move
$USE_SUDO mv -Tf "\$TEMP_SYMLINK" "$CURRENT_SYMLINK"

if [ \$? -eq 0 ]; then
    echo "✓ Symlink switched atomically"
else
    echo "Error: Failed to switch symlink"
    $USE_SUDO rm -f "\$TEMP_SYMLINK"
    exit 1
fi
EOF

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to switch symlink${NC}"
        exit 1
    fi

    echo -e "  ${GREEN}✓ Current symlink now points to: ${RELEASE_NAME}${NC}"
    echo ""

    # Step 9: Generate/Update nginx site configuration
    echo -e "${BLUE}Step 9/12: Generating nginx site configuration...${NC}"

    # Get nginx settings for this environment
    DOMAIN=$(get_nginx_domain "$ENVIRONMENT" "$CONFIG_FILE")
    HAS_SSL=$(has_ssl_config "$ENVIRONMENT" "$CONFIG_FILE")
    SSL_CERT=$(get_ssl_certificate "$ENVIRONMENT" "$CONFIG_FILE")
    SSL_KEY=$(get_ssl_certificate_key "$ENVIRONMENT" "$CONFIG_FILE")
    CUSTOM_PROPS=$(get_nginx_custom_properties "$CONFIG_FILE")

    # Generate site config for static files
    TEMP_SITE_FILE="/tmp/${NGINX_SITE_FILENAME%.conf}-static-site.conf"
    cat > "$TEMP_SITE_FILE" <<EOFSITE
# AXON-managed static site configuration for ${PRODUCT_NAME} - ${ENVIRONMENT}
# Auto-generated by AXON deployment
# Last updated: $(date)

# HTTP Server
server {
    listen 80;
    server_name ${DOMAIN};

    # Access logging
    access_log /var/log/nginx/${PRODUCT_NAME}-${ENVIRONMENT}.log combined;

    # Document root
    root ${CURRENT_SYMLINK};
    index index.html index.htm;

    # To redirect HTTP to HTTPS, uncomment the line below and comment out the location block:
    # return 301 https://\$server_name\$request_uri;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
EOFSITE

    # Add custom properties if present
    if [ -n "$CUSTOM_PROPS" ]; then
        echo "" >> "$TEMP_SITE_FILE"
        echo "    # Custom nginx properties from config" >> "$TEMP_SITE_FILE"
        echo "$CUSTOM_PROPS" | sed 's/^/    /' >> "$TEMP_SITE_FILE"
    fi

    # Close HTTP server block
    echo "}" >> "$TEMP_SITE_FILE"

    # Generate HTTPS server block if SSL is configured
    if [ "$HAS_SSL" = "true" ]; then
        cat >> "$TEMP_SITE_FILE" <<EOFHTTPS

# HTTPS Server
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    # Access logging
    access_log /var/log/nginx/${PRODUCT_NAME}-${ENVIRONMENT}.log combined;

    # SSL certificates
    ssl_certificate ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};

    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    # Document root
    root ${CURRENT_SYMLINK};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
EOFHTTPS

        # Add custom properties to HTTPS block if present
        if [ -n "$CUSTOM_PROPS" ]; then
            echo "" >> "$TEMP_SITE_FILE"
            echo "    # Custom nginx properties from config" >> "$TEMP_SITE_FILE"
            echo "$CUSTOM_PROPS" | sed 's/^/    /' >> "$TEMP_SITE_FILE"
        fi

        # Close HTTPS server block
        echo "}" >> "$TEMP_SITE_FILE"
    fi

    echo -e "  ✓ Site config generated: ${NGINX_SITE_FILENAME}"
    echo ""

    # Step 10: Upload nginx configuration
    echo -e "${BLUE}Step 10/12: Uploading nginx configuration to System Server...${NC}"

    REMOTE_TEMP_SITE="/tmp/${NGINX_SITE_FILENAME%.conf}-static-site.conf"

    # Ensure sites directory exists
    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "${USE_SUDO} mkdir -p ${NGINX_AXON_DIR}/sites"

    # Upload config
    scp -i "$SSH_KEY" "$TEMP_SITE_FILE" \
        "${SYSTEM_SERVER}:${REMOTE_TEMP_SITE}" > /dev/null 2>&1

    # Move to final location
    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "${USE_SUDO} mv ${REMOTE_TEMP_SITE} ${NGINX_SITE_FILE}"

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to upload nginx configuration${NC}"
        rm -f "$TEMP_SITE_FILE"
        exit 1
    fi

    echo -e "  ✓ Site config uploaded: ${NGINX_SITE_FILE}"

    # Cleanup local temp file
    rm -f "$TEMP_SITE_FILE"
    echo ""

    # Step 11: Test and reload nginx
    echo -e "${BLUE}Step 11/12: Testing and reloading nginx...${NC}"

    # Test nginx configuration
    NGINX_TEST_OUTPUT=$(ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "${USE_SUDO} nginx -t 2>&1")

    if ! echo "$NGINX_TEST_OUTPUT" | grep -q "successful"; then
        echo -e "${RED}Error: nginx configuration test failed!${NC}"
        echo ""
        echo -e "${YELLOW}nginx -t output:${NC}"
        echo "$NGINX_TEST_OUTPUT"
        echo ""

        # Rollback symlink if there was a previous release
        if [ -n "$CURRENT_RELEASE" ]; then
            echo -e "${YELLOW}Rolling back to previous release...${NC}"
            PREVIOUS_RELEASE_PATH=$(get_release_path "$DEPLOY_PATH" "$ENVIRONMENT" "$CURRENT_RELEASE")
            ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "ln -snf '$PREVIOUS_RELEASE_PATH' '$CURRENT_SYMLINK'"
        fi

        exit 1
    fi

    echo -e "  ${GREEN}✓ nginx configuration is valid${NC}"

    # Reload nginx
    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" "${USE_SUDO} nginx -s reload"

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: nginx reload failed!${NC}"
        exit 1
    fi

    echo -e "  ${GREEN}✓ nginx reloaded successfully (zero-downtime)${NC}"
    echo ""

    # Step 12: Cleanup old releases
    echo -e "${BLUE}Step 12/12: Cleaning up old releases (keeping last ${KEEP_RELEASES})...${NC}"

    ssh -i "$SSH_KEY" "$SYSTEM_SERVER" bash <<EOF
set -e
RELEASES_DIR="${DEPLOY_PATH}/${ENVIRONMENT}/releases"
if [ -d "\$RELEASES_DIR" ]; then
    # List releases by modification time (oldest first)
    cd "\$RELEASES_DIR"
    RELEASES=\$(ls -t | tail -n +\$((${KEEP_RELEASES} + 1)))

    if [ -n "\$RELEASES" ]; then
        echo "Removing old releases:"
        for release in \$RELEASES; do
            echo "  - \$release"
            $USE_SUDO rm -rf "\$release"
        done
    else
        echo "No old releases to remove"
    fi
fi
EOF

    echo ""

    # Success!
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}✓ Deployment completed successfully!${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo ""

    echo -e "${CYAN}Deployment Summary:${NC}"
    echo -e "  Product:          ${YELLOW}${PRODUCT_NAME}${NC}"
    echo -e "  Environment:      ${YELLOW}${ENVIRONMENT}${NC}"
    echo -e "  Release:          ${YELLOW}${RELEASE_NAME}${NC}"
    echo -e "  Deploy Path:      ${YELLOW}${CURRENT_SYMLINK}${NC}"
    echo -e "  Domain:           ${YELLOW}${DOMAIN}${NC}"
    echo ""

    echo -e "${CYAN}Useful Commands:${NC}"
    echo -e "  View site:        ${BLUE}http://${DOMAIN}${NC}"
    echo -e "  Current release:  ${BLUE}ssh -i $SSH_KEY $SYSTEM_SERVER 'readlink $CURRENT_SYMLINK'${NC}"
    echo -e "  nginx config:     ${BLUE}ssh -i $SSH_KEY $SYSTEM_SERVER 'cat $NGINX_SITE_FILE'${NC}"
    echo -e "  List releases:    ${BLUE}ssh -i $SSH_KEY $SYSTEM_SERVER 'ls -lt ${DEPLOY_PATH}/${ENVIRONMENT}/releases'${NC}"
    echo ""
}

# ==============================================================================
# Route to appropriate deployment function based on product type
# ==============================================================================

if [ "$PRODUCT_TYPE" = "static" ]; then
    deploy_static
else
    deploy_docker
fi

exit 0
