#!/bin/bash
# Test Framework for AXON
# Provides utilities for mocking commands and asserting results
# Bash 3.2 compatible

# ==============================================================================
# Color Codes
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ==============================================================================
# Test State
# ==============================================================================
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

# ==============================================================================
# Mock Infrastructure
# ==============================================================================
MOCK_DIR=""
ORIGINAL_PATH=""

# Initialize mock environment
setup_mocks() {
    # Create temporary directory for mock commands
    MOCK_DIR=$(mktemp -d)
    ORIGINAL_PATH="$PATH"
    export PATH="$MOCK_DIR:$PATH"
}

# Cleanup mock environment
teardown_mocks() {
    if [ -n "$MOCK_DIR" ] && [ -d "$MOCK_DIR" ]; then
        rm -rf "$MOCK_DIR"
    fi
    export PATH="$ORIGINAL_PATH"
}

# Create a mock command
# Usage: mock_command <command_name> <exit_code> [output]
mock_command() {
    local cmd_name=$1
    local exit_code=$2
    local output=${3:-}

    if [ -z "$MOCK_DIR" ]; then
        echo -e "${RED}Error: Mock environment not initialized. Call setup_mocks first.${NC}" >&2
        return 1
    fi

    local mock_script="$MOCK_DIR/$cmd_name"

    cat > "$mock_script" <<EOF
#!/bin/bash
# Mock for $cmd_name
if [ -n "$output" ]; then
    echo "$output"
fi
exit $exit_code
EOF

    chmod +x "$mock_script"
}

# Create a mock command that captures arguments
# Usage: mock_command_with_capture <command_name> <exit_code> <capture_file> [output]
mock_command_with_capture() {
    local cmd_name=$1
    local exit_code=$2
    local capture_file=$3
    local output=${4:-}

    if [ -z "$MOCK_DIR" ]; then
        echo -e "${RED}Error: Mock environment not initialized. Call setup_mocks first.${NC}" >&2
        return 1
    fi

    local mock_script="$MOCK_DIR/$cmd_name"

    cat > "$mock_script" <<EOF
#!/bin/bash
# Mock for $cmd_name with argument capture
echo "\$@" > "$capture_file"
if [ -n "$output" ]; then
    echo "$output"
fi
exit $exit_code
EOF

    chmod +x "$mock_script"
}

# Create a mock file
# Usage: mock_file <file_path> <content>
mock_file() {
    local file_path=$1
    local content=$2

    local dir=$(dirname "$file_path")
    mkdir -p "$dir"
    echo "$content" > "$file_path"
}

# ==============================================================================
# Assertion Functions
# ==============================================================================

# Assert that a command succeeded (exit code 0)
assert_success() {
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        return 0
    else
        echo -e "${RED}  ✗ Expected success (exit 0), got exit code $exit_code${NC}"
        return 1
    fi
}

# Assert that a command failed (exit code non-zero)
assert_failure() {
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        return 0
    else
        echo -e "${RED}  ✗ Expected failure (exit non-zero), got exit code 0${NC}"
        return 1
    fi
}

# Assert that two strings are equal
# Usage: assert_equals <expected> <actual> [message]
assert_equals() {
    local expected=$1
    local actual=$2
    local message=${3:-}

    if [ "$expected" = "$actual" ]; then
        return 0
    else
        echo -e "${RED}  ✗ Assertion failed${NC}"
        if [ -n "$message" ]; then
            echo -e "${RED}    Message: $message${NC}"
        fi
        echo -e "${RED}    Expected: '$expected'${NC}"
        echo -e "${RED}    Actual:   '$actual'${NC}"
        return 1
    fi
}

# Assert that a string contains a substring
# Usage: assert_contains <haystack> <needle> [message]
assert_contains() {
    local haystack=$1
    local needle=$2
    local message=${3:-}

    if echo "$haystack" | grep -q "$needle"; then
        return 0
    else
        echo -e "${RED}  ✗ Assertion failed${NC}"
        if [ -n "$message" ]; then
            echo -e "${RED}    Message: $message${NC}"
        fi
        echo -e "${RED}    Expected to contain: '$needle'${NC}"
        echo -e "${RED}    Actual: '$haystack'${NC}"
        return 1
    fi
}

# Assert that a file exists
# Usage: assert_file_exists <file_path> [message]
assert_file_exists() {
    local file_path=$1
    local message=${2:-}

    if [ -f "$file_path" ]; then
        return 0
    else
        echo -e "${RED}  ✗ Assertion failed${NC}"
        if [ -n "$message" ]; then
            echo -e "${RED}    Message: $message${NC}"
        fi
        echo -e "${RED}    Expected file to exist: $file_path${NC}"
        return 1
    fi
}

# Assert that a file does not exist
# Usage: assert_file_not_exists <file_path> [message]
assert_file_not_exists() {
    local file_path=$1
    local message=${2:-}

    if [ ! -f "$file_path" ]; then
        return 0
    else
        echo -e "${RED}  ✗ Assertion failed${NC}"
        if [ -n "$message" ]; then
            echo -e "${RED}    Message: $message${NC}"
        fi
        echo -e "${RED}    Expected file to not exist: $file_path${NC}"
        return 1
    fi
}

# ==============================================================================
# Test Runner
# ==============================================================================

# Run a test function
# Usage: run_test <test_name> <test_function>
run_test() {
    local test_name=$1
    local test_function=$2

    CURRENT_TEST="$test_name"
    TESTS_RUN=$((TESTS_RUN + 1))

    echo -e "${BLUE}Running: $test_name${NC}"

    # Run test in subshell to isolate environment
    (
        $test_function
    )
    local result=$?

    if [ $result -eq 0 ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}  ✓ PASSED${NC}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}  ✗ FAILED${NC}"
    fi

    echo ""
}

# Print test summary
print_summary() {
    echo "========================================"
    echo -e "${BLUE}Test Summary${NC}"
    echo "========================================"
    echo "Total tests: $TESTS_RUN"
    echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
    echo "========================================"

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed.${NC}"
        return 1
    fi
}

# ==============================================================================
# Test Suite Setup/Teardown
# ==============================================================================

# Setup function called before each test
setup() {
    setup_mocks
}

# Teardown function called after each test
teardown() {
    teardown_mocks
}
