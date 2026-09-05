#!/usr/bin/env bash
# tests/pi-intake-tick-fleetops-title-refusal.test.sh
#
# fleet-ops#3313: the deterministic intake tick (lib/pi-intake-tick.sh)
# MUST refuse agent-ready issues whose title starts with '[fleet-ops#'
# on product repos (any repo outside config/self-maintenance-repos.json).
# '[fleet-ops#N]'-titled issues are control-plane work; the worker App has
# no Workflows scope, so a product-repo claim on one can never land — the
# 2026-09-04 seat burn: 10 of 11 'ready' 0509 issues were fleet-ops CI
# wiring, 4 capable seats consumed, no product. The tick drops them the
# same way it drops escalate-senior and umbrella issues (pure jq pass on
# the already-fetched list). In fleet-ops they are native and stay.
#
# Static-grep + jq drill (same shape as the umbrella-exclusion test):
# pins the refusal in the tick without a live systemd/gh environment.
#
# Proves:
#   1. The refusal is scoped by product_first_is_self_maintenance "$REPO"
#      (product repos only; fleet-ops keeps its native '[fleet-ops#' work).
#   2. The tick runs a jq title filter (startswith "[fleet-ops#").
#   3. The jq filter drops '[fleet-ops#'-titled issues and keeps the rest.
#   4. The jq filter tolerates missing/null titles.
#   5. The tick counts refused issues and logs the refusal.
#   6. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: refusal scoped to product repos via self-maintenance check ===
grep -qF 'if ! product_first_is_self_maintenance "$REPO"; then' "$tick" \
    || fail 'product-repo scoping (product_first_is_self_maintenance "$REPO") not found in tick'
ok "Test 1: refusal scoped by product_first_is_self_maintenance"

# === Test 2: jq title filter present ===
grep -qF 'startswith("[fleet-ops#") | not' "$tick" \
    || fail 'jq fleet-ops title refusal filter (startswith("[fleet-ops#") | not) not found in tick'
ok "Test 2: jq title refusal filter present"

# === Test 3 + 4: jq drill on the real gh title shape ===
# Reproduce the exact filter the tick runs and prove it drops only
# '[fleet-ops#'-titled issues, keeps regular ones, tolerates missing titles.
filter='[.[] | select((.title // "") | startswith("[fleet-ops#") | not)]'

fixture='[
  {"number":1151,"title":"[fleet-ops#216] CI: add tests/ram-measure.test.sh to P14 verify-command list","labels":[{"name":"agent-ready"}]},
  {"number":1226,"title":"[fleet-ops#92] CI: verify systemd/*.slice in the systemd-analyze job","labels":[{"name":"agent-ready"}]},
  {"number":1576,"title":"Run the post-deploy assertion against a preview deploy as a required PR check","labels":[{"name":"agent-ready"}]},
  {"number":1600,"title":"verify-drift: npm test fails on vitest v4","labels":[{"name":"agent-ready"}]},
  {"number":1601,"title":null,"labels":[{"name":"agent-ready"}]},
  {"number":1602,"labels":[{"name":"agent-ready"}]}
]'
out=$(printf '%s' "$fixture" | jq -c "$filter")
count=$(printf '%s' "$out" | jq 'length')
[[ "$count" == "4" ]] || fail "drill: expected 4 issues after filter, got $count: $out"
kept=$(printf '%s' "$out" | jq -r '[.[].number] | sort | join(",")')
[[ "$kept" == "1576,1600,1601,1602" ]] || fail "drill: expected to keep 1576,1600,1601,1602; got $kept"
ok "Test 3-4: jq filter drops '[fleet-ops#' titles, keeps regular, tolerates missing/null title"

# === Test 5: tick counts refused issues and logs the refusal ===
grep -qF '_fleetops_titled_seen=' "$tick" \
    || fail "_fleetops_titled_seen count (pre-filter) not found in tick"
grep -qF 'startswith("[fleet-ops#"))] | length' "$tick" \
    || fail 'refusal count filter (startswith("[fleet-ops#"))] | length) not found in tick'
grep -qF 'fleetops-title-refusal:' "$tick" \
    || fail "fleetops-title-refusal log line not found in tick"
ok "Test 5: tick counts refused issues and logs the refusal"

# === Test 6: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning
    ok "Test 6: shellcheck clean"
else
    echo "SKIP: Test 6: shellcheck not installed"
fi

echo ""
echo "ALL OK: intake-tick fleet-ops title refusal (fleet-ops#3313)"
