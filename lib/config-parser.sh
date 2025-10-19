#!/bin/bash
# Configuration Parser Library
# Provides functions to parse deploy.config.yml
# Requires: yq (YAML processor) - Install with: brew install yq

# Check if yq is installed
check_yq() {
    if ! command -v yq &> /dev/null; then
        echo -e "${RED}Error: yq is not installed${NC}" >&2
        echo "" >&2
        echo "yq is required for parsing YAML configuration files." >&2
        echo "" >&2
        echo "Install it with:" >&2
        echo "  macOS:   brew install yq" >&2
        echo "  Linux:   https://github.com/mikefarah/yq#install" >&2
        echo "" >&2
        return 1
    fi
    return 0
}

# Function to parse YAML config
parse_yaml_key() {
    local key=$1
    local default=$2
    local config_file=${3:-$CONFIG_FILE}

    # Ensure yq is available
    if ! check_yq; then
        exit 1
    fi

    # Parse using yq (yq v4 requires leading dot in path expressions)
    # Ensure key has leading dot
    local yq_key="$key"
    if [[ "$yq_key" != .* ]]; then
        yq_key=".$yq_key"
    fi

    value=$(yq eval "$yq_key" "$config_file" 2>/dev/null || echo "")

    # Return value or default
    if [ "$value" != "null" ] && [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Load complete configuration for an environment
load_config() {
    local env=$1

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Error: Configuration file not found: $CONFIG_FILE${NC}"
        exit 1
    fi

    # Product config
    export PRODUCT_NAME=$(parse_yaml_key "product.name" "my-product")

    # AWS config
    export AWS_PROFILE=$(parse_yaml_key "aws.profile" "default")
    export AWS_REGION=$(parse_yaml_key "aws.region" "ap-northeast-1")
    export AWS_ACCOUNT_ID=$(parse_yaml_key "aws.account_id" "")
    export ECR_REPOSITORY=$(parse_yaml_key "aws.ecr_repository" "$PRODUCT_NAME")

    # Server config
    export SYSTEM_SERVER_HOST=$(parse_yaml_key "servers.system.host" "")
    export SYSTEM_SERVER_USER=$(parse_yaml_key "servers.system.user" "deploy")
    export SSH_KEY=$(parse_yaml_key "servers.system.ssh_key" "~/.ssh/deployment_key")
    export SSH_KEY="${SSH_KEY/#\~/$HOME}"
    export APPLICATION_SERVER_IP=$(parse_yaml_key "servers.application.host" "localhost")

    # Environment-specific config
    export BLUE_PORT=$(parse_yaml_key "environments.${env}.blue_port" "5100")
    export GREEN_PORT=$(parse_yaml_key "environments.${env}.green_port" "5102")
    export DOMAIN=$(parse_yaml_key "environments.${env}.domain" "")
    export NGINX_UPSTREAM_FILE=$(parse_yaml_key "environments.${env}.nginx_upstream_file" "/etc/nginx/upstreams/${PRODUCT_NAME}-${env}.conf")
    export NGINX_UPSTREAM_NAME=$(parse_yaml_key "environments.${env}.nginx_upstream_name" "${PRODUCT_NAME}_${env}_backend")
    export ENV_FILE_PATH=$(parse_yaml_key "environments.${env}.env_path" "/home/ubuntu/app/.env.${env}")
    export IMAGE_TAG=$(parse_yaml_key "environments.${env}.image_tag" "$env")
    export DOCKER_COMPOSE_FILE=$(parse_yaml_key "environments.${env}.docker_compose_file" "docker-compose.${env}.yml")

    # Health check config
    export HEALTH_ENDPOINT=$(parse_yaml_key "health_check.endpoint" "/api/health")
    export MAX_RETRIES=$(parse_yaml_key "health_check.max_retries" "30")
    export RETRY_INTERVAL=$(parse_yaml_key "health_check.retry_interval" "2")

    # Deployment config
    export DRAIN_TIME=$(parse_yaml_key "deployment.connection_drain_time" "5")
    export AUTO_ROLLBACK=$(parse_yaml_key "deployment.enable_auto_rollback" "true")
}
