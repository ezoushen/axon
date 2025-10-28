#!/bin/bash
# AXON SSH Batch Execution Library
# Reduces SSH connection overhead by batching commands into a single execution
# Part of AXON - reusable across products

# Load SSH connection multiplexing library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/ssh-connection.sh" ]; then
    source "$SCRIPT_DIR/ssh-connection.sh"
fi

# Usage:
#   source lib/ssh-batch.sh
#   ssh_batch_start
#   ssh_batch_add "echo 'command1'"
#   ssh_batch_add "echo 'command2'"
#   ssh_batch_execute "$SSH_KEY" "$SERVER" ["server_role"]
#   ssh_batch_result "command1"  # Get result of specific command

# Internal variables
_SSH_BATCH_COMMANDS=()
_SSH_BATCH_MARKERS=()
_SSH_BATCH_OUTPUT=""
_SSH_BATCH_COUNTER=0

# Start a new batch
ssh_batch_start() {
    _SSH_BATCH_COMMANDS=()
    _SSH_BATCH_MARKERS=()
    _SSH_BATCH_OUTPUT=""
    _SSH_BATCH_COUNTER=0
}

# Add a command to the batch
# Args: command [label]
ssh_batch_add() {
    local command=$1
    local label=${2:-"cmd_$_SSH_BATCH_COUNTER"}

    local marker="__AXON_MARKER_${_SSH_BATCH_COUNTER}__"
    _SSH_BATCH_COMMANDS+=("$command")
    _SSH_BATCH_MARKERS+=("$marker:$label")
    _SSH_BATCH_COUNTER=$((_SSH_BATCH_COUNTER + 1))
}

