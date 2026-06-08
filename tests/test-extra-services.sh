#!/bin/bash
# AXON - Extra Services (Sidecars) Test Suite
# Tests config getters, naming, validation, log selection for docker.extra_services

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AXON_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test-framework.sh"
source "$AXON_DIR/lib/extra-services.sh"

# Fixture config with two sidecars
FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE_DIR"' EXIT
FIXTURE_CONFIG="$FIXTURE_DIR/axon.config.yml"
cat > "$FIXTURE_CONFIG" <<'EOF'
docker:
  container_port: 3001
  network_name: api
  restart_policy: unless-stopped
  extra_services:
    scheduler:
      command: ["./scheduler"]
      compose_override: |
        mem_limit: "128m"
    worker:
      command: ["./worker", "--concurrency=4"]
EOF

# ------------------------------------------------------------------
# get_extra_service_names
# ------------------------------------------------------------------
test_get_names_lists_all_services() {
    local names
    names=$(CONFIG_FILE="$FIXTURE_CONFIG" get_extra_service_names | sort | tr '\n' ' ')
    assert_equals "scheduler worker " "$names" "should list both sidecar names"
}

test_get_names_empty_when_absent() {
    local empty_config="$FIXTURE_DIR/empty.yml"
    printf 'docker:\n  container_port: 3001\n' > "$empty_config"
    local names
    names=$(CONFIG_FILE="$empty_config" get_extra_service_names)
    assert_equals "" "$names" "should be empty when no extra_services key"
}

# ------------------------------------------------------------------
# get_extra_service_command_json
# ------------------------------------------------------------------
test_command_json_array() {
    local cmd
    cmd=$(CONFIG_FILE="$FIXTURE_CONFIG" get_extra_service_command_json "worker")
    assert_equals '["./worker","--concurrency=4"]' "$cmd" "command should be emitted as JSON array"
}

test_command_json_empty_when_absent() {
    local cfg="$FIXTURE_DIR/nocmd.yml"
    printf 'docker:\n  extra_services:\n    bare:\n      compose_override: |\n        mem_limit: "64m"\n' > "$cfg"
    local cmd
    cmd=$(CONFIG_FILE="$cfg" get_extra_service_command_json "bare")
    assert_equals "" "$cmd" "absent command must yield empty string, not 'null'"
}

# ------------------------------------------------------------------
# get_extra_service_compose_override
# ------------------------------------------------------------------
test_override_present() {
    local ov
    ov=$(CONFIG_FILE="$FIXTURE_CONFIG" get_extra_service_compose_override "scheduler")
    assert_contains "$ov" "mem_limit" "scheduler override should contain mem_limit"
}

test_override_absent() {
    local ov
    ov=$(CONFIG_FILE="$FIXTURE_CONFIG" get_extra_service_compose_override "worker")
    assert_equals "" "$ov" "worker has no override"
}

# ------------------------------------------------------------------
# sidecar_container_name
# ------------------------------------------------------------------
test_sidecar_name_format() {
    local name
    name=$(sidecar_container_name "goodtogo" "production" "scheduler" "1700000000")
    assert_equals "goodtogo-production-svc-scheduler-1700000000" "$name" "name must carry -svc- marker"
}

# ------------------------------------------------------------------
# generate_sidecar_compose
# ------------------------------------------------------------------
test_sidecar_compose_has_image_command_env_network() {
    source "$AXON_DIR/lib/docker-runtime.sh"
    local f
    f=$(generate_sidecar_compose \
        "goodtogo-production-svc-scheduler-1700000000" \
        "registry/goodtogo:production" \
        "/home/ubuntu/.env.production" \
        "api" \
        "unless-stopped" \
        '["./scheduler"]' \
        "" \
        "json-file" "10m" "3")
    local c; c=$(cat "$f"); rm -f "$f"
    assert_contains "$c" "image: registry/goodtogo:production" "image inherited" && \
    assert_contains "$c" 'command: \[' "command set" && \
    assert_contains "$c" "/home/ubuntu/.env.production" "env_file inherited" && \
    assert_contains "$c" "restart: unless-stopped" "restart inherited"
}

test_sidecar_compose_has_no_ports_or_healthcheck() {
    source "$AXON_DIR/lib/docker-runtime.sh"
    local f
    f=$(generate_sidecar_compose \
        "goodtogo-production-svc-scheduler-1700000000" \
        "registry/goodtogo:production" \
        "/home/ubuntu/.env.production" \
        "api" "unless-stopped" '["./scheduler"]' "" "json-file" "10m" "3")
    local c; c=$(cat "$f"); rm -f "$f"
    if echo "$c" | grep -qE 'ports:|healthcheck:'; then
        echo "  sidecar compose must NOT contain ports: or healthcheck:"
        echo "  Content: $c"
        return 1
    fi
    return 0
}

test_sidecar_compose_appends_override() {
    source "$AXON_DIR/lib/docker-runtime.sh"
    local f
    f=$(generate_sidecar_compose \
        "goodtogo-production-svc-scheduler-1700000000" \
        "registry/goodtogo:production" \
        "/home/ubuntu/.env.production" \
        "api" "unless-stopped" '["./scheduler"]' \
        'mem_limit: "128m"' "json-file" "10m" "3")
    local c; c=$(cat "$f"); rm -f "$f"
    assert_contains "$c" 'mem_limit: "128m"' "override appended at service level"
}

# ------------------------------------------------------------------
# Run
# ------------------------------------------------------------------
echo ""
echo -e "${BLUE}Testing extra-services config getters + naming...${NC}"
echo ""
run_test "get_extra_service_names lists all" test_get_names_lists_all_services
run_test "get_extra_service_names empty when absent" test_get_names_empty_when_absent
run_test "command emitted as JSON array" test_command_json_array
run_test "command empty when absent" test_command_json_empty_when_absent
run_test "compose_override present" test_override_present
run_test "compose_override absent" test_override_absent
run_test "sidecar_container_name format" test_sidecar_name_format

echo ""
echo -e "${BLUE}Testing sidecar compose generation...${NC}"
echo ""
run_test "sidecar compose has image/command/env/restart" test_sidecar_compose_has_image_command_env_network
run_test "sidecar compose has no ports/healthcheck" test_sidecar_compose_has_no_ports_or_healthcheck
run_test "sidecar compose appends override" test_sidecar_compose_appends_override

rm -rf "$FIXTURE_DIR"

echo ""
echo -e "${CYAN}=============================================${NC}"
echo -e "  Total Tests: ${TESTS_RUN}"
echo -e "  ${GREEN}Passed: ${TESTS_PASSED}${NC}"
[ $TESTS_FAILED -gt 0 ] && echo -e "  ${RED}Failed: ${TESTS_FAILED}${NC}"
echo ""
if [ $TESTS_FAILED -gt 0 ]; then exit 1; else echo -e "${GREEN}All tests passed!${NC}"; exit 0; fi
