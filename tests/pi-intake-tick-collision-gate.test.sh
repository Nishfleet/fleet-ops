#!/usr/bin/env bash
# tests/pi-intake-tick-collision-gate.test.sh
#
# fleet-ops#5165: intake must honor a `collision-gate:` line in an issue
# body — never claim a ticket whose named same-file blockers are still
# open. 0509#2408 was gated on #2350 + #2356 (the gate file maps
# "2408": [2350, 2356]); #2350 was closed, #2356 open, yet intake claimed
# #2408 anyway because its body said `depends-on: none` and nothing parsed
# the collision-gate line. The worker had to stop and post
# `blocked-on: orchestrator` — one wasted slot, and on a worse ticket a
# same-file PR racing the open blocker.
#
# Proves, offline:
#   1. lib/pi-intake-tick.sh parses the collision-gate line and prints
#      `skipped-collision-gate:#n` when a named blocker is not DONE.
#   2. Parse cases: none / one / many / cross-repo / the real annotated
#      "collision-gate (Fable <ts>): shares <file> with #a, #b" format.
#   3. DONE via closed issue and via merged claim/issue-<n> PR.
#   4. not DONE -> `skipped-collision-gate:#n`; two open -> first named.
#   5. The org-less `repo#n` trailer ("permanent fix fleet-ops#4808") is
#      NOT a ref — it must not resolve in the wrong repo and wedge the gate.
#   6. A body carrying BOTH `depends-on:` and `collision-gate:` where only
#      one is unmet reports the right reason.
#   7. Gate line absent -> unchanged behaviour (no refs, claimable).
#   8. Caching: one gh call per referenced ticket per tick (memoised).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: collision-gate wiring present in the tick ===
grep -qF 'collision-gate' "$tick" \
    || fail "collision-gate gate not present in tick"
grep -qF 'skipped-collision-gate:' "$tick" \
    || fail "tick must print skipped-collision-gate: when the gate fires"
ok "Test 1: collision-gate parse + skip reason present in tick"

# === Tests 2-10: bash drill reproducing the exact filter logic ===
# The tick is a top-level script (cannot be sourced), so the drill below
# mirrors lib/pi-intake-tick.sh verbatim in logic, with a stubbed gh so the
# DONE resolution is deterministic and offline.

scratch="$(mktemp -d -t pirt-collision-gate.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub gh: a table of issue states and PR heads the drill consults.
#   ISSUE_STATE[owner/repo#n] = open|closed
#   PR_MERGED[owner/repo#n]   = 1 when a claim/issue-<n> or fable/issue-<n>
#                               PR is merged
#   DEP_BODY[owner/repo#n]    = the dependency issue's body (cycle check)
declare -A ISSUE_STATE=()
declare -A PR_MERGED=()
declare -A DEP_BODY=()
GH_CALL_LOG="$scratch/gh-calls.log"
: > "$GH_CALL_LOG"

