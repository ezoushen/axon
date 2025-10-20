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
# Command: axon context show
# ==============================================================================

cmd_context_show() {
    local name=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                echo "Usage: axon context show <name>"
                echo ""
                echo "Show detailed information about a context."
                echo ""
                echo "Arguments:"
                echo "  name          Context name to show"
                echo ""
                echo "Options:"
                echo "  -h, --help    Show this help message"
                echo ""
                echo "Examples:"
                echo "  axon context show my-app"
                echo "  axon context show backend"
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
        echo "Usage: axon context show <name>"
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

    # Load context details
    local config=$(get_context_field "$name" "config")
    local project_root=$(get_context_field "$name" "project_root")
    local product=$(get_context_field "$name" "product_name")
    local registry=$(get_context_field "$name" "registry_provider")
    local description=$(get_context_field "$name" "description")
    local created=$(get_context_field "$name" "created")
    local last_used=$(get_context_field "$name" "last_used")

    # Check status
    local status_msg=""
    local status_color=""
    if [ ! -f "$config" ]; then
        status_msg="✗ Invalid (config file not found)"
        status_color="$RED"
    elif [ ! -d "$project_root" ]; then
        status_msg="✗ Invalid (project root not found)"
        status_color="$RED"
    else
        status_msg="✓ Valid (config exists and is readable)"
        status_color="$GREEN"
    fi

    # Parse additional config info if available
    local environments=""
    local system_server=""
    local app_server=""
    if [ -f "$config" ]; then
        # Get environments
        local env_list=$(yq eval '.environments | keys | .[]' "$config" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
        if [ -n "$env_list" ] && [ "$env_list" != "null" ]; then
            environments="$env_list"
        fi

        # Get servers
        local sys_user=$(yq eval '.servers.system.user' "$config" 2>/dev/null)
        local sys_host=$(yq eval '.servers.system.host' "$config" 2>/dev/null)
        if [ -n "$sys_user" ] && [ "$sys_user" != "null" ] && [ -n "$sys_host" ] && [ "$sys_host" != "null" ]; then
            system_server="${sys_user}@${sys_host}"
        fi

        local app_user=$(yq eval '.servers.application.user' "$config" 2>/dev/null)
        local app_host=$(yq eval '.servers.application.host' "$config" 2>/dev/null)
        if [ -n "$app_user" ] && [ "$app_user" != "null" ] && [ -n "$app_host" ] && [ "$app_host" != "null" ]; then
            app_server="${app_user}@${app_host}"
        fi

        # Update registry info from fresh config read
        registry=$(yq eval '.registry.provider' "$config" 2>/dev/null)

        # Get registry URL based on provider
        local registry_url=""
        case "$registry" in
            aws_ecr)
                local account=$(yq eval '.registry.aws_ecr.account_id' "$config" 2>/dev/null)
                local region=$(yq eval '.registry.aws_ecr.region' "$config" 2>/dev/null)
                if [ -n "$account" ] && [ "$account" != "null" ] && [ -n "$region" ] && [ "$region" != "null" ]; then
                    registry_url="${account}.dkr.ecr.${region}.amazonaws.com"
                fi
                ;;
            google_gcr)
                local project=$(yq eval '.registry.google_gcr.project_id' "$config" 2>/dev/null)
                if [ -n "$project" ] && [ "$project" != "null" ]; then
                    registry_url="gcr.io/${project}"
                fi
                ;;
            azure_acr)
                local reg_name=$(yq eval '.registry.azure_acr.registry_name' "$config" 2>/dev/null)
                if [ -n "$reg_name" ] && [ "$reg_name" != "null" ]; then
                    registry_url="${reg_name}.azurecr.io"
                fi
                ;;
            docker_hub)
                local namespace=$(yq eval '.registry.docker_hub.namespace' "$config" 2>/dev/null)
                if [ -z "$namespace" ] || [ "$namespace" = "null" ]; then
                    namespace=$(yq eval '.registry.docker_hub.username' "$config" 2>/dev/null)
                fi
                if [ -n "$namespace" ] && [ "$namespace" != "null" ]; then
                    registry_url="docker.io/${namespace}"
                fi
                ;;
        esac
    fi

    # Display context information
    echo -e "${CYAN}Context: ${YELLOW}$name${NC}"
    echo -e "${CYAN}─────────────────────────────${NC}"
    echo ""
    echo -e "${CYAN}Basic Information:${NC}"
    echo -e "  Config:       ${YELLOW}$(shorten_path "$config")${NC}"
    echo -e "  Project Root: ${YELLOW}$(shorten_path "$project_root")${NC}"

    if [ -n "$description" ] && [ "$description" != "null" ] && [ -n "$description" ]; then
        echo -e "  Description:  ${YELLOW}$description${NC}"
    fi

    if [ -n "$product" ] && [ "$product" != "null" ]; then
        echo -e "  Product:      ${YELLOW}$product${NC}"
    fi

    if [ -n "$registry" ] && [ "$registry" != "null" ]; then
        echo -e "  Registry:     ${YELLOW}$registry${NC}"
        if [ -n "$registry_url" ]; then
            echo -e "                ${YELLOW}($registry_url)${NC}"
        fi
    fi

    if [ -n "$environments" ]; then
        echo ""
        echo -e "${CYAN}Environments:${NC}"
        echo -e "  ${YELLOW}$environments${NC}"
    fi

    if [ -n "$system_server" ] || [ -n "$app_server" ]; then
        echo ""
        echo -e "${CYAN}Servers:${NC}"
        if [ -n "$system_server" ]; then
            echo -e "  System:       ${YELLOW}$system_server${NC}"
        fi
        if [ -n "$app_server" ]; then
            echo -e "  Application:  ${YELLOW}$app_server${NC}"
        fi
    fi

    echo ""
    echo -e "${CYAN}Timestamps:${NC}"
    if [ -n "$created" ] && [ "$created" != "null" ]; then
        echo -e "  Created:      ${YELLOW}$created${NC}"
    fi
    if [ -n "$last_used" ] && [ "$last_used" != "null" ]; then
        echo -e "  Last Used:    ${YELLOW}$(timestamp_to_relative "$last_used") ($last_used)${NC}"
    fi

    echo ""
    echo -e "${CYAN}Status:${NC}"
    echo -e "  ${status_color}${status_msg}${NC}"
}

