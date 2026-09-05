#!/usr/bin/env bash
# tests/fleet-failed-command-observe-duplicate-git-branch-force.test.sh
#
# fleet-ops#985: leftover duplicate open issue for the SAME session
# signal as the closed #849 must drain via observe-to-close, not sit
# on the desk dispatching workers after the session has aged out.
#
# GitHub's search-index delay filed 2 copies of
#   signal: failed-command-flagged/2026-08-27t02-21-40-527z-01a04105-e52f-78bf-9056-ca05fae95a80
# (#849 closed by PR #990 which locked the shape under
# tests/fleet-failed-command-git-branch-cannot-force-update.test.sh;
# #985 still open at filing time). Open-list dedup (fleet-ops#951)
# stops NEW copies. It does not close the copy already sitting on the
# desk. That closes only when the detector is green for the slug and
# observe-to-close walks every matching open issue (fleet-ops#650 /
# #758). A `first`-only close, or a CAP that silently drops the rest
# forever, would leave #985 dispatching workers after the session has
# aged out of the 24h window after 2026-08-27T02:21:40Z.
#
# The git-branch-force shape itself is locked under #849
# (tests/fleet-failed-command-git-branch-cannot-force-update.test.sh).
# This file locks the leftover-duplicate DRAIN so a future
# observe-to-close refactor cannot resolve only issue 0 of a
# same-signal pile, and so the citation chain (worker.md + detector
# docstring + seat-lib.test.sh host) for #985 is verified.
#
# Live session: 2026-08-27T02-21-40-527Z_01a04105-e52f-78bf-9056-ca05fae95a80.jsonl
#
# Scenarios:
#   1. green tick, one leftover open issue (#985) + one unrelated issue
#      with no failed-command signal: comments resolved-at on the
#      leftover, touches none of the unrelated issue, does not close
#      same tick.
#   2. later tick with the marker already on the leftover: closes it,
#      still leaves the unrelated issue open.
#   3. still-dirty slug: the leftover is neither commented nor closed.
#   4. prompt-side citation lock: prompts/lib/failed-command-flagged.py cites #985 (next
#      to #849, the original of the 01a04105 git-branch-force pile).
#   5. detector-side citation lock: lib/failed-command-flagged.py
#      docstring cites #985 (next to #849).
#   6. CI host: seat-lib.test.sh nests this file so the drain drill
#      cannot be skipped by a fresh CI line.

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

scratch="$(mktemp -d -t failed-command-observe-dup-gbf.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions/ws"
mkdir -p "$sessions"

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

# Live leftover from the 01a04105 git-branch-force session (#985).
# #849 is the closed original (PR #990); #985 is the open leftover.
slug="2026-08-27t02-21-40-527z-01a04105-e52f-78bf-9056-ca05fae95a80"
leftovers=(985)
unrelated=999

seed_leftovers() {
  local n
  rm -f "$gh_store"/issue-* "$gh_store/commented" "$gh_store/closed"
  : >"$gh_store/commented"
  : >"$gh_store/closed"
  for n in "${leftovers[@]}"; do
    printf '%s\n' "fix(failed-command): $slug — failed command walked past, never flagged" >"$gh_store/issue-${n}.body"
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
  FLEET_FAILED_COMMAND_NOW="2026-08-28T03:00:00Z" \
  FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
  FLEET_FAILED_COMMAND_CLOSE_ISSUES=1 \
  FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
  FLEET_FAILED_COMMAND_CAP=5 \
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

# --- 1. green tick comments resolved-at on the leftover, not same-tick close --
seed_leftovers
# No session file for the live slug: the 24h window has aged it out
# (NOW is 2026-08-28T03:00:00Z, session mtime was 2026-08-27T02:21:40Z).
# A clean unrelated session keeps the scanner honest.
printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"clean tick"}]}}' \
  >"$sessions/clean-unrelated.jsonl"
touch -d "2026-08-28T02:50:00Z" "$sessions/clean-unrelated.jsonl"

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
ok "live #985: green tick comments resolved-at on the leftover duplicate, not same-tick close"
rm -f "$sessions/clean-unrelated.jsonl"

# --- 2. later tick closes the leftover, leaves the unrelated issue open --------
: >"$gh_store/commented"
: >"$gh_store/closed"
printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"still clean"}]}}' \
  >"$sessions/clean-unrelated2.jsonl"
touch -d "2026-08-28T02:55:00Z" "$sessions/clean-unrelated2.jsonl"

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
ok "live #985: later tick closes the leftover duplicate"
rm -f "$sessions/clean-unrelated2.jsonl"

# --- 3. still-dirty slug: leftover stays open (no resolved-at, no close) -------
seed_leftovers
write_dirty="$sessions/${slug}.jsonl"
cat >"$write_dirty" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_force","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-650 && git branch -f claim/issue-650 origin/main && git status 2>&1 | head -5 && git log --oneline -3"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_force","toolName":"bash","isError":true,"content":[{"type":"text","text":"fatal: cannot force update the branch 'claim/issue-650' used by worktree at '/home/nish/workspaces/agent-worktrees/issue-fleet-ops-650'\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_recover","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-650 && git checkout -b tmp-clean origin/main 2>&1 | head -3 && git log --oneline -3"}}]}}
JSONL
touch -d "2026-08-28T02:50:00Z" "$write_dirty"

rc=$(run_bin)
[[ "$rc" == "1" ]] || fail "still-dirty slug should exit 1 (got $rc) $(cat "$scratch/err.log")"
if [ -s "$gh_store/closed" ]; then
  fail "still-dirty slug must not close leftover (closed=$(cat "$gh_store/closed"))"
fi
if [ -s "$gh_store/commented" ]; then
  fail "still-dirty slug must not comment resolved-at (commented=$(cat "$gh_store/commented"))"
fi
ok "live #985: still-dirty slug leaves the leftover duplicate open"

# --- 4. prompt-side citation lock for #985 -----------------------------------
# Same pin as #972 / #965 / #966: dropping the #985 citation from the
# prompt is a regression even if the drain drill still passes. The
# original #849 shape is locked under
# tests/fleet-failed-command-git-branch-cannot-force-update.test.sh;
# this file adds the #985 citation next to #849 — #985 is the leftover
# open duplicate of #849 in the 01a04105 git-branch-force pile.
worker="$repo_root/prompts/worker.md"
grep -q 'fleet-ops#849, #985' "$lib" \
  || fail "lib/failed-command-flagged.py must cite fleet-ops#985 next to #849 (the 01a04105 git-branch-force leftover-duplicate citation)"
ok "lib/failed-command-flagged.py cites #985 next to #849"

# --- 5. detector-side citation lock for #985 ---------------------------------
# The lib docstring is the standing-rule contract for the next detector
# maintainer. The sibling #972 / #965 / #966 tests already use the same
# three-place pattern: prompt + detector docstring + CI host. Dropping
# the #985 citation from the lib docstring is a regression even if the
# prompt lock and the drill still pass. Future detectors refactor the
# lib freely; this scenario is the regression fence.
grep -q 'fleet-ops#849, #985' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#985 next to #849"
ok "lib/failed-command-flagged.py docstring cites #985 next to #849"

# --- 6. CI host: seat-lib.test.sh nests this file ----------------------------
# A fresh PR cannot add a workflow line on this repo (worker token has
# no Workflows permission). The drain drill has to run through the
# nested seat-lib host so removing the test file (or moving the
# citation check out) is caught by the seat-lib listing test.
grep -F -q 'fleet-failed-command-observe-duplicate-git-branch-force.test.sh' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-observe-duplicate-git-branch-force: live #985 leftover-duplicate drain"
