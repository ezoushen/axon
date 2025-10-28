#!/bin/bash
# AXON - Context Manager Library
# Copyright (C) 2024-2025 ezoushen
# Licensed under GPL-3.0 - See LICENSE file for details
#
# Handles global context storage and operations

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Context storage paths
AXON_HOME="${HOME}/.axon"
AXON_CONFIG="${AXON_HOME}/config"
CONTEXTS_DIR="${AXON_HOME}/contexts"

# ==============================================================================
# Storage Initialization
# ==============================================================================

# Initialize context storage structure
# Creates ~/.axon/ directory structure and default config if needed
init_context_storage() {
    # Create directories
    mkdir -p "$CONTEXTS_DIR"

    # Create default global config if it doesn't exist
    if [ ! -f "$AXON_CONFIG" ]; then
        cat > "$AXON_CONFIG" <<EOF
# AXON Global Configuration
# This file is managed by AXON

# Version for future migration compatibility
version: 1

# Currently active context (empty = use local)
current_context: ""

# Global settings
settings:
  auto_validate: true
  verbose_by_default: false
EOF
    fi
}

# ==============================================================================
# Context CRUD Operations
# ==============================================================================

# Check if a context exists
# Args: context_name
# Returns: 0 if exists, 1 if not
context_exists() {
    local name=$1
    [ -f "$CONTEXTS_DIR/${name}.yml" ]
}

# Get path to context file
# Args: context_name
# Returns: absolute path to context YAML file
get_context_file() {
    local name=$1
    echo "$CONTEXTS_DIR/${name}.yml"
}

# Load context by name
# Args: context_name
# Returns: prints context data (multi-line output)
# Exit: 1 if context doesn't exist or is invalid
load_context() {
    local name=$1
    local context_file=$(get_context_file "$name")

    if [ ! -f "$context_file" ]; then
        echo "Error: Context '$name' does not exist" >&2
        return 1
    fi

    # Check if yq is available
    if ! command -v yq >/dev/null 2>&1; then
        echo "Error: yq is required but not installed" >&2
        return 1
    fi

    # Read entire context file
    cat "$context_file"
}

# Get specific field from context
# Args: context_name field_path
# Example: get_context_field "my-app" ".config"
get_context_field() {
    local name=$1
    local field=$2
    local context_file=$(get_context_file "$name")

    if [ ! -f "$context_file" ]; then
        echo "Error: Context '$name' does not exist" >&2
        return 1
    fi

    # Ensure field has leading dot for yq v4
    if [[ "$field" != .* ]]; then
        field=".$field"
    fi

    yq eval "$field" "$context_file" 2>/dev/null
}

# Save or update context
# Args: name config_path project_root [description]
save_context() {
    local name=$1
    local config_path=$2
    local project_root=$3
    local description=${4:-""}
    local context_file=$(get_context_file "$name")

    # Get current timestamp in ISO 8601 format
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # If context exists, preserve created timestamp
    local created="$timestamp"
    if [ -f "$context_file" ]; then
        created=$(yq eval '.created' "$context_file" 2>/dev/null || echo "$timestamp")
    fi

    # Try to extract product info from config for display (optional, non-fatal if fails)
    local product_name=""
    local registry_provider=""
    if [ -f "$config_path" ]; then
        product_name=$(yq eval '.product.name' "$config_path" 2>/dev/null || echo "")
        registry_provider=$(yq eval '.registry.provider' "$config_path" 2>/dev/null || echo "")
    fi

    # Create context file
    cat > "$context_file" <<EOF
# AXON Context: $name
# Created: $created
# Last Updated: $timestamp

name: $name
description: "$description"
created: "$created"
last_used: "$timestamp"

# Required: Where is the config file?
config: $config_path

# Required: What is the project root? (for Dockerfile, .git, etc.)
project_root: $project_root

# Optional: Cached product info (for display, refreshed on use)
product_name: $product_name
registry_provider: $registry_provider
EOF

    if [ $? -eq 0 ]; then
        return 0
    else
        echo "Error: Failed to save context" >&2
        return 1
    fi
}

# Update last_used timestamp for context
# Args: context_name
update_context_last_used() {
    local name=$1
    local context_file=$(get_context_file "$name")

    if [ ! -f "$context_file" ]; then
        return 1
    fi

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Use yq to update just the last_used field
    yq eval ".last_used = \"$timestamp\"" -i "$context_file" 2>/dev/null
}

