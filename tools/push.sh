#!/bin/bash
# Push Docker image to AWS ECR
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
GIT_SHA=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] <environment> [git-sha]"
            echo ""
            echo "Options:"
            echo "  -c, --config FILE    Specify config file (default: deploy.config.yml)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Arguments:"
            echo "  environment          Target environment (e.g., production, staging)"
            echo "  git-sha              Optional: specific git SHA tag to push"
            echo ""
            echo "Examples:"
            echo "  $0 production"
            echo "  $0 --config custom.yml staging"
            echo "  $0 production abc123"
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

echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Push to AWS ECR${NC}"
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

# Display push info
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

# Check if image exists locally
if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${ECR_URL}/${ECR_REPOSITORY}:${IMAGE_TAG}$"; then
    echo -e "${RED}Error: Image not found locally: ${FULL_IMAGE_NAME}${NC}"
    echo ""
    echo "Please build the image first:"
    echo "  ./tools/build.sh ${ENVIRONMENT}"
    exit 1
fi

# Authenticate with ECR
echo -e "${GREEN}Step 1/3: Authenticating with AWS ECR...${NC}"
aws ecr get-login-password --region "$AWS_REGION" --profile "$AWS_PROFILE" | \
    docker login --username AWS --password-stdin "$ECR_URL"

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to authenticate with AWS ECR${NC}"
    exit 1
fi

# Create repository if not exists
echo -e "${GREEN}Step 2/3: Creating ECR repository (if not exists)...${NC}"
aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" &> /dev/null || \
    aws ecr create-repository \
        --repository-name "$ECR_REPOSITORY" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256

# Determine which images to push
IMAGES_TO_PUSH=("$FULL_IMAGE_NAME")

if [ -n "$GIT_SHA" ]; then
    GIT_SHA_IMAGE="${ECR_URL}/${ECR_REPOSITORY}:${GIT_SHA}"
    # Check if git SHA image exists locally
    if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${ECR_URL}/${ECR_REPOSITORY}:${GIT_SHA}$"; then
        IMAGES_TO_PUSH+=("$GIT_SHA_IMAGE")
    else
        echo -e "${YELLOW}Warning: Git SHA image not found locally: ${GIT_SHA_IMAGE}${NC}"
        echo -e "${YELLOW}Only pushing environment tag${NC}"
    fi
fi

# Push to ECR
echo -e "${GREEN}Step 3/3: Pushing image(s) to AWS ECR...${NC}"
echo -e "${YELLOW}This may take a few minutes...${NC}"
echo ""

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
echo -e "${GREEN}Push completed successfully!${NC}"
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
echo "  Deploy to ${ENVIRONMENT}: ./tools/deploy.sh ${ENVIRONMENT}"
echo ""
