#!/bin/bash
# Tests for AWS ECR Authentication
# Tests AWS CLI profile, direct credentials, and credentials file methods

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
MOCK_PROFILE=""
MOCK_REGION=""
MOCK_ACCESS_KEY_ID=""
MOCK_SECRET_ACCESS_KEY=""
MOCK_SESSION_TOKEN=""
MOCK_CREDENTIALS_FILE=""
MOCK_ACCOUNT_ID=""

# Create a mock config that returns specific values
setup_mock_config_ecr() {
    MOCK_PROFILE=$1
    MOCK_REGION=$2
    MOCK_ACCESS_KEY_ID=$3
    MOCK_SECRET_ACCESS_KEY=$4
    MOCK_SESSION_TOKEN=$5
    MOCK_CREDENTIALS_FILE=$6
    MOCK_ACCOUNT_ID=$7
}

# Mock get_registry_config function (global scope)
get_registry_config() {
    local key=$1
    case $key in
        profile)
            echo "$MOCK_PROFILE"
            ;;
        region)
            echo "$MOCK_REGION"
            ;;
        access_key_id)
            echo "$MOCK_ACCESS_KEY_ID"
            ;;
        secret_access_key)
            echo "$MOCK_SECRET_ACCESS_KEY"
            ;;
        session_token)
            echo "$MOCK_SESSION_TOKEN"
            ;;
        credentials_file)
            echo "$MOCK_CREDENTIALS_FILE"
            ;;
    esac
}

# Mock build_registry_url function (global scope)
build_registry_url() {
    if [ -n "$MOCK_ACCOUNT_ID" ]; then
        local region_value=$(expand_env_vars "$MOCK_REGION")
        echo "${MOCK_ACCOUNT_ID}.dkr.ecr.${region_value}.amazonaws.com"
    fi
}

# Mock expand_env_vars function (global scope)
expand_env_vars() {
    local value=$1
    # Handle ${VAR_NAME:-default} syntax
    if echo "$value" | grep -q '\${.*:-'; then
        local var_name=$(echo "$value" | sed 's/.*\${\([^:]*\):-\([^}]*\)}.*/\1/')
        local default_val=$(echo "$value" | sed 's/.*\${\([^:]*\):-\([^}]*\)}.*/\2/')
        local var_value=$(eval echo "\${$var_name}")
        if [ -z "$var_value" ]; then
            echo "$default_val"
        else
            echo "$var_value"
        fi
    elif echo "$value" | grep -q '\${'; then
        # Simple ${VAR_NAME} syntax
        local var_name=$(echo "$value" | sed 's/.*\${\([^}]*\)}.*/\1/')
        eval echo "\${$var_name}"
    else
        echo "$value"
    fi
}

# ==============================================================================
# Test Cases: AWS CLI Profile
# ==============================================================================

test_aws_ecr_profile_success() {
    setup

    # Setup test data
    setup_mock_config_ecr "default" "us-east-1" "" "" "" "" "123456789012"

    # Mock AWS CLI
    mock_command "aws" 0 "password_token_here"

    # Mock docker login
    mock_command "docker" 0 "Login Succeeded"

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_success

    # Verify messages
    assert_contains "$output" "Using AWS CLI profile"
    assert_contains "$output" "Successfully authenticated with AWS ECR"
    assert_contains "$output" "AWS CLI profile default"

    teardown
}

test_aws_ecr_profile_missing_aws_cli() {
    setup

    setup_mock_config_ecr "default" "us-east-1" "" "" "" "" "123456789012"

    # Don't mock AWS CLI - simulate it's not installed

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_failure

    # Verify error message
    assert_contains "$output" "AWS CLI is not installed"
    assert_contains "$output" "brew install awscli"

    teardown
}

test_aws_ecr_profile_failure() {
    setup

    setup_mock_config_ecr "default" "us-east-1" "" "" "" "" "123456789012"

    # Mock AWS CLI to fail
    mock_command "aws" 1 ""

    # Mock docker login
    mock_command "docker" 1 "Error"

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_failure

    # Verify failure message
    assert_contains "$output" "Failed to authenticate with AWS ECR"
    assert_contains "$output" "Troubleshooting"

    teardown
}

