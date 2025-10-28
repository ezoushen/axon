#!/bin/bash
# Build Docker image locally
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
            echo "  -c, --config FILE    Specify config file (default: axon.config.yml)"
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

# Source the config parser and defaults library
source "$MODULE_DIR/lib/config-parser.sh"
source "$MODULE_DIR/lib/defaults.sh"

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

# Function for building Docker images
build_docker() {
    echo -e "${BLUE}==================================================${NC}"
    echo -e "${BLUE}Docker Build${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo ""

    # Load configuration from config file
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

    # Display build info
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
        GIT_SHA_IMAGE=$(build_image_uri "$GIT_SHA")
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
    echo "  Push to ${REGISTRY_PROVIDER}: ./tools/push.sh ${ENVIRONMENT}"
    if [ -n "$GIT_SHA" ]; then
        echo "                                ./tools/push.sh ${ENVIRONMENT} ${GIT_SHA}"
    fi
    echo "  Deploy: ./tools/deploy.sh ${ENVIRONMENT}"
    echo ""

    # Output git SHA for capture by parent script (e.g., axon)
    # Format: GIT_SHA_DETECTED=<sha>
    if [ -n "$GIT_SHA" ]; then
        echo "GIT_SHA_DETECTED=${GIT_SHA}"
    fi
}

# Function for building static sites
build_static() {
    echo -e "${BLUE}==================================================${NC}"
    echo -e "${BLUE}Static Site Build${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo ""

    # Load configuration
    load_config "$ENVIRONMENT"

    # Get per-environment static site configuration
    BUILD_COMMAND=$(get_build_command "$ENVIRONMENT" "$CONFIG_FILE")
    BUILD_OUTPUT_DIR=$(get_build_output_dir "$ENVIRONMENT" "$CONFIG_FILE")

    if [ -z "$BUILD_COMMAND" ]; then
        echo -e "${RED}Error: environments.${ENVIRONMENT}.build_command not configured${NC}"
        echo "Please set 'environments.${ENVIRONMENT}.build_command' in $CONFIG_FILE"
        exit 1
    fi

    if [ -z "$BUILD_OUTPUT_DIR" ]; then
        echo -e "${RED}Error: environments.${ENVIRONMENT}.build_output_dir not configured${NC}"
        echo "Please set 'environments.${ENVIRONMENT}.build_output_dir' in $CONFIG_FILE"
        exit 1
    fi

    # Generate release name
    RELEASE_NAME=$(generate_release_name)
    BUILD_ARCHIVE=$(get_build_archive_path "$RELEASE_NAME")

    # Display build info
    echo -e "Product:         ${YELLOW}${PRODUCT_NAME}${NC}"
    echo -e "Environment:     ${YELLOW}${ENVIRONMENT}${NC}"
    echo -e "Build Command:   ${YELLOW}${BUILD_COMMAND}${NC}"
    echo -e "Output Dir:      ${YELLOW}${BUILD_OUTPUT_DIR}${NC}"
    echo -e "Release Name:    ${YELLOW}${RELEASE_NAME}${NC}"
    echo -e "Archive:         ${YELLOW}${BUILD_ARCHIVE}${NC}"
    echo ""

    # Run build command
    echo -e "${GREEN}Running build command...${NC}"
    echo -e "${YELLOW}Command: ${BUILD_COMMAND}${NC}"
    echo ""

    cd "$PRODUCT_ROOT"

    eval "$BUILD_COMMAND"

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Build command failed${NC}"
        exit 1
    fi

    # Check if build output directory exists
    if [ ! -d "$PRODUCT_ROOT/$BUILD_OUTPUT_DIR" ]; then
        echo -e "${RED}Error: Build output directory not found: $PRODUCT_ROOT/$BUILD_OUTPUT_DIR${NC}"
        echo "Build command should create this directory"
        exit 1
    fi

    # Validate required files if configured
    REQUIRED_FILES=$(get_static_required_files "$CONFIG_FILE")
    if [ -n "$REQUIRED_FILES" ]; then
        echo ""
        echo -e "${GREEN}Validating required files...${NC}"
        while IFS= read -r required_file; do
            if [ -f "$PRODUCT_ROOT/$BUILD_OUTPUT_DIR/$required_file" ]; then
                echo -e "  ${GREEN}✓${NC} ${required_file}"
            else
                echo -e "  ${RED}✗${NC} ${required_file}"
                echo -e "${RED}Error: Required file missing: ${required_file}${NC}"
                exit 1
            fi
        done <<< "$REQUIRED_FILES"
    fi

    # Calculate build size
    BUILD_SIZE=$(du -sh "$PRODUCT_ROOT/$BUILD_OUTPUT_DIR" | cut -f1)
    echo ""
    echo -e "${GREEN}Build completed successfully${NC}"
    echo -e "Build size: ${YELLOW}${BUILD_SIZE}${NC}"

    # Create compressed archive
    echo ""
    echo -e "${GREEN}Creating compressed archive...${NC}"

    cd "$PRODUCT_ROOT/$BUILD_OUTPUT_DIR"
    tar -czf "$BUILD_ARCHIVE" .

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to create archive${NC}"
        exit 1
    fi

    ARCHIVE_SIZE=$(du -sh "$BUILD_ARCHIVE" | cut -f1)

    echo -e "Archive created: ${YELLOW}${BUILD_ARCHIVE}${NC}"
    echo -e "Archive size:    ${YELLOW}${ARCHIVE_SIZE}${NC}"

    # Success
    echo ""
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}Build completed successfully!${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo ""

    echo "Next steps:"
    echo "  Push to System Server: ./tools/push.sh ${ENVIRONMENT}"
    echo "  Deploy: ./tools/deploy.sh ${ENVIRONMENT}"
    echo ""

    # Output release name for capture by parent script
    echo "RELEASE_NAME=${RELEASE_NAME}"
}

# Validate environment exists before proceeding
if ! validate_environment "$ENVIRONMENT" "$CONFIG_FILE"; then
    exit 1
fi

# Route to appropriate build function based on product type
if [ "$PRODUCT_TYPE" = "static" ]; then
    build_static
else
    build_docker
fi
