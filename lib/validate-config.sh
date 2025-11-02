#!/bin/bash
# Configuration Validator for axon.config.yml
# Validates that all required fields are present and properly formatted

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Use current working directory for PRODUCT_ROOT (where config/Dockerfile live)
PRODUCT_ROOT="${PROJECT_ROOT:-$PWD}"

# Default configuration file
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
ENVIRONMENT=""
STRICT_MODE=false
CHECK_REMOTE=false
ERRORS=0
WARNINGS=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --strict)
            STRICT_MODE=true
            shift
            ;;
        --check-remote)
            CHECK_REMOTE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Validates axon.config.yml for required fields and proper formatting"
            echo ""
            echo "Options:"
            echo "  -c, --config FILE       Specify config file (default: axon.config.yml)"
            echo "  -e, --environment ENV   Validate specific environment only"
            echo "  --strict                Treat warnings as errors"
            echo "  --check-remote          Check remote nginx configuration (requires SSH)"
            echo "  -h, --help              Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Validate default config"
            echo "  $0 --config custom.yml                # Validate custom config"
            echo "  $0 --environment production           # Validate production env only"
            echo "  $0 --strict                           # Fail on warnings"
            echo "  $0 --check-remote                     # Validate + check remote nginx"
            exit 0
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            echo -e "${RED}Error: Unexpected positional argument: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Make CONFIG_FILE absolute path if it's relative
if [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="${PRODUCT_ROOT}/${CONFIG_FILE}"
fi

# Source config parser and defaults library
source "$MODULE_DIR/lib/config-parser.sh"
source "$MODULE_DIR/lib/defaults.sh"

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Configuration Validator${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""
echo -e "Config file: ${YELLOW}${CONFIG_FILE}${NC}"
echo ""

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}✗ Error: Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Check if yq is installed
if ! check_yq; then
    exit 1
fi

# Function to report error
report_error() {
    local message=$1
    echo -e "${RED}✗ ERROR: ${message}${NC}"
    ERRORS=$((ERRORS + 1))
}

# Function to report warning
report_warning() {
    local message=$1
    echo -e "${YELLOW}⚠ WARNING: ${message}${NC}"
    WARNINGS=$((WARNINGS + 1))
}

# Function to report success
report_success() {
    local message=$1
    echo -e "${GREEN}✓ ${message}${NC}"
}

# Function to validate required field
validate_required() {
    local key=$1
    local description=$2
    local value=$(parse_yaml_key "$key" "" "$CONFIG_FILE")

    if [ -z "$value" ] || [ "$value" = "null" ]; then
        report_error "Required field missing: ${key} (${description})"
        return 1
    else
        report_success "${description}: ${value}"
        return 0
    fi
}

# Function to validate optional field
validate_optional() {
    local key=$1
    local description=$2
    local default=$3
    local value=$(parse_yaml_key "$key" "" "$CONFIG_FILE")

    if [ -z "$value" ] || [ "$value" = "null" ]; then
        echo -e "  ${BLUE}○ ${description}: <not set> (will use default: ${default})${NC}"
    else
        report_success "${description}: ${value}"
    fi
}

# Function to validate file path exists
validate_file_path() {
    local key=$1
    local description=$2
    local value=$(parse_yaml_key "$key" "" "$CONFIG_FILE")

    if [ -z "$value" ] || [ "$value" = "null" ]; then
        report_error "Required field missing: ${key} (${description})"
        return 1
    fi

    # Expand tilde
    local expanded_path="${value/#\~/$HOME}"

    if [ ! -f "$expanded_path" ]; then
        report_error "${description} not found: ${expanded_path}"
        return 1
    else
        report_success "${description}: ${value} ✓ (file exists)"
        return 0
    fi
}

# Function to validate AWS account ID format (for AWS ECR)
validate_aws_account_id() {
    local value=$(parse_yaml_key "registry.aws_ecr.account_id" "" "$CONFIG_FILE")

    if [ -z "$value" ] || [ "$value" = "null" ]; then
        report_error "Required field missing: registry.aws_ecr.account_id"
        return 1
    fi

    # Expand environment variables if present (e.g., ${AWS_ACCOUNT_ID})
    local expanded_value=$(expand_env_vars "$value")

    # AWS account IDs are 12 digits
    if ! [[ "$expanded_value" =~ ^[0-9]{12}$ ]]; then
        report_error "Invalid AWS account ID format: ${value} (expanded: ${expanded_value}, must be 12 digits)"
        return 1
    else
        report_success "AWS Account ID: ${value} (expanded: ${expanded_value})"
        return 0
    fi
}

# Function to validate registry configuration based on provider
validate_registry_config() {
    local provider=$(parse_yaml_key "registry.provider" "" "$CONFIG_FILE")

    if [ -z "$provider" ] || [ "$provider" = "null" ]; then
        report_error "Required field missing: registry.provider"
        echo ""
        echo "  Supported providers: docker_hub, aws_ecr, google_gcr, azure_acr"
        return 1
    fi

    case $provider in
        docker_hub)
            report_success "Registry Provider: docker_hub"
            validate_required "registry.docker_hub.username" "Docker Hub username"
            validate_required "registry.docker_hub.access_token" "Docker Hub access token"
            validate_optional "registry.docker_hub.namespace" "Docker Hub namespace" "\${username}"
            validate_optional "registry.docker_hub.repository" "Docker Hub repository" "\${product.name}"
            ;;

        aws_ecr)
            report_success "Registry Provider: aws_ecr"
            validate_required "registry.aws_ecr.profile" "AWS profile"
            validate_required "registry.aws_ecr.region" "AWS region"
            validate_aws_account_id
            validate_optional "registry.aws_ecr.repository" "ECR repository" "\${product.name}"
            ;;

        google_gcr)
            report_success "Registry Provider: google_gcr"
            validate_required "registry.google_gcr.project_id" "GCP project ID"
            validate_optional "registry.google_gcr.location" "GCR location" "us"
            validate_optional "registry.google_gcr.service_account_key" "Service account key" "(uses gcloud CLI)"
            validate_optional "registry.google_gcr.use_artifact_registry" "Use Artifact Registry" "false"
            validate_optional "registry.google_gcr.repository" "GCR repository" "\${product.name}"
            ;;

        azure_acr)
            report_success "Registry Provider: azure_acr"
            validate_required "registry.azure_acr.registry_name" "ACR registry name"

            # Check if at least one auth method is configured
            local sp_id=$(parse_yaml_key "registry.azure_acr.service_principal_id" "" "$CONFIG_FILE")
            local admin_user=$(parse_yaml_key "registry.azure_acr.admin_username" "" "$CONFIG_FILE")

            if [ -z "$sp_id" ] && [ -z "$admin_user" ]; then
                report_warning "No authentication configured. Ensure one of:"
                echo "    - Service principal (service_principal_id + service_principal_password)"
                echo "    - Admin user (admin_username + admin_password)"
                echo "    - Azure CLI (az login)"
            else
                if [ -n "$sp_id" ]; then
                    validate_required "registry.azure_acr.service_principal_password" "Service principal password"
                fi
                if [ -n "$admin_user" ]; then
                    validate_required "registry.azure_acr.admin_password" "Admin password"
                fi
            fi

            validate_optional "registry.azure_acr.repository" "ACR repository" "\${product.name}"
            ;;

        *)
            report_error "Invalid registry.provider: ${provider}"
            echo ""
            echo "  Supported providers: docker_hub, aws_ecr, google_gcr, azure_acr"
            return 1
            ;;
    esac

    return 0
}

