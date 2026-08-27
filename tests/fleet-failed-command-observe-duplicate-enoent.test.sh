#!/usr/bin/env bash
# tests/fleet-failed-command-observe-duplicate-enoent.test.sh
#
# fleet-ops#972: leftover duplicate open issues for the SAME read-ENOENT
# session signal must ALL drain via observe-to-close, not just the first
# match.
#
# GitHub's search-index delay (fleet-ops#951) filed 7 copies of
#   signal: failed-command-flagged/2026-08-26t14-02-29-714z-01a03e61-27d2-7c3f-9101-da19c90f6ba5
# Leftovers still open at filing time of #972: #662, #953, #958, #967,
# #972, #977, #982. The read-ENOENT shape (live #958) is the class these
# duplicates share — a `read` of a missing path returning
# `ENOENT: no such file or directory, access '<path>'` (isError=true,
# details={}, no `Command exited with code` line), walked past with
# several thinking-only recovery turns (including an explicit skip) and
# then "Now I have the full picture. Let me plan and execute." prose
# bundled with todo toolCalls, with no user-facing flag.
# Open-list dedup (fleet-ops#951) stops NEW copies. It does not close
# the copies already sitting on the desk. Those close only when the
# detector is green for the slug AND observe-to-close walks every
# matching open issue (fleet-ops#650 / #758). A `first`-only close, or
# a CAP that silently drops the rest forever, would leave #972 (and its
# siblings) dispatching workers after the session has aged out.
#
# The read-ENOENT skip-then-todos shape itself is locked under #958
# (tests/fleet-failed-command-read-enoent-skip-todos.test.sh). The
# leftover-duplicate drain class is locked under #965 for the
# edit-unmatch pile (tests/fleet-failed-command-observe-duplicate-open.test.sh)
# and under #966 for the python-traceback pile
# (tests/fleet-failed-command-observe-duplicate-python-traceback.test.sh).
# This file locks the leftover-duplicate DRAIN for the read-ENOENT pile
# so a future observe-to-close refactor cannot resolve only issue 0 of
# the 01a03e61 pile, and so the citation chain (worker.md + detector
# docstring + seat-lib.test.sh host) for #972 is verified.
#
# Live session: 2026-08-26T14-02-29-714Z_01a03e61-27d2-7c3f-9101-da19c90f6ba5.jsonl
# Live signal:  failed-command-flagged/2026-08-26t14-02-29-714z-01a03e61-27d2-7c3f-9101-da19c90f6ba5
# Live leftover open duplicates (as of 2026-08-27T10:02Z):
#   #662, #953, #958, #967, #972, #977, #982
#
# Scenarios:
#   1. green tick, seven leftover open issues + one unrelated issue
#      with no failed-command signal: comments resolved-at on all
#      seven leftovers, touches none of the unrelated issue, does not
#      close same tick.
#   2. later tick with the marker already on all seven: closes all
#      seven, still leaves the unrelated issue open.
#   3. still-dirty slug: none of the leftovers are commented or closed.
#   4. three-place citation lock (prompt, detector, CI host) for #972.

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

scratch="$(mktemp -d -t failed-command-observe-dup-enoent.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions/ws"
mkdir -p "$sessions"

gh_store="$scratch/gh-issues"
mkdir -p "$gh_store"

# Mock gh: `--search` always returns [] (simulating GitHub search index
# delay) so dedup must rely on the open list (open_json). The list
# command (no --search) returns all open issues from the store. Issue
# bodies + comments live in flat files; comment writes append to a per-
# issue comments file; close writes a per-issue `.closed` sentinel.
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
        search_query="${search_query#\"}"
        search_query="${search_query%\"}"
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
            all_text="$body $(cat "$comments_file")"
          else
            comments_json='[]'
            all_text="$body"
          fi
          if [ -n "$search_query" ] && ! printf '%s' "$all_text" | grep -Fq -- "$search_query"; then
            continue
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
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/gh"

# Live leftover pile from the 01a03e61 read-ENOENT session.
# These seven issues are the live leftover open duplicates of #958
# (#662, #953, #958, #967, #972, #977, #982). A refactor that resolves
# only issue 0 of this pile is a regression; this test must catch it.
slug="2026-08-26t14-02-29-714z-01a03e61-27d2-7c3f-9101-da19c90f6ba5"
leftovers=(662 953 958 967 972 977 982)
unrelated=999

seed_leftovers() {
  local n
  rm -f "$gh_store"/issue-* "$gh_store/commented" "$gh_store/closed"
  : >"$gh_store/commented"
  : >"$gh_store/closed"
  for n in "${leftovers[@]}"; do
    printf '%s\n' "fix(failed-command): $slug" >"$gh_store/issue-${n}.body"
    printf '\nDo not close until the detector reports this clean.\n\nsignal: failed-command-flagged/%s\n' \
      "$slug" >>"$gh_store/issue-${n}.body"
  done
  # Unrelated issue has no failed-command signal, so observe-to-close
  # must skip it even on a fully green tick.
  printf '%s\n' "chore: unrelated fleet-ops issue" >"$gh_store/issue-${unrelated}.body"
  printf '\nThis issue has no failed-command signal and must stay untouched.\n' \
    >>"$gh_store/issue-${unrelated}.body"
}

