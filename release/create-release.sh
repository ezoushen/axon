#!/bin/bash
# AXON Release Creation Script
# Automates version tagging and release process

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
VERSION_FILE="$PROJECT_ROOT/VERSION"

# Function to validate semantic version
validate_version() {
    local version=$1
    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}Error: Invalid version format. Use semantic versioning (e.g., 0.1.0, 1.2.3)${NC}"
        return 1
    fi
    return 0
}

# Function to check if tag exists
tag_exists() {
    local tag=$1
    if git rev-parse "v$tag" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}AXON Release Creator${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check for uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
    echo -e "${YELLOW}Warning: You have uncommitted changes${NC}"
    git status --short
    echo ""
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Release cancelled${NC}"
        exit 0
    fi
fi

# Get current version
CURRENT_VERSION=""
if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
    echo -e "${BLUE}Current version: ${CURRENT_VERSION}${NC}"
else
    echo -e "${YELLOW}No VERSION file found${NC}"
fi

echo ""

# Get new version
read -p "Enter new version (e.g., 0.1.0, 1.2.3): " NEW_VERSION

# Validate version
if ! validate_version "$NEW_VERSION"; then
    exit 1
fi

# Check if tag already exists
if tag_exists "$NEW_VERSION"; then
    echo -e "${RED}Error: Tag v${NEW_VERSION} already exists${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}Preparing release v${NEW_VERSION}...${NC}"
echo ""

# Update VERSION file
echo "$NEW_VERSION" > "$VERSION_FILE"
echo -e "${GREEN}✓ Updated VERSION file${NC}"

# Commit VERSION file
git add "$VERSION_FILE"
git commit -m "chore: release v${NEW_VERSION}" || echo -e "${YELLOW}No changes to commit${NC}"
echo -e "${GREEN}✓ Committed version change${NC}"

# Create tag
git tag -a "v${NEW_VERSION}" -m "chore: release v${NEW_VERSION}"
echo -e "${GREEN}✓ Created tag v${NEW_VERSION}${NC}"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Release prepared successfully!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Next steps:"
echo ""
echo "  1. Push commit and tag:"
echo -e "     ${YELLOW}git push origin main${NC}"
echo -e "     ${YELLOW}git push origin v${NEW_VERSION}${NC}"
echo ""
echo "  2. GitHub Actions will automatically:"
echo "     - Create a release on GitHub"
echo "     - Generate changelog from commits"
echo "     - Attach installation files"
echo "     - Calculate SHA256 for the release tarball"
echo "     - Update homebrew/axon.rb with correct SHA256"
echo "     - Commit and push the Homebrew formula update"
echo ""
echo "  3. That's it! Everything is automated."
echo "     View progress at: https://github.com/ezoushen/axon/actions"
echo ""
echo "Or run this to push now:"
echo -e "  ${YELLOW}git push origin main && git push origin v${NEW_VERSION}${NC}"
echo ""

# Ask if user wants to push now
read -p "Push to GitHub now? (y/N): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${BLUE}Pushing to GitHub...${NC}"

    git push origin main
    echo -e "${GREEN}✓ Pushed main branch${NC}"

    git push origin "v${NEW_VERSION}"
    echo -e "${GREEN}✓ Pushed tag v${NEW_VERSION}${NC}"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ Release pushed to GitHub!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "GitHub Actions is now:"
    echo "  ✓ Creating the release"
    echo "  ✓ Calculating SHA256"
    echo "  ✓ Updating Homebrew formula"
    echo "  ✓ Committing and pushing changes"
    echo ""
    echo "View progress at: https://github.com/ezoushen/axon/actions"
    echo ""
    echo "Release will be available in ~1-2 minutes at:"
    echo "  https://github.com/ezoushen/axon/releases/tag/v${NEW_VERSION}"
    echo ""
fi
