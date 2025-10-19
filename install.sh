#!/bin/bash
# AXON Installation Script
# Install AXON deployment orchestration tool
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ezoushen/axon/main/install.sh | bash
#   wget -qO- https://raw.githubusercontent.com/ezoushen/axon/main/install.sh | bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
AXON_REPO="${AXON_REPO:-https://github.com/ezoushen/axon.git}"
AXON_BRANCH="${AXON_BRANCH:-main}"
AXON_DIR="${AXON_DIR:-$HOME/.axon}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

# Detect if running with sudo
if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}AXON Installation${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check prerequisites
echo -e "${BLUE}Checking prerequisites...${NC}"

if ! command -v git &> /dev/null; then
    echo -e "${RED}✗ git is not installed${NC}"
    echo "Please install git first:"
    echo "  macOS: brew install git"
    echo "  Ubuntu/Debian: sudo apt-get install git"
    echo "  CentOS/RHEL: sudo yum install git"
    exit 1
fi
echo -e "${GREEN}✓ git is installed${NC}"

# Create AXON directory
echo ""
echo -e "${BLUE}Installing AXON to ${AXON_DIR}...${NC}"

if [ -d "$AXON_DIR" ]; then
    echo -e "${YELLOW}AXON directory already exists. Updating...${NC}"
    cd "$AXON_DIR"
    git pull origin "$AXON_BRANCH"
else
    echo "Cloning AXON repository..."
    git clone --depth 1 --branch "$AXON_BRANCH" "$AXON_REPO" "$AXON_DIR"
fi

# Make axon executable
chmod +x "$AXON_DIR/axon"

# Create symlink
echo ""
echo -e "${BLUE}Creating symlink in ${INSTALL_DIR}...${NC}"

# Check if we need sudo for /usr/local/bin
if [ -w "$INSTALL_DIR" ]; then
    SUDO=""
fi

$SUDO ln -sf "$AXON_DIR/axon" "$INSTALL_DIR/axon"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Symlink created: ${INSTALL_DIR}/axon${NC}"
else
    echo -e "${RED}✗ Failed to create symlink${NC}"
    echo ""
    echo "Alternative: Add AXON to your PATH manually"
    echo "Add this to your ~/.bashrc or ~/.zshrc:"
    echo ""
    echo "  export PATH=\"\$PATH:$AXON_DIR\""
    echo ""
    exit 1
fi

# Get version
VERSION="unknown"
if [ -f "$AXON_DIR/VERSION" ]; then
    VERSION=$(cat "$AXON_DIR/VERSION" | tr -d '[:space:]')
fi

# Success
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ AXON ${VERSION} installed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Installed to: ${AXON_DIR}"
echo "Symlinked to: ${INSTALL_DIR}/axon"
echo ""
echo "Next steps:"
echo "  1. Verify installation: axon --version"
echo "  2. Get help: axon --help"
echo "  3. Setup local machine: axon setup local"
echo ""
echo "Documentation: https://github.com/ezoushen/axon"
echo ""

# Verify installation
if command -v axon &> /dev/null; then
    echo -e "${GREEN}Verification successful!${NC}"
    axon --version
else
    echo -e "${YELLOW}Note: You may need to restart your terminal or run:${NC}"
    echo "  hash -r"
fi

echo ""
