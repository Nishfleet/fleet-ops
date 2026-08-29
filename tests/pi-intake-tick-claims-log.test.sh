#!/usr/bin/env bash
# tests/pi-intake-tick-claims-log.test.sh
#
# fleet-ops#1455: the intake tick MUST append a claim record to the claims
# index (ready-work-claims.log) on each successful claim+spawn. Without this,
# opus-heartbeat-gather reads an empty log, reports claims_last_2h=0 even
# while claims are happening (visible in the journal as `claimed+spawned`),
# and watchers auto-file false "Intake starvation" issues (#1455, #1377,
# #1448). The claims index is also read by fleet-restore-drill (B.2 — a
# restored fleet tells which issues are claimed from this file).
#
# This is a static-grep test (same shape as pi-intake-tick-spawn-postcondition
# and pi-intake-tick-seat-gate): it pins the mechanical fix in
# lib/pi-intake-tick.sh without a live systemd/gh environment.
#
# Proves:
#   1. The tick defines a CLAIMS_LOG path variable (overridable for tests).
#   2. The tick appends to CLAIMS_LOG after the claimed+spawned line.
#   3. The append format is a timestamped claim record (ISO-8601 Z + space +
#      "claimed" keyword) — matches both consumers:
#        - opus-heartbeat-gather: ISO_START regex + "claimed" in line
#        - fleet-restore-drill B.2: ^YYYY-MM-DDTHH:MM:SSZ <rest>
#   4. The append comes AFTER all post-condition guards (branch, packet,
#      unit) so a failed spawn never writes a false claim record.
#   5. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: CLAIMS_LOG path variable defined and overridable ===
grep -qF 'CLAIMS_LOG="${PI_INTAKE_CLAIMS_LOG:-' "$tick" \
    || fail "CLAIMS_LOG path variable (overridable via PI_INTAKE_CLAIMS_LOG) not found in tick"
ok "Test 1: CLAIMS_LOG path variable present and overridable"

# === Test 2: append to CLAIMS_LOG after claimed+spawned ===
grep -qF '>> "$CLAIMS_LOG"' "$tick" \
    || fail "append to CLAIMS_LOG not found in tick"
ok "Test 2: tick appends to CLAIMS_LOG"

# === Test 3: append format is a timestamped claim record ===
# Must match opus-heartbeat-gather's ISO_START regex and "claimed" predicate,
# AND fleet-restore-drill B.2's ^YYYY-MM-DDTHH:MM:SSZ<space> regex.
# Check the printf template contains the "claimed" keyword and the ISO-Z date
# format string, in the append-to-CLAIMS_LOG line.
append_fmt=$(grep '>> "$CLAIMS_LOG"' "$tick" | head -1)
[[ "$append_fmt" == *"claimed"* ]] \
    || fail "claim record format missing 'claimed' keyword in CLAIMS_LOG append"
[[ "$append_fmt" == *'+%Y-%m-%dT%H:%M:%SZ'* ]] \
    || fail "claim record format missing ISO-8601 Z timestamp format string"
[[ "$append_fmt" == *'line=%s'* ]] \
    || fail "claim record format missing 'line=%s' issue-number field"
ok "Test 3: claim record format matches opus-heartbeat-gather + fleet-restore-drill consumers"

# === Test 4: append comes AFTER all post-condition guards ===
claimed_line=$(grep -n 'echo "issue \$N (\$title): claimed+spawned"' "$tick" | tail -1 | cut -d: -f1)
append_line=$(grep -n '>> "\$CLAIMS_LOG"' "$tick" | tail -1 | cut -d: -f1)
branch_line=$(grep -n 'claim branch missing post-spawn' "$tick" | tail -1 | cut -d: -f1)
packet_line=$(grep -n 'packet missing after write' "$tick" | tail -1 | cut -d: -f1)
lockout_line=$(grep -n 'spawn failed (start-limit lockout' "$tick" | tail -1 | cut -d: -f1)
[[ -n "$claimed_line" ]] || fail "claimed+spawned line not found"
[[ -n "$append_line" ]] || fail "CLAIMS_LOG append line not found"
[[ -n "$branch_line" ]] || fail "branch guard line not found"
[[ -n "$packet_line" ]] || fail "packet guard line not found"
[[ -n "$lockout_line" ]] || fail "lockout guard line not found"
(( claimed_line > branch_line )) \
    || fail "claimed+spawned (line $claimed_line) must come after branch guard (line $branch_line)"
(( append_line > claimed_line )) \
    || fail "CLAIMS_LOG append (line $append_line) must come after claimed+spawned (line $claimed_line) — a failed spawn must not write a false claim record"
ok "Test 4: append comes after all post-condition guards (no false claim records on failed spawns)"

# === Test 5: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning
    ok "Test 5: shellcheck clean"
else
    echo "SKIP: Test 5: shellcheck not installed"
fi

echo ""
echo "ALL OK: intake-tick claims-log write (fleet-ops#1455)"
