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
SECOND_ARG=${2}
GIT_SHA_OR_FLAG=""

if [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment parameter required${NC}"
    echo ""
    echo "Usage: $0 <environment> [git-sha|--skip-build|--skip-git]"
    echo ""
    echo "Examples:"
    echo "  $0 production              # Auto-detect git SHA, build, push, and deploy"
    echo "  $0 staging abc123          # Use specific git SHA, build, push, and deploy"
    echo "  $0 staging --skip-git      # Build without git SHA tag"
    echo "  $0 staging --skip-build    # Skip build, only deploy (use existing image)"
    exit 1
fi

# Determine if we're skipping build or passing git SHA
if [ "$SECOND_ARG" = "--skip-build" ]; then
    SKIP_BUILD=true
    GIT_SHA_OR_FLAG=""
else
    SKIP_BUILD=false
    GIT_SHA_OR_FLAG="$SECOND_ARG"  # Could be git SHA, --skip-git, or empty
fi

echo -e "${CYAN}===========================================================${NC}"
echo -e "${CYAN}Full Deployment Pipeline: ${ENVIRONMENT}${NC}"
echo -e "${CYAN}Build → Push to ECR → Zero-Downtime Deploy${NC}"
echo -e "${CYAN}===========================================================${NC}"
echo ""

# Step 1: Build and Push (unless skipped)
if [ "$SKIP_BUILD" = true ]; then
    echo -e "${YELLOW}⏭  Skipping build and push (--skip-build flag provided)${NC}"
    echo ""
else
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Step 1/2: Build and Push to ECR${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Call build-and-push.sh with optional git SHA argument
    if [ -n "$GIT_SHA_OR_FLAG" ]; then
        "$SCRIPT_DIR/scripts/build-and-push.sh" "$ENVIRONMENT" "$GIT_SHA_OR_FLAG"
    else
        "$SCRIPT_DIR/scripts/build-and-push.sh" "$ENVIRONMENT"
    fi

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
if [ "$SKIP_BUILD" = true ]; then
    echo -e "  Build:       ${YELLOW}Skipped${NC}"
else
    echo -e "  Build:       ${GREEN}✓ Completed${NC}"
    if [ -n "$GIT_SHA_OR_FLAG" ]; then
        if [ "$GIT_SHA_OR_FLAG" = "--skip-git" ]; then
            echo -e "  Git SHA:     ${YELLOW}Skipped${NC}"
        else
            echo -e "  Git SHA:     ${YELLOW}${GIT_SHA_OR_FLAG}${NC}"
        fi
    else
        echo -e "  Git SHA:     ${GREEN}Auto-detected${NC}"
    fi
fi
echo -e "  Deployment:  ${GREEN}✓ Completed${NC}"
echo -e "  Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "  Downtime:    ${GREEN}0 seconds${NC} ⚡"
echo ""

exit 0
