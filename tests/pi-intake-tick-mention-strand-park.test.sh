#!/usr/bin/env bash
# tests/pi-intake-tick-mention-strand-park.test.sh
#
# fleet-ops#5045: the mention-strand slow-spaced reclaim spin — the middle
# shape both earlier parks missed. A NON-protected (bot-authored, no
# critical-path) OPEN issue whose merged claim-branch PRs are ALL
# mention-classified (`Relates to #N` trailer, the same classification
# bin/fleet-merged-pr-close applies — fleet-ops#3231/#1138) is
# delivered-but-stranded: observe-to-close posts comment-only and never
# closes (a mention is not a fix), the #4540 park needs a protected issue,
# and the #4553 park needs NO merged claim-branch PR. Live case: #4980 was
# delivered by merged PR #4993 (claim/issue-4980 branch) carrying
# `Relates to #4980`; the issue re-claimed 4x in ~3h, two runs dying in
# StartLimitBurst crash loops. This test pins the third park contract:
#
#   1. The `skipped-parked-mention-strand` marker exists.
#   2. The non-protected park is a single `elif (( _park_protected == 0 ))`
#      holding BOTH non-protected shapes over one merged-PR probe.
#   3. The mention classifier uses the same `Relat(es|ed) to #N` regex as
#      bin/fleet-merged-pr-close's relates_to_issue.
#   4. Drill (stub gh, verbatim-mirrored logic):
#      - non-protected + claims>cap + all-mention merged claim PRs -> parked
#      - merged claim PR with a real delivery (no Relates-to) -> NOT parked
#      - mixed mention + delivery -> NOT parked
#      - no merged PR + termination:+gh pr view -> land-or-close still parks
#      - no merged PR + no termination -> NOT parked
#   5. On trip: awaiting-runtime-gate label added, agent-ready removed, a
#      fleet-ops#5045 comment posted, issue skipped via continue.
#   6. shellcheck clean on the changed file.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
close_bin="$repo_root/bin/fleet-merged-pr-close"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
[[ -f "$close_bin" ]] || fail "bin/fleet-merged-pr-close missing"

# === Test 1: skipped-parked-mention-strand marker present ===
grep -qF 'skipped-parked-mention-strand' "$tick" \
    || fail "skipped-parked-mention-strand marker not found"
ok "Test 1: skipped-parked-mention-strand marker present"

# === Test 2: one non-protected elif holds both non-protected shapes ===
# Exactly one `elif (( _park_protected == 0 ))` — the #4553 land-or-close and
# the #5045 mention-strand sub-branch inside it over a shared probe, so a
# land-or-close-shaped body WITH a merged mention PR cannot fall through.
elif_count=$(grep -cF 'elif (( _park_protected == 0 ))' "$tick")
(( elif_count == 1 )) \
    || fail "expected exactly one non-protected park elif, got $elif_count"
grep -qF 'if (( _park_protected == 1 )) &&' "$tick" \
    || fail "the #4540 protected-merged if branch must still be present (unchanged)"
# The merged-PR probe inside the non-protected elif must fetch the body
# (the Relates-to classification needs the trailer).
grep -qF -- '--head "claim/issue-$N" --state merged --json number,url,mergedAt,body' "$tick" \
    || fail "non-protected merged claim-branch probe must request the PR body (mention classification needs the trailer)"
ok "Test 2: single non-protected elif; probe carries the PR body"

# === Test 3: mention regex matches fleet-merged-pr-close relates_to_issue ===
relates_tick=$(grep -oF 'Relat(es|ed)[[:space:]]+to[[:space:]]+#${N}' "$tick" | head -1)
relates_close=$(grep -oF 'Relat(es|ed)[[:space:]]+to[[:space:]]+#${n}' "$close_bin" | head -1)
[[ -n "$relates_tick" ]] || fail "Relates-to classifier regex not found in tick"
[[ -n "$relates_close" ]] || fail "relates_to_issue regex not found in bin/fleet-merged-pr-close"
ok "Test 3: tick reuses the relates_to_issue Relates-to classification"

# === Test 4: drill — the park decision over a stubbed gh ===
# The tick is a top-level script (cannot be sourced), so the drill below
# mirrors the lib/pi-intake-tick.sh park block verbatim in logic, with a
# stubbed gh so merged-PR shape and park side effects are deterministic
# and offline.
scratch="$(mktemp -d -t pirt-mention-strand.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# PR_BODIES: newline-separated bodies for the merged claim-branch PR list.
# PR_COUNT: how many merged PRs the stub reports.
declare -a PR_BODIES=()
PARK_ACTIONS="$scratch/actions.log"

