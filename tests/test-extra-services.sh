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
    local rc=0
    assert_contains "$c" "image: registry/goodtogo:production" "image inherited" || rc=1
    assert_contains "$c" 'command: \["./scheduler"\]' "command set" || rc=1
    assert_contains "$c" "/home/ubuntu/.env.production" "env_file inherited" || rc=1
    assert_contains "$c" "restart: unless-stopped" "restart inherited" || rc=1
    return $rc
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

test_sidecar_compose_omits_empty_command() {
    source "$AXON_DIR/lib/docker-runtime.sh"
    local f
    f=$(generate_sidecar_compose \
        "goodtogo-production-svc-bare-1700000000" \
        "registry/goodtogo:production" \
        "/home/ubuntu/.env.production" \
        "api" "unless-stopped" "" "" "json-file" "10m" "3")
    local c; c=$(cat "$f"); rm -f "$f"
    if echo "$c" | grep -qE '^[[:space:]]*command:'; then
        echo "  empty command_json must NOT emit a command: line (would null the image CMD)"
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
# build_sidecar_run_command (decomposerize mocked)
# ------------------------------------------------------------------
test_sidecar_run_command_is_detached() {
    setup_mocks
    mock_command "decomposerize" 0 "docker run --name goodtogo-production-svc-scheduler-1700000000 --restart unless-stopped --network api registry/goodtogo:production ./scheduler"
    source "$AXON_DIR/lib/docker-runtime.sh"

    local cmd
    cmd=$(build_sidecar_run_command \
        "goodtogo-production-svc-scheduler-1700000000" \
        "registry/goodtogo:production" \
        "/home/ubuntu/.env.production" \
        "api" "unless-stopped" '["./scheduler"]' "" "json-file" "10m" "3")

    teardown_mocks
    local rc=0
    assert_contains "$cmd" "docker run -d " "sidecar run command must be detached" || rc=1
    assert_contains "$cmd" "goodtogo-production-svc-scheduler-1700000000" "carries sidecar name" || rc=1
    return $rc
}

test_sidecar_run_command_fails_without_decomposerize() {
    local isolated; isolated=$(mktemp -d)
    local rc=0
    PATH="$isolated:/usr/bin:/bin" bash -c '
        source "'"$AXON_DIR"'/lib/docker-runtime.sh"
        build_sidecar_run_command "n" "i" "e" "net" "unless-stopped" "[\"./x\"]" "" "json-file" "10m" "3" >/dev/null 2>&1
    ' || rc=$?
    rm -rf "$isolated"
    assert_equals "1" "$rc" "must return 1 when decomposerize missing"
}

# ------------------------------------------------------------------
# validate_extra_services (report_error/report_success stubbed)
# ------------------------------------------------------------------
_reset_reporters() { ERRORS=0; WARNINGS=0; LAST_ERROR=""; }
report_error()   { ERRORS=$((ERRORS+1)); LAST_ERROR="$1"; }
report_warning() { WARNINGS=$((WARNINGS+1)); }
report_success() { :; }

test_validate_ok_for_command_only() {
    _reset_reporters
    local cfg="$FIXTURE_DIR/ok.yml"
    cat > "$cfg" <<'EOF'
docker:
  extra_services:
    scheduler:
      command: ["./scheduler"]
EOF
    CONFIG_FILE="$cfg" validate_extra_services
    assert_equals "0" "$ERRORS" "valid sidecar produces no errors"
}

test_validate_rejects_missing_command() {
    _reset_reporters
    local cfg="$FIXTURE_DIR/nocmd.yml"
    cat > "$cfg" <<'EOF'
docker:
  extra_services:
    scheduler:
      compose_override: |
        mem_limit: "128m"
EOF
    CONFIG_FILE="$cfg" validate_extra_services
    local rc=0
    assert_equals "1" "$ERRORS" "missing command must error" || rc=1
    assert_contains "$LAST_ERROR" "command" "error message mentions command" || rc=1
    return $rc
}

test_validate_rejects_forbidden_keys() {
    _reset_reporters
    local cfg="$FIXTURE_DIR/bad.yml"
    cat > "$cfg" <<'EOF'
docker:
  extra_services:
    admin:
      command: ["./admin"]
      ports:
        - "8080:8080"
      image: "other:tag"
EOF
    CONFIG_FILE="$cfg" validate_extra_services
    assert_equals "2" "$ERRORS" "ports and image are both rejected"
}

# ------------------------------------------------------------------
# reap_filter: given a container list on stdin and the new container
# name, drop the new container AND any sidecar (-svc-).
# ------------------------------------------------------------------
test_reap_filter_drops_new_and_sidecars() {
    local list="goodtogo-production-1700000000
goodtogo-production-1699999999
goodtogo-production-svc-scheduler-1700000000
goodtogo-production-svc-worker-1700000000"
    local out
    out=$(printf '%s\n' "$list" | reap_filter "goodtogo-production-1700000000" | tr '\n' ' ')
    assert_equals "goodtogo-production-1699999999 " "$out" "only the old MAIN container survives the filter"
}

test_reap_filter_empty_input() {
    local out
    out=$(printf '' | reap_filter "anything")
    assert_equals "" "$out" "empty input produces empty output without error"
}

# ------------------------------------------------------------------
# pick_latest_container: choose target from a container list (stdin)
# Args: env_filter (product-env), service ("" = main)
# ------------------------------------------------------------------
test_pick_latest_main_excludes_sidecars() {
    local list="goodtogo-production-1699999999
goodtogo-production-1700000000
goodtogo-production-svc-scheduler-1700000000"
    local out
    out=$(printf '%s\n' "$list" | pick_latest_container "goodtogo-production" "")
    assert_equals "goodtogo-production-1700000000" "$out" "default picks latest MAIN, not sidecar"
}

test_pick_latest_named_sidecar() {
    local list="goodtogo-production-1700000000
goodtogo-production-svc-scheduler-1699999999
goodtogo-production-svc-scheduler-1700000000
goodtogo-production-svc-worker-1700000000"
    local out
    out=$(printf '%s\n' "$list" | pick_latest_container "goodtogo-production" "scheduler")
    assert_equals "goodtogo-production-svc-scheduler-1700000000" "$out" "service arg picks latest matching sidecar"
}

test_pick_latest_empty_list() {
    local out
    out=$(printf '' | pick_latest_container "goodtogo-production" "")
    assert_equals "" "$out" "empty list yields empty selection without error"
}

test_pick_latest_unknown_service() {
    local list="goodtogo-production-1700000000
goodtogo-production-svc-scheduler-1700000000"
    local out
    out=$(printf '%s\n' "$list" | pick_latest_container "goodtogo-production" "nonexistent")
    assert_equals "" "$out" "unknown service yields empty selection (drives the not-found path)"
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
run_test "sidecar compose omits empty command" test_sidecar_compose_omits_empty_command
run_test "sidecar compose appends override" test_sidecar_compose_appends_override

echo ""
echo -e "${BLUE}Testing sidecar docker run builder...${NC}"
echo ""
run_test "sidecar run command is detached" test_sidecar_run_command_is_detached
run_test "sidecar run fails without decomposerize" test_sidecar_run_command_fails_without_decomposerize

echo ""
echo -e "${BLUE}Testing reap filter...${NC}"
echo ""
run_test "reap_filter drops new + sidecars" test_reap_filter_drops_new_and_sidecars
run_test "reap_filter empty input" test_reap_filter_empty_input

echo ""
echo -e "${BLUE}Testing extra_services validation...${NC}"
echo ""
run_test "validate ok for command-only" test_validate_ok_for_command_only
run_test "validate rejects missing command" test_validate_rejects_missing_command
run_test "validate rejects forbidden keys" test_validate_rejects_forbidden_keys

echo ""
echo -e "${BLUE}Testing log target selection...${NC}"
echo ""
run_test "pick latest main excludes sidecars" test_pick_latest_main_excludes_sidecars
run_test "pick latest named sidecar" test_pick_latest_named_sidecar
run_test "pick latest empty list" test_pick_latest_empty_list
run_test "pick latest unknown service" test_pick_latest_unknown_service

rm -rf "$FIXTURE_DIR"

echo ""
echo -e "${CYAN}=============================================${NC}"
echo -e "  Total Tests: ${TESTS_RUN}"
echo -e "  ${GREEN}Passed: ${TESTS_PASSED}${NC}"
[ $TESTS_FAILED -gt 0 ] && echo -e "  ${RED}Failed: ${TESTS_FAILED}${NC}"
echo ""
if [ $TESTS_FAILED -gt 0 ]; then exit 1; else echo -e "${GREEN}All tests passed!${NC}"; exit 0; fi