# Function to validate environment configuration
validate_environment() {
    local env=$1
    local product_type=${2:-$PRODUCT_TYPE}
    echo ""
    echo -e "${BLUE}Validating environment: ${env}${NC}"
    echo ""

    if [ "$product_type" = "docker" ]; then
        # Docker type - require env_path
        validate_required "environments.${env}.env_path" "Environment file path"

        # Optional fields
        validate_optional "environments.${env}.image_tag" "Image tag" "${env}"

        # Check if env_path looks reasonable
        local env_path=$(parse_yaml_key "environments.${env}.env_path" "" "$CONFIG_FILE")
        if [ -n "$env_path" ] && [ "$env_path" != "null" ]; then
            if [[ ! "$env_path" =~ ^/ ]]; then
                report_warning "env_path should be an absolute path: ${env_path}"
            fi

            if [[ ! "$env_path" =~ \.env ]]; then
                report_warning "env_path should point to a .env file: ${env_path}"
            fi
        fi
    else
        # Static type - require per-environment build and deployment settings
        validate_required "environments.${env}.build_command" "Build command"
        validate_required "environments.${env}.build_output_dir" "Build output directory"
        validate_required "environments.${env}.deploy_path" "Deployment path"
        validate_required "environments.${env}.domain" "Domain"

        # Check deploy_path is absolute
        local deploy_path=$(parse_yaml_key "environments.${env}.deploy_path" "" "$CONFIG_FILE")
        if [ -n "$deploy_path" ] && [ "$deploy_path" != "null" ]; then
            if [[ ! "$deploy_path" =~ ^/ ]]; then
                report_warning "deploy_path should be an absolute path: ${deploy_path}"
            fi
        fi

        # Check build_output_dir doesn't start with /
        local build_output_dir=$(parse_yaml_key "environments.${env}.build_output_dir" "" "$CONFIG_FILE")
        if [ -n "$build_output_dir" ] && [ "$build_output_dir" != "null" ]; then
            if [[ "$build_output_dir" =~ ^/ ]]; then
                report_warning "build_output_dir should be relative to project root: ${build_output_dir}"
            fi
        fi

        # Warn if Docker-specific fields are present
        local env_path=$(parse_yaml_key "environments.${env}.env_path" "" "$CONFIG_FILE")
        if [ -n "$env_path" ] && [ "$env_path" != "null" ]; then
            report_warning "env_path ignored for static sites (environment: ${env})"
        fi

        local image_tag=$(parse_yaml_key "environments.${env}.image_tag" "" "$CONFIG_FILE")
        if [ -n "$image_tag" ] && [ "$image_tag" != "null" ]; then
            report_warning "image_tag ignored for static sites (environment: ${env})"
        fi
    fi
}

