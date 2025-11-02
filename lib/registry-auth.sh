#!/bin/bash
# Registry Authentication Library
# Provides functions to authenticate with different container registries
# Requires: lib/config-parser.sh

# Source config parser if not already loaded
if [ -z "$(type -t get_registry_provider)" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/config-parser.sh"
fi

# ==============================================================================
# Main Authentication Function
# ==============================================================================

# Authenticate with the configured registry provider
registry_login() {
    local provider=$(get_registry_provider)

    if [ -z "$provider" ]; then
        echo -e "${RED}Error: registry.provider not configured${NC}" >&2
        echo "" >&2
        echo "Add to axon.config.yml:" >&2
        echo "  registry:" >&2
        echo "    provider: docker_hub | aws_ecr | google_gcr | azure_acr" >&2
        echo "" >&2
        return 1
    fi

    case $provider in
        docker_hub)
            auth_docker_hub
            ;;
        aws_ecr)
            auth_aws_ecr
            ;;
        google_gcr)
            auth_google_gcr
            ;;
        azure_acr)
            auth_azure_acr
            ;;
        *)
            echo -e "${RED}Error: Unknown registry provider: $provider${NC}" >&2
            echo "Supported providers: docker_hub, aws_ecr, google_gcr, azure_acr" >&2
            return 1
            ;;
    esac
}

# ==============================================================================
# Docker Hub Authentication
# ==============================================================================

auth_docker_hub() {
    echo -e "${BLUE}Authenticating with Docker Hub...${NC}"

    local username=$(get_registry_config "username")
    local access_token=$(get_registry_config "access_token")

    # Option 1: Explicit credentials
    if [ -n "$username" ] && [ -n "$access_token" ]; then
        echo "Using explicit credentials..."

        # Expand environment variables
        username=$(expand_env_vars "$username")
        access_token=$(expand_env_vars "$access_token")

        # Login to Docker Hub
        echo "$access_token" | docker login -u "$username" --password-stdin

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Successfully authenticated with Docker Hub using credentials${NC}"
            return 0
        else
            echo -e "${RED}✗ Failed to authenticate with Docker Hub${NC}" >&2
            return 1
        fi
    fi

    # Option 2: Docker CLI config fallback
    echo "Using Docker CLI config (~/.docker/config.json)..."

    # Check if Docker config exists
    local docker_config="$HOME/.docker/config.json"
    if [ ! -f "$docker_config" ]; then
        echo -e "${RED}Error: No Docker Hub credentials available${NC}" >&2
        echo "" >&2
        echo "Please configure one of the following:" >&2
        echo "" >&2
        echo "Option 1: Explicit credentials (recommended for CI/CD)" >&2
        echo "  registry.docker_hub.username: \"\${DOCKER_HUB_USERNAME}\"" >&2
        echo "  registry.docker_hub.access_token: \"\${DOCKER_HUB_TOKEN}\"" >&2
        echo "" >&2
        echo "Option 2: Docker CLI login (recommended for local development)" >&2
        echo "  Run: docker login" >&2
        echo "  This stores credentials in ~/.docker/config.json" >&2
        echo "" >&2
        return 1
    fi

    # Check if Docker Hub credentials exist in config
    if ! grep -q "index.docker.io" "$docker_config" 2>/dev/null; then
        echo -e "${RED}Error: No Docker Hub credentials found in ~/.docker/config.json${NC}" >&2
        echo "" >&2
        echo "Please run 'docker login' first, or configure explicit credentials in axon.config.yml" >&2
        echo "" >&2
        return 1
    fi

    echo -e "${GREEN}✓ Using Docker Hub credentials from ~/.docker/config.json${NC}"
    echo "Note: Credentials stored by previous 'docker login' command"
    return 0
}

# ==============================================================================
# AWS ECR Authentication
# ==============================================================================

