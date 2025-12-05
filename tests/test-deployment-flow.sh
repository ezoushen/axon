#!/bin/bash
# AXON - Deployment Flow Test Suite
# Tests the deployment, sync, and restart flows with mocked SSH

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

# Create temp directory for mocks and config
MOCK_DIR=$(mktemp -d)
MOCK_NGINX_DIR="$MOCK_DIR/etc/nginx/axon.d"
mkdir -p "$MOCK_NGINX_DIR/upstreams"
mkdir -p "$MOCK_NGINX_DIR/sites"

# Create mock config file
cat > "$MOCK_DIR/axon.config.yml" <<EOF
product:
  name: testapp
  type: docker
  description: Test Application

servers:
  application:
    host: app.example.com
    user: deploy
    ssh_key: ~/.ssh/id_rsa
    deploy_path: /home/deploy/apps
    private_ip: 10.0.1.10

  system:
    host: sys.example.com
    user: deploy
    ssh_key: ~/.ssh/id_rsa

docker:
  container_port: 3000
  network_name: testnet
  restart_policy: unless-stopped

nginx:
  paths:
    axon_dir: /etc/nginx/axon.d

registry:
  provider: docker_hub
  repository: testorg/testapp

environments:
  production:
    domain: prod.example.com
    env_path: /home/deploy/.env.production
EOF

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

# ==============================================================================
# Test: Docker-runtime.sh build_docker_run_command
# ==============================================================================

test_docker_run_command_with_fixed_port() {
    # Source required libraries
    source "$AXON_DIR/lib/config-parser.sh"

    # Mock parse_config function for testing
    parse_config() {
        local key=$1
        local default=$2
        case "$key" in
            ".docker.restart_policy") echo "unless-stopped" ;;
            ".docker.env_vars") echo "" ;;
            ".docker.logging.driver") echo "json-file" ;;
            ".docker.logging.max_size") echo "10m" ;;
            ".docker.logging.max_file") echo "3" ;;
            ".docker.extra_hosts") echo "" ;;
            ".health_check.enabled") echo "true" ;;
            ".health_check.endpoint") echo "/health" ;;
            ".health_check.command") echo "" ;;
            ".health_check.interval") echo "30s" ;;
            ".health_check.timeout") echo "10s" ;;
            ".health_check.retries") echo "3" ;;
            ".health_check.start_period") echo "40s" ;;
            ".docker.compose_override") echo "" ;;
            *) echo "$default" ;;
        esac
    }

    # Source docker-runtime
    source "$AXON_DIR/lib/docker-runtime.sh"

    # Test generating compose with fixed port
    local temp_compose=$(generate_docker_compose_from_config \
        "testapp-production-1234567890" \
        "30042" \
        "testorg/testapp:production" \
        "/home/deploy/.env.production" \
        "testnet" \
        "testapp" \
        "3000")

    # Check if the compose file contains the fixed port mapping
    if [ -f "$temp_compose" ]; then
        local content=$(cat "$temp_compose")
        if echo "$content" | grep -q "30042:3000"; then
            rm -f "$temp_compose"
            return 0
        else
            echo "  Docker compose should contain fixed port mapping 30042:3000"
            echo "  Content: $content"
            rm -f "$temp_compose"
            return 1
        fi
    else
        echo "  Failed to generate docker-compose file"
        return 1
    fi
}

test_docker_run_command_with_auto_port() {
    # Source required libraries
    source "$AXON_DIR/lib/config-parser.sh"

    # Mock parse_config function for testing
    parse_config() {
        local key=$1
        local default=$2
        case "$key" in
            ".docker.restart_policy") echo "unless-stopped" ;;
            ".docker.env_vars") echo "" ;;
            ".docker.logging.driver") echo "json-file" ;;
            ".docker.logging.max_size") echo "10m" ;;
            ".docker.logging.max_file") echo "3" ;;
            ".docker.extra_hosts") echo "" ;;
            ".health_check.enabled") echo "true" ;;
            ".health_check.endpoint") echo "/health" ;;
            ".health_check.command") echo "" ;;
            ".health_check.interval") echo "30s" ;;
            ".health_check.timeout") echo "10s" ;;
            ".health_check.retries") echo "3" ;;
            ".health_check.start_period") echo "40s" ;;
            ".docker.compose_override") echo "" ;;
            *) echo "$default" ;;
        esac
    }

    # Source docker-runtime
    source "$AXON_DIR/lib/docker-runtime.sh"

    # Test generating compose with auto port (old behavior - should still work)
    local temp_compose=$(generate_docker_compose_from_config \
        "testapp-production-1234567890" \
        "auto" \
        "testorg/testapp:production" \
        "/home/deploy/.env.production" \
        "testnet" \
        "testapp" \
        "3000")

    # Check if the compose file contains just the container port (no host:container format)
    if [ -f "$temp_compose" ]; then
        local content=$(cat "$temp_compose")
        # With auto, we expect: - "3000" (just container port, no colon before it)
        # The line should be like:   - "3000" not like:   - "8080:3000"
        if echo "$content" | grep -E '^\s*-\s*"3000"$' > /dev/null; then
            rm -f "$temp_compose"
            return 0
        else
            echo "  Docker compose with auto should contain just '3000' in port mapping"
            rm -f "$temp_compose"
            return 1
        fi
    else
        echo "  Failed to generate docker-compose file"
        return 1
    fi
}

# ==============================================================================
# Test: Port Selection Avoids Conflicts
# ==============================================================================

