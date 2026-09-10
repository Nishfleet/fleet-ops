#!/usr/bin/env bash
# tests/pi-intake-tick-depends-on.test.sh
#
# fleet-ops#4808: intake must honor a `depends-on:` line in an issue body —
# never claim a ticket whose named dependencies are not merged/closed. The
# 0509 seam batch had to be hand-gated by removing agent-ready because intake
# claimed regardless; this locks the gate so a machine does that job.
#
# fleet-ops#5167: the same gate must honour the house format's
# `collision-gate:` line ("shares <path> with #<n>"), which until then was
# prose with no machinery behind it. Same DONE rule, same resolver, same
# per-tick memo; only the skip reason differs (skipped-collision-gate:#n).
#
# Proves, offline:
#   1. lib/pi-intake-tick.sh defines depends_on_filter() / collision_gate_
#      filter() and resolve_dep(), and calls both filters in the claim loop
#      with the skip summary line.
#   2. Parse cases: none / one / many / cross-repo / prose ("none", "any of").
#   3. DONE via closed issue.
#   4. DONE via merged PR (claim/issue-<n> branch).
#   5. not DONE -> skip line `skipped-depends-on:#n`.
#   6. Cycle (A depends on B depends on A) -> `depends-on-cycle`.
#   7. Caching: one gh call per referenced issue per tick (memoised).
#   8. collision-gate: house format parses; open ref -> skipped-collision-
#      gate:#n; closed / merged-PR ref -> claimable; memo shared with the
#      depends-on gate (no second resolver).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: filter function + cache arrays present in the tick ===
grep -qF 'depends_on_filter()' "$tick" \
    || fail "depends_on_filter() not defined in tick"
grep -qF 'resolve_dep()' "$tick" \
    || fail "resolve_dep() not defined in tick"
grep -qF 'declare -A _dep_state_cache=()' "$tick" \
    || fail "_dep_state_cache associative array not declared in tick"
grep -qF 'declare -A _dep_body_cache=()' "$tick" \
    || fail "_dep_body_cache associative array not declared in tick"
ok "Test 1: depends_on_filter, resolve_dep, and cache arrays present"

# === Test 2: filter applied in the claim loop with the skip summary line ===
grep -qF 'depends_on_filter "$body" "$FULL" "$N"' "$tick" \
    || fail "tick must call depends_on_filter on the issue body in the claim loop"
grep -qF 'skipped-depends-on:' "$tick" \
    || fail "tick must print skipped-depends-on: when the filter fires"
grep -qF 'depends-on-cycle' "$tick" \
    || fail "tick must print depends-on-cycle for a dependency cycle"
ok "Test 2: filter applied in claim loop with skip summary line"

# === Test 2b: the collision-gate label reuses the same machinery ===
grep -qF 'collision_gate_filter()' "$tick" \
    || fail "collision_gate_filter() not defined in tick"
grep -qF 'collision_gate_filter "$body" "$FULL" "$N"' "$tick" \
    || fail "tick must call collision_gate_filter on the issue body in the claim loop"
grep -qF 'skipped-collision-gate:' "$tick" \
    || fail "tick must print skipped-collision-gate: when the filter fires"
grep -qF "'^collision-gate[ :(]'" "$tick" \
    || fail "tick must match both 'collision-gate:' and the house 'collision-gate (who date):' form"
ok "Test 2b: collision_gate_filter applied in claim loop with skip summary line"

# === Test 2c: one resolver, one memo (the issue's must-not) ===
# Both gates must route through the single _gate_filter + resolve_dep and the
# shared caches. A second resolver or a second set of caches is the failure
# this asserts against.
resolver_defs=$(grep -cE '^resolve_dep\(\) \{' "$tick" || true)
[[ "$resolver_defs" == "1" ]] \
    || fail "exactly one resolve_dep() definition expected, found $resolver_defs"
cache_decls=$(grep -cF 'declare -A _dep_state_cache=()' "$tick" || true)
[[ "$cache_decls" == "1" ]] \
    || fail "exactly one _dep_state_cache declaration expected, found $cache_decls"
