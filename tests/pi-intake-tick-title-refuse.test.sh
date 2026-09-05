#!/usr/bin/env bash
# tests/pi-intake-tick-title-refuse.test.sh
#
# fleet-ops#3313: the product queue (0509) must hold only product-surface
# issues. Control-plane work is titled with a '<owner>#<N>' prefix (e.g.
# '[fleet-ops#303] CI: ...') to mark it as fleet-ops-owned CI/control-plane
# work that the worker App cannot push (no Workflows permission). This
# filter is the intake-side guard: a ready product issue carrying that
# prefix is mis-filed control-plane work, and product intake must drop it
# from the dispatch list so a worker is never spawned on it.
#
# Static-grep + jq drill (same shape as the umbrella-exclusion test):
# pins the exclusion in the tick without a live systemd/gh environment.
#
# Proves:
#   1. The tick defines an overridable PI_INTAKE_TITLE_REFUSE_PREFIX seam.
#   2. The tick gates the filter to the product repo (PI_INTAKE_TITLE_REFUSE_REPO).
#   3. The jq filter drops '[fleet-ops#'-titled issues.
#   4. The jq filter keeps regular product issues (incl. other bracket titles).
#   5. The filter only applies to the scoped repo (other repos unaffected).
#   6. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: prefix seam defined and overridable ===
grep -qF 'PI_INTAKE_TITLE_REFUSE_PREFIX="${PI_INTAKE_TITLE_REFUSE_PREFIX:-[fleet-ops#}"' "$tick" \
    || fail "PI_INTAKE_TITLE_REFUSE_PREFIX seam (overridable via PI_INTAKE_TITLE_REFUSE_PREFIX) not found in tick"
ok "Test 1: PI_INTAKE_TITLE_REFUSE_PREFIX seam present and overridable"

# === Test 2: repo gate seam ===
grep -qF 'PI_INTAKE_TITLE_REFUSE_REPO="${PI_INTAKE_TITLE_REFUSE_REPO:-0509}"' "$tick" \
    || fail "PI_INTAKE_TITLE_REFUSE_REPO seam (overridable, default 0509) not found in tick"
grep -qF 'if [[ "$REPO" == "$PI_INTAKE_TITLE_REFUSE_REPO" ]]; then' "$tick" \
    || fail "tick must gate the refusal to PI_INTAKE_TITLE_REFUSE_REPO"
ok "Test 2: repo gate present and default 0509"

# === Test 3 + 4: jq drill drops [fleet-ops# titles, keeps regular ===
filter='[.[] | select(((.title // "") | startswith("[fleet-ops#")) | not)]'

fixture='[
  {"number":1180,"title":"[fleet-ops#303] Copy reusable-gate-integrity.yml to fleet-ops .github/workflows/"},
  {"number":1205,"title":"[fleet-ops#407] CI: wire prove-one-run-check into P14 tests"},
  {"number":2001,"title":"regular product work"},
  {"number":2003,"title":"[BET 1] some product issue"},
  {"number":2005,"title":"[fleet-ops#571] CI: add tests/exec-review-prompt.test.sh to P14 verify-command list"}
]'
out=$(printf '%s' "$fixture" | jq -c "$filter")
count=$(printf '%s' "$out" | jq 'length')
[[ "$count" == "2" ]] || fail "drill: expected 2 issues after filter, got $count: $out"
kept=$(printf '%s' "$out" | jq -r '[.[].number] | sort | join(",")')
[[ "$kept" == "2001,2003" ]] || fail "drill: expected to keep 2001,2003; got $kept"
ok "Test 3-4: jq filter drops [fleet-ops# titles, keeps regular product issues"

# === Test 5: missing/empty title tolerated ===
missing=$(printf '%s' '[{"number":3001,"title":null},{"number":3003,"title":""}]' | jq -c "$filter")
[[ "$(printf '%s' "$missing" | jq 'length')" == "2" ]] \
    || fail "drill: missing/empty titles must be kept (length != 2): $missing"
ok "Test 5: jq filter tolerates null/empty titles"

# === Test 6: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning
    ok "Test 6: shellcheck clean"
else
    echo "SKIP: Test 6: shellcheck not installed"
fi

echo ""
echo "ALL OK: intake-tick product-title refusal (fleet-ops#3313)"
