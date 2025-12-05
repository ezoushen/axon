#!/bin/bash
# AXON - Master Test Runner
# Runs all test suites for the port management feature

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AXON_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Track results
SUITES_RUN=0
SUITES_PASSED=0
SUITES_FAILED=0
FAILED_SUITES=""

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║           AXON Port Management - Full Test Suite              ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

run_test_suite() {
    local suite_name=$1
    local suite_script=$2

    SUITES_RUN=$((SUITES_RUN + 1))

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Running: ${suite_name}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if "$SCRIPT_DIR/$suite_script"; then
        SUITES_PASSED=$((SUITES_PASSED + 1))
        echo ""
        echo -e "${GREEN}✓ ${suite_name} - PASSED${NC}"
    else
        SUITES_FAILED=$((SUITES_FAILED + 1))
        FAILED_SUITES="$FAILED_SUITES\n  - $suite_name"
        echo ""
        echo -e "${RED}✗ ${suite_name} - FAILED${NC}"
    fi
    echo ""
}

# Run all test suites
run_test_suite "Port Manager Tests" "test-port-manager.sh"
run_test_suite "Deployment Flow Tests" "test-deployment-flow.sh"
run_test_suite "Sync Command Tests" "test-sync-command.sh"

# Summary
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                       Test Summary                            ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Test Suites Run: ${SUITES_RUN}"
echo -e "  ${GREEN}Passed: ${SUITES_PASSED}${NC}"
if [ $SUITES_FAILED -gt 0 ]; then
    echo -e "  ${RED}Failed: ${SUITES_FAILED}${NC}"
    echo -e "${RED}Failed Suites:${FAILED_SUITES}${NC}"
fi
echo ""

if [ $SUITES_FAILED -gt 0 ]; then
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    TESTS FAILED                               ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
    exit 1
else
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                  ALL TESTS PASSED                             ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    exit 0
fi
