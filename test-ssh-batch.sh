#!/bin/bash
# Test script to demonstrate SSH batch performance
# Compares individual SSH calls vs batched execution

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-batch.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration (adjust these)
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
TEST_SERVER="${TEST_SERVER:-localhost}"

if [ ! -f "$SSH_KEY" ]; then
    echo -e "${RED}Error: SSH key not found: $SSH_KEY${NC}"
    echo "Set SSH_KEY environment variable or update script"
    exit 1
fi

echo -e "${CYAN}SSH Batch Execution Test${NC}"
echo -e "${CYAN}========================${NC}"
echo ""
echo "Target: $TEST_SERVER"
echo "SSH Key: $SSH_KEY"
echo ""

# Test 1: Individual SSH calls
echo -e "${YELLOW}Test 1: Individual SSH calls (5 commands)${NC}"
START_TIME=$(date +%s.%N)

RESULT1=$(ssh -i "$SSH_KEY" "$TEST_SERVER" "echo 'Command 1'; sleep 0.1")
RESULT2=$(ssh -i "$SSH_KEY" "$TEST_SERVER" "echo 'Command 2'; sleep 0.1")
RESULT3=$(ssh -i "$SSH_KEY" "$TEST_SERVER" "echo 'Command 3'; sleep 0.1")
RESULT4=$(ssh -i "$SSH_KEY" "$TEST_SERVER" "echo 'Command 4'; sleep 0.1")
RESULT5=$(ssh -i "$SSH_KEY" "$TEST_SERVER" "echo 'Command 5'; sleep 0.1")

END_TIME=$(date +%s.%N)
INDIVIDUAL_TIME=$(echo "$END_TIME - $START_TIME" | bc)

echo -e "  Results: ${GREEN}$RESULT1, $RESULT2, $RESULT3, $RESULT4, $RESULT5${NC}"
echo -e "  Time: ${GREEN}${INDIVIDUAL_TIME}s${NC}"
echo ""

# Test 2: Batched SSH calls
echo -e "${YELLOW}Test 2: Batched SSH calls (5 commands in 1 connection)${NC}"
START_TIME=$(date +%s.%N)

ssh_batch_start
ssh_batch_add "echo 'Command 1'; sleep 0.1" "cmd1"
ssh_batch_add "echo 'Command 2'; sleep 0.1" "cmd2"
ssh_batch_add "echo 'Command 3'; sleep 0.1" "cmd3"
ssh_batch_add "echo 'Command 4'; sleep 0.1" "cmd4"
ssh_batch_add "echo 'Command 5'; sleep 0.1" "cmd5"

ssh_batch_execute "$SSH_KEY" "$TEST_SERVER"

BATCH_RESULT1=$(ssh_batch_result "cmd1")
BATCH_RESULT2=$(ssh_batch_result "cmd2")
BATCH_RESULT3=$(ssh_batch_result "cmd3")
BATCH_RESULT4=$(ssh_batch_result "cmd4")
BATCH_RESULT5=$(ssh_batch_result "cmd5")

END_TIME=$(date +%s.%N)
BATCHED_TIME=$(echo "$END_TIME - $START_TIME" | bc)

echo -e "  Results: ${GREEN}$BATCH_RESULT1, $BATCH_RESULT2, $BATCH_RESULT3, $BATCH_RESULT4, $BATCH_RESULT5${NC}"
echo -e "  Time: ${GREEN}${BATCHED_TIME}s${NC}"
echo ""

# Calculate speedup
SPEEDUP=$(echo "scale=2; $INDIVIDUAL_TIME / $BATCHED_TIME" | bc)

echo -e "${CYAN}Performance Comparison${NC}"
echo -e "${CYAN}======================${NC}"
echo -e "Individual calls: ${YELLOW}${INDIVIDUAL_TIME}s${NC}"
echo -e "Batched calls:    ${GREEN}${BATCHED_TIME}s${NC}"
echo -e "Speedup:          ${GREEN}${SPEEDUP}x faster${NC}"
echo ""

# Test 3: Error handling
echo -e "${YELLOW}Test 3: Error handling${NC}"
ssh_batch_start
ssh_batch_add "echo 'Success'" "success_cmd"
ssh_batch_add "false" "fail_cmd"
ssh_batch_add "echo 'After failure'" "after_fail"

ssh_batch_execute "$SSH_KEY" "$TEST_SERVER" || true

SUCCESS_RESULT=$(ssh_batch_result "success_cmd")
FAIL_EXIT=$(ssh_batch_exitcode "fail_cmd")
AFTER_RESULT=$(ssh_batch_result "after_fail")

echo -e "  Success command: ${GREEN}$SUCCESS_RESULT${NC} (exit: $(ssh_batch_exitcode "success_cmd"))"
echo -e "  Failed command: ${RED}(empty)${NC} (exit: $FAIL_EXIT)"
echo -e "  After failure: ${GREEN}$AFTER_RESULT${NC} (exit: $(ssh_batch_exitcode "after_fail"))"
echo ""

if [ "$FAIL_EXIT" -ne 0 ] && [ -n "$AFTER_RESULT" ]; then
    echo -e "${GREEN}✓ Error handling works correctly${NC}"
else
    echo -e "${RED}✗ Error handling failed${NC}"
fi

echo ""
echo -e "${GREEN}All tests completed!${NC}"