echo -e "${BLUE}Product Configuration${NC}"
echo ""
validate_required "product.name" "Product name"

# Validate product type
PRODUCT_TYPE=$(get_product_type "$CONFIG_FILE")
if [ "$PRODUCT_TYPE" != "docker" ] && [ "$PRODUCT_TYPE" != "static" ]; then
    report_error "Invalid product.type: ${PRODUCT_TYPE} (must be 'docker' or 'static')"
    PRODUCT_TYPE="docker"  # Default for validation continuation
else
    report_success "Product type: ${PRODUCT_TYPE}"
fi

validate_optional "product.description" "Product description" "(none)"

# Validate static-specific or docker-specific configurations based on type
if [ "$PRODUCT_TYPE" = "static" ]; then
    # Static site global configuration validation
    echo ""
    echo -e "${BLUE}Static Site Global Configuration${NC}"
    echo ""
    echo -e "  ${BLUE}NOTE: Build and deployment settings are per-environment (validated below)${NC}"
    echo ""

    validate_optional "static.deploy_user" "Deploy user" "www-data"
    validate_optional "static.keep_releases" "Keep releases" "5"

    # Check for shared_dirs
    SHARED_DIRS=$(parse_yaml_array "static.shared_dirs" "$CONFIG_FILE")
    if [ -n "$SHARED_DIRS" ]; then
        dir_count=$(echo "$SHARED_DIRS" | wc -l | tr -d ' ')
        report_success "Shared directories: ${dir_count} configured"
    else
        echo -e "  ${BLUE}○ Shared directories: <not set>${NC}"
    fi

    # Check for required_files
    REQUIRED_FILES=$(parse_yaml_array "static.required_files" "$CONFIG_FILE")
    if [ -n "$REQUIRED_FILES" ]; then
        file_count=$(echo "$REQUIRED_FILES" | wc -l | tr -d ' ')
        report_success "Required files validation: ${file_count} file(s)"
    else
        echo -e "  ${BLUE}○ Required files: <not set> (defaults to index.html)${NC}"
    fi

    # Warn if deprecated global build/deploy fields are present
    OLD_BUILD_CMD=$(parse_yaml_key "static.build_command" "" "$CONFIG_FILE")
    if [ -n "$OLD_BUILD_CMD" ] && [ "$OLD_BUILD_CMD" != "null" ]; then
        report_error "static.build_command is deprecated - move to environments.{env}.build_command"
    fi

    OLD_BUILD_DIR=$(parse_yaml_key "static.build_output_dir" "" "$CONFIG_FILE")
    if [ -n "$OLD_BUILD_DIR" ] && [ "$OLD_BUILD_DIR" != "null" ]; then
        report_error "static.build_output_dir is deprecated - move to environments.{env}.build_output_dir"
    fi

    OLD_DEPLOY_PATH=$(parse_yaml_key "static.deploy_path" "" "$CONFIG_FILE")
    if [ -n "$OLD_DEPLOY_PATH" ] && [ "$OLD_DEPLOY_PATH" != "null" ]; then
        report_error "static.deploy_path is deprecated - move to environments.{env}.deploy_path"
    fi

    # Warn if docker/registry sections are present
    REGISTRY_CONFIG=$(parse_yaml_key "registry" "" "$CONFIG_FILE")
    if [ -n "$REGISTRY_CONFIG" ] && [ "$REGISTRY_CONFIG" != "null" ]; then
        report_warning "registry section ignored for static sites (type: static)"
    fi

    DOCKER_CONFIG=$(parse_yaml_key "docker" "" "$CONFIG_FILE")
    if [ -n "$DOCKER_CONFIG" ] && [ "$DOCKER_CONFIG" != "null" ]; then
        report_warning "docker section ignored for static sites (type: static)"
    fi

    HEALTH_CHECK_CONFIG=$(parse_yaml_key "health_check" "" "$CONFIG_FILE")
    if [ -n "$HEALTH_CHECK_CONFIG" ] && [ "$HEALTH_CHECK_CONFIG" != "null" ]; then
        report_warning "health_check section ignored for static sites (type: static)"
    fi
