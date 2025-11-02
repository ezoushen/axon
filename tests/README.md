# AXON Test Suite

This directory contains the test framework and test suites for AXON deployment scripts.

## Overview

The test framework provides:
- **Mock infrastructure** for commands and files
- **Assertion functions** for validating results
- **Test isolation** via setup/teardown mechanisms
- **Comprehensive reporting** with color-coded output

## Running Tests

### Run All Tests

```bash
./tests/run-tests.sh
```

### Run Individual Test Suites

```bash
# Docker Hub authentication tests
./tests/lib/test-registry-auth-dockerhub.sh

# AWS ECR authentication tests
./tests/lib/test-registry-auth-aws-ecr.sh
```

## Test Framework

The test framework (`test-framework.sh`) provides the following utilities:

### Mock Functions

- `setup_mocks()` - Initialize mock environment
- `teardown_mocks()` - Cleanup mock environment
- `mock_command <name> <exit_code> [output]` - Create a mock command
- `mock_command_with_capture <name> <exit_code> <capture_file> [output]` - Mock command that captures arguments
- `mock_file <path> <content>` - Create a mock file

### Assertion Functions

- `assert_success()` - Assert command succeeded (exit code 0)
- `assert_failure()` - Assert command failed (exit code non-zero)
- `assert_equals <expected> <actual> [message]` - Assert string equality
- `assert_contains <haystack> <needle> [message]` - Assert string contains substring
- `assert_file_exists <path> [message]` - Assert file exists
- `assert_file_not_exists <path> [message]` - Assert file doesn't exist

### Test Runner Functions

- `run_test <name> <function>` - Run a test function
- `print_summary()` - Print test results summary

## Test Structure

Each test file should follow this structure:

```bash
#!/bin/bash

# Source test framework
source "$SCRIPT_DIR/../test-framework.sh"

# Source code under test
source "$PROJECT_ROOT/lib/registry-auth.sh"

# Test helper functions (mocks, setup, etc.)
setup_mock_config() {
    # ...
}

# Test cases
test_feature_success() {
    setup

    # Arrange
    setup_mock_config "value1" "value2"
    mock_command "command" 0 "output"

    # Act
    local output=$(function_under_test 2>&1)

    # Assert
    assert_success
    assert_contains "$output" "expected message"

    teardown
}

# Run all tests
run_test "test_feature_success" test_feature_success
print_summary
exit $?
```

## Current Test Coverage

### Docker Hub Authentication (`test-registry-auth-dockerhub.sh`)

Tests for `auth_docker_hub()` function:

1. **Explicit Credentials**
   - Success with environment variables
   - Environment variable expansion
   - Authentication failure handling

2. **Docker CLI Config Fallback**
   - Success using ~/.docker/config.json
   - Missing config file error handling
   - Missing credentials in config file error handling

3. **Priority and Fallback**
   - Explicit credentials take priority over CLI config

**Total: 7 tests**

### AWS ECR Authentication (`test-registry-auth-aws-ecr.sh`)

Tests for `auth_aws_ecr()` function:

1. **AWS CLI Profile**
   - Success with profile authentication
   - Missing AWS CLI error handling
   - Authentication failure handling

2. **Direct Credentials**
   - Success with access key and secret key
   - Success with temporary credentials (session token)
   - Missing secret key error handling

3. **Credentials File**
   - Success using credentials file
   - Missing file error handling

4. **Environment Variable Expansion**
   - Region expansion with environment variable
   - Region expansion with default value

5. **Priority and Configuration**
   - Direct credentials take priority over profile
   - Missing region error handling
   - No authentication method configured error handling

**Total: 13 tests**

## Writing New Tests

### 1. Create Test File

Create a new test file in `tests/lib/`:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../test-framework.sh"
source "$PROJECT_ROOT/lib/your-script.sh"
```

### 2. Add Mock Setup

Define global mock variables and setup functions:

```bash
# Global mock variables
MOCK_VALUE=""

# Mock setup function
setup_mock_function() {
    MOCK_VALUE=$1
}

# Mock the actual function being called
your_function() {
    echo "$MOCK_VALUE"
}
```

### 3. Write Test Cases

Follow the Arrange-Act-Assert pattern:

```bash
test_your_feature() {
    setup

    # Arrange: Setup mocks and test data
    setup_mock_function "test_value"
    mock_command "dependency" 0 "output"

    # Act: Execute the function under test
    local output=$(function_under_test 2>&1)
    local result=$?

    # Assert: Verify results
    assert_success
    assert_contains "$output" "expected_string"

    teardown
}
```

### 4. Register and Run Tests

```bash
run_test "test_your_feature" test_your_feature
print_summary
exit $?
```

### 5. Add to Test Runner

Update `run-tests.sh` to include your test file:

```bash
if [ -f "$SCRIPT_DIR/lib/test-your-feature.sh" ]; then
    run_suite "$SCRIPT_DIR/lib/test-your-feature.sh"
    [ $? -ne 0 ] && ALL_PASSED=1
fi
```

## Best Practices

1. **Test Isolation**: Each test should be independent and not rely on other tests
2. **Mock External Dependencies**: Mock all system commands, file system access, and external services
3. **Clear Test Names**: Use descriptive names that explain what is being tested
4. **Arrange-Act-Assert**: Follow the AAA pattern for clarity
5. **Test Both Success and Failure**: Test happy paths and error conditions
6. **Cleanup**: Always call `teardown` to clean up mocks and temporary files

## Bash 3.2 Compatibility

All tests are compatible with Bash 3.2 (macOS default):
- No associative arrays
- No `local -n` (nameref)
- No `readarray` / `mapfile`
- Use global variables for test state

## Continuous Integration

These tests can be integrated into CI/CD pipelines:

```yaml
# Example GitHub Actions workflow
- name: Run AXON Tests
  run: ./tests/run-tests.sh
```

The test runner exits with:
- **0** if all tests pass
- **1** if any test fails

## Troubleshooting

### Tests Fail with "command not found"

Ensure mocks are set up before calling the function under test.

### Assertions Fail with Unexpected Output

Use `echo "$output"` to inspect the actual output and adjust assertions.

### Mock Commands Not Working

Check that:
1. `setup_mocks()` was called
2. Mock command name matches exactly
3. `$PATH` includes the mock directory

## Future Improvements

- Add tests for static site deployment functions
- Add tests for nginx configuration generation
- Add integration tests with real Docker commands (optional)
- Add performance benchmarks
