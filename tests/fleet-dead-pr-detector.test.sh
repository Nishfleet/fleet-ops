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
#      0b. PR-marked refs — `PR #N`, `pull #N`, `pull request #N` (a PR
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
# Measure line `dead_conflicting_prs=<n>` is the LAST stdout line.
# Exit codes: 0 clean, 1 when at least one dead conflicting PR is
# proven, 2 on gh/jq infra failure (fail-closed, never a false green).

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
    # $scratch/stderr.log; prints rc=<n> on stdout.
    local rc
    set +e
    env GH="$scratch/bin/gh" DEAD_PR_REPO="Nishfleet/fleet-ops" "$@" \
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
    for kv in "$@"; do
        n="${kv%%:*}"
        s="${kv#*:}"
        printf '{"state":"%s","title":"issue %s"}\n' "$s" "$n" \
            >"$scratch/issue-$n.json"
    done
    : >"$scratch/gh.log"
    : >"$scratch/stdout.log"
    : >"$scratch/stderr.log"
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

# --- Case 11: no conflicting PRs (MERGEABLE/CLEAN) -> clean sweep ---
set_fixtures \
  '[{"number":65,"title":"feat: a","headRefName":"fix/a","mergeable":"MERGEABLE","body":"Fixes #595"},{"number":66,"title":"feat: b","headRefName":"fix/b","mergeable":"CLEAN","body":"Fixes #1941"}]'
rc=$(run)
grep -q '^rc=0$' <<<"$rc" || fail "no conflicting PRs must exit 0: $rc"
[ "$(last_measure)" = "dead_conflicting_prs=0" ] || fail "measure must be = 0: $(last_measure)"
grep -q 'issue view' "$scratch/gh.log" && fail "non-conflicting PRs must not be resolved at all: $(cat "$scratch/gh.log")"
ok "case11: MERGEABLE/CLEAN PRs only -> dead_conflicting_prs=0, exit 0, no issue views"

# --- Case 12: gh pr list fails (shim exit 2) -> fail-closed rc 2, loud
# on stderr, no false green ---
set_fixtures '[]'
out=$(env GH="$scratch/bin/gh" DEAD_PR_REPO="Nishfleet/fleet-ops" \
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