gh() {
    if [[ -n "${GH_CALL_LOG:-}" ]]; then
        printf '%s\n' "$*" >>"$GH_CALL_LOG"
    fi
    local cmd="$1"; shift
    case "$cmd" in
        api)
            # repos/<owner>/<repo>/issues/<n>  -> state
            local path="$1"
            if [[ "$path" =~ ^repos/([^/]+)/([^/]+)/issues/([0-9]+)$ ]]; then
                local key="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}#${BASH_REMATCH[3]}"
                printf '{"state":"%s"}\n' "${ISSUE_STATE[$key]:-open}"
                return 0
            fi
            if [[ "$path" =~ ^repos/([^/]+)/([^/]+)/issues/([0-9]+)/timeline$ ]]; then
                # no cross-referenced merged PRs in the drill
                printf '[]\n'
                return 0
            fi
            echo "stub gh api: $path" >&2
            return 0
            ;;
        issue)
            # issue view <n> -R <owner>/<repo> --json body --jq ...
            if [[ "$1" == "view" ]]; then
                local n="$2"; shift 2
                local repo=""
                while [[ $# -gt 0 ]]; do
                    if [[ "$1" == "-R" ]]; then repo="$2"; shift 2; continue; fi
                    shift
                done
                printf '%s\n' "${DEP_BODY[${repo}#${n}]:-}"
                return 0
            fi
            echo "stub gh issue: $*" >&2
            return 0
            ;;
        pr)
            # pr list -R owner/repo --head claim/issue-<n> --state merged --json number
            if [[ "$1" == "list" ]]; then
                local repo="" head=""
                while [[ $# -gt 0 ]]; do
                    if [[ "$1" == "-R" ]]; then repo="$2"; shift 2; continue; fi
                    if [[ "$1" == "--head" ]]; then head="$2"; shift 2; continue; fi
                    shift
                done
                local n=""
                if [[ "$head" =~ ^(claim|fable)/issue-([0-9]+)$ ]]; then
                    n="${BASH_REMATCH[2]}"
                fi
                if [[ -n "$n" && "${PR_MERGED[${repo}#${n}]:-0}" == "1" ]]; then
                    printf '[{"number":1}]\n'
                else
                    printf '[]\n'
                fi
                return 0
            fi
            echo "stub gh pr: $*" >&2
            return 0
            ;;
        *)
            echo "stub gh: $*" >&2
            return 0
            ;;
    esac
}
export -f gh

# The drill's depends_on_filter + resolve_dep, mirroring the tick verbatim.
declare -A _dep_state_cache=()
declare -A _dep_body_cache=()

resolve_dep() {
    local owner="$1" rname="$2" num="$3"
    local state_json state
    state_json=$(gh api "repos/${owner}/${rname}/issues/${num}" 2>/dev/null) || { echo "NOT_DONE"; return; }
    state=$(printf '%s' "$state_json" | jq -r '.state // "open"' 2>/dev/null || echo open)
    if [[ "$state" == "closed" ]]; then
        echo "DONE"; return
    fi
    if gh pr list -R "${owner}/${rname}" --head "claim/issue-${num}" --state merged --json number 2>/dev/null \
        | jq -e 'length > 0' >/dev/null 2>&1; then
        echo "DONE"; return
    fi
    if gh pr list -R "${owner}/${rname}" --head "fable/issue-${num}" --state merged --json number 2>/dev/null \
        | jq -e 'length > 0' >/dev/null 2>&1; then
        echo "DONE"; return
    fi
    if gh api "repos/${owner}/${rname}/issues/${num}/timeline" 2>/dev/null \
        | jq -e '[.[]? | select(.event == "cross-referenced") | .source.issue | select(.pull_request != null and .pull_request.merged_at != null)] | length > 0' >/dev/null 2>&1; then
        echo "DONE"; return
    fi
    echo "NOT_DONE"
}

# The REAL _depends_on_refs parser, extracted verbatim from the tick —
# hand-mirroring a parser is how drift happens (fleet-ops#5107).
_dor_def="$(sed -n "/^_depends_on_refs()/,/^}/p" "$tick")"
[[ -n "$_dor_def" ]] || fail "_depends_on_refs() not found in tick lib"
eval "$_dor_def"

