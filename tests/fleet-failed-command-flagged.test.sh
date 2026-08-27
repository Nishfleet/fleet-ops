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
#   6d. Bash [N/M] progress + timeout, flag only in toolCall comment (live #686) -> exit 1.
#   6e. Bash [N/M] progress + timeout, real user-facing flag -> exit 0.
#   7. Auto-file with signal key, deduped on a second run.
#   7b. Origin #650: cp /tmp/install.sh cannot-stat walked past -> exit 1.
#   7c. Same snippet plus a later flag -> exit 0.
#   8. Missing helper fails loud.
#   9. Contracts: heartbeat wiring, MANIFEST, nested CI host, matrix enforced.
#  10. Observe-to-close: a green tick comments resolved-at on an aged-out
#      signal; a later tick with that marker closes; a still-dirty slug is
#      neither commented nor closed (fleet-ops#650).
#  11. Observe-to-close lifecycle for the live #791 canary exit-1
#      walked-past shape: in-window is still-dirty, aged-out comments
#      resolved-at, next tick closes (fleet-ops#791).

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
        printf '[\n'
        first=1
        for f in "$store"/issue-*.body; do
          [ -f "$f" ] || continue
          num=$(basename "$f" .body)
          num=${num#issue-}
          [ -f "$store/issue-${num}.closed" ] && continue
          body=$(tail -n +2 "$f")
          comments_file="$store/issue-${num}.comments"
          if [ -f "$comments_file" ]; then
            comments_json=$(python3 -c 'import json,sys;print(json.dumps([{"body": sys.stdin.read()}]))' <"$comments_file")
          else
            comments_json='[]'
          fi
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"title":"","body":%s,"comments":%s}' "$num" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")" "$comments_json"
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

# --- 4b. ls no-match (exit 2) is a probe, not a swallowed failure -----------
write_session "ls-nomatch" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ls","name":"bash","arguments":{"command":"cd /tmp && echo \"---\"; ls nonexistent-glob-* 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ls","toolName":"bash","isError":true,"content":[{"type":"text","text":"---\n\n\nCommand exited with code 2"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"No matching files. Continuing."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "ls no-match exit 2 should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "ls no-match (exit 2) is treated as a probe, not a swallowed failure"
rm -f "$sessions/ls-nomatch.jsonl"

# --- 4c. which no-match (exit 1) is a probe, not a swallowed failure --------
write_session "which-nomatch" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_which","name":"bash","arguments":{"command":"which nonexistent-binary 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_which","toolName":"bash","isError":true,"content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Binary not in PATH. Need to install or use full path."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "which no-match exit 1 should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "which no-match (exit 1) is treated as a probe, not a swallowed failure"
rm -f "$sessions/which-nomatch.jsonl"

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

# --- 6d. long-running bash probe with [N/M] progress, timed out, no flag ----
# Live #686 (0509 competitor discovery spike, session 2026-08-26T12-22:28Z):
# the bash command printed [N/M] progress, ran for 17/35 then the
# orchestrator killed it (Command timed out after 1500 seconds). The next
# assistant turn was a toolCall whose COMMAND ARGUMENT included a
# "# Got 17/35 done" comment — but no user-facing text. The detector
# correctly flags this. Lock the shape so a future detector refactor
# cannot accidentally drop the progress-output / partial-completion class.
write_session "bash-progress-timedout" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe","name":"bash","arguments":{"command":"for q in running_shoes wool_shoes sustainable_fashion note_taking_app productivity_app team_wiki smart_ring fitness_tracker sleep_tracker beauty_products indian_cosmetics skincare fitness_apparel athletic_wear gym_clothing crm_software marketing_automation; do\n  curl -sS -A 'Mozilla/5.0' \"https://0509.io/search?q=$q\" > /tmp/probe-$q.html\n  echo \"[$(date +%s)] $q done\"\n  sleep 35\ndone\n# 35 probes × 35s = ~21 min"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe","toolName":"bash","isError":true,"content":[{"type":"text","text":"[1/35] running shoes done\n[2/35] wool shoes done\n[3/35] sustainable fashion done\n[4/35] note taking app done\n[5/35] productivity app done\n[6/35] team wiki done\n[7/35] smart ring done\n[8/35] fitness tracker done\n[9/35] sleep tracker done\n[10/35] beauty products done\n[11/35] indian cosmetics done\n[12/35] skincare done\n[13/35] fitness apparel done\n[14/35] athletic wear done\n[15/35] gym clothing done\n[16/35] crm software done\n[17/35] marketing automation done\n\n\nCommand timed out after 1500 seconds"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_check","name":"bash","arguments":{"command":"# Got 17/35 done. Let me check status and continue\ntail -50 /tmp/probe.log\necho '---'\ndate"}}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "bash progress [N/M] + timeout with no flag should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err.log" \
  || fail "bash progress + timeout must be flagged as swallowed"
grep -q "running shoes done" "$scratch/err.log" \
  || fail "the [N/M] progress snippet must be in the loud line (live #686 shape)"
ok "bash [N/M] progress + timeout with no user-facing flag is swallowed (fleet-ops#686 shape locked)"
rm -f "$sessions/bash-progress-timedout.jsonl"

# --- 6e. long-running bash probe with [N/M] progress, timeout, with flag ---
# Same shape as 6d, but the next assistant turn has a real user-facing
# text flag ("the probe loop timed out at 17/35, ..."). The detector must
# not flag this. This is the proof the standing rule still works on the
# progress-output class: a worker that names the gap in user-facing text
# passes, a worker that only puts it in a toolCall comment (live #686) is filed.
write_session "bash-progress-flagged" "$(cat <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe2","name":"bash","arguments":{"command":"for q in running_shoes wool_shoes sustainable_fashion note_taking_app; do\n  curl -sS \"https://0509.io/search?q=$q\" > /tmp/probe-$q.html\n  echo \"[$q done]\"\n  sleep 35\ndone"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe2","toolName":"bash","isError":true,"content":[{"type":"text","text":"[1/4] running shoes done\n[2/4] wool shoes done\n[3/4] sustainable fashion done\n[4/4] note taking app done\n\n\nCommand timed out after 1500 seconds"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the probe loop call failed with a timeout at 4/4, the rest is unverified."},{"type":"toolCall","id":"call_resume","name":"bash","arguments":{"command":"tail -50 /tmp/probe.log"}}]}}
JSONL
)"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "bash progress + timeout with explicit flag should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "bash [N/M] progress + timeout with explicit user-facing flag is clean"
rm -f "$sessions/bash-progress-flagged.jsonl"

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