else
    # Docker configuration validation
    echo ""
    echo -e "${BLUE}Registry Configuration${NC}"
    echo ""
    validate_registry_config

    # Warn if static section is present
    STATIC_CONFIG=$(parse_yaml_key "static" "" "$CONFIG_FILE")
    if [ -n "$STATIC_CONFIG" ] && [ "$STATIC_CONFIG" != "null" ]; then
        report_warning "static section ignored for Docker sites (type: docker)"
    fi
fi

echo ""
echo -e "${BLUE}System Server Configuration${NC}"
echo ""
validate_required "servers.system.host" "System Server host"
validate_optional "servers.system.user" "System Server user" "ubuntu"
validate_file_path "servers.system.ssh_key" "System Server SSH key"

if [ "$PRODUCT_TYPE" = "docker" ]; then
    echo ""
    echo -e "${BLUE}Application Server Configuration${NC}"
    echo ""
    validate_required "servers.application.host" "Application Server host"
    validate_optional "servers.application.user" "Application Server user" "ubuntu"
    validate_file_path "servers.application.ssh_key" "Application Server SSH key"
    validate_optional "servers.application.private_ip" "Application Server private IP" "(uses public host)"
else
    # Static type - Application Server not used
    APP_SERVER_CONFIG=$(parse_yaml_key "servers.application" "" "$CONFIG_FILE")
    if [ -n "$APP_SERVER_CONFIG" ] && [ "$APP_SERVER_CONFIG" != "null" ]; then
        echo ""
        echo -e "${BLUE}Application Server Configuration${NC}"
        echo ""
        report_warning "Application Server not used for static sites (type: static)"
    fi
