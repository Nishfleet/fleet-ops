#!/usr/bin/env bash
# tests/fleet-failed-command-observe-duplicate-1003.test.sh
#
# fleet-ops#1003 / #1019: leftover duplicate open issues for the SAME
# 01a041a5 gh--json+python3 KeyError session signal must ALL drain via
# observe-to-close, not just the first match.
#
# The 01a041a5 session is a python-traceback sibling of the 01a03e38
# pile (the #957 / #966 / #971 / #976 / #981 pile locked under
# tests/fleet-failed-command-observe-duplicate-python-traceback.test.sh),
# but a DIFFERENT session slug. GitHub's search-index delay
# (fleet-ops#951) filed 2 copies of
#   signal: failed-command-flagged/2026-08-27t05-16-15-343z-01a041a5-ba6f-771c-9de4-d9ddaa6a54b0
# at 2026-08-27T05:32Z. Leftovers still open at filing time of #1003:
# #1003, #1019. Open-list dedup (fleet-ops#951) stops NEW copies. It
# does not close the copies already sitting on the desk. Those close
# only when the detector is green for the slug AND observe-to-close
# walks every matching open issue (fleet-ops#650 / #758). A `first`-only
# close, or a CAP that silently drops the rest forever, would leave
# #1019 dispatching workers after the session has aged out.
#
# The python-traceback shape itself is locked under #957 (and #1003
# adds the gh--json+python3 sibling wording) in
# tests/fleet-failed-command-python-traceback.test.sh. The 01a03e38
# leftover-duplicate drain is locked under #966 in
# tests/fleet-failed-command-observe-duplicate-python-traceback.test.sh.
# This file locks the 01a041a5 leftover-duplicate drain so a future
# observe-to-close refactor cannot resolve only issue 0 of the 01a041a5
# pile, and so the citation chain (worker.md + detector docstring +
# seat-lib.test.sh host) for #1019 is verified.
#
# Live session: 2026-08-27T05-16-15-343Z_01a041a5-ba6f-771c-9de4-d9ddaa6a54b0.jsonl
# Live signal:  failed-command-flagged/2026-08-27t05-16-15-343z-01a041a5-ba6f-771c-9de4-d9ddaa6a54b0
# Live leftover open duplicates (as of 2026-08-27T13:05Z): #1003, #1019
#
# Scenarios:
#   1. green tick, two leftover open issues + one unrelated issue
#      with no failed-command signal: comments resolved-at on both
#      leftovers, touches none of the unrelated issue, does not close
#      same tick.
#   2. later tick with the marker already on both: closes both,
#      still leaves the unrelated issue open.
#   3. still-dirty slug: none of the leftovers are commented or closed.
#   4. three-place citation lock (prompt, detector, CI host) for
#      #1003 / #1019.

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

scratch="$(mktemp -d -t failed-command-observe-dup-1003.XXXXXX)"
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

# Live leftover pile from the 01a041a5 gh--json+python3 KeyError
# session. These two issues are the live leftover open duplicates of
# #1003 (#1003, #1019). A refactor that resolves only issue 0 of this
# pile is a regression; this test must catch it.
slug="2026-08-27t05-16-15-343z-01a041a5-ba6f-771c-9de4-d9ddaa6a54b0"
leftovers=(1003 1019)
unrelated=8888

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
  FLEET_FAILED_COMMAND_NOW="2026-08-27T13:05:00Z" \
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
# No session file for the 01a041a5 slug: the 24h window has aged it
# out. A clean unrelated session keeps the scanner honest.
printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"clean tick"}]}}' \
  >"$sessions/clean-unrelated.jsonl"
touch -d "2026-08-27T12:55:00Z" "$sessions/clean-unrelated.jsonl"

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
ok "live #1003: green tick comments resolved-at on both leftover duplicates, not first-only"
rm -f "$sessions/clean-unrelated.jsonl"

# --- 2. later tick closes ALL leftovers, leaves the unrelated issue open ----
: >"$gh_store/commented"
: >"$gh_store/closed"
printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"still clean"}]}}' \
  >"$sessions/clean-unrelated2.jsonl"
touch -d "2026-08-27T13:00:00Z" "$sessions/clean-unrelated2.jsonl"

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
ok "live #1003: later tick closes both leftover duplicates"
rm -f "$sessions/clean-unrelated2.jsonl"

# --- 3. still-dirty slug: leftovers stay open (no resolved-at, no close) ----
seed_leftovers
write_dirty="$sessions/${slug}.jsonl"
cat >"$write_dirty" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe1","name":"bash","arguments":{"command":"gh issue view 844 -R Nishfleet/fleet-ops --comments --json author,body,createdAt 2>&1 | python3 -c \"import json,sys; d=json.load(sys.stdin); [print(c['author']['login'],c['createdAt'],':',c['body'][:300]) for c in d['comments']]\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe1","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\nKeyError: 'comments'\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_retry1","name":"bash","arguments":{"command":"gh issue view 844 -R Nishfleet/fleet-ops --json author,body,createdAt 2>&1 | python3 -c \"import json,sys; d=json.load(sys.stdin); [print(c['author']['login'],c['createdAt'],':',c['body'][:300]) for c in d['comments']]\""}}]}}
JSONL
touch -d "2026-08-27T13:00:00Z" "$write_dirty"

rc=$(run_bin)
[[ "$rc" == "1" ]] || fail "still-dirty slug should exit 1 (got $rc) $(cat "$scratch/err.log")"
if [ -s "$gh_store/closed" ]; then
  fail "still-dirty slug must not close leftovers (closed=$(cat "$gh_store/closed"))"
fi
if [ -s "$gh_store/commented" ]; then
  fail "still-dirty slug must not comment resolved-at (commented=$(cat "$gh_store/commented"))"
fi
ok "live #1003: still-dirty slug leaves both leftover duplicates open"

# --- 4. three-place citation lock (prompt, detector, CI host) for #1003 / #1019 -----
# Same pin as #937 / #957 / #965 / #966: dropping the #1003 or #1019
# citation from any one of these three places is a regression even if
# the drain drill still passes. The existing python-traceback test
# (fleet-ops#957) already pins #957 and the new #1003 gh--json+python3
# sibling; this file adds the #1003 / #1019 citation next to it for
# the leftover-duplicate drain, and pins the #1019 sibling in the
# 01a041a5 pile (a 2-issue pile, not the 6-issue 01a03e38 pile).
worker="$repo_root/lib/failed-command-flagged.py"
grep -q '#1003' "$worker" \
  || fail "prompts/worker.md must carry the #1003 citation next to the #957 python-traceback citation"
grep -q '#1019' "$worker" \
  || fail "prompts/worker.md must carry the #1019 citation (leftover-duplicate sibling of #1003 in the 01a041a5 pile)"
grep -q 'fleet-failed-command-observe-duplicate-1003.test.sh' "$worker" \
  || fail "prompts/worker.md must name the leftover-duplicate test file for the 01a041a5 pile"
ok "worker.md cites #1003, #1019, and names the leftover-duplicate test file"
grep -q '#1003, #1019' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite #1003 and #1019 next to #957 / #966"
grep -q 'fleet-failed-command-observe-duplicate-1003.test.sh' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the leftover-duplicate test file for the 01a041a5 pile"
ok "lib/failed-command-flagged.py docstring cites #1003 / #1019 and names the leftover-duplicate test file"
grep -F -q 'fleet-failed-command-observe-duplicate-1003.test.sh' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-observe-duplicate-1003: live #1003 / #1019 leftover-duplicate drain"
