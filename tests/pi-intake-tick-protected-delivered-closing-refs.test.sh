#!/usr/bin/env bash
# tests/pi-intake-tick-protected-delivered-closing-refs.test.sh
#
# fleet-ops#5991: the #5048 delivered-scan treats ANY mentioned merged PR
# as delivery. Live case: #4263 (critical-path, protected) was parked
# because a comment mentioned merged PR #4371 — which CLOSES #4219, not
# #4263. The scan greps every #N out of the body + comments and parks the
# issue on the first MERGED PR whose head is not claim/issue-<N>, so any
# dispatch comment referencing an unrelated merged PR parks a protected
# issue forever (and it would re-park on every rescan).
#
# Fixed contract:
#   1. The delivered-scan probe requests `closingIssuesReferences` in
#      addition to state,headRefName.
#   2. The park only fires when the closing refs include issue N in the
#      full repo — .number == N and repository.full-name == $FULL
#      (case-insensitive).
#   3. Mentions that do NOT close the issue never park it.
#   4. The #5689 contract is unchanged (state==MERGED, headRefName !=
#      claim/issue-N, park still gated on a delivery signal).
#   5. shellcheck clean on the changed file.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# Isolate the #5048 delivered-scan cell (same extraction the sibling tests use).
elif_line=$(grep -n 'elif (( _park_protected == 1 )) && (( _park_merged_count == 0 ))' "$tick" | head -1 | cut -d: -f1)
[[ -n "$elif_line" ]] || fail "#5048 elif not found"
cell=$(sed -n "${elif_line},/^        fi$/p" "$tick")

# === Test 1: probe requests closingIssuesReferences ===
printf '%s' "$cell" | grep -qF -- '--json state,headRefName,closingIssuesReferences' \
    || fail "gh pr view must request closingIssuesReferences in the delivered-scan probe"
ok "Test 1: probe requests closingIssuesReferences"

# === Test 2: park keys on the closing refs including N in $FULL ===
printf '%s' "$cell" | grep -qF '.number == $n' \
    || fail "the closing-refs check must compare .number against issue N"
printf '%s' "$cell" | grep -qF -- '--argjson n "$N"' \
    || fail "the closing-refs check must pass N as --argjson n"
printf '%s' "$cell" | grep -qF -- '--arg full "$FULL"' \
    || fail "the closing-refs check must pass the full repo name as --arg full"
printf '%s' "$cell" | grep -qF -- '== "true"' \
    || fail "the park must fire only when the closing-refs check returns true"
ok "Test 2: park keys on closing refs including N in the full repo"

# === Test 3: mentions that do not close the issue never park ===
if printf '%s' "$cell" | grep -qF '_park_nonclaim_merged=1'; then
    # every assignment of the delivery flag must sit INSIDE the
    # closing-refs gate: find the flag assignment and make sure a
    # closing-refs guard line precedes it within the same ref loop body.
    line_assign=$(printf '%s' "$cell" | grep -n '_park_nonclaim_merged=1' | head -1 | cut -d: -f1)
    [[ -n "$line_assign" ]] || fail "no delivery flag assignment found"
    before=$(printf '%s' "$cell" | sed -n "1,${line_assign}p")
    printf '%s' "$before" | grep -q '_park_closes_it' \
        || fail "the delivery flag must be set only inside the closing-refs gate (mentions never count as delivery)"
fi
ok "Test 3: delivery flag assignment is gated on the closing-refs check"

# === Test 4: #5689 contract unchanged ===
printf '%s' "$cell" | grep -qF '.state == "MERGED"' \
    || fail "merged check must key on .state == MERGED"
printf '%s' "$cell" | grep -q 'claim/issue-' \
    || fail "head branch must be compared against claim/issue-\$N"
printf '%s' "$cell" | grep -qF 'if [[ -n "$_park_runtime_unit" || $_park_nonclaim_merged -eq 1 ]]' \
    || fail "the park action must stay gated on a delivery signal"
ok "Test 4: #5689 delivered-scan contract unchanged"

# === Test 5: the closing-refs jq filter is valid and behaves ===
filter=$(_extract_filter() {
    yq 2>/dev/null || true
} 2>/dev/null)
# Pull the actual jq filter out of the cell and run it against both shapes.
_jq_probe=$(printf '%s' "$cell" | grep -o "any(.closingIssuesReferences.*ascii_downcase))" | head -1)
[[ -n "$_jq_probe" ]] || fail "closing-refs jq filter not found in the cell"
_full="Nishfleet/fleet-ops"
pr_json='{"state":"MERGED","headRefName":"some/branch","closingIssuesReferences":[{"number":4219,"repository":{"owner":{"login":"Nishfleet"},"name":"fleet-ops"}}]}'
out=$(printf '%s' "$pr_json" | jq -e --arg full "$_full" --argjson n 4263 "$_jq_probe" 2>/dev/null || true)
[[ "$out" == "false" ]] || fail "a merged PR closing a DIFFERENT issue (#4219) must NOT count as delivery for #4263 — got '$out'"
pr_json2='{"state":"MERGED","headRefName":"fix/other","closingIssuesReferences":[{"number":4219,"repository":{"owner":{"login":"Nishfleet"},"name":"fleet-ops"}},{"number":4263,"repository":{"owner":{"login":"Nishfleet"},"name":"fleet-ops"}}]}'
out2=$(printf '%s' "$pr_json2" | jq -e --arg full "$_full" --argjson n 4263 "$_jq_probe" 2>/dev/null || true)
[[ "$out2" == "true" ]] || fail "a merged PR whose closingIssuesReferences includes N must count as delivery — got '$out2'"
# Empty closing refs (noopener mention-classified) must not park.
out3=$(printf '%s' '{"state":"MERGED","headRefName":"x","closingIssuesReferences":[]}' | jq -e --arg full "$_full" --argjson n 4263 "$_jq_probe" 2>/dev/null || true)
[[ "$out3" == "false" ]] || fail "empty closingIssuesReferences must never park — got '$out3'"
ok "Test 5: closing-refs jq filter discriminates delivery from mention"

# === Test 6: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" --severity=warning
    ok "Test 6: shellcheck clean"
else
    echo "SKIP: Test 6: shellcheck not installed"
fi

echo "ALL OK: delivered-scan needs closingIssuesReferences (fleet-ops#5991)"
