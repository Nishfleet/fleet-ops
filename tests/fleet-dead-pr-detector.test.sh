#!/usr/bin/env bash
# tests/fleet-dead-pr-detector.test.sh
#
# Hermetic (no network) matrix for bin/fleet-dead-pr-detector
# (fleet-ops#4468): an open PR GitHub reports as `mergeable: CONFLICTING`
# is dead when its parent-originating issue is MERGED/CLOSED — the branch
# cannot merge and its work already landed. Parent resolution is
# deterministic and exact-number only (#11352 never matches issue 1135).
#
# PARENT RESOLUTION (priority, first match wins, on the SCRUBBED body):
#   0. scrub first — refs that can never name a parent issue of the
#      scanned repo are removed:
#      0a. cross-repo qualified refs — `owner/repo#N`, `owner/repo #N`
#          and the short `repo#N` form, when the repo is neither the
#          scanned repo (Nishfleet/fleet-ops) nor its short name
#          (fleet-ops). `Nishfleet/fleet-ops#N` / `fleet-ops#N` survive
#      0b. PR-marked refs — `PR #N`/`PRs #N`, `pull #N`/`pulls #N`,
#          `pull request(s) #N`, `pull-request(s) #N` (any case; a PR
#          reference is never an issue parent)
#   1. explicit delivery trailer — `Closes|Fixes|Resolves #N`, `Closed
#      #N`, with an optional `<repo>#N` / `<owner>/<repo>#N` prefix
#   2. `Relates to #N` in the body
#   3. head branch `claim/issue-<N>`
#   4. first bounded `#N` reference in the body
# A CONFLICTING PR with no resolvable parent is skipped, never guessed.
#
# REGRESSION REPLAY (the bug that phase 3 fixes): PR #9's body carried
# "Companion to Nishfleet/siterep-public PR #36" — a cross-repo PR
# reference. The generic bounded-`#N` fallback read it as fleet-ops
# issue #36 (an unrelated CLOSED intake issue) and would have flagged
# PR #9 dead on a bogus parent. Case 6 pins the fix: #36 is never
# viewed, nothing resolves, the PR is skipped.
#
# MERGEABLE IS NOT THE ONLY UNDECIDED VALUE (fleet-ops#5079): GitHub
# computes mergeability asynchronously, so `gh pr list` can report
# `mergeable: "UNKNOWN"` (or null) and the old scan read clean over a
# dead PR. Cases 15-19 pin the fix: any value that is not exactly
# MERGEABLE/CONFLICTING (`"UNKNOWN"`, null, a future value) is counted in
# the `unknown-mergeable` figure, kept in the scan, and re-queried with
# `gh pr view` (up to DEAD_PR_UNKNOWN_ATTEMPTS tries). Only a decided
# answer ends the
# question; else the parent decides first — CLOSED/MERGED parent ->
# LOUD DEAD-PR-UNRESOLVED + rc 2 (fail closed), OPEN parent -> logged and
# skipped, no resolvable parent -> logged and skipped.
#
# STALE-CONFLICTING CLASS (fleet-ops#5205): a decided-CONFLICTING PR whose
# parent is OPEN is not dead, but a conflict standing past
# DEAD_PR_STALE_HOURS (default 24) is stale — the branch rots, the parent
# holds its claim, and red-PR repair burns seats on a shape no worker can
# fix. GitHub has no conflict-since field (createdAt is branch age), so the
# detector writes a first-seen marker per PR under DEAD_PR_STATE_DIR and
# prunes it the same way red-pr-repair state is pruned — the instant the PR
# leaves the class (MERGEABLE, dead-classified, unresolved parent, or gone
# from the open list) the GC pass drops the marker. Flagged members are
# written to stale-conflicting.list (`<repo> <pr> <parent>` lines) for
# fleet-heartbeat-red-pr-repair to consume. Cases 20-25 pin the class.
#
# Measure lines: `stale_conflicting_prs=<n>` second-to-last, then
# `dead_conflicting_prs=<n>` is the LAST stdout line.
# Exit codes: 0 clean, 1 when at least one dead or stale-conflicting PR is
# proven, 2 on gh/jq infra failure or on a PR whose mergeable stays
# undecided while its parent is MERGED/CLOSED (fail-closed, never a
# false green).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-dead-pr-detector"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch=$(mktemp -d)
mkdir -p "$scratch/bin"

