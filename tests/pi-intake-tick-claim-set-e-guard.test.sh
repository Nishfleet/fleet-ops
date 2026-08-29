#!/usr/bin/env bash
# tests/pi-intake-tick-claim-set-e-guard.test.sh
#
# Regression: a GitHub secondary rate limit ("submitted too quickly") on
# `gh issue edit` or `gh issue comment` must NOT kill the intake tick mid-
# claim. The tick runs under `set -euo pipefail`; the original retry loops
# captured output with a bare `$(...)` and read `$?` on the NEXT line:
#
#     edit_out=$(gh issue edit ...)   # set -e kills the script HERE on failure
#     edit_rc=$?                       # dead code — never reached
#
# So the first 429/secondary-rate failure aborted the tick AFTER the claim
# branch was pushed and the label flipped, but BEFORE the worker spawned —
# an orphaned claim and a failed unit. The retry loops were dead code.
#
# The fix adds `|| rc=$?` guards (so set -e cannot fire) and resets rc=0 at
# the top of each iteration (so a successful retry clears a prior nonzero
# rc). The claim comment is also made non-fatal on exhaustion: the comment
# is a GH-visibility nicety, not load-bearing (the branch + label flip +
# claims log are the authoritative record), so a sustained secondary rate
# limit must not abandon an otherwise-valid claim.
#
# Proves (static, runs in CI without gh/git/network):
#   1. `gh issue edit` capture carries an `|| edit_rc=$?` guard.
#   2. `gh issue comment` capture carries an `|| comment_rc=$?` guard.
#   3. edit_rc is reset to 0 inside the retry loop (retry success clears it).
#   4. comment_rc is reset to 0 inside the retry loop.
#   5. A failed comment does NOT exit 1 — the tick continues to spawn.
#   6. The comment-failure path logs loud (non-silent) and continues.
#   7. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: gh issue edit capture has || edit_rc=$? guard ===
# A bare `edit_out=$(gh issue edit ...)` dies under set -e on the first
# failure. The `|| edit_rc=$?` makes the failure set the rc instead of
# aborting, so the retry loop below can run.
grep -qF 'edit_out=$(gh issue edit "$N" -R "$FULL" --remove-label agent-ready --add-label agent-in-progress 2>&1) || edit_rc=$?' "$tick" \
    || fail "gh issue edit capture must use '|| edit_rc=\$?' guard (set -e kills a bare \$(...))"
ok "Test 1: gh issue edit capture guarded against set -e"

# === Test 2: gh issue comment capture has || comment_rc=$? guard ===
grep -qF 'comment_out=$(gh issue comment "$N" -R "$FULL" --body "$comment_body" 2>&1) || comment_rc=$?' "$tick" \
    || fail "gh issue comment capture must use '|| comment_rc=\$?' guard (set -e kills a bare \$(...))"
ok "Test 2: gh issue comment capture guarded against set -e"

# === Test 3: edit_rc reset to 0 inside the retry loop ===
# Without a reset, a successful retry leaves edit_rc holding the prior
# nonzero value, and the post-loop `if [[ $edit_rc -ne 0 ]]` misfires.
# The reset must appear inside the `for _ in 1 2 3` loop body, before the
# capture.
edit_loop=$(awk '/for _ in 1 2 3; do/{f=1} f&&/edit_rc=0/{print NR": "$0; c++} f&&/done/{exit} END{print c}' "$tick")
edit_resets=$(printf '%s\n' "$edit_loop" | tail -1)
(( edit_resets >= 1 )) \
    || fail "edit_rc must be reset to 0 inside the retry loop (found $edit_resets resets)"
ok "Test 3: edit_rc reset to 0 inside retry loop ($edit_resets reset(s))"

# === Test 4: comment_rc reset to 0 inside the retry loop ===
comment_loop=$(awk '/comment_rc=0$/{print NR": "$0}' "$tick")
comment_resets=$(printf '%s\n' "$comment_loop" | wc -l)
# Two occurrences: the pre-loop init (line ~430) AND the in-loop reset.
(( comment_resets >= 2 )) \
    || fail "comment_rc must be reset to 0 inside the retry loop (found $comment_resets total resets; need >=2 for init+loop)"
ok "Test 4: comment_rc reset to 0 inside retry loop ($comment_resets reset(s))"

# === Test 5: failed comment does NOT exit 1 ===
# The old code did `exit 1` on comment exhaustion. The new code logs and
# continues so the worker still spawns. Confirm no `exit 1` in the
# comment-failure branch.
comment_fail_block=$(awk '/if \[\[ \$comment_rc -ne 0 \]\]; then/{f=1} f{print} f&&/fi$/{exit}' "$tick")
printf '%s\n' "$comment_fail_block" | grep -qF 'exit 1' \
    && fail "comment-failure branch must NOT exit 1 (orphaned claim); got: $comment_fail_block"
ok "Test 5: failed comment does not exit 1 (claim not orphaned)"

# === Test 6: comment-failure path logs loud and continues ===
printf '%s\n' "$comment_fail_block" | grep -qF 'claim comment skipped' \
    || fail "comment-failure branch must log 'claim comment skipped' (non-silent)"
# The branch must NOT contain a `continue` statement that skips the worker
# spawn — the worker packet + unit start live AFTER this block and must run.
# Match a line-leading `continue` (statement), not the word inside a comment.
printf '%s\n' "$comment_fail_block" | grep -qE '^[[:space:]]+continue\b' \
    && fail "comment-failure branch must not 'continue' (worker spawn must still run)"
ok "Test 6: comment-failure logs loud and falls through to worker spawn"

# === Test 7: shellcheck clean ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" || fail "shellcheck not clean on $tick"
    ok "Test 7: shellcheck clean"
else
    ok "Test 7: shellcheck not installed (skipped)"
fi

echo
echo "ALL OK: intake-tick claim set -e guard + non-fatal comment (claim-loss regression)"