# ==============================================================================
# Test Cases: Direct Credentials
# ==============================================================================

test_aws_ecr_direct_credentials_success() {
    setup

    # Setup test data with direct credentials
    export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
    export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

    setup_mock_config_ecr "" "us-west-2" "\${AWS_ACCESS_KEY_ID}" "\${AWS_SECRET_ACCESS_KEY}" "" "" "123456789012"

    # Mock AWS CLI
    local capture_file=$(mktemp)
    mock_command_with_capture "aws" 0 "$capture_file" "password_token_here"

    # Mock docker login
    mock_command "docker" 0 "Login Succeeded"

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_success

    # Verify messages
    assert_contains "$output" "Using direct AWS credentials"
    assert_contains "$output" "Successfully authenticated with AWS ECR"
    assert_contains "$output" "direct credentials"

    # Cleanup
    rm -f "$capture_file"
    teardown
}

test_aws_ecr_direct_credentials_with_session_token() {
    setup

    # Setup test data with session token
    export AWS_ACCESS_KEY_ID="ASIAIOSFODNN7EXAMPLE"
    export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    export AWS_SESSION_TOKEN="AQoDYXdzEJr...<session token>"

    setup_mock_config_ecr "" "ap-northeast-1" "\${AWS_ACCESS_KEY_ID}" "\${AWS_SECRET_ACCESS_KEY}" "\${AWS_SESSION_TOKEN}" "" "123456789012"

    # Mock AWS CLI
    mock_command "aws" 0 "password_token_here"

    # Mock docker login
    mock_command "docker" 0 "Login Succeeded"

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_success

    # Verify session token was used
    assert_contains "$output" "Using direct AWS credentials"
    assert_contains "$output" "Successfully authenticated with AWS ECR"

    teardown
}

test_aws_ecr_direct_credentials_missing_secret() {
    setup

    # Setup with only access key (missing secret)
    export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"

    setup_mock_config_ecr "" "us-east-1" "\${AWS_ACCESS_KEY_ID}" "" "" "" "123456789012"

    # Mock AWS CLI
    mock_command "aws" 0

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_failure

    # Verify error message shows available auth methods
    assert_contains "$output" "No AWS authentication method configured"
    assert_contains "$output" "Option 1: AWS CLI profile"
    assert_contains "$output" "Option 2: Direct credentials"

    teardown
}

# ==============================================================================
# Test Cases: Credentials File
# ==============================================================================

test_aws_ecr_credentials_file_success() {
    setup

    # Create mock credentials file
    local creds_file=$(mktemp)
    cat > "$creds_file" <<EOF
[custom]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
EOF

    setup_mock_config_ecr "custom" "eu-west-1" "" "" "" "$creds_file" "123456789012"

    # Mock AWS CLI
    mock_command "aws" 0 "password_token_here"

    # Mock docker login
    mock_command "docker" 0 "Login Succeeded"

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_success

    # Verify messages
    assert_contains "$output" "Using AWS credentials file"
    assert_contains "$output" "Successfully authenticated with AWS ECR"
    assert_contains "$output" "credentials file with profile custom"

    # Cleanup
    rm -f "$creds_file"
    teardown
}

test_aws_ecr_credentials_file_not_found() {
    setup

    # Non-existent credentials file
    setup_mock_config_ecr "" "us-east-1" "" "" "" "/nonexistent/credentials" "123456789012"

    # Mock AWS CLI
    mock_command "aws" 0

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_failure

    # Verify error message
    assert_contains "$output" "Credentials file not found"

    teardown
}

# ==============================================================================
# Test Cases: Environment Variable Expansion
# ==============================================================================

test_aws_ecr_env_var_expansion_region() {
    setup

    # Test region with default value
    export AWS_REGION="ap-southeast-1"

    setup_mock_config_ecr "default" "\${AWS_REGION:-us-east-1}" "" "" "" "" "123456789012"

    # Mock AWS CLI
    mock_command "aws" 0 "password_token_here"

    # Mock docker login
    mock_command "docker" 0 "Login Succeeded"

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_success

    # Verify region was expanded correctly
    assert_contains "$output" "ap-southeast-1"

    teardown
}