# --- 7b. origin #650: cp /tmp/install.sh cannot-stat walked past -------------
write_session "install-cp" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cp","name":"bash","arguments":{"command":"cp /tmp/install.sh /tmp/agent-cron-seat.6nGbWr/install.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cp","toolName":"bash","isError":true,"content":[{"type":"text","text":"Scratch: /tmp/agent-cron-seat.6nGbWr cp: cannot stat '"'"'/tmp/install.sh'"'"': No such file or directory\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next check."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "origin #650 cp /tmp/install.sh walked past should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err.log" || fail "origin #650 missing SWALLOWED loud line"
ok "origin #650: cp /tmp/install.sh cannot-stat walked past is flagged"
rm -f "$sessions/install-cp.jsonl"

# --- 7c. same snippet plus a later flag is clean ----------------------------
write_session "install-cp-flagged" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cp","name":"bash","arguments":{"command":"cp /tmp/install.sh /tmp/agent-cron-seat.6nGbWr/install.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cp","toolName":"bash","isError":true,"content":[{"type":"text","text":"Scratch: /tmp/agent-cron-seat.6nGbWr cp: cannot stat '"'"'/tmp/install.sh'"'"': No such file or directory\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the cp failed: /tmp/install.sh was not found, it is now the blocker."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "flagged #650 snippet should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "origin #650 snippet plus later flag is clean"
rm -f "$sessions/install-cp-flagged.jsonl"

# --- 10. observe-to-close (fleet-ops#650) -----------------------------------
# Isolate the mock store from the auto-file test's leftover issue-1.body.
rm -f "$gh_store"/issue-* "$gh_store"/commented "$gh_store"/closed
: >"$gh_store/commented"
: >"$gh_store/closed"
slug650="2026-08-26t08-55-06-528z-01a03d47-bc20-7470-8847-4b42403ff341"
printf '%s\n' "fix(failed-command): $slug650" >"$gh_store/issue-650.body"
printf '%s\n' "Do not close until the detector reports this clean.

signal: failed-command-flagged/${slug650}" >>"$gh_store/issue-650.body"