# Mock gh shim. Logs every call to FAKE_DIR/gh.log and serves fixtures:
#   pr list   -> FAKE_DIR/prlist.json (JSON array of open PRs with
#                number/title/headRefName/mergeable/body); exit code
#                FAKE_PR_LIST_RC (default 0)
#   pr view N -> FAKE_DIR/prview-N.json ({mergeable}) when that fixture
#                exists, else the mergeable of N taken from prlist.json.
#                Lets a case model "list said UNKNOWN, the re-query then
#                said CONFLICTING" and "both said UNKNOWN". A fallback with
#                no fixture for N (empty jq output) fails loudly (rc 1), so
#                a case can never silently model "view returned nothing".
#   issue view N -> FAKE_DIR/issue-N.json ({state,title})
cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/gh.log"
case "$1" in
  pr)
    case "$2" in
      list)
        cat "$FAKE_DIR/prlist.json" 2>/dev/null || true
        exit "${FAKE_PR_LIST_RC:-0}"
        ;;
      view)
        if [ -f "$FAKE_DIR/prview-$3.json" ]; then
          cat "$FAKE_DIR/prview-$3.json"
          exit 0
        fi
        out="$(jq -c --argjson n "$3" \
          '{mergeable: (.[] | select(.number == $n) | .mergeable)}' \
          "$FAKE_DIR/prlist.json" 2>/dev/null)" || out=""
        [ -n "$out" ] || { echo "no fixture for gh pr view $3" >&2; exit 1; }
        printf '%s\n' "$out"
        exit 0
        ;;
      *) echo "unexpected gh pr $2" >&2; exit 1 ;;
    esac ;;
  issue)
    case "$2" in
      view)
        cat "$FAKE_DIR/issue-$3.json" 2>/dev/null \
          || { echo "no fixture issue-$3" >&2; exit 1; }
        exit 0
        ;;
      *) echo "unexpected gh issue $2" >&2; exit 1 ;;
    esac ;;
  *) echo "unexpected gh $1" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh"

export FAKE_DIR="$scratch"

run() {
    # $@ -> env overrides, merged AFTER the defaults so a GH= override
    # wins. Detector stdout lands in $scratch/stdout.log, stderr in
    # $scratch/stderr.log; prints rc=<n> on stdout. First-seen markers and
    # the flagged list live in $scratch/state (DEAD_PR_STATE_DIR).
    local rc
    set +e
    env GH="$scratch/bin/gh" DEAD_PR_REPO="Nishfleet/fleet-ops" \
        DEAD_PR_STATE_DIR="$scratch/state" "$@" \
        "$bin" >"$scratch/stdout.log" 2>"$scratch/stderr.log"
    rc=$?
    set -e
    printf 'rc=%s\n' "$rc"
}

set_fixtures() {
    # $1 = pr list JSON; remaining args are `<issue>:<state>` pairs.
    printf '%s' "$1" >"$scratch/prlist.json"
    shift
    local kv n s
    rm -f "$scratch"/prview-*.json
    for kv in "$@"; do
        n="${kv%%:*}"
        s="${kv#*:}"
        printf '{"state":"%s","title":"issue %s"}\n' "$s" "$n" \
            >"$scratch/issue-$n.json"
    done
    : >"$scratch/gh.log"
    : >"$scratch/stdout.log"
    : >"$scratch/stderr.log"
    # Stale-conflicting state starts clean each case; a case seeds marker
    # files under $scratch/state itself when it needs an aged first-seen.
    rm -rf "$scratch/state"
    mkdir -p "$scratch/state"
}

set_pr_view() {
    # $1 = PR number, $2 = the mergeable value `gh pr view <n>` reports.
    printf '{"mergeable":"%s"}\n' "$2" >"$scratch/prview-$1.json"
}

last_measure() {
    # Print the last stdout line; the detector contract makes it the
    # `dead_conflicting_prs=<n>` measure line.
    tail -n 1 "$scratch/stdout.log"
}

# --- Case 1: trailer `Fixes #N`, parent CLOSED -> dead ---
set_fixtures \
  '[{"number":9,"title":"feat: cloud upload v2","headRefName":"fix/cloud-upload","mergeable":"CONFLICTING","body":"Re-upload path rebuilt.\n\nFixes #595"}]' \
  595:CLOSED
rc=$(run)
grep -q '^rc=1$' <<<"$rc" || fail "trailer+CLOSED parent must exit 1: $rc"
grep -q 'parent=595' "$scratch/stdout.log" || fail "evidence line must name parent=595: $(cat "$scratch/stdout.log")"
grep -q 'parent-state=CLOSED' "$scratch/stdout.log" || fail "evidence line must name parent-state=CLOSED: $(cat "$scratch/stdout.log")"
grep -q 'issue view 595' "$scratch/gh.log" || fail "must query issue 595: $(cat "$scratch/gh.log")"
[ "$(last_measure)" = "dead_conflicting_prs=1" ] || fail "measure must be last stdout line = 1: $(last_measure)"
ok "case1: Fixes #595 + CLOSED parent -> dead_conflicting_prs=1, exit 1, evidence line"

# --- Case 2: trailer `Closes #N`, parent MERGED -> dead ---
set_fixtures \
  '[{"number":46,"title":"feat: seat retry windows","headRefName":"fix/seats","mergeable":"CONFLICTING","body":"## Fix\n\nCloses #1941"}]' \
  1941:MERGED
rc=$(run)
grep -q '^rc=1$' <<<"$rc" || fail "Closes+MERGED parent must exit 1: $rc"
grep -q 'parent=1941' "$scratch/stdout.log" || fail "evidence line must name parent=1941: $(cat "$scratch/stdout.log")"
grep -q 'parent-state=MERGED' "$scratch/stdout.log" || fail "evidence line must name parent-state=MERGED: $(cat "$scratch/stdout.log")"
[ "$(last_measure)" = "dead_conflicting_prs=1" ] || fail "measure must be = 1: $(last_measure)"
ok "case2: Closes #1941 + MERGED parent -> dead_conflicting_prs=1, exit 1"