auth_aws_ecr() {
    echo -e "${BLUE}Authenticating with AWS ECR...${NC}"

    local profile=$(get_registry_config "profile")
    local region=$(get_registry_config "region")
    local access_key_id=$(get_registry_config "access_key_id")
    local secret_access_key=$(get_registry_config "secret_access_key")
    local session_token=$(get_registry_config "session_token")
    local credentials_file=$(get_registry_config "credentials_file")
    local registry_url=$(build_registry_url)

    # Expand environment variables
    region=$(expand_env_vars "$region")

    if [ -z "$region" ]; then
        echo -e "${RED}Error: registry.aws_ecr.region not configured${NC}" >&2
        return 1
    fi

    if [ -z "$registry_url" ]; then
        echo -e "${RED}Error: Could not build AWS ECR registry URL${NC}" >&2
        echo "Ensure registry.aws_ecr.account_id is configured" >&2
        return 1
    fi

    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}Error: AWS CLI is not installed${NC}" >&2
        echo "" >&2
        echo "Install AWS CLI:" >&2
        echo "  macOS:   brew install awscli" >&2
        echo "  Linux:   https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
        echo "" >&2
        return 1
    fi

    local aws_cmd="aws ecr get-login-password --region $region"
    local auth_method=""

    # Option 1: Direct credentials (recommended for CI/CD)
    if [ -n "$access_key_id" ] && [ -n "$secret_access_key" ]; then
        echo "Using direct AWS credentials..."

        # Expand environment variables
        access_key_id=$(expand_env_vars "$access_key_id")
        secret_access_key=$(expand_env_vars "$secret_access_key")

        # Set AWS environment variables for this command
        export AWS_ACCESS_KEY_ID="$access_key_id"
        export AWS_SECRET_ACCESS_KEY="$secret_access_key"

        if [ -n "$session_token" ]; then
            session_token=$(expand_env_vars "$session_token")
            export AWS_SESSION_TOKEN="$session_token"
        fi

        auth_method="direct credentials"
    # Option 2: Credentials file
    elif [ -n "$credentials_file" ]; then
        echo "Using AWS credentials file..."

        # Expand tilde to home directory
        credentials_file="${credentials_file/#\~/$HOME}"

        if [ ! -f "$credentials_file" ]; then
            echo -e "${RED}Error: Credentials file not found: $credentials_file${NC}" >&2
            return 1
        fi

        # Use credentials file with optional profile
        if [ -n "$profile" ]; then
            aws_cmd="$aws_cmd --profile $profile"
            export AWS_SHARED_CREDENTIALS_FILE="$credentials_file"
            auth_method="credentials file with profile $profile"
        else
            export AWS_SHARED_CREDENTIALS_FILE="$credentials_file"
            auth_method="credentials file"
        fi
    # Option 3: AWS CLI profile (recommended for local development)
    elif [ -n "$profile" ]; then
        echo "Using AWS CLI profile..."
        aws_cmd="$aws_cmd --profile $profile"
        auth_method="AWS CLI profile $profile"
    else
        echo -e "${RED}Error: No AWS authentication method configured${NC}" >&2
        echo "" >&2
        echo "Please configure one of the following:" >&2
        echo "" >&2
        echo "Option 1: AWS CLI profile (recommended for local development)" >&2
        echo "  registry.aws_ecr.profile: \"default\"" >&2
        echo "" >&2
        echo "Option 2: Direct credentials (recommended for CI/CD)" >&2
        echo "  registry.aws_ecr.access_key_id: \"\${AWS_ACCESS_KEY_ID}\"" >&2
        echo "  registry.aws_ecr.secret_access_key: \"\${AWS_SECRET_ACCESS_KEY}\"" >&2
        echo "  registry.aws_ecr.session_token: \"\${AWS_SESSION_TOKEN}\"  # Optional" >&2
        echo "" >&2
        echo "Option 3: Credentials file" >&2
        echo "  registry.aws_ecr.credentials_file: \"~/.aws/credentials\"" >&2
        echo "  registry.aws_ecr.profile: \"custom-profile\"  # Optional" >&2
        echo "" >&2
        return 1
    fi

    # Get ECR login password and authenticate
    echo "Getting ECR login token (valid for 12 hours)..."
    eval "$aws_cmd" | docker login --username AWS --password-stdin "$registry_url"
    local login_result=$?

    # Clean up exported credentials
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SHARED_CREDENTIALS_FILE

    if [ $login_result -eq 0 ]; then
        echo -e "${GREEN}✓ Successfully authenticated with AWS ECR${NC}"
        echo "Region: $region, Method: $auth_method"
        return 0
    else
        echo -e "${RED}✗ Failed to authenticate with AWS ECR${NC}" >&2
        echo "" >&2
        echo "Troubleshooting:" >&2
        if [ -n "$profile" ]; then
            echo "  1. Verify AWS CLI is configured: aws configure --profile $profile" >&2
            echo "  2. Check AWS credentials: aws sts get-caller-identity --profile $profile" >&2
        else
            echo "  1. Verify credentials are correct" >&2
            echo "  2. Check AWS credentials: aws sts get-caller-identity" >&2
        fi
        echo "  3. Verify ECR permissions for this AWS account" >&2
        echo "" >&2
        return 1
    fi
}

# ==============================================================================
# Google Container Registry Authentication
# ==============================================================================

