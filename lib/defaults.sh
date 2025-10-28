#!/bin/bash
# AXON - Default Values and Config Parsing Library
# Centralized configuration reading with fallback defaults
# Bash 3.2 compatible

# Nginx default values
readonly NGINX_DEFAULT_TIMEOUT="60"
readonly NGINX_DEFAULT_BUFFER_SIZE="128k"
readonly NGINX_DEFAULT_BUFFERS="4 256k"
readonly NGINX_DEFAULT_BUSY_BUFFERS_SIZE="256k"
readonly NGINX_DEFAULT_DOMAIN="_"
readonly NGINX_DEFAULT_CONFIG_PATH="/etc/nginx/nginx.conf"
readonly NGINX_DEFAULT_AXON_DIR="/etc/nginx/axon.d"

# Function to check if command exists
command_exists() {
    command -v "$1" > /dev/null 2>&1
}

# Function to get config value with default fallback
# Usage: get_config_with_default <yaml_path> <default_value> [config_file]
# Example: get_config_with_default ".nginx.proxy.timeout" "60" "/path/to/config.yml"
get_config_with_default() {
    local yaml_path="$1"
    local default_value="$2"
    local config_file="${3:-$CONFIG_FILE}"

    if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
        echo "$default_value"
        return
    fi

    local value=""

    # Try yq first (preferred method)
    if command_exists yq; then
        value=$(yq eval "$yaml_path" "$config_file" 2>/dev/null || echo "")
        if [ "$value" != "null" ] && [ -n "$value" ]; then
            echo "$value"
            return
        fi
    fi

    # Fallback: grep/awk parser for simple values
    # Extract the last component of the path (e.g., .nginx.proxy.timeout -> timeout)
    local search_key=$(echo "$yaml_path" | awk -F'.' '{print $NF}')

    # Try to find the key in the config file
    value=$(grep -E "^[[:space:]]*${search_key}:" "$config_file" | head -1 | \
            awk -F': ' '{print $2}' | sed 's/[\"'\''"]//g' | sed 's/#.*//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || echo "")

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default_value"
    fi
}

# Function to get list of configured environments
# Returns space-separated list of environment names
# Example output: "production staging development"
get_configured_environments() {
    local config_file="${1:-$CONFIG_FILE}"

    if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
        echo ""
        return
    fi

    local envs=""

    # Try yq first
    if command_exists yq; then
        envs=$(yq eval '.environments | keys | .[]' "$config_file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        if [ -n "$envs" ]; then
            echo "$envs"
            return
        fi
    fi

    # Fallback: grep for environment entries
    # Look for patterns like "production:" or "staging:" under environments section
    # This is a simple heuristic - may need adjustment for complex configs
    envs=$(grep -A 100 '^environments:' "$config_file" | \
           grep -E '^[[:space:]]{2}[a-zA-Z0-9_-]+:' | \
           sed 's/^[[:space:]]*//' | sed 's/:.*//' | \
           tr '\n' ' ' | sed 's/[[:space:]]*$//')

    echo "$envs"
}

# Function to get nginx domain for specific environment
# Returns domain or "_" (catch-all) if not configured
get_nginx_domain() {
    local env="$1"
    local config_file="${2:-$CONFIG_FILE}"

    if [ -z "$env" ]; then
        echo "$NGINX_DEFAULT_DOMAIN"
        return
    fi

    # Try new location first: environments.{env}.domain (for both docker and static)
    local domain=$(get_config_with_default ".environments.${env}.domain" "" "$config_file")

    # Fall back to old location: nginx.domain.{env} (for backward compatibility)
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        domain=$(get_config_with_default ".nginx.domain.${env}" "" "$config_file")
    fi

    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        echo "$NGINX_DEFAULT_DOMAIN"
    else
        echo "$domain"
    fi
}

# Function to get nginx proxy setting
# Usage: get_nginx_proxy_setting <setting_name> [config_file]
# Example: get_nginx_proxy_setting "timeout"
get_nginx_proxy_setting() {
    local setting="$1"
    local config_file="${2:-$CONFIG_FILE}"

    case "$setting" in
        timeout)
            get_config_with_default ".nginx.proxy.timeout" "$NGINX_DEFAULT_TIMEOUT" "$config_file"
            ;;
        buffer_size)
            get_config_with_default ".nginx.proxy.buffer_size" "$NGINX_DEFAULT_BUFFER_SIZE" "$config_file"
            ;;
        buffers)
            get_config_with_default ".nginx.proxy.buffers" "$NGINX_DEFAULT_BUFFERS" "$config_file"
            ;;
        busy_buffers_size)
            get_config_with_default ".nginx.proxy.busy_buffers_size" "$NGINX_DEFAULT_BUSY_BUFFERS_SIZE" "$config_file"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Function to get nginx custom properties
# Returns custom nginx directives or empty string
get_nginx_custom_properties() {
    local config_file="${1:-$CONFIG_FILE}"

    if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
        echo ""
        return
    fi

    local custom_props=""

    # Try yq first (handles multi-line YAML correctly)
    if command_exists yq; then
        custom_props=$(yq eval '.nginx.custom_properties' "$config_file" 2>/dev/null || echo "")
        if [ "$custom_props" != "null" ] && [ -n "$custom_props" ]; then
            echo "$custom_props"
            return
        fi
    fi

    # Fallback: Try to extract custom_properties block
    # This is complex for multi-line, so we just return empty if yq not available
    # Users should install yq for custom_properties support
    echo ""
}

