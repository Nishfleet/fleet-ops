#!/usr/bin/env bash
# tests/pi-intake-tick-umbrella-exclusion.test.sh
#
# fleet-ops#3295: the deterministic intake tick (lib/pi-intake-tick.sh)
# MUST exclude umbrella-labeled issues from the dispatch list, the same
# way it drops escalate-senior issues (tests/pi-intake-tick-escalate-
# senior-exclusion.test.sh). Umbrella = "tracking parent; not claimable"
# (label desc). The lifecycle-label-sweep guard stops NEW umbrella issues
# from getting agent-ready, but an umbrella issue may already carry
# agent-ready (e.g. #3128 was labeled agent-ready before the guard landed,
# or a manual label edit re-added it). This filter is the intake-side
# guard so the tick never dispatches a worker on a tracker with no
# implementable work — the dead-seat loop where the worker claims, finds
# nothing to do, and dies or releases (live #3128: 6 claims in one day).
#
# Static-grep + jq drill (same shape as the escalate-senior exclusion
# test): pins the exclusion in the tick without a live systemd/gh
# environment.
#
# Proves:
#   1. The tick defines an overridable UMBRELLA_LABEL seam.
#   2. The tick runs a jq filter that drops umbrella issues.
#   3. The jq filter keeps regular agent-ready issues.
#   4. The jq filter handles the real gh labels shape (objects with .name).
#   5. The jq filter handles a missing/empty labels array.
#   6. The tick counts umbrella issues before filtering (the metric seam).
#   7. The tick exports fleet_umbrella_dispatch_total (the prom metric).
#   8. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: UMBRELLA_LABEL seam defined and overridable ===
grep -qF 'UMBRELLA_LABEL="${PI_INTAKE_UMBRELLA_LABEL:-umbrella}"' "$tick" \
    || fail "UMBRELLA_LABEL seam (overridable via PI_INTAKE_UMBRELLA_LABEL) not found in tick"
ok "Test 1: UMBRELLA_LABEL seam present and overridable"

# === Test 2: jq filter drops umbrella issues ===
grep -qF 'index($umb) == null' "$tick" \
    || fail "jq umbrella exclusion filter (index(\$umb) == null) not found in tick"
ok "Test 2: jq umbrella exclusion filter present"

# === Test 3 + 4 + 5: jq drill on the real gh labels shape ===
# Reproduce the exact filter the tick runs and prove it drops only
# umbrella issues, keeps regular ones, and tolerates missing labels.
filter='[.[] | select((.labels // []) | map(if type == "object" then (.name // empty) else . end) | index("umbrella") == null)]'

fixture='[
  {"number":3128,"title":"umbrella: seat health observability gaps","labels":[{"name":"agent-ready","id":1,"color":"0E8A16"},{"name":"umbrella","id":2,"color":"BFD4F2"}]},
  {"number":2001,"title":"regular work","labels":[{"name":"agent-ready","id":1,"color":"0E8A16"}]},
  {"number":2003,"title":"no labels","labels":[]},
  {"number":2005,"title":"string labels","labels":["agent-ready","umbrella"]}
]'
out=$(printf '%s' "$fixture" | jq -c "$filter")
count=$(printf '%s' "$out" | jq 'length')
[[ "$count" == "2" ]] || fail "drill: expected 2 issues after filter, got $count: $out"
kept=$(printf '%s' "$out" | jq -r '[.[].number] | sort | join(",")')
[[ "$kept" == "2001,2003" ]] || fail "drill: expected to keep 2001,2003; got $kept"
ok "Test 3-5: jq filter drops umbrella (object + string labels), keeps regular, tolerates missing labels"

# === Test 6: tick counts umbrella issues before filtering (metric seam) ===
grep -qF 'umbrella_dispatch_seen=' "$tick" \
    || fail "umbrella_dispatch_seen count (pre-filter) not found in tick"
grep -qF 'index($umb) != null' "$tick" \
    || fail "umbrella count filter (index(\$umb) != null) not found in tick"
ok "Test 6: tick counts umbrella issues before filtering (metric seam)"

# === Test 7: tick exports fleet_umbrella_dispatch_total prom metric ===
grep -qF 'fleet_umbrella_dispatch_total' "$tick" \
    || fail "fleet_umbrella_dispatch_total prom metric not found in tick"
grep -qF 'PI_INTAKE_UMBRELLA_PROM' "$tick" \
    || fail "PI_INTAKE_UMBRELLA_PROM override seam not found in tick"
ok "Test 7: tick exports fleet_umbrella_dispatch_total with override seam"

# === Test 8: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning
    ok "Test 8: shellcheck clean"
else
    echo "SKIP: Test 8: shellcheck not installed"
fi

echo ""
echo "ALL OK: intake-tick umbrella exclusion (fleet-ops#3295)"
