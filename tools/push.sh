#!/bin/bash
# Push Docker image to container registry
# Supports: Docker Hub, AWS ECR, Google GCR, Azure ACR
# Product-agnostic version - uses axon.config.yml

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
# Use current working directory for PRODUCT_ROOT (where config/Dockerfile live)
PRODUCT_ROOT="${PROJECT_ROOT:-$PWD}"

# Default values
CONFIG_FILE="${PRODUCT_ROOT}/axon.config.yml"
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
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
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

# Source the config parser, defaults, and registry auth
source "$MODULE_DIR/lib/config-parser.sh"
source "$MODULE_DIR/lib/defaults.sh"
source "$MODULE_DIR/lib/registry-auth.sh"

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

# Detect product type
PRODUCT_TYPE=$(get_product_type "$CONFIG_FILE")
if [ "$PRODUCT_TYPE" != "docker" ] && [ "$PRODUCT_TYPE" != "static" ]; then
    echo -e "${RED}Error: Invalid product.type: ${PRODUCT_TYPE}${NC}"
    echo "Must be 'docker' or 'static'"
    exit 1
fi

# Validate environment exists before proceeding
if ! validate_environment "$ENVIRONMENT" "$CONFIG_FILE"; then
    exit 1
fi

# Function for pushing Docker images
push_docker() {
    echo -e "${BLUE}==================================================${NC}"
    echo -e "${BLUE}Push to Container Registry${NC}"
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

    # Validate required registry configuration
    REGISTRY_PROVIDER=$(get_registry_provider)
    if [ -z "$REGISTRY_PROVIDER" ]; then
        echo -e "${RED}Error: Registry provider not configured${NC}"
        echo "Please set 'registry.provider' in $CONFIG_FILE"
        echo "Supported providers: docker_hub, aws_ecr, google_gcr, azure_acr"
        exit 1
    fi

    # Build image URI using registry abstraction
    REGISTRY_URL=$(build_registry_url)
    if [ $? -ne 0 ] || [ -z "$REGISTRY_URL" ]; then
        echo -e "${RED}Error: Could not build registry URL${NC}"
        echo "Check your registry configuration in $CONFIG_FILE"
        exit 1
    fi

    REPOSITORY=$(get_repository_name)
    if [ -z "$REPOSITORY" ]; then
        echo -e "${RED}Error: Repository name not configured${NC}"
        echo "Set either registry.${REGISTRY_PROVIDER}.repository or product.name in $CONFIG_FILE"
        exit 1
    fi

    FULL_IMAGE_NAME=$(build_image_uri "$IMAGE_TAG")
    if [ $? -ne 0 ] || [ -z "$FULL_IMAGE_NAME" ]; then
        echo -e "${RED}Error: Could not build image URI${NC}"
        exit 1
    fi

    # Display push info
    echo -e "Product:         ${YELLOW}${PRODUCT_NAME}${NC}"
    echo -e "Environment:     ${YELLOW}${ENVIRONMENT}${NC}"
    echo -e "Registry:        ${YELLOW}${REGISTRY_PROVIDER}${NC}"
    echo -e "Registry URL:    ${YELLOW}${REGISTRY_URL}${NC}"
    echo -e "Repository:      ${YELLOW}${REPOSITORY}${NC}"
    echo -e "Image Tag:       ${YELLOW}${IMAGE_TAG}${NC}"
    [ -n "$GIT_SHA" ] && echo -e "Git SHA Tag:     ${YELLOW}${GIT_SHA}${NC}"
    echo -e "Full Image:      ${YELLOW}${FULL_IMAGE_NAME}${NC}"
    echo ""

    # Check prerequisites
    if ! docker info &> /dev/null; then
        echo -e "${RED}Error: Docker is not running${NC}"
        exit 1
    fi

    # Check if image exists locally
    if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${FULL_IMAGE_NAME}$"; then
        echo -e "${RED}Error: Image not found locally: ${FULL_IMAGE_NAME}${NC}"
        echo ""
        echo "Please build the image first:"
        echo "  ./tools/build.sh ${ENVIRONMENT}"
        exit 1
    fi

    # Authenticate with registry
    echo -e "${GREEN}Step 1/3: Authenticating with container registry...${NC}"
    if ! registry_login; then
        echo -e "${RED}Error: Failed to authenticate with registry${NC}"
        exit 1
    fi

    # Create repository if needed (AWS ECR only)
    if [ "$REGISTRY_PROVIDER" = "aws_ecr" ]; then
        echo -e "${GREEN}Step 2/3: Creating ECR repository (if not exists)...${NC}"
        AWS_PROFILE=$(get_registry_config "profile")
        AWS_REGION=$(get_registry_config "region")

        aws ecr describe-repositories --repository-names "$REPOSITORY" \
            --region "$AWS_REGION" --profile "$AWS_PROFILE" &> /dev/null || \
            aws ecr create-repository \
                --repository-name "$REPOSITORY" \
                --region "$AWS_REGION" \
                --profile "$AWS_PROFILE" \
                --image-scanning-configuration scanOnPush=true \
                --encryption-configuration encryptionType=AES256
    else
        echo -e "${GREEN}Step 2/3: Repository setup (skipped for ${REGISTRY_PROVIDER})...${NC}"
    fi

    # Determine which images to push
    IMAGES_TO_PUSH=("$FULL_IMAGE_NAME")

    if [ -n "$GIT_SHA" ]; then
        GIT_SHA_IMAGE=$(build_image_uri "$GIT_SHA")
        # Check if git SHA image exists locally
        if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${GIT_SHA_IMAGE}$"; then
            IMAGES_TO_PUSH+=("$GIT_SHA_IMAGE")
        else
            echo -e "${YELLOW}Warning: Git SHA image not found locally: ${GIT_SHA_IMAGE}${NC}"
            echo -e "${YELLOW}Only pushing environment tag${NC}"
        fi
    fi

    # Push to registry
    echo -e "${GREEN}Step 3/3: Pushing image(s) to ${REGISTRY_PROVIDER}...${NC}"
    echo -e "${YELLOW}This may take a few minutes...${NC}"
    echo ""

    for IMAGE in "${IMAGES_TO_PUSH[@]}"; do
        echo -e "Pushing: ${YELLOW}${IMAGE}${NC}"
        docker push "$IMAGE"
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to push image to registry${NC}"
            exit 1
        fi
    done

    # Success
    echo ""
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}Push completed successfully!${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo ""

    echo "Image(s) pushed to ${REGISTRY_PROVIDER}:"
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
}