# Green tick (clean session only) comments resolved-at; does not close yet
# (marker must already be present from a prior tick, same as #521).
write_session "clean-observe" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Ran the canary. It passed."},{"type":"toolCall","id":"call_ok","name":"bash","arguments":{"command":"true"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"ok"}]}}'
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_CLOSE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-obs.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "observe-to-close green tick should exit 0 (got $rc) $(cat "$scratch/err-obs.log")"
grep -q "OBSERVED-RESOLVED" "$scratch/err-obs.log" || fail "green tick must log OBSERVED-RESOLVED $(cat "$scratch/err-obs.log")"
grep -q '^650$' "$gh_store/commented" || fail "green tick must comment on #650 (commented=$(cat "$gh_store/commented"))"
grep -q "resolved-at: signal: failed-command-flagged/${slug650}" "$gh_store/issue-650.comments" \
  || fail "comment missing resolved-at marker"
if [ -s "$gh_store/closed" ]; then
  fail "same-tick must not close (closed=$(cat "$gh_store/closed"))"
fi
ok "observe-to-close: green tick comments resolved-at, does not close same tick"
rm -f "$sessions/clean-observe.jsonl"

# Later tick: marker already present, slug still absent -> close
: >"$gh_store/commented"
: >"$gh_store/closed"
write_session "clean-observe2" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Still clean."}]}}'
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_CLOSE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-close.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "observe close tick should exit 0 (got $rc) $(cat "$scratch/err-close.log")"
grep -q "OBSERVE-CLOSED" "$scratch/err-close.log" || fail "later tick must log OBSERVE-CLOSED $(cat "$scratch/err-close.log")"
grep -q '^650$' "$gh_store/closed" || fail "later tick must close #650 (closed=$(cat "$gh_store/closed"))"
if [ -s "$gh_store/commented" ]; then
  fail "later tick must not comment again (commented=$(cat "$gh_store/commented"))"
fi
ok "observe-to-close: later tick with resolved-at marker closes"
rm -f "$sessions/clean-observe2.jsonl"

# Still-dirty slug: even with a resolved-at marker, do not close
: >"$gh_store/commented"
: >"$gh_store/closed"
# Re-open for the dirty tick (the previous tick closed it in the mock).
rm -f "$gh_store/issue-650.closed"
write_session "still-dirty" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cp","name":"bash","arguments":{"command":"cp /tmp/install.sh /tmp/x"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cp","toolName":"bash","isError":true,"content":[{"type":"text","text":"Scratch: /tmp/agent-cron-seat.6nGbWr cp: cannot stat '"'"'/tmp/install.sh'"'"': No such file or directory\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'
# Force the session slug to match issue 650's signal by using that filename.
mv "$sessions/still-dirty.jsonl" "$sessions/${slug650}.jsonl"
touch -d "2026-08-27T00:00:00Z" "$sessions/${slug650}.jsonl"
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_CLOSE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-dirty.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "still-dirty slug should exit 1 (got $rc) $(cat "$scratch/err-dirty.log")"
if [ -s "$gh_store/closed" ]; then
  fail "still-dirty slug must not close (closed=$(cat "$gh_store/closed"))"
fi
if [ -s "$gh_store/commented" ]; then
  fail "still-dirty slug must not comment resolved-at (commented=$(cat "$gh_store/commented"))"
fi
ok "observe-to-close: still-dirty slug is neither commented nor closed"
rm -f "$sessions/${slug650}.jsonl"

# --- 11. observe-to-close lifecycle for the live #791 canary exit-1 shape ---
# fleet-ops#791: the 2026-08-27T00-01:33 session (slug 01a04085) is the
# canary exit-1 walked-past class. While the session mtime is in the 24h
# window the detector keeps flagging the slug, and the auto-file dedup
# leaves the open issue untouched. Once the session ages out of the
# window the slug drops off the findings list, the same-tick
# observe-to-close comments resolved-at, and the next tick closes the
# issue. This drills the full lifecycle on the live slug so a future
# detector refactor cannot regress the canary class to a never-closes
# state — the canary exit-1 is real, the issue must still close when
# the session ages out (no stuck-open auto-files).
rm -f "$gh_store"/issue-* "$gh_store"/commented "$gh_store"/closed
: >"$gh_store/commented"
: >"$gh_store/closed"
slug791="2026-08-27t00-01-33-243z-01a04085-9c3b-7194-a332-20e86c213e81"
printf '%s\n' "fix(failed-command): $slug791" >"$gh_store/issue-791.body"
printf '%s\n' "Do not close until the detector reports this clean.

signal: failed-command-flagged/${slug791}" >>"$gh_store/issue-791.body"

# Replay the live #727/#791 canary exit-1 walked-past shape and pin the
# session mtime to T0 (2026-08-27T00:01:00Z) so window/grace math is
# deterministic across ticks.
cat >"$sessions/${slug791}.jsonl" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_canary","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-0509-973 && timeout 1800 npm run canary:bet2 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_canary","toolName":"bash","isError":true,"content":[{"type":"text","text":"{\n  \"termination\": {\n    \"pass\": false,\n    \"checks\": [\n      {\"name\": \"zero_dead_ends\", \"ok\": false, \"observed\": 2, \"threshold\": 0, \"detail\": \"dead-end empty states: 2\"}\n    ]\n  }\n}\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The canary ran and shows current state. Let me triage the results."}]}}
{"type":"message","message":{"role":"toolCall","id":"call_probe","name":"bash","arguments":{"command":"for domain in salesforce.com shopify.com; do\n  echo -n \"$domain: \"\n  curl -s --max-time 10 \"https://0509.io/search?website=$domain\" 2>&1 | grep -oE '\"rowCount\":[0-9]+' | head -1\ndone"}}]}}
JSONL
touch -d "2026-08-27T00:01:00Z" "$sessions/${slug791}.jsonl"