run_bin() {
  set +e
  FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
  FLEET_FAILED_COMMAND_LIB="$lib" \
  FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
  FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
  FLEET_FAILED_COMMAND_NOW="2026-08-27T13:00:00Z" \
  FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
  FLEET_FAILED_COMMAND_CLOSE_ISSUES=1 \
  FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
  FLEET_FAILED_COMMAND_CAP=10 \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$gh_store" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

assert_set_eq() {
  local label="$1" file="$2"
  shift 2
  local expected actual
  expected=$(printf '%s\n' "$@" | sort -n | tr '\n' ' ')
  if [ ! -s "$file" ]; then
    fail "$label: expected ${expected}got empty ($(cat "$scratch/err.log"))"
  fi
  actual=$(sort -n "$file" | tr '\n' ' ')
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected' got '$actual' ($(cat "$scratch/err.log"))"
}

# --- 1. green tick comments resolved-at on EVERY leftover, not first-only ---
seed_leftovers
# No session file for the 01a03e61 slug: the 24h window has aged it
# out. A clean unrelated session keeps the scanner honest.
printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"clean tick"}]}}' \
  >"$sessions/clean-unrelated.jsonl"
touch -d "2026-08-27T12:50:00Z" "$sessions/clean-unrelated.jsonl"

rc=$(run_bin)
[[ "$rc" == "0" ]] || fail "green tick should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "OBSERVED-RESOLVED" "$scratch/err.log" \
  || fail "green tick must log OBSERVED-RESOLVED $(cat "$scratch/err.log")"
assert_set_eq "green tick comments" "$gh_store/commented" "${leftovers[@]}"
if grep -qxF "$unrelated" "$gh_store/commented"; then
  fail "green tick must not comment on unrelated #$unrelated"
fi
if [ -s "$gh_store/closed" ]; then
  fail "same-tick must not close (closed=$(cat "$gh_store/closed"))"
fi
for n in "${leftovers[@]}"; do
  grep -q "resolved-at: signal: failed-command-flagged/${slug}" "$gh_store/issue-${n}.comments" \
    || fail "green tick missing resolved-at on #$n"
done
ok "live #972: green tick comments resolved-at on all seven leftover duplicates, not first-only"
rm -f "$sessions/clean-unrelated.jsonl"

# --- 2. later tick closes ALL leftovers, leaves the unrelated issue open ----
: >"$gh_store/commented"
: >"$gh_store/closed"
printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"still clean"}]}}' \
  >"$sessions/clean-unrelated2.jsonl"
touch -d "2026-08-27T12:55:00Z" "$sessions/clean-unrelated2.jsonl"

rc=$(run_bin)
[[ "$rc" == "0" ]] || fail "close tick should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "OBSERVE-CLOSED" "$scratch/err.log" \
  || fail "later tick must log OBSERVE-CLOSED $(cat "$scratch/err.log")"
assert_set_eq "close tick closes" "$gh_store/closed" "${leftovers[@]}"
if grep -qxF "$unrelated" "$gh_store/closed"; then
  fail "close tick must not close unrelated #$unrelated"
fi
if [ -s "$gh_store/commented" ]; then
  fail "later tick must not comment again (commented=$(cat "$gh_store/commented"))"
fi
ok "live #972: later tick closes all seven leftover duplicates"
rm -f "$sessions/clean-unrelated2.jsonl"

# --- 3. still-dirty slug: leftovers stay open (no resolved-at, no close) ----
seed_leftovers
write_dirty="$sessions/${slug}.jsonl"
cat >"$write_dirty" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me read the context files first."},{"type":"toolCall","id":"call_overnight","name":"read","arguments":{"path":"/home/nish/workspaces/agent-state/OVERNIGHT.md"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_overnight","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/agent-state/OVERNIGHT.md'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"OVERNIGHT.md is missing. Let me look for it elsewhere or skip."},{"type":"toolCall","id":"call_find","name":"bash","arguments":{"command":"find /home/nish/workspaces/agent-state -maxdepth 2 -iname \"OVERNIGHT*\" 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_find","toolName":"bash","isError":false,"content":[{"type":"text","text":""}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now I have the full picture. Let me plan and execute."},{"type":"toolCall","id":"call_todo1","name":"todo","arguments":{"action":"add","text":"Create branch","id":1}}]}}
JSONL
touch -d "2026-08-27T12:50:00Z" "$write_dirty"

rc=$(run_bin)
[[ "$rc" == "1" ]] || fail "still-dirty slug should exit 1 (got $rc) $(cat "$scratch/err.log")"
if [ -s "$gh_store/closed" ]; then
  fail "still-dirty slug must not close leftovers (closed=$(cat "$gh_store/closed"))"
fi
if [ -s "$gh_store/commented" ]; then
  fail "still-dirty slug must not comment resolved-at (commented=$(cat "$gh_store/commented"))"
fi
ok "live #972: still-dirty slug leaves all seven leftover duplicates open"

# --- 4. three-place citation lock (prompt, detector, CI host) for #972 -----
# Same pin as #937 / #957 / #966: dropping the #972 citation from any
# one of these three places is a regression even if the drain drill
# still passes. The existing read-ENOENT skip-then-todos test
# (fleet-ops#958) already pins #958; this file adds the #972 citation
# next to it.
worker="$repo_root/prompts/worker.md"
grep -q '#972' "$worker" \
  || fail "prompts/worker.md must carry the #972 citation next to the #958 read-ENOENT citation"
grep -q 'fleet-ops#958, #972' "$worker" \
  || fail "prompts/worker.md must cite #972 next to the #958 read-ENOENT citation"
ok "worker.md cites #972"
grep -q 'fleet-ops#958, #972' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite #972 next to #958"
ok "lib/failed-command-flagged.py docstring cites #972"
grep -F -q 'fleet-failed-command-observe-duplicate-enoent.test.sh' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-observe-duplicate-enoent: live #972 leftover-duplicate drain"