fi

echo ""
echo -e "${BLUE}Environment Configurations${NC}"

# Get list of environments
if [ -n "$ENVIRONMENT" ]; then
    # Validate specific environment
    validate_environment "$ENVIRONMENT"
else
    # Validate all environments
    ENVS=$(yq eval '.environments | keys | .[]' "$CONFIG_FILE" 2>/dev/null)

    if [ -z "$ENVS" ]; then
        report_error "No environments defined in config"
    else
        for env in $ENVS; do
            validate_environment "$env"
        done
    fi
fi

# Function to validate hostname or underscore
is_valid_hostname() {
    local value="$1"
    if [ "$value" = "_" ]; then
        return 0
    fi
    # Basic hostname validation: alphanumeric, hyphens, dots
    if echo "$value" | grep -qE '^[a-zA-Z0-9.-]+$'; then
        return 0
    fi
    return 1
}

# Function to validate proxy settings
validate_nginx_proxy_settings() {
    echo ""
    echo -e "${BLUE}Nginx Proxy Settings${NC}"
    echo ""

    local timeout=$(get_nginx_proxy_setting "timeout" "$CONFIG_FILE")
    local buffer_size=$(get_nginx_proxy_setting "buffer_size" "$CONFIG_FILE")
    local buffers=$(get_nginx_proxy_setting "buffers" "$CONFIG_FILE")
    local busy_buffers=$(get_nginx_proxy_setting "busy_buffers_size" "$CONFIG_FILE")

    # Validate timeout is a number
    if ! echo "$timeout" | grep -qE '^[0-9]+$'; then
        report_error "nginx.proxy.timeout must be a number: ${timeout}"
    else
        report_success "Proxy timeout: ${timeout}s"
    fi

    # Buffer sizes should have units (k, m, etc)
    if echo "$buffer_size" | grep -qE '^[0-9]+[kmgKMG]?$'; then
        report_success "Proxy buffer_size: ${buffer_size}"
    else
        report_error "nginx.proxy.buffer_size invalid format: ${buffer_size}"
    fi

    if echo "$buffers" | grep -qE '^[0-9]+ [0-9]+[kmgKMG]?$'; then
        report_success "Proxy buffers: ${buffers}"
    else
        report_error "nginx.proxy.buffers invalid format: ${buffers}"
    fi

    if echo "$busy_buffers" | grep -qE '^[0-9]+[kmgKMG]?$'; then
        report_success "Proxy busy_buffers_size: ${busy_buffers}"
    else
        report_error "nginx.proxy.busy_buffers_size invalid format: ${busy_buffers}"
    fi
}

# Function to check environment naming conflicts
check_environment_conflicts() {
    echo ""
    echo -e "${BLUE}Environment Conflict Detection${NC}"
    echo ""

    # Get product name
    local product=$(parse_yaml_key "product.name" "" "$CONFIG_FILE")
    if [ -z "$product" ]; then
        report_warning "Cannot check conflicts without product.name"
        return
    fi

    # Get all environments
    local envs=$(get_configured_environments "$CONFIG_FILE")
    if [ -z "$envs" ]; then
        report_warning "No environments found"
        return
    fi

    local env_count=$(echo "$envs" | wc -w | tr -d ' ')
    report_success "Found ${env_count} environment(s): ${envs}"

    # Check for duplicate names
    local duplicates=$(echo "$envs" | tr ' ' '\n' | sort | uniq -d)
    if [ -n "$duplicates" ]; then
        report_error "Duplicate environment names found: ${duplicates}"
    fi

    # Check each environment name is valid
    for env in $envs; do
        if ! echo "$env" | grep -qE '^[a-zA-Z0-9_-]+$'; then
            report_error "Invalid environment name '${env}' (use only alphanumeric, hyphens, underscores)"
        fi
    done

    # Check for filename conflicts
    # Generate all filenames and check for duplicates
    local filenames=""
    for env in $envs; do
        local filename=$(get_site_filename "$product" "$env")
        filenames="${filenames}${filename}"$'\n'
    done

    local duplicate_files=$(echo "$filenames" | sort | uniq -d)
    if [ -n "$duplicate_files" ]; then
        report_error "Filename conflict detected: Multiple environments generate same filename:"
        echo "$duplicate_files" | while read -r file; do
            if [ -n "$file" ]; then
                echo "    ${file}"
            fi
        done
    else
        report_success "No filename conflicts detected"
    fi
}