# Function for pushing static site builds
push_static() {
    echo -e "${BLUE}==================================================${NC}"
    echo -e "${BLUE}Push to System Server${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo ""

    # Load configuration
    load_config "$ENVIRONMENT"

    # Get System Server SSH details
    if [ -z "$SYSTEM_SERVER_HOST" ] || [ -z "$SYSTEM_SERVER_USER" ] || [ -z "$SSH_KEY" ]; then
        echo -e "${RED}Error: System Server configuration incomplete${NC}"
        echo "Please configure:"
        echo "  servers.system.host"
        echo "  servers.system.user"
        echo "  servers.system.ssh_key"
        exit 1
    fi

    # Check SSH key exists
    if [ ! -f "$SSH_KEY" ]; then
        echo -e "${RED}Error: SSH key not found: $SSH_KEY${NC}"
        exit 1
    fi

    # Determine release name - check for most recent build archive
    LATEST_ARCHIVE=$(ls -t /tmp/static-build-*.tar.gz 2>/dev/null | head -n 1)

    if [ -z "$LATEST_ARCHIVE" ]; then
        echo -e "${RED}Error: No build archive found in /tmp/${NC}"
        echo ""
        echo "Please build first:"
        echo "  ./tools/build.sh ${ENVIRONMENT}"
        exit 1
    fi

    # Extract release name from archive filename
    ARCHIVE_BASENAME=$(basename "$LATEST_ARCHIVE")
    RELEASE_NAME=$(echo "$ARCHIVE_BASENAME" | sed 's/static-build-\(.*\)\.tar\.gz/\1/')

    ARCHIVE_SIZE=$(du -sh "$LATEST_ARCHIVE" | cut -f1)

    # Display push info
    echo -e "Product:         ${YELLOW}${PRODUCT_NAME}${NC}"
    echo -e "Environment:     ${YELLOW}${ENVIRONMENT}${NC}"
    echo -e "Release:         ${YELLOW}${RELEASE_NAME}${NC}"
    echo -e "Target:          ${YELLOW}${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}${NC}"
    echo -e "Archive:         ${YELLOW}${LATEST_ARCHIVE}${NC}"
    echo -e "Archive Size:    ${YELLOW}${ARCHIVE_SIZE}${NC}"
    echo ""

    # Test SSH connection
    echo -e "${GREEN}Testing SSH connection...${NC}"
    if ! ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes \
        "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" "echo 'OK'" > /dev/null 2>&1; then
        echo -e "${RED}Error: Cannot connect to System Server via SSH${NC}"
        echo "  Host: ${SYSTEM_SERVER_HOST}"
        echo "  User: ${SYSTEM_SERVER_USER}"
        echo "  Key:  ${SSH_KEY}"
        exit 1
    fi
    echo -e "${GREEN}✓ SSH connection successful${NC}"
    echo ""

    # Upload build archive
    echo -e "${GREEN}Uploading build archive to System Server...${NC}"
    echo -e "${YELLOW}This may take a few minutes...${NC}"
    echo ""

    rsync -avz --progress \
        "$LATEST_ARCHIVE" \
        "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}:/tmp/"

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to upload archive${NC}"
        exit 1
    fi

    # Verify upload
    REMOTE_ARCHIVE="/tmp/$(basename "$LATEST_ARCHIVE")"
    if ! ssh -i "$SSH_KEY" "${SYSTEM_SERVER_USER}@${SYSTEM_SERVER_HOST}" \
        "[ -f '$REMOTE_ARCHIVE' ]"; then
        echo -e "${RED}Error: Archive not found on System Server after upload${NC}"
        exit 1
    fi

    # Success
    echo ""
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}Push completed successfully!${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo ""

    echo -e "Archive uploaded to: ${YELLOW}${REMOTE_ARCHIVE}${NC}"
    echo ""
    echo "Next steps:"
    echo "  Deploy to ${ENVIRONMENT}: ./tools/deploy.sh ${ENVIRONMENT}"
    echo ""
}

# Route to appropriate push function based on product type
if [ "$PRODUCT_TYPE" = "static" ]; then
    push_static
else
    push_docker
fi
