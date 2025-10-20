#!/bin/bash
# Configuration Parser Library
# Provides functions to parse axon.config.yml
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

# Get list of all environments defined in config
get_available_environments() {
    local config_file=${1:-$CONFIG_FILE}

    # Ensure yq is available
    if ! check_yq; then
        exit 1
    fi

    # Get all environment keys
    yq eval '.environments | keys | .[]' "$config_file" 2>/dev/null
}

# Validate that an environment exists in config
validate_environment() {
    local env=$1
    local config_file=${2:-$CONFIG_FILE}

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}Error: Configuration file not found: $config_file${NC}" >&2
        return 1
    fi

    # Ensure yq is available
    if ! check_yq; then
        exit 1
    fi

    # Check if environment exists in config
    local env_path=$(yq eval ".environments.$env" "$config_file" 2>/dev/null)

    if [ "$env_path" = "null" ] || [ -z "$env_path" ]; then
        echo -e "${RED}Error: Environment '$env' not found in $config_file${NC}" >&2
        echo "" >&2
        echo -e "${YELLOW}Available environments:${NC}" >&2
        local available_envs=$(get_available_environments "$config_file")
        if [ -n "$available_envs" ]; then
            echo "$available_envs" | while read -r e; do
                echo "  - $e" >&2
            done
        else
            echo "  (none defined)" >&2
        fi
        echo "" >&2
        return 1
    fi

    return 0
}

# Load complete configuration for an environment
load_config() {
    local env=$1

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Error: Configuration file not found: $CONFIG_FILE${NC}"
        exit 1
    fi

    # Product config
    export PRODUCT_NAME=$(parse_yaml_key "product.name" "")

    # Registry config (generic exports for all providers)
    export REGISTRY_PROVIDER=$(get_registry_provider)
    export REPOSITORY_NAME=$(get_repository_name)

    # System Server config
    export SYSTEM_SERVER_HOST=$(parse_yaml_key "servers.system.host" "")
    export SYSTEM_SERVER_USER=$(parse_yaml_key "servers.system.user" "")
    export SSH_KEY=$(parse_yaml_key "servers.system.ssh_key" "")
    export SSH_KEY="${SSH_KEY/#\~/$HOME}"

    # Application Server config
    export APPLICATION_SERVER_HOST=$(parse_yaml_key "servers.application.host" "")
    export APPLICATION_SERVER_USER=$(parse_yaml_key "servers.application.user" "")
    export APPLICATION_SERVER_SSH_KEY=$(parse_yaml_key "servers.application.ssh_key" "")
    export APPLICATION_SERVER_SSH_KEY="${APPLICATION_SERVER_SSH_KEY/#\~/$HOME}"
    export APPLICATION_SERVER_PRIVATE_IP=$(parse_yaml_key "servers.application.private_ip" "")

    # Environment-specific config
    export ENV_FILE_PATH=$(parse_yaml_key "environments.${env}.env_path" "")
    export IMAGE_TAG=$(parse_yaml_key "environments.${env}.image_tag" "$env")

    # Health check config
    export HEALTH_ENDPOINT=$(parse_yaml_key "health_check.endpoint" "/api/health")
    export MAX_RETRIES=$(parse_yaml_key "health_check.max_retries" "30")
    export RETRY_INTERVAL=$(parse_yaml_key "health_check.retry_interval" "2")

    # Deployment config
    export GRACEFUL_SHUTDOWN_TIMEOUT=$(parse_yaml_key "deployment.graceful_shutdown_timeout" "30")
    export AUTO_ROLLBACK=$(parse_yaml_key "deployment.enable_auto_rollback" "true")

    # Docker config
    export CONTAINER_PORT=$(parse_yaml_key "docker.container_port" "3000")
    export DOCKERFILE_PATH=$(parse_yaml_key "docker.dockerfile" "Dockerfile")
}

# ==============================================================================
# Registry Configuration Functions
# ==============================================================================

# Get active registry provider
get_registry_provider() {
    parse_yaml_key "registry.provider" ""
}

# Get registry-specific config value
get_registry_config() {
    local provider=$(get_registry_provider)
    local key=$1
    parse_yaml_key "registry.${provider}.${key}" ""
}

# Get repository name (respects provider-specific setting or defaults to product name)
get_repository_name() {
    local provider=$(get_registry_provider)
    local repo=$(parse_yaml_key "registry.${provider}.repository" "")
    if [ -z "$repo" ]; then
        repo=$(parse_yaml_key "product.name" "")
    fi
    echo "$repo"
}

# Build full registry URL
build_registry_url() {
    local provider=$(get_registry_provider)

    case $provider in
        docker_hub)
            echo "docker.io"
            ;;
        aws_ecr)
            local account_id=$(get_registry_config "account_id")
            local region=$(get_registry_config "region")

            if [ -z "$account_id" ] || [ -z "$region" ]; then
                echo "" >&2
                return 1
            fi

            echo "${account_id}.dkr.ecr.${region}.amazonaws.com"
            ;;
        google_gcr)
            local project_id=$(get_registry_config "project_id")
            local use_artifact=$(get_registry_config "use_artifact_registry")
            local location=$(get_registry_config "location")
            location="${location:-us}"

            if [ -z "$project_id" ]; then
                echo "" >&2
                return 1
            fi

            if [ "$use_artifact" = "true" ]; then
                # Artifact Registry format
                echo "${location}-docker.pkg.dev/${project_id}"
            else
                # GCR format
                echo "${location}.gcr.io/${project_id}"
            fi
            ;;
        azure_acr)
            local registry_name=$(get_registry_config "registry_name")

            if [ -z "$registry_name" ]; then
                echo "" >&2
                return 1
            fi

            echo "${registry_name}.azurecr.io"
            ;;
        *)
            echo "" >&2
            return 1
            ;;
    esac
}

# Build full image URI (registry URL + repository + tag)
build_image_uri() {
    local tag=$1
    local provider=$(get_registry_provider)
    local registry_url=$(build_registry_url)
    local repository=$(get_repository_name)

    if [ -z "$registry_url" ] || [ -z "$repository" ]; then
        echo "" >&2
        return 1
    fi

    case $provider in
        docker_hub)
            local namespace=$(get_registry_config "namespace")
            if [ -z "$namespace" ]; then
                namespace=$(get_registry_config "username")
            fi

            if [ -z "$namespace" ]; then
                echo "" >&2
                return 1
            fi

            echo "${namespace}/${repository}:${tag}"
            ;;
        *)
            echo "${registry_url}/${repository}:${tag}"
            ;;
    esac
}

# Expand environment variables in config values
# Usage: expand_env_vars "$value"
# Supports ${VAR_NAME} syntax
expand_env_vars() {
    local value=$1

    # Use envsubst if available (preferred)
    if command -v envsubst >/dev/null 2>&1; then
        echo "$value" | envsubst
        return
    fi

    # Fallback: Simple bash-based expansion
    # This handles ${VAR} syntax only
    local result="$value"

    # Find all ${VAR} patterns and replace them
    while [[ "$result" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        local var_name="${BASH_REMATCH[1]}"
        local var_value="${!var_name}"
        result="${result//\$\{${var_name}\}/${var_value}}"
    done

    echo "$result"
}
