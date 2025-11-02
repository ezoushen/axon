#!/bin/bash
# Tests for Docker Hub Authentication
# Tests both explicit credentials and Docker CLI config fallback

# Get script directory and source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test framework
source "$SCRIPT_DIR/../test-framework.sh"

# Source the code under test
source "$PROJECT_ROOT/lib/registry-auth.sh"

# ==============================================================================
# Test Helper Functions
# ==============================================================================

# Store mock values in global variables
MOCK_USERNAME=""
MOCK_ACCESS_TOKEN=""

# Create a mock config that returns specific values
setup_mock_config() {
    MOCK_USERNAME=$1
    MOCK_ACCESS_TOKEN=$2
}

# Mock get_registry_config function (global scope)
get_registry_config() {
    local key=$1
    case $key in
        username)
            echo "$MOCK_USERNAME"
            ;;
        access_token)
            echo "$MOCK_ACCESS_TOKEN"
            ;;
    esac
}

# Mock expand_env_vars function (global scope)
expand_env_vars() {
    local value=$1
    # Simple env var expansion for testing
    # Handles ${VAR_NAME} syntax
    if echo "$value" | grep -q '\${'; then
        # Extract variable name
        local var_name=$(echo "$value" | sed 's/.*\${\([^}]*\)}.*/\1/')
        eval echo "\${$var_name}"
    else
        echo "$value"
    fi
}

# ==============================================================================
# Test Cases: Explicit Credentials
# ==============================================================================

test_dockerhub_explicit_credentials_success() {
    setup

    # Setup test data
    export DOCKER_HUB_USERNAME="testuser"
    export DOCKER_HUB_TOKEN="testtoken123"

    setup_mock_config "\${DOCKER_HUB_USERNAME}" "\${DOCKER_HUB_TOKEN}"

    # Mock docker login command
    local capture_file=$(mktemp)
    mock_command_with_capture "docker" 0 "$capture_file" "Login Succeeded"

    # Run the function
    local output=$(auth_docker_hub 2>&1)
    assert_success

    # Verify docker login was called with correct arguments
    local captured_args=$(cat "$capture_file")
    assert_contains "$captured_args" "login"
    assert_contains "$captured_args" "-u"
    assert_contains "$captured_args" "testuser"
    assert_contains "$captured_args" "--password-stdin"

    # Verify success message
    assert_contains "$output" "Successfully authenticated with Docker Hub using credentials"

    # Cleanup
    rm -f "$capture_file"
    teardown
}

test_dockerhub_explicit_credentials_expansion() {
    setup

    # Setup test data with environment variables
    export TEST_USER="myuser"
    export TEST_TOKEN="mytoken456"

    setup_mock_config "\${TEST_USER}" "\${TEST_TOKEN}"

    # Mock docker login command
    mock_command "docker" 0 "Login Succeeded"

    # Run the function
    local output=$(auth_docker_hub 2>&1)
    assert_success

    # Verify environment variable expansion occurred
    assert_contains "$output" "Using explicit credentials"

    teardown
}

test_dockerhub_explicit_credentials_failure() {
    setup

    # Setup test data
    setup_mock_config "baduser" "badtoken"

    # Mock docker login command to fail
    mock_command "docker" 1 "Error: unauthorized"

    # Run the function
    local output=$(auth_docker_hub 2>&1)
    assert_failure

    # Verify failure message
    assert_contains "$output" "Failed to authenticate with Docker Hub"

    teardown
}

# ==============================================================================
# Test Cases: Docker CLI Config Fallback
# ==============================================================================

test_dockerhub_cli_config_success() {
    setup

    # No explicit credentials
    setup_mock_config "" ""

    # Mock Docker config file
    local mock_docker_dir=$(mktemp -d)
    export HOME="$mock_docker_dir"
    mkdir -p "$mock_docker_dir/.docker"

    # Create mock config.json with Docker Hub auth
    cat > "$mock_docker_dir/.docker/config.json" <<EOF
{
  "auths": {
    "https://index.docker.io/v1/": {
      "auth": "dGVzdHVzZXI6dGVzdHBhc3M="
    }
  }
}
EOF

    # Run the function
    local output=$(auth_docker_hub 2>&1)
    assert_success

    # Verify fallback message
    assert_contains "$output" "Using Docker CLI config"
    assert_contains "$output" "Using Docker Hub credentials from ~/.docker/config.json"

    # Cleanup
    rm -rf "$mock_docker_dir"
    teardown
}

