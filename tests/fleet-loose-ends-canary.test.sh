#!/usr/bin/env bash
# tests/fleet-loose-ends-canary.test.sh
#
# fleet-ops#528: sr-nothing-half-done enforcer. Three detection
# classes (unanswered questions, stale worker PRs, stale worktrees)
# share one classifier and one observe-to-open / observe-to-close
# drain. Offline. Live gh and systemctl are stubbed. Proves:
#
#   1. QUESTIONS.md OPEN row -> nag finding, parse clean, file.
#   2. QUESTIONS.md ANSWERED row -> not a nag target.
#   3. QUESTIONS.md HOLD past return date -> expired-hold finding.
#   4. QUESTIONS.md malformed row -> LOUD parse error, NOT silent.
#   5. Open worker PR >24h without auto-merge -> stale-worker-pr finding.
#   6. Open worker PR <24h -> skipped_fresh, NOT a finding.
#   7. Human PR (nish3451, branch=main) >24h -> skipped_human, NOT a finding.
#   8. Worker PR with autoMerge.enabled=true >24h -> skipped (green-in-flight).
#   9. Draft worker PR >24h -> skipped_draft, NOT a finding.
#  10. Stale worktree with no live unit -> finding.
#  11. Worktree touched by live worker unit -> skipped_live.
#  12. Fresh worktree (<24h) -> skipped_fresh.
#  13. Auto-file dedupes the marker on a second run.
#  14. Observe-to-close: a green tick comments resolved-at on a previously
#      filed slug that is no longer a finding; a later tick with that
#      marker closes; a still-dirty slug is neither commented nor closed.
#  15. Watcher broken: missing helper / bad fixture / no enrolled repos
#      fails loud.
#  16. Contracts: prompts/worker.md, heartbeat-tier1 wiring, MANIFEST,
#      matrix enforced, no bin/loose-ends dispatcher.
#  17. FILE=1 against a scratch QUESTIONS.md (the #1596 "Back again"
#      fixture) must NOT invoke gh issue create, and must LOUD
#      LOOSE-ENDS-NONCANONICAL-FILE (fleet-ops#1670 / #1596).
#  18. FILE=1 against a QUESTIONS.md under the canonical dir still files.
#  19. Bulk gh issue list must not request the comments field (HTTP 504
#      on a comment-storm issue blocked observe-to-close of #1596).
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-loose-ends-canary"
lib="$repo_root/lib/loose-ends.py"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
worker="$repo_root/prompts/worker.md"
matrix="$repo_root/config/rule-enforcement.json"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$tier1" ]] || fail "missing $tier1"
[[ -f "$worker" ]] || fail "missing $worker"
[[ -f "$matrix" ]] || fail "missing $matrix"
[[ -f "$manifest" ]] || fail "missing $manifest"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t loose-ends-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_LOOSE_ENDS_LIB="$lib"
export FLEET_LOOSE_ENDS_ISSUE_REPO="Nishfleet/fleet-ops"
export FLEET_LOOSE_ENDS_FILE="0"
export FLEET_LOOSE_ENDS_CLOSE="0"
export FLEET_LOOSE_ENDS_SCAN_PRS="0"
export FLEET_LOOSE_ENDS_SCAN_WORKTREES="0"
export FLEET_LOOSE_ENDS_NOW="2026-08-28T12:00:00Z"
export FLEET_LOOSE_ENDS_IDLE_HOURS="24"
export FLEET_LOOSE_ENDS_NAG_HOURS="24"

