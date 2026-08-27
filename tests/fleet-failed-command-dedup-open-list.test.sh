#!/usr/bin/env bash
# tests/fleet-failed-command-dedup-open-list.test.sh
#
# fleet-ops#951: the detector's open-issue dedup relied on
# `gh issue list --search "\"$signal\""`. GitHub's search API has an
# indexing delay — a just-filed issue is not searchable for several
# minutes. Consecutive heartbeat ticks each filed a duplicate before the
# prior one was indexed (live #951: 7 duplicates of #652 for the same
# session signal). The fix dedups against the already-fetched open issue
# list (open_json, fetched fresh each tick with --state open --json, no
# index delay) via a body-grep for the signal.
#
# This test simulates the index delay: the mock gh's `--search` always
# returns [] (as if no issue is indexed yet), while `--state open --json`
# (no --search) returns the pre-populated open issue. The detector must
# dedup against the open list and NOT file a duplicate.
#
# Same CI constraint as the other failed-command tests (worker token
# cannot add a P14 line in ci.yml): nested in tests/seat-lib.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-failed-command-flagged"
lib="$repo_root/lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-dedup.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions/ws"
mkdir -p "$sessions"

gh_store="$scratch/gh-issues"
mkdir -p "$gh_store"

# Mock gh: `--search` always returns [] (simulating GitHub search index
# delay). `--state open --json` without --search returns all open issues
# from the store. This is the exact failure mode: the search API cannot
# find a just-filed issue, but the open issue list can.
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
            --repo|-R) shift 2 ;;
            *) shift ;;
          esac
        done
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
              shift
              ;;
          esac
        done
        printf '%s\n' "$body" >"$store/issue-${num}.comments"
        printf '%s\n' "$num" >>"$store/commented"
        echo "https://github.com/Nishfleet/fleet-ops/issues/${num}#issuecomment-1"
        ;;
      list)
        state_filter="open"
        search_query=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --state) state_filter="$2"; shift 2 ;;
            --search) search_query="$2"; shift 2 ;;
            --limit|--json|--repo|-R) shift 2 ;;
            *) shift ;;
          esac
        done
        # Simulate GitHub search index delay: --search always returns [].
        if [ -n "$search_query" ]; then
          printf '[]\n'
          exit 0
        fi
        printf '[\n'
        first=1
        for f in "$store"/issue-*.body; do
          [ -f "$f" ] || continue
          num=$(basename "$f" .body)
          num=${num#issue-}
          is_closed=""
          [ -f "$store/issue-${num}.closed" ] && is_closed="1"
          if [ "$state_filter" = "open" ] && [ -n "$is_closed" ]; then
            continue
          fi
          if [ "$state_filter" = "closed" ] && [ -z "$is_closed" ]; then
            continue
          fi
          body=$(tail -n +2 "$f")
          comments_file="$store/issue-${num}.comments"
          if [ -f "$comments_file" ]; then
            comments_json=$(python3 -c 'import json,sys;print(json.dumps([{"body": sys.stdin.read()}]))' <"$comments_file")
          else
            comments_json='[]'
          fi
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"body":%s,"comments":%s}' \
            "$num" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")" "$comments_json"
        done
        printf '\n]\n'
        ;;
      close)
        num=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --reason|--comment|--repo|-R) shift 2 ;;
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift
              ;;
          esac
        done
        [ -n "$num" ] || exit 1
        : > "$store/issue-${num}.closed"
        printf '%s\n' "$num" >>"$store/closed"
        echo "Closed issue #$num"
        ;;
      reopen)
        num=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --repo|-R) shift 2 ;;
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift
              ;;
          esac
        done
        [ -n "$num" ] || exit 1
        rm -f "$store/issue-${num}.closed"
        printf '%s\n' "$num" >>"$store/reopened"
        echo "Reopened issue #$num"
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/gh"

write_session() {
  local name="$1"
  local jsonl="$2"
  printf '%s\n' "$jsonl" >"$sessions/$name.jsonl"
  touch -d "2026-08-27T00:00:00Z" "$sessions/$name.jsonl"
}

