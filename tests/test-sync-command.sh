#!/bin/bash
# AXON - Sync Command Test Suite
# Tests the sync command argument parsing and behavior

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AXON_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ==============================================================================
# Test Utilities
# ==============================================================================

log_test() {
    echo -e "${CYAN}[TEST]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

run_test() {
    local test_name=$1
    local test_func=$2

    TESTS_RUN=$((TESTS_RUN + 1))
    log_test "$test_name"

    if $test_func 2>/dev/null; then
        log_pass "$test_name"
    else
        log_fail "$test_name"
    fi
}

assert_contains() {
    local haystack=$1
    local needle=$2
    local msg=${3:-"String should contain '$needle'"}

    if echo "$haystack" | grep -q "$needle"; then
        return 0
    else
        echo "  $msg"
        return 1
    fi
}

assert_exit_code() {
    local expected=$1
    local actual=$2
    local msg=${3:-"Expected exit code $expected but got $actual"}

    if [ "$expected" = "$actual" ]; then
        return 0
    else
        echo "  $msg"
        return 1
    fi
}

# ==============================================================================
# Test: Sync Command Help
# ==============================================================================

test_sync_help_displays() {
    local output=$("$AXON_DIR/axon" sync --help 2>&1)
    assert_contains "$output" "Synchronize nginx upstream"
}

test_sync_help_shows_options() {
    local output=$("$AXON_DIR/axon" sync --help 2>&1)
    # Check each option exists in the output
    echo "$output" | grep -q "\-\-all" && \
    echo "$output" | grep -q "\-\-force" && \
    echo "$output" | grep -q "\-\-config"
}

test_sync_help_shows_examples() {
    local output=$("$AXON_DIR/axon" sync --help 2>&1)
    assert_contains "$output" "axon sync production"
}

# ==============================================================================
# Test: Sync Command Argument Validation
# ==============================================================================

test_sync_requires_environment() {
    local output=$("$AXON_DIR/axon" sync 2>&1 || true)
    assert_contains "$output" "Environment parameter required"
}

test_sync_rejects_both_all_and_env() {
    # The sync.sh script should reject both --all and environment
    local output=$("$AXON_DIR/cmd/sync.sh" --all production 2>&1 || true)
    assert_contains "$output" "Cannot specify both"
}

# ==============================================================================
# Test: Sync Command for Static Sites
# ==============================================================================

test_sync_rejects_static_type() {
    # Create a temp config with static type
    local temp_dir=$(mktemp -d)
    cat > "$temp_dir/axon.config.yml" <<EOF
product:
  name: staticsite
  type: static
EOF

    local output=$("$AXON_DIR/cmd/sync.sh" --config "$temp_dir/axon.config.yml" production 2>&1 || true)
    rm -rf "$temp_dir"

    assert_contains "$output" "only available for Docker"
}

# ==============================================================================
# Test: CLI Integration
# ==============================================================================

test_axon_sync_in_help() {
    local output=$("$AXON_DIR/axon" --help 2>&1)
    assert_contains "$output" "sync"
}

test_axon_sync_in_utility_commands() {
    local output=$("$AXON_DIR/axon" --help 2>&1)
    # sync should be in the UTILITY COMMANDS section
    assert_contains "$output" "sync <env|--all>"
}

# ==============================================================================
# Test: Command Parser Integration
# ==============================================================================

test_sync_is_valid_command() {
    source "$AXON_DIR/lib/command-parser.sh"
    validate_command "sync"
}

test_sync_requires_env_in_parser() {
    source "$AXON_DIR/lib/command-parser.sh"
    command_requires_env "sync"
}

# ==============================================================================
# Run Tests
# ==============================================================================

echo ""
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}AXON Sync Command Test Suite${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""

echo -e "${BLUE}Testing Help Output...${NC}"
echo ""
run_test "Sync help displays description" test_sync_help_displays
run_test "Sync help shows options" test_sync_help_shows_options
run_test "Sync help shows examples" test_sync_help_shows_examples

echo ""
echo -e "${BLUE}Testing Argument Validation...${NC}"
echo ""
run_test "Sync requires environment" test_sync_requires_environment
run_test "Sync rejects both --all and environment" test_sync_rejects_both_all_and_env

echo ""
echo -e "${BLUE}Testing Product Type Validation...${NC}"
echo ""
run_test "Sync rejects static site type" test_sync_rejects_static_type

echo ""
echo -e "${BLUE}Testing CLI Integration...${NC}"
echo ""
run_test "Sync appears in axon --help" test_axon_sync_in_help
run_test "Sync appears in utility commands" test_axon_sync_in_utility_commands

echo ""
echo -e "${BLUE}Testing Command Parser...${NC}"
echo ""
run_test "Sync is valid command" test_sync_is_valid_command
run_test "Sync requires environment in parser" test_sync_requires_env_in_parser

# ==============================================================================
# Summary
# ==============================================================================

echo ""
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}Test Summary${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""
echo -e "  Total Tests: ${TESTS_RUN}"
echo -e "  ${GREEN}Passed: ${TESTS_PASSED}${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "  ${RED}Failed: ${TESTS_FAILED}${NC}"
fi
echo ""

# Exit with appropriate code
if [ $TESTS_FAILED -gt 0 ]; then
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
