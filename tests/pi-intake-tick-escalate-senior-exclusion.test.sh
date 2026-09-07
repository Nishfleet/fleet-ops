#!/usr/bin/env bash
# tests/pi-intake-tick-escalate-senior-exclusion.test.sh
#
# fleet-ops#234 / #2007: the deterministic intake tick (lib/pi-intake-tick.sh)
# MUST exclude escalate-senior issues from the regular-worker claim order,
# the same way the model-based orderer (lib/intake-priority.sh,
# pi-intake-priority order) drops them via select(.escalation != true).
# Without this, a regular pi-issue@ worker gets dispatched on a
# senior-auditor-owned escalation — the #2007 live class: pi-issue@fleet-ops-2007
# claimed an [escalate-senior] scout-futility wrapper that pi-escalation-audit
# was already convening a three-senior panel on. The senior-auditor panel
# lists escalate-senior directly (not agent-ready), so dropping them here
# does not hide them from the panel.
#
# Static-grep + jq drill (same shape as pi-intake-tick-claims-log and
# pi-intake-tick-seat-gate): pins the exclusion in the tick without a live
# systemd/gh environment.
#
# Proves:
#   1. The tick fetches labels (so the filter has data to work on).
#   2. The tick defines an overridable ESCALATE_LABEL seam.
#   3. The tick runs a jq filter that drops escalate-senior issues.
#   4. The jq filter keeps regular agent-ready issues.
#   5. The jq filter handles the real gh labels shape (objects with .name).
#   6. The jq filter handles a missing/empty labels array.
#   7. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: tick fetches labels ===
grep -qF 'gh issue list -R "$FULL" -l agent-ready --state open --json number,title,labels' "$tick" \
    || fail "tick must fetch labels (--json number,title,labels) so the escalate-senior filter has data"
ok "Test 1: tick fetches labels for the escalate-senior filter"

# === Test 2: ESCALATE_LABEL seam defined and overridable ===
grep -qF 'ESCALATE_LABEL="${PI_INTAKE_ESCALATE_LABEL:-escalate-senior}"' "$tick" \
    || fail "ESCALATE_LABEL seam (overridable via PI_INTAKE_ESCALATE_LABEL) not found in tick"
ok "Test 2: ESCALATE_LABEL seam present and overridable"

# === Test 3: jq filter drops escalate-senior issues ===
grep -qF 'index($esc) == null' "$tick" \
    || fail "jq escalate-senior exclusion filter (index(\$esc) == null) not found in tick"
ok "Test 3: jq escalate-senior exclusion filter present"

# === Test 4 + 5 + 6: jq drill on the real gh labels shape ===
# Reproduce the exact filter the tick runs and prove it drops only
# escalate-senior issues, keeps regular ones, and tolerates missing labels.
filter='[.[] | select((.labels // []) | map(if type == "object" then (.name // empty) else . end) | index("escalate-senior") == null)]'

fixture='[
  {"number":2007,"title":"[escalate-senior] scout futility","labels":[{"name":"agent-ready","id":1,"color":"FBCA04"},{"name":"escalate-senior","id":2,"color":"d93f0b"}]},
  {"number":2001,"title":"regular work","labels":[{"name":"agent-ready","id":1,"color":"FBCA04"}]},
  {"number":2003,"title":"no labels","labels":[]},
  {"number":2005,"title":"string labels","labels":["agent-ready","escalate-senior"]}
]'
out=$(printf '%s' "$fixture" | jq -c "$filter")
count=$(printf '%s' "$out" | jq 'length')
[[ "$count" == "2" ]] || fail "drill: expected 2 issues after filter, got $count: $out"
kept=$(printf '%s' "$out" | jq -r '[.[].number] | sort | join(",")')
[[ "$kept" == "2001,2003" ]] || fail "drill: expected to keep 2001,2003; got $kept"
ok "Test 4-6: jq filter drops escalate-senior (object + string labels), keeps regular, tolerates missing labels"

# === Test 7: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning
    ok "Test 7: shellcheck clean"
else
    echo "SKIP: Test 7: shellcheck not installed"
fi

echo ""
echo "ALL OK: intake-tick escalate-senior exclusion (fleet-ops#234 / #2007)"