# Function to validate nginx configuration
validate_nginx_config() {
    echo ""
    echo -e "${BLUE}Nginx Configuration${NC}"
    echo ""

    # Check if nginx section exists
    local nginx_configured=$(parse_yaml_key "nginx" "" "$CONFIG_FILE")

    if [ -z "$nginx_configured" ] || [ "$nginx_configured" = "null" ]; then
        echo -e "  ${BLUE}○ Nginx configuration: <not set> (will use all defaults)${NC}"
        return
    fi

    report_success "Nginx configuration found"

    # Validate domains
    local envs=$(get_configured_environments "$CONFIG_FILE")
    for env in $envs; do
        local domain=$(get_nginx_domain "$env" "$CONFIG_FILE")
        if [ "$domain" = "_" ]; then
            echo -e "  ${BLUE}○ nginx.domain.${env}: <not set> (will use catch-all \"_\")${NC}"
        else
            if is_valid_hostname "$domain"; then
                report_success "nginx.domain.${env}: ${domain}"
            else
                report_error "nginx.domain.${env} invalid hostname: ${domain}"
            fi
        fi
    done

    # Validate SSL configuration
    for env in $envs; do
        local ssl_cert=$(get_ssl_certificate "$env" "$CONFIG_FILE")
        local ssl_key=$(get_ssl_certificate_key "$env" "$CONFIG_FILE")

        if [ -n "$ssl_cert" ] || [ -n "$ssl_key" ]; then
            if [ -n "$ssl_cert" ] && [ -n "$ssl_key" ]; then
                report_success "nginx.ssl.${env}: certificate and key configured"
            elif [ -n "$ssl_cert" ]; then
                report_error "nginx.ssl.${env}.certificate_key is required when certificate is set"
            else
                report_error "nginx.ssl.${env}.certificate is required when certificate_key is set"
            fi
        else
            echo -e "  ${BLUE}○ nginx.ssl.${env}: <not set> (HTTP only)${NC}"
        fi
    done

    # Validate proxy settings (only for Docker sites)
    if [ "$PRODUCT_TYPE" = "docker" ]; then
        validate_nginx_proxy_settings
    fi

    # Check custom properties
    local custom_props=$(get_nginx_custom_properties "$CONFIG_FILE")
    if [ -n "$custom_props" ]; then
        report_success "Custom nginx properties: configured"
        if ! command_exists yq; then
            report_warning "yq not installed - custom properties may not be parsed correctly"
        fi
    else
        echo -e "  ${BLUE}○ Custom nginx properties: <not set>${NC}"
    fi

    # Check environment conflicts
    check_environment_conflicts
}