auth_google_gcr() {
    echo -e "${BLUE}Authenticating with Google Container Registry...${NC}"

    local project_id=$(get_registry_config "project_id")
    local service_account_key=$(get_registry_config "service_account_key")
    local use_artifact=$(get_registry_config "use_artifact_registry")

    if [ -z "$project_id" ]; then
        echo -e "${RED}Error: registry.google_gcr.project_id not configured${NC}" >&2
        return 1
    fi

    # Determine registry hostname
    local registry_host
    if [ "$use_artifact" = "true" ]; then
        registry_host="https://$(get_registry_config "location")-docker.pkg.dev"
    else
        registry_host="https://gcr.io"
    fi

    # Option 1: Use service account key file
    if [ -n "$service_account_key" ]; then
        # Expand tilde to home directory
        service_account_key="${service_account_key/#\~/$HOME}"

        if [ ! -f "$service_account_key" ]; then
            echo -e "${RED}Error: Service account key file not found: $service_account_key${NC}" >&2
            return 1
        fi

        echo "Using service account key file..."
        cat "$service_account_key" | docker login -u _json_key --password-stdin "$registry_host"

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Successfully authenticated with GCR using service account${NC}"
            return 0
        else
            echo -e "${RED}✗ Failed to authenticate with GCR${NC}" >&2
            return 1
        fi
    fi

    # Option 2: Use gcloud CLI
    if command -v gcloud &> /dev/null; then
        echo "Using gcloud CLI for authentication..."
        gcloud auth configure-docker --quiet

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Successfully authenticated with GCR using gcloud${NC}"
            return 0
        else
            echo -e "${RED}✗ Failed to authenticate with GCR${NC}" >&2
            return 1
        fi
    fi

    # No authentication method available
    echo -e "${RED}Error: No authentication method available for GCR${NC}" >&2
    echo "" >&2
    echo "Please configure one of the following:" >&2
    echo "" >&2
    echo "Option 1: Service account key" >&2
    echo "  registry.google_gcr.service_account_key: ~/gcp-key.json" >&2
    echo "" >&2
    echo "Option 2: Install gcloud CLI" >&2
    echo "  macOS:   brew install --cask google-cloud-sdk" >&2
    echo "  Linux:   curl https://sdk.cloud.google.com | bash" >&2
    echo "" >&2
    return 1
}

# ==============================================================================
# Azure Container Registry Authentication
# ==============================================================================

auth_azure_acr() {
    echo -e "${BLUE}Authenticating with Azure Container Registry...${NC}"

    local registry_name=$(get_registry_config "registry_name")
    local sp_id=$(get_registry_config "service_principal_id")
    local sp_password=$(get_registry_config "service_principal_password")
    local admin_user=$(get_registry_config "admin_username")
    local admin_password=$(get_registry_config "admin_password")

    if [ -z "$registry_name" ]; then
        echo -e "${RED}Error: registry.azure_acr.registry_name not configured${NC}" >&2
        return 1
    fi

    local registry_url="${registry_name}.azurecr.io"

    # Option 1: Service Principal authentication
    if [ -n "$sp_id" ] && [ -n "$sp_password" ]; then
        echo "Authenticating with service principal..."

        # Expand environment variables
        sp_password=$(expand_env_vars "$sp_password")

        echo "$sp_password" | docker login "$registry_url" --username "$sp_id" --password-stdin

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Successfully authenticated with ACR using service principal${NC}"
            return 0
        else
            echo -e "${RED}✗ Failed to authenticate with ACR${NC}" >&2
            return 1
        fi
    fi

    # Option 2: Admin user authentication
    if [ -n "$admin_user" ] && [ -n "$admin_password" ]; then
        echo "Authenticating with admin user..."

        # Expand environment variables
        admin_password=$(expand_env_vars "$admin_password")

        echo "$admin_password" | docker login "$registry_url" --username "$admin_user" --password-stdin

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Successfully authenticated with ACR using admin user${NC}"
            return 0
        else
            echo -e "${RED}✗ Failed to authenticate with ACR${NC}" >&2
            return 1
        fi
    fi

    # Option 3: Azure CLI authentication
    if command -v az &> /dev/null; then
        echo "Authenticating with Azure CLI..."
        az acr login --name "$registry_name"

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Successfully authenticated with ACR using Azure CLI${NC}"
            return 0
        else
            echo -e "${RED}✗ Failed to authenticate with ACR${NC}" >&2
            return 1
        fi
    fi

    # No authentication method available
    echo -e "${RED}Error: No authentication method available for ACR${NC}" >&2
    echo "" >&2
    echo "Please configure one of the following:" >&2
    echo "" >&2
    echo "Option 1: Service principal" >&2
    echo "  registry.azure_acr.service_principal_id: <app-id>" >&2
    echo "  registry.azure_acr.service_principal_password: \"\${AZURE_SP_PASSWORD}\"" >&2
    echo "" >&2
    echo "Option 2: Admin user (enable in Azure Portal)" >&2
    echo "  registry.azure_acr.admin_username: <username>" >&2
    echo "  registry.azure_acr.admin_password: \"\${AZURE_ADMIN_PASSWORD}\"" >&2
    echo "" >&2
    echo "Option 3: Install Azure CLI" >&2
    echo "  macOS:   brew install azure-cli" >&2
    echo "  Linux:   curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash" >&2
    echo "" >&2
    return 1
}

# ==============================================================================
# Helper Function: Expand environment variables
# ==============================================================================

# Note: This function is defined in config-parser.sh
# We provide a fallback if not loaded
if [ -z "$(type -t expand_env_vars)" ]; then
    expand_env_vars() {
        local value=$1

        if ! command -v envsubst >/dev/null 2>&1; then
            echo "Error: envsubst is not installed (required for environment variable expansion)" >&2
            echo "Install: brew install gettext (macOS) or apt-get install gettext-base (Linux)" >&2
            return 1
        fi

        echo "$value" | envsubst
    }
fi
