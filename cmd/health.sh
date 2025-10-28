#!/bin/bash
# Health check script for deployed containers
# Runs from LOCAL MACHINE and checks via domain or SSHs to Application Server
# Product-agnostic version

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

# Default configuration file
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
ENVIRONMENT=""
HEALTH_ALL=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --all)
            HEALTH_ALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 <environment|--all> [OPTIONS]"
            echo ""
            echo "Check container health status for a specific environment or all environments."
            echo ""
            echo "Options:"
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
            echo "  --all                Check health for all environments"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment          Specific environment to check"
            echo ""
            echo "Examples:"
            echo "  $0 --all             # Check all environments"
            echo "  $0 production        # Check production only"
            echo "  $0 --config custom.yml staging"
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
if [ "$HEALTH_ALL" = false ] && [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment is required (or use --all to check all environments)${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Conflict check
if [ "$HEALTH_ALL" = true ] && [ -n "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Cannot specify both --all and a specific environment${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Set ENVIRONMENT to 'all' if --all flag is used
if [ "$HEALTH_ALL" = true ]; then
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

check_environment() {
    local env=$1

    # Load all config for this environment
    load_config "$env"

    echo -e "${BLUE}Checking ${PRODUCT_NAME} - ${env}:${NC}"

    # Check via Application Server (container directly via localhost)
    if [ -z "$APPLICATION_SERVER_HOST" ]; then
        echo -e "  ${YELLOW}⚠ Application Server not configured${NC}"
        return 1
    fi

    if [ ! -f "$APPLICATION_SERVER_SSH_KEY" ]; then
        echo -e "  ${RED}✗ SSH key not found: $APPLICATION_SERVER_SSH_KEY${NC}"
        return 1
    fi

    APP_SERVER="${APPLICATION_SERVER_USER}@${APPLICATION_SERVER_HOST}"

    # Find the most recent container for this environment (timestamp-based naming)
    # Container name format: ${PRODUCT_NAME}-${env}-${timestamp}
    CONTAINER_NAME=$(axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
        "docker ps -a --filter 'name=${PRODUCT_NAME}-${env}-' --format '{{.Names}}' | sort -r | head -n 1" 2>/dev/null)

    if [ -z "$CONTAINER_NAME" ]; then
        echo -e "  Status: ${YELLOW}⚠ Container not found on Application Server${NC}"
        return 1
    fi

    echo -e "  Container:      ${CYAN}${CONTAINER_NAME}${NC}"

    # Get port from the container
    PORT=$(axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
        "docker port '${CONTAINER_NAME}' 3000 2>/dev/null | cut -d: -f2" 2>/dev/null)

    if [ -z "$PORT" ]; then
        echo -e "  Status: ${YELLOW}⚠ Container port not found${NC}"
        return 1
    fi

    URL="http://localhost:${PORT}${HEALTH_ENDPOINT}"
    echo -e "  Container Port: ${CYAN}${PORT}${NC}"
    echo -e "  Health URL:     ${CYAN}${URL}${NC} (on Application Server)"

    # Perform health check via SSH
    HTTP_CODE=$(axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 5 '$URL' 2>/dev/null")

    if [ "$HTTP_CODE" == "200" ]; then
        echo -e "  Status:         ${GREEN}✓ Healthy (HTTP $HTTP_CODE)${NC}"
        return 0
    else
        echo -e "  Status:         ${RED}✗ Unhealthy (HTTP $HTTP_CODE)${NC}"
        return 1
    fi
}

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Health Check${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

if [ "$ENVIRONMENT" == "all" ]; then
    # Check all configured environments
    # Try using yq first (if available), otherwise use awk
    if command -v yq &> /dev/null; then
        ENVS=$(yq eval '.environments | keys | .[]' "$CONFIG_FILE" 2>/dev/null)
    else
        # Fallback: Use awk to extract environment names
        # Look for lines that are 2-space indented under environments: section
        ENVS=$(awk '
            /^environments:/ { in_envs=1; next }
            in_envs && /^[a-z]/ { in_envs=0 }
            in_envs && /^  [a-z]/ {
                gsub(/:.*/, "")
                gsub(/^  /, "")
                print
            }
        ' "$CONFIG_FILE")
    fi

    if [ -z "$ENVS" ]; then
        echo -e "${YELLOW}No environments found in config${NC}"
        echo -e "${YELLOW}Tried to read from: $CONFIG_FILE${NC}"
        exit 1
    fi

    FAILED=0
    for env in $ENVS; do
        check_environment "$env"
        RESULT=$?
        [ $RESULT -ne 0 ] && FAILED=$((FAILED + 1))
        echo ""
    done

    echo -e "${BLUE}==================================================${NC}"
    if [ $FAILED -eq 0 ]; then
        echo -e "${GREEN}✓ All environments healthy${NC}"
        exit 0
    else
        echo -e "${RED}✗ ${FAILED} environment(s) unhealthy${NC}"
        exit 1
    fi
else
    check_environment "$ENVIRONMENT"
    exit $?
fi
