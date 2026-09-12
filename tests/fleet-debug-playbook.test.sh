#!/usr/bin/env bash
# tests/fleet-debug-playbook.test.sh
#
# fleet-ops#522: session-close lint for "debugging sessions end with a
# playbook note". Offline. Live gh is stubbed. Proves:
#   1. Clean assistant text / successful toolResult -> exit 0, DEBUG-PLAYBOOK-OK.
#   2. One real failure, no playbook -> exit 0 (not this rule; #535 owns it).
#   3. Two real failures, no playbook -> exit 1.
#   4. Two real failures plus four-heading playbook in assistant text -> exit 0.
#   5. Two real failures plus playbook in a write tool argument -> exit 0.
#   6. Two real failures plus incomplete playbook (no DEAD ENDS) -> exit 1.
#   6b. Two real failures plus playbook headings only in a toolResult read -> exit 1.
#   7. Two grep/rg exit 1 (POSIX no-match) -> exit 0.
#   7b. Two schema-validation-only isError toolResults -> exit 0 (formatting
#       error, not a debug attempt — fleet-ops#2210).
#   8. Auto-file with signal key, deduped on a second run.
#   9. Missing helper fails loud.
#  10. Contracts: heartbeat wiring, MANIFEST, nested CI host, matrix enforced.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-debug-playbook"
lib="$repo_root/lib/debug-playbook.py"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t debug-playbook.XXXXXX)"
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
          body=$(tail -n +2 "$f")
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"title":"","body":%s}' "$n" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")"
        done
        printf '\n]\n'
        ;;
      close)
        num=""
        for arg in "$@"; do
          case "$arg" in
            [0-9]*) num="$arg"; break ;;
          esac
        done
        [ -n "$num" ] || exit 1
        # Rename the issue body file so a subsequent list no longer sees it.
        if [ -f "$store/issue-$num.body" ]; then
          mv "$store/issue-$num.body" "$store/closed-$num.body" 2>/dev/null || true
        fi
        echo "closed #$num"
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
  FLEET_DEBUG_PLAYBOOK_SESSIONS="$scratch/sessions" \
  FLEET_DEBUG_PLAYBOOK_LIB="$lib" \
  FLEET_DEBUG_PLAYBOOK_WINDOW_HOURS="24" \
  FLEET_DEBUG_PLAYBOOK_GRACE_MINUTES="0" \
  FLEET_DEBUG_PLAYBOOK_NOW="2026-08-27T00:10:00Z" \
  FLEET_DEBUG_PLAYBOOK_FILE_ISSUES="$file_issues" \
  FLEET_DEBUG_PLAYBOOK_ISSUE_REPO="Nishfleet/fleet-ops" \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$gh_store" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

FAIL_ONE='{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_a","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_a","toolName":"bash","isError":true,"content":[{"type":"text","text":"Command exited with code 1"}]}}'

FAIL_TWO='{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_a","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_a","toolName":"bash","isError":true,"content":[{"type":"text","text":"Command exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_b","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_b","toolName":"bash","isError":true,"content":[{"type":"text","text":"Command exited with code 1"}]}}'

PLAYBOOK_TEXT='SIGNATURE: Command exited with code 1
ROOT CAUSE: missing helper on PATH
FIX THAT WORKED: install the helper and re-run
DEAD ENDS: chmod +x on the wrong path — did not work, do not retry'

# --- 1. clean session -------------------------------------------------------
write_session "clean" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Ran the canary. It passed."},{"type":"toolCall","id":"call_ok","name":"bash","arguments":{"command":"true"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"ok"}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "clean session should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "DEBUG-PLAYBOOK-OK" "$scratch/err.log" || fail "clean session missing OK line"
ok "clean session exits 0"

