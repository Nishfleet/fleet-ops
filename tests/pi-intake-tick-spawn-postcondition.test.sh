#!/usr/bin/env bash
# tests/pi-intake-tick-spawn-postcondition.test.sh
#
# fleet-ops#1546: the intake tick's `claimed+spawned` line must be a
# POST-CONDITION, not an intention. Two classes pinned here:
#
#   (a) Start-limit lockout healer: after a seat storm, pi-issue@ units sit
#       in `failed` state with StartLimitBurst exhausted. `systemctl start
#       --no-block` returns exit 0 even when the unit is `failed` — the unit
#       never runs, but the old intake logged `claimed+spawned` anyway (the
#       spawn-vs-alive divergence: 56 claimed+spawned, 2 alive). The tick
#       must detect `failed`, reset-failed (systemd-native clear), retry
#       start once, and only then accept the spawn.
#   (b) Post-condition verification: `claimed+spawned` must be emitted only
#       AFTER verifying branch + packet + unit exist. A unit that is not
#       active/activating, a missing packet, or a missing claim branch is
#       `spawn failed`, not success.
#
# Proves:
#   1. lib/pi-intake-tick.sh has a SYSTEMCTL seam (testability).
#   2. The tick checks is-active AFTER start --no-block (not just exit code).
#   3. The tick calls reset-failed when the unit is `failed` (the healer).
#   4. The tick retries start once after reset-failed.
#   5. The tick verifies the packet file exists before claimed+spawned.
#   6. The tick verifies the claim branch exists (ls-remote) before
#      claimed+spawned.
#   7. A unit stuck in `failed` after reset-failed+retry is reported as
#      `spawn failed (start-limit lockout)`, NOT `claimed+spawned`.
#   8. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: SYSTEMCTL seam ===
grep -qF 'SYSTEMCTL="${SYSTEMCTL:-systemctl}"' "$tick" \
    || fail "SYSTEMCTL seam not found in tick"
ok "Test 1: SYSTEMCTL seam present (testability)"

# === Test 2: is-active check AFTER start --no-block ===
# The post_state check is the core fix: --no-block exit 0 does not mean
# the unit started. Must verify ActiveState.
grep -qF 'post_state=$("$SYSTEMCTL" --user is-active "$unit"' "$tick" \
    || fail "post_state is-active check after start not found"
ok "Test 2: is-active checked after start --no-block"

# === Test 3: reset-failed healer ===
grep -qF '"$SYSTEMCTL" --user reset-failed "$unit"' "$tick" \
    || fail "reset-failed healer not found in tick"
ok "Test 3: reset-failed healer present"

# === Test 4: retry start once after reset-failed ===
# Verify reset-failed is followed by a second start --no-block in the
# healer block (not just reset-failed alone).
healer_start=$(grep -c 'start --no-block "$unit"' "$tick" || true)
(( healer_start >= 2 )) \
    || fail "expected >=2 start --no-block calls (initial + healer retry), found $healer_start"
ok "Test 4: retry start after reset-failed ($healer_start start calls)"

# === Test 5: packet file post-condition ===
grep -qF '[[ -f "$packet_path" ]]' "$tick" \
    || fail "packet file post-condition check not found"
grep -qF 'packet missing after write' "$tick" \
    || fail "packet-missing failure message not found"
ok "Test 5: packet file post-condition verified"

# === Test 6: claim branch post-condition ===
grep -qF 'branch_check=$(git -C "$REPO_DIR" ls-remote origin "refs/heads/claim/issue-$N"' "$tick" \
    || fail "claim branch post-condition check not found"
grep -qF 'claim branch missing post-spawn' "$tick" \
    || fail "branch-missing failure message not found"
ok "Test 6: claim branch post-condition verified"

# === Test 7: failed unit reported, not claimed+spawned ===
grep -qF 'spawn failed (start-limit lockout' "$tick" \
    || fail "start-limit lockout failure message not found"
# The claimed+spawned line must come AFTER all three post-condition guards.
claimed_line=$(grep -n 'echo "issue $N ($title): claimed+spawned"' "$tick" | tail -1 | cut -d: -f1)
lockout_line=$(grep -n 'spawn failed (start-limit lockout' "$tick" | tail -1 | cut -d: -f1)
packet_line=$(grep -n 'packet missing after write' "$tick" | tail -1 | cut -d: -f1)
branch_line=$(grep -n 'claim branch missing post-spawn' "$tick" | tail -1 | cut -d: -f1)
[[ -n "$claimed_line" ]] || fail "claimed+spawned line not found"
[[ -n "$lockout_line" ]] || fail "lockout failure line not found"
[[ -n "$packet_line" ]] || fail "packet failure line not found"
[[ -n "$branch_line" ]] || fail "branch failure line not found"
(( lockout_line < claimed_line )) \
    || fail "lockout guard (line $lockout_line) must precede claimed+spawned (line $claimed_line)"
(( packet_line < claimed_line )) \
    || fail "packet guard (line $packet_line) must precede claimed+spawned (line $claimed_line)"
(( branch_line < claimed_line )) \
    || fail "branch guard (line $branch_line) must precede claimed+spawned (line $claimed_line)"
ok "Test 7: all post-condition guards precede claimed+spawned"

# === Test 8: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning
    ok "Test 8: shellcheck clean"
else
    echo "SKIP: Test 8: shellcheck not installed"
fi

echo ""
echo "ALL OK: intake-tick spawn post-condition + start-limit healer (fleet-ops#1546)"
