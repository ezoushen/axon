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

# Deploy all sidecars after the main container is live. Each sidecar:
#   - inherits FULL_IMAGE, ENV_PATH, NETWORK_NAME, docker.restart_policy, logging
#   - is started as a new timestamped -svc- container
#   - has its own old same-name containers stopped/removed (per-name cleanup)
# Sidecars never gate the main deploy: failures here log a warning and leave the
# main container untouched. Relies on globals set by deploy_docker:
#   PRODUCT_NAME ENVIRONMENT FULL_IMAGE ENV_PATH NETWORK_NAME
#   APP_SSH_KEY APP_SERVER CONFIG_FILE
# Args: timestamp
deploy_extra_services() {
    local timestamp=$1
    local names
    names=$(get_extra_service_names "$CONFIG_FILE")
    [ -z "$names" ] && return 0

    echo -e "${BLUE}Deploying extra services (sidecars)...${NC}"

    local restart_policy log_driver log_max_size log_max_file
    restart_policy=$(parse_config ".docker.restart_policy" "unless-stopped")
    log_driver=$(parse_config ".docker.logging.driver" "json-file")
    log_max_size=$(parse_config ".docker.logging.max_size" "10m")
    log_max_file=$(parse_config ".docker.logging.max_file" "3")

    local name
    while IFS= read -r name; do
        [ -z "$name" ] && continue

        local cmd_json override svc_container run_cmd
        cmd_json=$(get_extra_service_command_json "$name")
        if [ -z "$cmd_json" ] || [ "$cmd_json" = "null" ]; then
            echo -e "  ${YELLOW}⚠ Skipping ${name}: no command${NC}"
            continue
        fi
        override=$(get_extra_service_compose_override "$name")
        svc_container=$(sidecar_container_name "$PRODUCT_NAME" "$ENVIRONMENT" "$name" "$timestamp")

        run_cmd=$(build_sidecar_run_command \
            "$svc_container" "$FULL_IMAGE" "$ENV_PATH" "$NETWORK_NAME" \
            "$restart_policy" "$cmd_json" "$override" \
            "$log_driver" "$log_max_size" "$log_max_file")
        if [ $? -ne 0 ] || [ -z "$run_cmd" ]; then
            echo -e "  ${YELLOW}⚠ ${name}: could not build run command (sidecar skipped)${NC}"
            continue
        fi

        ssh -i "$APP_SSH_KEY" "$APP_SERVER" bash <<EOF
set -e
NETWORK_NAME="${NETWORK_NAME}"
SVC_CONTAINER="${svc_container}"
SVC_PREFIX="${PRODUCT_NAME}-${ENVIRONMENT}-svc-${name}-"

if ! docker network ls | grep -q "\${NETWORK_NAME}"; then
    docker network create "\${NETWORK_NAME}"
fi

docker rm -f "\${SVC_CONTAINER}" 2>/dev/null || true
eval "${run_cmd}"

OLD=\$(docker ps -a --filter "name=\${SVC_PREFIX}" --format '{{.Names}}' | grep -v "^\${SVC_CONTAINER}\$" || true)
if [ -n "\$OLD" ]; then
    for c in \$OLD; do
        docker stop "\$c" 2>/dev/null || true
        docker rm "\$c" 2>/dev/null || true
    done
fi
EOF
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}✓${NC} ${name} → ${svc_container}"
        else
            echo -e "  ${YELLOW}⚠ ${name}: deploy reported an error (main container unaffected)${NC}"
        fi
    done <<< "$names"
    echo ""
}
