#!/bin/bash
# AXON Env Command Handler
# Handles environment file management

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

show_env_help() {
    cat <<EOF
Usage: axon env <subcommand> [environment] [options]

Manage environment files (.env files) on Application Server.

SUBCOMMANDS:
  edit <environment>       Edit environment file for specified environment

OPTIONS:
  -c, --config FILE        Config file (default: axon.config.yml)
  --editor EDITOR          Editor to use (default: \$EDITOR or vim)
  -h, --help               Show this help message

EXAMPLES:
  axon env edit production
  axon env edit staging --editor nano
  axon env edit production -c custom.yml

NOTES:
  - Edits .env file directly on Application Server via SSH
  - Uses \$EDITOR environment variable, falls back to \$VISUAL, then vim
  - Requires SSH access to Application Server configured in axon.config.yml
  - Environment must be defined in config file with env_path set

EOF
}

handle_env_command() {
    # Check if subcommand is provided
    if [ $# -eq 0 ]; then
        echo -e "${RED}Error: No subcommand provided${NC}"
        echo ""
        show_env_help
        exit 1
    fi

    local subcommand="$1"
    shift

    case "$subcommand" in
        edit)
            handle_env_edit "$@"
            ;;
        -h|--help)
            show_env_help
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown subcommand: ${subcommand}${NC}"
            echo ""
            show_env_help
            exit 1
            ;;
    esac
}

handle_env_edit() {
    # Inherit CONFIG_FILE from parent if set
    if [ -z "$CONFIG_FILE" ]; then
        CONFIG_FILE="axon.config.yml"
    fi

    local ENVIRONMENT=""
    local EDITOR_OVERRIDE=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --editor)
                EDITOR_OVERRIDE="$2"
                shift 2
                ;;
            -h|--help)
                show_env_help
                exit 0
                ;;
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}"
                show_env_help
                exit 1
                ;;
            *)
                if [ -z "$ENVIRONMENT" ]; then
                    ENVIRONMENT="$1"
                    shift
                else
                    echo -e "${RED}Error: Unexpected argument: $1${NC}"
                    show_env_help
                    exit 1
                fi
                ;;
        esac
    done

    # Validate environment parameter
    if [ -z "$ENVIRONMENT" ]; then
        echo -e "${RED}Error: Environment not specified${NC}"
        echo ""
        echo "Usage: axon env edit <environment> [options]"
        echo ""
        echo "Example:"
        echo "  axon env edit production"
        echo "  axon env edit staging --editor nano"
        exit 1
    fi

    # Check config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
        exit 1
    fi

    echo -e "${BLUE}Environment File Editor${NC}"
    echo -e "${BLUE}======================${NC}"
    echo ""

    # Load configuration using yq
    if ! command -v yq &> /dev/null; then
        echo -e "${RED}Error: yq is required but not installed${NC}"
        echo "Install: brew install yq (macOS) or see https://github.com/mikefarah/yq#install"
        exit 1
    fi

    # Check if environment exists in config
    if ! yq eval ".environments.${ENVIRONMENT}" "$CONFIG_FILE" | grep -v "^null$" &> /dev/null; then
        echo -e "${RED}Error: Environment '${ENVIRONMENT}' not found in ${CONFIG_FILE}${NC}"
        echo ""
        echo "Available environments:"
        yq eval '.environments | keys | .[]' "$CONFIG_FILE" 2>/dev/null || echo "  (none defined)"
        exit 1
    fi

    # Get env_path for environment
    ENV_PATH=$(yq eval ".environments.${ENVIRONMENT}.env_path" "$CONFIG_FILE" 2>/dev/null)

    if [ -z "$ENV_PATH" ] || [ "$ENV_PATH" = "null" ]; then
        echo -e "${RED}Error: env_path not configured for environment '${ENVIRONMENT}'${NC}"
        echo ""
        echo "Add env_path to your configuration:"
        echo ""
        echo "environments:"
        echo "  ${ENVIRONMENT}:"
        echo "    env_path: \"/path/to/.env.${ENVIRONMENT}\""
        exit 1
    fi

    # Get Application Server configuration
    APP_HOST=$(yq eval '.servers.application.host' "$CONFIG_FILE" 2>/dev/null)
    APP_USER=$(yq eval '.servers.application.user' "$CONFIG_FILE" 2>/dev/null)
    APP_SSH_KEY=$(yq eval '.servers.application.ssh_key' "$CONFIG_FILE" 2>/dev/null)

    # Validate Application Server config
    if [ -z "$APP_HOST" ] || [ "$APP_HOST" = "null" ]; then
        echo -e "${RED}Error: Application Server host not configured${NC}"
        exit 1
    fi

    if [ -z "$APP_USER" ] || [ "$APP_USER" = "null" ]; then
        echo -e "${RED}Error: Application Server user not configured${NC}"
        exit 1
    fi

    # Expand tilde in SSH key path
    if [ -n "$APP_SSH_KEY" ] && [ "$APP_SSH_KEY" != "null" ]; then
        APP_SSH_KEY="${APP_SSH_KEY/#\~/$HOME}"
    fi

    # Determine editor to use
    local EDITOR_CMD
    if [ -n "$EDITOR_OVERRIDE" ]; then
        EDITOR_CMD="$EDITOR_OVERRIDE"
    elif [ -n "$EDITOR" ]; then
        EDITOR_CMD="$EDITOR"
    elif [ -n "$VISUAL" ]; then
        EDITOR_CMD="$VISUAL"
    else
        EDITOR_CMD="vim"
    fi

    # Display information
    echo -e "${CYAN}Environment:${NC}  $ENVIRONMENT"
    echo -e "${CYAN}File:${NC}         $ENV_PATH"
    echo -e "${CYAN}Server:${NC}       ${APP_USER}@${APP_HOST}"
    echo -e "${CYAN}Editor:${NC}       $EDITOR_CMD"
    echo ""

    # Build SSH command
    SSH_CMD="ssh"
    if [ -n "$APP_SSH_KEY" ] && [ "$APP_SSH_KEY" != "null" ]; then
        SSH_CMD="$SSH_CMD -i $APP_SSH_KEY"
    fi
    SSH_CMD="$SSH_CMD ${APP_USER}@${APP_HOST}"

    # Check if file exists on server
    echo -e "${YELLOW}Checking if file exists on server...${NC}"
    if $SSH_CMD "test -f $ENV_PATH" 2>/dev/null; then
        echo -e "${GREEN}✓ File exists${NC}"
    else
        echo -e "${YELLOW}⚠ File does not exist yet${NC}"
        echo ""
        read -p "Create new file? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Cancelled${NC}"
            exit 0
        fi

        # Create parent directory if needed
        ENV_DIR=$(dirname "$ENV_PATH")
        echo -e "${YELLOW}Creating directory: $ENV_DIR${NC}"
        $SSH_CMD "mkdir -p $ENV_DIR" 2>/dev/null || {
            echo -e "${RED}Error: Failed to create directory${NC}"
            exit 1
        }
    fi

    echo ""
    echo -e "${YELLOW}Opening editor on remote server...${NC}"
    echo -e "${YELLOW}(Save and exit to return)${NC}"
    echo ""

    # Open editor on remote server
    $SSH_CMD -t "$EDITOR_CMD $ENV_PATH"

    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✓ File saved successfully${NC}"
    else
        echo ""
        echo -e "${RED}✗ Editor exited with error (code: $EXIT_CODE)${NC}"
        exit $EXIT_CODE
    fi
}

# Only run if executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    handle_env_command "$@"
fi