# --- 2. single failure, no playbook -----------------------------------------
write_session "once" "$FAIL_ONE
{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Fixed it.\"}]}}"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "single failure should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "single failure is not this rule"

# --- 3. two failures, no playbook -------------------------------------------
write_session "twice" "$FAIL_TWO
{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Fixed it.\"}]}}"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "two failures without playbook should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "DEBUG-PLAYBOOK-MISSING" "$scratch/err.log" || fail "two failures missing LOUD tag $(cat "$scratch/err.log")"
ok "two failures without playbook exit 1"
rm -f "$sessions/twice.jsonl"

# --- 4. two failures + playbook in assistant text ---------------------------
write_session "noted" "$FAIL_TWO
$(python3 -c 'import json,sys; print(json.dumps({"type":"message","message":{"role":"assistant","content":[{"type":"text","text":sys.argv[1]}]}}))' "$PLAYBOOK_TEXT")"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "playbook in assistant text should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "playbook in assistant text exits 0"
rm -f "$sessions/noted.jsonl"

# --- 5. two failures + playbook in write arguments --------------------------
write_session "vaultwrite" "$FAIL_TWO
$(python3 -c 'import json,sys; print(json.dumps({"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_w","name":"write","arguments":{"path":"/vault/note.md","contents":sys.argv[1]}}]}}))' "$PLAYBOOK_TEXT")
{\"type\":\"message\",\"message\":{\"role\":\"toolResult\",\"toolCallId\":\"call_w\",\"toolName\":\"write\",\"isError\":false,\"content\":[{\"type\":\"text\",\"text\":\"wrote\"}]}}"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "playbook in write args should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "playbook in write arguments exits 0"
rm -f "$sessions/vaultwrite.jsonl"

# --- 6. incomplete playbook (no DEAD ENDS) ----------------------------------
incomplete='SIGNATURE: Command exited with code 1
ROOT CAUSE: missing helper
FIX THAT WORKED: install it'
write_session "incomplete" "$FAIL_TWO
$(python3 -c 'import json,sys; print(json.dumps({"type":"message","message":{"role":"assistant","content":[{"type":"text","text":sys.argv[1]}]}}))' "$incomplete")"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "incomplete playbook should exit 1 (got $rc) $(cat "$scratch/err.log")"
ok "incomplete playbook (no DEAD ENDS) exits 1"
rm -f "$sessions/incomplete.jsonl"

# --- 6b. standing-rules read in toolResult must not count as filing ---------
write_session "readrules" "$FAIL_TWO
{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"call_r\",\"name\":\"read\",\"arguments\":{\"path\":\"global-standing-rules.md\"}}]}}
$(python3 -c 'import json,sys; print(json.dumps({"type":"message","message":{"role":"toolResult","toolCallId":"call_r","toolName":"read","isError":False,"content":[{"type":"text","text":sys.argv[1]}]}}))' "$PLAYBOOK_TEXT")
{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Fixed it.\"}]}}"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "read of playbook headings should not count as filing (got $rc) $(cat "$scratch/err.log")"
ok "standing-rules read in toolResult does not count as a playbook"
rm -f "$sessions/readrules.jsonl"

# --- 7. two grep exit 1 (POSIX no-match) ------------------------------------
write_session "greps" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"g1","name":"bash","arguments":{"command":"grep foo bar"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"g1","toolName":"bash","isError":true,"content":[{"type":"text","text":"Command exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"g2","name":"bash","arguments":{"command":"rg baz qux"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"g2","toolName":"bash","isError":true,"content":[{"type":"text","text":"Command exited with code 1"}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "grep no-match pair should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "grep/rg exit 1 pair is skipped"
rm -f "$sessions/greps.jsonl"

# --- 7c. two `ls` existence-probe exit 2 (POSIX no-match, fleet-ops#4512) ---
# `ls <missing-path>` exits 2 with "cannot access ...: No such file or
# directory". The failed-command doctrine names `ls` as a no-match probe;
# it must not count as a real debug attempt. Fixtures are written with
# python3 because the expected text embeds shell single quotes.
python3 - <<PYEOF
import json
lines = [
  {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"l1","name":"bash","arguments":{"command":"ls bin/fleet-no-agent-names-check bin/missing-helper 2>&1"}}]}},
  {"type":"message","message":{"role":"toolResult","toolCallId":"l1","toolName":"bash","isError":True,"content":[{"type":"text","text":"ls: cannot access 'bin/fleet-no-agent-names-check': No such file or directory\nls: cannot access 'bin/missing-helper': No such file or directory\nCommand exited with code 2"}]}},
  {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"l2","name":"bash","arguments":{"command":"ls /tmp/also-missing 2>&1"}}]}},
  {"type":"message","message":{"role":"toolResult","toolCallId":"l2","toolName":"bash","isError":True,"content":[{"type":"text","text":"ls: cannot access '/tmp/also-missing': No such file or directory\nCommand exited with code 2"}]}}
]
with open("$sessions/lsprobe.jsonl","w") as f:
    f.write("\n".join(json.dumps(o) for o in lines) + "\n")
PYEOF
touch -d "2026-08-27T00:00:00Z" "$sessions/lsprobe.jsonl" 2>/dev/null; touch -d "2026-08-27T00:00:00Z" "$sessions/compound.jsonl" 2>/dev/null; touch -d "2026-08-27T00:00:00Z" "$sessions/mixederr.jsonl" 2>/dev/null
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "ls no-match pair should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "ls exit 2 no-match pair is skipped (fleet-ops#4512)"
rm -f "$sessions/lsprobe.jsonl"

# --- 7d. compound `ls bin/ | head` + ls probes + one real failure (#4512) ---
# The real 0509-1279 shape: stdout listing plus ls no-match stderr, exit 2.
# Only the real failure counts -> below the two-attempt floor -> exit 0.
python3 - <<PYEOF
import json
lines = [
  {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"cd /srv/fleet && ls bin/ 2>&1 | head -30; echo ---; ls bin/fleet-no-agent-names-check bin/_dirty-worktree-audit.py 2>&1"}}]}},
  {"type":"message","message":{"role":"toolResult","toolCallId":"c1","toolName":"bash","isError":True,"content":[{"type":"text","text":"agent-cron-run\n_dirty-worktree-audit.py\n---\nls: cannot access 'bin/fleet-no-agent-names-check': No such file or directory\nls: cannot access 'bin/_dirty-worktree-audit.py': No such file or directory\nCommand exited with code 2"}]}},
  {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"false"}}]}},
  {"type":"message","message":{"role":"toolResult","toolCallId":"c2","toolName":"bash","isError":True,"content":[{"type":"text","text":"Command exited with code 1"}]}}
]
with open("$sessions/compound.jsonl","w") as f:
    f.write("\n".join(json.dumps(o) for o in lines) + "\n")