# Tick A: in-window, slug is a finding, auto-file deduped on open #791.
# Observe-to-close is skipped (still-dirty). Exit 1. No comment, no close.
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_CLOSE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-791a.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "live #791 in-window tick should exit 1 (got $rc) $(cat "$scratch/err-791a.log")"
grep -q "FAILED-COMMAND-SWALLOWED" "$scratch/err-791a.log" \
  || fail "in-window tick must log the slug as swallowed (live #791 shape)"
if [ -s "$gh_store/commented" ]; then
  fail "in-window tick must not comment (still-dirty, commented=$(cat "$gh_store/commented"))"
fi
if [ -s "$gh_store/closed" ]; then
  fail "in-window tick must not close (still-dirty, closed=$(cat "$gh_store/closed"))"
fi
ok "live #791: in-window tick leaves the open issue untouched (still-dirty)"

# Tick B: 24h+1min past session mtime, session is skipped_old, slug is
# not a finding. Auto-file deduped (signal in open). Observe-to-close
# comments resolved-at. Exit 0. Same-tick must NOT close.
: >"$gh_store/commented"
: >"$gh_store/closed"
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-28T00:02:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_CLOSE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-791b.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "live #791 aged-out tick should exit 0 (got $rc) $(cat "$scratch/err-791b.log")"
grep -q "OBSERVED-RESOLVED" "$scratch/err-791b.log" \
  || fail "aged-out tick must log OBSERVED-RESOLVED (got $(cat "$scratch/err-791b.log"))"
grep -q '^791$' "$gh_store/commented" \
  || fail "aged-out tick must comment on #791 (commented=$(cat "$gh_store/commented"))"
grep -q "resolved-at: signal: failed-command-flagged/${slug791}" "$gh_store/issue-791.comments" \
  || fail "comment missing resolved-at marker"
if [ -s "$gh_store/closed" ]; then
  fail "aged-out tick must not close (same-tick, closed=$(cat "$gh_store/closed"))"
fi
ok "live #791: aged-out tick comments resolved-at, does not close same tick"

# Tick C: marker already present, slug still absent -> close. Exit 0.
: >"$gh_store/commented"
: >"$gh_store/closed"
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-28T00:02:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_CLOSE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-791c.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "live #791 close tick should exit 0 (got $rc) $(cat "$scratch/err-791c.log")"
grep -q "OBSERVE-CLOSED" "$scratch/err-791c.log" \
  || fail "close tick must log OBSERVE-CLOSED (got $(cat "$scratch/err-791c.log"))"
grep -q '^791$' "$gh_store/closed" \
  || fail "close tick must close #791 (closed=$(cat "$gh_store/closed"))"
if [ -s "$gh_store/commented" ]; then
  fail "close tick must not comment again (commented=$(cat "$gh_store/commented"))"
fi
ok "live #791: later tick with resolved-at marker closes"
rm -f "$sessions/${slug791}.jsonl"

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

echo "OK: fleet-failed-command-flagged: rc canary, grep/ls/which no-match exemption, auto-file dedupe, observe-to-close"
