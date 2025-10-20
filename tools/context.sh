#!/bin/bash
# AXON Context Commands
# User-facing commands for managing contexts
# Part of AXON - reusable across products

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source context manager library
source "$MODULE_DIR/lib/context-manager.sh"

# ==============================================================================
# Command: axon context add
# ==============================================================================

cmd_context_add() {
    local name=""
    local config_file=""
    local description=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                echo "Usage: axon context add <name> [config_file]"
                echo ""
                echo "Add a new context for global project management."
                echo ""
                echo "Arguments:"
                echo "  name          Context name (alphanumeric, hyphens, underscores)"
                echo "  config_file   Path to axon.config.yml (default: ./axon.config.yml)"
                echo ""
                echo "Options:"
                echo "  -h, --help    Show this help message"
                echo ""
                echo "Examples:"
                echo "  axon context add my-app                      # Auto-detect config in CWD"
                echo "  axon context add my-app ~/path/to/config.yml # Explicit path"
                exit 0
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}"
                exit 1
                ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                elif [ -z "$config_file" ]; then
                    config_file="$1"
                else
                    echo -e "${RED}Error: Too many arguments${NC}"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate name provided
    if [ -z "$name" ]; then
        echo -e "${RED}Error: Context name required${NC}"
        echo "Usage: axon context add <name> [config_file]"
        exit 1
    fi

    # Validate name format
    if ! validate_context_name "$name"; then
        exit 1
    fi

    # Check if context already exists
    if context_exists "$name"; then
        echo -e "${RED}Error: Context '$name' already exists${NC}"
        echo ""
        echo "Options:"
        echo "  - Remove existing context: axon context remove $name"
        echo "  - Use different name: axon context add <different-name>"
        exit 1
    fi

    # Determine config file
    if [ -z "$config_file" ]; then
        # Auto-detect in CWD
        if [ -f "$PWD/axon.config.yml" ]; then
            config_file="$PWD/axon.config.yml"
        else
            echo -e "${RED}Error: No config file found in current directory${NC}"
            echo ""
            echo "Options:"
            echo "  - Create config: axon init-config"
            echo "  - Specify path: axon context add $name <config-file-path>"
            exit 1
        fi
    fi

    # Resolve to absolute path
    if [[ "$config_file" != /* ]]; then
        config_file="${PWD}/${config_file}"
    fi

    # Validate config file
    if ! validate_config_file "$config_file"; then
        exit 1
    fi

    # Set project root to directory containing config
    local project_root=$(dirname "$config_file")

    # Try to extract product name for description
    local product_name=$(yq eval '.product.name' "$config_file" 2>/dev/null || echo "")
    if [ -n "$product_name" ] && [ "$product_name" != "null" ]; then
        description="$product_name"
    fi

    # Save context
    echo -e "${BLUE}Adding context...${NC}"
    if save_context "$name" "$config_file" "$project_root" "$description"; then
        echo -e "${GREEN}✓ Context '$name' added successfully${NC}"
        echo ""
        echo -e "${CYAN}Context Details:${NC}"
        echo -e "  Name:         ${YELLOW}$name${NC}"
        echo -e "  Config:       ${YELLOW}$(shorten_path "$config_file")${NC}"
        echo -e "  Project Root: ${YELLOW}$(shorten_path "$project_root")${NC}"
        if [ -n "$product_name" ]; then
            echo -e "  Product:      ${YELLOW}$product_name${NC}"
        fi
        echo ""
        echo -e "${CYAN}Next Steps:${NC}"
        echo -e "  Switch to context: ${BLUE}axon context use $name${NC}"
        echo -e "  View all contexts: ${BLUE}axon context list${NC}"
    else
        echo -e "${RED}✗ Failed to add context${NC}"
        exit 1
    fi
}

# ==============================================================================
# Command: axon context use
# ==============================================================================

cmd_context_use() {
    local name=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                echo "Usage: axon context use <name>"
                echo ""
                echo "Switch to a different context (sets as active)."
                echo ""
                echo "Arguments:"
                echo "  name          Context name to switch to"
                echo ""
                echo "Options:"
                echo "  -h, --help    Show this help message"
                echo ""
                echo "Examples:"
                echo "  axon context use my-app"
                echo "  axon context use backend"
                exit 0
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}"
                exit 1
                ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                else
                    echo -e "${RED}Error: Too many arguments${NC}"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate name provided
    if [ -z "$name" ]; then
        echo -e "${RED}Error: Context name required${NC}"
        echo "Usage: axon context use <name>"
        exit 1
    fi

    # Check if context exists
    if ! context_exists "$name"; then
        echo -e "${RED}Error: Context '$name' does not exist${NC}"
        echo ""
        echo "Available contexts:"
        cmd_context_list
        exit 1
    fi

    # Validate context is still valid
    local config=$(get_context_field "$name" "config")
    local project_root=$(get_context_field "$name" "project_root")

    if [ ! -f "$config" ]; then
        echo -e "${RED}Error: Config file not found: $config${NC}"
        echo -e "${YELLOW}Context '$name' may be outdated${NC}"
        echo ""
        echo "Options:"
        echo "  - Remove context: axon context remove $name"
        echo "  - Update context: axon context add $name <new-config-path>"
        exit 1
    fi

    if [ ! -d "$project_root" ]; then
        echo -e "${RED}Error: Project root not found: $project_root${NC}"
        echo -e "${YELLOW}Context '$name' may be outdated${NC}"
        echo ""
        echo "Options:"
        echo "  - Remove context: axon context remove $name"
        echo "  - Update context: axon context add $name <new-config-path>"
        exit 1
    fi

    # Set as current context
    if set_current_context "$name"; then
        echo -e "${GREEN}✓ Switched to context '$name'${NC}"
        echo ""

        # Show context details
        local product=$(get_context_field "$name" "product_name")
        local registry=$(get_context_field "$name" "registry_provider")

        echo -e "${CYAN}Context Details:${NC}"
        echo -e "  Name:         ${YELLOW}$name${NC}"
        echo -e "  Config:       ${YELLOW}$(shorten_path "$config")${NC}"
        echo -e "  Project Root: ${YELLOW}$(shorten_path "$project_root")${NC}"
        if [ -n "$product" ] && [ "$product" != "null" ]; then
            echo -e "  Product:      ${YELLOW}$product${NC}"
        fi
        if [ -n "$registry" ] && [ "$registry" != "null" ]; then
            echo -e "  Registry:     ${YELLOW}$registry${NC}"
        fi
        echo ""
        echo -e "${CYAN}You can now run AXON commands from any directory.${NC}"
    else
        echo -e "${RED}✗ Failed to switch context${NC}"
        exit 1
    fi
}

# ==============================================================================
# Command: axon context list
# ==============================================================================

cmd_context_list() {
    echo -e "${CYAN}Available Contexts:${NC}"
    echo ""

    # Get list of contexts
    local contexts=$(list_contexts)

    if [ -z "$contexts" ]; then
        echo "No contexts found."
        echo ""
        echo "Create a context with: axon context add <name>"
        return 0
    fi

    # Print header
    printf "%-2s %-15s %-20s %-40s %-15s\n" "" "NAME" "PRODUCT" "PROJECT ROOT" "LAST USED"
    printf "%s\n" "--------------------------------------------------------------------------------"

    # Print each context
    echo "$contexts" | while IFS=$'\t' read -r marker name product project_root last_used; do
        # Shorten path
        project_root=$(shorten_path "$project_root")

        # Convert timestamp to relative
        local relative=$(timestamp_to_relative "$last_used")

        # Truncate long values
        if [ ${#product} -gt 20 ]; then
            product="${product:0:17}..."
        fi
        if [ ${#project_root} -gt 40 ]; then
            project_root="...${project_root: -37}"
        fi

        # Print row
        printf "%-2s %-15s %-20s %-40s %-15s\n" "$marker" "$name" "$product" "$project_root" "$relative"
    done

    echo ""
    echo "(* = currently active)"
    echo ""
    echo "Use 'axon context use <name>' to switch contexts"
}

# ==============================================================================
# Command: axon context current
# ==============================================================================

cmd_context_current() {
    local current=$(get_current_context)

    if [ -z "$current" ]; then
        echo "No context active (using local mode)"
        echo ""
        echo "Switch to a context with: axon context use <name>"
        return 0
    fi

    # Load context details
    local config=$(get_context_field "$current" "config")
    local project_root=$(get_context_field "$current" "project_root")
    local product=$(get_context_field "$current" "product_name")
    local registry=$(get_context_field "$current" "registry_provider")
    local last_used=$(get_context_field "$current" "last_used")

    echo -e "${CYAN}Current Context: ${YELLOW}$current${NC}"
    echo ""
    echo -e "${CYAN}Details:${NC}"
    echo -e "  Config:       ${YELLOW}$(shorten_path "$config")${NC}"
    echo -e "  Project Root: ${YELLOW}$(shorten_path "$project_root")${NC}"

    if [ -n "$product" ] && [ "$product" != "null" ]; then
        echo -e "  Product:      ${YELLOW}$product${NC}"
    fi

    if [ -n "$registry" ] && [ "$registry" != "null" ]; then
        echo -e "  Registry:     ${YELLOW}$registry${NC}"
    fi

    if [ -n "$last_used" ] && [ "$last_used" != "null" ]; then
        echo -e "  Last Used:    ${YELLOW}$(timestamp_to_relative "$last_used")${NC}"
    fi
}

# ==============================================================================
# Command: axon context remove
# ==============================================================================

cmd_context_remove() {
    local name=""
    local force=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force)
                force=true
                shift
                ;;
            -h|--help)
                echo "Usage: axon context remove <name> [--force]"
                echo ""
                echo "Remove a context."
                echo ""
                echo "Arguments:"
                echo "  name          Context name to remove"
                echo ""
                echo "Options:"
                echo "  -f, --force   Force removal without confirmation"
                echo "  -h, --help    Show this help message"
                echo ""
                echo "Examples:"
                echo "  axon context remove my-app"
                echo "  axon context remove my-app --force"
                exit 0
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}"
                exit 1
                ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                else
                    echo -e "${RED}Error: Too many arguments${NC}"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate name provided
    if [ -z "$name" ]; then
        echo -e "${RED}Error: Context name required${NC}"
        echo "Usage: axon context remove <name>"
        exit 1
    fi

    # Check if context exists
    if ! context_exists "$name"; then
        echo -e "${RED}Error: Context '$name' does not exist${NC}"
        exit 1
    fi

    # Check if it's the current context
    local current=$(get_current_context)
    local is_current=false
    if [ "$name" = "$current" ]; then
        is_current=true
    fi

    # Confirm removal unless --force
    if [ "$force" != true ]; then
        echo -e "${YELLOW}Remove context '$name'?${NC}"
        if [ "$is_current" = true ]; then
            echo -e "${YELLOW}(This is the currently active context)${NC}"
        fi
        echo ""
        read -p "Type 'yes' to confirm: " confirm
        if [ "$confirm" != "yes" ]; then
            echo "Cancelled."
            exit 0
        fi
    fi

    # Delete context
    if delete_context "$name"; then
        # If it was the current context, clear it
        if [ "$is_current" = true ]; then
            clear_current_context
        fi

        echo -e "${GREEN}✓ Context '$name' removed${NC}"

        if [ "$is_current" = true ]; then
            echo -e "${YELLOW}(Switched to local mode)${NC}"
        fi
    else
        echo -e "${RED}✗ Failed to remove context${NC}"
        exit 1
    fi
}

# ==============================================================================
# Command Dispatcher
# ==============================================================================

handle_context_command() {
    local subcommand=""

    # Parse subcommand
    if [ $# -gt 0 ]; then
        subcommand="$1"
        shift
    fi

    # Dispatch to appropriate command
    case "$subcommand" in
        add)
            cmd_context_add "$@"
            ;;
        use)
            cmd_context_use "$@"
            ;;
        list|ls)
            cmd_context_list "$@"
            ;;
        current)
            cmd_context_current "$@"
            ;;
        remove|rm)
            cmd_context_remove "$@"
            ;;
        -h|--help|"")
            echo "Usage: axon context <command> [options]"
            echo ""
            echo "Manage AXON contexts for global project access."
            echo ""
            echo "Commands:"
            echo "  add <name> [config]    Add a new context"
            echo "  use <name>             Switch to a context"
            echo "  list                   List all contexts"
            echo "  current                Show current context"
            echo "  remove <name>          Remove a context"
            echo ""
            echo "Options:"
            echo "  -h, --help             Show this help message"
            echo ""
            echo "Examples:"
            echo "  axon context add my-app"
            echo "  axon context use my-app"
            echo "  axon context list"
            echo "  axon context remove my-app"
            ;;
        *)
            echo -e "${RED}Error: Unknown context command: $subcommand${NC}"
            echo "Use 'axon context --help' for usage information"
            exit 1
            ;;
    esac
}

# If script is run directly (not sourced), handle command
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    handle_context_command "$@"
fi
