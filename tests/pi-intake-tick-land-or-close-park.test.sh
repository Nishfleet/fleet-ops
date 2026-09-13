#!/usr/bin/env bash
# tests/pi-intake-tick-land-or-close-park.test.sh
#
# fleet-ops#4553: the bot-authored land-or-close slow-spaced reclaim spin.
# A land-or-close ticket (e.g. #4417, "Land-or-close stale MERGEABLE PRs")
# drives OTHER PRs to merge, but the worker cannot `gh issue close`
# (land-or-close issues are closed by Nish, as #2263 was). Its acceptance is
# met without opening its own claim-branch delivery PR, so the #4540 park
# detector (which requires protection + a merged claim-branch PR) and the
# reset (#2462) / window (#2772) gates all miss the SAME slow-spaced spin the
# #4540 protected-merged detector was built for. This test pins the new
# land-or-close park branch contract:
#
#   1. The `skipped-parked-land-or-close` marker exists (the termination
#      shell in #4553 greps for exactly this string).
#   2. The land-or-close branch is an `elif` — it ADDS to the #4540
#      protected-merged path, never replaces it.
#   3. It requires: NOT protected (`_park_protected == 0`; bot-authored /
#      no critical-path) AND a `termination:` clause AND the body names
#      other PRs via a `gh pr <verb>` probe (`view`, `checks`, `list`,
#      `merge` — fleet-ops#5835 widened this from `gh pr view`-only after
#      #5761's `gh pr checks 5744` termination evaded the park) AND no
#      merged claim-branch delivery PR — all four, else no land-or-close park.
#   4. On trip: awaiting-runtime-gate label added, agent-ready removed, a
#      land-or-close-specific comment (fleet-ops#4553) posted, and the issue
#      skipped via continue.
#   5. The existing protected-merged path is untouched (covered by
#      tests/pi-intake-tick-awaiting-runtime-gate.test.sh).
#   6. shellcheck clean on the changed file.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: skipped-parked-land-or-close marker present ===
grep -qF 'skipped-parked-land-or-close' "$tick" \
    || fail "skipped-parked-land-or-close marker not found (the #4553 termination shell greps for exactly this)"
ok "Test 1: skipped-parked-land-or-close marker present"

# === Test 2: land-or-close branch is an elif, additive to #4540 ===
grep -qF 'elif (( _park_protected == 0 ))' "$tick" \
    || fail "land-or-close branch must be an elif on _park_protected == 0 (additive, not a replacement)"
grep -qF 'if (( _park_protected == 1 )) &&' "$tick" \
    || fail "the #4540 protected-merged `if` branch must still be present (unchanged)"
ok "Test 2: land-or-close branch is an elif; protected-merged path unchanged"

# === Test 3: all four land-or-close preconditions wired ===
grep -qF 'grep -qi '\''termination:'\''' "$tick" \
    || fail "termination: clause check not found"
grep -qF "grep -Eiq 'gh pr (view|checks|list|merge)'" "$tick" \
    || fail "gh pr <verb> probe (names other PRs) check not found (fleet-ops#5835 widened past 'gh pr view'-only)"
grep -qF "grep -qi 'gh pr view'" "$tick" \
    && fail "the old 'gh pr view'-only probe is still present (fleet-ops#5835: #5761's 'gh pr checks' termination evades it)" \
    || true
grep -qF -- '--head "claim/issue-$N" --state merged' "$tick" \
    || fail "merged claim-branch delivery PR probe not found (land-or-close must park only when ABSENT)"
# the no-merged probe is reused by both branches; count it.
probe_count=$(grep -cF -- '--head "claim/issue-$N" --state merged' "$tick")
(( probe_count >= 1 )) || fail "merged claim-branch probe missing"
ok "Test 3: land-or-close requires termination: + gh pr <verb> probe + no-protection + no merged claim-branch PR"

# === Test 3b: the widened verb grep matches the #5761 live-miss termination ===
# fleet-ops#5835: #5761's termination is 'gh pr checks 5744 -R Nishfleet/fleet-ops'
# — the old predicate grepped only for 'gh pr view' and never matched, so the
# issue re-spun a worker every intake cycle. Pin the actual regex against that
# body shape.
_checks_body='termination: gh pr checks 5744 -R Nishfleet/fleet-ops'
printf '%s' "$_checks_body" | grep -Eiq 'gh pr (view|checks|list|merge)' \
    || fail "the widened gh pr verb regex must match a 'gh pr checks' termination (fleet-ops#5835 live miss on #5761)"
for _other_verb in view list merge; do
    printf '%s' "termination: gh pr $_other_verb 1234 -R Nishfleet/fleet-ops" | grep -Eiq 'gh pr (view|checks|list|merge)' >/dev/null \
        || fail "the widened regex must match 'gh pr $_other_verb' terminations"
done
printf '%s' "termination: some future event" | grep -Eiq 'gh pr (view|checks|list|merge)' >/dev/null \
    && fail "the widened regex must NOT match a termination with no gh pr probe" \
    || true

# === Test 4: non-protected requirement (bot-authored / no critical-path) ===
# _park_protected defaults to 0 and is set to 1 only by critical-path or
# nish3451 ownership. The land-or-close branch fires only when it is 0.
park_start=$(grep -n '_park_protected=0' "$tick" | head -1 | cut -d: -f1)
critical_line=$(grep -n 'index("critical-path") != null' "$tick" | head -1 | cut -d: -f1)
land_line=$(grep -n 'elif (( _park_protected == 0 ))' "$tick" | head -1 | cut -d: -f1)
[[ -n "$park_start" && -n "$land_line" ]] || fail "protection init or land-or-close elif line not found"
(( land_line > park_start )) \
    || fail "land-or-close elif (line $land_line) must come after the protection determination (line $park_start)"
ok "Test 4: land-or-close fires only for non-protected issues (bot-authored, no critical-path)"

# === Test 5: park trip flips the label + land-or-close comment + skip ===
grep -qF -- '--add-label awaiting-runtime-gate --remove-label agent-ready' "$tick" \
    || fail "park label flip (add awaiting-runtime-gate, remove agent-ready) not found"
grep -qF 'fleet-ops#4553' "$tick" \
    || fail "land-or-close-specific comment (fleet-ops#4553) not found"
# count continue statements guarded by the land-or-close block
land_continue=$(sed -n '/elif (( _park_protected == 0 ))/,/^        fi$/p' "$tick" | grep -c 'continue')
(( land_continue >= 1 )) \
    || fail "land-or-close park branch must skip the claim (continue)"
ok "Test 5: land-or-close trip flips the label, posts a fleet-ops#4553 comment, and skips"

# === Test 6: park label provisioned (create --force) before add ===
grep -qF 'label create awaiting-runtime-gate' "$tick" \
    || fail "missing 'label create awaiting-runtime-gate' (gh issue edit --add-label cannot auto-create a missing label)"
create_line=$(grep -n 'label create awaiting-runtime-gate' "$tick" | head -1 | cut -d: -f1)
add_line=$(grep -n -- '--add-label awaiting-runtime-gate' "$tick" | head -1 | cut -d: -f1)
[[ -n "$create_line" && -n "$add_line" ]] || fail "label create or add line not found"
(( create_line < add_line )) \
    || fail "label create (line $create_line) must precede the --add-label (line $add_line)"
ok "Test 6: awaiting-runtime-gate label provisioned (create --force) before it is added"

# === Test 7: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" --severity=warning
    ok "Test 7: shellcheck clean"
else
    echo "SKIP: Test 7: shellcheck not installed"
fi

echo "ALL OK: land-or-close park detector (fleet-ops#4553)"