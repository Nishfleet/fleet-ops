#!/usr/bin/env bash
# tests/fleet-failed-command-edit-unmatch.test.sh
#
# fleet-ops#956 / #965: an `edit` tool result with
#   "Could not find the exact text in <path>. The old text must match
#    exactly including all whitespace and newlines."
# is a real failure (the worker's `oldText` was stale) and must still be
# flagged when the worker walks past it. The worker almost always recovers
# by reading the file again to find the right text — that recovery is
# fine, but the failure must be NAMED in user-facing text in the same turn
# (fleet-ops#535 standing rule). A later `thinking` block that notices
# the file was different is not a user-facing flag.
#
# A future detector refactor must not silently drop the
# "Could not find the exact text" shape on the `edit` tool, the way the
# "Offset N is beyond end of file" shape is exempt on the `read` tool.
# No `lib/failed-command-flagged.py` exemption — a suppression would
# silence a real signal. The auto-filed issue closes via observe-to-close
# (fleet-ops#758) when the session mtime ages out of the 24h window after
# 2026-08-27T11:57:42Z.
#
# Live session: 2026-08-26T11-57-42-915Z_01a03dee-ea83-759b-8044-ba3adddcbe8b.jsonl
# The same session was also auto-filed as leftover duplicates #965,
# #970, #975, #980 (search-index delay, fleet-ops#951). The shape lock
# lives here; leftover-duplicate observe-to-close drain lives in
# tests/fleet-failed-command-observe-duplicate-open.test.sh (#965).
# The worker edited
#   /home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py
# with a stale `oldText` (`def fetch_0509_search(query: str, retries: int = 2)`).
# The edit tool returned isError=true, details={}, and the exact-text
# message (no "Command exited with code" line). The next turns were a
# silent `read`, a grep for the function, more reads, and a thinking
# block "Ah, the file is different from what I had in mind" — never a
# user-facing flag.
#
# Scenarios:
#   1. live #956 shape: edit unmatch + silent read/grep recovery -> finding.
#   2. same shape plus a later thinking-only note that the file was
#      different -> still a finding (thinking is not a flag).
#   3. same shape plus later unrelated user-facing prose that does NOT
#      name the failure -> still a finding.
#   4. same shape plus a later "the edit call failed" user-facing flag
#      -> clean.

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
  touch -d "2026-08-26T12:56:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-26T13:30:00Z"
}

# --- 1. live #956 shape: edit unmatch + silent read/grep recovery ----------
# The live session slug 01a03dee was filed because an `edit` of
# discover_v2.py returned isError=true with the exact-text message,
# details={}, and no "Command exited with code" line. The assistant's
# next turns were a `read` of the same path and a grep for the function,
# with no user-facing text. Replay that exact shape.
write_session "edit-unmatch-walked-past" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit1","name":"edit","arguments":{"path":"/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py","edits":[{"oldText":"def fetch_0509_search(query: str, retries: int = 2) -> dict:"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit1","toolName":"edit","content":[{"type":"text","text":"Could not find the exact text in /home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py. The old text must match exactly including all whitespace and newlines."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read1","name":"read","arguments":{"path":"/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py","offset":196,"limit":30}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read1","toolName":"read","isError":false,"content":[{"type":"text","text":"                      and 0 < len(s.split()) <= 4]"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_grep1","name":"bash","arguments":{"command":"grep -n \"def fetch_0509_search\" /home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_grep1","toolName":"bash","isError":false,"content":[{"type":"text","text":"414:def fetch_0509_search(query: str, mode: str = \"keyword\", *,"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #956 edit unmatch walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Could not find the exact text' <<<"$snippet" \
  || fail "finding snippet should mention Could not find the exact text (got $snippet)"
grep -q 'discover_v2.py' <<<"$snippet" \
  || fail "finding snippet should mention discover_v2.py (got $snippet)"
ok "live #956: edit 'Could not find the exact text' with silent read/grep recovery is flagged"
rm -f "$sessions/edit-unmatch-walked-past.jsonl"

# --- 2. live #956 thinking-only recovery is still a finding ----------------
# After the silent read, the live session's next assistant turn was a
# `thinking` block ("Ah, the file is different from what I had in mind")
# plus another toolCall. Thinking is not a user-facing flag (fleet-ops#535
# / #953). Pin that a future `_text_chunks` change that starts collecting
# `thinking` fields still cannot discharge this class unless FLAG_RE
# matches — and this thinking text does not.
write_session "edit-unmatch-thinking-only" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit2","name":"edit","arguments":{"path":"/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py","edits":[{"oldText":"def fetch_0509_search(query: str, retries: int = 2) -> dict:"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit2","toolName":"edit","content":[{"type":"text","text":"Could not find the exact text in /home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py. The old text must match exactly including all whitespace and newlines."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Ah, the file is different from what I had in mind — it was already updated with retry logic. Let me re-read the whole script."},{"type":"toolCall","id":"call_wc","name":"bash","arguments":{"command":"wc -l /home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "edit unmatch with thinking-only recovery should be a finding (got $count) $report"
ok "live #956: edit unmatch with later thinking-only recovery is still flagged"
rm -f "$sessions/edit-unmatch-thinking-only.jsonl"

# --- 3. later unrelated user-facing prose does not discharge ---------------
# Same class as #936's 6j: real user-facing text that moves on without
# naming the failure must NOT clear the pending swallowed failure.
write_session "edit-unmatch-unrelated-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit3","name":"edit","arguments":{"path":"/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py","edits":[{"oldText":"def fetch_0509_search(query: str, retries: int = 2) -> dict:"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit3","toolName":"edit","content":[{"type":"text","text":"Could not find the exact text in /home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py. The old text must match exactly including all whitespace and newlines."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read3","name":"read","arguments":{"path":"/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py","offset":414,"limit":60}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read3","toolName":"read","isError":false,"content":[{"type":"text","text":"def fetch_0509_search(query: str, mode: str = \"keyword\", *, ..."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The file has been heavily modified already. Let me look at the rest of the pipeline."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "edit unmatch followed by unrelated prose should be a finding (got $count) $report"
ok "live #956: edit unmatch with later unrelated user-facing prose is still flagged"
rm -f "$sessions/edit-unmatch-unrelated-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean ------------------
# The standing rule is satisfied when the assistant names the failure in
# user-facing text. The detector must NOT flag this.
write_session "edit-unmatch-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit4","name":"edit","arguments":{"path":"/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py","edits":[{"oldText":"def fetch_0509_search(query: str, retries: int = 2) -> dict:"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit4","toolName":"edit","content":[{"type":"text","text":"Could not find the exact text in /home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py. The old text must match exactly including all whitespace and newlines."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the edit call failed with Could not find the exact text — oldText was stale, reading the file to find the right offset."},{"type":"toolCall","id":"call_read4","name":"read","arguments":{"path":"/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py","offset":414,"limit":60}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "edit unmatch with later user-facing flag should be clean (got $count) $report"
ok "edit 'Could not find the exact text' plus later user-facing flag is clean"
rm -f "$sessions/edit-unmatch-flagged.jsonl"

echo "OK: fleet-failed-command-edit-unmatch: live #956 edit 'Could not find the exact text' drills"
