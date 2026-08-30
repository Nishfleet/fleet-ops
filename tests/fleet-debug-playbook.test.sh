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

# --- 8b. cumulative cap bounds total open issues -----------------------------
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
FLEET_DEBUG_PLAYBOOK_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-cap.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "cumulative-cap run should exit 1 (got $rc)"
n_filed=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$n_filed" -eq 3 ]] || fail "cumulative cap should file exactly 3 issues, got $n_filed"
grep -q "cumulative cap reached" "$scratch/err-cap.log" || fail "cumulative cap log line missing"
ok "cumulative cap bounds total filed issues at 3"
for i in one two three four five; do rm -f "$sessions/cap-$i.jsonl"; done

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
grep -q 'bin/fleet-debug-playbook' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-debug-playbook"
grep -q 'lib/debug-playbook.py' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install lib/debug-playbook.py"
grep -Fq 'bash "$here/fleet-debug-playbook.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
jq -e '.rules[] | select(.id == "sr-debug-playbook" and .status == "enforced")' \
  "$repo_root/config/rule-enforcement.json" >/dev/null \
  || fail "sr-debug-playbook must be status=enforced in the matrix"
ok "contracts: heartbeat-tier1, MANIFEST, nested CI host, matrix enforced"

echo "OK: fleet-debug-playbook: two-attempt canary, playbook shape, auto-file dedupe"
