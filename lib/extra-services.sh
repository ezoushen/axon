#!/bin/bash
# AXON - Extra Services (Sidecars) Library
# Copyright (C) 2024-2025 ezoushen
# Licensed under GPL-3.0 - See LICENSE file for details
#
# Sidecar containers declared under docker.extra_services.<name>.
# Sidecars inherit the main container's image, env file, network, restart and
# logging policy. They never expose ports and never get an nginx upstream.

# List sidecar service names (one per line; empty if none).
# Uses CONFIG_FILE from the environment.
get_extra_service_names() {
    local config_file=${1:-$CONFIG_FILE}
    local value
    value=$(yq eval '.docker.extra_services | keys | .[]' "$config_file" 2>/dev/null)
    if [ "$value" != "null" ] && [ -n "$value" ]; then
        echo "$value"
    fi
}

# Emit a sidecar's command as a single-line JSON array (or string).
# Example: ["./worker", "--concurrency=4"]
get_extra_service_command_json() {
    local name=$1
    local config_file=${2:-$CONFIG_FILE}
    local value
    value=$(yq eval -o=json -I0 ".docker.extra_services.\"${name}\".command" "$config_file" 2>/dev/null \
        | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    if [ "$value" != "null" ] && [ -n "$value" ]; then
        echo "$value"
    fi
}

# Return a sidecar's raw compose_override YAML (empty if not set).
get_extra_service_compose_override() {
    local name=$1
    local config_file=${2:-$CONFIG_FILE}
    local value
    value=$(yq eval ".docker.extra_services.\"${name}\".compose_override" "$config_file" 2>/dev/null)
    if [ "$value" != "null" ] && [ -n "$value" ]; then
        echo "$value"
    fi
}

# Build a sidecar container name carrying the -svc- marker.
# Args: product, env, service_name, timestamp
sidecar_container_name() {
    echo "${1}-${2}-svc-${3}-${4}"
}