# ==============================================================================
# Command: axon context validate
# ==============================================================================

cmd_context_validate() {
    local name=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                echo "Usage: axon context validate <name>"
                echo ""
                echo "Validate a context's configuration."
                echo ""
                echo "Arguments:"
                echo "  name          Context name to validate"
                echo ""
                echo "Options:"
                echo "  -h, --help    Show this help message"
                echo ""
                echo "Examples:"
                echo "  axon context validate my-app"
                echo "  axon context validate backend"
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
        echo "Usage: axon context validate <name>"
        exit 1
    fi

    # Check if context exists
    if ! context_exists "$name"; then
        echo -e "${RED}Error: Context '$name' does not exist${NC}"
        exit 1
    fi

    echo -e "${CYAN}Validating context: ${YELLOW}$name${NC}"
    echo ""

    local errors=0
    local warnings=0

    # Load context
    local config=$(get_context_field "$name" "config")
    local project_root=$(get_context_field "$name" "project_root")

    # Check 1: Context file exists
    if [ -f "$(get_context_file "$name")" ]; then
        echo -e "${GREEN}✓ Context file exists${NC}"
    else
        echo -e "${RED}✗ Context file missing${NC}"
        errors=$((errors + 1))
    fi

    # Check 2: Config file exists
    if [ -f "$config" ]; then
        echo -e "${GREEN}✓ Config file exists: $(basename "$config")${NC}"
    else
        echo -e "${RED}✗ Config file not found: $config${NC}"
        errors=$((errors + 1))
        echo ""
        echo -e "${RED}Validation: Failed ($errors errors, $warnings warnings)${NC}"
        exit 1
    fi

    # Check 3: Config is valid YAML
    if yq eval '.' "$config" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Config is valid YAML${NC}"
    else
        echo -e "${RED}✗ Config is not valid YAML${NC}"
        errors=$((errors + 1))
        echo ""
        echo -e "${RED}Validation: Failed ($errors errors, $warnings warnings)${NC}"
        exit 1
    fi

    # Check 4: Required fields present
    local product_name=$(yq eval '.product.name' "$config" 2>/dev/null)
    local registry_provider=$(yq eval '.registry.provider' "$config" 2>/dev/null)

    if [ -n "$product_name" ] && [ "$product_name" != "null" ]; then
        echo -e "${GREEN}✓ Required field present: product.name${NC}"
    else
        echo -e "${RED}✗ Missing required field: product.name${NC}"
        errors=$((errors + 1))
    fi

    if [ -n "$registry_provider" ] && [ "$registry_provider" != "null" ]; then
        echo -e "${GREEN}✓ Required field present: registry.provider${NC}"
    else
        echo -e "${RED}✗ Missing required field: registry.provider${NC}"
        errors=$((errors + 1))
    fi

    # Check 5: Project root exists
    if [ -d "$project_root" ]; then
        echo -e "${GREEN}✓ Project root exists${NC}"
    else
        echo -e "${RED}✗ Project root not found: $project_root${NC}"
        errors=$((errors + 1))
    fi

    # Check 6: SSH keys exist
    local sys_key=$(yq eval '.servers.system.ssh_key' "$config" 2>/dev/null)
    local app_key=$(yq eval '.servers.application.ssh_key' "$config" 2>/dev/null)

    if [ -n "$sys_key" ] && [ "$sys_key" != "null" ]; then
        sys_key="${sys_key/#\~/$HOME}"
        if [ -f "$sys_key" ]; then
            echo -e "${GREEN}✓ System Server SSH key exists${NC}"
        else
            echo -e "${RED}✗ System Server SSH key not found: $sys_key${NC}"
            errors=$((errors + 1))
        fi
    fi

    if [ -n "$app_key" ] && [ "$app_key" != "null" ]; then
        app_key="${app_key/#\~/$HOME}"
        if [ -f "$app_key" ]; then
            echo -e "${GREEN}✓ Application Server SSH key exists${NC}"
        else
            echo -e "${RED}✗ Application Server SSH key not found: $app_key${NC}"
            errors=$((errors + 1))
        fi
    fi

    # Check 7: Dockerfile exists (warning only)
    local dockerfile=$(yq eval '.docker.dockerfile' "$config" 2>/dev/null)
    if [ -z "$dockerfile" ] || [ "$dockerfile" = "null" ]; then
        dockerfile="Dockerfile"
    fi

    if [ -f "${project_root}/${dockerfile}" ]; then
        echo -e "${GREEN}✓ Dockerfile exists in project root${NC}"
    else
        echo -e "${YELLOW}⚠ Warning: Dockerfile not found: ${project_root}/${dockerfile}${NC}"
        warnings=$((warnings + 1))
    fi

    # Summary
    echo ""
    if [ $errors -eq 0 ]; then
        if [ $warnings -eq 0 ]; then
            echo -e "${GREEN}Validation: Passed${NC}"
        else
            echo -e "${YELLOW}Validation: Passed with $warnings warning(s)${NC}"
        fi
        exit 0
    else
        echo -e "${RED}Validation: Failed ($errors error(s), $warnings warning(s))${NC}"
        exit 1
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
# Command: axon context export
# ==============================================================================

cmd_context_export() {
    local name=""
    local output_file=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -o|--output)
                output_file="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: axon context export <name> [-o output_file]"
                echo ""
                echo "Export a context to a YAML file for sharing or backup."
                echo ""
                echo "Arguments:"
                echo "  name                 Context name to export"
                echo ""
                echo "Options:"
                echo "  -o, --output FILE    Output file (default: <name>-context.yml)"
                echo "  -h, --help           Show this help message"
                echo ""
                echo "Examples:"
                echo "  axon context export my-app"
                echo "  axon context export my-app -o backup.yml"
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
        echo "Usage: axon context export <name> [-o output_file]"
        exit 1
    fi

    # Check if context exists
    if ! context_exists "$name"; then
        echo -e "${RED}Error: Context '$name' does not exist${NC}"
        exit 1
    fi

    # Determine output file
    if [ -z "$output_file" ]; then
        output_file="${name}-context.yml"
    fi

    # Load context
    local context_file=$(get_context_file "$name")
    local config=$(get_context_field "$name" "config")
    local project_root=$(get_context_field "$name" "project_root")
    local description=$(get_context_field "$name" "description")

    # Make paths relative to home for portability
    local config_portable="${config/#$HOME/~}"
    local project_root_portable="${project_root/#$HOME/~}"

    # Create export file
    cat > "$output_file" <<EOF
# AXON Context Export: $name
# Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# This file can be imported on another machine using:
#   axon context import $output_file --name <new-name> --root <project-root>

name: $name
description: "$description"

# Paths (may need adjustment on import)
config: $config_portable
project_root: $project_root_portable
EOF

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Context '$name' exported to: $output_file${NC}"
        echo ""
        echo "To import on another machine:"
        echo "  axon context import $output_file --name <new-name> --root <new-root>"
    else
        echo -e "${RED}Error: Failed to export context${NC}"
        exit 1
    fi
}

