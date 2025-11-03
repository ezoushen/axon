#!/bin/bash
# Check status of Docker containers
# Runs from LOCAL MACHINE and SSHs to Application Server
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
# Use current working directory for PRODUCT_ROOT (where config/Dockerfile live)
PRODUCT_ROOT="${PROJECT_ROOT:-$PWD}"

# Default configuration file
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"

# Early product type detection - check config file location from args
# This allows us to delegate to status-static.sh before parsing all arguments
for arg in "$@"; do
    if [ "$next_is_config" = "1" ]; then
        CONFIG_FILE="$arg"
        next_is_config=""
        break
    fi
    if [ "$arg" = "-c" ] || [ "$arg" = "--config" ]; then
        next_is_config="1"
    fi
done

# Make CONFIG_FILE absolute path if it's relative
if [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="${PRODUCT_ROOT}/${CONFIG_FILE}"
fi

# Check if config exists and get product type early
if [ -f "$CONFIG_FILE" ]; then
    source "$MODULE_DIR/lib/config-parser.sh"
    PRODUCT_TYPE=$(get_product_type "$CONFIG_FILE" 2>/dev/null || echo "docker")

    # For static sites, delegate to status-static.sh immediately (before parsing args)
    if [ "$PRODUCT_TYPE" = "static" ]; then
        exec "$MODULE_DIR/cmd/status-static.sh" "$@"
    fi
fi

# Docker deployment continues below
ENVIRONMENT=""
STATUS_ALL=false
# Status display flags
SHOW_DETAILED=false
SHOW_CONFIG=false
SHOW_HEALTH=false

# Parse arguments
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
        --detailed|--inspect)
            SHOW_DETAILED=true
            shift
            ;;
        --configuration)
            SHOW_CONFIG=true
            shift
            ;;
        --health)
            SHOW_HEALTH=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 <environment|--all> [OPTIONS]"
            echo ""
            echo "Show comprehensive container status and Docker-level information."
            echo ""
            echo "This command displays container state, resource usage, configuration, and"
            echo "Docker health check status (from Dockerfile HEALTHCHECK). It provides operational"
            echo "insights into running containers without making active requests to your application."
            echo ""
            echo "Note: To actively test application health endpoints, use 'axon health' instead."
            echo ""
            echo "Options:"
            echo "  -c, --config FILE         Specify config file (default: axon.config.yml)"
            echo "  --all                     Show status for all environments"
            echo "  --detailed, --inspect     Show detailed container information"
            echo "  --configuration           Show container configuration (env vars, volumes, ports)"
            echo "  --health                  Show Docker health check status and history"
            echo "  -h, --help                Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment               Specific environment to check"
            echo ""
            echo "Examples:"
            echo "  $0 --all                  # Check all environments (summary)"
            echo "  $0 production             # Check production only (summary)"
            echo "  $0 production --detailed  # Show detailed information"
            echo "  $0 staging --health       # Show Docker health check status"
            echo "  $0 --all --configuration  # Show configuration for all environments"
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
if [ "$STATUS_ALL" = false ] && [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment is required (or use --all to show all environments)${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Conflict check
if [ "$STATUS_ALL" = true ] && [ -n "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Cannot specify both --all and a specific environment${NC}"
    echo "Use --help for usage information"
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

# Initialize SSH connection multiplexing for performance
ssh_init_multiplexing

# Load product name (type already checked above)
PRODUCT_NAME=$(parse_yaml_key "product.name" "")

# Get Application Server SSH details
# We load these early since they're needed for all environments
APPLICATION_SERVER_HOST=$(expand_env_vars "$(parse_yaml_key ".servers.application.host" "")")
APPLICATION_SERVER_USER=$(expand_env_vars "$(parse_yaml_key ".servers.application.user" "")")
APPLICATION_SERVER_SSH_KEY=$(parse_yaml_key ".servers.application.ssh_key" "")
APPLICATION_SERVER_SSH_KEY="${APPLICATION_SERVER_SSH_KEY/#\~/$HOME}"

if [ -z "$APPLICATION_SERVER_HOST" ]; then
    echo -e "${RED}Error: Application Server host not configured${NC}"
    exit 1
fi

if [ ! -f "$APPLICATION_SERVER_SSH_KEY" ]; then
    echo -e "${RED}Error: SSH key not found: $APPLICATION_SERVER_SSH_KEY${NC}"
    exit 1
fi

APP_SERVER="${APPLICATION_SERVER_USER}@${APPLICATION_SERVER_HOST}"

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

# Build container name filter based on environment
if [ "$ENVIRONMENT" == "all" ]; then
    CONTAINER_FILTER="${PRODUCT_NAME}"
    ENV_DISPLAY="All Environments"
else
    CONTAINER_FILTER="${PRODUCT_NAME}-${ENVIRONMENT}"
    # Convert environment to title case (Bash 3.2 compatible)
    ENV_TITLE="$(echo "${ENVIRONMENT:0:1}" | tr '[:lower:]' '[:upper:]')${ENVIRONMENT:1}"
    ENV_DISPLAY="${ENV_TITLE} Environment"
fi

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Docker Containers Status - ${PRODUCT_NAME}${NC}"
echo -e "${BLUE}${ENV_DISPLAY}${NC}"
echo -e "${BLUE}On Application Server: ${APP_SERVER}${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

# Consolidated data fetch - single SSH call for all container data
REMOTE_DATA=$(axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" bash <<EOF_FETCH
CONTAINER_FILTER="${CONTAINER_FILTER}"

# Get container list
CONTAINERS=\$(docker ps -a --filter "name=\${CONTAINER_FILTER}" --format '{{.Names}}' | sort)

if [ -z "\$CONTAINERS" ]; then
    echo "===NO_CONTAINERS==="
    exit 0
fi

# Output container names
echo "===CONTAINERS==="
echo "\$CONTAINERS"

# Get complete inspect data as JSON (single call for all containers)
echo "===INSPECT==="
docker inspect \$CONTAINERS 2>/dev/null

# Get summary table
echo "===SUMMARY==="
docker ps -a --filter "name=\${CONTAINER_FILTER}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Get stats for running containers only
RUNNING=\$(docker ps --filter "name=\${CONTAINER_FILTER}" --format '{{.Names}}' | tr '\n' ' ')
if [ -n "\$RUNNING" ]; then
    echo "===STATS==="
    docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}' \$RUNNING
fi

EOF_FETCH
)

# Check if no containers found
if echo "$REMOTE_DATA" | grep -q "===NO_CONTAINERS==="; then
    echo -e "${YELLOW}No containers found for ${PRODUCT_NAME}${NC}"
    echo ""
    echo "To deploy:"
    echo "  ./deploy.sh production"
    echo "  ./deploy.sh staging"
    exit 0
fi

# Extract sections from remote data
CONTAINERS=$(echo "$REMOTE_DATA" | awk '/===CONTAINERS===/,/===INSPECT===/' | grep -v '===')
INSPECT_JSON=$(echo "$REMOTE_DATA" | awk '/===INSPECT===/,/===SUMMARY===/' | grep -v '===')

# Extract SUMMARY_TABLE - stop at ===STATS=== if it exists, otherwise get everything after ===SUMMARY===
if echo "$REMOTE_DATA" | grep -q "===STATS==="; then
    SUMMARY_TABLE=$(echo "$REMOTE_DATA" | awk '/===SUMMARY===/,/===STATS===/' | grep -v '===')
    STATS_TABLE=$(echo "$REMOTE_DATA" | awk '/===STATS===/{flag=1; next} flag')
else
    SUMMARY_TABLE=$(echo "$REMOTE_DATA" | awk '/===SUMMARY===/{flag=1; next} flag')
    STATS_TABLE=""
fi

#==============================================================================
# Display Functions
#==============================================================================

# Helper function to redact sensitive environment variables
redact_env_value() {
    local key="$1"
    local value="$2"

    # List of sensitive keywords
    if [[ "$key" =~ (PASSWORD|SECRET|KEY|TOKEN|CREDENTIAL|AUTH) ]]; then
        echo "[REDACTED]"
    else
        echo "$value"
    fi
}

# Function to show detailed container information
show_detailed() {
    local container="$1"

    echo -e "${BLUE}==================================================  ${NC}"
    echo -e "${CYAN}Container: ${container}${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo ""

    # Parse all data locally from INSPECT_JSON (single jq call, much faster)
    local DATA=$(echo "$INSPECT_JSON" | jq -r --arg name "$container" '
        .[] | select(.Name == "/\($name)") | {
            status: .State.Status,
            health: (.State.Health.Status // "N/A"),
            created: .Created,
            started: .State.StartedAt,
            image: .Config.Image,
            image_id: .Image,
            ports: [.NetworkSettings.Ports | to_entries[] | select(.value != null) | "\(.key) -> \(.value[0].HostPort)"] | join(" "),
            network: [.NetworkSettings.Networks | keys[]] | join(","),
            ip: [.NetworkSettings.Networks | to_entries[].value.IPAddress] | join(","),
            env_count: (.Config.Env | length),
            healthcheck_test: (if .Config.Healthcheck then [.Config.Healthcheck.Test[]] | join(" ") else "" end),
            volumes: [.Mounts[] | "\(.Source) → \(.Destination)"] | join("\n")
        } | @json
    ')

    # Extract individual fields
    local STATUS=$(echo "$DATA" | jq -r '.status')
    local HEALTH=$(echo "$DATA" | jq -r '.health')
    local CREATED=$(echo "$DATA" | jq -r '.created' | cut -d'.' -f1)
    local STARTED=$(echo "$DATA" | jq -r '.started' | cut -d'.' -f1)
    local IMAGE=$(echo "$DATA" | jq -r '.image')
    local IMAGE_ID=$(echo "$DATA" | jq -r '.image_id' | cut -d':' -f2 | cut -c1-12)
    local TAG=$(echo "$IMAGE" | cut -d':' -f2)
    local PORTS=$(echo "$DATA" | jq -r '.ports')
    local NETWORK=$(echo "$DATA" | jq -r '.network')
    local IP=$(echo "$DATA" | jq -r '.ip')
    local ENV_COUNT=$(echo "$DATA" | jq -r '.env_count')
    local HEALTH_TEST=$(echo "$DATA" | jq -r '.healthcheck_test')
    local VOLUMES=$(echo "$DATA" | jq -r '.volumes')

    # Status icon and text
    if [ "$STATUS" == "running" ]; then
        STATUS_ICON="${GREEN}✓"
        if [ "$HEALTH" == "healthy" ]; then
            STATUS_TEXT="Running (Healthy)"
        elif [ "$HEALTH" == "unhealthy" ]; then
            STATUS_TEXT="Running (Unhealthy)"
            STATUS_ICON="${YELLOW}⚠"
        else
            STATUS_TEXT="Running"
        fi
    else
        STATUS_ICON="${RED}✗"
        STATUS_TEXT="$STATUS"
    fi

    echo -e "Status: ${STATUS_ICON} ${STATUS_TEXT}${NC}"

    # Uptime
    if [ "$STATUS" == "running" ]; then
        echo -e "Uptime: ${CYAN}$(TZ=UTC date -d "$STARTED" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "$STARTED")${NC}"
    fi
    echo ""

    # Image info
    echo -e "${CYAN}IMAGE & VERSION:${NC}"
    echo -e "  Image: ${IMAGE}"
    echo -e "  Image ID: ${IMAGE_ID}"
    echo -e "  Tag: ${TAG}"
    echo -e "  Created: ${CREATED}"
    echo ""

    # Network & Ports
    echo -e "${CYAN}NETWORK & PORTS:${NC}"
    echo -e "  Port Mapping: ${PORTS:-None}"
    echo -e "  Networks: ${NETWORK:-None}"
    echo -e "  IP Address: ${IP:-None}"
    echo ""

    # Resources (fetch from remote only for running containers)
    if [ "$STATUS" == "running" ]; then
        echo -e "${CYAN}RESOURCES:${NC}"
        axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
            "docker stats --no-stream --format '  CPU Usage: {{.CPUPerc}}\n  Memory Usage: {{.MemUsage}}' '$container'"
        echo ""
    fi

    # Health check
    if [ "$HEALTH" != "N/A" ]; then
        echo -e "${CYAN}HEALTH CHECK:${NC}"
        echo -e "  Status: ${HEALTH}"
        echo -e "  Test: ${HEALTH_TEST}"
        echo ""
    fi

    # Environment variables (count only)
    echo -e "${CYAN}ENVIRONMENT:${NC}"
    echo -e "  Variables: ${ENV_COUNT} set"
    echo -e "  (Use --configuration to view details)"
    echo ""

    # Volumes
    if [ -n "$VOLUMES" ] && [ "$VOLUMES" != "null" ]; then
        echo -e "${CYAN}VOLUMES:${NC}"
        echo "$VOLUMES" | while read line; do
            [ -n "$line" ] && echo -e "  $line"
        done
        echo ""
    fi

    # Recent logs (fetch from remote only for running containers)
    if [ "$STATUS" == "running" ]; then
        echo -e "${CYAN}RECENT LOGS (last 10 lines):${NC}"
        axon_ssh "app" -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
            "docker logs --tail 10 '$container' 2>&1" | sed 's/^/  /'
        echo ""
    fi

    echo ""
}

# Function to show configuration details
show_configuration() {
    local container="$1"

    echo -e "${BLUE}==================================================${NC}"
    echo -e "${CYAN}Configuration: ${container}${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo ""

    # Parse all data locally from INSPECT_JSON (single jq call)
    local DATA=$(echo "$INSPECT_JSON" | jq -r --arg name "$container" '
        .[] | select(.Name == "/\($name)") | {
            env: .Config.Env,
            volumes: [.Mounts[] | "\(.Source) → \(.Destination)"] | join("\n"),
            network: [.NetworkSettings.Networks | keys[]] | join(","),
            ip: [.NetworkSettings.Networks | to_entries[].value.IPAddress] | join(","),
            ports: [.NetworkSettings.Ports | to_entries[] | select(.value != null) | "\(.key) -> \(.value[0].HostPort)"] | join(" ")
        } | @json
    ')

    # Environment Variables
    echo -e "${CYAN}Environment Variables:${NC}"
    echo "$DATA" | jq -r '.env[]' | while IFS='=' read -r key value; do
        if [[ "$key" =~ (PASSWORD|SECRET|KEY|TOKEN|CREDENTIAL|AUTH) ]]; then
            echo -e "  ${key}=${YELLOW}[REDACTED]${NC}"
        else
            echo "  ${key}=${value}"
        fi
    done
    echo ""

    # Volumes
    echo -e "${CYAN}Volumes:${NC}"
    local VOLUMES=$(echo "$DATA" | jq -r '.volumes')
    if [ -n "$VOLUMES" ] && [ "$VOLUMES" != "null" ]; then
        echo "$VOLUMES" | while read line; do
            [ -n "$line" ] && echo "  $line"
        done
    else
        echo "  None"
    fi
    echo ""

    # Network
    echo -e "${CYAN}Network:${NC}"
    local NETWORK=$(echo "$DATA" | jq -r '.network')
    local IP=$(echo "$DATA" | jq -r '.ip')
    local PORTS=$(echo "$DATA" | jq -r '.ports')

    echo -e "  Mode: ${NETWORK:-bridge}"
    echo -e "  IP: ${IP:-None}"
    echo -e "  Ports: ${PORTS:-None}"
    echo ""
}

# Function to show health check details
show_health() {
    local container="$1"

    echo -e "${BLUE}==================================================${NC}"
    echo -e "${CYAN}Health Check: ${container}${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo ""

    # Parse all health data locally from INSPECT_JSON (single jq call)
    local DATA=$(echo "$INSPECT_JSON" | jq -r --arg name "$container" '
        .[] | select(.Name == "/\($name)") | {
            health_status: (.State.Health.Status // "N/A"),
            test: (if .Config.Healthcheck then [.Config.Healthcheck.Test[]] | join(" ") else "" end),
            interval: (.Config.Healthcheck.Interval // "N/A"),
            timeout: (.Config.Healthcheck.Timeout // "N/A"),
            retries: (.Config.Healthcheck.Retries // "N/A"),
            start_period: (.Config.Healthcheck.StartPeriod // "N/A"),
            log: (.State.Health.Log // [])
        } | @json
    ')

    local HEALTH_STATUS=$(echo "$DATA" | jq -r '.health_status')

    if [ "$HEALTH_STATUS" == "N/A" ] || [ -z "$HEALTH_STATUS" ]; then
        echo -e "${YELLOW}No health check configured for this container${NC}"
        echo ""
        return 0
    fi

    # Status icon and text
    local STATUS_ICON STATUS_TEXT
    case "$HEALTH_STATUS" in
        healthy) STATUS_ICON="${GREEN}✓"; STATUS_TEXT="Healthy" ;;
        unhealthy) STATUS_ICON="${RED}✗"; STATUS_TEXT="Unhealthy" ;;
        starting) STATUS_ICON="${YELLOW}⚠"; STATUS_TEXT="Starting" ;;
        *) STATUS_ICON="${YELLOW}?"; STATUS_TEXT="$HEALTH_STATUS" ;;
    esac

    echo -e "Overall Status: ${STATUS_ICON} ${STATUS_TEXT}${NC}"
    echo ""

    # Health check configuration
    echo -e "${CYAN}Health Check Configuration:${NC}"
    local TEST=$(echo "$DATA" | jq -r '.test')
    local INTERVAL=$(echo "$DATA" | jq -r '.interval')
    local TIMEOUT=$(echo "$DATA" | jq -r '.timeout')
    local RETRIES=$(echo "$DATA" | jq -r '.retries')
    local START_PERIOD=$(echo "$DATA" | jq -r '.start_period')

    echo -e "  Test: ${TEST}"
    echo -e "  Interval: ${INTERVAL}"
    echo -e "  Timeout: ${TIMEOUT}"
    echo -e "  Retries: ${RETRIES}"
    echo -e "  Start Period: ${START_PERIOD}"
    echo ""

    # Recent health check results (last 5)
    echo -e "${CYAN}Recent Health Checks (last 5):${NC}"
    echo "$DATA" | jq -r '.log[-5:] | .[] | "\(.Start) - \(.ExitCode)"' | while read line; do
        if [ -n "$line" ]; then
            local TIMESTAMP=$(echo "$line" | cut -d' ' -f1)
            local EXIT_CODE=$(echo "$line" | awk '{print $NF}')

            if [ "$EXIT_CODE" == "0" ]; then
                echo -e "  [${TIMESTAMP}] ${GREEN}✓ Passed${NC}"
            else
                echo -e "  [${TIMESTAMP}] ${RED}✗ Failed (exit code: ${EXIT_CODE})${NC}"
            fi
        fi
    done
    echo ""
}

#==============================================================================
# Main Display Logic
#==============================================================================

# Determine which display mode to use
if [ "$SHOW_DETAILED" = true ] || [ "$SHOW_CONFIG" = true ] || [ "$SHOW_HEALTH" = true ]; then
    # Custom display mode - show for each container
    for CONTAINER in $CONTAINERS; do
        if [ "$SHOW_DETAILED" = true ]; then
            show_detailed "$CONTAINER"
        fi

        if [ "$SHOW_CONFIG" = true ]; then
            show_configuration "$CONTAINER"
        fi

        if [ "$SHOW_HEALTH" = true ]; then
            show_health "$CONTAINER"
        fi
    done
    exit 0
fi

# Default mode - original summary display
# Summary
echo -e "${CYAN}Container Summary:${NC}"
echo ""
echo "$SUMMARY_TABLE"
echo ""

# Detailed status
echo -e "${CYAN}Detailed Status:${NC}"
echo ""

# Parse container details locally using jq (much faster than remote docker loops)
while IFS= read -r CONTAINER; do
    if [ -z "$CONTAINER" ]; then
        continue
    fi

    # Extract all data for this container from JSON in one pass
    CONTAINER_DATA=$(echo "$INSPECT_JSON" | jq -r --arg name "$CONTAINER" '
        .[] | select(.Name == "/\($name)") | {
            status: .State.Status,
            health: (.State.Health.Status // "N/A"),
            image: .Config.Image,
            started: .State.StartedAt
        } | @json
    ')

    # Parse environment from container name
    if [[ $CONTAINER == *"production"* ]]; then
        ENV="PRODUCTION"
    elif [[ $CONTAINER == *"staging"* ]]; then
        ENV="STAGING"
    else
        ENV="UNKNOWN"
    fi

    # Extract fields from JSON
    STATUS=$(echo "$CONTAINER_DATA" | jq -r '.status')
    HEALTH=$(echo "$CONTAINER_DATA" | jq -r '.health')
    IMAGE=$(echo "$CONTAINER_DATA" | jq -r '.image')
    IMAGE_TAG=$(echo "$IMAGE" | cut -d':' -f2)
    STARTED=$(echo "$CONTAINER_DATA" | jq -r '.started' | cut -d'.' -f1)

    # Environment color
    case "$ENV" in
        PRODUCTION) ENV_COLOR="${GREEN}" ;;
        STAGING) ENV_COLOR="${YELLOW}" ;;
        *) ENV_COLOR="${RED}" ;;
    esac

    # Status color
    if [ "$STATUS" == "running" ]; then
        STATUS_COLOR="${GREEN}"
        STATUS_SYMBOL="●"
    else
        STATUS_COLOR="${RED}"
        STATUS_SYMBOL="●"
    fi

    # Health color
    case "$HEALTH" in
        healthy) HEALTH_COLOR="${GREEN}" ;;
        unhealthy) HEALTH_COLOR="${RED}" ;;
        *) HEALTH_COLOR="${YELLOW}" ;;
    esac

    echo -e "${ENV_COLOR}${ENV} Environment${NC}"
    echo -e "  Container:  ${CYAN}${CONTAINER}${NC}"
    echo -e "  Status:     ${STATUS_COLOR}${STATUS_SYMBOL} ${STATUS}${NC}"
    echo -e "  Health:     ${HEALTH_COLOR}${HEALTH}${NC}"
    echo -e "  Image Tag:  ${CYAN}${IMAGE_TAG}${NC}"

    if [ -n "$STARTED" ]; then
        echo -e "  Started:    ${CYAN}${STARTED}${NC}"
    fi

    echo ""
done <<< "$CONTAINERS"

# Resource usage
echo -e "${CYAN}Resource Usage:${NC}"
echo ""

if [ -n "$STATS_TABLE" ]; then
    echo "$STATS_TABLE"
else
    echo -e "${YELLOW}No running containers to show stats${NC}"
fi
echo ""
