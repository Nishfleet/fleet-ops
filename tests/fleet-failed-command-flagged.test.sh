#!/usr/bin/env bash
# tests/fleet-failed-command-flagged.test.sh
#
# fleet-ops#535: session-close lint for "a failed command is ALWAYS flagged".
# Offline. Live gh is stubbed. Proves:
#   1. Clean assistant text / successful toolResult -> exit 0, FAILED-COMMAND-OK.
#   2. isError + no later flag -> exit 1.
#   3. isError plus later "the call failed" -> exit 0.
#   3d. SPAWN_BLOCKED (command never ran; live #648 git_stash_forbidden) -> exit 0.
#   4. grep/rg exit 1 (POSIX no-match) -> exit 0.
#   5. Origin case: 404 Not Found walked past -> exit 1.
#   6. Timeout unflagged -> exit 1.
#   7. Auto-file with signal key, deduped on a second run.
#   8. Missing helper fails loud.
#   9. Contracts: heartbeat wiring, MANIFEST, nested CI host, matrix enforced.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-failed-command-flagged"
lib="$repo_root/lib/failed-command-flagged.py"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command.XXXXXX)"
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
      list)
        printf '[\n'
        first=1
        n=0
        for f in "$store"/*.body; do
          [ -f "$f" ] || continue
          n=$((n+1))
          # Skip closed issues (issue-N.closed marker exists)
          [ -f "$store/issue-$n.closed" ] && continue
          body=$(tail -n +2 "$f")
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"title":"","body":%s}' "$n" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")"
        done
        printf '\n]\n'
        ;;
      close)
        num=""; comment=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            [0-9]*) num="$1"; shift ;;
            --comment) comment="$2"; shift 2 ;;
            --repo|-R) shift 2 ;;
            --reason) shift 2 ;;
            *) shift ;;
          esac
        done
        [ -n "$num" ] || exit 1
        : > "$store/issue-$num.closed"
        [ -n "$comment" ] && printf '%s\n' "$comment" > "$store/issue-$num.close-comment"
        echo "Closed issue #$num"
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

# --- 1. clean session -------------------------------------------------------
write_session "clean" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Ran the canary. It passed."},{"type":"toolCall","id":"call_ok","name":"bash","arguments":{"command":"true"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"ok"}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "clean session should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-OK" "$scratch/err.log" || fail "clean session missing OK line"
ok "clean session exits 0"

# --- 2. isError, no flag ----------------------------------------------------
write_session "swallowed" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on to the next task."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "swallowed failure should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err.log" || fail "missing FAILED-COMMAND-SWALLOWED loud line"
ok "isError without a later flag is swallowed"
rm -f "$sessions/swallowed.jsonl"

# --- 3. isError plus later flag ---------------------------------------------
write_session "flagged" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the false call failed with 1, it is now the blocker."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "flagged failure should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "isError plus later flag is clean"
rm -f "$sessions/flagged.jsonl"

# --- 3b. "fails" in later text is also a flag (live BET 9 wording) ----------
write_session "fails-word" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"node canary.mjs"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"mobile CTA below fold\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"unit tests pass, but the live run fails — mobile CTA is below the fold."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "'fails' wording should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "later text using 'fails' counts as a flag"
rm -f "$sessions/fails-word.jsonl"

# --- 3c. harness block is not a ran-and-failed command ----------------------
write_session "harness-block" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_rm","name":"bash","arguments":{"command":"rm -rf /"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_rm","toolName":"bash","isError":true,"content":[{"type":"text","text":"Dangerous command blocked (no UI for confirmation)"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Skipping that path."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "harness block should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "harness-blocked command is not a swallowed failure"
rm -f "$sessions/harness-block.jsonl"

# --- 3d. SPAWN_BLOCKED is not a ran-and-failed command (fleet-ops#648) ------
write_session "spawn-block" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_st","name":"bash","arguments":{"command":"git stash list"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_st","toolName":"bash","isError":true,"content":[{"type":"text","text":"SPAWN_BLOCKED reason=git_stash_forbidden. `git stash` is forbidden on this machine: checkouts are shared, so `git stash pop` grabs stash@{0}, which is very often another agent's work. Commit to a branch instead, or clone the repo fresh under /tmp and work there."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next check."}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "SPAWN_BLOCKED should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "SPAWN_BLOCKED is not a swallowed failure (command never ran)"
rm -f "$sessions/spawn-block.jsonl"

# --- 4. grep exit 1 is POSIX no-match ---------------------------------------
write_session "grep-nomatch" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_g","name":"bash","arguments":{"command":"grep nowhere /etc/hosts"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_g","toolName":"bash","isError":true,"content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"No matches. Continuing."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "grep exit 1 should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "grep exit 1 is treated as no-match, not a swallowed failure"
rm -f "$sessions/grep-nomatch.jsonl"

# --- 5. origin case: 404 walked past ----------------------------------------
write_session "origin-404" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh","name":"bash","arguments":{"command":"gh api -X PATCH /repos/Nishfleet/0509/branches/main/protection"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh","toolName":"bash","isError":true,"content":[{"type":"text","text":"Not Found\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"verify: strict is still true. Next task."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "404 walked past should exit 1 (got $rc) $(cat "$scratch/err.log")"
ok "origin 404 walked past is flagged"
rm -f "$sessions/origin-404.jsonl"

# --- 6. timeout unflagged ---------------------------------------------------
write_session "timeout" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_t","name":"bash","arguments":{"command":"sleep 999"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_t","toolName":"bash","isError":true,"content":[{"type":"text","text":"Command timed out after 180 seconds"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next check."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "timeout walked past should exit 1 (got $rc) $(cat "$scratch/err.log")"
ok "timeout without a later flag is swallowed"
rm -f "$sessions/timeout.jsonl"

# --- 6b. gh issue create GraphQL transient, retry with no flag --------------
write_session "gh-graphql-retry" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The workers project passes. The node test failure is pre-existing. Let me file it as a new issue, then check sgscan.\n\n"}]}}
{"type":"message","message":{"role":"toolCall","id":"call_gh1","name":"bash","arguments":{"command":"cd /tmp && gh issue create -R Nishfleet/0509 --title \"Pre-existing timeout\" --body \"pre-existing\" 2>&1"}}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh1","toolName":"bash","isError":true,"content":[{"type":"text","text":"GraphQL: Something went wrong while executing your query. Please include 'TOKEN' when reporting this issue.\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"\n\n"},{"type":"toolCall","id":"call_gh2","name":"bash","arguments":{"command":"cd /tmp && gh issue create -R Nishfleet/0509 --title \"Pre-existing timeout\" --body \"pre-existing\" 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh2","toolName":"bash","isError":false,"content":[{"type":"text","text":"https://github.com/Nishfleet/0509/issues/1231"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now let me check sgscan.\n\n"}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "gh GraphQL retry with no flag should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err.log" || fail "gh GraphQL retry must be flagged as swallowed"
ok "gh issue create GraphQL failure + silent retry is swallowed"
rm -f "$sessions/gh-graphql-retry.jsonl"

# --- 6c. gh issue create GraphQL transient, explicit flag -> clean ----------
write_session "gh-graphql-flagged" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The workers project passes. The node test failure is pre-existing. Let me file it as a new issue, then check sgscan.\n\n"}]}}
{"type":"message","message":{"role":"toolCall","id":"call_gh1","name":"bash","arguments":{"command":"cd /tmp && gh issue create -R Nishfleet/0509 --title \"Pre-existing timeout\" --body \"pre-existing\" 2>&1"}}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh1","toolName":"bash","isError":true,"content":[{"type":"text","text":"GraphQL: Something went wrong while executing your query. Please include 'TOKEN' when reporting this issue.\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the gh issue create call failed with a GraphQL error, retrying.\n\n"},{"type":"toolCall","id":"call_gh2","name":"bash","arguments":{"command":"cd /tmp && gh issue create -R Nishfleet/0509 --title \"Pre-existing timeout\" --body \"pre-existing\" 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh2","toolName":"bash","isError":false,"content":[{"type":"text","text":"https://github.com/Nishfleet/0509/issues/1231"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now let me check sgscan.\n\n"}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "gh GraphQL retry with explicit flag should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "gh issue create GraphQL failure + explicit user-facing flag is clean"
rm -f "$sessions/gh-graphql-flagged.jsonl"

# --- 7. auto-file + dedupe --------------------------------------------------
write_session "swallowed" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err2.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "auto-file run should exit 1 (got $rc) $(cat "$scratch/err2.log")"
grep -q "FILED" "$scratch/err2.log" || { cat "$scratch/err2.log"; fail "auto-file did not file an issue"; }
grep -rq "signal: failed-command-flagged/" "$scratch/gh-issues" || fail "filed issue body missing signal key"
ok "auto-file creates an issue with the signal key"

set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err3.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "second auto-file run should still exit 1 (got $rc)"
grep -q "deduped" "$scratch/err3.log" || fail "second run did not dedupe $(cat "$scratch/err3.log")"
grep -rl "signal: failed-command-flagged/" "$scratch/gh-issues" | wc -l | grep -q "^1$" \
  || fail "signal key filed more than once (dedupe broken)"
ok "auto-file dedupes the signal key on a second run"
rm -f "$sessions/swallowed.jsonl"

# --- 7b. observe-to-close: clean tick closes the filed issue ----------------
# The auto-file run above filed one issue (issue-1.body) with a signal key.
# A clean tick (no findings) must close it via observe-to-close.
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-close.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "clean tick should exit 0 (got $rc) $(cat "$scratch/err-close.log")"
grep -q "observe-to-close: CLOSED" "$scratch/err-close.log" \
  || fail "clean tick did not close the filed issue $(cat "$scratch/err-close.log")"
[ -f "$gh_store/issue-1.closed" ] \
  || fail "issue-1 was not marked closed by observe-to-close"
grep -q "observe-to-close" "$gh_store/issue-1.close-comment" \
  || fail "close comment missing observe-to-close evidence"
ok "observe-to-close closes a filed issue on a clean tick"

# --- 7c. observe-to-close: still-active slug is NOT closed ------------------
# File a new issue, then run with the slug still in findings — must NOT close.
write_session "swallowed" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-noclose.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "active slug should exit 1 (got $rc)"
# The newly filed issue should NOT be closed (its slug is still in findings)
new_issue=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[ -f "$gh_store/issue-$new_issue.closed" ] \
  && fail "active slug issue #$new_issue was closed (should stay open)" || true
ok "observe-to-close leaves an active slug open"
rm -f "$sessions/swallowed.jsonl"

# --- 8. missing helper fails loud -------------------------------------------
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$scratch/no-such.py" \
FLEET_FAILED_COMMAND_FILE_ISSUES=0 \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err4.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "missing helper should exit 1 (got $rc)"
grep -q "FAILED-COMMAND-BROKEN" "$scratch/err4.log" || fail "missing helper must be LOUD"
ok "missing helper fails loud"

# --- 9. contracts -----------------------------------------------------------
grep -q 'fleet-failed-command-flagged' "$tier1" \
  || fail "fleet-heartbeat-tier1 must invoke fleet-failed-command-flagged"
grep -q 'failed_command_rc' "$tier1" \
  || fail "fleet-heartbeat-tier1 must propagate failed_command_rc"
grep -q 'bin/fleet-failed-command-flagged' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-failed-command-flagged"
grep -q 'lib/failed-command-flagged.py' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install lib/failed-command-flagged.py"
grep -Fq 'bash "$here/fleet-failed-command-flagged.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
jq -e '.rules[] | select(.id == "sr-failed-command-flagged" and .status == "enforced")' \
  "$repo_root/config/rule-enforcement.json" >/dev/null \
  || fail "sr-failed-command-flagged must be status=enforced in the matrix"
ok "contracts: heartbeat-tier1, MANIFEST, nested CI host, matrix enforced"

echo "OK: fleet-failed-command-flagged: rc canary, grep exemption, auto-file dedupe"
