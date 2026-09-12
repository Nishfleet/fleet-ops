#!/usr/bin/env bash
# tests/pi-intake-tick-protected-term-nonclaim-park.test.sh
#
# fleet-ops#5689: the FIFTH park-detector shape, live-spinning on #4625.
# A protected open issue whose body CARRIES a `termination:` clause but
# has NO merged claim-branch delivery PR used to fall straight through
# the #4540 branch (its inner `if _park_merged_count > 0` failed with no
# park and no continue) and skip the #5048 delivered-scan entirely — the
# elif was gated on a NEGATED `termination:` check. Live case #4625:
# protected (author nish3451), `termination:` naming `deepseek-v4-flash`
# (retired provider-side 2026-09-10, so the named runtime gate can never
# fire), delivery landed via merged NON-claim PR #5081, claim-branch PR
# #4830 closed conflicting — ~15 re-claims since the merge.
#
# This test pins the fixed contract:
#
#   1. The #4540 branch guard REQUIRES `_park_merged_count > 0` — a
#      protected + termination: issue with no merged claim-branch PR can
#      no longer fall through with no park and no continue.
#   2. The #5048 elif no longer carries a negated `termination:` check —
#      it keys on `_park_merged_count == 0` alone, so the delivered-scan
#      runs for protected issues with or without a termination clause.
#   3. The delivered-scan's non-claim-PR signal is unchanged: refs from
#      body+comments probed with `gh pr view --json state,headRefName`,
#      parked when state==MERGED and headRefName != claim/issue-<N>.
#   4. A protected + termination: issue with NO delivery evidence still
#      claims normally (the park sits inside the delivery-signal gate).
#   5. shellcheck clean on the changed file.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: #4540 guard requires merged claim-branch PR ===
guard_line=$(grep -n 'if (( _park_protected == 1 )) && printf' "$tick" | head -1 | cut -d: -f1)
[[ -n "$guard_line" ]] || fail "#4540 branch guard missing"
guard=$(sed -n "${guard_line},$(( guard_line + 1 ))p" "$tick")
printf '%s' "$guard" | grep -qF '(( _park_merged_count > 0 ))' \
    || fail "#4540 branch guard must require _park_merged_count > 0 — otherwise protected + termination: + no merged claim-branch PR falls through with no park and no continue (the #4625 spin)"
ok "Test 1: #4540 branch guard carries the merged-claim-PR condition"

# === Test 2: #5048 elif keys on merged_count == 0, NOT on !termination: ===
elif_line=$(grep -n 'elif (( _park_protected == 1 )) && (( _park_merged_count == 0 ))' "$tick" | head -1 | cut -d: -f1)
[[ -n "$elif_line" ]] \
    || fail "#5048 elif must be gated on _park_merged_count == 0"
cell=$(sed -n "${elif_line},/^        fi$/p" "$tick")
if printf '%s' "$cell" | grep -q '! printf .%s. "$body" | grep -qi .termination:.'; then
    fail "#5048 elif must NOT carry a negated termination: check (#5689) — a termination: naming an unrunnable gate is exactly the delivered-spin shape"
fi
ok "Test 2: #5048 delivered-scan runs with or without a termination: clause"

# === Test 3: delivered-scan signal unchanged (non-claim merged PR) ===
printf '%s' "$cell" | grep -qF -- '--json state,headRefName' \
    || fail "gh pr view must request state,headRefName"
printf '%s' "$cell" | grep -qF '.state == "MERGED"' \
    || fail "merged check must key on .state == MERGED"
printf '%s' "$cell" | grep -q 'claim/issue-' \
    || fail "head branch must be compared against claim/issue-\$N"
ok "Test 3: non-claim merged-PR probe unchanged (state==MERGED, headRefName != claim/issue-N)"

# === Test 4: no delivery evidence means no park — the issue still claims ===
printf '%s' "$cell" | grep -qF 'if [[ -n "$_park_runtime_unit" || $_park_nonclaim_merged -eq 1 ]]' \
    || fail "the park action must stay gated on a delivery signal"
sig_line=$(printf '%s' "$cell" | grep -n 'if \[\[ -n "\$_park_runtime_unit"' | head -1 | cut -d: -f1)
cont_line=$(printf '%s' "$cell" | grep -n 'continue' | tail -1 | cut -d: -f1)
[[ -n "$sig_line" && -n "$cont_line" ]] || fail "delivery-signal gate or continue not found in cell"
(( cont_line > sig_line )) \
    || fail "continue must come after the delivery-signal gate inside the cell"
ok "Test 4: protected + termination: with no delivery evidence still claims normally"

# === Test 5: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" --severity=warning
    ok "Test 5: shellcheck clean"
else
    echo "SKIP: Test 5: shellcheck not installed"
fi

echo "ALL OK: protected + termination: + non-claim delivery park (fleet-ops#5689)"
