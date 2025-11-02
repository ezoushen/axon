#!/bin/bash
# Test Runner for AXON
# Runs all test suites and reports results

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test results
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

# Run a test suite
run_suite() {
    local suite_path=$1
    local suite_name=$(basename "$suite_path")

    TOTAL_SUITES=$((TOTAL_SUITES + 1))

    echo ""
    echo "========================================"
    echo -e "${BLUE}Running Test Suite: $suite_name${NC}"
    echo "========================================"
    echo ""

    # Run the test suite
    bash "$suite_path"
    local result=$?

    if [ $result -eq 0 ]; then
        PASSED_SUITES=$((PASSED_SUITES + 1))
        echo -e "${GREEN}✓ Test suite passed: $suite_name${NC}"
    else
        FAILED_SUITES=$((FAILED_SUITES + 1))
        echo -e "${RED}✗ Test suite failed: $suite_name${NC}"
    fi

    return $result
}

# Main execution
echo ""
echo "========================================"
echo -e "${BLUE}AXON Test Runner${NC}"
echo "========================================"

# Find and run all test files
ALL_PASSED=0

# Registry authentication tests
if [ -f "$SCRIPT_DIR/lib/test-registry-auth-dockerhub.sh" ]; then
    run_suite "$SCRIPT_DIR/lib/test-registry-auth-dockerhub.sh"
    [ $? -ne 0 ] && ALL_PASSED=1
fi

if [ -f "$SCRIPT_DIR/lib/test-registry-auth-aws-ecr.sh" ]; then
    run_suite "$SCRIPT_DIR/lib/test-registry-auth-aws-ecr.sh"
    [ $? -ne 0 ] && ALL_PASSED=1
fi

# Print overall summary
echo ""
echo "========================================"
echo -e "${BLUE}Overall Test Summary${NC}"
echo "========================================"
echo "Total test suites: $TOTAL_SUITES"
echo -e "${GREEN}Passed: $PASSED_SUITES${NC}"
echo -e "${RED}Failed: $FAILED_SUITES${NC}"
echo "========================================"

if [ $ALL_PASSED -eq 0 ]; then
    echo -e "${GREEN}All test suites passed!${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}Some test suites failed.${NC}"
    echo ""
    exit 1
fi
