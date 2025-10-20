#!/bin/bash
# Test Bash 3.2 compatibility for async execution helpers
# Tests helper functions without requiring SSH

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-batch.sh"

echo "Testing Bash 3.2 Compatibility"
echo "==============================="
echo "Bash version: $(bash --version | head -1)"
echo ""

# Test 1: Helper functions exist
echo "Test 1: Checking helper functions..."
if declare -f _async_get >/dev/null 2>&1 && \
   declare -f _async_set >/dev/null 2>&1 && \
   declare -f _async_unset >/dev/null 2>&1; then
    echo "  ✓ All helper functions exist"
else
    echo "  ✗ Helper functions missing"
    exit 1
fi

# Test 2: _async_set and _async_get
echo ""
echo "Test 2: Testing _async_set and _async_get..."
_async_set "_SSH_BATCH_ASYNC_PIDS" "test1" "12345"
result=$(_async_get "_SSH_BATCH_ASYNC_PIDS" "test1")
if [ "$result" = "12345" ]; then
    echo "  ✓ _async_set/_async_get works"
else
    echo "  ✗ Expected '12345', got '$result'"
    exit 1
fi

# Test 3: Multiple entries
echo ""
echo "Test 3: Testing multiple entries..."
_async_set "_SSH_BATCH_ASYNC_PIDS" "test2" "67890"
_async_set "_SSH_BATCH_ASYNC_OUTPUTS" "test1" "/tmp/file1"
_async_set "_SSH_BATCH_ASYNC_OUTPUTS" "test2" "/tmp/file2"

result1=$(_async_get "_SSH_BATCH_ASYNC_PIDS" "test1")
result2=$(_async_get "_SSH_BATCH_ASYNC_PIDS" "test2")
result3=$(_async_get "_SSH_BATCH_ASYNC_OUTPUTS" "test1")
result4=$(_async_get "_SSH_BATCH_ASYNC_OUTPUTS" "test2")

if [ "$result1" = "12345" ] && [ "$result2" = "67890" ] && \
   [ "$result3" = "/tmp/file1" ] && [ "$result4" = "/tmp/file2" ]; then
    echo "  ✓ Multiple entries work correctly"
else
    echo "  ✗ Multiple entries failed"
    echo "    Expected: 12345, 67890, /tmp/file1, /tmp/file2"
    echo "    Got: $result1, $result2, $result3, $result4"
    exit 1
fi

# Test 4: _async_unset
echo ""
echo "Test 4: Testing _async_unset..."
_async_unset "_SSH_BATCH_ASYNC_PIDS" "test1"
result=$(_async_get "_SSH_BATCH_ASYNC_PIDS" "test1" || echo "NOT_FOUND")
if [ "$result" = "NOT_FOUND" ]; then
    echo "  ✓ _async_unset works correctly"
else
    echo "  ✗ Expected 'NOT_FOUND', got '$result'"
    exit 1
fi

# Test 5: Values with special characters
echo ""
echo "Test 5: Testing values with special characters..."
_async_set "_SSH_BATCH_ASYNC_COMMANDS" "test3" "echo 'hello world'"
result=$(_async_get "_SSH_BATCH_ASYNC_COMMANDS" "test3")
if [ "$result" = "echo 'hello world'" ]; then
    echo "  ✓ Special characters handled correctly"
else
    echo "  ✗ Expected \"echo 'hello world'\", got \"$result\""
    exit 1
fi

echo ""
echo "================================"
echo "✓ All Bash 3.2 compatibility tests passed!"
echo "================================"
echo ""
echo "The parallel execution implementation is compatible with Bash 3.2"
