#!/bin/bash
# Setup script for local machine
# Checks required tools for AXON deployment
# Use --auto-install to automatically install missing tools
# Supports macOS and Linux

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
AUTO_INSTALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --auto-install)
            AUTO_INSTALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --auto-install    Automatically install missing tools"
            echo "  -h, --help        Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                # Check which tools are missing"
            echo "  $0 --auto-install # Install all missing tools"
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}==================================================${NC}"
if [ "$AUTO_INSTALL" = true ]; then
    echo -e "${BLUE}AXON - Local Machine Setup (Auto-Install Mode)${NC}"
else
    echo -e "${BLUE}AXON - Local Machine Setup (Check Mode)${NC}"
fi
echo -e "${BLUE}==================================================${NC}"
echo ""

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

OS=$(detect_os)
echo -e "${YELLOW}Detected OS: $OS${NC}"
echo ""

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check or install tool based on mode
install_tool() {
    local tool=$1
    local install_cmd_macos=$2
    local install_cmd_linux=$3

    if command_exists "$tool"; then
        echo -e "${GREEN}✓ $tool is already installed${NC}"
        return 0
    fi

    # Tool is missing
    if [ "$AUTO_INSTALL" = false ]; then
        echo -e "${RED}✗ $tool is not installed${NC}"
        return 1
    fi

    # Auto-install mode
    echo -e "${YELLOW}Installing $tool...${NC}"

    if [ "$OS" = "macos" ]; then
        eval "$install_cmd_macos"
    elif [ "$OS" = "linux" ]; then
        eval "$install_cmd_linux"
    else
        echo -e "${RED}✗ Unsupported OS for automatic installation${NC}"
        return 1
    fi

    if command_exists "$tool"; then
        echo -e "${GREEN}✓ $tool installed successfully${NC}"
    else
        echo -e "${RED}✗ Failed to install $tool${NC}"
        return 1
    fi
}

# Check Homebrew on macOS
if [ "$OS" = "macos" ]; then
    echo -e "${BLUE}Checking Homebrew...${NC}"
    if ! command_exists brew; then
        if [ "$AUTO_INSTALL" = true ]; then
            echo -e "${YELLOW}Homebrew not found. Installing Homebrew...${NC}"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

            if ! command_exists brew; then
                echo -e "${RED}✗ Failed to install Homebrew${NC}"
                echo "Please install Homebrew manually: https://brew.sh"
                exit 1
            fi
        else
            echo -e "${RED}✗ Homebrew is not installed${NC}"
            echo "  Install manually: https://brew.sh"
            echo "  Or run with --auto-install flag"
        fi
    else
        echo -e "${GREEN}✓ Homebrew is available${NC}"
    fi
    echo ""
fi

# Check/Install required tools
echo -e "${BLUE}==================================================${NC}"
if [ "$AUTO_INSTALL" = true ]; then
    echo -e "${BLUE}Installing Required Tools${NC}"
else
    echo -e "${BLUE}Checking Required Tools${NC}"
fi
echo -e "${BLUE}==================================================${NC}"
echo ""

# 1. yq (YAML processor) - REQUIRED
echo -e "${BLUE}1. yq (YAML processor)${NC}"
install_tool "yq" \
    "brew install yq" \
    "sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && sudo chmod +x /usr/bin/yq"
echo ""

# 2. envsubst (environment variable substitution) - REQUIRED
echo -e "${BLUE}2. envsubst (environment variable substitution)${NC}"
install_tool "envsubst" \
    "brew install gettext && brew link --force gettext" \
    "sudo apt-get install -y gettext-base"
echo ""

# 3. Docker - REQUIRED
echo -e "${BLUE}3. Docker${NC}"
if command_exists docker; then
    echo -e "${GREEN}✓ Docker is already installed${NC}"
    docker --version
else
    if [ "$AUTO_INSTALL" = false ]; then
        echo -e "${RED}✗ Docker is not installed${NC}"
        if [ "$OS" = "macos" ]; then
            echo "  Install manually: https://docs.docker.com/desktop/install/mac-install/"
        elif [ "$OS" = "linux" ]; then
            echo "  Install with: curl -fsSL https://get.docker.com | sh"
        fi
    else
        # Auto-install mode
        if [ "$OS" = "macos" ]; then
            echo -e "${YELLOW}Docker Desktop must be installed manually on macOS${NC}"
            echo "  Please download from: https://docs.docker.com/desktop/install/mac-install/"
            echo "  After installation, run this script again with --auto-install"
        elif [ "$OS" = "linux" ]; then
            echo -e "${YELLOW}Installing Docker...${NC}"
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            sudo usermod -aG docker "$USER"
            rm get-docker.sh
            echo -e "${GREEN}✓ Docker installed${NC}"
            echo -e "${YELLOW}Note: You may need to log out and back in for Docker group permissions to take effect${NC}"
        fi
    fi
fi
echo ""

# 4. AWS CLI - REQUIRED
echo -e "${BLUE}4. AWS CLI${NC}"
install_tool "aws" \
    "brew install awscli" \
    "curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip' && unzip awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip"

if command_exists aws; then
    aws --version
fi
echo ""

# 5. Node.js and npm - REQUIRED (for decomposerize)
echo -e "${BLUE}5. Node.js and npm${NC}"
install_tool "node" \
    "brew install node" \
    "curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - && sudo apt-get install -y nodejs"

if command_exists node && command_exists npm; then
    node --version
    npm --version
elif command_exists node; then
    echo -e "${YELLOW}⚠ Node.js is installed but npm is missing${NC}"
fi
echo ""

