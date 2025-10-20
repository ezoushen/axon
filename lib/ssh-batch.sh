#!/bin/bash
# AXON SSH Batch Execution Library
# Reduces SSH connection overhead by batching commands into a single execution
# Part of AXON - reusable across products

# Usage:
#   source lib/ssh-batch.sh
#   ssh_batch_start
#   ssh_batch_add "echo 'command1'"
#   ssh_batch_add "echo 'command2'"
#   ssh_batch_execute "$SSH_KEY" "$SERVER"
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
# Args: ssh_key server_address [options]
# Options: --fail-fast (exit on first error)
ssh_batch_execute() {
    local ssh_key=$1
    local server=$2
    local fail_fast=false

    shift 2
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

    # Execute via SSH
    _SSH_BATCH_OUTPUT=$(ssh -i "$ssh_key" "$server" bash <<EOF
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

# Global associative arrays for async batch tracking
declare -A _SSH_BATCH_ASYNC_PIDS=()
declare -A _SSH_BATCH_ASYNC_OUTPUTS=()
declare -A _SSH_BATCH_ASYNC_COMMANDS=()
declare -A _SSH_BATCH_ASYNC_MARKERS=()

# Execute batch asynchronously in background
# Args: ssh_key server batch_id [options]
# Returns: immediately, job runs in background
ssh_batch_execute_async() {
    local ssh_key=$1
    local server=$2
    local batch_id=$3
    local fail_fast=false

    shift 3
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

    # Store commands and markers for this batch
    local commands_str=""
    local markers_str=""
    for cmd in "${_SSH_BATCH_COMMANDS[@]}"; do
        commands_str+="$cmd"$'\n'
    done
    for marker in "${_SSH_BATCH_MARKERS[@]}"; do
        markers_str+="$marker"$'\n'
    done
    _SSH_BATCH_ASYNC_COMMANDS[$batch_id]="$commands_str"
    _SSH_BATCH_ASYNC_MARKERS[$batch_id]="$markers_str"

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

    # Execute via SSH in background, capture output to temp file
    local temp_output="/tmp/axon_batch_${batch_id}_$$.out"
    {
        ssh -i "$ssh_key" "$server" bash <<EOF
$script
EOF
    } > "$temp_output" 2>&1 &

    # Store PID and output file
    _SSH_BATCH_ASYNC_PIDS[$batch_id]=$!
    _SSH_BATCH_ASYNC_OUTPUTS[$batch_id]="$temp_output"
}

# Wait for one or more async batches to complete
# Args: batch_id1 [batch_id2 ...]
# Returns: 0 if all succeeded, 1 if any failed
ssh_batch_wait() {
    local exit_code=0

    for batch_id in "$@"; do
        if [ -z "${_SSH_BATCH_ASYNC_PIDS[$batch_id]}" ]; then
            echo "Error: Unknown batch_id: $batch_id" >&2
            return 1
        fi

        local pid="${_SSH_BATCH_ASYNC_PIDS[$batch_id]}"

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

    local output_file="${_SSH_BATCH_ASYNC_OUTPUTS[$batch_id]}"
    if [ ! -f "$output_file" ]; then
        echo "Error: Output file not found for batch $batch_id" >&2
        return 1
    fi

    local batch_output=$(cat "$output_file")

    # Reconstruct markers from stored data
    local markers_str="${_SSH_BATCH_ASYNC_MARKERS[$batch_id]}"

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

    local output_file="${_SSH_BATCH_ASYNC_OUTPUTS[$batch_id]}"
    if [ ! -f "$output_file" ]; then
        echo "255"
        return 1
    fi

    local batch_output=$(cat "$output_file")

    # Reconstruct markers
    local markers_str="${_SSH_BATCH_ASYNC_MARKERS[$batch_id]}"

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
        local output_file="${_SSH_BATCH_ASYNC_OUTPUTS[$batch_id]}"
        if [ -f "$output_file" ]; then
            rm -f "$output_file"
        fi
        unset "_SSH_BATCH_ASYNC_PIDS[$batch_id]"
        unset "_SSH_BATCH_ASYNC_OUTPUTS[$batch_id]"
        unset "_SSH_BATCH_ASYNC_COMMANDS[$batch_id]"
        unset "_SSH_BATCH_ASYNC_MARKERS[$batch_id]"
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
