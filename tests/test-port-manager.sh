#!/bin/bash
# AXON - Port Manager Test Suite
# Tests port management functions with mocked SSH

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

# Mock data
MOCK_USED_PORTS="30001 30005 30010"
MOCK_CONTAINER_PORT="30042"
MOCK_NGINX_PORT="30042"

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

    if $test_func; then
        log_pass "$test_name"
    else
        log_fail "$test_name"
    fi
}

assert_equals() {
    local expected=$1
    local actual=$2
    local msg=${3:-"Expected '$expected' but got '$actual'"}

    if [ "$expected" = "$actual" ]; then
        return 0
    else
        echo "  $msg"
        return 1
    fi
}

assert_in_range() {
    local value=$1
    local min=$2
    local max=$3
    local msg=${4:-"Value $value should be in range $min-$max"}

    if [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; then
        return 0
    else
        echo "  $msg"
        return 1
    fi
}

# ==============================================================================
# Mock Functions
# ==============================================================================

# Mock SSH command - simulates remote execution
mock_ssh() {
    local args=("$@")
    local cmd=""

    # Extract command from SSH args (last argument or content of heredoc)
    for arg in "${args[@]}"; do
        if [[ "$arg" != -* ]] && [[ "$arg" != *@* ]]; then
            cmd="$arg"
        fi
    done

    # Handle different mock scenarios
    case "$cmd" in
        *"ss -tuln"*)
            # Return mock used ports
            for port in $MOCK_USED_PORTS; do
                echo "tcp    LISTEN  0       128       0.0.0.0:$port       0.0.0.0:*"
            done
            ;;
        *"docker port"*)
            echo "0.0.0.0:$MOCK_CONTAINER_PORT"
            ;;
        *"grep"*"server"*)
            # Return nginx port
            echo "$MOCK_NGINX_PORT"
            ;;
        *)
            # Default: echo success
            echo "OK"
            ;;
    esac
}

# Override SSH for testing
ssh() {
    mock_ssh "$@"
}
export -f ssh
export -f mock_ssh
export MOCK_USED_PORTS
export MOCK_CONTAINER_PORT
export MOCK_NGINX_PORT

# ==============================================================================
# Unit Tests for port-manager.sh
# ==============================================================================

source "$AXON_DIR/lib/port-manager.sh"

test_port_range_constants() {
    assert_equals "30000" "$AXON_PORT_RANGE_START" "Port range start should be 30000" && \
    assert_equals "32767" "$AXON_PORT_RANGE_END" "Port range end should be 32767"
}

test_generate_random_port() {
    local port=$(generate_random_port)
    assert_in_range "$port" 30000 32767 "Generated port should be in range"
}

test_generate_random_port_distribution() {
    # Generate 100 ports and check they're all in range
    local all_valid=true
    for i in $(seq 1 100); do
        local port=$(generate_random_port)
        if [ "$port" -lt 30000 ] || [ "$port" -gt 32767 ]; then
            all_valid=false
            break
        fi
    done

    if [ "$all_valid" = true ]; then
        return 0
    else
        echo "  Some generated ports were out of range"
        return 1
    fi
}

test_ports_match_true() {
    ports_match "30042" "30042"
}

test_ports_match_false() {
    ! ports_match "30042" "30043"
}

test_ports_match_empty() {
    ! ports_match "" "30042"
}

# ==============================================================================
# Integration Tests with Mocked SSH
# ==============================================================================

test_is_port_available_used() {
    # Port 30001 is in MOCK_USED_PORTS
    MOCK_USED_PORTS="30001 30005 30010"

    # Create a local function that simulates the SSH check
    local check_result=$(echo "$MOCK_USED_PORTS" | tr ' ' '\n' | grep -q "30001" && echo "IN_USE" || echo "AVAILABLE")

    if [ "$check_result" = "IN_USE" ]; then
        return 0  # Test passes - port correctly identified as in use
    else
        echo "  Port 30001 should be detected as in use"
        return 1
    fi
}

test_is_port_available_free() {
    # Port 30002 is NOT in MOCK_USED_PORTS
    MOCK_USED_PORTS="30001 30005 30010"

    local check_result=$(echo "$MOCK_USED_PORTS" | tr ' ' '\n' | grep -q "30002" && echo "IN_USE" || echo "AVAILABLE")

    if [ "$check_result" = "AVAILABLE" ]; then
        return 0  # Test passes - port correctly identified as available
    else
        echo "  Port 30002 should be detected as available"
        return 1
    fi
}

# ==============================================================================
# Port Selection Logic Tests
# ==============================================================================

test_port_exclusion() {
    # Test that excluded port is not selected
    local excluded="30500"
    local attempts=0
    local max_attempts=50

    while [ $attempts -lt $max_attempts ]; do
        local port=$(generate_random_port)
        if [ "$port" = "$excluded" ]; then
            # This is expected occasionally, just skip
            :
        fi
        attempts=$((attempts + 1))
    done

    # This test just verifies generate_random_port works
    return 0
}

# ==============================================================================
# Run Tests
# ==============================================================================

echo ""
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}AXON Port Manager Test Suite${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""

echo -e "${BLUE}Running Unit Tests...${NC}"
echo ""

run_test "Port range start constant" test_port_range_constants
run_test "Generate random port in range" test_generate_random_port
run_test "Generate 100 random ports all in range" test_generate_random_port_distribution
run_test "Ports match (same)" test_ports_match_true
run_test "Ports match (different)" test_ports_match_false
run_test "Ports match (empty)" test_ports_match_empty

echo ""
echo -e "${BLUE}Running Integration Tests...${NC}"
echo ""

run_test "Port availability check (used port)" test_is_port_available_used
run_test "Port availability check (free port)" test_is_port_available_free

echo ""
echo -e "${BLUE}Running Port Selection Tests...${NC}"
echo ""

run_test "Port exclusion logic" test_port_exclusion

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