PYEOF
touch -d "2026-08-27T00:00:00Z" "$sessions/lsprobe.jsonl" 2>/dev/null; touch -d "2026-08-27T00:00:00Z" "$sessions/compound.jsonl" 2>/dev/null; touch -d "2026-08-27T00:00:00Z" "$sessions/mixederr.jsonl" 2>/dev/null
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "compound ls-probe + one real failure should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "compound ls-probe command counts as one attempt, not two (fleet-ops#4512)"
rm -f "$sessions/compound.jsonl"

# --- 7e. exit 2 with ls no-match AND a real error is still real --------------
# Fail-closed guard: the ls exemption must not swallow mixed failures.
python3 - <<PYEOF
import json
lines = [
  {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"m1","name":"bash","arguments":{"command":"ls /tmp/x 2>&1; some-thing-fatal"}}]}},
  {"type":"message","message":{"role":"toolResult","toolCallId":"m1","toolName":"bash","isError":True,"content":[{"type":"text","text":"ls: cannot access '/tmp/x': No such file or directory\nfatal: bad config\nCommand exited with code 2"}]}},
  {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"m2","name":"bash","arguments":{"command":"false"}}]}},
  {"type":"message","message":{"role":"toolResult","toolCallId":"m2","toolName":"bash","isError":True,"content":[{"type":"text","text":"Command exited with code 1"}]}}
]
with open("$sessions/mixederr.jsonl","w") as f:
    f.write("\n".join(json.dumps(o) for o in lines) + "\n")
PYEOF
touch -d "2026-08-27T00:00:00Z" "$sessions/lsprobe.jsonl" 2>/dev/null; touch -d "2026-08-27T00:00:00Z" "$sessions/compound.jsonl" 2>/dev/null; touch -d "2026-08-27T00:00:00Z" "$sessions/mixederr.jsonl" 2>/dev/null
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "mixed ls-probe + real error pair should exit 1 (got $rc) $(cat "$scratch/err.log")"
ok "mixed ls-probe + real error still counts as a real attempt"
rm -f "$sessions/mixederr.jsonl"

