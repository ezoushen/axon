#!/bin/bash
# AXON - Full deployment pipeline: Build → Push → Deploy (Zero-Downtime)
# Runs from LOCAL MACHINE
#
# Usage: ./axon.sh [OPTIONS] <environment>
# Example: ./axon.sh production
# Example: ./axon.sh --skip-build staging
# Example: ./axon.sh --config custom.yml production abc123

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

# Default values
CONFIG_FILE="deploy.config.yml"
SKIP_BUILD=false
SKIP_PUSH=false
SKIP_GIT=false
ENVIRONMENT=""
GIT_SHA=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            SKIP_PUSH=true  # If skipping build, must skip push too
            shift
            ;;
        --skip-push)
            SKIP_PUSH=true
            shift
            ;;
        --skip-git)
            SKIP_GIT=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] <environment> [git-sha]"
            echo ""
            echo "Options:"
            echo "  -c, --config FILE    Specify config file (default: deploy.config.yml)"
            echo "  --skip-build         Skip build and push, only deploy"
            echo "  --skip-push          Skip push, only build and deploy (local image)"
            echo "  --skip-git           Build without git SHA tag"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment          Target environment (e.g., production, staging)"
            echo "  git-sha              Optional: specific git SHA to use"
            echo ""
            echo "Examples:"
            echo "  $0 production                        # Build → Push → Deploy"
            echo "  $0 --skip-build staging              # Deploy only (use existing image)"
            echo "  $0 --skip-push production            # Build → Deploy (no ECR push)"
            echo "  $0 --config custom.yml production    # Use custom config"
            echo "  $0 production abc123                 # Build with specific git SHA"
            echo "  $0 --skip-git staging                # Build without git SHA tag"
            exit 0
            ;;
        -*)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
        *)
            # Positional arguments
            if [ -z "$ENVIRONMENT" ]; then
                ENVIRONMENT="$1"
            elif [ -z "$GIT_SHA" ]; then
                GIT_SHA="$1"
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
if [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment parameter required${NC}"
    echo "Use --help for usage information"
    exit 1
fi

# Validate config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi

echo -e "${CYAN}===========================================================${NC}"
echo -e "${CYAN}AXON - Full Deployment Pipeline: ${ENVIRONMENT}${NC}"
echo -e "${CYAN}Build → Push to ECR → Zero-Downtime Deploy${NC}"
echo -e "${CYAN}Config: ${CONFIG_FILE}${NC}"
echo -e "${CYAN}===========================================================${NC}"
echo ""

# Step 1: Build (unless skipped)
if [ "$SKIP_BUILD" = true ]; then
    echo -e "${YELLOW}⏭  Skipping build and push (--skip-build flag provided)${NC}"
    echo ""
else
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$SKIP_PUSH" = true ]; then
        echo -e "${BLUE}Step 1/2: Build Docker Image${NC}"
    else
        echo -e "${BLUE}Step 1/3: Build Docker Image${NC}"
    fi
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Build arguments for build.sh
    BUILD_ARGS=("--config" "$CONFIG_FILE" "$ENVIRONMENT")

    if [ "$SKIP_GIT" = true ]; then
        BUILD_ARGS+=("--skip-git")
    elif [ -n "$GIT_SHA" ]; then
        BUILD_ARGS+=("$GIT_SHA")
    fi

    "$SCRIPT_DIR/tools/build.sh" "${BUILD_ARGS[@]}"

    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ Build failed!${NC}"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}✓ Build completed successfully!${NC}"
    echo ""
fi

# Step 2: Push (unless skipped)
if [ "$SKIP_PUSH" = true ]; then
    if [ "$SKIP_BUILD" = false ]; then
        echo -e "${YELLOW}⏭  Skipping push to ECR (--skip-push flag provided)${NC}"
        echo ""
    fi
else
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Step 2/3: Push to AWS ECR${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Push arguments
    PUSH_ARGS=("--config" "$CONFIG_FILE" "$ENVIRONMENT")

    if [ -n "$GIT_SHA" ] && [ "$SKIP_GIT" = false ]; then
        PUSH_ARGS+=("$GIT_SHA")
    fi

    "$SCRIPT_DIR/tools/push.sh" "${PUSH_ARGS[@]}"

    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ Push failed!${NC}"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}✓ Push completed successfully!${NC}"
    echo ""
fi

# Step 3: Deploy with Zero-Downtime
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$SKIP_BUILD" = true ]; then
    echo -e "${BLUE}Step 1/1: Zero-Downtime Deployment${NC}"
elif [ "$SKIP_PUSH" = true ]; then
    echo -e "${BLUE}Step 2/2: Zero-Downtime Deployment${NC}"
else
    echo -e "${BLUE}Step 3/3: Zero-Downtime Deployment${NC}"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

"$SCRIPT_DIR/tools/deploy.sh" --config "$CONFIG_FILE" "$ENVIRONMENT"

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
echo -e "  Config:      ${YELLOW}${CONFIG_FILE}${NC}"
if [ "$SKIP_BUILD" = true ]; then
    echo -e "  Build:       ${YELLOW}Skipped${NC}"
    echo -e "  Push:        ${YELLOW}Skipped${NC}"
else
    echo -e "  Build:       ${GREEN}✓ Completed${NC}"
    if [ "$SKIP_GIT" = true ]; then
        echo -e "  Git SHA:     ${YELLOW}Skipped${NC}"
    elif [ -n "$GIT_SHA" ]; then
        echo -e "  Git SHA:     ${YELLOW}${GIT_SHA}${NC}"
    else
        echo -e "  Git SHA:     ${GREEN}Auto-detected${NC}"
    fi
    if [ "$SKIP_PUSH" = true ]; then
        echo -e "  Push:        ${YELLOW}Skipped${NC}"
    else
        echo -e "  Push:        ${GREEN}✓ Completed${NC}"
    fi
fi
echo -e "  Deployment:  ${GREEN}✓ Completed${NC}"
echo -e "  Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "  Downtime:    ${GREEN}0 seconds${NC} ⚡"
echo ""

exit 0