# Function to get nginx config path
get_nginx_config_path() {
    local config_file="${1:-$CONFIG_FILE}"
    get_config_with_default ".nginx.paths.config" "$NGINX_DEFAULT_CONFIG_PATH" "$config_file"
}

# Function to get nginx axon directory path
get_nginx_axon_dir() {
    local config_file="${1:-$CONFIG_FILE}"
    get_config_with_default ".nginx.paths.axon_dir" "$NGINX_DEFAULT_AXON_DIR" "$config_file"
}

# Function to normalize environment name for filename
# Converts name to lowercase and ensures it's filesystem-safe
normalize_env_name() {
    local env="$1"
    # Convert to lowercase and replace spaces with hyphens
    echo "$env" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'
}

# Function to generate upstream filename for environment
# Returns: {product}-{env}.conf
get_upstream_filename() {
    local product="$1"
    local env="$2"
    local normalized_env=$(normalize_env_name "$env")
    echo "${product}-${normalized_env}.conf"
}

# Function to generate site config filename for environment
# Returns: {product}-{env}.conf
get_site_filename() {
    local product="$1"
    local env="$2"
    local normalized_env=$(normalize_env_name "$env")
    echo "${product}-${normalized_env}.conf"
}

# Function to generate upstream name (for use in nginx configs)
# Converts hyphens to underscores
# Returns: {product}_{env}_backend
get_upstream_name() {
    local product="$1"
    local env="$2"
    local normalized_env=$(normalize_env_name "$env")
    local upstream_name="${product}-${normalized_env}"
    # Convert hyphens to underscores for nginx upstream name
    upstream_name="${upstream_name//-/_}"
    echo "${upstream_name}_backend"
}

# Function to get SSL certificate path for environment
# Returns empty string if not configured
get_ssl_certificate() {
    local env="$1"
    local config_file="${2:-$CONFIG_FILE}"
    get_config_with_default ".nginx.ssl.${env}.certificate" "" "$config_file"
}

# Function to get SSL certificate key path for environment
# Returns empty string if not configured
get_ssl_certificate_key() {
    local env="$1"
    local config_file="${2:-$CONFIG_FILE}"
    get_config_with_default ".nginx.ssl.${env}.certificate_key" "" "$config_file"
}

# Function to check if SSL is configured for environment
# Returns "true" if both certificate and key are configured
has_ssl_config() {
    local env="$1"
    local config_file="${2:-$CONFIG_FILE}"

    local cert=$(get_ssl_certificate "$env" "$config_file")
    local key=$(get_ssl_certificate_key "$env" "$config_file")

    if [ -n "$cert" ] && [ -n "$key" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# ==============================================================================
# Static Site Defaults and Helpers
# ==============================================================================

# Static site default values
readonly STATIC_DEFAULT_KEEP_RELEASES="5"
readonly STATIC_DEFAULT_DEPLOY_USER="www-data"
readonly STATIC_DEFAULT_BUILD_DIR="dist"

# Generate timestamp-based release name
# Returns: YYYYMMDDHHMMSS format (e.g., 20250127153045)
generate_release_name() {
    date +"%Y%m%d%H%M%S"
}

# NOTE: Static site configuration getters have been moved to lib/config-parser.sh
# - get_static_deploy_user() -> now in config-parser.sh
# - get_static_keep_releases() -> now in config-parser.sh
# - get_static_shared_dirs() -> now in config-parser.sh
# - get_static_required_files() -> now in config-parser.sh
# - get_build_command(environment) -> now in config-parser.sh (per-environment)
# - get_build_output_dir(environment) -> now in config-parser.sh (per-environment)
# - get_deploy_path(environment) -> now in config-parser.sh (per-environment)
# - get_domain(environment) -> now in config-parser.sh (per-environment)

# ==============================================================================
# Static Site Helper Functions (path construction, not config parsing)
# ==============================================================================

# Get full release directory path
# Returns: {deploy_path}/{environment}/releases/{release_name}
get_release_path() {
    local deploy_path="$1"
    local environment="$2"
    local release_name="$3"
    echo "${deploy_path}/${environment}/releases/${release_name}"
}

# Get full shared directory path
# Returns: {deploy_path}/{environment}/shared
get_shared_path() {
    local deploy_path="$1"
    local environment="$2"
    echo "${deploy_path}/${environment}/shared"
}

# Get current release symlink path
# Returns: {deploy_path}/{environment}/current
get_current_symlink_path() {
    local deploy_path="$1"
    local environment="$2"
    echo "${deploy_path}/${environment}/current"
}

# Get build archive filename
# Returns: static-build-{release_name}.tar.gz
get_build_archive_name() {
    local release_name="$1"
    echo "static-build-${release_name}.tar.gz"
}

# Get temporary build archive path (on local machine)
# Returns: /tmp/static-build-{release_name}.tar.gz
get_build_archive_path() {
    local release_name="$1"
    echo "/tmp/$(get_build_archive_name "$release_name")"
}
