#!/bin/bash
# View nginx logs for static sites on System Server
# Runs from LOCAL MACHINE and SSHs to System Server
# Product-agnostic version - uses axon.config.yml

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Use current working directory for PRODUCT_ROOT (where config/Dockerfile live)
PRODUCT_ROOT="${PROJECT_ROOT:-$PWD}"

# Default configuration file (use exported CONFIG_FILE if set, otherwise default)
CONFIG_FILE="${CONFIG_FILE:-${PRODUCT_ROOT}/axon.config.yml}"
ENVIRONMENT=""
LOGS_ALL=false
FOLLOW=false
LINES="50"
SINCE=""
LOG_TYPE="both"  # access, error, or both

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --all)
            LOGS_ALL=true
            shift
            ;;
        --follow|-f)
            FOLLOW=true
            shift
            ;;
        -n|--lines|--tail)
            LINES="$2"
            shift 2
            ;;
        --since)
            SINCE="$2"
            shift 2
            ;;
        --type)
            LOG_TYPE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 <environment|--all> [OPTIONS]"
            echo ""
            echo "View nginx logs for static site deployments."
            echo ""
            echo "OPTIONS:"
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
            echo "  --all                View logs for all environments"
            echo "  -f, --follow         Follow log output (stream in real-time)"
            echo "  -n, --lines N        Number of lines to show (default: 50)"
            echo "  --tail N             Same as --lines"
            echo "  --since DURATION     Show logs since duration (e.g., 1h, 30m)"
            echo "  --type TYPE          Log type: access, error, or both (default: both)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment          Specific environment to check logs for"
            echo ""
            echo "Examples:"
            echo "  $0 production                # Last 50 lines (both access and error)"
            echo "  $0 --all                     # Logs from all environments"
            echo "  $0 staging --follow          # Follow logs in real-time"
            echo "  $0 production --lines 100    # Last 100 lines"
            echo "  $0 staging --since 1h        # Logs from last hour"
            echo "  $0 production --type access  # Only access logs"
            echo "  $0 production --type error   # Only error logs"
            exit 0
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            # Positional argument
            if [ -z "$ENVIRONMENT" ]; then
                ENVIRONMENT="$1"
            else
                echo -e "${RED}Error: Too many positional arguments${NC}"
                echo "Use --help for usage information"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ "$LOGS_ALL" = false ] && [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment is required (or use --all to view all environments)${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Conflict check
if [ "$LOGS_ALL" = true ] && [ -n "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Cannot specify both --all and a specific environment${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Validate log type
if [ "$LOG_TYPE" != "access" ] && [ "$LOG_TYPE" != "error" ] && [ "$LOG_TYPE" != "both" ]; then
    echo -e "${RED}Error: Invalid log type: $LOG_TYPE${NC}"
    echo "Valid types: access, error, both"
    exit 1
fi

# Set ENVIRONMENT to 'all' if --all flag is used
if [ "$LOGS_ALL" = true ]; then
    ENVIRONMENT="all"
fi

# Make CONFIG_FILE absolute path if it's relative
if [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="${PRODUCT_ROOT}/${CONFIG_FILE}"
fi

# Validate config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Source libraries
source "$MODULE_DIR/lib/config-parser.sh"
source "$MODULE_DIR/lib/defaults.sh"
source "$MODULE_DIR/lib/ssh-connection.sh"

# Initialize SSH connection multiplexing for performance
ssh_init_multiplexing

# Load product name
PRODUCT_NAME=$(parse_yaml_key "product.name" "")

if [ -z "$PRODUCT_NAME" ]; then
    echo -e "${RED}Error: Product name not configured${NC}"
    exit 1
fi

# Get System Server SSH details
SYSTEM_SERVER_HOST=$(expand_env_vars "$(parse_yaml_key ".servers.system.host" "")")
SYSTEM_SERVER_USER=$(expand_env_vars "$(parse_yaml_key ".servers.system.user" "")")
SYSTEM_SERVER_SSH_KEY=$(parse_yaml_key ".servers.system.ssh_key" "")
SYSTEM_SERVER_SSH_KEY="${SYSTEM_SERVER_SSH_KEY/#\~/$HOME}"

if [ -z "$SYSTEM_SERVER_HOST" ]; then
    echo -e "${RED}Error: System Server host not configured${NC}"
    exit 1
fi

if [ ! -f "$SYSTEM_SERVER_SSH_KEY" ]; then
    echo -e "${RED}Error: SSH key not found: $SYSTEM_SERVER_SSH_KEY${NC}"
    exit 1
fi

SYSTEM_SERVER="${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}"

# Validate environment exists if specific environment requested
if [ "$ENVIRONMENT" != "all" ]; then
    AVAILABLE_ENVS=$(get_configured_environments "$CONFIG_FILE")

    if [ -z "$AVAILABLE_ENVS" ]; then
        echo -e "${RED}Error: No environments configured in ${CONFIG_FILE}${NC}"
        exit 1
    fi

    # Check if requested environment is in the list
    ENV_FOUND=false
    for env in $AVAILABLE_ENVS; do
        if [ "$env" = "$ENVIRONMENT" ]; then
            ENV_FOUND=true
            break
        fi
    done

    if [ "$ENV_FOUND" = false ]; then
        echo -e "${RED}Error: Environment '${ENVIRONMENT}' not found in configuration${NC}"
        echo ""
        echo -e "${BLUE}Available environments:${NC}"
        for env in $AVAILABLE_ENVS; do
            echo -e "  - ${env}"
        done
        echo ""
        exit 1
    fi
fi

# Show logs for a single environment
show_environment_logs() {
    local env=$1

    # Build log file paths
    local ACCESS_LOG="/var/log/nginx/${PRODUCT_NAME}-${env}.log"
    local ERROR_LOG="/var/log/nginx/${PRODUCT_NAME}-${env}-error.log"

    echo -e "${BLUE}==================================================${NC}"
    echo -e "${BLUE}Nginx Logs - ${PRODUCT_NAME}${NC}"
    echo -e "${BLUE}Environment: $(echo "${env:0:1}" | tr '[:lower:]' '[:upper:]')${env:1}${NC}"
    echo -e "${BLUE}On System Server: ${SYSTEM_SERVER}${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo ""

    # Check if log files exist
    if [ "$LOG_TYPE" = "access" ] || [ "$LOG_TYPE" = "both" ]; then
        local ACCESS_EXISTS=$(axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
            "[ -f '$ACCESS_LOG' ] && echo 'yes' || echo 'no'")

        if [ "$ACCESS_EXISTS" = "no" ]; then
            echo -e "${YELLOW}Warning: Access log not found: $ACCESS_LOG${NC}"
            if [ "$LOG_TYPE" = "access" ]; then
                exit 1
            fi
        fi
    fi

    if [ "$LOG_TYPE" = "error" ] || [ "$LOG_TYPE" = "both" ]; then
        local ERROR_EXISTS=$(axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
            "[ -f '$ERROR_LOG' ] && echo 'yes' || echo 'no'")

        if [ "$ERROR_EXISTS" = "no" ]; then
            echo -e "${YELLOW}Warning: Error log not found: $ERROR_LOG${NC}"
            if [ "$LOG_TYPE" = "error" ]; then
                exit 1
            fi
        fi
    fi

    # Build tail command options
    local TAIL_OPTS=""

    if [ "$FOLLOW" = true ]; then
        TAIL_OPTS="$TAIL_OPTS -f"
        echo -e "${GREEN}Following logs (Ctrl+C to exit)...${NC}"
        echo ""
    fi

    TAIL_OPTS="$TAIL_OPTS -n $LINES"

    # Show logs based on type
    if [ "$LOG_TYPE" = "both" ]; then
        echo -e "${CYAN}Access Log: $ACCESS_LOG${NC}"
        echo -e "${CYAN}Error Log:  $ERROR_LOG${NC}"
        echo ""

        # For both logs, we need to merge them
        # If following, we can't easily merge two files, so show them separately
        if [ "$FOLLOW" = true ]; then
            echo -e "${YELLOW}Note: Following both logs simultaneously. Access logs first, then error logs.${NC}"
            echo ""

            # This will follow both but not interleave them perfectly
            # A more sophisticated implementation could use `multitail` if available
            axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
                "tail $TAIL_OPTS '$ACCESS_LOG' '$ERROR_LOG'"
        else
            # For non-follow mode, we can show last N lines from each
            echo -e "${BLUE}--- Access Log (last $LINES lines) ---${NC}"
            axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
                "tail $TAIL_OPTS '$ACCESS_LOG' 2>/dev/null || echo '  (empty)'"
            echo ""
            echo -e "${BLUE}--- Error Log (last $LINES lines) ---${NC}"
            axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
                "tail $TAIL_OPTS '$ERROR_LOG' 2>/dev/null || echo '  (empty)'"
        fi
    elif [ "$LOG_TYPE" = "access" ]; then
        echo -e "${CYAN}Access Log: $ACCESS_LOG${NC}"
        echo ""
        axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
            "tail $TAIL_OPTS '$ACCESS_LOG'"
    else
        echo -e "${CYAN}Error Log: $ERROR_LOG${NC}"
        echo ""
        axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
            "tail $TAIL_OPTS '$ERROR_LOG'"
    fi
}

# Handle --all or single environment
if [ "$ENVIRONMENT" = "all" ]; then
    AVAILABLE_ENVS=$(get_configured_environments "$CONFIG_FILE")

    if [ -z "$AVAILABLE_ENVS" ]; then
        echo -e "${YELLOW}No environments configured${NC}"
        exit 0
    fi

    for env in $AVAILABLE_ENVS; do
        show_environment_logs "$env"
        echo ""
        echo ""
    done
else
    show_environment_logs "$ENVIRONMENT"
fi