# --- Case 3: `Relates to #N`, parent CLOSED -> dead ---
set_fixtures \
  '[{"number":87,"title":"feat: escalation exclude","headRefName":"fix/escalate","mergeable":"CONFLICTING","body":"Adjudication notes.\n\nRelates to #2133"}]' \
  2133:CLOSED
rc=$(run)
grep -q '^rc=1$' <<<"$rc" || fail "Relates-to+CLOSED parent must exit 1: $rc"
grep -q 'parent=2133' "$scratch/stdout.log" || fail "evidence line must name parent=2133: $(cat "$scratch/stdout.log")"
[ "$(last_measure)" = "dead_conflicting_prs=1" ] || fail "measure must be = 1: $(last_measure)"
ok "case3: Relates to #2133 + CLOSED parent -> dead_conflicting_prs=1, exit 1"

# --- Case 4: claim/issue-N head branch, parent CLOSED -> dead ---
set_fixtures \
  '[{"number":1301,"title":"feat: ram metric compare","headRefName":"claim/issue-1126","mergeable":"CONFLICTING","body":"worktree rebuild in flight"}]' \
  1126:CLOSED
rc=$(run)
grep -q '^rc=1$' <<<"$rc" || fail "claim-branch + CLOSED parent must exit 1: $rc"
grep -q 'parent=1126' "$scratch/stdout.log" || fail "evidence line must name parent=1126: $(cat "$scratch/stdout.log")"
grep -q 'issue view 1126' "$scratch/gh.log" || fail "must query issue 1126: $(cat "$scratch/gh.log")"
ok "case4: claim/issue-1126 branch + CLOSED parent -> dead_conflicting_prs=1, exit 1"

# --- Case 5: `Relates to #N`, parent OPEN -> not dead ---
set_fixtures \
  '[{"number":21,"title":"feat: gap closure","headRefName":"fix/gap","mergeable":"CONFLICTING","body":"Partial fix.\n\nRelates to #489"}]' \
  489:OPEN
rc=$(run)
grep -q '^rc=0$' <<<"$rc" || fail "OPEN parent must exit 0: $rc"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] || fail "measure must be = 0: $(last_measure)"
grep -q 'still live' "$scratch/stderr.log" || fail "OPEN parent must be logged as still live: $(cat "$scratch/stderr.log")"
ok "case5: Relates to #489 + OPEN parent -> clean, dead_conflicting_prs=0, exit 0"

# --- Case 6 (REGRESSION REPLAY): cross-repo PR ref must not resolve as
# a fleet-ops parent issue. "Companion to Nishfleet/siterep-public PR
# #36": no same-repo qualifier, the ref is PR-marked -> scrubbed, no
# parent, PR skipped. The bogus #36 must never be viewed. ---
set_fixtures \
  '[{"number":9,"title":"feat: siterep companion","headRefName":"fix/siterep","mergeable":"CONFLICTING","body":"Companion to Nishfleet/siterep-public PR #36"}]'
rc=$(run)
grep -q '^rc=0$' <<<"$rc" || fail "cross-repo PR ref must not flag the PR dead: $rc"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] || fail "measure must be = 0: $(last_measure)"
grep -q 'issue view 36' "$scratch/gh.log" && fail "bogus parent #36 must never be viewed: $(cat "$scratch/gh.log")"
grep -q 'no resolvable parent' "$scratch/stderr.log" || fail "skipped PR must be logged: $(cat "$scratch/stderr.log")"
ok "case6 (regression): cross-repo 'PR #36' ref -> no parent, not flagged, no issue view 36"

# --- Case 7: cross-repo `foo/bar#42` scrubbed; same-repo short name
# `fleet-ops#3111` survives the scrub and resolves as the parent ---
set_fixtures \
  '[{"number":3289,"title":"fix: config drop-in","headRefName":"fix/dropin","mergeable":"CONFLICTING","body":"See also foo/bar#42 and Ref: fleet-ops#3111"}]' \
  3111:CLOSED
rc=$(run)
grep -q '^rc=1$' <<<"$rc" || fail "same-repo fleet-ops#N must resolve and dead-flag: $rc"
grep -q 'parent=3111' "$scratch/stdout.log" || fail "parent must be 3111, not 42: $(cat "$scratch/stdout.log")"
grep -q 'issue view 3111' "$scratch/gh.log" || fail "must query issue 3111: $(cat "$scratch/gh.log")"
grep -q 'issue view 42' "$scratch/gh.log" && fail "cross-repo foo/bar#42 must be scrubbed: $(cat "$scratch/gh.log")"
ok "case7: foo/bar#42 scrubbed, fleet-ops#3111 kept -> parent=3111, exit 1"

# --- Case 8: bare `#N` mention survives the scrub, OPEN parent -> live ---
set_fixtures \
  '[{"number":55,"title":"chore: tune windows","headRefName":"fix/tune","mergeable":"CONFLICTING","body":"unrelated chatter #404"}]' \
  404:OPEN