# --- 7b. two schema-validation-only isError toolResults (fleet-ops#2210) -----
# A cheap model sent a malformed tool call (wrong arg name / {} arguments),
# Pi rejected it with isError=true + "Validation failed for tool", the model
# retried with correct args and succeeded. No debugging happened — the model
# just fixed its formatting. The canary must NOT file this (fleet-ops#2210).
write_session "schemaval" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"sv1","name":"bash","arguments":{}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"sv1","toolName":"bash","isError":true,"content":[{"type":"text","text":"Validation failed for tool \"bash\": - command: must have required properties command"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"sv2","name":"edit","arguments":{"edits":[]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"sv2","toolName":"edit","isError":true,"content":[{"type":"text","text":"Validation failed for tool \"edit\": - edits.0: must have object"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Fixed the formatting and retried; it worked."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "schema-validation-only pair should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "schema-validation-only isError pair is skipped (fleet-ops#2210)"
rm -f "$sessions/schemaval.jsonl"

# --- 7f. two SPAWN_BLOCKED-only isError toolResults (fleet-ops#4620) -----------
# A spawn-guard block (SPAWN_BLOCKED reason=...) means the command never ran;
# it is not a ran-and-failed command (fleet-ops#648, same class as the Pi
# confirmation-prompt "Dangerous command blocked"). lib/failed-command-flagged.py
# exempts it; the debug-playbook detector must too, or a SPAWN_BLOCKED is counted
# as a real failed attempt and can push a session over the two-attempt threshold
# into a false DEBUG-PLAYBOOK-MISSING alarm (fleet-ops#4620).
write_session "spawnblock" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"sb1","name":"bash","arguments":{"command":"rm -rf /home/nish/workspaces/x"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"sb1","toolName":"bash","isError":true,"content":[{"type":"text","text":"SPAWN_BLOCKED reason=rm_rf_home_or_workspaces. Recursive delete under /home/nish or workspaces/ is forbidden. Delete the exact paths you created, by name."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"sb2","name":"bash","arguments":{"command":"rm -rf /home/nish/workspaces/y"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"sb2","toolName":"bash","isError":true,"content":[{"type":"text","text":"SPAWN_BLOCKED reason=rm_rf_home_or_workspaces. Recursive delete under /home/nish or workspaces/ is forbidden. Delete the exact paths you created, by name."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "SPAWN_BLOCKED-only pair should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "SPAWN_BLOCKED-only isError pair is skipped (fleet-ops#4620)"
rm -f "$sessions/spawnblock.jsonl"

# --- 7h. printed text containing the exit phrase must not count (#4979) -----
# A sed/cat/deep-read of a file that CONTAINS the literal string
# `Command exited with code 1` (e.g. a session fixture or a cited log) is
# text the command merely PRINTED; the command itself exited 0. Before the
# fix, `_exit_code` searched the whole result text and counted each printed
# occurrence as a real failed attempt — a false two-attempt block on a
# session whose every command succeeded (fleet-ops#4949 live session).
python3 - "$sessions" <<'PYEOF'
import json, sys
sessions = sys.argv[1]
text = "Command exited with code 1\nCommand exited with code 1\nsome fixture body"
lines = [
  {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"s1","name":"bash","arguments":{"command":"sed -n '120,200p' tests/pi-issue-run-debug-playbook-gate.test.sh"}}]}},
  {"type":"message","message":{"role":"toolResult","toolCallId":"s1","toolName":"bash","isError":False,"content":[{"type":"text","text":text + "\nCommand exited with code 0"}]}},
  {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"s2","name":"bash","arguments":{"command":"cat tests/fleet-debug-playbook.test.sh | head"}}]}},
  {"type":"message","message":{"role":"toolResult","toolCallId":"s2","toolName":"bash","isError":False,"content":[{"type":"text","text":text + "\nCommand exited with code 0"}]}}
]
with open(sessions + "/printexit.jsonl","w") as f:
    f.write("\n".join(json.dumps(o) for o in lines) + "\n")
PYEOF
touch -d "2026-08-27T00:00:00Z" "$sessions/printexit.jsonl"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "printed-exit-text session should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "mid-body printed 'Command exited with code' text is not a failed attempt (#4979)"
rm -f "$sessions/printexit.jsonl"

# --- 7i. the gate's own probe must not ratchet the count (#4979) ------------
# `fleet-debug-playbook gate <session>` exits 1 BY DESIGN when the session is
# blocked; that rc=1 is a check exit code, not a work failure. Counting it
# raises the very count under inspection (attempts went 2 -> 4 in the live
# #4949 session).
python3 - "$sessions" <<'PYEOF'
import json, sys
sessions = sys.argv[1]
lines = [
  {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"p1","name":"bash","arguments":{"command":"fleet-debug-playbook gate ~/.pi/agent/sessions/foo.jsonl"}}]}},
  {"type":"message","message":{"role":"toolResult","toolCallId":"p1","toolName":"bash","isError":True,"content":[{"type":"text","text":"{\"attempts\":\"2\"}\nCommand exited with code 1"}]}},
  {"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"p2","name":"bash","arguments":{"command":"python3 lib/debug-playbook.py gate --path foo.jsonl"}}]}},
  {"type":"message","message":{"role":"toolResult","toolCallId":"p2","toolName":"bash","isError":True,"content":[{"type":"text","text":"{\"attempts\":\"4\"}\nCommand exited with code 1"}]}}
]
with open(sessions + "/gateprobe.jsonl","w") as f:
    f.write("\n".join(json.dumps(o) for o in lines) + "\n")
PYEOF
touch -d "2026-08-27T00:00:00Z" "$sessions/gateprobe.jsonl"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "gate self-probe pair should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "gate self-probe exit-1 does not ratchet the count (fleet-ops#4979)"
rm -f "$sessions/gateprobe.jsonl"

# --- 7j. a real rc!=0 command still counts (fail-closed guard) --------------
# The trailing-status discriminator must not weaken the real signal: a real
# isError=true harness status line is still the final non-empty line.
write_session "stillreal" "$FAIL_TWO"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "real failing pair should still exit 1 (got $rc) $(cat "$scratch/err.log")"
ok "trailing-status real failures still count after the #4979 fix"
rm -f "$sessions/stillreal.jsonl"

# --- 7g. two edit no-op-only isError toolResults (fleet-ops#4946) -----------
# An `edit` tool no-op "No changes made to <path>. The replacement produced
# identical content" is the edit-tool analog of a grep/rg/diff/ls no-match:
# the tool completed and the file is already in the requested state. Counting
# it as a real failed attempt could push a normal implementation session over
# the two-attempt threshold into a false DEBUG-PLAYBOOK-GATE-BLOCK alarm
# (the live fleet-ops#4946 alarm surfaced exactly this: a pricing test edit
# no-op plus a gh field typo). The gate exists for multi-attempt DEBUGGING
# sessions without a playbook note (fleet-ops#522); a no-op edit is not one.
write_session "editnoop" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"en1","name":"edit","arguments":{"path":"/tmp/x.ts","edits":[{"oldText":"a","newText":"b"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"en1","toolName":"edit","isError":true,"content":[{"type":"text","text":"No changes made to /tmp/x.ts. The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"en2","name":"edit","arguments":{"path":"/tmp/x.ts","edits":[{"oldText":"c","newText":"d"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"en2","toolName":"edit","isError":true,"content":[{"type":"text","text":"No changes made to /tmp/x.ts. The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "edit no-op-only pair should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "edit no-op-only isError pair is skipped (fleet-ops#4946)"
rm -f "$sessions/editnoop.jsonl"

# --- 8. auto-file + dedupe --------------------------------------------------
write_session "swallowed" "$FAIL_TWO
{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Fixed it.\"}]}}"
set +e
FLEET_DEBUG_PLAYBOOK_SESSIONS="$scratch/sessions" \
FLEET_DEBUG_PLAYBOOK_LIB="$lib" \
FLEET_DEBUG_PLAYBOOK_WINDOW_HOURS="24" \
FLEET_DEBUG_PLAYBOOK_GRACE_MINUTES="0" \
FLEET_DEBUG_PLAYBOOK_NOW="2026-08-27T00:10:00Z" \
FLEET_DEBUG_PLAYBOOK_FILE_ISSUES=1 \
FLEET_DEBUG_PLAYBOOK_AGGREGATE=0 \
FLEET_DEBUG_PLAYBOOK_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err2.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "auto-file run should exit 1 (got $rc) $(cat "$scratch/err2.log")"
grep -q "FILED" "$scratch/err2.log" || { cat "$scratch/err2.log"; fail "auto-file did not file an issue"; }
grep -rq "signal: debug-playbook/" "$scratch/gh-issues" || fail "filed issue body missing signal key"
ok "auto-file creates an issue with the signal key"

set +e
FLEET_DEBUG_PLAYBOOK_SESSIONS="$scratch/sessions" \
FLEET_DEBUG_PLAYBOOK_LIB="$lib" \
FLEET_DEBUG_PLAYBOOK_WINDOW_HOURS="24" \
FLEET_DEBUG_PLAYBOOK_GRACE_MINUTES="0" \
FLEET_DEBUG_PLAYBOOK_NOW="2026-08-27T00:10:00Z" \
FLEET_DEBUG_PLAYBOOK_FILE_ISSUES=1 \
FLEET_DEBUG_PLAYBOOK_AGGREGATE=0 \
FLEET_DEBUG_PLAYBOOK_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err3.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "second auto-file run should still exit 1 (got $rc)"
grep -q "deduped" "$scratch/err3.log" || fail "second run did not dedupe $(cat "$scratch/err3.log")"
grep -rl "signal: debug-playbook/" "$scratch/gh-issues" | wc -l | grep -q "^1$" \
  || fail "signal key filed more than once (dedupe broken)"
ok "auto-file dedupes the signal key on a second run"
rm -f "$sessions/swallowed.jsonl"

# --- 8b. age-based dynamic cap: in-window findings are never truncated ---
# fleet-ops#2726: the old cumulative cap silently dropped findings past
# CUMULATIVE_CAP open issues (the gap-audit found 46 of 66 debug-playbook
# findings sitting in the canary ledger as invisible debt). The effective
# cap now grows to cover every finding still inside the scan window
# (eff_cap = max(CUMULATIVE_CAP, findings)), so 5 in-window findings with
# CUMULATIVE_CAP=3 must FILE ALL 5 (paced by the per-tick CAP), and the
# FAIL line must size the remaining debt.
rm -rf "$gh_store"/*
mkdir -p "$gh_store"
for i in one two three four five; do
  write_session "cap-$i" "$FAIL_TWO
{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Fixed it.\"}]}}"
done
set +e
FLEET_DEBUG_PLAYBOOK_SESSIONS="$scratch/sessions" \
FLEET_DEBUG_PLAYBOOK_LIB="$lib" \
FLEET_DEBUG_PLAYBOOK_WINDOW_HOURS="24" \
FLEET_DEBUG_PLAYBOOK_GRACE_MINUTES="0" \
FLEET_DEBUG_PLAYBOOK_NOW="2026-08-27T00:10:00Z" \
FLEET_DEBUG_PLAYBOOK_FILE_ISSUES=1 \
FLEET_DEBUG_PLAYBOOK_CUMULATIVE_CAP=3 \
FLEET_DEBUG_PLAYBOOK_AGGREGATE=0 \
FLEET_DEBUG_PLAYBOOK_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-cap.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "age-cap run should exit 1 (got $rc)"
n_filed=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$n_filed" -eq 5 ]] || fail "dynamic cap must file all 5 in-window findings (got $n_filed) — in-window findings are never truncated (fleet-ops#2726)"
grep -qE "debt=[0-9]+" "$scratch/err-cap.log" || fail "FAIL line must size the debt (fleet-ops#2726)"
ok "dynamic cap files all in-window findings and sizes the debt on the FAIL line"
for i in one two three four five; do rm -f "$sessions/cap-$i.jsonl"; done

# --- 8b-prime. per-tick CAP paces filings; deferred findings remain findings -----
# Paced findings are NOT dropped: they stay in the window and the next tick
# files them (observe-to-close drains once the session ages out). With a
# per-tick CAP of 2 and 5 findings, the first tick files 2 and defers 3; the
# FAIL line reports filed=2 deferred=3.
rm -rf "$gh_store"/*
mkdir -p "$gh_store"
for i in one two three four five; do
  write_session "pace-$i" "$FAIL_TWO
{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Fixed it.\"}]}}"
done
set +e
FLEET_DEBUG_PLAYBOOK_SESSIONS="$scratch/sessions" \
FLEET_DEBUG_PLAYBOOK_LIB="$lib" \
FLEET_DEBUG_PLAYBOOK_WINDOW_HOURS="24" \
FLEET_DEBUG_PLAYBOOK_GRACE_MINUTES="0" \
FLEET_DEBUG_PLAYBOOK_NOW="2026-08-27T00:10:00Z" \
FLEET_DEBUG_PLAYBOOK_FILE_ISSUES=1 \
FLEET_DEBUG_PLAYBOOK_CAP=2 \
FLEET_DEBUG_PLAYBOOK_CUMULATIVE_CAP=3 \
FLEET_DEBUG_PLAYBOOK_AGGREGATE=0 \
FLEET_DEBUG_PLAYBOOK_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-pace.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "pace run should exit 1 (got $rc)"
n_filed=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$n_filed" -eq 2 ]] || fail "per-tick CAP should file 2 in the first tick (got $n_filed)"
grep -q "filed=2 deferred=3" "$scratch/err-pace.log" || fail "FAIL line must report filed=2 deferred=3 $(cat "$scratch/err-pace.log")"
# Second tick: the remaining 3 findings are still in the window (not dropped),
# so the same scan files them once the first 2 are deduped against the open
# list. Default per-tick CAP (5) lets the backlog drain.
set +e
FLEET_DEBUG_PLAYBOOK_SESSIONS="$scratch/sessions" \
FLEET_DEBUG_PLAYBOOK_LIB="$lib" \
FLEET_DEBUG_PLAYBOOK_WINDOW_HOURS="24" \
FLEET_DEBUG_PLAYBOOK_GRACE_MINUTES="0" \
FLEET_DEBUG_PLAYBOOK_NOW="2026-08-27T00:10:00Z" \
FLEET_DEBUG_PLAYBOOK_FILE_ISSUES=1 \
FLEET_DEBUG_PLAYBOOK_CUMULATIVE_CAP=3 \
FLEET_DEBUG_PLAYBOOK_AGGREGATE=0 \
FLEET_DEBUG_PLAYBOOK_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-pace2.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "second pace run should exit 1 (got $rc)"
n_filed=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$n_filed" -eq 5 ]] || fail "second tick must file the remaining 3 (got $n_filed) — deferred findings are not dropped (fleet-ops#2726)"
ok "deferred findings survive the next tick and still get filed"
for i in one two three four five; do rm -f "$sessions/pace-$i.jsonl"; done

# --- 8c. observe-to-close closes stale issues -------------------------------
rm -rf "$gh_store"/*
mkdir -p "$gh_store"
# Pre-create two open issues: one for a session still in findings, one stale.
# The gh stub lists and renumbers *.body files sequentially, so use 1/2.
cat >"$gh_store/issue-1.body" <<'BODY'
title
fix(debug-playbook): stale-session — multi-attempt debug with no playbook note

signal: debug-playbook/stale-session
BODY
cat >"$gh_store/issue-2.body" <<'BODY'
title
fix(debug-playbook): live-session — multi-attempt debug with no playbook note

signal: debug-playbook/live-session
BODY
write_session "live-session" "$FAIL_TWO
{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Fixed it.\"}]}}"
set +e
FLEET_DEBUG_PLAYBOOK_SESSIONS="$scratch/sessions" \
FLEET_DEBUG_PLAYBOOK_LIB="$lib" \
FLEET_DEBUG_PLAYBOOK_WINDOW_HOURS="24" \
FLEET_DEBUG_PLAYBOOK_GRACE_MINUTES="0" \
FLEET_DEBUG_PLAYBOOK_NOW="2026-08-27T00:10:00Z" \
FLEET_DEBUG_PLAYBOOK_FILE_ISSUES=1 \
FLEET_DEBUG_PLAYBOOK_OK_TO_CLOSE=1 \
FLEET_DEBUG_PLAYBOOK_AGGREGATE=0 \
FLEET_DEBUG_PLAYBOOK_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-close.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "observe-to-close run should exit 1 for live finding (got $rc)"
[[ -f "$gh_store/closed-1.body" ]] || fail "stale issue #1 should be closed"
[[ -f "$gh_store/issue-2.body" ]] || fail "live issue #2 should stay open"
grep -q "CLOSED issue #1" "$scratch/err-close.log" || fail "close log missing for #1"
ok "observe-to-close closes stale debug-playbook issues only"
rm -f "$sessions/live-session.jsonl"

# --- 8e. aggregate mode (fleet-ops#4384) -------------------------------------
# With FLEET_DEBUG_PLAYBOOK_AGGREGATE=1 (default) and multiple in-window
# findings, exactly ONE aggregate issue per day is created (title carries the
# date + count, body lists paths + slugs, deduped by signal: debug-playbook/
# <date>). A second scan run does not create another. No per-slug ticket is
# ever auto-created again (regression pin).
rm -rf "$gh_store"/*
mkdir -p "$gh_store"
for i in agg-one agg-two agg-three; do
  write_session "$i" "$FAIL_TWO
{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Fixed it.\"}]}}"
done
set +e
FLEET_DEBUG_PLAYBOOK_SESSIONS="$scratch/sessions" \
FLEET_DEBUG_PLAYBOOK_LIB="$lib" \
FLEET_DEBUG_PLAYBOOK_WINDOW_HOURS="24" \
FLEET_DEBUG_PLAYBOOK_GRACE_MINUTES="0" \
FLEET_DEBUG_PLAYBOOK_NOW="2026-08-27T00:10:00Z" \
FLEET_DEBUG_PLAYBOOK_FILE_ISSUES=1 \
FLEET_DEBUG_PLAYBOOK_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-agg.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "aggregate run should exit 1 (got $rc) $(cat "$scratch/err-agg.log")"
grep -q "FILED aggregate 2026-08-27" "$scratch/err-agg.log" \
  || fail "aggregate run did not file the daily aggregate $(cat "$scratch/err-agg.log")"
n_issues=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$n_issues" -eq 1 ]] || fail "aggregate mode must file exactly ONE issue for 3 findings (got $n_issues)"
grep -rq "signal: debug-playbook/2026-08-27" "$gh_store" \
  || fail "aggregate issue body missing the date signal key"
# Regression pin: no per-slug ticket is auto-created in aggregate mode.
if grep -rqE "signal: debug-playbook/(agg-one|agg-two|agg-three)" "$gh_store"; then
  fail "aggregate mode must NOT auto-create per-slug tickets (fleet-ops#4384)"
fi
ok "aggregate mode files exactly one daily issue, no per-slug tickets"

# Second scan run: the aggregate is deduped, no new issue is created.
set +e
FLEET_DEBUG_PLAYBOOK_SESSIONS="$scratch/sessions" \
FLEET_DEBUG_PLAYBOOK_LIB="$lib" \
FLEET_DEBUG_PLAYBOOK_WINDOW_HOURS="24" \
FLEET_DEBUG_PLAYBOOK_GRACE_MINUTES="0" \
FLEET_DEBUG_PLAYBOOK_NOW="2026-08-27T00:10:00Z" \
FLEET_DEBUG_PLAYBOOK_FILE_ISSUES=1 \
FLEET_DEBUG_PLAYBOOK_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-agg2.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "second aggregate run should exit 1 (got $rc)"
grep -q "already open (deduped)" "$scratch/err-agg2.log" \
  || fail "second aggregate run did not dedupe $(cat "$scratch/err-agg2.log")"
n_issues=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$n_issues" -eq 1 ]] || fail "second aggregate run must not create another issue (got $n_issues)"
ok "aggregate dedupes on a second scan run"
for i in agg-one agg-two agg-three; do rm -f "$sessions/$i.jsonl"; done

# --- 8e-prime. aggregate observe-to-close -----------------------------------
# An aggregate issue for a date with no remaining finding closes. Pre-create
# an aggregate issue for a PAST date (2026-08-26) whose sessions are gone, and
# one for the CURRENT date (2026-08-27) that still has a finding. The past
# aggregate closes; the current one stays open.
rm -rf "$gh_store"/*
mkdir -p "$gh_store"
cat >"$gh_store/issue-1.body" <<'BODY'
title
fix(debug-playbook): 2026-08-26 — 2 sessions missing playbook notes

signal: debug-playbook/2026-08-26
BODY
cat >"$gh_store/issue-2.body" <<'BODY'
title
fix(debug-playbook): 2026-08-27 — 1 session missing playbook notes

signal: debug-playbook/2026-08-27
BODY
write_session "agg-live" "$FAIL_TWO
{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Fixed it.\"}]}}"
set +e
FLEET_DEBUG_PLAYBOOK_SESSIONS="$scratch/sessions" \
FLEET_DEBUG_PLAYBOOK_LIB="$lib" \
FLEET_DEBUG_PLAYBOOK_WINDOW_HOURS="24" \
FLEET_DEBUG_PLAYBOOK_GRACE_MINUTES="0" \
FLEET_DEBUG_PLAYBOOK_NOW="2026-08-27T00:10:00Z" \
FLEET_DEBUG_PLAYBOOK_FILE_ISSUES=1 \
FLEET_DEBUG_PLAYBOOK_OK_TO_CLOSE=1 \
FLEET_DEBUG_PLAYBOOK_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-aggclose.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "aggregate observe-to-close run should exit 1 for live finding (got $rc)"
[[ -f "$gh_store/closed-1.body" ]] || fail "past-date aggregate #1 should be closed"
[[ -f "$gh_store/issue-2.body" ]] || fail "current-date aggregate #2 should stay open"
grep -q "CLOSED aggregate issue #1" "$scratch/err-aggclose.log" \
  || fail "aggregate close log missing for #1 $(cat "$scratch/err-aggclose.log")"
ok "aggregate observe-to-close closes a past-date aggregate, keeps the live one"
rm -f "$sessions/agg-live.jsonl"

# --- 8d. gate subcommand -----------------------------------------------------
good_session='{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"ok","name":"bash","arguments":{"command":"true"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"ok"}]}}'
printf '%s\n' "$good_session" >"$scratch/good.jsonl"
set +e
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" "$bin" gate "$scratch/good.jsonl" >/dev/null 2>"$scratch/err-gate-good.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "gate should exit 0 for clean session (got $rc)"
write_session "bad-gate" "$FAIL_TWO"
set +e
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" "$bin" gate "$sessions/bad-gate.jsonl" >/dev/null 2>"$scratch/err-gate-bad.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "gate should exit 1 for missing playbook (got $rc)"
grep -q "DEBUG-PLAYBOOK-GATE-BLOCK" "$scratch/err-gate-bad.log" || fail "gate block tag missing"
ok "gate subcommand blocks missing-playbook sessions"
rm -f "$sessions/bad-gate.jsonl"

# --- 9. missing helper fails loud -------------------------------------------
set +e
FLEET_DEBUG_PLAYBOOK_SESSIONS="$scratch/sessions" \
FLEET_DEBUG_PLAYBOOK_LIB="$scratch/no-such.py" \
FLEET_DEBUG_PLAYBOOK_FILE_ISSUES=0 \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err4.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "missing helper should exit 1 (got $rc)"
grep -q "DEBUG-PLAYBOOK-BROKEN" "$scratch/err4.log" || fail "missing helper must be LOUD"
ok "missing helper fails loud"

# --- 10. contracts ----------------------------------------------------------
grep -q 'fleet-debug-playbook' "$tier1" \
  || fail "fleet-heartbeat-tier1 must invoke fleet-debug-playbook"
grep -q 'debug_playbook_rc' "$tier1" \
  || fail "fleet-heartbeat-tier1 must propagate debug_playbook_rc"
grep -q 'FLEET_DEBUG_PLAYBOOK_OK_TO_CLOSE=1' "$tier1" \
  || fail "fleet-heartbeat-tier1 must set FLEET_DEBUG_PLAYBOOK_OK_TO_CLOSE=1 (fleet-ops#4384 — production is the only caller trusted to close)"
grep -q 'FLEET_DEBUG_PLAYBOOK_AGGREGATE' "$bin" \
  || fail "bin/fleet-debug-playbook must gate aggregate filing on FLEET_DEBUG_PLAYBOOK_AGGREGATE (fleet-ops#4384)"
grep -q 'bin/fleet-debug-playbook' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-debug-playbook"
grep -q 'lib/debug-playbook.py' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install lib/debug-playbook.py"
grep -Fq 'bash "$here/fleet-debug-playbook.test.sh"' "$here/seat.lib.test.sh" \
  || fail "seat.lib.test.sh must nest this file (CI cannot gain a new workflow line)"
jq -e '.rules[] | select(.id == "sr-debug-playbook" and .status == "enforced")' \
  "$repo_root/config/rule-enforcement.json" >/dev/null \
  || fail "sr-debug-playbook must be status=enforced in the matrix"
ok "contracts: heartbeat-tier1, MANIFEST, nested CI host, matrix enforced"

echo "OK: fleet-debug-playbook: two-attempt canary, playbook shape, auto-file dedupe"
