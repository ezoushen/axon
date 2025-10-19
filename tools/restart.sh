#!/bin/bash
# Restart specific environment or all containers
# Performs graceful restart without downtime

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
ENVIRONMENT=${1}
PRODUCT_NAME=${2:-linebot-nextjs}

# Show usage if no arguments
if [ -z "$ENVIRONMENT" ]; then
  echo -e "${BLUE}Restart Docker Containers${NC}"
  echo ""
  echo "Usage:"
  echo "  $0 <environment> [product_name]"
  echo ""
  echo "Examples:"
  echo "  $0 production    # Restart production container only"
  echo "  $0 staging       # Restart staging container only"
  echo "  $0 all           # Restart all containers"
  exit 0
fi

# Validate environment
if [ "$ENVIRONMENT" != "production" ] && [ "$ENVIRONMENT" != "staging" ] && [ "$ENVIRONMENT" != "all" ]; then
  echo -e "${RED}Error: Environment must be 'production', 'staging', or 'all'${NC}"
  exit 1
fi

# Check if Docker is running
if ! docker info &> /dev/null 2>&1; then
  echo -e "${RED}Error: Docker is not running${NC}"
  exit 1
fi

# Function to restart an environment
restart_environment() {
  local ENV=$1

  # Find the most recent container for this environment (sorted by name which includes timestamp)
  local CONTAINER=$(docker ps -a --filter "name=${PRODUCT_NAME}-${ENV}-" --format '{{.Names}}' | sort -r | head -n 1)

  # Check if container exists
  if [ -z "$CONTAINER" ]; then
    echo -e "${YELLOW}Warning: No ${ENV} container found (${PRODUCT_NAME}-${ENV})${NC}"
    return 1
  fi

  echo -e "${BLUE}Restarting ${ENV} environment...${NC}"
  echo -e "Container: ${YELLOW}${CONTAINER}${NC}"
  echo ""

  docker restart "$CONTAINER"

  if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ ${ENV} container restarted successfully${NC}"

    # Wait a moment for container to start
    sleep 3

    # Show status
    echo ""
    echo -e "${BLUE}Container status:${NC}"
    docker ps --filter "name=$CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    return 0
  else
    echo -e "${RED}✗ Failed to restart ${ENV} container${NC}"
    return 1
  fi
}

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Restart Docker Containers${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

# Main logic
if [ "$ENVIRONMENT" == "all" ]; then
  # Restart production
  restart_environment "production"
  PROD_RESULT=$?

  echo ""
  echo -e "${BLUE}---------------------------------------------------${NC}"
  echo ""

  # Restart staging
  restart_environment "staging"
  STAGING_RESULT=$?

  echo ""
  echo -e "${BLUE}==================================================${NC}"
  echo -e "${BLUE}Restart Summary${NC}"
  echo -e "${BLUE}==================================================${NC}"

  if [ $PROD_RESULT -eq 0 ]; then
    echo -e "${GREEN}✓ Production: Restarted${NC}"
  else
    echo -e "${RED}✗ Production: Failed${NC}"
  fi

  if [ $STAGING_RESULT -eq 0 ]; then
    echo -e "${GREEN}✓ Staging: Restarted${NC}"
  else
    echo -e "${RED}✗ Staging: Failed${NC}"
  fi
  echo ""

  # Show all containers
  echo -e "${BLUE}All Containers:${NC}"
  docker ps --filter "name=${PRODUCT_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  echo ""

  if [ $PROD_RESULT -ne 0 ] || [ $STAGING_RESULT -ne 0 ]; then
    exit 1
  fi
else
  restart_environment "$ENVIRONMENT"
  exit $?
fi