# Function to validate remote nginx (optional)
validate_remote_nginx() {
    if [ "$CHECK_REMOTE" != "true" ]; then
        echo ""
        echo -e "  ${BLUE}○ Remote nginx check skipped (use --check-remote to enable)${NC}"
        return
    fi

    echo ""
    echo -e "${BLUE}Remote Nginx Validation${NC}"
    echo ""

    # Get System Server info
    local sys_host=$(parse_yaml_key "servers.system.host" "" "$CONFIG_FILE")
    local sys_user=$(parse_yaml_key "servers.system.user" "ubuntu" "$CONFIG_FILE")
    local sys_key=$(parse_yaml_key "servers.system.ssh_key" "" "$CONFIG_FILE")

    if [ -z "$sys_host" ]; then
        report_warning "Cannot check remote nginx: servers.system.host not configured"
        return
    fi

    # Expand tilde in SSH key path
    sys_key="${sys_key/#\~/$HOME}"

    if [ ! -f "$sys_key" ]; then
        report_warning "Cannot check remote nginx: SSH key not found: ${sys_key}"
        return
    fi

    # Get nginx paths
    local nginx_axon_dir=$(get_nginx_axon_dir "$CONFIG_FILE")
    local product=$(parse_yaml_key "product.name" "" "$CONFIG_FILE")

    echo -e "  Checking ${sys_user}@${sys_host}..."

    # Check SSH connection
    if ! ssh -i "$sys_key" -o ConnectTimeout=5 -o BatchMode=yes \
        "${sys_user}@${sys_host}" "echo 'OK'" > /dev/null 2>&1; then
        report_warning "Cannot connect to System Server via SSH"
        return
    fi

    # Check nginx installed
    local nginx_check=$(ssh -i "$sys_key" "${sys_user}@${sys_host}" \
        "nginx -v 2>&1 || echo 'NOT_INSTALLED'" 2>/dev/null)

    if echo "$nginx_check" | grep -q "NOT_INSTALLED"; then
        report_error "nginx not installed on System Server"
        return
    fi

    report_success "nginx is installed"

    # Check nginx config validity
    local nginx_test=$(ssh -i "$sys_key" "${sys_user}@${sys_host}" \
        "sudo nginx -t 2>&1" 2>/dev/null)

    if echo "$nginx_test" | grep -q "successful"; then
        report_success "nginx configuration is valid on System Server"
    else
        report_error "nginx configuration test failed on System Server"
        echo "$nginx_test"
    fi

    # Check if axon.d exists
    local axon_exists=$(ssh -i "$sys_key" "${sys_user}@${sys_host}" \
        "[ -d '$nginx_axon_dir' ] && echo 'YES' || echo 'NO'" 2>/dev/null)

    if [ "$axon_exists" = "YES" ]; then
        report_success "AXON directory exists: ${nginx_axon_dir}"

        # Check if includes are in nginx.conf
        local includes_check=$(ssh -i "$sys_key" "${sys_user}@${sys_host}" \
            "grep -c 'include ${nginx_axon_dir}' /etc/nginx/nginx.conf 2>/dev/null || echo '0'" 2>/dev/null)

        if [ "$includes_check" -gt "0" ]; then
            report_success "AXON includes found in nginx.conf"
        else
            report_warning "AXON includes not found in nginx.conf - run setup script"
        fi

        # Check for environment configs
        if [ -n "$product" ]; then
            local envs=$(get_configured_environments "$CONFIG_FILE")
            for env in $envs; do
                local site_file=$(get_site_filename "$product" "$env")
                local site_exists=$(ssh -i "$sys_key" "${sys_user}@${sys_host}" \
                    "[ -f '${nginx_axon_dir}/sites/${site_file}' ] && echo 'YES' || echo 'NO'" 2>/dev/null)

                if [ "$site_exists" = "YES" ]; then
                    report_success "Site config exists: ${env}"
                else
                    report_warning "Site config missing for ${env} - run setup script"
                fi
            done
        fi
    else
        report_warning "AXON directory not found: ${nginx_axon_dir} - run setup script"
    fi
}