rc=$(run)
grep -q '^rc=0$' <<<"$rc" || fail "bare ref + OPEN parent must exit 0: $rc"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] || fail "measure must be = 0: $(last_measure)"
grep -q 'issue view 404' "$scratch/gh.log" || fail "bare ref must still be resolved and viewed: $(cat "$scratch/gh.log")"
ok "case8: bare #N mention + OPEN parent -> clean, exit 0"

# --- Case 9: a PR-marked ref alone must never attribute a parent ---
set_fixtures \
  '[{"number":1561,"title":"feat: template roll","headRefName":"fix/tpl","mergeable":"CONFLICTING","body":"Only a link to PR #1561 lives here"}]'
rc=$(run)
grep -q '^rc=0$' <<<"$rc" || fail "PR-marked ref must not be attributed as a parent: $rc"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] || fail "measure must be = 0: $(last_measure)"
grep -q 'issue view 1561' "$scratch/gh.log" && fail "PR #1561 must never be viewed as an issue: $(cat "$scratch/gh.log")"
ok "case9: PR #1561 only -> not attributed, clean, exit 0"

# --- Case 10: mixed sweep — one dead PR + one live PR -> count 1 ---
set_fixtures \
  '[{"number":9,"title":"feat: cloud upload v2","headRefName":"fix/cloud-upload","mergeable":"CONFLICTING","body":"Re-upload path rebuilt.\n\nFixes #595"},{"number":21,"title":"feat: gap closure","headRefName":"fix/gap","mergeable":"CONFLICTING","body":"Partial fix.\n\nRelates to #489"}]' \
  595:CLOSED 489:OPEN
rc=$(run)
grep -q '^rc=1$' <<<"$rc" || fail "one dead + one live must exit 1: $rc"
[ "$(last_measure)" = "dead_conflicting_prs=1" ] || fail "measure must be = 1: $(last_measure)"
grep -q 'issue view 595' "$scratch/gh.log" || fail "must query issue 595: $(cat "$scratch/gh.log")"
grep -q 'issue view 489' "$scratch/gh.log" || fail "must query issue 489: $(cat "$scratch/gh.log")"
n=$(grep -c '^dead-pr:' "$scratch/stdout.log" || true)
[ "$n" = "1" ] || fail "exactly one dead-pr evidence line expected, got $n: $(cat "$scratch/stdout.log")"
grep -q 'parent=595' "$scratch/stdout.log" || fail "evidence line must be for parent 595: $(cat "$scratch/stdout.log")"
grep -q 'parent=489' "$scratch/stdout.log" && fail "live PR must not get an evidence line: $(cat "$scratch/stdout.log")"
ok "case10: one dead (595) + one live (489) -> dead_conflicting_prs=1, exit 1"

# --- Case 11: no conflicting PRs (both MERGEABLE) -> clean sweep ---
set_fixtures \
  '[{"number":65,"title":"feat: a","headRefName":"fix/a","mergeable":"MERGEABLE","body":"Fixes #595"},{"number":66,"title":"feat: b","headRefName":"fix/b","mergeable":"MERGEABLE","body":"Fixes #1941"}]'
rc=$(run)
grep -q '^rc=0$' <<<"$rc" || fail "no conflicting PRs must exit 0: $rc"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] || fail "measure must be = 0: $(last_measure)"
grep -q 'issue view' "$scratch/gh.log" && fail "non-conflicting PRs must not be resolved at all: $(cat "$scratch/gh.log")"
grep -q 'unknown-mergeable=0' "$scratch/stderr.log" || fail "honesty line must report 0 undecided values: $(cat "$scratch/stderr.log")"
ok "case11: MERGEABLE PRs only -> dead_conflicting_prs=0, exit 0, no issue views"

# --- Case 12: gh pr list fails (shim exit 2) -> fail-closed rc 2, loud
# on stderr, no false green ---
set_fixtures '[]'
out=$(env GH="$scratch/bin/gh" DEAD_PR_REPO="Nishfleet/fleet-ops" \
  DEAD_PR_STATE_DIR="$scratch/state" \
  FAKE_PR_LIST_RC=2 "$bin" >"$scratch/stdout.log" 2>"$scratch/stderr.log"; echo "rc=$?")
grep -q 'rc=2' <<<"$out" || fail "gh pr list failure must exit rc 2: $out"
grep -q 'LOUD \[DEAD-PR-GH\]' "$scratch/stderr.log" || fail "gh failure must LOUD on stderr: $(cat "$scratch/stderr.log")"
grep -q 'gh pr list failed' "$scratch/stderr.log" || fail "loud line must say pr list failed: $(cat "$scratch/stderr.log")"
grep -q 'dead_conflicting_prs' "$scratch/stdout.log" && fail "infra failure must not print a measure (no false green): $(cat "$scratch/stdout.log")"
ok "case12: gh pr list rc 2 -> exit 2, loud on stderr, no measure"

# --- Case 13: gh missing -> fail-closed rc 2 ---
rc=$(run GH=/nonexistent)
grep -q '^rc=2$' <<<"$rc" || fail "gh missing must exit rc 2: $rc"
grep -q 'gh missing' "$scratch/stderr.log" || fail "gh missing must LOUD on stderr: $(cat "$scratch/stderr.log")"
grep -q 'dead_conflicting_prs' "$scratch/stdout.log" && fail "gh missing must not print a measure: $(cat "$scratch/stdout.log")"
ok "case13: GH=/nonexistent -> exit 2, loud on stderr"