run_bin() {
  local file_issues="${1:-0}"
  set +e
  FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
  FLEET_FAILED_COMMAND_LIB="$lib" \
  FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
  FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
  FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
  FLEET_FAILED_COMMAND_FILE_ISSUES="$file_issues" \
  FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$gh_store" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

# --- 1. open-list dedup when search returns empty (index delay) -------------
# Pre-populate the mock store with an open issue that carries the signal,
# as if a prior heartbeat tick had just filed it and GitHub had not indexed
# it yet. The mock's --search returns [] (index delay), but --state open
# --json returns the issue. The detector must dedup against the open list
# and NOT file a duplicate.
slug_test="2026-08-26t11-57-42-915z-01a03dee-test-dedup-shape"
printf '%s\n' "fix(failed-command): $slug_test" >"$gh_store/issue-652.body"
printf '\nThe session-close lint found a swallowed failure.\n\nsignal: failed-command-flagged/%s\n' "$slug_test" >>"$gh_store/issue-652.body"

write_session "$slug_test" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'

rc=$(run_bin 1)
[[ "$rc" == "1" ]] || fail "finding should still exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "deduped via open list" "$scratch/err.log" \
  || fail "must dedup via open list, not search: $(cat "$scratch/err.log")"
issue_count=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$issue_count" == "1" ]] || fail "must not file a duplicate (got $issue_count issues)"
ok "open-list dedup: detector dedups against open_json when search returns empty (live #951 index-delay shape)"
rm -f "$sessions/${slug_test}.jsonl"

# --- 2. files a new issue when no open or closed match exists ----------------
# No pre-populated issue. The detector must file a new issue even though
# --search returns [] (the open list is also empty). This proves the fix
# does not suppress legitimate first filings.
rm -f "$gh_store"/issue-* "$gh_store"/commented "$gh_store"/closed "$gh_store"/reopened
slug_new="2026-08-27t00-00-00-000z-new-finding-shape"
write_session "$slug_new" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'

rc=$(run_bin 1)
[[ "$rc" == "1" ]] || fail "new finding should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FILED" "$scratch/err.log" || fail "must file a new issue: $(cat "$scratch/err.log")"
issue_count=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$issue_count" == "1" ]] || fail "must file exactly one new issue (got $issue_count)"
ok "first filing: detector files a new issue when open list and search are both empty"
rm -f "$sessions/${slug_new}.jsonl"

# --- 3. second tick dedups against the open list (no search) -----------------
# Simulate two consecutive ticks. Tick 1 files the issue. Tick 2 fetches
# the open list (which now includes the just-filed issue) and must dedup
# even though --search returns [] (index delay). This is the exact live
# #951 scenario: the prior tick's issue is not yet indexed by search.
rm -f "$gh_store"/issue-* "$gh_store"/commented "$gh_store"/closed "$gh_store"/reopened
slug_two="2026-08-27t00-01-00-000z-two-tick-dedup-shape"
write_session "$slug_two" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'

# Tick 1: file
rc=$(run_bin 1)
[[ "$rc" == "1" ]] || fail "tick 1 should exit 1 (got $rc)"
grep -q "FILED" "$scratch/err.log" || fail "tick 1 must file: $(cat "$scratch/err.log")"
issue_count=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$issue_count" == "1" ]] || fail "tick 1 must file exactly one issue (got $issue_count)"

# Tick 2: dedup via open list (search returns [] due to index delay)
rc=$(run_bin 1)
[[ "$rc" == "1" ]] || fail "tick 2 should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "deduped via open list" "$scratch/err.log" \
  || fail "tick 2 must dedup via open list: $(cat "$scratch/err.log")"
issue_count=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$issue_count" == "1" ]] || fail "tick 2 must not file a duplicate (got $issue_count)"
ok "two-tick dedup: second tick dedups via open list when search has index delay (live #951)"
rm -f "$sessions/${slug_two}.jsonl"

echo "OK: fleet-failed-command-dedup-open-list: open-list dedup bypasses GitHub search index delay"
