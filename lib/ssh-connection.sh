#!/usr/bin/env bash
# AXON - SSH Connection Multiplexing Library
# Copyright (C) 2024-2025 ezoushen
# Licensed under GPL-3.0 - See LICENSE file for details
#
# Provides persistent SSH connections to reduce connection overhead
# Compatible with Bash 3.2+

# Global variables for SSH multiplexing
AXON_SSH_SOCKET_DIR="${HOME}/.axon/ssh-sockets"
AXON_SSH_MULTIPLEX="${AXON_SSH_MULTIPLEX:-1}"  # Default: enabled
AXON_SSH_VERBOSE="${AXON_SSH_VERBOSE:-0}"      # Default: quiet

# Track which master connections have been announced (space-separated list)
# Compatible with Bash 3.2 (no associative arrays)
_AXON_SSH_MASTERS_ANNOUNCED=""

# Initialize SSH multiplexing for the current command
# Creates socket directory and sets up cleanup trap
# Usage: ssh_init_multiplexing
ssh_init_multiplexing() {
    # Create socket directory if it doesn't exist
    if [ ! -d "$AXON_SSH_SOCKET_DIR" ]; then
        mkdir -p "$AXON_SSH_SOCKET_DIR" 2>/dev/null
        if [ $? -ne 0 ]; then
            # Fallback to temp directory if home directory not writable
            AXON_SSH_SOCKET_DIR="/tmp/axon-ssh-sockets-$$"
            mkdir -p "$AXON_SSH_SOCKET_DIR" 2>/dev/null
        fi
    fi

    # Set restrictive permissions on socket directory
    chmod 700 "$AXON_SSH_SOCKET_DIR" 2>/dev/null

    # Register cleanup trap (preserve existing traps)
    trap 'ssh_cleanup_multiplexing' EXIT INT TERM

    if [ "$AXON_SSH_VERBOSE" = "1" ]; then
        echo "[SSH] Multiplexing initialized: $AXON_SSH_SOCKET_DIR" >&2
    fi
}

# Get SSH multiplexing options for a given server role
# Args: $1 - server_role (optional, defaults to "app")
# Returns: SSH command-line options string
# Usage: ssh_opts=$(ssh_get_multiplex_opts "system")
ssh_get_multiplex_opts() {
    local server_role="${1:-app}"

    # Check if multiplexing is disabled
    if [ "$AXON_SSH_MULTIPLEX" = "0" ]; then
        echo ""
        return 0
    fi

    # Build control path using %C token (hash of connection params)
    # Fallback to %h-%p-%r for older SSH versions
    local control_path="${AXON_SSH_SOCKET_DIR}/${server_role}-%C"

    # ControlMaster=auto: reuse existing or create new master
    # ControlPath: socket file location
    # ControlPersist=yes: keep connection alive until explicit close
    # ServerAliveInterval=60: send keepalive every 60s to prevent timeout
    # ServerAliveCountMax=3: close if 3 keepalives fail
    echo "-o ControlMaster=auto -o ControlPath=${control_path} -o ControlPersist=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=3"
}

# Announce master connection creation (only once per role)
# Args: $1 - server_role
# Usage: ssh_announce_master_connection "system"
ssh_announce_master_connection() {
    local server_role="$1"

    if [ "$AXON_SSH_VERBOSE" = "1" ]; then
        # Check if we've already announced this role
        if ! echo "$_AXON_SSH_MASTERS_ANNOUNCED" | grep -q " ${server_role} "; then
            echo "[SSH] Creating master connection (role: ${server_role})" >&2
            # Mark this role as announced (with spaces for exact matching)
            _AXON_SSH_MASTERS_ANNOUNCED="$_AXON_SSH_MASTERS_ANNOUNCED ${server_role} "
        fi
    fi
}

# Handle stale SSH control socket errors
# Args: $1 - server_role
#       $@ - remaining SSH command arguments
# Returns: 0 if retry succeeded, non-zero otherwise
# Usage: ssh_handle_stale_socket "app" -i key.pem user@host "command"
ssh_handle_stale_socket() {
    local server_role="$1"
    shift

    if [ "$AXON_SSH_VERBOSE" = "1" ]; then
        echo "[SSH] Stale control socket detected, cleaning and retrying..." >&2
    fi

    # Clean stale socket and retry
    local control_path="${AXON_SSH_SOCKET_DIR}/${server_role}-%C"
    ssh -O exit -o ControlPath="${control_path}" 2>/dev/null || true
    rm -f "${control_path}" 2>/dev/null || true

    # Get multiplexing options for retry
    local ssh_opts
    ssh_opts=$(ssh_get_multiplex_opts "$server_role")

    # Retry without error capture (avoid infinite loop)
    ssh $ssh_opts "$@"
    return $?
}