test_dockerhub_cli_config_missing_file() {
    setup

    # No explicit credentials
    setup_mock_config "" ""

    # Mock HOME without Docker config
    local mock_home=$(mktemp -d)
    export HOME="$mock_home"

    # Run the function
    local output=$(auth_docker_hub 2>&1)
    assert_failure

    # Verify error message
    assert_contains "$output" "No Docker Hub credentials available"
    assert_contains "$output" "Option 1: Explicit credentials"
    assert_contains "$output" "Option 2: Docker CLI login"

    # Cleanup
    rm -rf "$mock_home"
    teardown
}

test_dockerhub_cli_config_missing_credentials() {
    setup

    # No explicit credentials
    setup_mock_config "" ""

    # Mock Docker config file without Docker Hub auth
    local mock_docker_dir=$(mktemp -d)
    export HOME="$mock_docker_dir"
    mkdir -p "$mock_docker_dir/.docker"

    # Create mock config.json without Docker Hub credentials
    cat > "$mock_docker_dir/.docker/config.json" <<EOF
{
  "auths": {
    "https://some-other-registry.com": {
      "auth": "dGVzdA=="
    }
  }
}
EOF

    # Run the function
    local output=$(auth_docker_hub 2>&1)
    assert_failure

    # Verify error message
    assert_contains "$output" "No Docker Hub credentials found in ~/.docker/config.json"
    assert_contains "$output" "docker login"

    # Cleanup
    rm -rf "$mock_docker_dir"
    teardown
}

# ==============================================================================
# Test Cases: Priority and Fallback
# ==============================================================================

test_dockerhub_explicit_credentials_priority() {
    setup

    # Both explicit credentials AND Docker CLI config present
    export DOCKER_HUB_USERNAME="explicit_user"
    export DOCKER_HUB_TOKEN="explicit_token"

    setup_mock_config "\${DOCKER_HUB_USERNAME}" "\${DOCKER_HUB_TOKEN}"

    # Mock Docker config file (should be ignored)
    local mock_docker_dir=$(mktemp -d)
    export HOME="$mock_docker_dir"
    mkdir -p "$mock_docker_dir/.docker"
    cat > "$mock_docker_dir/.docker/config.json" <<EOF
{
  "auths": {
    "https://index.docker.io/v1/": {
      "auth": "Y2xpX3VzZXI6Y2xpX3Rva2Vu"
    }
  }
}
EOF

    # Mock docker login command
    local capture_file=$(mktemp)
    mock_command_with_capture "docker" 0 "$capture_file" "Login Succeeded"

    # Run the function
    local output=$(auth_docker_hub 2>&1)
    assert_success

    # Verify explicit credentials were used (not CLI config)
    assert_contains "$output" "Using explicit credentials"
    assert_contains "$output" "Successfully authenticated with Docker Hub using credentials"

    # Should NOT contain CLI config message
    if echo "$output" | grep -q "Using Docker CLI config"; then
        echo -e "${RED}  ✗ Expected explicit credentials to take priority over CLI config${NC}"
        rm -rf "$mock_docker_dir"
        rm -f "$capture_file"
        teardown
        return 1
    fi

    # Verify docker login was called with explicit credentials
    local captured_args=$(cat "$capture_file")
    assert_contains "$captured_args" "explicit_user"

    # Cleanup
    rm -rf "$mock_docker_dir"
    rm -f "$capture_file"
    teardown
}

# ==============================================================================
# Run All Tests
# ==============================================================================

echo "========================================"
echo "Docker Hub Authentication Tests"
echo "========================================"
echo ""

# Explicit credentials tests
run_test "test_dockerhub_explicit_credentials_success" test_dockerhub_explicit_credentials_success
run_test "test_dockerhub_explicit_credentials_expansion" test_dockerhub_explicit_credentials_expansion
run_test "test_dockerhub_explicit_credentials_failure" test_dockerhub_explicit_credentials_failure

# Docker CLI config tests
run_test "test_dockerhub_cli_config_success" test_dockerhub_cli_config_success
run_test "test_dockerhub_cli_config_missing_file" test_dockerhub_cli_config_missing_file
run_test "test_dockerhub_cli_config_missing_credentials" test_dockerhub_cli_config_missing_credentials

# Priority tests
run_test "test_dockerhub_explicit_credentials_priority" test_dockerhub_explicit_credentials_priority

# Print summary
print_summary
exit $?
