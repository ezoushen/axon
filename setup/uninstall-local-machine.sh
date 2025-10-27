#!/bin/bash
# Uninstall script for local machine
# Removes AXON-installed tools (USE WITH CAUTION)
# This script does NOT remove shared tools like Docker, Node.js
# Only removes AXON-specific installations

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -f, --force       Skip confirmation prompts"
            echo "  -h, --help        Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                # Interactive uninstall with confirmations"
            echo "  $0 --force        # Uninstall without confirmations"
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
echo -e "${BLUE}AXON - Local Machine Uninstallation${NC}"
echo -e "${BLUE}==================================================${NC}"
echo ""

# Warning message
echo -e "${YELLOW}WARNING: This will remove AXON-specific tools from your local machine.${NC}"
echo -e "${YELLOW}Shared tools (Docker, Node.js, etc.) will NOT be removed.${NC}"
echo ""

# Confirm unless --force
if [ "$FORCE" = false ]; then
    read -p "Do you want to continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Uninstallation cancelled.${NC}"
        exit 0
    fi
fi

echo ""
echo -e "${BLUE}Starting uninstallation...${NC}"
echo ""

# Function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Function to uninstall a tool
uninstall_tool() {
    local tool=$1
    local uninstall_method=$2

    if ! command_exists "$tool"; then
        echo -e "${YELLOW}⊘ $tool is not installed (skipping)${NC}"
        return 0
    fi

    echo -e "${YELLOW}Uninstalling $tool...${NC}"

    if [ "$FORCE" = false ]; then
        read -p "  Remove $tool? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "  ${BLUE}Skipped $tool${NC}"
            return 0
        fi
    fi

    eval "$uninstall_method"
    echo -e "${GREEN}✓ $tool uninstalled${NC}"
}

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
else
    OS="unknown"
fi

echo -e "${YELLOW}Detected OS: $OS${NC}"
echo ""

# Note about tool removal
echo -e "${BLUE}Tool Removal Policy:${NC}"
echo -e "  - ${GREEN}Will remove:${NC} AXON CLI symlink"
echo -e "  - ${YELLOW}Will NOT remove:${NC} Docker, Node.js, yq, envsubst (may be used by other tools)"
echo ""

# Remove AXON CLI symlink
if [ -L "/usr/local/bin/axon" ]; then
    echo -e "${YELLOW}Removing AXON CLI symlink...${NC}"
    if [ "$FORCE" = false ]; then
        read -p "  Remove /usr/local/bin/axon symlink? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo rm -f /usr/local/bin/axon
            echo -e "${GREEN}✓ AXON CLI symlink removed${NC}"
        else
            echo -e "  ${BLUE}Skipped AXON CLI removal${NC}"
        fi
    else
        sudo rm -f /usr/local/bin/axon
        echo -e "${GREEN}✓ AXON CLI symlink removed${NC}"
    fi
else
    echo -e "${YELLOW}⊘ AXON CLI symlink not found (skipping)${NC}"
fi

echo ""
echo -e "${BLUE}Checking for AXON installation directory...${NC}"

# Remove AXON installation directory (if installed via install.sh)
if [ -d "$HOME/.axon" ]; then
    echo -e "${YELLOW}Found AXON installation at $HOME/.axon${NC}"
    if [ "$FORCE" = false ]; then
        read -p "  Remove $HOME/.axon directory? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$HOME/.axon"
            echo -e "${GREEN}✓ AXON directory removed${NC}"
        else
            echo -e "  ${BLUE}Skipped AXON directory removal${NC}"
        fi
    else
        rm -rf "$HOME/.axon"
        echo -e "${GREEN}✓ AXON directory removed${NC}"
    fi
else
    echo -e "${YELLOW}⊘ AXON directory not found (skipping)${NC}"
fi

echo ""
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}Local Machine Uninstallation Complete${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
echo -e "${BLUE}Note:${NC} Shared tools (Docker, Node.js, yq, etc.) were not removed."
echo -e "      Use your package manager to remove them if desired."
echo ""
