#!/bin/bash
# Full deployment pipeline: Build → Push → Deploy (Zero-Downtime)
# Runs from LOCAL MACHINE
#
# Usage: ./deploy-full.sh <environment> [--skip-build]
# Example: ./deploy-full.sh production
# Example: ./deploy-full.sh staging --skip-build  # Skip build if image already pushed

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

# Parse arguments
ENVIRONMENT=${1}
SKIP_BUILD=${2}

if [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment parameter required${NC}"
    echo ""
    echo "Usage: $0 <environment> [--skip-build]"
    echo ""
    echo "Examples:"
    echo "  $0 production              # Build, push, and deploy"
    echo "  $0 staging --skip-build    # Skip build, only deploy"
    exit 1
fi

echo -e "${CYAN}===========================================================${NC}"
echo -e "${CYAN}Full Deployment Pipeline: ${ENVIRONMENT}${NC}"
echo -e "${CYAN}Build → Push to ECR → Zero-Downtime Deploy${NC}"
echo -e "${CYAN}===========================================================${NC}"
echo ""

# Step 1: Build and Push (unless skipped)
if [ "$SKIP_BUILD" == "--skip-build" ]; then
    echo -e "${YELLOW}⏭  Skipping build and push (--skip-build flag provided)${NC}"
    echo ""
else
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Step 1/2: Build and Push to ECR${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    "$SCRIPT_DIR/scripts/build-and-push.sh" "$ENVIRONMENT"

    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ Build and push failed!${NC}"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}✓ Build and push completed successfully!${NC}"
    echo ""
fi

# Step 2: Deploy with Zero-Downtime
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 2/2: Zero-Downtime Deployment${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

"$SCRIPT_DIR/deploy.sh" "$ENVIRONMENT"

if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Deployment failed!${NC}"
    exit 1
fi

# Success!
echo ""
echo -e "${GREEN}===========================================================${NC}"
echo -e "${GREEN}✓ Full deployment pipeline completed successfully!${NC}"
echo -e "${GREEN}===========================================================${NC}"
echo ""

echo -e "${CYAN}Summary:${NC}"
if [ "$SKIP_BUILD" == "--skip-build" ]; then
    echo -e "  Build:       ${YELLOW}Skipped${NC}"
else
    echo -e "  Build:       ${GREEN}✓ Completed${NC}"
fi
echo -e "  Deployment:  ${GREEN}✓ Completed${NC}"
echo -e "  Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "  Downtime:    ${GREEN}0 seconds${NC} ⚡"
echo ""

exit 0
