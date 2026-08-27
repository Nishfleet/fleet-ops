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

echo "OK: fleet-failed-command-read: offset negative result, real read failure still flagged"