# --- Case 14 (EXACT-NUMBER PIN): `#11352` must resolve issue 11352,
# never its substring 1135. Conflicting PR body "related ticket #11352"
# with 11352 OPEN and 1135 CLOSED: if resolution matched 1135 the parent
# would be CLOSED and the PR dead-flagged — this case fails the detector
# the moment it touches 1135. ---
set_fixtures \
  '[{"number":77,"title":"feat: exact-number pin","headRefName":"fix/exactnum","mergeable":"CONFLICTING","body":"related ticket #11352"}]' \
  1135:CLOSED 11352:OPEN
rc=$(run)
grep -q '^rc=0$' <<<"$rc" || fail "exact-number pin: parent must be 11352 (OPEN), not 1135 (CLOSED): $rc"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] || fail "exact-number pin: measure must be 0: $(last_measure)"
grep -q 'issue view 11352' "$scratch/gh.log" || fail "exact-number pin: must query issue 11352: $(cat "$scratch/gh.log")"
grep -Eq 'issue view 1135([^0-9]|$)' "$scratch/gh.log" && fail "exact-number pin: issue 1135 must never be viewed: $(cat "$scratch/gh.log")"
grep -q 'still live' "$scratch/stderr.log" || fail "exact-number pin: OPEN parent must be logged as still live: $(cat "$scratch/stderr.log")"
ok "case14 (exact-number pin): #11352 -> parent 11352 (OPEN), never 1135; clean, exit 0"

# --- Case 15 (fleet-ops#5079): `gh pr list` says mergeable "UNKNOWN" for
# a PR whose parent issue is CLOSED. The list fetch is not the last word:
# the PR is counted in `unknown-mergeable`, kept in the scan, re-queried
# with `gh pr view` (which here answers CONFLICTING), and dead-classified
# by the parent. It must NEVER exit 0 with dead_conflicting_prs=0. ---
set_fixtures \
  '[{"number":4978,"title":"feat: intake reconcile","headRefName":"fix/intake","mergeable":"UNKNOWN","body":"Fixes #4945"}]' \
  4945:CLOSED
set_pr_view 4978 CONFLICTING
rc=$(run DEAD_PR_UNKNOWN_SLEEP=0)
grep -q '^rc=0$' <<<"$rc" && fail "UNKNOWN mergeable must never exit 0: $rc: $(cat "$scratch/stdout.log")"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] && fail "UNKNOWN mergeable must never read dead_conflicting_prs=0: $(cat "$scratch/stdout.log")"
grep -q '^rc=1$' <<<"$rc" || fail "re-query answered CONFLICTING + CLOSED parent must exit 1: $rc"
grep -q 'pr view 4978' "$scratch/gh.log" || fail "undecided mergeable must be re-queried with gh pr view: $(cat "$scratch/gh.log")"
grep -q 'issue view 4945' "$scratch/gh.log" || fail "parent must be resolved: $(cat "$scratch/gh.log")"
grep -q 'parent=4945 parent-state=CLOSED' "$scratch/stdout.log" || fail "evidence line must name parent 4945 CLOSED: $(cat "$scratch/stdout.log")"
grep -q 'unknown-mergeable=1' "$scratch/stderr.log" || fail "honesty line must count the undecided list value: $(cat "$scratch/stderr.log")"
[ "$(last_measure)" = "dead_conflicting_prs=1" ] || fail "measure must be = 1: $(last_measure)"
ok "case15: list UNKNOWN -> view CONFLICTING + CLOSED parent -> rc 1, parent-state=CLOSED, never clean"

# --- Case 16: the re-query never decides — the list fetch AND every
# `gh pr view` answer "UNKNOWN" — while the parent issue is CLOSED. The
# sweep must fail closed: rc 2, LOUD DEAD-PR-UNRESOLVED on stderr, and no
# measure line at all (no false green). DEAD_PR_UNKNOWN_ATTEMPTS is NOT
# overridden here: the call-count assertion pins the SHIPPED default. ---
set_fixtures \
  '[{"number":4978,"title":"feat: intake reconcile","headRefName":"fix/intake","mergeable":"UNKNOWN","body":"Fixes #4945"}]' \
  4945:CLOSED
set_pr_view 4978 UNKNOWN
rc=$(run DEAD_PR_UNKNOWN_SLEEP=0)
grep -q '^rc=0$' <<<"$rc" && fail "still-undecided + CLOSED parent must never exit 0: $rc"
grep -q 'dead_conflicting_prs' "$scratch/stdout.log" && fail "fail-closed must not print a measure: $(cat "$scratch/stdout.log")"
grep -q '^rc=2$' <<<"$rc" || fail "still-undecided + CLOSED parent must exit 2 (fail closed): $rc"
grep -q 'LOUD \[DEAD-PR-UNRESOLVED\]' "$scratch/stderr.log" || fail "fail-closed must LOUD DEAD-PR-UNRESOLVED: $(cat "$scratch/stderr.log")"
grep -q 'issue view 4945' "$scratch/gh.log" || fail "the parent must be resolved before concluding: $(cat "$scratch/gh.log")"
n=$(grep -c '^pr view 4978' "$scratch/gh.log" || true)
[ "$n" = "3" ] || fail "must re-query DEAD_PR_UNKNOWN_ATTEMPTS=3 times, got $n: $(cat "$scratch/gh.log")"
ok "case16: still UNKNOWN after 3 tries + CLOSED parent -> rc 2, LOUD DEAD-PR-UNRESOLVED, no measure"

