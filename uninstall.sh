#!/bin/bash
# AXON Uninstallation Script
# Remove AXON deployment orchestration tool

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
AXON_DIR="${AXON_DIR:-$HOME/.axon}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

# Detect if running with sudo
if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}AXON Uninstallation${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Confirm uninstallation
echo -e "${YELLOW}This will remove AXON from your system.${NC}"
echo ""
echo "The following will be removed:"
if [ -d "$AXON_DIR" ]; then
    echo "  - AXON directory: ${AXON_DIR}"
fi
if [ -L "${INSTALL_DIR}/axon" ]; then
    echo "  - Symlink: ${INSTALL_DIR}/axon"
fi
echo ""

read -p "Continue with uninstallation? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Uninstallation cancelled.${NC}"
    exit 0
fi

echo ""

# Remove symlink
if [ -L "${INSTALL_DIR}/axon" ] || [ -f "${INSTALL_DIR}/axon" ]; then
    echo -e "${BLUE}Removing symlink...${NC}"

    # Check if we need sudo
    if [ -w "$INSTALL_DIR" ]; then
        SUDO=""
    fi

    $SUDO rm -f "${INSTALL_DIR}/axon"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Symlink removed${NC}"
    else
        echo -e "${YELLOW}⚠ Could not remove symlink (may require manual deletion)${NC}"
    fi
else
    echo -e "${YELLOW}No symlink found at ${INSTALL_DIR}/axon${NC}"
fi

# Remove AXON directory
if [ -d "$AXON_DIR" ]; then
    echo -e "${BLUE}Removing AXON directory...${NC}"

    rm -rf "$AXON_DIR"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ AXON directory removed${NC}"
    else
        echo -e "${RED}✗ Failed to remove AXON directory${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}No AXON directory found at ${AXON_DIR}${NC}"
fi

# Success
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ AXON has been uninstalled${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if command still exists
if command -v axon &> /dev/null; then
    echo -e "${YELLOW}Note: 'axon' command still found in PATH${NC}"
    echo "You may need to:"
    echo "  1. Restart your terminal"
    echo "  2. Run: hash -r"
    echo "  3. Check for other installations (e.g., Homebrew)"
else
    echo -e "${GREEN}Verification successful! AXON command removed.${NC}"
fi

echo ""
