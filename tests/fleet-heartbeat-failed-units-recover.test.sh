#!/usr/bin/env bash
# tests/fleet-heartbeat-failed-units-recover.test.sh
#
# fleet-ops#28: fleet-heartbeat ran 57s after pi-intake-repair@0509.service
# failed and did not recover it. Root cause: the failed-units matcher only
# looked at `pi-issue-*` and `fable-p*` (hyphen), so it matched neither the
# template instance `pi-issue@*` (at-sign) nor the repair unit
# `pi-intake-repair@*`. The unit was invisible and was cleared by hand.
#
# This test pins the fix:
#   A. The matcher covers every fleet worker/repair/cleanup unit instance
#      (at-sign templates + fable-p*), so no fleet unit is invisible.
#   B. unit_recovery_class splits units into `recover` (supply/repair, safe
#      to reset+start) and `observe` (workers + reaps, whose OnFailure reap
#      and intake re-dispatch are the retry path — a heartbeat restart would
#      race a second worker onto the same issue).
#   C. The recover floor is a plain `systemctl --user reset-failed` + `start`
#      (no agent lane involved), bounded by FAILED_UNITS_MAX_ATTEMPTS, with
#      a loud UNIT-ESCALATE when exhausted.
#   D. Each tick records an observable summary (failed_seen / failed_repaired
#      / failed_still_failed / failed_exhausted / failed_escalated) so a tick
#      that changed nothing is distinguishable from a tick that did not run.
#
# We do not run the full tick (it depends on gh + a live repo). We extract
# the real helper functions from the source and exercise them, and grep the
# source for the structural invariants.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

# Extract a single function body from the source by name (lines from the
# `name()` line through the closing `}` at column 1).
extract_fn() {
    local fn="$1"
    awk -v fn="$fn" '
        $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { in_fn=1 }
        in_fn { print }
        in_fn && /^\}/ { in_fn=0 }
    ' "$bin"
}

# --- Phase A: the matcher covers all fleet unit instances -------------------
# Pull the real matcher regex out of the source and prove it admits the
# incident unit and every other fleet template instance, while rejecting a
# non-fleet failed unit.
matcher_line=$(grep -nE "grep -E '\\^\\(pi-\\(intake" "$bin" | head -1) \
    || fail "could not find the failed-units matcher grep in $bin"
matcher_re=$(printf '%s\n' "$matcher_line" \
    | sed -E "s/.*grep -E '([^']*)'.*/\1/" )
[[ -n "$matcher_re" ]] || fail "could not extract matcher regex from: $matcher_line"

matches() { printf '%s' "$1" | grep -qE "$matcher_re"; }

for u in \
    pi-intake-repair@0509.service \
    pi-intake@0509.service \
    pi-scout@siterep-public.service \
    pi-scout-repair@0509.service \
    pi-issue@fleet-ops-28.service \
    pi-issue-failed@fleet-ops-28.service \
    pi-packet@p42.service \
    pi-packet-failed@p42.service \
    fable-p123.service
do
    matches "$u" || fail "matcher must admit fleet unit: $u (regex: $matcher_re)"
done
ok "matcher admits every fleet worker/repair/cleanup unit instance"

# A non-fleet failed unit must NOT be admitted (heartbeat must not adopt
# random host services).
for u in \
    agent-scheduler-drift.service \
    snapd.service \
    fleet-heartbeat.service
do
    if matches "$u"; then
        fail "matcher must NOT admit non-fleet unit: $u (regex: $matcher_re)"
    fi
done
ok "matcher rejects non-fleet units (heartbeat does not adopt host services)"

# The old §4 hyphen-only matcher must be gone. pi-issue-* (hyphen) never
# matched the at-sign template instance, which is the #28 bug. The exact old
# §4 pattern was `^(pi-issue-|fable-p)` (no pi-packet-); the §7 degraded-lane
# pass uses a different pattern (`^(pi-issue-|pi-packet-|fable-p)`) and is
# out of scope here. Pin that the failed-units pipeline no longer feeds the
# old hyphen pattern.
if grep -qF "grep -E '^(pi-issue-|fable-p)'" "$bin"; then
    fail "old §4 hyphen matcher ^(pi-issue-|fable-p) still present — the #28 bug"
fi
ok "old §4 hyphen-only matcher is gone"

