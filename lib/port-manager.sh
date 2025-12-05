#!/bin/bash
# AXON - Port Manager Library
# Copyright (C) 2024-2025 ezoushen
# Licensed under GPL-3.0 - See LICENSE file for details
#
# Manages port allocation for Docker containers
# Ports are picked by AXON from a dedicated range to avoid conflicts

# ==============================================================================
# Port Range Configuration
# ==============================================================================
# Use a dedicated range below Docker's default ephemeral range (32768-60999)
# This prevents conflicts with Docker's auto-assigned ports
readonly AXON_PORT_RANGE_START="${AXON_PORT_RANGE_START:-30000}"
readonly AXON_PORT_RANGE_END="${AXON_PORT_RANGE_END:-32767}"

# Maximum attempts to find an available port
readonly AXON_PORT_MAX_ATTEMPTS="${AXON_PORT_MAX_ATTEMPTS:-50}"

# ==============================================================================
# Port Availability Functions
# ==============================================================================

# Check if a port is available on the Application Server
# Args: $1 - ssh_key, $2 - app_server, $3 - port
# Returns: 0 if available, 1 if in use
is_port_available() {
    local ssh_key="$1"
    local app_server="$2"
    local port="$3"

    # Get SSH multiplexing options if available
    local ssh_opts=""
    if type ssh_get_multiplex_opts >/dev/null 2>&1; then
        ssh_opts=$(ssh_get_multiplex_opts "app")
    fi

    # Check if port is in use using ss (socket statistics)
    # ss -tuln shows TCP/UDP listening ports
    local result=$(ssh $ssh_opts -i "$ssh_key" "$app_server" \
        "ss -tuln 2>/dev/null | grep -q ':${port} ' && echo 'IN_USE' || echo 'AVAILABLE'")

    if [ "$result" = "AVAILABLE" ]; then
        return 0
    else
        return 1
    fi
}

# Generate a random port within the AXON range
# Returns: Random port number
generate_random_port() {
    local range=$((AXON_PORT_RANGE_END - AXON_PORT_RANGE_START + 1))
    local random_offset=$((RANDOM % range))
    echo $((AXON_PORT_RANGE_START + random_offset))
}

# Pick an available port on the Application Server
# This function finds a random available port in the AXON range
# Args: $1 - ssh_key, $2 - app_server, $3 - excluded_port (optional, port to avoid)
# Returns: Available port number, or empty string on failure
pick_available_port() {
    local ssh_key="$1"
    local app_server="$2"
    local excluded_port="${3:-}"

    local attempts=0
    local port=""

    while [ $attempts -lt $AXON_PORT_MAX_ATTEMPTS ]; do
        port=$(generate_random_port)

        # Skip if this is the excluded port
        if [ -n "$excluded_port" ] && [ "$port" = "$excluded_port" ]; then
            attempts=$((attempts + 1))
            continue
        fi

        # Check if port is available
        if is_port_available "$ssh_key" "$app_server" "$port"; then
            echo "$port"
            return 0
        fi

        attempts=$((attempts + 1))
    done

    # Failed to find available port
    echo ""
    return 1
}

# ==============================================================================
# Container Port Query Functions
# ==============================================================================

# Get the current port of a running container
# Args: $1 - ssh_key, $2 - app_server, $3 - container_name, $4 - container_port
# Returns: Host port number or empty string if not found
get_container_port() {
    local ssh_key="$1"
    local app_server="$2"
    local container_name="$3"
    local container_port="$4"

    # Get SSH multiplexing options if available
    local ssh_opts=""
    if type ssh_get_multiplex_opts >/dev/null 2>&1; then
        ssh_opts=$(ssh_get_multiplex_opts "app")
    fi

    # Query docker port
    local port=$(ssh $ssh_opts -i "$ssh_key" "$app_server" \
        "docker port '$container_name' '$container_port' 2>/dev/null | cut -d: -f2")

    # Validate it's a number
    if [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
    else
        echo ""
    fi
}

# Get the port from nginx upstream configuration
# Args: $1 - ssh_key, $2 - system_server, $3 - upstream_file
# Returns: Port number or empty string if not found
get_nginx_upstream_port() {
    local ssh_key="$1"
    local system_server="$2"
    local upstream_file="$3"

    # Get SSH multiplexing options if available
    local ssh_opts=""
    if type ssh_get_multiplex_opts >/dev/null 2>&1; then
        ssh_opts=$(ssh_get_multiplex_opts "system")
    fi

    # Extract port from upstream config
    local port=$(ssh $ssh_opts -i "$ssh_key" "$system_server" \
        "grep -oP 'server.*:\K\d+' '$upstream_file' 2>/dev/null || echo ''")

    # Validate it's a number
    if [[ "$port" =~ ^[0-9]+$ ]]; then
        echo "$port"
    else
        echo ""
    fi
}

# ==============================================================================
# Port Synchronization Functions
# ==============================================================================

# Check if nginx upstream port matches container port
# Args: $1 - nginx_port, $2 - container_port
# Returns: 0 if matched, 1 if mismatched
ports_match() {
    local nginx_port="$1"
    local container_port="$2"

    if [ -n "$nginx_port" ] && [ -n "$container_port" ] && [ "$nginx_port" = "$container_port" ]; then
        return 0
    else
        return 1
    fi
}

# Sync nginx upstream with actual container port
# This updates nginx upstream config to point to the container's current port
# Args: Multiple parameters for server connections and config paths
# Returns: 0 on success, 1 on failure
sync_nginx_upstream() {
    local app_ssh_key="$1"
    local app_server="$2"
    local system_ssh_key="$3"
    local system_server="$4"
    local container_name="$5"
    local container_port="$6"
    local upstream_file="$7"
    local upstream_name="$8"
    local upstream_ip="$9"
    local use_sudo="${10:-}"

    # Get current container port
    local actual_port=$(get_container_port "$app_ssh_key" "$app_server" "$container_name" "$container_port")

    if [ -z "$actual_port" ]; then
        echo "Error: Could not determine container port" >&2
        return 1
    fi

    # Get current nginx port
    local nginx_port=$(get_nginx_upstream_port "$system_ssh_key" "$system_server" "$upstream_file")

    # Check if sync is needed
    if ports_match "$nginx_port" "$actual_port"; then
        echo "Ports already match: $actual_port"
        return 0
    fi

    echo "Port mismatch detected: nginx=$nginx_port, container=$actual_port"
    echo "Updating nginx upstream to port $actual_port..."

    # Get SSH multiplexing options if available
    local ssh_opts=""
    if type ssh_get_multiplex_opts >/dev/null 2>&1; then
        ssh_opts=$(ssh_get_multiplex_opts "system")
    fi

    # Generate new upstream config
    local upstream_config="upstream ${upstream_name} {
    server ${upstream_ip}:${actual_port};
}"

    # Update nginx upstream and reload
    ssh $ssh_opts -i "$system_ssh_key" "$system_server" bash <<EOF
        echo '$upstream_config' | ${use_sudo} tee '$upstream_file' > /dev/null
        ${use_sudo} nginx -t 2>&1 && ${use_sudo} nginx -s reload
EOF

    if [ $? -eq 0 ]; then
        echo "nginx upstream synced to port $actual_port"
        return 0
    else
        echo "Error: Failed to update nginx upstream" >&2
        return 1
    fi
}