# --- Case 17: still undecided after the retries, parent issue OPEN. A live
# parent is never dead: logged, not paged, rc 0 with measure 0 — and the
# honesty line still shows the undecided value, so a blind tick is visible
# in the journal. ---
set_fixtures \
  '[{"number":4978,"title":"feat: intake reconcile","headRefName":"fix/intake","mergeable":"UNKNOWN","body":"Fixes #4945"}]' \
  4945:OPEN
set_pr_view 4978 UNKNOWN
rc=$(run DEAD_PR_UNKNOWN_SLEEP=0)
grep -q '^rc=0$' <<<"$rc" || fail "still-undecided + OPEN parent must exit 0: $rc"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] || fail "measure must be = 0: $(last_measure)"
grep -q 'issue view 4945' "$scratch/gh.log" || fail "the parent must be resolved before concluding: $(cat "$scratch/gh.log")"
grep -q 'state=OPEN' "$scratch/stderr.log" || fail "OPEN parent must be logged: $(cat "$scratch/stderr.log")"
grep -q 'unknown-mergeable=1' "$scratch/stderr.log" || fail "honesty line must count the undecided value: $(cat "$scratch/stderr.log")"
grep -q '^dead-pr:' "$scratch/stdout.log" && fail "an OPEN parent must not produce a dead-pr evidence line: $(cat "$scratch/stdout.log")"
ok "case17: still UNKNOWN + OPEN parent -> rc 0, logged, honesty line shows it, never paged"

# --- Case 18: an undecided mergeable must not resurrect the bogus-parent
# class (case 6). List UNKNOWN + a cross-repo `PR #36`-style body: no
# resolvable parent, so the PR is logged and skipped — the bogus #36 is
# never viewed and nothing is paged. ---
set_fixtures \
  '[{"number":9,"title":"feat: siterep companion","headRefName":"fix/siterep","mergeable":"UNKNOWN","body":"Companion to Nishfleet/siterep-public PR #36"}]'
set_pr_view 9 UNKNOWN
rc=$(run DEAD_PR_UNKNOWN_SLEEP=0)
grep -q '^rc=0$' <<<"$rc" || fail "undecided + no resolvable parent must be skipped, not paged: $rc"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] || fail "measure must be = 0: $(last_measure)"
grep -q 'issue view 36' "$scratch/gh.log" && fail "bogus parent #36 must never be viewed: $(cat "$scratch/gh.log")"
grep -q 'no resolvable parent' "$scratch/stderr.log" || fail "skipped PR must be logged: $(cat "$scratch/stderr.log")"
ok "case18: undecided mergeable + cross-repo PR ref -> no parent, skipped, never paged"

# --- Case 19 (fleet-ops#5079): the other undecided shape the issue names
# — `mergeable: null` in `gh pr list` — for a PR whose parent issue is
# CLOSED. Same contract as case 15: counted in `unknown-mergeable`, kept
# in the scan, re-queried with `gh pr view` (which here answers
# CONFLICTING), then dead-classified by the parent. It must never exit 0
# with dead_conflicting_prs=0. ---
set_fixtures \
  '[{"number":4978,"title":"feat: intake reconcile","headRefName":"fix/intake","mergeable":null,"body":"Fixes #4945"}]' \
  4945:CLOSED
set_pr_view 4978 CONFLICTING
rc=$(run DEAD_PR_UNKNOWN_SLEEP=0)
grep -q '^rc=0$' <<<"$rc" && fail "null mergeable must never exit 0: $rc: $(cat "$scratch/stdout.log")"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] && fail "null mergeable must never read dead_conflicting_prs=0: $(cat "$scratch/stdout.log")"
grep -q '^rc=1$' <<<"$rc" || fail "null mergeable re-queried to CONFLICTING + CLOSED parent must exit 1: $rc"
grep -q 'pr view 4978' "$scratch/gh.log" || fail "null mergeable must be re-queried with gh pr view: $(cat "$scratch/gh.log")"
grep -q 'unknown-mergeable=1' "$scratch/stderr.log" || fail "honesty line must count the null list value: $(cat "$scratch/stderr.log")"
grep -q 'parent=4945 parent-state=CLOSED' "$scratch/stdout.log" || fail "evidence line must name parent 4945 CLOSED: $(cat "$scratch/stdout.log")"
[ "$(last_measure)" = "dead_conflicting_prs=1" ] || fail "measure must be = 1: $(last_measure)"
ok "case19: list mergeable null -> view CONFLICTING + CLOSED parent -> rc 1, parent-state=CLOSED, never clean"