# Conditional validation based on product type
if [ "$PRODUCT_TYPE" = "docker" ]; then
    echo ""
    echo -e "${BLUE}Health Check Configuration${NC}"
    echo ""
    validate_optional "health_check.endpoint" "Health check endpoint" "/api/health"
    validate_optional "health_check.interval" "Docker health check interval" "30s"
    validate_optional "health_check.timeout" "Docker health check timeout" "10s"
    validate_optional "health_check.retries" "Docker health check retries" "3"
    validate_optional "health_check.start_period" "Docker health check start period" "40s"
    validate_optional "health_check.max_retries" "Deployment max retries" "30"
    validate_optional "health_check.retry_interval" "Deployment retry interval" "2"

    echo ""
    echo -e "${BLUE}Deployment Configuration${NC}"
    echo ""
    validate_optional "deployment.graceful_shutdown_timeout" "Graceful shutdown timeout" "30"
    validate_optional "deployment.enable_auto_rollback" "Auto rollback" "true"

    echo ""
    echo -e "${BLUE}Docker Configuration${NC}"
    echo ""
    validate_optional "docker.container_port" "Container port" "3000"
    validate_optional "docker.dockerfile" "Dockerfile path" "Dockerfile"

    # Validate Dockerfile exists if specified
    DOCKERFILE_PATH=$(parse_yaml_key "docker.dockerfile" "Dockerfile" "$CONFIG_FILE")
    if [ -f "$PRODUCT_ROOT/$DOCKERFILE_PATH" ]; then
        report_success "Dockerfile exists: $DOCKERFILE_PATH ✓"
    else
        report_warning "Dockerfile not found: $PRODUCT_ROOT/$DOCKERFILE_PATH"
    fi

    validate_optional "docker.restart_policy" "Restart policy" "unless-stopped"
    validate_optional "docker.network_name" "Network name" "(auto)"
    validate_optional "docker.network_alias" "Network alias" "(none)"
    validate_optional "docker.logging.driver" "Logging driver" "json-file"
    validate_optional "docker.logging.max_size" "Log max size" "10m"
    validate_optional "docker.logging.max_file" "Log max files" "3"

    # Check for docker.env_vars
    ENV_VARS=$(parse_yaml_key "docker.env_vars" "" "$CONFIG_FILE")
    if [ -n "$ENV_VARS" ] && [ "$ENV_VARS" != "null" ]; then
        report_success "Docker environment variables: configured"
    else
        echo -e "  ${BLUE}○ Docker environment variables: <not set>${NC}"
    fi

    # Check for docker.extra_hosts
    EXTRA_HOSTS=$(parse_yaml_key "docker.extra_hosts" "" "$CONFIG_FILE")
    if [ -n "$EXTRA_HOSTS" ] && [ "$EXTRA_HOSTS" != "null" ]; then
        report_success "Docker extra hosts: configured"
    else
        echo -e "  ${BLUE}○ Docker extra hosts: <not set>${NC}"
    fi

    # Check for docker.compose_override
    COMPOSE_OVERRIDE=$(parse_yaml_key "docker.compose_override" "" "$CONFIG_FILE")
    if [ -n "$COMPOSE_OVERRIDE" ] && [ "$COMPOSE_OVERRIDE" != "null" ]; then
        report_success "Docker compose override: configured"
    else
        echo -e "  ${BLUE}○ Docker compose override: <not set>${NC}"
    fi
fi

# Validate nginx configuration
validate_nginx_config

# Validate remote nginx (optional)
validate_remote_nginx

# Summary
echo ""
echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Validation Summary${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✓ Configuration is valid!${NC}"
    echo -e "${GREEN}  0 errors, 0 warnings${NC}"
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}⚠ Configuration has warnings${NC}"
    echo -e "${YELLOW}  0 errors, ${WARNINGS} warning(s)${NC}"

    if [ "$STRICT_MODE" = true ]; then
        echo ""
        echo -e "${RED}Strict mode enabled - treating warnings as errors${NC}"
        exit 1
    else
        exit 0
    fi
else
    echo -e "${RED}✗ Configuration validation failed${NC}"
    echo -e "${RED}  ${ERRORS} error(s), ${WARNINGS} warning(s)${NC}"
    echo ""
    echo "Please fix the errors above and run validation again."
    exit 1
fi