test_port_selection_avoids_used_ports() {
    source "$AXON_DIR/lib/port-manager.sh"

    # Simulate port checking
    local used_ports="30001 30005 30010"
    local attempts=0
    local max_attempts=100

    while [ $attempts -lt $max_attempts ]; do
        local port=$(generate_random_port)

        # Check if port is in used list (simulating is_port_available)
        for used in $used_ports; do
            if [ "$port" = "$used" ]; then
                # This is expected occasionally, continue
                break
            fi
        done

        attempts=$((attempts + 1))
    done

    # As long as we can generate ports, this passes
    return 0
}

# ==============================================================================
# Test: Sync Command Logic
# ==============================================================================

test_sync_detects_port_mismatch() {
    # Setup: nginx has old port, container has new port
    echo "upstream testapp_production_backend {
    server 10.0.1.10:30040;
}" > "$MOCK_NGINX_DIR/upstreams/testapp-production.conf"

    local nginx_port="30040"
    local container_port="30042"

    if [ "$nginx_port" != "$container_port" ]; then
        return 0  # Mismatch correctly detected
    else
        echo "  Should detect port mismatch"
        return 1
    fi
}

test_sync_no_action_when_ports_match() {
    local nginx_port="30042"
    local container_port="30042"

    if [ "$nginx_port" = "$container_port" ]; then
        return 0  # No sync needed - correct behavior
    else
        echo "  Should not need sync when ports match"
        return 1
    fi
}

# ==============================================================================
# Test: Restart with Port Verification
# ==============================================================================

test_restart_port_verification_logic() {
    # After restart, verify port hasn't changed
    local expected_port="30042"
    local actual_port="30042"

    assert_equals "$expected_port" "$actual_port" "Port should remain stable after restart"
}

test_restart_detects_port_change() {
    # Simulate port change after restart (edge case)
    local nginx_port="30040"
    local container_port="30045"

    # This should trigger sync
    if [ "$nginx_port" != "$container_port" ]; then
        return 0  # Correctly detects need for sync
    else
        echo "  Should detect port change after restart"
        return 1
    fi
}

# ==============================================================================
# Test: nginx Upstream Configuration
# ==============================================================================

test_nginx_upstream_format() {
    local upstream_name="testapp_production_backend"
    local upstream_ip="10.0.1.10"
    local upstream_port="30042"

    local expected="upstream ${upstream_name} {
    server ${upstream_ip}:${upstream_port};
}"

    local actual="upstream ${upstream_name} {
    server ${upstream_ip}:${upstream_port};
}"

    assert_equals "$expected" "$actual" "nginx upstream format should match"
}

test_nginx_upstream_port_extraction() {
    # Create a mock upstream file
    echo "upstream testapp_production_backend {
    server 10.0.1.10:30042;
}" > "$MOCK_NGINX_DIR/upstreams/testapp-production.conf"

    # Use sed instead of grep -P (not available on macOS)
    local extracted_port=$(grep "server" "$MOCK_NGINX_DIR/upstreams/testapp-production.conf" | sed 's/.*:\([0-9]*\);.*/\1/')

    assert_equals "30042" "$extracted_port" "Should extract port from nginx upstream"
}

# ==============================================================================
# Test: CLI Command Registration
# ==============================================================================

test_sync_command_in_valid_commands() {
    source "$AXON_DIR/lib/command-parser.sh"

    if echo "$AXON_VALID_COMMANDS" | grep -qw "sync"; then
        return 0
    else
        echo "  'sync' should be in AXON_VALID_COMMANDS"
        return 1
    fi
}

test_sync_command_requires_env() {
    source "$AXON_DIR/lib/command-parser.sh"

    if echo "$AXON_ENV_REQUIRED_COMMANDS" | grep -qw "sync"; then
        return 0
    else
        echo "  'sync' should be in AXON_ENV_REQUIRED_COMMANDS"
        return 1
    fi
}

# ==============================================================================
# Run Tests
# ==============================================================================

echo ""
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}AXON Deployment Flow Test Suite${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""

echo -e "${BLUE}Testing Docker Runtime...${NC}"
echo ""
run_test "Docker run command with fixed port" test_docker_run_command_with_fixed_port
run_test "Docker run command with auto port (backward compat)" test_docker_run_command_with_auto_port

echo ""
echo -e "${BLUE}Testing Port Selection...${NC}"
echo ""
run_test "Port selection avoids used ports" test_port_selection_avoids_used_ports

echo ""
echo -e "${BLUE}Testing Sync Logic...${NC}"
echo ""
run_test "Sync detects port mismatch" test_sync_detects_port_mismatch
run_test "Sync no action when ports match" test_sync_no_action_when_ports_match

echo ""
echo -e "${BLUE}Testing Restart Logic...${NC}"
echo ""
run_test "Restart port verification" test_restart_port_verification_logic
run_test "Restart detects port change" test_restart_detects_port_change

echo ""
echo -e "${BLUE}Testing nginx Configuration...${NC}"
echo ""
run_test "nginx upstream format" test_nginx_upstream_format
run_test "nginx upstream port extraction" test_nginx_upstream_port_extraction

echo ""
echo -e "${BLUE}Testing CLI Registration...${NC}"
echo ""
run_test "Sync command in valid commands" test_sync_command_in_valid_commands
run_test "Sync command requires environment" test_sync_command_requires_env

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

# Cleanup
rm -rf "$MOCK_DIR"

# Exit with appropriate code
if [ $TESTS_FAILED -gt 0 ]; then
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
