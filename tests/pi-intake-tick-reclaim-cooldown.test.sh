#!/usr/bin/env bash
# tests/pi-intake-tick-reclaim-cooldown.test.sh
#
# fleet-ops#2133: proves the intake tick has the reclaim-cooldown skip and
# the stale-claim-release logic that together break the spawn-die-respawn
# wedge. Static structural test (the tick needs gh/git/network to run
# end-to-end; the assertions verify the logic is present and correctly
# ordered, same pattern as pi-intake-tick-spawn-postcondition.test.sh).
#
# Proves:
#   1. RECLAIM_COOLDOWN_S env var is defined (testability + tunability).
#   2. The cooldown file path uses the per-issue ATTEMPTS_DIR convention.
#   3. The cooldown skip fires when age < RECLAIM_COOLDOWN_S and emits
#      skipped-reclaim-cooldown.
#   4. The cooldown marker is removed after expiry (issue becomes claimable).
#   5. The cooldown check precedes the git fetch / ls-remote (zero network
#      cost for a cooldown'd issue).
#   6. The skipped-claim-lost path now checks for a live worker unit.
#   7. The skipped-claim-lost path checks for an open PR before skipping.
#   8. A stale claim (no live worker, no open PR) is released via branch
#      delete, not skipped forever.
#   9. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: RECLAIM_COOLDOWN_S env var defined ===
grep -qF 'RECLAIM_COOLDOWN_S="${PI_INTAKE_RECLAIM_COOLDOWN_S:-900}"' "$tick" \
    || fail "RECLAIM_COOLDOWN_S env var not found (must be overridable for tests)"
ok "Test 1: RECLAIM_COOLDOWN_S env var defined (default 900s, overridable)"

# === Test 2: cooldown file path uses ATTEMPTS_DIR convention ===
grep -qF '_cooldown_file="$ATTEMPTS_DIR/pi-issue-${REPO}-${N}.cooldown"' "$tick" \
    || fail "cooldown file path must use ATTEMPTS_DIR/pi-issue-\${REPO}-\${N}.cooldown"
ok "Test 2: cooldown file path uses per-issue ATTEMPTS_DIR convention"

# === Test 3: cooldown skip fires when age < RECLAIM_COOLDOWN_S ===
grep -qF 'skipped-reclaim-cooldown' "$tick" \
    || fail "skipped-reclaim-cooldown skip message not found"
grep -qF '_cd_age < RECLAIM_COOLDOWN_S' "$tick" \
    || fail "cooldown age comparison (< RECLAIM_COOLDOWN_S) not found"
ok "Test 3: cooldown skip fires when age < RECLAIM_COOLDOWN_S"

# === Test 4: cooldown marker removed after expiry ===
grep -qF 'rm -f "$_cooldown_file"' "$tick" \
    || fail "cooldown marker removal after expiry not found"
ok "Test 4: cooldown marker removed after expiry (issue becomes claimable)"

# === Test 5: cooldown check precedes per-issue git fetch / ls-remote ===
# The tick has a pre-loop fetch (line ~362) and a per-issue fetch inside the
# loop. The cooldown check is inside the loop and must precede the per-issue
# fetch + ls-remote so a cooldown'd issue costs zero network calls.
cooldown_line=$(grep -n '_cooldown_file="$ATTEMPTS_DIR' "$tick" | head -1 | cut -d: -f1)
# Per-issue fetch: the one that says "failed for issue $N" (inside the loop).
fetch_line=$(grep -n 'git fetch origin failed for issue $N' "$tick" | head -1 | cut -d: -f1)
# The fetch call is 2 lines above the error message; back up to find it.
fetch_call_line=$(( fetch_line - 1 ))
lsremote_line=$(grep -n 'remote=$(git -C "$REPO_DIR" ls-remote origin "refs/heads/claim/issue-$N"' "$tick" | head -1 | cut -d: -f1)
[[ -n "$cooldown_line" ]] || fail "cooldown check line not found"
[[ -n "$fetch_line" ]] || fail "per-issue fetch error line not found"
[[ -n "$lsremote_line" ]] || fail "ls-remote line not found"
(( cooldown_line < fetch_call_line )) \
    || fail "cooldown check (line $cooldown_line) must precede per-issue git fetch (line $fetch_call_line)"
(( cooldown_line < lsremote_line )) \
    || fail "cooldown check (line $cooldown_line) must precede ls-remote (line $lsremote_line)"
ok "Test 5: cooldown check precedes per-issue git fetch + ls-remote (zero network cost for cooldown'd issue)"

# === Test 6: skipped-claim-lost checks for live worker unit ===
grep -qF '_claim_unit="pi-issue@${REPO}-${N}.service"' "$tick" \
    || fail "claim worker unit check not found in skipped-claim path"
grep -qF 'skipped-claim-live' "$tick" \
    || fail "skipped-claim-live message not found"
ok "Test 6: skipped-claim path checks for a live worker unit"

# === Test 7: skipped-claim-lost checks for open PR before skipping ===
grep -qF 'skipped-claim-pr-open' "$tick" \
    || fail "skipped-claim-pr-open message not found"
grep -qF 'repos/$FULL/pulls?state=open&head=${FULL#*/}:claim/issue-$N' "$tick" \
    || fail "open PR check (gh api pulls) not found in skipped-claim path"
ok "Test 7: skipped-claim path checks for an open PR before skipping"

# === Test 8: stale claim (no live worker, no open PR) is released ===
grep -qF 'released-stale-claim' "$tick" \
    || fail "released-stale-claim message not found"
grep -qF 'push origin ":refs/heads/claim/issue-$N"' "$tick" \
    || fail "stale claim branch delete (push :refs/heads) not found"
# The stale-claim release must fall through to re-claim (no `continue` after
# the successful delete). The `continue` is only in the else (failed-delete)
# branch. Verify the success branch (if ... released-stale-claim ... else)
# has no continue before the else.
stale_if_branch=$(awk '/released-stale-claim/{f=1} f{print} f&&/else/{exit}' "$tick")
printf '%s\n' "$stale_if_branch" | grep -qE '^[[:space:]]+continue\b' \
    && fail "stale-claim release (success branch) must NOT continue (must fall through to re-claim)"
# The else branch MUST have a continue (failed delete -> skip this tick).
stale_else_branch=$(awk '/skipped-claim-lost \(stale branch delete failed/{f=1} f{print} f&&/fi$/{exit}' "$tick")
printf '%s\n' "$stale_else_branch" | grep -qE '^[[:space:]]+continue\b' \
    || fail "stale-claim failed-delete (else branch) must continue (skip this tick)"
ok "Test 8: stale claim (no live worker, no open PR) is released via branch delete, falls through to re-claim"

# === Test 9: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" --severity=warning
    ok "Test 9: shellcheck clean"
else
    echo "SKIP: Test 9: shellcheck not installed"
fi

echo
echo "ALL OK: intake-tick reclaim cooldown + stale-claim release (fleet-ops#2133)"
