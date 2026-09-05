#!/usr/bin/env bash
# tests/pi-intake-tick-self-maint-cap.test.sh
#
# fleet-ops#3254 (part 1/4): the deterministic intake tick
# (lib/pi-intake-tick.sh) caps SELF-maintenance (fleet-ops) claims at
# SELF_MAINT_CLAIM_PCT of this tick's available slots (floor 1) per tick,
# so a giant fleet-ops agent-ready backlog cannot flood the fleet while
# product (0509) work waits. Product repos are never capped. A
# critical-path (or escalate-senior) issue is exempt from the cap and
# claims even past the budget.
#
# This also retires the gap-audit yield rule (fleet-ops#180): the
# ordering organs that made product yield to fleet-ops gap-audit work
# (pi-intake-priority, fleet-gap-closure-yield/order) are not referenced
# by the live deterministic tick; the cap itself is the self-limiting
# control-plane budget so fleet-ops can no longer outrun product.
#
# Static-grep + shell arithmetic drill (same shape as the umbrella /
# escalate-senior exclusion tests): pins the cap mechanism without a live
# systemd/gh environment.
#
# Proves:
#   1. A SELF_MAINT_CLAIM_PCT knob (default 20) overridable via env.
#   2. A CRITICAL_PATH_LABEL seam (default critical-path) for exemption.
#   3. The cap is computed as floor(slots * pct / 100) with a floor of 1.
#   4. The tick skips non-exempt fleet-ops issues once claims >= cap.
#   5. Exempt (critical-path) issues claim even past the cap.
#   6. The counter increments only on real non-exempt claims.
#   7. Product repos (0509) are not capped.
#   8. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: SELF_MAINT_CLAIM_PCT knob present and overridable ===
grep -qF 'SELF_MAINT_CLAIM_PCT="${PI_INTAKE_SELF_MAINT_CLAIM_PCT:-20}"' "$tick" \
    || fail "SELF_MAINT_CLAIM_PCT knob (default 20) not found in tick"
ok "Test 1: SELF_MAINT_CLAIM_PCT knob present (default 20)"

# === Test 2: CRITICAL_PATH_LABEL seam present and overridable ===
grep -qF 'CRITICAL_PATH_LABEL="${PI_INTAKE_CRITICAL_PATH_LABEL:-critical-path}"' "$tick" \
    || fail "CRITICAL_PATH_LABEL seam not found in tick"
ok "Test 2: CRITICAL_PATH_LABEL seam present (default critical-path)"

# === Test 3: cap = floor(slots * pct / 100) with floor 1 ===
# Reproduce the exact expression the tick uses and prove floor-1 rounding.
cap_for() {
    local slots="$1" pct="$2"
    local c=$(( slots * pct / 100 ))
    (( c < 1 )) && c=1
    printf '%s\n' "$c"
}
grep -qF '_self_maint_cap=$(( slots * SELF_MAINT_CLAIM_PCT / 100 ))' "$tick" \
    || fail "cap expression (slots * SELF_MAINT_CLAIM_PCT / 100) not found in tick"
grep -qF '(( _self_maint_cap < 1 )) && _self_maint_cap=1' "$tick" \
    || fail "floor-1 guard not found in tick"
# slots=20, pct=20 -> 4 (20% of 20)
[[ "$(cap_for 20 20)" == "4" ]] || fail "20% of 20 should be 4, got $(cap_for 20 20)"
# slots=4, pct=20 -> 0, floored to 1
[[ "$(cap_for 4 20)" == "1" ]] || fail "floor-1: 20% of 4 should floor to 1, got $(cap_for 4 20)"
# slots=1, pct=20 -> 0, floored to 1
[[ "$(cap_for 1 20)" == "1" ]] || fail "floor-1: 20% of 1 should floor to 1, got $(cap_for 1 20)"
ok "Test 3: cap = floor(slots*pct/100) with floor 1 (4 / 1 / 1)"

# === Test 4: tick skips non-exempt fleet-ops when claims >= cap ===
grep -qF 'skipped-self-maintenance-cap' "$tick" \
    || fail "skip message skipped-self-maintenance-cap not found in tick"
grep -qF '_self_maint_claims >= _self_maint_cap' "$tick" \
    || fail "cap comparison (_self_maint_claims >= _self_maint_cap) not found in tick"
ok "Test 4: non-exempt fleet-ops skip when claims >= cap"

# === Test 5: critical-path exemption (claims even past the cap) ===
# Reproduce the jq exemption filter the tick runs: a critical-path label
# present in the labels array marks the issue exempt.
exempt() {
    local labels_json="$1"
    printf '%s' "$labels_json" | jq -e --arg cp "critical-path" \
        '[.[]?.name // empty] | index($cp) != null' >/dev/null 2>&1
}
grep -qF 'index($cp) != null' "$tick" \
    || fail "critical-path exemption filter (index(\$cp) != null) not found in tick"
exempt '[{"name":"critical-path"},{"name":"agent-ready"}]' \
    || fail "critical-path issue must be exempt"
if exempt '[{"name":"agent-ready"},{"name":"fix"}]'; then
    fail "non-critical-path issue must NOT be exempt"
fi
ok "Test 5: critical-path exemption filter (exempt true when critical-path, false otherwise)"

# === Test 6: counter increments only on real non-exempt claims ===
grep -qF '_self_maint_claims=$(( _self_maint_claims + 1 ))' "$tick" \
    || fail "claim counter increment not found in tick"
grep -qF '_self_maint_claims=0' "$tick" \
    || fail "claim counter init (0) not found in tick"
ok "Test 6: claim counter init and increment present"

# === Test 7: product repos (0509) are not capped ===
# The cap is gated on the repo being self-maintenance / fleet-ops; product
# repos fall through with _self_maint_cap=0 (no cap).
grep -qF 'product_first_is_self_maintenance "$REPO" || [[ "$REPO" == "fleet-ops" ]]' "$tick" \
    || fail "self-maintenance repo gate not found in tick (product repos should be uncapped)"
ok "Test 7: cap gated to self-maintenance/fleet-ops repo (product repos uncapped)"

# === Test 8: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning
    ok "Test 8: shellcheck clean"
else
    echo "SKIP: Test 8: shellcheck not installed"
fi

echo ""
echo "ALL OK: intake-tick self-maintenance claim cap (fleet-ops#3254)"