# Delete context
# Args: context_name
delete_context() {
    local name=$1
    local context_file=$(get_context_file "$name")

    if [ ! -f "$context_file" ]; then
        echo "Error: Context '$name' does not exist" >&2
        return 1
    fi

    rm -f "$context_file"

    if [ $? -eq 0 ]; then
        return 0
    else
        echo "Error: Failed to delete context" >&2
        return 1
    fi
}

# List all contexts with metadata
# Returns: tab-separated lines of context data
# Format: name\tproduct\tproject_root\tlast_used
list_contexts() {
    init_context_storage

    # Find all context files
    local context_files=("$CONTEXTS_DIR"/*.yml)

    # Check if any contexts exist
    if [ ! -f "${context_files[0]}" ]; then
        return 0  # No contexts, but not an error
    fi

    # Get current context for marking
    local current=$(get_current_context)

    # Process each context file
    for context_file in "${context_files[@]}"; do
        if [ -f "$context_file" ]; then
            local name=$(yq eval '.name' "$context_file" 2>/dev/null || echo "unknown")
            local product=$(yq eval '.product_name' "$context_file" 2>/dev/null || echo "")
            local project_root=$(yq eval '.project_root' "$context_file" 2>/dev/null || echo "")
            local last_used=$(yq eval '.last_used' "$context_file" 2>/dev/null || echo "")

            # Mark current context (use space instead of empty to avoid IFS read issues)
            local marker=" "
            if [ "$name" = "$current" ]; then
                marker="*"
            fi

            # Use printf with consistent field output
            printf '%s\t%s\t%s\t%s\t%s\n' "$marker" "$name" "$product" "$project_root" "$last_used"
        fi
    done
}

# ==============================================================================
# Active Context Management
# ==============================================================================

# Get currently active context name
# Returns: context name or empty string if none
get_current_context() {
    init_context_storage

    if [ ! -f "$AXON_CONFIG" ]; then
        echo ""
        return
    fi

    local current=$(yq eval '.current_context' "$AXON_CONFIG" 2>/dev/null || echo "")

    # Return empty string if it's null or literally empty
    if [ "$current" = "null" ] || [ -z "$current" ]; then
        echo ""
    else
        echo "$current"
    fi
}

# Set active context
# Args: context_name
set_current_context() {
    local name=$1
    init_context_storage

    # Verify context exists
    if ! context_exists "$name"; then
        echo "Error: Context '$name' does not exist" >&2
        return 1
    fi

    # Update config file
    yq eval ".current_context = \"$name\"" -i "$AXON_CONFIG" 2>/dev/null

    if [ $? -eq 0 ]; then
        # Update last_used timestamp
        update_context_last_used "$name"
        return 0
    else
        echo "Error: Failed to set current context" >&2
        return 1
    fi
}

# Clear active context (switch to local mode)
clear_current_context() {
    init_context_storage

    yq eval '.current_context = ""' -i "$AXON_CONFIG" 2>/dev/null

    if [ $? -ne 0 ]; then
        echo "Error: Failed to clear current context" >&2
        return 1
    fi
}

# ==============================================================================
# Context Resolution
# ==============================================================================

# Resolve which config file and project root to use
# Returns: Multi-line output with:
#   mode: explicit|local|context|error
#   config: /absolute/path/to/config.yml
#   project_root: /absolute/path/to/project
#   context: context_name (only if mode=context)
resolve_config() {
    local explicit_config=$1  # From -c flag (optional)
    local context_override=$2 # From --context flag (optional)

    # 1. Explicit -c flag (highest priority)
    if [ -n "$explicit_config" ]; then
        # Make absolute path
        if [[ "$explicit_config" != /* ]]; then
            explicit_config="${PWD}/${explicit_config}"
        fi

        echo "mode: explicit"
        echo "config: $explicit_config"
        echo "project_root: $(dirname "$explicit_config")"
        return 0
    fi

    # 2. Context override --context flag (one-off override)
    if [ -n "$context_override" ]; then
        if ! context_exists "$context_override"; then
            echo "mode: error"
            echo "error: Context '$context_override' does not exist"
            return 1
        fi

        local config=$(get_context_field "$context_override" "config")
        local project_root=$(get_context_field "$context_override" "project_root")

        # Validate config exists
        if [ ! -f "$config" ]; then
            echo "mode: error"
            echo "error: Config file not found: $config"
            echo "hint: Context '$context_override' may be outdated"
            return 1
        fi

        # Validate project root exists
        if [ ! -d "$project_root" ]; then
            echo "mode: error"
            echo "error: Project root not found: $project_root"
            echo "hint: Context '$context_override' may be outdated"
            return 1
        fi

        echo "mode: context"
        echo "config: $config"
        echo "project_root: $project_root"
        echo "context: $context_override"
        return 0
    fi

    # 3. Local axon.config.yml in CWD
    if [ -f "$PWD/axon.config.yml" ]; then
        echo "mode: local"
        echo "config: $PWD/axon.config.yml"
        echo "project_root: $PWD"
        return 0
    fi

    # 4. Active context
    local current=$(get_current_context)
    if [ -n "$current" ]; then
        if ! context_exists "$current"; then
            echo "mode: error"
            echo "error: Context '$current' is set but does not exist"
            return 1
        fi

        local config=$(get_context_field "$current" "config")
        local project_root=$(get_context_field "$current" "project_root")

        # Validate config exists
        if [ ! -f "$config" ]; then
            echo "mode: error"
            echo "error: Config file not found: $config"
            echo "hint: Context '$current' may be outdated"
            return 1
        fi

        # Validate project root exists
        if [ ! -d "$project_root" ]; then
            echo "mode: error"
            echo "error: Project root not found: $project_root"
            echo "hint: Context '$current' may be outdated"
            return 1
        fi

        echo "mode: context"
        echo "config: $config"
        echo "project_root: $project_root"
        echo "context: $current"
        return 0
    fi

    # 5. Nothing found - error
    echo "mode: error"
    echo "error: No config file found and no active context"
    return 1
}

# ==============================================================================
# Validation
# ==============================================================================

# Validate context name
# Args: context_name
# Returns: 0 if valid, 1 if invalid
validate_context_name() {
    local name=$1

    # Check if empty
    if [ -z "$name" ]; then
        echo "Error: Context name cannot be empty" >&2
        return 1
    fi

    # Check format: alphanumeric, hyphens, underscores only
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        echo "Error: Context name must contain only letters, numbers, hyphens, and underscores" >&2
        echo "Invalid name: $name" >&2
        return 1
    fi

    return 0
}

# Validate config file
# Args: config_file_path
# Returns: 0 if valid, 1 if invalid
validate_config_file() {
    local config_file=$1

    # Check if file exists
    if [ ! -f "$config_file" ]; then
        echo "Error: Config file not found: $config_file" >&2
        return 1
    fi

    # Check if file is readable
    if [ ! -r "$config_file" ]; then
        echo "Error: Config file not readable: $config_file" >&2
        return 1
    fi

    # Check if valid YAML (yq can parse it)
    if ! yq eval '.' "$config_file" >/dev/null 2>&1; then
        echo "Error: Config file is not valid YAML: $config_file" >&2
        return 1
    fi

    # Check for required fields
    local product_name=$(yq eval '.product.name' "$config_file" 2>/dev/null || echo "")
    if [ -z "$product_name" ] || [ "$product_name" = "null" ]; then
        echo "Error: Config file missing required field: product.name" >&2
        return 1
    fi

    return 0
}

# ==============================================================================
# Utility Functions
# ==============================================================================

# Convert timestamp to relative time
# Args: ISO 8601 timestamp
# Returns: human-readable relative time
timestamp_to_relative() {
    local timestamp=$1

    # If empty or null, return "never"
    if [ -z "$timestamp" ] || [ "$timestamp" = "null" ]; then
        echo "never"
        return
    fi

    # Convert ISO 8601 to Unix timestamp (platform-agnostic approach)
    # This is a simplified version - may not work for all timestamp formats
    local now=$(date +%s)
    local then=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || echo "$now")

    local diff=$((now - then))

    # Calculate relative time
    if [ $diff -lt 60 ]; then
        echo "just now"
    elif [ $diff -lt 3600 ]; then
        local minutes=$((diff / 60))
        if [ $minutes -eq 1 ]; then
            echo "1 minute ago"
        else
            echo "$minutes minutes ago"
        fi
    elif [ $diff -lt 86400 ]; then
        local hours=$((diff / 3600))
        if [ $hours -eq 1 ]; then
            echo "1 hour ago"
        else
            echo "$hours hours ago"
        fi
    elif [ $diff -lt 2592000 ]; then
        local days=$((diff / 86400))
        if [ $days -eq 1 ]; then
            echo "yesterday"
        else
            echo "$days days ago"
        fi
    else
        local months=$((diff / 2592000))
        if [ $months -eq 1 ]; then
            echo "1 month ago"
        else
            echo "$months months ago"
        fi
    fi
}

# Shorten home directory in path
# Args: absolute_path
# Returns: path with ~ instead of $HOME
shorten_path() {
    local path=$1
    echo "$path" | sed "s|^$HOME|~|"
}
