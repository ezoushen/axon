#!/bin/bash
# AXON - Docker Runtime Library
# Functions for generating docker-compose files and docker run commands

# Function to generate temporary docker-compose.yml from config
# Args: container_name, app_port, full_image, env_file, network_name, network_alias, container_port
# Returns: Path to temporary docker-compose file (stdout)
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
    # Check if health checks are enabled (default: true for backward compatibility)
    local health_enabled=$(parse_config ".health_check.enabled" "true")
    local health_endpoint=$(parse_config ".health_check.endpoint" "")

    if [ "$health_enabled" = "true" ] && [ -n "$health_endpoint" ]; then
        echo "" >> "$temp_compose"
        echo "    healthcheck:" >> "$temp_compose"

        # Check if custom health check command is provided
        local custom_command=$(parse_config ".health_check.command" "" | grep -E "^\s*-\s*" || true)

        if [ -n "$custom_command" ]; then
            # Use custom health check command from config
            # Parse array items and build the test command
            local cmd_parts=()
            while IFS= read -r line; do
                # Extract value after dash
                local part=$(echo "$line" | sed 's/^\s*-\s*//')
                # Strip inline comments (before removing quotes to handle: "value" # comment)
                part=$(echo "$part" | sed 's/[[:space:]]*#.*//')
                # Trim whitespace and remove surrounding quotes
                part=$(echo "$part" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed 's/^"//; s/"$//')
                if [ -n "$part" ]; then
                    # Substitute template variables using parameter expansion (more reliable than sed)
                    part="${part//\$\{container_port\}/${container_port}}"
                    part="${part//\$\{health_endpoint\}/${health_endpoint}}"
                    cmd_parts+=("$part")
                fi
            done <<< "$custom_command"

            # Build JSON array format for docker-compose
            echo -n "      test: [" >> "$temp_compose"
            local first=true
            for part in "${cmd_parts[@]}"; do
                if [ "$first" = true ]; then
                    first=false
                else
                    echo -n ", " >> "$temp_compose"
                fi
                echo -n "\"$part\"" >> "$temp_compose"
            done
            echo "]" >> "$temp_compose"
        else
            # Use default wget-based health check
            echo "      test: [\"CMD\", \"wget\", \"--quiet\", \"--tries=1\", \"--spider\", \"http://127.0.0.1:${container_port}${health_endpoint}\"]" >> "$temp_compose"
        fi

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
# Args: container_name, app_port, full_image, env_file, network_name, network_alias, container_port
# Returns: Docker run command string (stdout)
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

    # Fix health check format (decomposerize outputs CMD,wget,... but docker expects space-separated and quoted)
    if echo "$docker_run_cmd" | grep -q -- "--health-cmd"; then
        # Extract health command value - decomposerize outputs comma-separated format
        # Example: --health-cmd CMD,wget,--quiet,--tries=1,--spider,http://...
        # We need to convert to: --health-cmd "wget --quiet --tries=1 --spider http://..."
        local health_value=$(echo "$docker_run_cmd" | sed -n 's/.*--health-cmd \([^ ]*\).*/\1/p' | sed 's/^CMD,//' | tr ',' ' ')
        # Replace with properly quoted and escaped health command (escape for heredoc)
        # Use '\' to escape quotes so they survive heredoc expansion
        docker_run_cmd=$(echo "$docker_run_cmd" | sed "s|--health-cmd [^ ]*|--health-cmd \\\\\"$health_value\\\\\"|")
    fi

    # Fix log options (decomposerize may output: --log-opt max-file=3,max-size=10m)
    docker_run_cmd=$(echo "$docker_run_cmd" | sed 's/--log-opt \([^,]*\),\([a-z-]*=\)/--log-opt \1 --log-opt \2/g')

    echo "$docker_run_cmd"
}