# ==============================================================================
# Command: axon context import
# ==============================================================================

cmd_context_import() {
    local import_file=""
    local new_name=""
    local new_root=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                new_name="$2"
                shift 2
                ;;
            --root)
                new_root="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: axon context import <file> --name <name> [--root <project_root>]"
                echo ""
                echo "Import a context from an exported YAML file."
                echo ""
                echo "Arguments:"
                echo "  file                  Exported context file"
                echo ""
                echo "Options:"
                echo "  --name NAME           Name for the imported context (required)"
                echo "  --root PATH           Project root path (default: auto-detect)"
                echo "  -h, --help            Show this help message"
                echo ""
                echo "Examples:"
                echo "  axon context import my-app-context.yml --name my-app"
                echo "  axon context import backup.yml --name my-app --root ~/projects/my-app"
                exit 0
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}"
                exit 1
                ;;
            *)
                if [ -z "$import_file" ]; then
                    import_file="$1"
                else
                    echo -e "${RED}Error: Too many arguments${NC}"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate import file provided
    if [ -z "$import_file" ]; then
        echo -e "${RED}Error: Import file required${NC}"
        echo "Usage: axon context import <file> --name <name> [--root <project_root>]"
        exit 1
    fi

    # Check if import file exists
    if [ ! -f "$import_file" ]; then
        echo -e "${RED}Error: Import file not found: $import_file${NC}"
        exit 1
    fi

    # Validate name provided
    if [ -z "$new_name" ]; then
        echo -e "${RED}Error: --name is required${NC}"
        echo "Usage: axon context import <file> --name <name> [--root <project_root>]"
        exit 1
    fi

    # Validate name format
    if ! validate_context_name "$new_name"; then
        exit 1
    fi

    # Check if context already exists
    if context_exists "$new_name"; then
        echo -e "${RED}Error: Context '$new_name' already exists${NC}"
        exit 1
    fi

    # Read from import file
    local imported_config=$(yq eval '.config' "$import_file" 2>/dev/null)
    local imported_root=$(yq eval '.project_root' "$import_file" 2>/dev/null)
    local imported_desc=$(yq eval '.description' "$import_file" 2>/dev/null)

    # Expand ~ to $HOME
    imported_config="${imported_config/#\~/$HOME}"
    imported_root="${imported_root/#\~/$HOME}"

    # Use provided root or imported root
    local final_root="${new_root:-$imported_root}"

    # Validate project root exists
    if [ ! -d "$final_root" ]; then
        echo -e "${RED}Error: Project root not found: $final_root${NC}"
        echo ""
        echo "Please provide a valid project root using --root flag"
        exit 1
    fi

    # Determine config file path
    local final_config=""
    if [ -f "${final_root}/axon.config.yml" ]; then
        final_config="${final_root}/axon.config.yml"
    else
        echo -e "${RED}Error: Config file not found in project root: ${final_root}/axon.config.yml${NC}"
        exit 1
    fi

    # Validate config file
    if ! validate_config_file "$final_config"; then
        exit 1
    fi

    # Create context
    if save_context "$new_name" "$final_config" "$final_root" "$imported_desc"; then
        echo -e "${GREEN}Context '$new_name' imported successfully${NC}"
        echo ""
        echo "Details:"
        echo "  Config:       $final_config"
        echo "  Project Root: $final_root"
        echo ""
        echo "Switch to this context:"
        echo "  axon context use $new_name"
    else
        echo -e "${RED}Error: Failed to import context${NC}"
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
        show)
            cmd_context_show "$@"
            ;;
        validate)
            cmd_context_validate "$@"
            ;;
        export)
            cmd_context_export "$@"
            ;;
        import)
            cmd_context_import "$@"
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
            echo "  show <name>            Show detailed context information"
            echo "  validate <name>        Validate a context configuration"
            echo "  export <name>          Export context to file"
            echo "  import <file>          Import context from file"
            echo "  remove <name>          Remove a context"
            echo ""
            echo "Options:"
            echo "  -h, --help             Show this help message"
            echo ""
            echo "Examples:"
            echo "  axon context add my-app"
            echo "  axon context use my-app"
            echo "  axon context list"
            echo "  axon context show my-app"
            echo "  axon context validate my-app"
            echo "  axon context export my-app"
            echo "  axon context import my-app-context.yml --name my-app"
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
