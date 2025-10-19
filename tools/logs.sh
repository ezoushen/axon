#!/bin/bash
# View logs for specific environment or all containers
# Supports following logs in real-time

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
ENVIRONMENT=${1}
FOLLOW=${2}
PRODUCT_NAME=${3}

# Show usage if no arguments
if [ -z "$ENVIRONMENT" ]; then
  echo -e "${BLUE}View Docker Container Logs${NC}"
  echo ""
  echo "Usage:"
  echo "  $0 <environment> [follow] [product_name]"
  echo ""
  echo "Arguments:"
  echo "  environment    Any environment from axon.config.yml or 'all'"
  echo "  follow         Optional: 'follow' to stream logs in real-time"
  echo "  product_name   Optional: filter by specific product"
  echo ""
  echo "Examples:"
  echo "  $0 production           # Show last 50 lines"
  echo "  $0 staging              # Show last 50 lines"
  echo "  $0 development          # Show last 50 lines (custom env)"
  echo "  $0 all                  # Show all environments"
  echo "  $0 production follow    # Follow logs in real-time"
  exit 0
fi

# Note: Environment validation is not needed here
# The script accepts any environment name defined in axon.config.yml or "all"

# Check if Docker is running
if ! docker info &> /dev/null 2>&1; then
  echo -e "${RED}Error: Docker is not running${NC}"
  exit 1
fi

# Function to show logs for an environment
show_logs() {
  local ENV=$1

  # Find the most recent container for this environment (sorted by name which includes timestamp)
  local CONTAINER=$(docker ps -a --filter "name=${PRODUCT_NAME}-${ENV}-" --format '{{.Names}}' | sort -r | head -n 1)

  # Check if container exists
  if [ -z "$CONTAINER" ]; then
    echo -e "${YELLOW}Warning: No ${ENV} container found (${PRODUCT_NAME}-${ENV})${NC}"
    return 1
  fi

  echo -e "${BLUE}Logs for ${ENV} environment:${NC}"
  echo -e "${BLUE}Container: ${CONTAINER}${NC}"
  echo ""

  if [ "$FOLLOW" == "follow" ]; then
    echo -e "${GREEN}Following logs (Ctrl+C to exit)...${NC}"
    echo ""
    docker logs -f --tail=100 "$CONTAINER"
  else
    docker logs --tail=50 "$CONTAINER"
  fi
}

# Main logic
if [ "$ENVIRONMENT" == "all" ]; then
  echo -e "${BLUE}==================================================${NC}"
  echo -e "${BLUE}All Container Logs${NC}"
  echo -e "${BLUE}==================================================${NC}"
  echo ""

  if [ "$FOLLOW" == "follow" ]; then
    echo -e "${GREEN}Following all logs (Ctrl+C to exit)...${NC}"
    echo ""
    # Get all containers and follow them
    CONTAINERS=$(docker ps -a --filter "name=${PRODUCT_NAME}-" --format '{{.Names}}' | sort -r)
    if [ -z "$CONTAINERS" ]; then
      echo -e "${YELLOW}No containers found${NC}"
      exit 0
    fi

    # Follow logs from all containers (Docker will multiplex them)
    docker logs -f --tail=100 $(echo $CONTAINERS | tr '\n' ' ')
  else
    # Show production logs
    show_logs "production"
    echo ""
    echo -e "${BLUE}---------------------------------------------------${NC}"
    echo ""
    # Show staging logs
    show_logs "staging"
  fi
else
  show_logs "$ENVIRONMENT"
fi