test_aws_ecr_env_var_expansion_region_default() {
    setup

    # Test region default value when env var not set
    unset AWS_REGION

    setup_mock_config_ecr "default" "\${AWS_REGION:-eu-central-1}" "" "" "" "" "123456789012"

    # Mock AWS CLI
    mock_command "aws" 0 "password_token_here"

    # Mock docker login
    mock_command "docker" 0 "Login Succeeded"

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_success

    # Verify default region was used
    assert_contains "$output" "eu-central-1"

    teardown
}

# ==============================================================================
# Test Cases: Priority and Configuration Errors
# ==============================================================================

test_aws_ecr_direct_credentials_priority() {
    setup

    # Setup both direct credentials AND profile
    export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
    export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

    setup_mock_config_ecr "should-be-ignored" "us-east-1" "\${AWS_ACCESS_KEY_ID}" "\${AWS_SECRET_ACCESS_KEY}" "" "" "123456789012"

    # Mock AWS CLI
    mock_command "aws" 0 "password_token_here"

    # Mock docker login
    mock_command "docker" 0 "Login Succeeded"

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_success

    # Verify direct credentials took priority
    assert_contains "$output" "Using direct AWS credentials"
    assert_contains "$output" "direct credentials"

    # Should NOT use profile
    if echo "$output" | grep -q "AWS CLI profile should-be-ignored"; then
        echo -e "${RED}  ✗ Expected direct credentials to take priority over profile${NC}"
        teardown
        return 1
    fi

    teardown
}

test_aws_ecr_missing_region() {
    setup

    # Missing region
    setup_mock_config_ecr "default" "" "" "" "" "" "123456789012"

    # Mock AWS CLI
    mock_command "aws" 0

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_failure

    # Verify error message
    assert_contains "$output" "registry.aws_ecr.region not configured"

    teardown
}

test_aws_ecr_no_auth_method() {
    setup

    # No auth method configured
    setup_mock_config_ecr "" "us-east-1" "" "" "" "" "123456789012"

    # Mock AWS CLI
    mock_command "aws" 0

    # Run the function
    local output=$(auth_aws_ecr 2>&1)
    assert_failure

    # Verify error message lists all options
    assert_contains "$output" "No AWS authentication method configured"
    assert_contains "$output" "Option 1: AWS CLI profile"
    assert_contains "$output" "Option 2: Direct credentials"
    assert_contains "$output" "Option 3: Credentials file"

    teardown
}

# ==============================================================================
# Run All Tests
# ==============================================================================

echo "========================================"
echo "AWS ECR Authentication Tests"
echo "========================================"
echo ""

# AWS CLI Profile tests
run_test "test_aws_ecr_profile_success" test_aws_ecr_profile_success
run_test "test_aws_ecr_profile_missing_aws_cli" test_aws_ecr_profile_missing_aws_cli
run_test "test_aws_ecr_profile_failure" test_aws_ecr_profile_failure

# Direct credentials tests
run_test "test_aws_ecr_direct_credentials_success" test_aws_ecr_direct_credentials_success
run_test "test_aws_ecr_direct_credentials_with_session_token" test_aws_ecr_direct_credentials_with_session_token
run_test "test_aws_ecr_direct_credentials_missing_secret" test_aws_ecr_direct_credentials_missing_secret

# Credentials file tests
run_test "test_aws_ecr_credentials_file_success" test_aws_ecr_credentials_file_success
run_test "test_aws_ecr_credentials_file_not_found" test_aws_ecr_credentials_file_not_found

# Environment variable expansion tests
run_test "test_aws_ecr_env_var_expansion_region" test_aws_ecr_env_var_expansion_region
run_test "test_aws_ecr_env_var_expansion_region_default" test_aws_ecr_env_var_expansion_region_default

# Priority and error tests
run_test "test_aws_ecr_direct_credentials_priority" test_aws_ecr_direct_credentials_priority
run_test "test_aws_ecr_missing_region" test_aws_ecr_missing_region
run_test "test_aws_ecr_no_auth_method" test_aws_ecr_no_auth_method

# Print summary
print_summary
exit $?
