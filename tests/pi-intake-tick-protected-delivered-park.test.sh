#!/usr/bin/env bash
# tests/pi-intake-tick-protected-delivered-park.test.sh
#
# fleet-ops#5048 (amended by #5689): the protected-delivered slow-spaced
# reclaim spin. A protected open issue (owner-authored or critical-path)
# with NO merged claim-branch delivery PR still re-claims forever when its
# remaining work was already delivered by a merged PR on a non-claim
# branch, or delegated to a named user .timer/.service that is active —
# the live case was #4891 (delivered by fable-branch PRs #4893 + #4897,
# remainder delegated to `remeasure-4891-timer.timer`, 12 claims in one
# day). Since #5689 the scan runs WITH OR WITHOUT a `termination:` clause
# in the body (see the #4625 sibling test).
#
# This test pins the third park-cell contract:
#
#   1. The `skipped-parked-protected-delivered` marker exists.
#   2. The branch is an `elif` on `_park_protected == 1` gated on the
#      shared `_park_merged_count == 0` probe — it ADDS to the #4540 and
#      #4553 paths, never replaces them. (#5689: the negated `termination:`
#      check was REMOVED — a clause naming a gate that can never fire is
#      exactly the delivered-spin shape, see the #4625 sibling test.)
#   3. It requires the shared merged-claim-branch probe to be ABSENT
#      (`_park_merged_count == 0`) before any delivery signal is read.
#   4. Delivery signals, either sufficient:
#      a. a named user unit token (`X.timer`/`X.service`) in body+comments
#         that `systemctl --user is-active` reports active, checked over
#         ALL matches (first-token-only would miss a later live unit);
#      b. a body/comment reference to a PR that `gh pr view` reports
#         state==MERGED on a head branch other than `claim/issue-<N>`
#         (the `merged` JSON field is NOT a valid `gh pr view` field —
#         fleet-ops#1244 — the check must key on `.state`).
#   5. On trip: awaiting-runtime-gate label added, agent-ready removed, a
#      fleet-ops#5048 comment posted, and the issue skipped via continue.
#   6. Genuinely unfinished protected issues are NOT parked: the continue
#      sits inside the delivery-signal condition, so no timer + no merged
#      non-claim PR means the claim proceeds.
#   7. shellcheck clean on the changed file.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: skipped-parked-protected-delivered marker present ===
grep -qF 'skipped-parked-protected-delivered' "$tick" \
    || fail "skipped-parked-protected-delivered marker not found"
ok "Test 1: skipped-parked-protected-delivered marker present"

# === Test 2: the new cell is an additive elif, ordered after land-or-close ===
elif_line=$(grep -n 'elif (( _park_protected == 1 )) && (( _park_merged_count == 0 ))' "$tick" | head -1 | cut -d: -f1)
[[ -n "$elif_line" ]] \
    || fail "protected-delivered branch must be an elif on _park_protected == 1 gated on _park_merged_count == 0"
land_line=$(grep -n 'elif (( _park_protected == 0 ))' "$tick" | head -1 | cut -d: -f1)
[[ -n "$land_line" ]] || fail "land-or-close elif (#4553) missing"
(( elif_line > land_line )) \
    || fail "protected-delivered elif (line $elif_line) must follow the land-or-close elif (line $land_line)"
grep -qF 'if (( _park_protected == 1 )) &&' "$tick" \
    || fail "the #4540 protected-merged if branch must still be present (unchanged)"
ok "Test 2: protected-delivered branch is an additive elif after the land-or-close branch"

# === Test 3: gated on no merged claim-branch delivery PR; termination: is not an exemption ===
cell=$(sed -n "${elif_line},/^        fi$/p" "$tick")
printf '%s' "$cell" | grep -qF '(( _park_merged_count == 0 ))' \
    || fail "protected-delivered elif must require _park_merged_count == 0 (no claim-branch delivery PR)"