# --- Phase B: unit_recovery_class splits recover vs observe -----------------
eval "$(extract_fn unit_recovery_class)" \
    || fail "could not extract unit_recovery_class from $bin"

for u in \
    pi-intake@0509.service \
    pi-intake-repair@0509.service \
    pi-scout@0509.service \
    pi-scout-repair@0509.service
do
    [[ "$(unit_recovery_class "$u")" == "recover" ]] \
        || fail "unit_recovery_class($u) must be recover (supply/repair, safe to restart)"
done
ok "supply/repair units classify as recover"

for u in \
    pi-issue@fleet-ops-28.service \
    pi-packet@p42.service \
    pi-issue-failed@fleet-ops-28.service \
    pi-packet-failed@p42.service \
    fable-p123.service \
    fleet-heartbeat.service \
    agent-scheduler-drift.service
do
    [[ "$(unit_recovery_class "$u")" == "observe" ]] \
        || fail "unit_recovery_class($u) must be observe (worker/reap — restart races the OnFailure cleanup)"
done
ok "worker/reap/other units classify as observe (no heartbeat restart)"

# --- Phase C: the recover floor + N-attempt escalation ----------------------
# The floor is a plain systemctl reset-failed + start --no-block (no agent
# lane). Pin the exact calls so a future edit cannot silently drop the floor
# or make it depend on an LLM.
grep -F -- 'systemctl --user reset-failed "$unit"' "$bin" >/dev/null \
    || fail "recover floor must call: systemctl --user reset-failed <unit>"
grep -F -- 'systemctl --user start --no-block "$unit"' "$bin" >/dev/null \
    || fail "recover floor must call: systemctl --user start --no-block <unit> (no-block so a long oneshot does not blow the tier1 budget)"
ok "recover floor: reset-failed + start --no-block (agent-lane-independent)"

# Bounded by FAILED_UNITS_MAX_ATTEMPTS with a loud UNIT-ESCALATE when exhausted.
grep -F -- 'FAILED_UNITS_MAX_ATTEMPTS' "$bin" >/dev/null \
    || fail "recover floor must be bounded by FAILED_UNITS_MAX_ATTEMPTS"
grep -F -- 'loud "UNIT-ESCALATE"' "$bin" >/dev/null \
    || fail "exhausted recovery must escalate via loud UNIT-ESCALATE (never a quiet failed unit)"
# observe-class units must NOT be reset+started: the restart is gated behind
# the rclass check. Pin that the observe branch continues before the floor.
grep -F -- 'observe-only class=$cls' "$bin" >/dev/null \
    || fail "observe-class transient faults must be logged and skipped, not restarted"
ok "recover floor is bounded (N attempts) and escalates loud; observe units are not restarted"

# --- Phase D: per-tick observability summary --------------------------------
# A tick that changed nothing must be distinguishable from a tick that did
# not run. The final summary line carries the failed-units counters so a
# zero-failed tick still leaves a recorded `failed_seen=0`.
grep -F -- 'failed_seen=$seen' "$bin" >/dev/null \
    || fail "tier1 complete line must report failed_seen (tick-ran vs no-tick distinction)"
grep -F -- 'failed_repaired=$repaired' "$bin" >/dev/null \
    || fail "tier1 complete line must report failed_repaired"
grep -F -- 'failed_still_failed=$still_failed' "$bin" >/dev/null \
    || fail "tier1 complete line must report failed_still_failed"
grep -F -- 'failed_exhausted=$exhausted' "$bin" >/dev/null \
    || fail "tier1 complete line must report failed_exhausted"
grep -F -- 'failed_escalated=$escd' "$bin" >/dev/null \
    || fail "tier1 complete line must report failed_escalated"
ok "per-tick summary records seen/repaired/still_failed/exhausted/escalated (tick-ran is observable)"

# --- Phase E: tier2 engages on the new escalation tag -----------------------
# fleet-heartbeat must route UNIT-ESCALATE into tier 2 (and clear it after a
# successful tier2 run), so an exhausted unit reaches a judgment seat instead
# of sitting failed.
entry="$repo_root/bin/fleet-heartbeat"
grep -F -- 'UNIT-ESCALATE' "$entry" >/dev/null \
    || fail "fleet-heartbeat must recognise UNIT-ESCALATE as a tier2 trigger"
ok "fleet-heartbeat routes UNIT-ESCALATE into tier 2"

echo "all phases passed"