# --- Case 20 (fleet-ops#5205a): CONFLICTING + OPEN parent with the
# first-seen marker older than the bound -> stale-conflicting: rc 1, a
# `stale-conflicting-pr:` evidence line, the `stale_conflicting_prs=1`
# measure line, `dead_conflicting_prs=0` still LAST, the PR on the flagged
# list for red-pr-repair, and the marker kept (the PR is still in class). ---
set_fixtures \
  '[{"number":4830,"title":"seat: deepseek last-resort","headRefName":"claim/issue-4625","mergeable":"CONFLICTING","body":"Closes #4625"}]' \
  4625:OPEN
printf '%s\n' "$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  >"$scratch/state/fleet-ops-4830.first-seen"
rc=$(run)
grep -q '^rc=1$' <<<"$rc" || fail "case20: stale-conflicting must exit 1 like the dead class: $rc"
grep -q '^stale-conflicting-pr: 4830 ' "$scratch/stdout.log" \
  || fail "case20: must emit a stale-conflicting-pr evidence line: $(cat "$scratch/stdout.log")"
grep -q 'parent=4625' "$scratch/stdout.log" || fail "case20: evidence line must name parent=4625: $(cat "$scratch/stdout.log")"
grep -q 'first-seen=' "$scratch/stdout.log" || fail "case20: evidence line must carry first-seen: $(cat "$scratch/stdout.log")"
grep -q '^stale_conflicting_prs=1$' "$scratch/stdout.log" \
  || fail "case20: measure must be stale_conflicting_prs=1: $(cat "$scratch/stdout.log")"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] \
  || fail "case20: dead_conflicting_prs=0 must still be the LAST stdout line: $(last_measure)"
grep -qx 'Nishfleet/fleet-ops 4830 4625' "$scratch/state/stale-conflicting.list" \
  || fail "case20: flagged list must carry the PR for red-pr-repair: $(cat "$scratch/state/stale-conflicting.list")"
[ -f "$scratch/state/fleet-ops-4830.first-seen" ] \
  || fail "case20: marker must be kept while the PR stays in class"
grep -q 'stale-conflicting=1' "$scratch/stderr.log" \
  || fail "case20: scan-done line must count stale-conflicting=1: $(cat "$scratch/stderr.log")"
ok "case20: CONFLICTING + OPEN parent, first-seen 25h > 24h bound -> flagged, rc 1, on the repair-suppression list"

# --- Case 21 (fleet-ops#5205b): same shape but inside the bound -> NOT
# flagged. Marker kept (the clock keeps running), flagged list written
# empty, rc 0. ---
set_fixtures \
  '[{"number":4830,"title":"seat: deepseek last-resort","headRefName":"claim/issue-4625","mergeable":"CONFLICTING","body":"Closes #4625"}]' \
  4625:OPEN
printf '%s\n' "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  >"$scratch/state/fleet-ops-4830.first-seen"
rc=$(run)
grep -q '^rc=0$' <<<"$rc" || fail "case21: inside-bound conflict must exit 0: $rc"
grep -q '^stale_conflicting_prs=0$' "$scratch/stdout.log" \
  || fail "case21: measure must be stale_conflicting_prs=0: $(cat "$scratch/stdout.log")"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] || fail "case21: last measure must be dead_conflicting_prs=0: $(last_measure)"
[ -f "$scratch/state/fleet-ops-4830.first-seen" ] \
  || fail "case21: marker must survive while the PR stays in class"
[ -f "$scratch/state/stale-conflicting.list" ] \
  || fail "case21: flagged list must be written even when empty"
[ -s "$scratch/state/stale-conflicting.list" ] \
  && fail "case21: flagged list must be empty inside the bound: $(cat "$scratch/state/stale-conflicting.list")"
grep -q 'inside 24h bound' "$scratch/stderr.log" \
  || fail "case21: inside-bound conflict must be logged: $(cat "$scratch/stderr.log")"
ok "case21: CONFLICTING + OPEN parent, first-seen 1h < 24h bound -> not flagged, rc 0, marker kept"

# --- Case 22: no marker yet -> the first observation writes first-seen
# and does NOT flag (the bound cannot be crossed on the same tick the
# conflict is first seen). A second run inside the bound stays clean and
# keeps the SAME first-seen (the clock does not reset per tick). ---
set_fixtures \
  '[{"number":5074,"title":"fix: slowburn terminus","headRefName":"claim/issue-4773","mergeable":"CONFLICTING","body":"Closes #4773"}]' \
  4773:OPEN
rc=$(run)
grep -q '^rc=0$' <<<"$rc" || fail "case22: first observation must exit 0: $rc"
grep -q 'conflict first seen' "$scratch/stderr.log" \
  || fail "case22: first-seen write must be logged: $(cat "$scratch/stderr.log")"
fs1="$(cat "$scratch/state/fleet-ops-5074.first-seen" 2>/dev/null)"
[ -n "$fs1" ] || fail "case22: first-seen marker must be written"
rc=$(run)
grep -q '^rc=0$' <<<"$rc" || fail "case22: second tick inside bound must exit 0: $rc"
fs2="$(cat "$scratch/state/fleet-ops-5074.first-seen" 2>/dev/null)"
[ "$fs1" = "$fs2" ] || fail "case22: first-seen must not reset between ticks ($fs1 -> $fs2)"
grep -q '^stale_conflicting_prs=0$' "$scratch/stdout.log" || fail "case22: still inside bound: $(cat "$scratch/stdout.log")"
ok "case22: first observation writes the marker without flagging; the clock persists across ticks"