# Stub gh (PRs are scanned OFF by default; this stub is only here for the
# observe-to-open / observe-to-close path).
gh_store="$scratch/gh-issues"
mkdir -p "$gh_store"
cat >"$scratch/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
store="${GH_MOCK_STORE:?}"
cmd="$1"; shift
case "$cmd" in
  issue)
    sub="$1"; shift
    case "$sub" in
      create)
        title=""; body=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --title) title="$2"; shift 2 ;;
            --body) body="$2"; shift 2 ;;
            --body-file) body=$(cat "$2"); shift 2 ;;
            --repo|-R) shift 2 ;;
            *) shift ;;
          esac
        done
        printf 'create %s\n' "$title" >>"$store/creates"
        n=$(find "$store" -maxdepth 1 -name 'issue-*.body' | wc -l)
        f="$store/issue-$((n+1)).body"
        printf '%s\n' "$title" > "$f"
        printf '%s\n' "$body" >> "$f"
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        ;;
      comment)
        num=""; body=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --body) body="$2"; shift 2 ;;
            --repo|-R) shift 2 ;;
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift ;;
          esac
        done
        printf '%s\n' "$body" >"$store/issue-${num}.comments"
        printf '%s\n' "$num" >>"$store/commented"
        echo "https://github.com/Nishfleet/fleet-ops/issues/${num}#issuecomment-1"
        ;;
      list)
        # Record the --json field list so the #1596 504 regression can
        # assert the bulk list never asks for comments.
        printf '%s\n' "$*" >>"$store/list-args"
        printf '[\n'
        first=1
        for f in "$store"/issue-*.body; do
          [ -f "$f" ] || continue
          num=$(basename "$f" .body); num=${num#issue-}
          [ -f "$store/issue-${num}.closed" ] && continue
          body=$(tail -n +2 "$f")
          comments_file="$store/issue-${num}.comments"
          if [ -f "$comments_file" ]; then
            comments_json=$(python3 -c 'import json,sys;print(json.dumps([{"body": sys.stdin.read()}]))' <"$comments_file")
          else
            comments_json='[]'
          fi
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"title":"","body":%s,"comments":%s}' "$num" \
            "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")" "$comments_json"
        done
        printf '\n]\n'
        ;;
      view)
        num=""
        json_fields=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --json) json_fields="$2"; shift 2 ;;
            --repo|-R) shift 2 ;;
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift ;;
          esac
        done
        [ -n "$num" ] || exit 1
        comments_file="$store/issue-${num}.comments"
        if [ -f "$comments_file" ]; then
          comments_json=$(python3 -c 'import json,sys;print(json.dumps([{"body": sys.stdin.read()}]))' <"$comments_file")
        else
          comments_json='[]'
        fi
        body_file="$store/issue-${num}.body"
        if [ -f "$body_file" ]; then
          body=$(tail -n +2 "$body_file")
        else
          body=""
        fi
        printf '{"number":%s,"body":%s,"comments":%s}\n' "$num" \
          "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")" "$comments_json"
        ;;
      close)
        num=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --reason|--comment|--repo|-R) shift 2 ;;
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift ;;
          esac
        done
        [ -n "$num" ] || exit 1
        : > "$store/issue-${num}.closed"
        printf '%s\n' "$num" >>"$store/closed"
        echo "Closed issue #$num"
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/gh"
export GH="$scratch/gh"
export GH_MOCK_STORE="$gh_store"

write_questions() {
    local path="$1"; shift
    cat >"$path" <<'MD'
# QUESTIONS LEDGER

| Asked | Question | Asked-by | Status |
|---|---|---|---|
| 2026-08-20 | Resolved row, ignore | claude-mac | ANSWERED 2026-08-20 (proof run, telegram receipt logged) |
| 2026-08-20 | Stale token ask | claude-mac | OPEN |
| 2026-08-21 | Expired hold, ignore | claude-mac | HOLD until=2026-08-25 |
| 2026-08-22 | Malformed row, must LOUD | badrow |
| 2026-08-23 | Future hold, not yet expired | claude-mac | HOLD until=2026-12-01 |
MD
}

run_nag() {
    local qpath="$1"
    FLEET_LOOSE_ENDS_QUESTIONS="$qpath" \
        FLEET_LOOSE_ENDS_SCAN_PRS="0" \
        FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
        FLEET_LOOSE_ENDS_FILE="0" \
        FLEET_LOOSE_ENDS_CLOSE="0" \
        set +e
    "$bin" --nag-only >"$scratch/nag.out" 2>"$scratch/nag.err"
    rc=$?
    set -e
    return "$rc"
}

