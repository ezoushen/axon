#!/bin/bash
# Update Homebrew Formula SHA256
# Run this after creating a GitHub release

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FORMULA_FILE="$PROJECT_ROOT/homebrew/axon.rb"
VERSION_FILE="$PROJECT_ROOT/VERSION"

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}Update Homebrew Formula SHA256${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Get version
if [ -n "$1" ]; then
    VERSION="$1"
else
    if [ -f "$VERSION_FILE" ]; then
        VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
    else
        read -p "Enter version (e.g., 0.1.0): " VERSION
    fi
fi

echo -e "${BLUE}Version: ${VERSION}${NC}"
echo ""

# Construct tarball URL
TARBALL_URL="https://github.com/ezoushen/axon/archive/refs/tags/v${VERSION}.tar.gz"

echo "Downloading tarball to calculate SHA256..."
echo -e "${YELLOW}${TARBALL_URL}${NC}"
echo ""

# Download and calculate SHA256
SHA256=$(curl -sL "$TARBALL_URL" | shasum -a 256 | awk '{print $1}')

if [ -z "$SHA256" ]; then
    echo -e "${RED}Error: Failed to download tarball or calculate SHA256${NC}"
    echo ""
    echo "Make sure the release exists on GitHub:"
    echo "  https://github.com/ezoushen/axon/releases/tag/v${VERSION}"
    exit 1
fi

echo -e "${GREEN}✓ SHA256 calculated: ${SHA256}${NC}"
echo ""

# Update formula file
if [ ! -f "$FORMULA_FILE" ]; then
    echo -e "${RED}Error: Homebrew formula not found at ${FORMULA_FILE}${NC}"
    exit 1
fi

# Backup formula
cp "$FORMULA_FILE" "${FORMULA_FILE}.bak"

# Update SHA256 in formula
sed -i.tmp "s/sha256 \".*\"/sha256 \"${SHA256}\"/" "$FORMULA_FILE"
rm -f "${FORMULA_FILE}.tmp"

# Update version in formula (in case it changed)
sed -i.tmp "s/version \".*\"/version \"${VERSION}\"/" "$FORMULA_FILE"
rm -f "${FORMULA_FILE}.tmp"

# Update URL in formula
sed -i.tmp "s|url \".*\"|url \"${TARBALL_URL}\"|" "$FORMULA_FILE"
rm -f "${FORMULA_FILE}.tmp"

echo -e "${GREEN}✓ Updated ${FORMULA_FILE}${NC}"
echo ""

# Show diff
echo -e "${BLUE}Changes:${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
diff -u "${FORMULA_FILE}.bak" "$FORMULA_FILE" || true
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Clean up backup
rm -f "${FORMULA_FILE}.bak"

echo -e "${GREEN}✓ Homebrew formula updated successfully!${NC}"
echo ""
echo "Next steps:"
echo "  1. Review the changes above"
echo "  2. Commit and push:"
echo -e "     ${YELLOW}git add homebrew/axon.rb${NC}"
echo -e "     ${YELLOW}git commit -m \"Update Homebrew formula SHA256 for v${VERSION}\"${NC}"
echo -e "     ${YELLOW}git push origin main${NC}"
echo ""
