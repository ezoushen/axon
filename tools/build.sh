#!/bin/bash
# Build Docker image locally
# Product-agnostic version - uses deploy.config.yml

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRODUCT_ROOT="$(cd "$MODULE_DIR/.." && pwd)"

# Default values
CONFIG_FILE="${PRODUCT_ROOT}/deploy.config.yml"
ENVIRONMENT=""
GIT_SHA_ARG=""
SKIP_GIT=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
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
            echo "  --skip-git           Skip git SHA tag"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment          Target environment (e.g., production, staging)"
            echo "  git-sha              Optional: specific git SHA to use"
            echo ""
            echo "Examples:"
            echo "  $0 production"
            echo "  $0 --config custom.yml staging"
            echo "  $0 production abc123"
            echo "  $0 --skip-git production"
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
            elif [ -z "$GIT_SHA_ARG" ]; then
                GIT_SHA_ARG="$1"
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

# Source the config parser
source "$MODULE_DIR/lib/config-parser.sh"

# Validate environment
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

# Check if we're in a git repository
if [ -d ".git" ] || git rev-parse --git-dir > /dev/null 2>&1; then
    IS_GIT_REPO=true
else
    IS_GIT_REPO=false
fi

# Handle git SHA
if [ "$SKIP_GIT" = true ]; then
    # Explicitly skip git SHA
    echo -e "${YELLOW}Skipping git SHA tag (--skip-git flag provided)${NC}"
    GIT_SHA=""
elif [ -n "$GIT_SHA_ARG" ]; then
    # User provided explicit SHA - use it regardless of uncommitted changes
    GIT_SHA="$GIT_SHA_ARG"
    echo -e "${YELLOW}Using provided git SHA: ${GIT_SHA}${NC}"
elif [ "$IS_GIT_REPO" = true ]; then
    # No SHA provided - auto-detect from git
    # Check for uncommitted changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo -e "${RED}Error: You have uncommitted changes${NC}"
        echo ""
        echo "Please commit your changes before building, or provide an explicit git SHA:"
        echo "  $0 --config $CONFIG_FILE $ENVIRONMENT <git-sha>"
        echo ""
        echo "Uncommitted changes:"
        git status --short
        exit 1
    fi

    # Get current commit SHA
    GIT_SHA=$(git rev-parse --short HEAD)
    echo -e "${GREEN}Auto-detected git SHA: ${GIT_SHA}${NC}"
else
    echo -e "${YELLOW}Warning: Not a git repository, skipping git SHA tag${NC}"
    GIT_SHA=""
fi

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Docker Build${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

# Load configuration from config file
# First validate environment exists
if ! validate_environment "$ENVIRONMENT" "$CONFIG_FILE"; then
    exit 1
fi

load_config "$ENVIRONMENT"

# Verify IMAGE_TAG matches environment (fallback parser might pick wrong one)
# Re-parse with explicit environment prefix to ensure correctness
if command -v yq &> /dev/null; then
    if [ -z "$IMAGE_TAG" ] || [ "$IMAGE_TAG" = "null" ]; then
        IMAGE_TAG="$ENVIRONMENT"  # Default to environment name
    fi
else
    echo -e "${YELLOW}Warning: yq not found. Using fallback parser.${NC}"
    echo -e "${YELLOW}For accurate YAML parsing, install yq: brew install yq${NC}"
    echo ""
    # Fallback: default to environment name
    IMAGE_TAG="$ENVIRONMENT"
fi

# Validate required AWS configuration
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo -e "${RED}Error: AWS account ID not configured${NC}"
    echo "Please set 'aws.account_id' in $CONFIG_FILE"
    exit 1
fi

if [ -z "$AWS_REGION" ]; then
    echo -e "${RED}Error: AWS region not configured${NC}"
    echo "Please set 'aws.region' in $CONFIG_FILE"
    exit 1
fi

if [ -z "$ECR_REPOSITORY" ]; then
    echo -e "${RED}Error: ECR repository not configured${NC}"
    echo "Please set 'aws.ecr_repository' in $CONFIG_FILE"
    exit 1
fi

# Build variables
ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
FULL_IMAGE_NAME="${ECR_URL}/${ECR_REPOSITORY}:${IMAGE_TAG}"

# Display build info
echo -e "Product:        ${YELLOW}${PRODUCT_NAME}${NC}"
echo -e "Environment:    ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "ECR Repository: ${YELLOW}${ECR_REPOSITORY}${NC}"
echo -e "Image Tag:      ${YELLOW}${IMAGE_TAG}${NC}"
[ -n "$GIT_SHA" ] && echo -e "Git SHA Tag:    ${YELLOW}${GIT_SHA}${NC}"
echo -e "Full Image:     ${YELLOW}${FULL_IMAGE_NAME}${NC}"
echo ""

# Check prerequisites
if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker is not running${NC}"
    exit 1
fi

# Check if Dockerfile exists
if [ ! -f "$PRODUCT_ROOT/$DOCKERFILE_PATH" ]; then
    echo -e "${RED}Error: Dockerfile not found: $PRODUCT_ROOT/$DOCKERFILE_PATH${NC}"
    echo "Please check docker.dockerfile in $CONFIG_FILE"
    exit 1
fi

# Build Docker image
echo -e "${GREEN}Building Docker image...${NC}"
echo -e "Using Dockerfile: ${YELLOW}${DOCKERFILE_PATH}${NC}"
echo -e "${YELLOW}This may take a few minutes...${NC}"
echo ""

cd "$PRODUCT_ROOT"

docker build \
    --build-arg BUILD_STANDALONE=true \
    --platform linux/amd64 \
    -f "$DOCKERFILE_PATH" \
    -t "$FULL_IMAGE_NAME" \
    .

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Docker build failed${NC}"
    exit 1
fi

# Tag image with git SHA if provided
if [ -n "$GIT_SHA" ]; then
    echo ""
    echo -e "${GREEN}Tagging image with git SHA...${NC}"
    GIT_SHA_IMAGE="${ECR_URL}/${ECR_REPOSITORY}:${GIT_SHA}"
    docker tag "$FULL_IMAGE_NAME" "$GIT_SHA_IMAGE"
    echo -e "Tagged as: ${YELLOW}${GIT_SHA_IMAGE}${NC}"
fi

# Success
echo ""
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}Build completed successfully!${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""

echo "Image(s) built:"
echo -e "  ${YELLOW}${FULL_IMAGE_NAME}${NC}"
if [ -n "$GIT_SHA" ]; then
    echo -e "  ${YELLOW}${GIT_SHA_IMAGE}${NC}"
fi

IMAGE_SIZE=$(docker images "$FULL_IMAGE_NAME" --format "{{.Size}}")
echo ""
echo -e "Image size: ${YELLOW}${IMAGE_SIZE}${NC}"
echo ""
echo "Next steps:"
echo "  Push to ECR: ./tools/push.sh ${ENVIRONMENT}"
if [ -n "$GIT_SHA" ]; then
    echo "               ./tools/push.sh ${ENVIRONMENT} ${GIT_SHA}"
fi
echo "  Deploy: ./tools/deploy.sh ${ENVIRONMENT}"
echo ""

# Output git SHA for capture by parent script (e.g., axon)
# Format: GIT_SHA_DETECTED=<sha>
if [ -n "$GIT_SHA" ]; then
    echo "GIT_SHA_DETECTED=${GIT_SHA}"
fi