gh() {
    local cmd="$1"; shift
    case "$cmd" in
        pr)
            # pr list -R <full> --head claim/issue-<n> --state merged --json ...
            if [[ "${1:-}" == "list" ]]; then
                local out='[' i
                for i in "${!PR_BODIES[@]}"; do
                    (( i > 0 )) && out+=','
                    out+=$(jq -nc --arg b "${PR_BODIES[$i]}" --arg n "$((i+1))" \
                        '{number:($n|tonumber), url:("https://x/" + $n), mergedAt:"2026-09-10T15:00:00Z", body:$b}')
                done
                out+=']'
                printf '%s\n' "$out"
                return 0
            fi
            return 0
            ;;
        label|issue)
            printf '%s\n' "$cmd $*" >>"$PARK_ACTIONS"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
export -f gh

# park_block N BODY CLAIMS PROTECTED — verbatim mirror of the tick's
# `if (( _park_claims > PARK_MAX_CLAIMS ))` block. Prints the skip echo on
# stdout (the tick uses >&2; the drill keeps stdout for assertion) and
# records gh write calls in PARK_ACTIONS. Returns 0 when the issue was
# parked/skipped, 1 when the claim proceeds.
park_block() {
    local N="$1" body="$2" _park_claims="$3" _park_protected="$4"
    local FULL="Nishfleet/fleet-ops" title="drill"
    local PARK_MAX_CLAIMS=3
    if (( _park_claims > PARK_MAX_CLAIMS )); then
        if (( _park_protected == 1 )) && printf '%s' "$body" | grep -qi 'termination:'; then
            local _park_merged
            _park_merged=$(gh pr list -R "$FULL" --head "claim/issue-$N" --state merged --json number,url,mergedAt 2>/dev/null || echo "[]")
            if printf '%s' "$_park_merged" | jq -e 'length > 0' >/dev/null 2>&1; then
                echo "skipped-parked-protected-merged"
                gh label create awaiting-runtime-gate -R "$FULL" --force >/dev/null 2>&1 || true
                gh issue edit "$N" -R "$FULL" --add-label awaiting-runtime-gate --remove-label agent-ready 2>/dev/null || true
                return 0
            fi
        elif (( _park_protected == 0 )); then
            local _park_merged
            _park_merged=$(gh pr list -R "$FULL" --head "claim/issue-$N" --state merged --json number,url,mergedAt,body 2>/dev/null || echo "[]")
            if ! printf '%s' "$_park_merged" | jq -e 'length > 0' >/dev/null 2>&1 \
                && printf '%s' "$body" | grep -qi 'termination:' \
                && printf '%s' "$body" | grep -qi 'gh pr view'; then
                echo "skipped-parked-land-or-close"
                gh label create awaiting-runtime-gate -R "$FULL" --force >/dev/null 2>&1 || true
                gh issue edit "$N" -R "$FULL" --add-label awaiting-runtime-gate --remove-label agent-ready 2>/dev/null || true
                return 0
            elif printf '%s' "$_park_merged" | jq -e 'length > 0' >/dev/null 2>&1; then
                local _park_all_mention=1 _park_pr="" _pn _pb64 _pb
                while IFS=$'\t' read -r _pn _pb64; do
                    [ -z "$_pn" ] && continue
                    [ -z "$_park_pr" ] && _park_pr="$_pn"
                    _pb=$(printf '%s' "$_pb64" | base64 -d 2>/dev/null || printf '')
                    if ! printf '%s' "$_pb" | grep -Eiq "(^|[^0-9A-Za-z])Relat(es|ed)[[:space:]]+to[[:space:]]+#${N}([^0-9A-Za-z]|$)"; then
                        _park_all_mention=0
                        break
                    fi
                done < <(printf '%s' "$_park_merged" | jq -r '.[] | [.number, ((.body // "") | @base64)] | @tsv' 2>/dev/null)
                if (( _park_all_mention == 1 )); then
                    echo "skipped-parked-mention-strand"
                    gh label create awaiting-runtime-gate -R "$FULL" --force >/dev/null 2>&1 || true
                    gh issue edit "$N" -R "$FULL" --add-label awaiting-runtime-gate --remove-label agent-ready 2>/dev/null || true
                    return 0
                fi
            fi
        fi
    fi
    return 1
}

# --- 4a: THE MIDDLE SHAPE — non-protected, claims>cap, merged claim-branch
#         PR carrying `Relates to #N` -> parked, label flipped ---
: > "$PARK_ACTIONS"
PR_BODIES=($'worker delivery PR body\n\nRelates to #4980\n')
set +e
out=$(park_block 4980 "ordinary delivery issue, no termination clause" 5 0)
rc=$?
set -e
[[ "$rc" == "0" && "$out" == "skipped-parked-mention-strand" ]] \
    || fail "4a: all-mention merged claim PR must park (mention-strand), got rc=$rc out=$out"
