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
PRODUCT_ROOT="$PWD"

# Default configuration file
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
ENVIRONMENT=""
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
            echo "Usage: $0 [OPTIONS] [environment]"
            echo ""
            echo "Options:"
            echo "  -c, --config FILE         Specify config file (default: axon.config.yml)"
            echo "  --detailed, --inspect     Show detailed container information"
            echo "  --configuration           Show container configuration (env vars, volumes, ports)"
            echo "  --health                  Show health check status and history"
            echo "  -h, --help                Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment               Environment to check (default: all)"
            echo ""
            echo "Examples:"
            echo "  $0                        # Check all environments (summary)"
            echo "  $0 production             # Check production only (summary)"
            echo "  $0 production --detailed  # Show detailed information"
            echo "  $0 staging --health       # Show health check status"
            echo "  $0 --configuration        # Show configuration for all environments"
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

# Default environment to 'all'
ENVIRONMENT=${ENVIRONMENT:-all}

# Make CONFIG_FILE absolute path if it's relative
if [[ "$CONFIG_FILE" != /* ]]; then
    CONFIG_FILE="${PRODUCT_ROOT}/${CONFIG_FILE}"
fi

# Validate config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Source config parser
source "$MODULE_DIR/lib/config-parser.sh"

# Load product name only for initial setup (don't need full config yet)
PRODUCT_NAME=$(parse_yaml_key "product.name" "")

# Get Application Server SSH details
# We load these early since they're needed for all environments
APPLICATION_SERVER_HOST=$(parse_yaml_key ".servers.application.host" "")
APPLICATION_SERVER_USER=$(parse_yaml_key ".servers.application.user" "")
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

# Get containers for this product/environment from Application Server
CONTAINERS=$(ssh -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
    "docker ps -a --filter 'name=${CONTAINER_FILTER}' --format '{{.Names}}' | sort")

if [ -z "$CONTAINERS" ]; then
    echo -e "${YELLOW}No containers found for ${PRODUCT_NAME}${NC}"
    echo ""
    echo "To deploy:"
    echo "  ./deploy.sh production"
    echo "  ./deploy.sh staging"
    exit 0
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

    ssh -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" bash <<EOF_DETAILED
CONTAINER="$container"

# Basic info
STATUS=\$(docker inspect --format='{{.State.Status}}' "\$CONTAINER" 2>/dev/null)
HEALTH=\$(docker inspect --format='{{.State.Health.Status}}' "\$CONTAINER" 2>/dev/null)
[ "\$HEALTH" == "<no value>" ] && HEALTH="N/A"
CREATED=\$(docker inspect --format='{{.Created}}' "\$CONTAINER" | cut -d'.' -f1)
STARTED=\$(docker inspect --format='{{.State.StartedAt}}' "\$CONTAINER" | cut -d'.' -f1)

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Status icon
if [ "\$STATUS" == "running" ]; then
    STATUS_ICON="\${GREEN}✓"
    [ "\$HEALTH" == "healthy" ] && STATUS_TEXT="Running (Healthy)"
    [ "\$HEALTH" == "unhealthy" ] && STATUS_TEXT="Running (Unhealthy)" && STATUS_ICON="\${YELLOW}⚠"
    [ "\$HEALTH" == "N/A" ] && STATUS_TEXT="Running"
else
    STATUS_ICON="\${RED}✗"
    STATUS_TEXT="\${STATUS}"
fi

echo -e "Status: \${STATUS_ICON} \${STATUS_TEXT}\${NC}"

# Uptime
if [ "\$STATUS" == "running" ]; then
    UPTIME=\$(docker inspect --format='{{.State.StartedAt}}' "\$CONTAINER")
    echo -e "Uptime: \${CYAN}\$(TZ=UTC date -d "\$UPTIME" '+%Y-%m-%d %H:%M:%S UTC')\${NC}"
fi

echo ""

# Image info
echo -e "\${CYAN}IMAGE & VERSION:\${NC}"
IMAGE=\$(docker inspect --format='{{.Config.Image}}' "\$CONTAINER")
IMAGE_ID=\$(docker inspect --format='{{.Image}}' "\$CONTAINER" | cut -d':' -f2 | cut -c1-12)
TAG=\$(echo "\$IMAGE" | cut -d':' -f2)
echo -e "  Image: \${IMAGE}"
echo -e "  Image ID: \${IMAGE_ID}"
echo -e "  Tag: \${TAG}"
echo -e "  Created: \${CREATED}"
echo ""

# Network & Ports
echo -e "\${CYAN}NETWORK & PORTS:\${NC}"
PORTS=\$(docker inspect --format='{{range \$p, \$conf := .NetworkSettings.Ports}}{{if \$conf}}{{\$p}} -> {{(index \$conf 0).HostPort}} {{end}}{{end}}' "\$CONTAINER")
NETWORK=\$(docker inspect --format='{{range \$net, \$conf := .NetworkSettings.Networks}}{{\$net}}{{end}}' "\$CONTAINER")
IP=\$(docker inspect --format='{{range \$net, \$conf := .NetworkSettings.Networks}}{{\$conf.IPAddress}}{{end}}' "\$CONTAINER")

echo -e "  Port Mapping: \${PORTS:-None}"
echo -e "  Networks: \${NETWORK:-None}"
echo -e "  IP Address: \${IP:-None}"
echo ""

# Resources
if [ "\$STATUS" == "running" ]; then
    echo -e "\${CYAN}RESOURCES:\${NC}"
    docker stats --no-stream --format "  CPU Usage: {{.CPUPerc}}\n  Memory Usage: {{.MemUsage}}" "\$CONTAINER"
    echo ""
fi

# Health check
if [ "\$HEALTH" != "N/A" ]; then
    echo -e "\${CYAN}HEALTH CHECK:\${NC}"
    HEALTH_TEST=\$(docker inspect --format='{{range .Config.Healthcheck.Test}}{{.}} {{end}}' "\$CONTAINER")
    echo -e "  Status: \${HEALTH}"
    echo -e "  Test: \${HEALTH_TEST}"
    echo ""
fi

# Environment variables (count only, redacted)
ENV_COUNT=\$(docker inspect --format='{{range .Config.Env}}{{.}}
{{end}}' "\$CONTAINER" | wc -l)
echo -e "\${CYAN}ENVIRONMENT:\${NC}"
echo -e "  Variables: \${ENV_COUNT} set"
echo -e "  (Use --configuration to view details)"
echo ""

# Volumes
VOLUMES=\$(docker inspect --format='{{range \$vol, \$conf := .Mounts}}{{.Source}} → {{.Destination}}
{{end}}' "\$CONTAINER")
if [ -n "\$VOLUMES" ]; then
    echo -e "\${CYAN}VOLUMES:\${NC}"
    echo "\$VOLUMES" | while read line; do
        [ -n "\$line" ] && echo -e "  \$line"
    done
    echo ""
fi

# Recent logs
if [ "\$STATUS" == "running" ]; then
    echo -e "\${CYAN}RECENT LOGS (last 10 lines):\${NC}"
    docker logs --tail 10 "\$CONTAINER" 2>&1 | sed 's/^/  /'
    echo ""
fi

EOF_DETAILED
    echo ""
}

# Function to show configuration details
show_configuration() {
    local container="$1"

    echo -e "${BLUE}==================================================${NC}"
    echo -e "${CYAN}Configuration: ${container}${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo ""

    ssh -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" bash <<EOF_CONFIG
CONTAINER="$container"

# Colors
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Environment Variables
echo -e "\${CYAN}Environment Variables:\${NC}"
docker inspect --format='{{range .Config.Env}}{{.}}
{{end}}' "\$CONTAINER" | while IFS='=' read -r key value; do
    if [[ "\$key" =~ (PASSWORD|SECRET|KEY|TOKEN|CREDENTIAL|AUTH) ]]; then
        echo -e "  \${key}=\${YELLOW}[REDACTED]\${NC}"
    else
        echo "  \${key}=\${value}"
    fi
done
echo ""

# Volumes
echo -e "\${CYAN}Volumes:\${NC}"
VOLUMES=\$(docker inspect --format='{{range \$vol, \$conf := .Mounts}}{{.Source}} → {{.Destination}}
{{end}}' "\$CONTAINER")
if [ -n "\$VOLUMES" ]; then
    echo "\$VOLUMES" | while read line; do
        [ -n "\$line" ] && echo "  \$line"
    done
else
    echo "  None"
fi
echo ""

# Network
echo -e "\${CYAN}Network:\${NC}"
NETWORK=\$(docker inspect --format='{{range \$net, \$conf := .NetworkSettings.Networks}}{{\$net}}{{end}}' "\$CONTAINER")
IP=\$(docker inspect --format='{{range \$net, \$conf := .NetworkSettings.Networks}}{{\$conf.IPAddress}}{{end}}' "\$CONTAINER")
PORTS=\$(docker inspect --format='{{range \$p, \$conf := .NetworkSettings.Ports}}{{if \$conf}}{{\$p}} -> {{(index \$conf 0).HostPort}} {{end}}{{end}}' "\$CONTAINER")

echo -e "  Mode: \${NETWORK:-bridge}"
echo -e "  IP: \${IP:-None}"
echo -e "  Ports: \${PORTS:-None}"
echo ""

EOF_CONFIG
}

# Function to show health check details
show_health() {
    local container="$1"

    echo -e "${BLUE}==================================================${NC}"
    echo -e "${CYAN}Health Check: ${container}${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo ""

    ssh -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" bash <<EOF_HEALTH
CONTAINER="$container"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

HEALTH_STATUS=\$(docker inspect --format='{{.State.Health.Status}}' "\$CONTAINER" 2>/dev/null)

if [ "\$HEALTH_STATUS" == "<no value>" ] || [ -z "\$HEALTH_STATUS" ]; then
    echo -e "\${YELLOW}No health check configured for this container\${NC}"
    echo ""
    exit 0
fi

# Status icon
case "\$HEALTH_STATUS" in
    healthy) STATUS_ICON="\${GREEN}✓"; STATUS_TEXT="Healthy" ;;
    unhealthy) STATUS_ICON="\${RED}✗"; STATUS_TEXT="Unhealthy" ;;
    starting) STATUS_ICON="\${YELLOW}⚠"; STATUS_TEXT="Starting" ;;
    *) STATUS_ICON="\${YELLOW}?"; STATUS_TEXT="\$HEALTH_STATUS" ;;
esac

echo -e "Overall Status: \${STATUS_ICON} \${STATUS_TEXT}\${NC}"
echo ""

# Health check configuration
echo -e "\${CYAN}Health Check Configuration:\${NC}"
TEST=\$(docker inspect --format='{{range .Config.Healthcheck.Test}}{{.}} {{end}}' "\$CONTAINER")
INTERVAL=\$(docker inspect --format='{{.Config.Healthcheck.Interval}}' "\$CONTAINER")
TIMEOUT=\$(docker inspect --format='{{.Config.Healthcheck.Timeout}}' "\$CONTAINER")
RETRIES=\$(docker inspect --format='{{.Config.Healthcheck.Retries}}' "\$CONTAINER")
START_PERIOD=\$(docker inspect --format='{{.Config.Healthcheck.StartPeriod}}' "\$CONTAINER")

echo -e "  Test: \${TEST}"
echo -e "  Interval: \${INTERVAL}"
echo -e "  Timeout: \${TIMEOUT}"
echo -e "  Retries: \${RETRIES}"
echo -e "  Start Period: \${START_PERIOD}"
echo ""

# Recent health check results
echo -e "\${CYAN}Recent Health Checks (last 5):\${NC}"
docker inspect --format='{{range .State.Health.Log}}{{.Start}} - {{.ExitCode}}
{{end}}' "\$CONTAINER" | tail -5 | while read line; do
    if [ -n "\$line" ]; then
        TIMESTAMP=\$(echo "\$line" | cut -d' ' -f1)
        EXIT_CODE=\$(echo "\$line" | awk '{print \$NF}')

        if [ "\$EXIT_CODE" == "0" ]; then
            echo -e "  [\${TIMESTAMP}] \${GREEN}✓ Passed\${NC}"
        else
            echo -e "  [\${TIMESTAMP}] \${RED}✗ Failed (exit code: \${EXIT_CODE})\${NC}"
        fi
    fi
done
echo ""

EOF_HEALTH
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
ssh -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
    "docker ps -a --filter 'name=${CONTAINER_FILTER}' \
     --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
echo ""

# Detailed status
echo -e "${CYAN}Detailed Status:${NC}"
echo ""

# Get detailed info for all containers in one SSH call
CONTAINER_DETAILS=$(ssh -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" bash <<'EOF_REMOTE'
CONTAINER_FILTER="'"$CONTAINER_FILTER"'"
CONTAINERS=$(docker ps -a --filter "name=${CONTAINER_FILTER}" --format "{{.Names}}" | sort)

for CONTAINER in $CONTAINERS; do
    # Parse environment from container name
    if [[ $CONTAINER == *"production"* ]]; then
        ENV="PRODUCTION"
    elif [[ $CONTAINER == *"staging"* ]]; then
        ENV="STAGING"
    else
        ENV="UNKNOWN"
    fi

    # Get container details
    STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null)
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)
    [ "$HEALTH" == "<no value>" ] && HEALTH="N/A"

    IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER" 2>/dev/null)
    IMAGE_TAG=$(echo "$IMAGE" | cut -d':' -f2)

    STARTED=""
    if [ "$STATUS" == "running" ]; then
        STARTED=$(docker inspect --format='{{.State.StartedAt}}' "$CONTAINER" | cut -d'.' -f1)
    fi

    # Output in parseable format
    echo "CONTAINER:${CONTAINER}|ENV:${ENV}|STATUS:${STATUS}|HEALTH:${HEALTH}|IMAGE_TAG:${IMAGE_TAG}|STARTED:${STARTED}"
done
EOF_REMOTE
)

# Parse and display the details
while IFS= read -r LINE; do
    if [ -z "$LINE" ]; then
        continue
    fi

    # Parse the line
    CONTAINER=$(echo "$LINE" | grep -oP 'CONTAINER:\K[^|]+')
    ENV=$(echo "$LINE" | grep -oP 'ENV:\K[^|]+')
    STATUS=$(echo "$LINE" | grep -oP 'STATUS:\K[^|]+')
    HEALTH=$(echo "$LINE" | grep -oP 'HEALTH:\K[^|]+')
    IMAGE_TAG=$(echo "$LINE" | grep -oP 'IMAGE_TAG:\K[^|]+')
    STARTED=$(echo "$LINE" | grep -oP 'STARTED:\K[^|]+')

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
done <<< "$CONTAINER_DETAILS"

# Resource usage
echo -e "${CYAN}Resource Usage:${NC}"
echo ""

# Get container names and pass them directly to docker stats
# (--filter not supported in older Docker versions)
# Convert newlines to spaces so they're passed as separate arguments, not separate commands
CONTAINER_NAMES=$(ssh -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
    "docker ps --filter 'name=${CONTAINER_FILTER}' --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')

if [ -n "$CONTAINER_NAMES" ]; then
    ssh -i "$APPLICATION_SERVER_SSH_KEY" "$APP_SERVER" \
        "docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}' ${CONTAINER_NAMES}"
else
    echo -e "${YELLOW}No running containers to show stats${NC}"
fi
echo ""
