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

# Validate docker.extra_services. Relies on report_error/report_success being
# defined by the caller (validate-config.sh). Enforces inherit-only contract:
#   - command is REQUIRED
#   - ports / image / env_path / env_file / expose / health_check are FORBIDDEN
validate_extra_services() {
    local config_file=${1:-$CONFIG_FILE}
    local names
    names=$(get_extra_service_names "$config_file")

    if [ -z "$names" ]; then
        return 0
    fi

    local forbidden="ports image env_path env_file expose health_check"
    local name
    while IFS= read -r name; do
        [ -z "$name" ] && continue

        local cmd
        cmd=$(yq eval ".docker.extra_services.\"${name}\".command" "$config_file" 2>/dev/null)
        if [ "$cmd" = "null" ] || [ -z "$cmd" ]; then
            report_error "extra_services.${name}: 'command' is required"
        else
            report_success "extra_services.${name}: command configured"
        fi

        local key has
        for key in $forbidden; do
            has=$(yq eval ".docker.extra_services.\"${name}\" | has(\"${key}\")" "$config_file" 2>/dev/null)
            if [ "$has" = "true" ]; then
                report_error "extra_services.${name}: '${key}' is not allowed (sidecars inherit from the main container and are never exposed)"
            fi
        done
    done <<< "$names"
}

# Pick the latest container for logs from a newline list on stdin.
# Args: env_filter (e.g. product-env), service ("" => main container)
# - main: names starting "<env_filter>-" but NOT containing -svc-
# - service: names starting "<env_filter>-svc-<service>-"
pick_latest_container() {
    local env_filter=$1
    local service=$2
    if [ -n "$service" ]; then
        grep "^${env_filter}-svc-${service}-" | sort -r | head -n 1
    else
        grep "^${env_filter}-" | grep -v -- '-svc-' | sort -r | head -n 1
    fi
}

# Filter a newline-delimited container list (stdin), dropping the new main
# container and every sidecar (names containing -svc-).
# NOTE: This is a tested parity model of the reap pipelines embedded in
# deploy-docker.sh Step 9 and Step 10 — those run remotely inside SSH heredocs
# and cannot call this function, so the exclusion is duplicated inline there.
# Keep this in sync with both sweeps (guarded by `grep -c "grep -v -- '-svc-'"`).
# Args: new_container_name
reap_filter() {
    local new_container=$1
    grep -v "^${new_container}\$" | grep -v -- '-svc-' || true
}