depends_on_filter() {
    local body="$1" repo="$2" num="$3"
    local ref owner rname target_num dep_key dep_state dep_body
    local gate_re skip_reason gi
    local -a deps=()

    local -a _gate_res=(
        '^depends-on:'
        '^collision-gate([[:space:]]*\([^)]*\))?[[:space:]]*:'
    )
    local -a _gate_reasons=('skipped-depends-on' 'skipped-collision-gate')

    for gi in 0 1; do
        gate_re="${_gate_res[$gi]}"
        skip_reason="${_gate_reasons[$gi]}"

        if [[ "$skip_reason" == "skipped-depends-on" ]]; then
            mapfile -t deps < <(printf '%s\n' "$body" | _depends_on_refs)
        else
            mapfile -t deps < <(printf '%s\n' "$body" \
                | grep -E "$gate_re" \
                | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|[A-Za-z0-9_.-]+#[0-9]+|#[0-9]+' || true)
        fi
        (( ${#deps[@]} == 0 )) && continue

        for ref in "${deps[@]}"; do
            if [[ "$ref" =~ ^#([0-9]+)$ ]]; then
                owner="${repo%%/*}"; rname="${repo#*/}"; target_num="${BASH_REMATCH[1]}"
            elif [[ "$ref" =~ ^([^/]+)/([^/]+)#([0-9]+)$ ]]; then
                owner="${BASH_REMATCH[1]}"; rname="${BASH_REMATCH[2]}"; target_num="${BASH_REMATCH[3]}"
            else
                continue
            fi
            dep_key="${owner}/${rname}#${target_num}"

            if [[ -n "${_dep_state_cache[$dep_key]:-}" ]]; then
                dep_state="${_dep_state_cache[$dep_key]}"
            else
                dep_state="$(resolve_dep "$owner" "$rname" "$target_num")"
                _dep_state_cache[$dep_key]="$dep_state"
            fi
            if [[ "$dep_state" != "DONE" ]]; then
                if [[ "$skip_reason" == "skipped-depends-on" ]]; then
                    if [[ -n "${_dep_body_cache[$dep_key]:-}" ]]; then
                        dep_body="${_dep_body_cache[$dep_key]}"
                    else
                        dep_body="$(gh issue view "$target_num" -R "${owner}/${rname}" --json body --jq '.body // ""' 2>/dev/null || true)"
                        _dep_body_cache[$dep_key]="$dep_body"
                    fi
                    if printf '%s\n' "$dep_body" | _depends_on_refs \
                        | grep -qE "#${num}\b|${repo}#${num}\b"; then
                        echo "depends-on-cycle"
                        return 1
                    fi
                fi
                echo "${skip_reason}:${ref}"
                return 1
            fi
        done
    done
    return 0
}

# --- Test 2: parse cases ---
# gate line present but no refs -> claimable
out="$(depends_on_filter $'title\n\ncollision-gate: none\n' Nishfleet/fleet-ops 100)"; rc=$?
[[ "$rc" == "0" ]] || fail "Test 2a: 'collision-gate: none' must be claimable, got rc=$rc out=$out"
ok "Test 2a: 'collision-gate: none' is claimable (no refs parsed)"

# one same-repo blocker, DONE via closed -> claimable
ISSUE_STATE[Nishfleet/fleet-ops#2350]=closed
out="$(depends_on_filter $'title\n\ncollision-gate: #2350\n' Nishfleet/fleet-ops 100)"; rc=$?
[[ "$rc" == "0" ]] || fail "Test 2b: one closed blocker must be claimable, got rc=$rc out=$out"
ok "Test 2b: one same-repo blocker closed -> claimable"

# many blockers, all DONE -> claimable
ISSUE_STATE[Nishfleet/fleet-ops#2356]=closed
out="$(depends_on_filter $'title\n\ncollision-gate: #2350, #2356\n' Nishfleet/fleet-ops 100)"; rc=$?
[[ "$rc" == "0" ]] || fail "Test 2c: many closed blockers must be claimable, got rc=$rc out=$out"
ok "Test 2c: many blockers all closed -> claimable"

# cross-repo blocker, DONE via closed -> claimable
ISSUE_STATE[Nishfleet/0509#2350]=closed
out="$(depends_on_filter $'title\n\ncollision-gate: Nishfleet/0509#2350\n' Nishfleet/fleet-ops 100)"; rc=$?
[[ "$rc" == "0" ]] || fail "Test 2d: cross-repo closed blocker must be claimable, got rc=$rc out=$out"
ok "Test 2d: cross-repo blocker closed -> claimable"

# --- Test 3: the real 0509 annotated format ---
# "collision-gate (Fable <ts>): shares <file> with #a, #b ... (gate file:
# ...; permanent fix fleet-ops#4808)." — the parenthetical annotation and
# the org-less `fleet-ops#4808` trailer must not parse as refs.
_dep_state_cache=()
: > "$GH_CALL_LOG"
ISSUE_STATE[Nishfleet/0509#2350]=closed
ISSUE_STATE[Nishfleet/0509#2356]=open
set +e
out="$(depends_on_filter $'title\n\ncollision-gate (Fable 2026-09-10 09:40 IST): shares app/lib/better-auth.server.ts with #2350, #2356. agent-ready returns automatically when those are merged/closed (gate file: agent-state/fleet-landing-watch/ticket-gates.json; permanent fix fleet-ops#4808).\n' Nishfleet/0509 2408)"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "Test 3a: open blocker must skip, got rc=$rc out=$out"
[[ "$out" == "skipped-collision-gate:#2356" ]] || fail "Test 3a: reason must be skipped-collision-gate:#2356, got: $out"
# fleet-ops#4808 must never be looked up: no gh call may touch it.
if grep -qE 'fleet-ops/issues/4808|issues/4808' "$GH_CALL_LOG"; then
    fail "Test 3b: org-less fleet-ops#4808 trailer was resolved as a ref: $(cat "$GH_CALL_LOG")"
fi
ok "Test 3: real annotated format -> skipped-collision-gate:#2356; fleet-ops#4808 trailer ignored"

# --- Test 4: DONE via merged PR (claim/issue-<n> branch) ---
_dep_state_cache=()
ISSUE_STATE[Nishfleet/fleet-ops#2218]=open
PR_MERGED[Nishfleet/fleet-ops#2218]=1
out="$(depends_on_filter $'title\n\ncollision-gate: #2218\n' Nishfleet/fleet-ops 100)"; rc=$?
[[ "$rc" == "0" ]] || fail "Test 4: blocker with merged claim/issue PR must be claimable, got rc=$rc out=$out"
ok "Test 4: DONE via merged claim/issue-<n> PR -> claimable"

# --- Test 5: not DONE -> skip line ---
_dep_state_cache=()
ISSUE_STATE[Nishfleet/fleet-ops#2218]=open
PR_MERGED[Nishfleet/fleet-ops#2218]=0
set +e
out="$(depends_on_filter $'title\n\ncollision-gate: #2218\n' Nishfleet/fleet-ops 100)"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "Test 5: open unmerged blocker must skip, got rc=$rc out=$out"
[[ "$out" == "skipped-collision-gate:#2218" ]] || fail "Test 5: skip reason must be skipped-collision-gate:#2218, got: $out"
ok "Test 5: open unmerged blocker -> skipped-collision-gate:#2218"

# --- Test 6: two open blockers -> the first one is named ---
_dep_state_cache=()
ISSUE_STATE[Nishfleet/fleet-ops#2218]=open
ISSUE_STATE[Nishfleet/fleet-ops#2219]=open
set +e
out="$(depends_on_filter $'title\n\ncollision-gate: #2218, #2219\n' Nishfleet/fleet-ops 100)"
rc=$?
set -e
[[ "$rc" == "1" && "$out" == "skipped-collision-gate:#2218" ]] \
    || fail "Test 6: first open blocker must be named, got rc=$rc out=$out"
ok "Test 6: two open blockers -> skipped-collision-gate:#2218 (first named)"

# --- Test 7: gate line absent -> unchanged behaviour ---
# A body that merely mentions tickets in passing (not on a gate line) does
# not gate.
_dep_state_cache=()
out="$(depends_on_filter $'title\n\nsee also #2218 and Nishfleet/0509#2356 for context\n' Nishfleet/fleet-ops 100)"; rc=$?
[[ "$rc" == "0" ]] || fail "Test 7: prose mentioning tickets must not gate, got rc=$rc out=$out"
ok "Test 7: no gate line -> prose ticket mentions ignored, claimable"

# --- Test 8: BOTH lines, only one unmet -> right reason ---
_dep_state_cache=()
ISSUE_STATE[Nishfleet/fleet-ops#2218]=closed      # depends-on DONE
ISSUE_STATE[Nishfleet/fleet-ops#2219]=open        # collision-gate NOT done
set +e
out="$(depends_on_filter $'title\n\ndepends-on: #2218\ncollision-gate: #2219\n' Nishfleet/fleet-ops 100)"
rc=$?
set -e
[[ "$rc" == "1" && "$out" == "skipped-collision-gate:#2219" ]] \
    || fail "Test 8a: only collision-gate unmet -> skipped-collision-gate:#2219, got rc=$rc out=$out"
ok "Test 8a: depends-on DONE + collision-gate open -> skipped-collision-gate:#2219"

_dep_state_cache=()
ISSUE_STATE[Nishfleet/fleet-ops#2218]=open        # depends-on NOT done
ISSUE_STATE[Nishfleet/fleet-ops#2219]=closed      # collision-gate DONE
set +e
out="$(depends_on_filter $'title\n\ndepends-on: #2218\ncollision-gate: #2219\n' Nishfleet/fleet-ops 100)"
rc=$?
set -e
[[ "$rc" == "1" && "$out" == "skipped-depends-on:#2218" ]] \
    || fail "Test 8b: only depends-on unmet -> skipped-depends-on:#2218, got rc=$rc out=$out"
ok "Test 8b: depends-on open + collision-gate DONE -> skipped-depends-on:#2218"

# --- Test 9: depends-on cycle detection still works through the shared filter ---
_dep_state_cache=(); _dep_body_cache=()
ISSUE_STATE[Nishfleet/fleet-ops#2218]=open
PR_MERGED[Nishfleet/fleet-ops#2218]=0
DEP_BODY[Nishfleet/fleet-ops#2218]=$'title\n\ndepends-on: #100\n'
set +e
out="$(depends_on_filter $'title\n\ndepends-on: #2218\n' Nishfleet/fleet-ops 100)"
rc=$?
set -e
[[ "$rc" == "1" && "$out" == "depends-on-cycle" ]] \
    || fail "Test 9: cycle must still be depends-on-cycle, got rc=$rc out=$out"
ok "Test 9: depends-on cycle -> depends-on-cycle (unchanged)"

# --- Test 10: caching — one gh call per referenced ticket per tick ---
# A ticket named by collision-gate on two issues costs one state lookup;
# the cache is shared with depends-on.
_dep_state_cache=(); _dep_body_cache=()
: > "$GH_CALL_LOG"
ISSUE_STATE[Nishfleet/fleet-ops#2218]=open
PR_MERGED[Nishfleet/fleet-ops#2218]=0
_dep_reason_file="$scratch/gate-reason"
set +e
depends_on_filter $'title\n\ncollision-gate: #2218\n' Nishfleet/fleet-ops 100 >"$_dep_reason_file"
rc1=$?
depends_on_filter $'title\n\ndepends-on: #2218\n' Nishfleet/fleet-ops 200 >"$_dep_reason_file"
rc2=$?
set -e
[[ "$rc1" == "1" && "$rc2" == "1" ]] || fail "Test 10: both issues must skip, got rc1=$rc1 rc2=$rc2"
state_calls=$(grep -cE 'repos/Nishfleet/fleet-ops/issues/2218$' "$GH_CALL_LOG" || true)
[[ "$state_calls" == "1" ]] || fail "Test 10: #2218 state must be resolved once (cached across gates), got $state_calls calls: $(cat "$GH_CALL_LOG")"
ok "Test 10: gate resolution memoised across collision-gate and depends-on"

echo "ALL COLLISION-GATE TESTS PASSED"