# Execute the batch on remote server
# Args: ssh_key server_address [server_role] [options]
# server_role: "system" or "app" (default: "app") - used for SSH multiplexing
# Options: --fail-fast (exit on first error)
ssh_batch_execute() {
    local ssh_key=$1
    local server=$2
    local server_role="app"
    local fail_fast=false

    shift 2

    # Check if third argument is a server role (not a flag)
    if [[ $# -gt 0 && "$1" != --* ]]; then
        server_role="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --fail-fast)
                fail_fast=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Get SSH multiplexing options (if available)
    local ssh_multiplex_opts=""
    if type ssh_get_multiplex_opts >/dev/null 2>&1; then
        ssh_multiplex_opts=$(ssh_get_multiplex_opts "$server_role")

        # Verbose output (only once per role, consistent with axon_ssh)
        if [ "$AXON_SSH_VERBOSE" = "1" ]; then
            if ! echo "$_AXON_SSH_MASTERS_ANNOUNCED" | grep -q " ${server_role} "; then
                echo "[SSH] Creating master connection (role: ${server_role})" >&2
                _AXON_SSH_MASTERS_ANNOUNCED="$_AXON_SSH_MASTERS_ANNOUNCED ${server_role} "
            fi
        fi
    fi

    # Build remote script
    local script="#!/bin/bash
set -o pipefail
"

    if [ "$fail_fast" = true ]; then
        script+="set -e
"
    fi

    # Add each command with markers
    local i=0
    for cmd in "${_SSH_BATCH_COMMANDS[@]}"; do
        local marker="${_SSH_BATCH_MARKERS[$i]}"
        marker="${marker%%:*}"  # Extract marker name

        script+="
# Command $i
echo '${marker}:START'
{
$cmd
} && echo '${marker}:EXIT:0' || echo '${marker}:EXIT:'\$?
"
        i=$((i + 1))
    done

    # Execute via SSH with multiplexing options
    _SSH_BATCH_OUTPUT=$(ssh $ssh_multiplex_opts -i "$ssh_key" "$server" bash <<EOF
$script
EOF
)

    return $?
}

# Get result of a specific command by label
# Args: label
# Returns: command output (without markers)
ssh_batch_result() {
    local label=$1

    # Find the marker for this label
    local marker=""
    for marker_label in "${_SSH_BATCH_MARKERS[@]}"; do
        if [[ "$marker_label" == *":$label" ]]; then
            marker="${marker_label%%:*}"
            break
        fi
    done

    if [ -z "$marker" ]; then
        echo "Error: Label '$label' not found" >&2
        return 1
    fi

    # Extract output between START and EXIT markers
    echo "$_SSH_BATCH_OUTPUT" | awk "
        /^${marker}:START\$/ { recording=1; next }
        /^${marker}:EXIT:/ { recording=0 }
        recording { print }
    "
}

# Get exit code of a specific command by label
# Args: label
# Returns: exit code
ssh_batch_exitcode() {
    local label=$1

    # Find the marker for this label
    local marker=""
    for marker_label in "${_SSH_BATCH_MARKERS[@]}"; do
        if [[ "$marker_label" == *":$label" ]]; then
            marker="${marker_label%%:*}"
            break
        fi
    done

    if [ -z "$marker" ]; then
        echo "255"  # Error: label not found
        return 1
    fi

    # Extract exit code
    local exitcode=$(echo "$_SSH_BATCH_OUTPUT" | grep "^${marker}:EXIT:" | cut -d: -f3)
    echo "${exitcode:-255}"
}

# Get full raw output (for debugging)
ssh_batch_raw_output() {
    echo "$_SSH_BATCH_OUTPUT"
}

# ==============================================================================
# Async Parallel Execution Support
# ==============================================================================

# Global indexed arrays for async batch tracking (Bash 3.2 compatible)
# Each entry is stored as "batch_id:value"
_SSH_BATCH_ASYNC_PIDS=()
_SSH_BATCH_ASYNC_OUTPUTS=()
_SSH_BATCH_ASYNC_COMMANDS=()
_SSH_BATCH_ASYNC_MARKERS=()

# Helper: Get value from array by batch_id
_async_get() {
    local array_name=$1
    local batch_id=$2
    local array_ref="${array_name}[@]"

    for entry in "${!array_ref}"; do
        if [[ "$entry" == "${batch_id}:"* ]]; then
            echo "${entry#*:}"
            return 0
        fi
    done
    return 1
}

# Helper: Set value in array by batch_id
_async_set() {
    local array_name=$1
    local batch_id=$2
    local value=$3

    # Remove existing entry if present
    _async_unset "$array_name" "$batch_id"

    # Add new entry (properly handle special characters and newlines)
    local entry="${batch_id}:${value}"
    eval "${array_name}+=(\"$(printf '%s' "$entry" | sed 's/"/\\"/g')\")"
}

# Helper: Unset value in array by batch_id
_async_unset() {
    local array_name=$1
    local batch_id=$2
    local array_ref="${array_name}[@]"
    local new_array=()

    for entry in "${!array_ref}"; do
        if [[ "$entry" != "${batch_id}:"* ]]; then
            new_array+=("$entry")
        fi
    done

    eval "${array_name}=(\"\${new_array[@]}\")"
}

# Execute batch asynchronously in background
# Args: ssh_key server batch_id [server_role] [options]
# server_role: "system" or "app" (default: "app") - used for SSH multiplexing
# Returns: immediately, job runs in background
ssh_batch_execute_async() {
    local ssh_key=$1
    local server=$2
    local batch_id=$3
    local server_role="app"
    local fail_fast=false

    shift 3

    # Check if fourth argument is a server role (not a flag)
    if [[ $# -gt 0 && "$1" != --* ]]; then
        server_role="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --fail-fast)
                fail_fast=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Get SSH multiplexing options (if available)
    local ssh_multiplex_opts=""
    if type ssh_get_multiplex_opts >/dev/null 2>&1; then
        ssh_multiplex_opts=$(ssh_get_multiplex_opts "$server_role")

        # Verbose output (only once per role, consistent with axon_ssh)
        if [ "$AXON_SSH_VERBOSE" = "1" ]; then
            if ! echo "$_AXON_SSH_MASTERS_ANNOUNCED" | grep -q " ${server_role} "; then
                echo "[SSH] Creating master connection (role: ${server_role})" >&2
                _AXON_SSH_MASTERS_ANNOUNCED="$_AXON_SSH_MASTERS_ANNOUNCED ${server_role} "
            fi
        fi
    fi

    # Store commands and markers for this batch
    local commands_str=""
    local markers_str=""
    for cmd in "${_SSH_BATCH_COMMANDS[@]}"; do
        commands_str+="$cmd"$'\n'
    done
    for marker in "${_SSH_BATCH_MARKERS[@]}"; do
        markers_str+="$marker"$'\n'
    done
    _async_set "_SSH_BATCH_ASYNC_COMMANDS" "$batch_id" "$commands_str"
    _async_set "_SSH_BATCH_ASYNC_MARKERS" "$batch_id" "$markers_str"

    # Build remote script
    local script="#!/bin/bash
set -o pipefail
"

    if [ "$fail_fast" = true ]; then
        script+="set -e
"
    fi

    # Add each command with markers
    local i=0
    for cmd in "${_SSH_BATCH_COMMANDS[@]}"; do
        local marker="${_SSH_BATCH_MARKERS[$i]}"
        marker="${marker%%:*}"

        script+="
# Command $i
echo '${marker}:START'
{
$cmd
} && echo '${marker}:EXIT:0' || echo '${marker}:EXIT:'\$?
"
        i=$((i + 1))
    done

    # Execute via SSH in background with multiplexing options, capture output to temp file
    local temp_output="/tmp/axon_batch_${batch_id}_$$.out"
    {
        ssh $ssh_multiplex_opts -i "$ssh_key" "$server" bash <<EOF
$script
EOF
    } > "$temp_output" 2>&1 &

    # Store PID and output file
    _async_set "_SSH_BATCH_ASYNC_PIDS" "$batch_id" "$!"
    _async_set "_SSH_BATCH_ASYNC_OUTPUTS" "$batch_id" "$temp_output"
}

# Wait for one or more async batches to complete
# Args: batch_id1 [batch_id2 ...]
# Returns: 0 if all succeeded, 1 if any failed
ssh_batch_wait() {
    local exit_code=0

    for batch_id in "$@"; do
        local pid=$(_async_get "_SSH_BATCH_ASYNC_PIDS" "$batch_id")
        if [ -z "$pid" ]; then
            echo "Error: Unknown batch_id: $batch_id" >&2
            return 1
        fi

        # Wait for this specific job
        wait "$pid"
        local job_exit=$?

        if [ $job_exit -ne 0 ]; then
            exit_code=1
        fi
    done

    return $exit_code
}

# Get result from async batch
# Args: batch_id label
ssh_batch_result_from() {
    local batch_id=$1
    local label=$2

    local output_file=$(_async_get "_SSH_BATCH_ASYNC_OUTPUTS" "$batch_id")
    if [ -z "$output_file" ] || [ ! -f "$output_file" ]; then
        echo "Error: Output file not found for batch $batch_id" >&2
        return 1
    fi

    local batch_output=$(cat "$output_file")

    # Reconstruct markers from stored data
    local markers_str=$(_async_get "_SSH_BATCH_ASYNC_MARKERS" "$batch_id")

    # Find the marker for this label
    local marker=""
    while IFS= read -r marker_label; do
        if [[ "$marker_label" == *":$label" ]]; then
            marker="${marker_label%%:*}"
            break
        fi
    done <<< "$markers_str"

    if [ -z "$marker" ]; then
        echo "Error: Label '$label' not found in batch $batch_id" >&2
        return 1
    fi

    # Extract output between START and EXIT markers
    echo "$batch_output" | awk "
        /^${marker}:START\$/ { recording=1; next }
        /^${marker}:EXIT:/ { recording=0 }
        recording { print }
    "
}

# Get exit code from async batch
# Args: batch_id label
ssh_batch_exitcode_from() {
    local batch_id=$1
    local label=$2

    local output_file=$(_async_get "_SSH_BATCH_ASYNC_OUTPUTS" "$batch_id")
    if [ -z "$output_file" ] || [ ! -f "$output_file" ]; then
        echo "255"
        return 1
    fi

    local batch_output=$(cat "$output_file")

    # Reconstruct markers
    local markers_str=$(_async_get "_SSH_BATCH_ASYNC_MARKERS" "$batch_id")

    local marker=""
    while IFS= read -r marker_label; do
        if [[ "$marker_label" == *":$label" ]]; then
            marker="${marker_label%%:*}"
            break
        fi
    done <<< "$markers_str"

    if [ -z "$marker" ]; then
        echo "255"
        return 1
    fi

    local exitcode=$(echo "$batch_output" | grep "^${marker}:EXIT:" | cut -d: -f3)
    echo "${exitcode:-255}"
}

# Clean up async batch resources
# Args: batch_id1 [batch_id2 ...]
ssh_batch_cleanup() {
    for batch_id in "$@"; do
        local output_file=$(_async_get "_SSH_BATCH_ASYNC_OUTPUTS" "$batch_id")
        if [ -n "$output_file" ] && [ -f "$output_file" ]; then
            rm -f "$output_file"
        fi
        _async_unset "_SSH_BATCH_ASYNC_PIDS" "$batch_id"
        _async_unset "_SSH_BATCH_ASYNC_OUTPUTS" "$batch_id"
        _async_unset "_SSH_BATCH_ASYNC_COMMANDS" "$batch_id"
        _async_unset "_SSH_BATCH_ASYNC_MARKERS" "$batch_id"
    done
}

# Example usage in comments:
: <<'EXAMPLE'
# Start a batch
ssh_batch_start

# Add commands
ssh_batch_add "docker ps --format '{{.Names}}'" "list_containers"
ssh_batch_add "docker inspect mycontainer --format '{{.State.Health.Status}}'" "health_status"
ssh_batch_add "cat /etc/nginx/conf.d/upstream.conf" "nginx_config"

# Execute all at once
ssh_batch_execute "$SSH_KEY" "user@server"

# Get individual results
CONTAINERS=$(ssh_batch_result "list_containers")
HEALTH=$(ssh_batch_result "health_status")
NGINX_CONF=$(ssh_batch_result "nginx_config")

# Check exit codes
if [ $(ssh_batch_exitcode "health_status") -ne 0 ]; then
    echo "Health check failed"
fi
EXAMPLE