grep -q 'issue edit 4980 .*--add-label awaiting-runtime-gate --remove-label agent-ready' "$PARK_ACTIONS" \
    || fail "4a: park must flip the label (add awaiting-runtime-gate, remove agent-ready)"
ok "Test 4a: non-protected + claims>cap + Relates-to merged claim PR -> parked, label flipped"

# --- 4b: a REAL delivery PR (no Relates-to trailer) -> NOT parked by this
#         branch (observe-to-close owns the close) ---
: > "$PARK_ACTIONS"
PR_BODIES=($'worker delivery PR body\n\nCloses #4981\n')
set +e
out=$(park_block 4981 "ordinary delivery issue" 5 0)
rc=$?
set -e
[[ "$rc" == "1" ]] \
    || fail "4b: a delivery-classified merged claim PR must NOT park (observe-to-close owns it), got rc=$rc out=$out"
ok "Test 4b: merged claim PR without Relates-to (real delivery) -> not parked here"

# --- 4c: mixed — one Relates-to + one real delivery -> NOT parked ---
: > "$PARK_ACTIONS"
PR_BODIES=($'partial PR\n\nRelates to #4982\n' $'delivery PR\n\nCloses #4982\n')
set +e
out=$(park_block 4982 "ordinary issue" 5 0)
rc=$?
set -e
[[ "$rc" == "1" ]] \
    || fail "4c: mixed mention + delivery merged PRs must NOT park, got rc=$rc out=$out"
ok "Test 4c: mixed mention + delivery merged claim PRs -> not parked"

# --- 4d: land-or-close still parks inside the restructured elif ---
: > "$PARK_ACTIONS"
PR_BODIES=()
set +e
out=$(park_block 4417 $'drive other PRs\n\ntermination: gh pr view 1234 merged\n' 5 0)
rc=$?
set -e
[[ "$rc" == "0" && "$out" == "skipped-parked-land-or-close" ]] \
    || fail "4d: land-or-close shape must still park after the restructure, got rc=$rc out=$out"
ok "Test 4d: no merged PR + termination:+gh pr view -> land-or-close park (unchanged)"

# --- 4e: land-or-close-shaped body WITH a merged mention PR -> mention-strand
#         park (the shape the old elif order dropped on the floor) ---
: > "$PARK_ACTIONS"
PR_BODIES=($'adjudication PR on reused branch\n\nRelates to #4417\n')
set +e
out=$(park_block 4417 $'drive other PRs\n\ntermination: gh pr view 1234 merged\n' 5 0)
rc=$?
set -e
[[ "$rc" == "0" && "$out" == "skipped-parked-mention-strand" ]] \
    || fail "4e: termination body + all-mention merged claim PR must park as mention-strand, got rc=$rc out=$out"
ok "Test 4e: termination: body + all-mention merged claim PR -> mention-strand park"

# --- 4f: no merged PR + no termination -> NOT parked ---
: > "$PARK_ACTIONS"
PR_BODIES=()
set +e
out=$(park_block 5000 "plain issue body" 5 0)
rc=$?
set -e
[[ "$rc" == "1" ]] \
    || fail "4f: non-protected with no merged PR and no termination: must NOT park, got rc=$rc out=$out"
ok "Test 4f: no merged PR + no termination: -> not parked"

# --- 4g: claims under cap -> nothing parks ---
: > "$PARK_ACTIONS"
PR_BODIES=($'x\n\nRelates to #5001\n')
set +e
out=$(park_block 5001 "plain issue body" 3 0)
rc=$?
set -e
[[ "$rc" == "1" ]] \
    || fail "4g: claims <= PARK_MAX_CLAIMS must not park, got rc=$rc out=$out"
ok "Test 4g: claims under the cap -> not parked"

# === Test 5: on trip the real tick flips the label + posts the #5045 comment ===
grep -qF 'fleet-ops#5045' "$tick" \
    || fail "mention-strand park comment (fleet-ops#5045) not found"
park_line=$(grep -n 'skipped-parked-mention-strand' "$tick" | head -1 | cut -d: -f1)
[[ -n "$park_line" ]] || fail "mention-strand skip line not found"
# the label flip must follow the skip echo inside the same block
tail_block=$(tail -n +"$park_line" "$tick" | head -20)
printf '%s' "$tail_block" | grep -qF -- '--add-label awaiting-runtime-gate --remove-label agent-ready' \
    || fail "mention-strand park must flip the label right after the skip echo"
printf '%s' "$tail_block" | grep -q 'continue' \
    || fail "mention-strand park must skip the claim (continue)"
ok "Test 5: mention-strand trip flips the label, posts fleet-ops#5045 comment, and skips"

# === Test 6: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" --severity=warning
    ok "Test 6: shellcheck clean"
else
    echo "SKIP: Test 6: shellcheck not installed"
fi

echo "ALL OK: mention-strand park detector (fleet-ops#5045)"
