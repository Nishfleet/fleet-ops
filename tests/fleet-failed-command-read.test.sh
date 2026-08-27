#!/usr/bin/env bash
# tests/fleet-failed-command-read.test.sh
#
# fleet-ops#651: a read tool result with the offset past the end of the
# file is a negative result, not a swallowed command failure. Real read
# failures (ENOENT, permission denied, etc.) are still findings.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-read.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-26T09:20:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-26T09:30:00Z"
}

# --- 1. read offset beyond end is a negative result, not a finding ----------
write_session "read-offset" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read","name":"read","arguments":{"path":"/home/nish/workspaces/agent-worktrees/issue-0509-1099/AGENTS.md","offset":40}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read","toolName":"read","isError":true,"content":[{"type":"text","text":"Offset 40 is beyond end of file (33 lines total)"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "read offset beyond end should not be a finding (got $count) $report"
ok "read offset beyond end is not a swallowed failure"
rm -f "$sessions/read-offset.jsonl"

# --- 2. real read failure (ENOENT) is still a finding -----------------------
write_session "read-enoent" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read2","name":"read","arguments":{"path":"/nonexistent/file.txt"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read2","toolName":"read","isError":true,"content":[{"type":"text","text":"Failed to read /nonexistent/file.txt: No such file or directory"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Proceeding."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "real read failure should be a finding (got $count) $report"
ok "real read failure is still flagged"
rm -f "$sessions/read-enoent.jsonl"

# --- 3. a later explicit flag keeps the result clean ------------------------
write_session "read-offset-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read3","name":"read","arguments":{"path":"/some/file.md","offset":99}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read3","toolName":"read","isError":true,"content":[{"type":"text","text":"Offset 99 is beyond end of file (5 lines total)"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the read call failed because the offset was beyond the file."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged read offset beyond end should be clean (got $count) $report"
ok "flagged read offset beyond end is clean"

# --- 4. live #664 shape: ENOENT 'access <path>' on a read tool --------------
# The pi-issue-fleet-ops-239 worker hit this exact text and walked past it
# without naming the failure in later text. The detector must still flag it.
# Without this drill a future change to the detector could drop the
# 'access <path>' shape (e.g. by adding a generic ENOENT exemption) and
# silently regress the class fleet-ops#664 is filed for.
write_session "read-enoent-access" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read4","name":"read","arguments":{"path":"/home/nish/workspaces/products/fleet-ops/tests/fleet-heartbeat-verify-timers.test.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read4","toolName":"read","isError":true,"content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/products/fleet-ops/tests/fleet-heartbeat-verify-timers.test.sh'"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now let me check the diff."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "ENOENT 'access <path>' should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
[[ "$snippet" == "ENOENT: no such file or directory, access '/home/nish/workspaces/products/fleet-ops/tests/fleet-heartbeat-verify-timers.test.sh'" ]] \
    || fail "unexpected snippet: $snippet"
ok "ENOENT 'access <path>' on read is a finding (fleet-ops#664 shape locked)"
rm -f "$sessions/read-enoent-access.jsonl"

# --- 5. ENOENT 'access <path>' + later flag is clean (proves the rule) ------
# Same shape as #664 but the assistant names the failure in the very next
# turn. The standing rule says: a failed command is ALWAYS flagged. The
# detector must clear on a named failure, so the worker can recover without
# being told to repeat the call. This is the proof that the rule still works
# on the #664 shape — a worker that names the failure passes; a worker that
# walks past it (the live #664 case) fails.
write_session "read-enoent-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read5","name":"read","arguments":{"path":"/home/nish/workspaces/products/fleet-ops/tests/fleet-heartbeat-verify-timers.test.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read5","toolName":"read","isError":true,"content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/products/fleet-ops/tests/fleet-heartbeat-verify-timers.test.sh'"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the read call failed with ENOENT — the test file is not on this local checkout. Continuing from the diff in PR #166."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged ENOENT 'access <path>' should be clean (got $count) $report"
ok "flagged ENOENT 'access <path>' is clean"
rm -f "$sessions/read-enoent-flagged.jsonl"

echo "OK: fleet-failed-command-read: offset negative result, real read failure still flagged, ENOENT access-path class locked"