# --- 1. QUESTIONS.md OPEN row -> nag finding, parse clean ----------------
write_questions "$scratch/q.md"
set +e
out=$(FLEET_LOOSE_ENDS_QUESTIONS="$scratch/q.md" \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
    FLEET_LOOSE_ENDS_FILE="0" FLEET_LOOSE_ENDS_CLOSE="0" \
    "$bin" --nag-only 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "1: nag-only must exit 0 on findings (got $rc)"
nag_count=$(grep -c '^\[.*\] \[LOOSE-ENDS-NAG\]' "$scratch/triage.md" || true)
[[ "$nag_count" -ge 1 ]] || fail "1: expected at least one LOOSE-ENDS-NAG line, got $nag_count"
grep -q 'questions.md:L' "$scratch/triage.md" || fail "1: triage missing slug"
ok "1: QUESTIONS.md OPEN row detected and nagged"

# --- 2. QUESTIONS.md ANSWERED row -> not a nag target --------------------
write_questions "$scratch/q.md"
: >"$triage"
FLEET_LOOSE_ENDS_QUESTIONS="$scratch/q.md" \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
    FLEET_LOOSE_ENDS_FILE="0" FLEET_LOOSE_ENDS_CLOSE="0" \
    "$bin" --nag-only >/dev/null 2>&1
if grep -q 'Resolved row' "$scratch/triage.md"; then
    fail "2: ANSWERED row must not be nagged"
fi
ok "2: QUESTIONS.md ANSWERED row skipped"

# --- 3. QUESTIONS.md HOLD past return date -> expired-hold finding -------
write_questions "$scratch/q.md"
: >"$triage"
FLEET_LOOSE_ENDS_QUESTIONS="$scratch/q.md" \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
    FLEET_LOOSE_ENDS_FILE="0" FLEET_LOOSE_ENDS_CLOSE="0" \
    "$bin" --nag-only >/dev/null 2>&1
grep -q 'expired-hold' "$scratch/triage.md" || fail "3: HOLD past return date must surface"
grep -q 'questions.md:L' "$scratch/triage.md" || fail "3: triage missing expired-hold slug"
# And the future hold must NOT show up.
if grep -q 'Future hold' "$scratch/triage.md"; then
    fail "3: future HOLD must not nag yet"
fi
ok "3: expired HOLD detected, future HOLD skipped"

# --- 4. QUESTIONS.md malformed row -> LOUD parse error --------------------
write_questions "$scratch/q.md"
: >"$triage"
FLEET_LOOSE_ENDS_QUESTIONS="$scratch/q.md" \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
    FLEET_LOOSE_ENDS_FILE="0" FLEET_LOOSE_ENDS_CLOSE="0" \
    "$bin" --nag-only >/dev/null 2>&1
grep -q 'LOOSE-ENDS-QUESTIONS-PARSE' "$scratch/triage.md" \
    || fail "4: malformed row must surface as LOUD parse error"
ok "4: malformed QUESTIONS.md row LOUD"

# Now build fixtures for the PR classifier ---------------------------------
NOW=1787918400  # 2026-08-28T12:00:00Z
OLD="$NOW"; OLD_TS=$(python3 -c "import datetime;print(datetime.datetime.fromtimestamp($OLD-30*3600,datetime.timezone.utc).isoformat().replace('+00:00','Z'))")
FRESH_TS=$(python3 -c "import datetime;print(datetime.datetime.fromtimestamp($NOW-1*3600,datetime.timezone.utc).isoformat().replace('+00:00','Z'))")
NEW_DRAFT_TS=$(python3 -c "import datetime;print(datetime.datetime.fromtimestamp($NOW-2*3600,datetime.timezone.utc).isoformat().replace('+00:00','Z'))")

cat >"$scratch/prs.json" <<JSON
[
  {"repo":"Nishfleet/fleet-ops","number":10,"title":"stale worker","url":"https://x/10","createdAt":"${OLD_TS}","headRefName":"claim/issue-10","isDraft":false,"author":{"login":"nishfleet-worker[bot]"}},
  {"repo":"Nishfleet/fleet-ops","number":11,"title":"fresh worker","url":"https://x/11","createdAt":"${FRESH_TS}","headRefName":"claim/issue-11","isDraft":false,"author":{"login":"nishfleet-worker[bot]"}},
  {"repo":"Nishfleet/fleet-ops","number":12,"title":"human PR","url":"https://x/12","createdAt":"${OLD_TS}","headRefName":"main","isDraft":false,"author":{"login":"nish3451"}},
  {"repo":"Nishfleet/fleet-ops","number":13,"title":"worker auto-merge on","url":"https://x/13","createdAt":"${OLD_TS}","headRefName":"claim/issue-13","isDraft":false,"author":{"login":"nishfleet-worker[bot]"},"autoMergeRequest":{"enabled":true}},
  {"repo":"Nishfleet/fleet-ops","number":14,"title":"worker draft","url":"https://x/14","createdAt":"${OLD_TS}","headRefName":"claim/issue-14","isDraft":true,"author":{"login":"nishfleet-worker[bot]"}}
]
JSON

run_prs() {
    set +e
    env -u FLEET_LOOSE_ENDS_NAG_HOURS \
        FLEET_LOOSE_ENDS_PRS_FILE="$scratch/prs.json" \
        FLEET_LOOSE_ENDS_QUESTIONS="$scratch/empty-q.md" \
        FLEET_LOOSE_ENDS_SCAN_PRS="1" \
        FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
        FLEET_LOOSE_ENDS_FILE="0" \
        FLEET_LOOSE_ENDS_CLOSE="0" \
        "$bin" --prs-only >"$scratch/p.out" 2>"$scratch/p.err"
    rc=$?
    set -e
    return "$rc"
}

# --- 5-9. PR classifier matrix --------------------------------------------
: >"$scratch/empty-q.md"
run_prs
grep -q 'prs: findings=1' "$scratch/p.err" || fail "5: stale worker PR must be a finding"
grep -q 'LOOSE-ENDS-STALE-PR' "$scratch/triage.md" || fail "5: stale worker PR must LOUD"
grep -q 'Nishfleet/fleet-ops#10' "$scratch/triage.md" || fail "5: stale PR #10 must appear"
ok "5: stale worker PR detected"
if grep -q 'Nishfleet/fleet-ops#11' "$scratch/triage.md"; then
    fail "6: fresh worker PR must be skipped"
fi
ok "6: fresh worker PR skipped"
if grep -q 'Nishfleet/fleet-ops#12' "$scratch/triage.md"; then
    fail "7: human PR must be skipped"
fi
ok "7: human PR skipped"
if grep -q 'Nishfleet/fleet-ops#13' "$scratch/triage.md"; then
    fail "8: auto-merge-on PR must be skipped (green in flight)"
fi
ok "8: auto-merge-on PR skipped"
if grep -q 'Nishfleet/fleet-ops#14' "$scratch/triage.md"; then
    fail "9: draft PR must be skipped"
fi
ok "9: draft PR skipped"

# --- 10-12. Worktree classifier -------------------------------------------
cat >"$scratch/wts.json" <<JSON
[
  {"path":"/tmp/wt-stale","branch":"claim/issue-99","last_commit_ts":$((NOW-30*3600)),"dirty":false,"live":false,"unit":""},
  {"path":"/tmp/wt-dirty","branch":"claim/issue-100","last_commit_ts":$((NOW-30*3600)),"dirty":true,"live":false,"unit":""},
  {"path":"/tmp/wt-fresh","branch":"claim/issue-101","last_commit_ts":$((NOW-1*3600)),"dirty":false,"live":false,"unit":""},
  {"path":"/tmp/wt-live","branch":"claim/issue-102","last_commit_ts":$((NOW-30*3600)),"dirty":true,"live":true,"unit":"pi-issue-fleet-ops-102"}
]
JSON
printf 'pi-issue-fleet-ops-102\n' >"$scratch/live.txt"

run_wt() {
    set +e
    env -u FLEET_LOOSE_ENDS_NAG_HOURS \
        FLEET_LOOSE_ENDS_WORKTREES_FILE="$scratch/wts.json" \
        FLEET_LOOSE_ENDS_LIVE_UNITS_FILE="$scratch/live.txt" \
        FLEET_LOOSE_ENDS_QUESTIONS="$scratch/empty-q.md" \
        FLEET_LOOSE_ENDS_SCAN_PRS="0" \
        FLEET_LOOSE_ENDS_SCAN_WORKTREES="1" \
        FLEET_LOOSE_ENDS_FILE="0" \
        FLEET_LOOSE_ENDS_CLOSE="0" \
        "$bin" --worktrees-only >"$scratch/w.out" 2>"$scratch/w.err"
    rc=$?
    set -e
    return "$rc"
}
: >"$triage"
run_wt
grep -q 'worktrees: findings=2' "$scratch/w.err" || fail "10: stale + dirty must be findings"
grep -q 'claim/issue-99' "$scratch/triage.md" || fail "10: stale worktree must appear"
grep -q 'claim/issue-100' "$scratch/triage.md" || fail "10: dirty worktree must appear"
ok "10: stale worktree detected"
if grep -q 'claim/issue-102' "$scratch/triage.md"; then
    fail "11: live worker unit must exempt"
fi
ok "11: live worker unit exempts worktree"
if grep -q 'claim/issue-101' "$scratch/triage.md"; then
    fail "12: fresh worktree must be skipped"
fi
ok "12: fresh worktree skipped"

# --- 12b. LIVE WALK (JSONL → array) must not crash -------------------------
# The fixture path above feeds a hand-written JSON array. The LIVE path
# walks WORKTREES_ROOT and appends one bare object per worktree; if that
# file is not coalesced into a single JSON array, >=2 worktrees make it
# invalid JSON and lib/loose-ends.py json.loads() raises "Extra data" →
# rc=2 → LOOSE-ENDS-BROKEN → fleet-heartbeat.service fails every tick
# (fleet-ops#528 live regression). This test proves the live walk emits a
# valid single-document array and the helper classifies without breaking.
wt_root="$scratch/livewt"
mkdir -p "$wt_root/a" "$wt_root/b" "$wt_root/c"
for d in "$wt_root/a" "$wt_root/b" "$wt_root/c"; do
    git init -q "$d"
    mkdir -p "$d/.git/refs/heads"
    printf 'ref: refs/heads/claim/issue-%s\n' "$(basename "$d")" >"$d/.git/HEAD"
done
set +e
env -u FLEET_LOOSE_ENDS_NAG_HOURS \
    FLEET_LOOSE_ENDS_WORKTREES_ROOT="$wt_root" \
    FLEET_LOOSE_ENDS_WORKTREES_FILE= \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" \
    FLEET_LOOSE_ENDS_SCAN_WORKTREES="1" \
    FLEET_LOOSE_ENDS_FILE="0" FLEET_LOOSE_ENDS_CLOSE="0" \
    "$bin" --worktrees-only >"$scratch/w2.out" 2>"$scratch/w2.err"
w2_rc=$?
set -e
if [ "$w2_rc" -ne 0 ] || grep -q 'LOOSE-ENDS-BROKEN' "$scratch/w2.err"; then
    echo "w2 rc=$w2_rc" >&2
    tail -5 "$scratch/w2.err" >&2
    fail "12b: live walk (JSONL→array) must not crash"
fi
grep -Eq 'worktrees: scanned=[0-9]+' "$scratch/w2.err" \
    || fail "12b: live walk must report a scan count"
ok "12b: live walk (JSONL→array) does not break"

# --- 13. Auto-file dedupes the marker -------------------------------------
# Use a fake already-open issue that carries our marker and re-run.
cat >"$scratch/q.md" <<'MD'
# Q
| Asked | Question | Asked-by | Status |
|---|---|---|---|
| 2026-08-20 | Stale token ask | claude-mac | OPEN |
MD
: >"$scratch/gh-issues/issue-77.body"
printf 'fix(loose-ends): open-question — questions.md:L20:2026-08-20\n\nThe canary already filed this.\n\nloose-ends-canary: questions.md:L20:2026-08-20 open-question\n\nsignal: rule-enforcement/sr-nothing-half-done\n' >"$scratch/gh-issues/issue-77.body"
: >"$triage"
env -u FLEET_LOOSE_ENDS_NAG_HOURS \
    FLEET_LOOSE_ENDS_QUESTIONS="$scratch/q.md" \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
    FLEET_LOOSE_ENDS_FILE="1" FLEET_LOOSE_ENDS_CLOSE="0" \
    "$bin" --nag-only >/dev/null 2>&1
n_issue=$(find "$scratch/gh-issues" -name 'issue-*.body' | wc -l)
[[ "$n_issue" -eq 1 ]] || fail "13: dedup must keep # of filed issues at 1 (got $n_issue)"
ok "13: auto-file dedupes the marker"

# --- 14. Observe-to-close two-tick shape ---------------------------------
# Tick 1: previously filed slug is still a finding -> comment resolved-at.
# Tick 2: same slug no longer a finding -> close.
# Tick 3: still-dirty slug stays untouched.
printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$scratch/ts"
TICK1_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$scratch/gh-issues"
: >"$scratch/gh-issues/issue-100.body"
cat >"$scratch/gh-issues/issue-100.body" <<EOF
fix(loose-ends): open-question — questions.md:L20:2026-08-20

Previously filed.

loose-ends-canary: questions.md:L20:2026-08-20 open-question

signal: rule-enforcement/sr-nothing-half-done
EOF
cat >"$scratch/q-empty.md" <<'EOF'
# Q
| Asked | Question | Asked-by | Status |
|---|---|---|---|
EOF
: >"$triage"
env -u FLEET_LOOSE_ENDS_NAG_HOURS \
    FLEET_LOOSE_ENDS_QUESTIONS="$scratch/q-empty.md" \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
    FLEET_LOOSE_ENDS_FILE="1" FLEET_LOOSE_ENDS_CLOSE="1" \
    "$bin" --nag-only >/dev/null 2>&1
[[ -f "$scratch/gh-issues/issue-100.comments" ]] || fail "14a: tick 1 must comment resolved-at"
grep -q 'resolved-at: signal: rule-enforcement/sr-nothing-half-done' \
    "$scratch/gh-issues/issue-100.comments" \
    || fail "14a: tick 1 comment must carry resolved-at marker"
ok "14a: tick 1 comments resolved-at on a clean finding"

# Tick 2: same empty questions.md; marker is already there -> close.
env -u FLEET_LOOSE_ENDS_NAG_HOURS \
    FLEET_LOOSE_ENDS_QUESTIONS="$scratch/q-empty.md" \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
    FLEET_LOOSE_ENDS_FILE="1" FLEET_LOOSE_ENDS_CLOSE="1" \
    "$bin" --nag-only >/dev/null 2>&1
[[ -f "$scratch/gh-issues/issue-100.closed" ]] || fail "14b: tick 2 must close the issue"
ok "14b: tick 2 closes the resolved issue"

# Tick 3: a still-dirty slug stays untouched (no comment, no close).
# We REOPEN the issue so the closed marker does not bleed from tick 2;
# the live gh list stub already filters closed issues, but here we want
# to assert the canary does not re-close or re-comment.
# The OPEN row must sit on the SAME line number as the previously-filed
# slug (L20) — otherwise the canary correctly observes a new slug and
# re-files, which is not what this test asserts.
{
    for i in $(seq 1 19); do printf '# filler %d\n' "$i"; done
    printf '| 2026-08-20 | Back again | claude-mac | OPEN |\n'
} >"$scratch/q-dirty.md"
: >"$scratch/gh-issues/issue-100.comments"
rm -f "$scratch/gh-issues/issue-100.closed"   # un-close so we measure only tick 3's actions
env -u FLEET_LOOSE_ENDS_NAG_HOURS \
    FLEET_LOOSE_ENDS_QUESTIONS="$scratch/q-dirty.md" \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
    FLEET_LOOSE_ENDS_FILE="1" FLEET_LOOSE_ENDS_CLOSE="1" \
    "$bin" --nag-only >"$scratch/tick3.out" 2>"$scratch/tick3.err"
[[ ! -f "$scratch/gh-issues/issue-100.closed" ]] || { cat "$scratch/tick3.err" >&2; fail "14c: still-dirty slug must NOT close"; }
[[ ! -s "$scratch/gh-issues/issue-100.comments" ]] \
    || { cat "$scratch/gh-issues/issue-100.comments" >&2; fail "14c: still-dirty slug must NOT comment"; }
ok "14c: still-dirty slug stays untouched"

# --- 15. Watcher broken: missing helper / bad fixture / no enrolled repos
# (We test the helper-missing path; the others are covered by the inline
# loud log lines in the canary itself.)
LIB_BAK="$lib"
mv "$lib" "$scratch/lib.bak"
set +e
FLEET_LOOSE_ENDS_LIB="" \
    FLEET_LOOSE_ENDS_QUESTIONS="$scratch/q.md" \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
    FLEET_LOOSE_ENDS_FILE="0" FLEET_LOOSE_ENDS_CLOSE="0" \
    "$bin" --nag-only >"$scratch/broken.out" 2>"$scratch/broken.err"
rc=$?
set -e
mv "$scratch/lib.bak" "$lib"
[[ "$rc" -ne 0 ]] || fail "15: missing helper must fail loud (rc=$rc)"
grep -q 'LOOSE-ENDS-BROKEN' "$triage" || fail "15: missing helper must LOUD"
ok "15: missing helper fails loud"

# --- 16. Contracts --------------------------------------------------------
# Matrix: sr-nothing-half-done must be enforced.
status=$(jq -r '.rules[] | select(.id=="sr-nothing-half-done") | .status' "$matrix")
[[ "$status" == "enforced" ]] || fail "16: sr-nothing-half-done must be enforced, got $status"
ok "16a: rule-enforcement.json status=enforced"

# MANIFEST: the new bin and lib must be installed.
grep -q '^bin/fleet-loose-ends-canary ' "$manifest" \
    || fail "16: MANIFEST missing bin/fleet-loose-ends-canary"
grep -q '^lib/loose-ends.py ' "$manifest" \
    || fail "16: MANIFEST missing lib/loose-ends.py"
ok "16b: MANIFEST entries installed"

# Heartbeat-tier1: block 42 wires the canary.
grep -q 'LOOSE_ENDS_CANARY_BIN' "$tier1" \
    || fail "16: heartbeat-tier1 missing LOOSE_ENDS_CANARY_BIN"
grep -q '43. loose-ends canary' "$tier1" \
    || fail "16: heartbeat-tier1 missing block 43 header"
ok "16c: heartbeat-tier1 block 43 wired"

# Worker prompt: PR-body gate that references the canary's marker.
grep -q 'sr-nothing-half-done\|loose-ends-canary' "$worker" \
    || fail "16: worker prompt missing loose-ends reference"
ok "16d: prompts/worker.md references the canary"

# No bin/loose-ends dispatcher (depth-1 spawn-guard, no retries).
if [[ -x "$repo_root/bin/loose-ends" ]]; then
    fail "16: bin/loose-ends dispatcher must not exist"
fi
ok "16e: no bin/loose-ends dispatcher"

# --- 17. Non-canonical QUESTIONS.md + FILE=1 must not create (fleet-ops#1596)
# The live leak: a worker ran the canary with FLEET_LOOSE_ENDS_FILE=1 against
# the test fixture whose row text is "Back again" and filed #1596. The
# canonical-dir guard treats FILE=1 as 0 for question auto-file only.
canon_q_dir="$scratch/canon-q"
mkdir -p "$canon_q_dir"
{
    for i in $(seq 1 19); do printf '# filler %d\n' "$i"; done
    printf '| 2026-08-20 | Back again | claude-mac | OPEN |\n'
} >"$scratch/q-back-again.md"
: >"$triage"
rm -f "$scratch/gh-issues/creates"
create_before=$(find "$scratch/gh-issues" -name 'issue-*.body' | wc -l)
set +e
env -u FLEET_LOOSE_ENDS_NAG_HOURS \
    FLEET_LOOSE_ENDS_QUESTIONS="$scratch/q-back-again.md" \
    FLEET_LOOSE_ENDS_CANONICAL_QUESTIONS_DIR="$canon_q_dir" \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
    FLEET_LOOSE_ENDS_FILE="1" FLEET_LOOSE_ENDS_CLOSE="0" \
    "$bin" --nag-only >"$scratch/noncanon.out" 2>"$scratch/noncanon.err"
noncanon_rc=$?
set -e
[[ "$noncanon_rc" -eq 0 ]] || fail "17: non-canonical FILE=1 must still exit 0 (got $noncanon_rc)"
grep -q 'LOOSE-ENDS-NONCANONICAL-FILE' "$triage" \
    || fail "17: non-canonical FILE=1 must LOUD LOOSE-ENDS-NONCANONICAL-FILE"
[[ ! -f "$scratch/gh-issues/creates" ]] \
    || { cat "$scratch/gh-issues/creates" >&2; fail "17: scratch QUESTIONS.md must not invoke gh issue create"; }
create_after=$(find "$scratch/gh-issues" -name 'issue-*.body' | wc -l)
[[ "$create_after" -eq "$create_before" ]] \
    || fail "17: scratch QUESTIONS.md must not add issue bodies (before=$create_before after=$create_after)"
ok "17: non-canonical QUESTIONS.md + FILE=1 does not file"

# --- 18. Canonical QUESTIONS.md + FILE=1 still files ----------------------
{
    printf '# QUESTIONS LEDGER\n\n'
    printf '| Asked | Question | Asked-by | Status |\n'
    printf '|---|---|---|---|\n'
    printf '| 2026-08-20 | Canonical token ask | claude-mac | OPEN |\n'
} >"$canon_q_dir/QUESTIONS.md"
: >"$triage"
rm -f "$scratch/gh-issues/creates"
set +e
env -u FLEET_LOOSE_ENDS_NAG_HOURS \
    FLEET_LOOSE_ENDS_QUESTIONS="$canon_q_dir/QUESTIONS.md" \
    FLEET_LOOSE_ENDS_CANONICAL_QUESTIONS_DIR="$canon_q_dir" \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
    FLEET_LOOSE_ENDS_FILE="1" FLEET_LOOSE_ENDS_CLOSE="0" \
    "$bin" --nag-only >"$scratch/canon.out" 2>"$scratch/canon.err"
canon_rc=$?
set -e
[[ "$canon_rc" -eq 0 ]] || fail "18: canonical FILE=1 must exit 0 (got $canon_rc)"
[[ -f "$scratch/gh-issues/creates" ]] \
    || { cat "$scratch/canon.err" >&2; fail "18: canonical QUESTIONS.md + FILE=1 must invoke gh issue create"; }
grep -q 'open-question' "$scratch/gh-issues/creates" \
    || fail "18: create log must name the open-question title"
ok "18: canonical QUESTIONS.md + FILE=1 still files"

# --- 19. Bulk list never asks for comments (fleet-ops#1596 HTTP 504) ------
# Live proof 2026-09-05: `gh issue list --limit 200 --json number,body,comments`
# returned HTTP 504; the same list without comments returned 200 rows including
# #1596. Observe-to-close must keep using per-issue `gh issue view --json comments`.
: >"$scratch/gh-issues/list-args"
env -u FLEET_LOOSE_ENDS_NAG_HOURS \
    FLEET_LOOSE_ENDS_QUESTIONS="$scratch/q-empty.md" \
    FLEET_LOOSE_ENDS_SCAN_PRS="0" FLEET_LOOSE_ENDS_SCAN_WORKTREES="0" \
    FLEET_LOOSE_ENDS_FILE="1" FLEET_LOOSE_ENDS_CLOSE="0" \
    "$bin" --nag-only >/dev/null 2>&1
[[ -s "$scratch/gh-issues/list-args" ]] || fail "19: FILE=1 tick must call gh issue list"
if grep -E -- '--json[[:space:]]+[^[:space:]]*comments' "$scratch/gh-issues/list-args"; then
    cat "$scratch/gh-issues/list-args" >&2
    fail "19: bulk gh issue list must not request comments"
fi
grep -q -- '--json number,body' "$scratch/gh-issues/list-args" \
    || { cat "$scratch/gh-issues/list-args" >&2; fail "19: bulk list must request number,body only"; }
ok "19: bulk gh issue list omits comments"

echo
echo "OK: fleet-loose-ends-canary (fleet-ops#528) — 19 scenarios green"