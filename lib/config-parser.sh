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

    # Debug output if verbose mode
    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] Parsing config key: $key" >&2
    fi

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

    # Run yq with timeout to prevent hanging (10 seconds should be plenty)
    # Use timeout command if available, otherwise run directly
    local value
    local exit_code
    if command -v timeout >/dev/null 2>&1; then
        value=$(timeout 10 yq eval "$yq_key" "$config_file" 2>/dev/null || echo "")
        exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "Error: yq command timed out while parsing key: $key" >&2
            echo "Config file: $config_file" >&2
            exit 1
        fi
    else
        value=$(yq eval "$yq_key" "$config_file" 2>/dev/null || echo "")
        exit_code=$?
    fi

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

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] load_config: Starting configuration load for environment: $env" >&2
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Error: Configuration file not found: $CONFIG_FILE${NC}"
        exit 1
    fi

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] load_config: Parsing product.name..." >&2
    fi
    # Product config
    export PRODUCT_NAME=$(parse_yaml_key "product.name" "")

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] load_config: Parsing registry provider..." >&2
    fi
    # Registry config (generic exports for all providers)
    export REGISTRY_PROVIDER=$(get_registry_provider)

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] load_config: Parsing repository name..." >&2
    fi
    export REPOSITORY_NAME=$(get_repository_name)

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] load_config: Repository name parsed successfully: $REPOSITORY_NAME" >&2
        echo "[VERBOSE] load_config: Parsing server configuration..." >&2
    fi

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

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] load_config: Configuration load completed successfully" >&2
    fi
}

# ==============================================================================
# Registry Configuration Functions
# ==============================================================================

# Get active registry provider
get_registry_provider() {
    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] get_registry_provider: Fetching registry provider..." >&2
    fi
    local provider=$(parse_yaml_key "registry.provider" "")
    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] get_registry_provider: Provider is '$provider'" >&2
    fi
    echo "$provider"
}

# Get registry-specific config value
get_registry_config() {
    local provider=$(get_registry_provider)
    local key=$1
    parse_yaml_key "registry.${provider}.${key}" ""
}

# Get repository name (respects provider-specific setting or defaults to product name)
get_repository_name() {
    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] get_repository_name: Starting..." >&2
    fi

    local provider=$(get_registry_provider)

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] get_repository_name: Provider is '$provider', checking for repository override..." >&2
    fi

    local repo=$(parse_yaml_key "registry.${provider}.repository" "")

    if [ -z "$repo" ]; then
        if [ "${VERBOSE:-false}" = "true" ]; then
            echo "[VERBOSE] get_repository_name: No override, using product.name..." >&2
        fi
        repo=$(parse_yaml_key "product.name" "")
    fi

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] get_repository_name: Repository name is '$repo'" >&2
    fi

    echo "$repo"
}

# Build full registry URL
build_registry_url() {
    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] build_registry_url: Starting..." >&2
    fi

    local provider=$(get_registry_provider)

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] build_registry_url: Provider is '$provider'" >&2
    fi

    case $provider in
        docker_hub)
            if [ "${VERBOSE:-false}" = "true" ]; then
                echo "[VERBOSE] build_registry_url: Using Docker Hub registry" >&2
            fi
            echo "docker.io"
            ;;
        aws_ecr)
            if [ "${VERBOSE:-false}" = "true" ]; then
                echo "[VERBOSE] build_registry_url: Using AWS ECR registry, fetching account_id and region..." >&2
            fi

            local account_id=$(get_registry_config "account_id")
            local region=$(get_registry_config "region")

            if [ "${VERBOSE:-false}" = "true" ]; then
                echo "[VERBOSE] build_registry_url: account_id='$account_id', region='$region'" >&2
            fi

            if [ -z "$account_id" ] || [ -z "$region" ]; then
                echo "" >&2
                return 1
            fi

            local url="${account_id}.dkr.ecr.${region}.amazonaws.com"
            if [ "${VERBOSE:-false}" = "true" ]; then
                echo "[VERBOSE] build_registry_url: AWS ECR URL is '$url'" >&2
            fi
            echo "$url"
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

    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] build_image_uri: Starting with tag='$tag'..." >&2
    fi

    local provider=$(get_registry_provider)
    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] build_image_uri: Provider is '$provider'" >&2
    fi

    local registry_url=$(build_registry_url)
    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] build_image_uri: Registry URL is '$registry_url'" >&2
    fi

    local repository=$(get_repository_name)
    if [ "${VERBOSE:-false}" = "true" ]; then
        echo "[VERBOSE] build_image_uri: Repository is '$repository'" >&2
    fi

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
# Requires: envsubst command (from gettext package)
expand_env_vars() {
    local value=$1

    # Check if envsubst is available
    if ! command -v envsubst >/dev/null 2>&1; then
        echo "Error: envsubst is not installed (required for environment variable expansion)" >&2
        echo "" >&2
        echo "Install envsubst:" >&2
        echo "  macOS:   brew install gettext && brew link --force gettext" >&2
        echo "  Ubuntu:  sudo apt-get install gettext-base" >&2
        echo "  CentOS:  sudo yum install gettext" >&2
        echo "" >&2
        return 1
    fi

    echo "$value" | envsubst
}

