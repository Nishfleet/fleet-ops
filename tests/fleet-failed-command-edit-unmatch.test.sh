#!/usr/bin/env bash
# tests/fleet-failed-command-edit-unmatch.test.sh
#
# fleet-ops#652: a `edit` tool result with the message
#   "Could not find the exact text in <path>. The old text must match
#    exactly including all whitespace and newlines."
# is a real failure (the worker's `oldText` was wrong) and must still be
# flagged when the worker walks past it. The worker almost always recovers
# by reading the file again to find the right text — that recovery is
# fine, but the failure must be NAMED in user-facing text in the same turn
# (fleet-ops#535 standing rule).
#
# A future detector refactor must not silently drop the
# "Could not find the exact text" shape on the `edit` tool, the way the
# "Offset N is beyond end of file" shape is exempt on the `read` tool.
# These two scenarios lock the shape.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-edit-unmatch.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-26T11:57:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-26T12:10:00Z"
}

# --- 1. live #652 shape: edit 'Could not find the exact text' -> read -> walk
# The pi-issue-fleet-ops-307 worker at 2026-08-26T11:57:42Z hit this exact
# text: an `edit` call returned isError=true with the 'Could not find the
# exact text' message, the worker moved to a `read` to find the right
# offset, and never named the failure in user-facing text. The detector
# must still flag it (no exemption). A future detector refactor that
# generalises an ENOENT-style exemption across all `isError: true` tool
# results would silently regress this class.
write_session "edit-unmatch-walked-past" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit1","name":"edit","arguments":{"path":"/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py","edits":[{"oldText":"def fetch_0509_search(query: str, retries: int = 2) -> dict:"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit1","toolName":"edit","isError":true,"content":[{"type":"text","text":"Could not find the exact text in /home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py. The old text must match exactly including all whitespace and newlines."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read1","name":"read","arguments":{"path":"/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py","offset":414,"limit":60}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read1","toolName":"read","isError":false,"content":[{"type":"text","text":"def fetch_0509_search(query: str, mode: str = \"keyword\", *, ..."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now let me try with the right offset."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "edit 'Could not find the exact text' walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
case "$snippet" in
  "Could not find the exact text in"*) ok "edit 'Could not find the exact text' is a finding (fleet-ops#652 shape locked)" ;;
  *) fail "unexpected snippet: $snippet" ;;
esac
rm -f "$sessions/edit-unmatch-walked-past.jsonl"

# --- 2. same shape + later flag is clean (proves the rule still works) ------
# Same shape as #652, but the assistant names the failure in the very next
# turn — the standing rule says a failed command is ALWAYS flagged. The
# detector must clear on a named failure so the worker can recover
# (read the file, retry the edit) without being told to repeat the call.
# This is the proof the rule still works on the #652 shape: a worker that
# names the failure passes; a worker that walks past it (the live #652
# case) fails.
write_session "edit-unmatch-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit2","name":"edit","arguments":{"path":"/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py","edits":[{"oldText":"def fetch_0509_search(query: str, retries: int = 2) -> dict:"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit2","toolName":"edit","isError":true,"content":[{"type":"text","text":"Could not find the exact text in /home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py. The old text must match exactly including all whitespace and newlines."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the edit call failed because the oldText did not match exactly — let me read the file to find the right offset."},{"type":"toolCall","id":"call_read2","name":"read","arguments":{"path":"/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py","offset":414,"limit":60}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read2","toolName":"read","isError":false,"content":[{"type":"text","text":"def fetch_0509_search(query: str, mode: str = \"keyword\", *, ..."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now retrying with the correct text."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "edit 'Could not find the exact text' with later flag should be clean (got $count) $report"
ok "edit 'Could not find the exact text' with a later flag is clean"

echo "OK: fleet-failed-command-edit-unmatch: 'Could not find the exact text' shape on edit is a real failure when walked past, clean when flagged"
