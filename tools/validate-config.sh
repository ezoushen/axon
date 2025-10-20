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
PRODUCT_ROOT="$PWD"

# Default configuration file
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
ENVIRONMENT=""
STRICT_MODE=false
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
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Validates axon.config.yml for required fields and proper formatting"
            echo ""
            echo "Options:"
            echo "  -c, --config FILE       Specify config file (default: axon.config.yml)"
            echo "  -e, --environment ENV   Validate specific environment only"
            echo "  --strict                Treat warnings as errors"
            echo "  -h, --help              Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Validate default config"
            echo "  $0 --config custom.yml                # Validate custom config"
            echo "  $0 --environment production           # Validate production env only"
            echo "  $0 --strict                           # Fail on warnings"
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

# Source config parser
source "$MODULE_DIR/lib/config-parser.sh"

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

# Function to validate AWS account ID format
validate_aws_account_id() {
    local value=$(parse_yaml_key "aws.account_id" "" "$CONFIG_FILE")

    if [ -z "$value" ] || [ "$value" = "null" ]; then
        report_error "Required field missing: aws.account_id"
        return 1
    fi

    # AWS account IDs are 12 digits
    if ! [[ "$value" =~ ^[0-9]{12}$ ]]; then
        report_error "Invalid AWS account ID format: ${value} (must be 12 digits)"
        return 1
    else
        report_success "AWS Account ID: ${value}"
        return 0
    fi
}

# Function to validate environment configuration
validate_environment() {
    local env=$1
    echo ""
    echo -e "${BLUE}Validating environment: ${env}${NC}"
    echo ""

    # Required fields
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
}

echo -e "${BLUE}Product Configuration${NC}"
echo ""
validate_required "product.name" "Product name"
validate_optional "product.description" "Product description" "(none)"

echo ""
echo -e "${BLUE}AWS Configuration${NC}"
echo ""
validate_required "aws.profile" "AWS profile"
validate_required "aws.region" "AWS region"
validate_aws_account_id
validate_optional "aws.ecr_repository" "ECR repository" "\${PRODUCT_NAME}"

echo ""
echo -e "${BLUE}System Server Configuration${NC}"
echo ""
validate_required "servers.system.host" "System Server host"
validate_optional "servers.system.user" "System Server user" "ubuntu"
validate_file_path "servers.system.ssh_key" "System Server SSH key"

echo ""
echo -e "${BLUE}Application Server Configuration${NC}"
echo ""
validate_required "servers.application.host" "Application Server host"
validate_optional "servers.application.user" "Application Server user" "ubuntu"
validate_file_path "servers.application.ssh_key" "Application Server SSH key"
validate_optional "servers.application.private_ip" "Application Server private IP" "(uses public host)"

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
