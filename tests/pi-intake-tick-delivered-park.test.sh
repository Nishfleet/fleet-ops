#!/usr/bin/env bash
# tests/pi-intake-tick-delivered-park.test.sh
#
# fleet-ops#5048 (+ the #5045 middle cell): the delivered-or-delegated
# park. The #4540 park needs protected + `termination:` + a merged
# claim-branch PR; the #4553 land-or-close park needs NON-protected. Two
# cells were left uncovered and re-claimed forever on a slow spin every
# anti-loop gate misses:
#
#   * #5048 cell — PROTECTED open issue past PARK_MAX_CLAIMS with NO
#     merged claim-branch PR and NO `termination:` clause, whose work was
#     delivered on other branches (live: fable/* PRs #4893/#4897 on #4891)
#     or delegated to a named runtime event (remeasure-4891-timer). #4891
#     was re-claimed 12x in one day before a hand-applied label parked it.
#   * #5045 cell — NON-protected open issue past PARK_MAX_CLAIMS whose
#     merged claim-branch PR was mention-classified (`Relates to` never
#     closes; live #4980 via PR #4993). A still-open issue with a merged
#     claim PR is delivered-but-stranded by definition.
#
# This test pins the third park branch's contract:
#
#   1. The `skipped-parked-delivered` marker exists.
#   2. The branch is ADDITIVE — the #4540 protected-merged `if` and the
#      #4553 land-or-close `elif` are untouched, and the new block sits
#      inside the same PARK_MAX_CLAIMS gate (before the shared comments
#      fetch).
#   3. A merged claim/issue-<N> PR is delivery evidence at EITHER
#      protection level — the evidence assignment precedes the protected
#      elif (the #5045 cell is non-protected).
#   4. Weaker evidence is PROTECTED-gated (`elif _park_protected == 1`):
#      off-claim merged PRs referencing `#N` (coarse search + exact
#      `#<N>\b` filter), a delegation marker (`awaiting: <name>` /
#      `blocked-on: timer <name>`), or a named runtime unit still ACTIVE
#      under systemctl --user.
#   5. No evidence -> no park: the label flip/comment/skip only run under
#      a non-empty _park_evidence.
#   6. On trip: awaiting-runtime-gate added, agent-ready removed, a
#      fleet-ops#5048 comment posted, and the issue skipped via continue.
#   7. The park label is provisioned (create --force) before it is added
#      in the new block too.
#   8. shellcheck clean on the changed file.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: skipped-parked-delivered marker present ===
grep -qF 'skipped-parked-delivered' "$tick" \
    || fail "skipped-parked-delivered marker not found"
ok "Test 1: skipped-parked-delivered marker present"

# === Test 2: additive — #4540/#4553 branches intact, new block in the over-cap gate ===
grep -qF 'if (( _park_protected == 1 )) &&' "$tick" \
    || fail "the #4540 protected-merged if branch must still be present (unchanged)"
grep -qF 'elif (( _park_protected == 0 ))' "$tick" \
    || fail "the #4553 land-or-close elif branch must still be present (unchanged)"
land_line=$(grep -n 'elif (( _park_protected == 0 ))' "$tick" | head -1 | cut -d: -f1)
new_line=$(grep -n 'delivered-or-delegated' "$tick" | head -1 | cut -d: -f1)
comments_line=$(grep -nF '_cjson=$(gh issue view "$N" -R "$FULL" --json comments 2>/dev/null) || {' "$tick" | head -1 | cut -d: -f1)
[[ -n "$land_line" && -n "$new_line" && -n "$comments_line" ]] \
    || fail "land-or-close elif, new block, or comments-fetch line not found"
(( new_line > land_line )) \
    || fail "the delivered-or-delegated block (line $new_line) must follow the land-or-close elif (line $land_line)"
(( new_line < comments_line )) \
    || fail "the delivered-or-delegated block (line $new_line) must sit inside the over-cap gate, before the shared comments fetch (line $comments_line)"
ok "Test 2: new park branch is additive and inside the PARK_MAX_CLAIMS gate"