# ==============================================================================
# Product Type Detection Functions
# ==============================================================================

# Get product deployment type (docker or static)
get_product_type() {
    local config_file=${1:-$CONFIG_FILE}
    local type=$(parse_yaml_key "product.type" "docker" "$config_file")

    # Normalize to lowercase
    type=$(echo "$type" | tr '[:upper:]' '[:lower:]')

    # Validate type
    if [ "$type" != "docker" ] && [ "$type" != "static" ]; then
        echo "docker"  # Default to docker for backward compatibility
    else
        echo "$type"
    fi
}

# Check if product is a static site
is_static_site() {
    local config_file=${1:-$CONFIG_FILE}
    [ "$(get_product_type "$config_file")" = "static" ]
}

# Check if product is a Docker deployment
is_docker_site() {
    local config_file=${1:-$CONFIG_FILE}
    [ "$(get_product_type "$config_file")" = "docker" ]
}

# Require System Server configuration (for static sites)
require_system_server() {
    local config_file=${1:-$CONFIG_FILE}

    local host=$(parse_yaml_key "servers.system.host" "" "$config_file")
    local user=$(parse_yaml_key "servers.system.user" "" "$config_file")
    local ssh_key=$(parse_yaml_key "servers.system.ssh_key" "" "$config_file")

    if [ -z "$host" ] || [ -z "$user" ] || [ -z "$ssh_key" ]; then
        echo -e "${RED}Error: System Server configuration required for static sites${NC}" >&2
        echo "" >&2
        echo "Required fields in $config_file:" >&2
        echo "  servers.system.host" >&2
        echo "  servers.system.user" >&2
        echo "  servers.system.ssh_key" >&2
        echo "" >&2
        return 1
    fi

    # Expand tilde in SSH key path
    ssh_key="${ssh_key/#\~/$HOME}"

    # Check if SSH key exists
    if [ ! -f "$ssh_key" ]; then
        echo -e "${RED}Error: System Server SSH key not found: $ssh_key${NC}" >&2
        return 1
    fi

    return 0
}

# Require Application Server configuration (for Docker sites)
require_application_server() {
    local config_file=${1:-$CONFIG_FILE}

    local host=$(parse_yaml_key "servers.application.host" "" "$config_file")
    local user=$(parse_yaml_key "servers.application.user" "" "$config_file")
    local ssh_key=$(parse_yaml_key "servers.application.ssh_key" "" "$config_file")
    local private_ip=$(parse_yaml_key "servers.application.private_ip" "" "$config_file")

    if [ -z "$host" ] || [ -z "$user" ] || [ -z "$ssh_key" ] || [ -z "$private_ip" ]; then
        echo -e "${RED}Error: Application Server configuration required for Docker deployments${NC}" >&2
        echo "" >&2
        echo "Required fields in $config_file:" >&2
        echo "  servers.application.host" >&2
        echo "  servers.application.user" >&2
        echo "  servers.application.ssh_key" >&2
        echo "  servers.application.private_ip" >&2
        echo "" >&2
        return 1
    fi

    # Expand tilde in SSH key path
    ssh_key="${ssh_key/#\~/$HOME}"

    # Check if SSH key exists
    if [ ! -f "$ssh_key" ]; then
        echo -e "${RED}Error: Application Server SSH key not found: $ssh_key${NC}" >&2
        return 1
    fi

    return 0
}

# Alias for consistency with other scripts (get_configured_environments is used in some tools)
get_configured_environments() {
    get_available_environments "$@"
}
