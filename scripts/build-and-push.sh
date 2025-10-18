#!/bin/bash
# Build Docker image locally and push to AWS ECR
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
CONFIG_FILE="${PRODUCT_ROOT}/deploy.config.yml"

# Source the config parser
source "$MODULE_DIR/lib/config-parser.sh"

# Parse arguments
ENVIRONMENT=${1}
GIT_SHA_ARG=${2}  # User-provided SHA (optional)

# Validate environment
if [ -z "$ENVIRONMENT" ]; then
    echo -e "${RED}Error: Environment parameter required${NC}"
    echo ""
    echo "Usage: $0 <environment> [git-sha]"
    echo ""
    echo "Examples:"
    echo "  $0 production                 # Auto-detect git SHA"
    echo "  $0 staging                    # Auto-detect git SHA"
    echo "  $0 production abc123          # Use specific git SHA"
    echo "  $0 production --skip-git      # Skip git SHA (build only with env tag)"
    exit 1
fi

# Check if we're in a git repository
if [ -d ".git" ] || git rev-parse --git-dir > /dev/null 2>&1; then
    IS_GIT_REPO=true
else
    IS_GIT_REPO=false
fi

# Handle git SHA
if [ -z "$GIT_SHA_ARG" ]; then
    # No SHA provided - auto-detect from git
    if [ "$IS_GIT_REPO" = true ]; then
        # Check for uncommitted changes
        if ! git diff-index --quiet HEAD -- 2>/dev/null; then
            echo -e "${RED}Error: You have uncommitted changes${NC}"
            echo ""
            echo "Please commit your changes before building, or provide an explicit git SHA:"
            echo "  $0 $ENVIRONMENT <git-sha>"
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
elif [ "$GIT_SHA_ARG" = "--skip-git" ]; then
    # Explicitly skip git SHA
    GIT_SHA=""
else
    # User provided explicit SHA - use it regardless of uncommitted changes
    GIT_SHA="$GIT_SHA_ARG"
    echo -e "${YELLOW}Using provided git SHA: ${GIT_SHA}${NC}"
fi

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Docker Build and Push to AWS ECR${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

# Load configuration
load_config "$ENVIRONMENT"

# Verify IMAGE_TAG matches environment (fallback parser might pick wrong one)
# Re-parse with explicit environment prefix to ensure correctness
if command -v yq &> /dev/null; then
    IMAGE_TAG=$(yq eval ".environments.${ENVIRONMENT}.image_tag" "$CONFIG_FILE" 2>/dev/null)
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

# Load product env file
ENV_FILE="${PRODUCT_ROOT}/${ENV_FILE_PATH}"
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: Environment file not found: $ENV_FILE${NC}"
    exit 1
fi

export $(cat "$ENV_FILE" | grep -v '^#' | xargs)

# Build variables
ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
FULL_IMAGE_NAME="${ECR_URL}/${ECR_REPOSITORY}:${IMAGE_TAG}"

# Display build info
echo -e "Product:        ${YELLOW}${PRODUCT_NAME}${NC}"
echo -e "Environment:    ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "AWS Profile:    ${YELLOW}${AWS_PROFILE}${NC}"
echo -e "AWS Region:     ${YELLOW}${AWS_REGION}${NC}"
echo -e "ECR Repository: ${YELLOW}${ECR_REPOSITORY}${NC}"
echo -e "Image Tag:      ${YELLOW}${IMAGE_TAG}${NC}"
[ -n "$GIT_SHA" ] && echo -e "Git SHA Tag:    ${YELLOW}${GIT_SHA}${NC}"
echo -e "Full Image:     ${YELLOW}${FULL_IMAGE_NAME}${NC}"
echo ""

# Check prerequisites
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed${NC}"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker is not running${NC}"
    exit 1
fi

# Authenticate with ECR
echo -e "${GREEN}Step 1/5: Authenticating with AWS ECR...${NC}"
aws ecr get-login-password --region "$AWS_REGION" --profile "$AWS_PROFILE" | \
    docker login --username AWS --password-stdin "$ECR_URL"

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to authenticate with AWS ECR${NC}"
    exit 1
fi

# Create repository if not exists
echo -e "${GREEN}Step 2/5: Creating ECR repository (if not exists)...${NC}"
aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" &> /dev/null || \
    aws ecr create-repository \
        --repository-name "$ECR_REPOSITORY" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256

# Build Docker image
echo -e "${GREEN}Step 3/5: Building Docker image...${NC}"
echo -e "${YELLOW}This may take a few minutes...${NC}"

cd "$PRODUCT_ROOT"

docker build \
    --build-arg BUILD_STANDALONE=true \
    --platform linux/amd64 \
    -t "$FULL_IMAGE_NAME" \
    .

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Docker build failed${NC}"
    exit 1
fi

# Tag image
echo -e "${GREEN}Step 4/5: Tagging image...${NC}"
IMAGES_TO_PUSH=("$FULL_IMAGE_NAME")

if [ -n "$GIT_SHA" ]; then
    GIT_SHA_IMAGE="${ECR_URL}/${ECR_REPOSITORY}:${GIT_SHA}"
    docker tag "$FULL_IMAGE_NAME" "$GIT_SHA_IMAGE"
    IMAGES_TO_PUSH+=("$GIT_SHA_IMAGE")
    echo -e "Tagged as: ${YELLOW}${GIT_SHA_IMAGE}${NC}"
fi

# Push to ECR
echo -e "${GREEN}Step 5/5: Pushing image(s) to AWS ECR...${NC}"
echo -e "${YELLOW}This may take a few minutes...${NC}"

for IMAGE in "${IMAGES_TO_PUSH[@]}"; do
    echo -e "Pushing: ${YELLOW}${IMAGE}${NC}"
    docker push "$IMAGE"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to push image to ECR${NC}"
        exit 1
    fi
done

# Success
echo ""
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}Build and push completed successfully!${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
echo "Image(s) pushed to ECR:"
for IMAGE in "${IMAGES_TO_PUSH[@]}"; do
    echo -e "  ${YELLOW}${IMAGE}${NC}"
done

IMAGE_SIZE=$(docker images "$FULL_IMAGE_NAME" --format "{{.Size}}")
echo ""
echo -e "Image size: ${YELLOW}${IMAGE_SIZE}${NC}"
echo ""
echo "Next steps:"
echo "  Deploy to ${ENVIRONMENT}: ./deploy/deploy.sh ${ENVIRONMENT}"
echo ""