# fleet-ops#5689: the #4540 branch guard must carry the merged-claim-PR
# condition, so a protected+termination: issue with NO merged claim-branch
# PR falls through INTO this scan instead of skipping it.
guard_line=$(grep -n 'if (( _park_protected == 1 )) && printf' "$tick" | head -1 | cut -d: -f1)
[[ -n "$guard_line" ]] || fail "#4540 branch guard missing"
guard=$(sed -n "${guard_line},$(( guard_line + 1 ))p" "$tick")
printf '%s' "$guard" | grep -qF '(( _park_merged_count > 0 ))' \
    || fail "#4540 branch guard must require _park_merged_count > 0 (#5689)"
ok "Test 3: cell requires protected + no merged claim-branch PR; #4540 guard keeps merged-claim priority"

# === Test 4: runtime-unit signal — all .timer/.service tokens probed with is-active ===
printf '%s' "$cell" | grep -qF "grep -oE '[A-Za-z0-9_.@:-]+\\.(timer|service)'" \
    || fail "user .timer/.service token extraction not found"
printf '%s' "$cell" | grep -qF 'systemctl --user is-active' \
    || fail "systemctl --user is-active probe not found"
printf '%s' "$cell" | grep -qF 'while IFS= read -r _park_unit' \
    || fail "must iterate ALL named units — a first-token-only check misses a later live unit"
ok "Test 4: named user units are extracted and each probed with is-active"

# === Test 5: merged non-claim PR signal keys on .state, not the bogus `merged` field ===
printf '%s' "$cell" | grep -qF -- '--json state,headRefName' \
    || fail "gh pr view must request state,headRefName"
printf '%s' "$cell" | grep -qF '.state == "MERGED"' \
    || fail "merged check must key on .state == MERGED"
printf '%s' "$cell" | grep -q 'claim/issue-' \
    || fail "head branch must be compared against claim/issue-\$N"
if printf '%s' "$cell" | grep -qF -- '--json state,merged,'; then
    fail "'merged' is not a valid gh pr view --json field (fleet-ops#1244) — the probe would always fail closed"
fi
ok "Test 5: merged non-claim PR probe uses state==MERGED + headRefName != claim/issue-N"

# === Test 6: park trip flips the label + #5048 comment + skip ===
printf '%s' "$cell" | grep -qF -- '--add-label awaiting-runtime-gate --remove-label agent-ready' \
    || fail "park label flip (add awaiting-runtime-gate, remove agent-ready) not found in the cell"
printf '%s' "$cell" | grep -qF 'fleet-ops#5048' \
    || fail "protected-delivered comment (fleet-ops#5048) not found"
printf '%s' "$cell" | grep -q 'continue' \
    || fail "protected-delivered park branch must skip the claim (continue)"
ok "Test 6: trip flips the label, posts a fleet-ops#5048 comment, and skips"

# === Test 7: unfinished protected issues are not parked ===
# The continue must sit inside the delivery-signal condition
# (runtime unit OR non-claim merged PR), so a protected issue with no
# delivery evidence falls through to a normal claim.
printf '%s' "$cell" | grep -qF 'if [[ -n "$_park_runtime_unit" || $_park_nonclaim_merged -eq 1 ]]' \
    || fail "the park action must be gated on a delivery signal (active unit OR merged non-claim PR)"
sig_line=$(printf '%s' "$cell" | grep -n 'if \[\[ -n "\$_park_runtime_unit"' | head -1 | cut -d: -f1)
cont_line=$(printf '%s' "$cell" | grep -n 'continue' | tail -1 | cut -d: -f1)
[[ -n "$sig_line" && -n "$cont_line" ]] || fail "delivery-signal gate or continue not found in cell"
(( cont_line > sig_line )) \
    || fail "continue must come after the delivery-signal gate inside the cell"
ok "Test 7: no delivery signal means no park — unfinished protected issues still claim"

# === Test 8: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" --severity=warning
    ok "Test 8: shellcheck clean"
else
    echo "SKIP: Test 8: shellcheck not installed"
fi

echo "ALL OK: protected-delivered park detector (fleet-ops#5048)"