# 6. decomposerize - REQUIRED
echo -e "${BLUE}6. decomposerize${NC}"
if command_exists decomposerize; then
    echo -e "${GREEN}✓ decomposerize is already installed${NC}"
else
    if command_exists npm; then
        if [ "$AUTO_INSTALL" = true ]; then
            echo -e "${YELLOW}Installing decomposerize...${NC}"
            sudo npm install -g decomposerize

            if command_exists decomposerize; then
                echo -e "${GREEN}✓ decomposerize installed successfully${NC}"
            else
                echo -e "${RED}✗ Failed to install decomposerize${NC}"
            fi
        else
            echo -e "${RED}✗ decomposerize is not installed${NC}"
            echo "  Install with: npm install -g decomposerize"
        fi
    else
        echo -e "${RED}✗ npm not found - cannot install decomposerize${NC}"
        echo "  Please install Node.js first"
    fi
fi
echo ""

# 7. SSH (usually pre-installed)
echo -e "${BLUE}7. SSH Client${NC}"
if command_exists ssh; then
    echo -e "${GREEN}✓ SSH is available${NC}"
else
    echo -e "${RED}✗ SSH not found${NC}"
    echo "SSH should be pre-installed on most systems."
    if [ "$OS" = "linux" ]; then
        echo "Install with: sudo apt-get install openssh-client"
    fi
fi
echo ""

# Verify installations
echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Verification${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

MISSING_TOOLS=()

# Check required tools
if ! command_exists yq; then
    MISSING_TOOLS+=("yq")
fi

if ! command_exists envsubst; then
    MISSING_TOOLS+=("envsubst")
fi

if ! command_exists docker; then
    MISSING_TOOLS+=("docker")
fi

if ! command_exists aws; then
    MISSING_TOOLS+=("aws")
fi

if ! command_exists ssh; then
    MISSING_TOOLS+=("ssh")
fi

if ! command_exists node; then
    MISSING_TOOLS+=("node")
fi

if ! command_exists npm; then
    MISSING_TOOLS+=("npm")
fi

if ! command_exists decomposerize; then
    MISSING_TOOLS+=("decomposerize")
fi

# Check Docker is running
if command_exists docker; then
    if docker info &> /dev/null; then
        echo -e "${GREEN}✓ Docker is running${NC}"
    else
        echo -e "${YELLOW}⚠ Docker is installed but not running${NC}"
        echo "  Start Docker and try again"
        MISSING_TOOLS+=("docker (not running)")
    fi
fi

echo ""

# Registry-specific tools note
echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}Registry-Specific Tools (Optional)${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""
echo -e "${YELLOW}Depending on your registry provider, you may need additional tools:${NC}"
echo ""
echo -e "  ${CYAN}Docker Hub:${NC} No additional tools needed (uses docker login)"
echo -e "  ${CYAN}AWS ECR:${NC} AWS CLI (optional on local machine, required on Application Server)"
echo -e "  ${CYAN}Google GCR:${NC} gcloud CLI - https://cloud.google.com/sdk/docs/install"
echo -e "  ${CYAN}Azure ACR:${NC} Azure CLI - https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
echo ""
echo -e "${YELLOW}Configure your registry provider in axon.config.yml:${NC}"
echo -e "  ${CYAN}registry.provider: docker_hub | aws_ecr | google_gcr | azure_acr${NC}"
echo ""
echo -e "${YELLOW}Installation commands (if needed):${NC}"
echo ""
if [ "$OS" = "macos" ]; then
    echo -e "  ${CYAN}# Google Cloud SDK (gcloud)${NC}"
    echo -e "  brew install --cask google-cloud-sdk"
    echo ""
    echo -e "  ${CYAN}# Azure CLI${NC}"
    echo -e "  brew install azure-cli"
elif [ "$OS" = "linux" ]; then
    echo -e "  ${CYAN}# Google Cloud SDK (gcloud)${NC}"
    echo -e "  curl https://sdk.cloud.google.com | bash"
    echo ""
    echo -e "  ${CYAN}# Azure CLI${NC}"
    echo -e "  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
fi
echo ""

# Summary
if [ ${#MISSING_TOOLS[@]} -eq 0 ]; then
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}✓ All required tools are installed!${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Choose and configure your container registry:"
    echo "   Edit axon.config.yml and set registry.provider"
    echo ""
    echo "2. Install registry-specific CLI tools (if needed)"
    echo "   See registry-specific tools section above"
    echo ""
    echo "3. Set up SSH keys for your servers"
    echo "   (or use existing keys in ~/.ssh/)"
    echo ""
    echo "4. Create your axon.config.yml:"
    echo "   axon init-config"
    echo "   # Or: axon init-config --interactive"
    echo ""
    echo "5. Install on servers:"
    echo "   axon install app-server"
    echo "   axon install system-server"
    echo ""
    echo "6. Run deployment:"
    echo "   axon run production"
    echo ""
else
    echo -e "${RED}==================================================${NC}"
    echo -e "${RED}✗ Missing required tools (${#MISSING_TOOLS[@]}):${NC}"
    for tool in "${MISSING_TOOLS[@]}"; do
        echo "  - $tool"
    done
    echo -e "${RED}==================================================${NC}"
    echo ""

    if [ "$AUTO_INSTALL" = false ]; then
        echo -e "${YELLOW}To automatically install missing tools, run:${NC}"
        echo "  $0 --auto-install"
        echo ""
    else
        echo "Some tools could not be installed automatically."
        echo "Please install them manually and run this script again."
        echo ""
    fi
    exit 1
fi

exit 0