# Wrapper for SSH commands with automatic multiplexing and error recovery
# Args: $1 - server_role ("system" or "app")
#       $@ - remaining arguments passed to ssh command
# Usage: axon_ssh "app" -i key.pem user@host "command"
axon_ssh() {
    local server_role="$1"
    shift

    # Get multiplexing options
    local ssh_opts
    ssh_opts=$(ssh_get_multiplex_opts "$server_role")

    # Announce master connection (only once per role)
    ssh_announce_master_connection "$server_role"

    # Try SSH with multiplexing
    local error_file="/tmp/axon_ssh_error_$$_${RANDOM}"
    if ssh $ssh_opts "$@" 2>"$error_file"; then
        # Success - clean up error file
        rm -f "$error_file" 2>/dev/null
        return 0
    else
        local exit_code=$?

        # Check if it's a control socket error
        if grep -q -i "control socket" "$error_file" 2>/dev/null || \
           grep -q -i "mux_client_request_session" "$error_file" 2>/dev/null; then

            # Handle stale socket and retry
            rm -f "$error_file"
            ssh_handle_stale_socket "$server_role" "$@"
            return $?
        else
            # Other error - propagate to stderr and return error code
            cat "$error_file" >&2
            rm -f "$error_file"
            return $exit_code
        fi
    fi
}

# Check if a master connection exists for a server role
# Args: $1 - server_role
# Returns: 0 if master exists, 1 otherwise
# Usage: if ssh_master_exists "app"; then ...
ssh_master_exists() {
    local server_role="${1:-app}"
    local control_path="${AXON_SSH_SOCKET_DIR}/${server_role}-%C"

    # Try to check master connection status
    if ssh -O check -o ControlPath="${control_path}" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Close a specific master connection
# Args: $1 - server_role
# Usage: ssh_close_master "system"
ssh_close_master() {
    local server_role="${1:-app}"
    local control_path="${AXON_SSH_SOCKET_DIR}/${server_role}-%C"

    if [ "$AXON_SSH_VERBOSE" = "1" ]; then
        echo "[SSH] Closing master connection: $server_role" >&2
    fi

    # Send exit command to master
    ssh -O exit -o ControlPath="${control_path}" 2>/dev/null || true

    # Remove socket file if it exists
    rm -f "${control_path}" 2>/dev/null || true
}

# Clean up all SSH master connections
# Called automatically on script exit via trap
# Usage: ssh_cleanup_multiplexing
ssh_cleanup_multiplexing() {
    if [ ! -d "$AXON_SSH_SOCKET_DIR" ]; then
        return 0
    fi

    if [ "$AXON_SSH_VERBOSE" = "1" ]; then
        echo "[SSH] Cleaning up multiplexed connections..." >&2
    fi

    # Close all active master connections
    for socket in "$AXON_SSH_SOCKET_DIR"/*; do
        if [ -S "$socket" ]; then
            # Send exit command
            ssh -O exit -o ControlPath="$socket" 2>/dev/null || true
        fi
    done

    # Clean up socket files
    # Only remove our temporary directory, not the permanent one
    if echo "$AXON_SSH_SOCKET_DIR" | grep -q "/tmp/axon-ssh-sockets-"; then
        rm -rf "$AXON_SSH_SOCKET_DIR" 2>/dev/null || true
    else
        # Just remove socket files, keep directory
        rm -f "$AXON_SSH_SOCKET_DIR"/* 2>/dev/null || true
    fi

    if [ "$AXON_SSH_VERBOSE" = "1" ]; then
        echo "[SSH] Cleanup complete" >&2
    fi
}

# Display status of active SSH multiplexed connections
# Usage: ssh_connection_status
ssh_connection_status() {
    echo "SSH Multiplexed Connections:"
    echo "Socket Directory: $AXON_SSH_SOCKET_DIR"
    echo ""

    if [ ! -d "$AXON_SSH_SOCKET_DIR" ]; then
        echo "No active connections (socket directory does not exist)"
        return 0
    fi

    local count=0
    for socket in "$AXON_SSH_SOCKET_DIR"/*; do
        if [ -S "$socket" ]; then
            count=$((count + 1))
            local socket_name=$(basename "$socket")
            echo "  [$count] $socket_name"

            # Try to get connection info
            if ssh -O check -o ControlPath="$socket" 2>&1 | grep -q "Master running"; then
                echo "      Status: Active"
            else
                echo "      Status: Stale (should be cleaned)"
            fi
        fi
    done

    if [ $count -eq 0 ]; then
        echo "No active connections"
    fi
}
