#!/bin/bash
# Check status of static site deployments
# Runs from LOCAL MACHINE and SSHs to System Server
# Product-agnostic version - uses axon.config.yml

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
# Use current working directory for PRODUCT_ROOT (where config lives)
PRODUCT_ROOT="${PROJECT_ROOT:-$PWD}"

# Default configuration file
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
ENVIRONMENT=""
STATUS_ALL=false

# Parse arguments (inherit from parent status.sh call)
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --all)
            STATUS_ALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 <environment|--all> [OPTIONS]"
            echo ""
            echo "Show static site deployment status"
            echo ""
            echo "Options:"
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
            echo "  --all                Show status for all environments"
            echo "  -h, --help           Show this help message"
            exit 0
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            exit 1
            ;;
        *)
            if [ -z "$ENVIRONMENT" ]; then
                ENVIRONMENT="$1"
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ "$STATUS_ALL" = false ] && [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment is required (or use --all)${NC}"
    exit 1
fi

# Set ENVIRONMENT to 'all' if --all flag is used
if [ "$STATUS_ALL" = true ]; then
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

# Initialize SSH connection multiplexing
ssh_init_multiplexing

# Load product name
PRODUCT_NAME=$(parse_yaml_key "product.name" "")

# Get System Server SSH details
SYSTEM_SERVER_HOST=$(parse_yaml_key ".servers.system.host" "")
SYSTEM_SERVER_USER=$(parse_yaml_key ".servers.system.user" "")
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

# Check status for a single environment
check_environment() {
    local env=$1

    echo -e "${BLUE}=== ${PRODUCT_NAME} - ${env} ===${NC}"
    echo ""

    # Get deploy path for this environment
    DEPLOY_PATH=$(get_deploy_path "$env" "$CONFIG_FILE")
    DOMAIN=$(get_nginx_domain "$env" "$CONFIG_FILE")

    if [ -z "$DEPLOY_PATH" ]; then
        echo -e "${YELLOW}⚠ Deploy path not configured for ${env}${NC}"
        return 1
    fi

    # Get current release
    CURRENT_SYMLINK=$(get_current_symlink_path "$DEPLOY_PATH" "$env")
    CURRENT_RELEASE=$(axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
        "if [ -L '$CURRENT_SYMLINK' ]; then readlink '$CURRENT_SYMLINK' | xargs basename; else echo ''; fi" 2>/dev/null)

    if [ -n "$CURRENT_RELEASE" ]; then
        echo -e "  ${GREEN}✓${NC} Deployed"
        echo -e "  Current Release:  ${CYAN}${CURRENT_RELEASE}${NC}"
        echo -e "  Deploy Path:      ${CYAN}${CURRENT_SYMLINK}${NC}"
    else
        echo -e "  ${YELLOW}⚠${NC} Not deployed"
        echo -e "  Deploy Path:      ${CYAN}${DEPLOY_PATH}/${env}${NC}"
    fi

    if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ]; then
        echo -e "  Domain:           ${CYAN}https://${DOMAIN}${NC}"
    fi

    # List available releases
    RELEASES_DIR="${DEPLOY_PATH}/${env}/releases"
    RELEASES=$(axon_ssh "system" -i "$SYSTEM_SERVER_SSH_KEY" "$SYSTEM_SERVER" \
        "if [ -d '$RELEASES_DIR' ]; then ls -t '$RELEASES_DIR' 2>/dev/null; else echo ''; fi" 2>/dev/null)

    if [ -n "$RELEASES" ]; then
        RELEASE_COUNT=$(echo "$RELEASES" | wc -l | tr -d ' ')
        echo -e "  Available Releases: ${CYAN}${RELEASE_COUNT}${NC}"

        # Show last 3 releases
        echo "$RELEASES" | head -3 | while read -r release; do
            if [ "$release" = "$CURRENT_RELEASE" ]; then
                echo -e "    ${GREEN}→${NC} $release (current)"
            else
                echo -e "      $release"
            fi
        done

        if [ "$RELEASE_COUNT" -gt 3 ]; then
            echo -e "      ... and $((RELEASE_COUNT - 3)) more"
        fi
    else
        echo -e "  Available Releases: ${YELLOW}0${NC}"
    fi

    echo ""
}

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Static Site Status - ${PRODUCT_NAME}${NC}"
echo -e "${BLUE}System Server: ${SYSTEM_SERVER}${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

# Check environments
if [ "$ENVIRONMENT" = "all" ]; then
    AVAILABLE_ENVS=$(get_configured_environments "$CONFIG_FILE")

    if [ -z "$AVAILABLE_ENVS" ]; then
        echo -e "${RED}Error: No environments configured${NC}"
        exit 1
    fi

    for env in $AVAILABLE_ENVS; do
        check_environment "$env"
    done
else
    check_environment "$ENVIRONMENT"
fi

echo -e "${BLUE}Useful Commands:${NC}"
echo -e "  Check health:     ${CYAN}axon health ${ENVIRONMENT}${NC}"
echo -e "  View logs:        ${CYAN}ssh -i ${SYSTEM_SERVER_SSH_KEY} ${SYSTEM_SERVER} 'journalctl -u nginx -n 50'${NC}"
echo ""
