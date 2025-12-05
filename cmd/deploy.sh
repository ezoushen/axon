#!/bin/bash
# AXON - Zero-Downtime Deployment Script
# Runs from LOCAL MACHINE and orchestrates deployment on Application Server
# Part of AXON - reusable across products
#
# Usage: ./deploy.sh <environment>
# Example: ./deploy.sh production

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

# Product root directory (parent of deploy module)
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Use current working directory for PRODUCT_ROOT (where config/Dockerfile live)
PRODUCT_ROOT="${PROJECT_ROOT:-$PWD}"

# Source SSH batch execution library for performance optimization
source "$MODULE_DIR/lib/ssh-batch.sh"

# Source defaults library for nginx configuration functions
source "$MODULE_DIR/lib/defaults.sh"

# Source docker runtime library for container management functions
source "$MODULE_DIR/lib/docker-runtime.sh"

# Source nginx config library for nginx configuration generation
source "$MODULE_DIR/lib/nginx-config.sh"

# Source deploy-docker library for Docker deployment
source "$MODULE_DIR/lib/deploy-docker.sh"

# Source deploy-static library for static site deployment
source "$MODULE_DIR/lib/deploy-static.sh"

# Source port manager library for stable port allocation
source "$MODULE_DIR/lib/port-manager.sh"

# Default values
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
ENVIRONMENT=""
FORCE_CLEANUP=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --force|-f)
            FORCE_CLEANUP=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] <environment>"
            echo ""
            echo "Options:"
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
            echo "  --force, -f          Force cleanup of existing containers on target port"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment          Target environment (e.g., production, staging)"
            echo ""
            echo "Examples:"
            echo "  $0 production"
            echo "  $0 --config custom.yml staging"
            echo "  $0 --force production"
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

# Make CONFIG_FILE absolute path if it's relative
if [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="${PRODUCT_ROOT}/${CONFIG_FILE}"
fi

# Validate environment parameter
if [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment parameter required${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Check if configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Configuration file not found: $CONFIG_FILE${NC}"
    echo ""
    echo "Please create axon.config.yml in your product root directory."
    echo "You can copy from: $MODULE_DIR/config.example.yml"
    exit 1
fi

# Initialize SSH connection multiplexing for performance
if type ssh_init_multiplexing >/dev/null 2>&1; then
    ssh_init_multiplexing
fi

# Source the shared config parser library
source "$MODULE_DIR/lib/config-parser.sh"

# Wrapper function for backward compatibility (parse_config uses different syntax than parse_yaml_key)
# Still needed for Docker-specific config that's not in load_config
parse_config() {
    local key=$1
    local default=$2
    parse_yaml_key "$key" "$default" "$CONFIG_FILE"
}

# Load configuration
echo -e "${CYAN}==================================================${NC}"
echo -e "${CYAN}AXON - Zero-Downtime Deployment${NC}"
echo -e "${CYAN}==================================================${NC}"
echo ""

# Show context info if using context mode
if [ "$CONTEXT_MODE" = "context" ] && [ -n "$CONTEXT_NAME" ]; then
    echo -e "${BLUE}Context: ${YELLOW}${CONTEXT_NAME}${NC}"
fi

echo -e "${YELLOW}Running from: $(hostname)${NC}"
echo ""

echo -e "${BLUE}Loading configuration...${NC}"

# Validate environment exists in config
if ! validate_environment "$ENVIRONMENT" "$CONFIG_FILE"; then
    exit 1
fi

if [ "${VERBOSE:-false}" = "true" ]; then
    echo "[VERBOSE] deploy.sh: Calling load_config..." >&2
fi

# Load all common configuration using load_config
load_config "$ENVIRONMENT"

if [ "${VERBOSE:-false}" = "true" ]; then
    echo "[VERBOSE] deploy.sh: load_config completed, parsing product description..." >&2
fi

# Additional product-specific config not in load_config
PRODUCT_DESC=$(parse_config ".product.description" "")

# Detect product type
PRODUCT_TYPE=$(get_product_type "$CONFIG_FILE")
if [ "$PRODUCT_TYPE" != "docker" ] && [ "$PRODUCT_TYPE" != "static" ]; then
    echo -e "${RED}Error: Invalid product.type: ${PRODUCT_TYPE}${NC}"
    echo "Must be 'docker' or 'static'"
    exit 1
fi

# ==============================================================================
# Deployment Functions (defined in lib/deploy-*.sh)
# ==============================================================================
# deploy_docker() is sourced from lib/deploy-docker.sh
# deploy_static() is sourced from lib/deploy-static.sh

# ==============================================================================
# Route to appropriate deployment function based on product type
# ==============================================================================

if [ "$PRODUCT_TYPE" = "static" ]; then
    deploy_static
else
    deploy_docker
fi

exit 0
