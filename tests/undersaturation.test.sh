#!/usr/bin/env bash
# fleet-ops UNDERSATURATED rule test (fleet-ops UNDERSATURATED, 2026-08-27).
#
# Runs `promtool test rules` against the rule in ../rules/undersaturation.yml
# using the test cases in undersaturation.test.yml. The test cases cover the
# five behaviors the rule must exhibit:
#
#   1. Fires when workers<2 and ready>0 sustained 30m (the page).
#   2. Does NOT fire when workers>=2 (fleet is healthy).
#   3. Does NOT fire when ready=0 (no work concept → no wedge).
#   4. Does NOT fire during a sub-30m maintenance window (the `for` absorbs it).
#   5. DOES fire when the maintenance window exceeds 30m (the failure case).
#
# The test runs from the worktree root. Failures print the promtool output and
# exit non-zero.
set -euo pipefail

cd "$(dirname "$0")/.."
RULES=rules/undersaturation.yml
TEST=tests/undersaturation.test.yml

if ! command -v promtool >/dev/null 2>&1; then
    echo "FATAL: promtool not in PATH" >&2
    exit 2
fi

# Step 1: promtool check rules — structural validity.
echo "==> promtool check rules $RULES"
promtool check rules "$RULES"

# Step 2: promtool test rules — the 5 behavioral cases.
echo "==> promtool test rules $TEST"
promtool test rules "$TEST"

echo "OK: undersaturation rule + 5 test cases pass"