# --- Case 23 (GC): markers for PRs that left the class are pruned by the
# same scan — a dead-classified PR, a MERGEABLE PR, and a vanished PR all
# lose their markers; the flagged list rewrites empty. The dead class
# itself is untouched (parent CLOSED still dead-flags, rc 1). ---
set_fixtures \
  '[{"number":9,"title":"feat: cloud upload v2","headRefName":"fix/cloud-upload","mergeable":"CONFLICTING","body":"Fixes #595"},{"number":66,"title":"feat: b","headRefName":"fix/b","mergeable":"MERGEABLE","body":"Fixes #1941"}]' \
  595:CLOSED
for gone in fleet-ops-9 fleet-ops-66 fleet-ops-999; do
  printf '%s\n' "$(date -u -d '30 hours ago' +%Y-%m-%dT%H:%M:%SZ)" >"$scratch/state/$gone.first-seen"
done
printf 'Nishfleet/fleet-ops 999 888\n' >"$scratch/state/stale-conflicting.list"
rc=$(run)
grep -q '^rc=1$' <<<"$rc" || fail "case23: dead class must still exit 1: $rc"
[ "$(last_measure)" = "dead_conflicting_prs=1" ] || fail "case23: dead measure must be 1: $(last_measure)"
for gone in fleet-ops-9 fleet-ops-66 fleet-ops-999; do
  [ ! -f "$scratch/state/$gone.first-seen" ] \
    || fail "case23: marker $gone must be pruned (PR left the class or vanished)"
done
[ -s "$scratch/state/stale-conflicting.list" ] \
  && fail "case23: flagged list must rewrite to this scan's set (empty): $(cat "$scratch/state/stale-conflicting.list")"
grep -q '^stale_conflicting_prs=0$' "$scratch/stdout.log" || fail "case23: stale measure must be 0"
ok "case23: GC prunes markers for dead/mergeable/vanished PRs; dead class unchanged"

# --- Case 24 (bound edge): a first-seen exactly DEAD_PR_STALE_HOURS old
# crosses the bound (age >= bound) -> flagged. ---
set_fixtures \
  '[{"number":4830,"title":"seat: deepseek last-resort","headRefName":"claim/issue-4625","mergeable":"CONFLICTING","body":"Closes #4625"}]' \
  4625:OPEN
printf '%s\n' "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  >"$scratch/state/fleet-ops-4830.first-seen"
rc=$(run)
grep -q '^rc=1$' <<<"$rc" || fail "case24: conflict exactly at the bound must flag: $rc"
grep -q '^stale_conflicting_prs=1$' "$scratch/stdout.log" || fail "case24: stale measure must be 1: $(cat "$scratch/stdout.log")"
ok "case24: first-seen exactly 24h old -> flagged (age >= bound)"

# --- Case 25 (unreadable marker): a corrupt first-seen file must never
# flag on a guess and must never hide the conflict forever — the detector
# LOUDs DEAD-PR-STATE, resets the clock to now, and the PR stays inside
# the bound this tick. ---
set_fixtures \
  '[{"number":4830,"title":"seat: deepseek last-resort","headRefName":"claim/issue-4625","mergeable":"CONFLICTING","body":"Closes #4625"}]' \
  4625:OPEN
printf 'not-a-timestamp\n' >"$scratch/state/fleet-ops-4830.first-seen"
rc=$(run)
grep -q '^rc=0$' <<<"$rc" || fail "case25: corrupt marker must not flag: $rc"
grep -q 'DEAD-PR-STATE' "$scratch/stderr.log" \
  || fail "case25: corrupt marker must LOUD DEAD-PR-STATE: $(cat "$scratch/stderr.log")"
date -u -d "$(cat "$scratch/state/fleet-ops-4830.first-seen")" +%s >/dev/null 2>&1 \
  || fail "case25: corrupt marker must be reset to a parseable timestamp"
grep -q '^stale_conflicting_prs=0$' "$scratch/stdout.log" || fail "case25: corrupt marker resets inside bound: $(cat "$scratch/stdout.log")"
ok "case25: corrupt marker -> LOUD + self-heal reset, never a guessed flag"

# --- No agent names anywhere in detector output ---
grep -qiE '(^|[[:space:]])(by|with|via|from|using|through|used)[[:space:]]+(the[[:space:]]+)?(claude|codex|devin|cursor|grok|openai|anthropic|deepseek|minimax|copilot|gemini|opus|chatgpt|fable|luna|sol)([^a-z]|$)' \
    "$scratch/stdout.log" "$scratch/stderr.log" \
    && fail "agent attribution in detector output"
grep -qiE '(^|[[:space:]])(by|with|via|from|using|through|used)[[:space:]]+(the[[:space:]]+)?(claude|codex|devin|cursor|grok|openai|anthropic|deepseek|minimax|copilot|gemini|opus|chatgpt|fable|luna|sol)([^a-z]|$)' \
    "$bin" \
    && fail "agent attribution in detector source"
ok "no agent names in detector output or source"

rm -rf "$scratch"
echo "all fleet-dead-pr-detector cases passed"