grep -qF '_gate_filter() {' "$tick" \
    || fail "_gate_filter() must hold the shared gate loop"
[[ "$(grep -cF '_gate_filter ' "$tick" || true)" -ge 2 ]] \
    || fail "both gates must call the shared _gate_filter"
ok "Test 2c: one resolver and one memo set, shared by both gates"

# === Tests 3-9: bash drill reproducing the exact filter logic ===
# The tick is a top-level script (cannot be sourced), so the drill below
# mirrors lib/pi-intake-tick.sh verbatim in logic, with a stubbed gh so the
# DONE/cycle resolution is deterministic and offline.

scratch="$(mktemp -d -t pirt-depends-on.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub gh: a table of issue states and PR heads the drill consults.
#   ISSUE_STATE[owner/repo#n] = open|closed
#   PR_MERGED[owner/repo#n]  = 1 when a claim/issue-<n> or fable/issue-<n>
#                              PR is merged
#   DEP_BODY[owner/repo#n]   = the dependency issue's body (for cycle check)
declare -A ISSUE_STATE=()
declare -A PR_MERGED=()
declare -A DEP_BODY=()

gh() {
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
                # parse -R owner/repo
                local repo=""
                while [[ $# -gt 0 ]]; do
                    if [[ "$1" == "-R" ]]; then repo="$2"; shift 2; continue; fi
                    shift
                done
                local key="${repo}#${n}"
                printf '%s\n' "${DEP_BODY[$key]:-}"
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
                local key="${repo}#${n}"
                if [[ -n "$n" && "${PR_MERGED[$key]:-0}" == "1" ]]; then
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

# The drill's _gate_filter + both gate wrappers + resolve_dep, mirroring the
# tick verbatim.
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

_gate_filter() {
    local gate_re="$1" skip_reason="$2" cycle_reason="$3"
    local body="$4" repo="$5" num="$6"
    local ref owner rname target_num dep_key dep_state dep_body
    local -a deps=()

    mapfile -t deps < <(printf '%s\n' "$body" \
        | grep -E "$gate_re" \
        | grep -oE '#[0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' || true)
    (( ${#deps[@]} == 0 )) && return 0

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
            if [[ -n "${_dep_body_cache[$dep_key]:-}" ]]; then
                dep_body="${_dep_body_cache[$dep_key]}"
            else
                dep_body="$(gh issue view "$target_num" -R "${owner}/${rname}" --json body --jq '.body // ""' 2>/dev/null || true)"
                _dep_body_cache[$dep_key]="$dep_body"
            fi
            if printf '%s\n' "$dep_body" | grep -E "$gate_re" \
                | grep -qE "#${num}\b|${repo}#${num}\b"; then
                echo "$cycle_reason"
                return 1
            fi
            echo "${skip_reason}${ref}"
            return 1
        fi
    done
    return 0
}

depends_on_filter() {
    _gate_filter '^depends-on:' 'skipped-depends-on:' 'depends-on-cycle' "$@"
}

collision_gate_filter() {
    _gate_filter '^collision-gate[ :(]' 'skipped-collision-gate:' 'collision-gate-cycle' "$@"
}

# --- Test 3: parse cases ---
# none / prose "none" -> claimable (no deps)
out="$(depends_on_filter $'title\n\ndepends-on: none\n' Nishfleet/fleet-ops 100)"; rc=$?
[[ "$rc" == "0" ]] || fail "Test 3a: 'depends-on: none' must be claimable, got rc=$rc out=$out"
ok "Test 3a: 'depends-on: none' is claimable (no deps parsed)"

# prose "any of" -> claimable
out="$(depends_on_filter $'title\n\ndepends-on: any of the above\n' Nishfleet/fleet-ops 100)"; rc=$?
[[ "$rc" == "0" ]] || fail "Test 3b: 'depends-on: any of' prose must be claimable, got rc=$rc out=$out"
ok "Test 3b: 'depends-on: any of' prose is claimable (no refs parsed)"

# one same-repo dep, DONE via closed -> claimable
ISSUE_STATE[Nishfleet/fleet-ops#2218]=closed
out="$(depends_on_filter $'title\n\ndepends-on: #2218\n' Nishfleet/fleet-ops 100)"; rc=$?
[[ "$rc" == "0" ]] || fail "Test 3c: one closed dep must be claimable, got rc=$rc out=$out"
ok "Test 3c: one same-repo dep closed -> claimable"

# many deps, all DONE -> claimable
ISSUE_STATE[Nishfleet/fleet-ops#2213]=closed
ISSUE_STATE[Nishfleet/fleet-ops#2214]=closed
out="$(depends_on_filter $'title\n\ndepends-on: #2213, #2214\n' Nishfleet/fleet-ops 100)"; rc=$?
[[ "$rc" == "0" ]] || fail "Test 3d: many closed deps must be claimable, got rc=$rc out=$out"
ok "Test 3d: many deps all closed -> claimable"

# cross-repo dep, DONE via closed -> claimable
ISSUE_STATE[Nishfleet/0509#2181]=closed
out="$(depends_on_filter $'title\n\ndepends-on: Nishfleet/0509#2181\n' Nishfleet/fleet-ops 100)"; rc=$?
[[ "$rc" == "0" ]] || fail "Test 3e: cross-repo closed dep must be claimable, got rc=$rc out=$out"
ok "Test 3e: cross-repo dep closed -> claimable"

# --- Test 4: DONE via merged PR (claim/issue-<n> branch) ---
ISSUE_STATE[Nishfleet/fleet-ops#2218]=open
PR_MERGED[Nishfleet/fleet-ops#2218]=1
out="$(depends_on_filter $'title\n\ndepends-on: #2218\n' Nishfleet/fleet-ops 100)"; rc=$?
[[ "$rc" == "0" ]] || fail "Test 4: dep with merged claim/issue PR must be claimable, got rc=$rc out=$out"
ok "Test 4: DONE via merged claim/issue-<n> PR -> claimable"

# --- Test 5: not DONE -> skip line ---
ISSUE_STATE[Nishfleet/fleet-ops#2218]=open
PR_MERGED[Nishfleet/fleet-ops#2218]=0
set +e
out="$(depends_on_filter $'title\n\ndepends-on: #2218\n' Nishfleet/fleet-ops 100)"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "Test 5: open unmerged dep must skip, got rc=$rc out=$out"
[[ "$out" == "skipped-depends-on:#2218" ]] || fail "Test 5: skip reason must be skipped-depends-on:#2218, got: $out"
ok "Test 5: open unmerged dep -> skipped-depends-on:#2218"

# --- Test 6: cycle (A depends on B depends on A) -> depends-on-cycle ---
# A (#100) depends on B (#2218); B's body depends on A (#100).
ISSUE_STATE[Nishfleet/fleet-ops#2218]=open
PR_MERGED[Nishfleet/fleet-ops#2218]=0
DEP_BODY[Nishfleet/fleet-ops#2218]=$'title\n\ndepends-on: #100\n'
set +e
out="$(depends_on_filter $'title\n\ndepends-on: #2218\n' Nishfleet/fleet-ops 100)"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "Test 6: cycle must skip, got rc=$rc out=$out"
[[ "$out" == "depends-on-cycle" ]] || fail "Test 6: cycle reason must be depends-on-cycle, got: $out"
ok "Test 6: A depends on B depends on A -> depends-on-cycle"

# --- Test 7: caching (one gh call per referenced issue per tick) ---
# Reset caches and count gh api issue calls for a repeated dependency.
_dep_state_cache=()
_dep_body_cache=()
GH_CALL_LOG="$scratch/gh-calls.log"
: > "$GH_CALL_LOG"
gh() {
    if [[ -n "${GH_CALL_LOG:-}" ]]; then
        printf '%s\n' "$*" >>"$GH_CALL_LOG"
    fi
    # re-dispatch to the real stub body below
    _gh_stub "$@"
}
_gh_stub() {
    local cmd="$1"; shift
    case "$cmd" in
        api)
            local path="$1"
            if [[ "$path" =~ ^repos/([^/]+)/([^/]+)/issues/([0-9]+)$ ]]; then
                local key="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}#${BASH_REMATCH[3]}"
                printf '{"state":"%s"}\n' "${ISSUE_STATE[$key]:-open}"
                return 0
            fi
            printf '[]\n'
            return 0
            ;;
        issue)
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
            return 0
            ;;
        pr)
            if [[ "$1" == "list" ]]; then
                local repo="" head=""
                while [[ $# -gt 0 ]]; do
                    if [[ "$1" == "-R" ]]; then repo="$2"; shift 2; continue; fi
                    if [[ "$1" == "--head" ]]; then head="$2"; shift 2; continue; fi
                    shift
                done
                local n=""
                if [[ "$head" =~ ^(claim|fable)/issue-([0-9]+)$ ]]; then n="${BASH_REMATCH[2]}"; fi
                local key="${repo}#${n}"
                if [[ -n "$n" && "${PR_MERGED[$key]:-0}" == "1" ]]; then
                    printf '[{"number":1}]\n'
                else
                    printf '[]\n'
                fi
                return 0
            fi
            return 0
            ;;
    esac
    return 0
}
export -f gh

# Two issues both depend on #2218 (open). The second must reuse the cache.
# Call the filter in the CURRENT shell (stdout to a temp file, like the
# fixed tick) so the memo caches persist across the two calls.
ISSUE_STATE[Nishfleet/fleet-ops#2218]=open
PR_MERGED[Nishfleet/fleet-ops#2218]=0
_dep_reason_file="$scratch/dep-reason"
set +e
if depends_on_filter $'title\n\ndepends-on: #2218\n' Nishfleet/fleet-ops 100 >"$_dep_reason_file"; then
    rc1=0
else
    rc1=$?
fi
if depends_on_filter $'title\n\ndepends-on: #2218\n' Nishfleet/fleet-ops 200 >"$_dep_reason_file"; then
    rc2=0
else
    rc2=$?
fi
set -e
[[ "$rc1" == "1" && "$rc2" == "1" ]] || fail "Test 7: both issues must skip, got rc1=$rc1 rc2=$rc2"
# The state lookup for #2218 should happen once (memoised); the second call
# reuses the cache. Count only the issue-state lookup (not the /timeline call).
state_calls=$(grep -cE 'repos/Nishfleet/fleet-ops/issues/2218$' "$GH_CALL_LOG" || true)
[[ "$state_calls" == "1" ]] || fail "Test 7: #2218 state must be resolved once (cached), got $state_calls calls: $(cat "$GH_CALL_LOG")"
ok "Test 7: dependency resolution is memoised (one gh call per issue per tick)"

# --- Tests 8a-8g: the collision-gate gate (fleet-ops#5167) ---
# The house ticket format carries:
#   collision-gate (Fable 2026-09-10): shares <path> with #<n>. agent-ready
#   returns automatically when those are merged/closed
# Live case: 0509#2411 gated on #2407, claimed anyway.
COLLISION_OPEN=$'title\n\ncollision-gate (Fable 2026-09-10): shares app/components/signup-first-brief-view.tsx with #2407. agent-ready returns\nautomatically when those are merged/closed (gate file: agent-state/fleet-landing-watch/ticket-gates.json)\n'

# 8a: open gated ticket -> skipped-collision-gate:#2407 (not claimed).
ISSUE_STATE[Nishfleet/fleet-ops#2407]=open
PR_MERGED[Nishfleet/fleet-ops#2407]=0
set +e
out="$(collision_gate_filter "$COLLISION_OPEN" Nishfleet/fleet-ops 2411)"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "Test 8a: open collision-gate ref must skip, got rc=$rc out=$out"
[[ "$out" == "skipped-collision-gate:#2407" ]] \
    || fail "Test 8a: skip reason must be skipped-collision-gate:#2407, got: $out"
ok "Test 8a: open collision-gate ref -> skipped-collision-gate:#2407"

# 8b: the tick after the gated ticket closes -> claimable.
ISSUE_STATE[Nishfleet/fleet-ops#2407]=closed
set +e
out="$(collision_gate_filter "$COLLISION_OPEN" Nishfleet/fleet-ops 2411)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "Test 8b: closed gated ticket must be claimable, got rc=$rc out=$out"
ok "Test 8b: collision-gate ref closed -> claimable"

# 8c: DONE via a merged claim/issue-<n> PR counts too (same DONE rule).
ISSUE_STATE[Nishfleet/fleet-ops#2407]=open
PR_MERGED[Nishfleet/fleet-ops#2407]=1
set +e
out="$(collision_gate_filter "$COLLISION_OPEN" Nishfleet/fleet-ops 2411)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "Test 8c: merged PR must clear the collision gate, got rc=$rc out=$out"
ok "Test 8c: collision-gate ref with merged PR -> claimable"
PR_MERGED[Nishfleet/fleet-ops#2407]=0

# 8d: prose with no ref -> claimable (no false gate).
set +e
out="$(collision_gate_filter $'title\n\ncollision-gate: nothing overlaps\n' Nishfleet/fleet-ops 2411)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "Test 8d: ref-less collision-gate prose must be claimable, got rc=$rc out=$out"
ok "Test 8d: collision-gate prose with no ref -> claimable"

# 8e: cross-repo ref parses.
ISSUE_STATE[Nishfleet/0509#2181]=open
set +e
out="$(collision_gate_filter $'title\n\ncollision-gate: shares lib/x.ts with Nishfleet/0509#2181\n' Nishfleet/fleet-ops 2411)"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "Test 8e: open cross-repo ref must skip, got rc=$rc out=$out"
[[ "$out" == "skipped-collision-gate:Nishfleet/0509#2181" ]] \
    || fail "Test 8e: cross-repo skip reason wrong, got: $out"
ok "Test 8e: cross-repo collision-gate ref -> skipped-collision-gate:Nishfleet/0509#2181"

# 8f: mutual gates (A collision-gates B, B collision-gates A) -> cycle reason.
ISSUE_STATE[Nishfleet/fleet-ops#2407]=open
DEP_BODY[Nishfleet/fleet-ops#2407]=$'title\n\ncollision-gate: shares lib/x.ts with #2411\n'
set +e
out="$(collision_gate_filter "$COLLISION_OPEN" Nishfleet/fleet-ops 2411)"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "Test 8f: mutual gate must skip, got rc=$rc out=$out"
[[ "$out" == "collision-gate-cycle" ]] || fail "Test 8f: cycle reason must be collision-gate-cycle, got: $out"
ok "Test 8f: mutual collision gate -> collision-gate-cycle"

# 8g: the memo is SHARED with depends-on (one resolver, one lookup).
# Resolve #2218 once through the depends-on gate, then gate on it through the
# collision gate: no second gh API state call may happen.
_dep_state_cache=()
_dep_body_cache=()
ISSUE_STATE[Nishfleet/fleet-ops#2218]=open
PR_MERGED[Nishfleet/fleet-ops#2218]=0
: > "$GH_CALL_LOG"
set +e
depends_on_filter $'title\n\ndepends-on: #2218\n' Nishfleet/fleet-ops 100 >/dev/null
rc1=$?
set -e
: > "$GH_CALL_LOG"
set +e
out="$(collision_gate_filter $'title\n\ncollision-gate: shares lib/y.ts with #2218\n' Nishfleet/fleet-ops 2411)"
rc2=$?
set -e
[[ "$rc1" == "1" && "$rc2" == "1" ]] || fail "Test 8g: both gates must skip, got rc1=$rc1 rc2=$rc2"
[[ "$out" == "skipped-collision-gate:#2218" ]] || fail "Test 8g: skip reason wrong, got: $out"
calls_after=$(grep -cE 'repos/Nishfleet/fleet-ops/issues/2218$' "$GH_CALL_LOG" || true)
[[ "$calls_after" == "0" ]] \
    || fail "Test 8g: collision gate must reuse the depends-on memo (0 state calls), got $calls_after: $(cat "$GH_CALL_LOG")"
ok "Test 8g: collision gate reuses the depends-on memo (one resolver, one lookup)"

echo "ALL DEPENDS-ON TESTS PASSED"