# === Test 3: merged claim-branch PR is evidence at EITHER protection level ===
# The merged claim/issue-<N> probe and its evidence assignment must precede
# the protected elif so the #5045 (non-protected) cell is covered.
probe_count=$(grep -cF -- '--head "claim/issue-$N" --state merged' "$tick")
(( probe_count >= 3 )) || fail "merged claim-branch probe count $probe_count < 3 (4540 + 4553 + new block)"
evidence_line=$(grep -n '_park_evidence="merged claim/issue-$N PR' "$tick" | head -1 | cut -d: -f1)
protected_elif=$(grep -n 'elif (( _park_protected == 1 ))' "$tick" | head -1 | cut -d: -f1)
[[ -n "$evidence_line" && -n "$protected_elif" ]] \
    || fail "merged-claim evidence line or protected elif not found"
(( evidence_line < protected_elif )) \
    || fail "merged claim-PR evidence (line $evidence_line) must precede the protected elif (line $protected_elif) — the #5045 cell is non-protected"
ok "Test 3: merged claim/issue-<N> PR parks at either protection level (#5045 cell covered)"

# === Test 4: weaker evidence is protected-gated and wired ===
refs_line=$(grep -n -- '--state merged --search "#$N in:body"' "$tick" | head -1 | cut -d: -f1)
[[ -n "$refs_line" ]] || fail "off-claim merged-PR reference search not found"
(( refs_line > protected_elif )) \
    || fail "off-claim reference search (line $refs_line) must sit under the protected elif (line $protected_elif) — a bare mention never parks a claimable non-protected issue (#3231)"
grep -qF 'test("#" + $n + "\\b")' "$tick" \
    || fail "exact #<N> word-boundary filter missing — the search pre-filter must not substring-match other issue numbers"
grep -qE "awaiting:\[\[:space:\]\]\*" "$tick" \
    || fail "awaiting: <name> delegation marker check not found"
grep -qF 'blocked-on:[[:space:]]*timer[[:space:]]' "$tick" \
    || fail "blocked-on: timer <name> delegation marker check not found"
grep -qF '"$SYSTEMCTL" --user is-active --quiet "$_park_unit"' "$tick" \
    || fail "live-unit liveness check (systemctl --user is-active) not found"
grep -qE "\\\\\.\(timer\|service\)|\(timer\|service\)" "$tick" \
    || fail "runtime unit token extraction (*.timer / *.service) not found"
ok "Test 4: protected-gated evidence — off-claim merged refs, delegation markers, live runtime units"

# === Test 5: no evidence -> no park ===
grep -qF 'if [[ -n "$_park_evidence" ]]; then' "$tick" \
    || fail "park must be gated on a non-empty _park_evidence (no evidence -> no park)"
ok "Test 5: park fires only on a non-empty evidence string"

# === Test 6: on trip, label flip + fleet-ops#5048 comment + skip ===
grep -qF -- '--add-label awaiting-runtime-gate --remove-label agent-ready' "$tick" \
    || fail "park label flip not found"
grep -qF 'fleet-ops#5048' "$tick" \
    || fail "delivered-or-delegated comment (fleet-ops#5048) not found"
block_continue=$(sed -n '/_park_evidence=""/,/skipped-parked-delivered/p' "$tick" | grep -c 'continue' || true)
# the park block itself must also end in continue (count it after the marker)
after_continue=$(sed -n '/skipped-parked-delivered/,$p' "$tick" | grep -m2 -c 'continue' || true)
(( block_continue >= 1 || after_continue >= 1 )) \
    || fail "delivered-or-delegated park must skip the claim (continue)"
ok "Test 6: park trip flips the label, posts a fleet-ops#5048 comment, and skips"

# === Test 7: park label provisioned (create --force) before add — all blocks ===
create_lines=$(grep -n 'label create awaiting-runtime-gate' "$tick" | cut -d: -f1)
add_lines=$(grep -n -- '--add-label awaiting-runtime-gate' "$tick" | cut -d: -f1)
c_count=$(printf '%s\n' "$create_lines" | grep -c .)
a_count=$(printf '%s\n' "$add_lines" | grep -c .)
(( c_count == a_count )) || fail "label create count ($c_count) != add count ($a_count) — every park path must provision the label first"
paste -d' ' <(printf '%s\n' "$create_lines") <(printf '%s\n' "$add_lines") | while read -r c a; do
    (( c < a )) || fail "label create (line $c) must precede --add-label (line $a)"
done
ok "Test 7: awaiting-runtime-gate label provisioned before add in every park path"

# === Test 8: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" --severity=warning
    ok "Test 8: shellcheck clean"
else
    echo "SKIP: Test 8: shellcheck not installed"
fi

echo "ALL OK: delivered-or-delegated park detector (fleet-ops#5048)"
