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
# fleet-ops#1053: the same edit-unmatch class but with the
#   "Found N occurrences of the text in <path>. The text must be unique."
# shape — the edit tool's oldText matched MULTIPLE locations in the file
# (not zero, as in #956/#965) — is also a real swallowed failure. The
# detector already catches it (isError=true on the `edit` tool), so this
# test pins that the "Found N occurrences" variant cannot be silently
# dropped by a future refactor that only checks for "Could not find".
# Live session: 2026-08-27T06:52:12-544Z_01a041fd-9380-77aa-adf8-f535436833e9.jsonl
# The auditor edited AUDITOR-LOG.md with oldText matching 42 occurrences;
# the edit tool returned isError=true with "Found 42 occurrences"; the
# next 4 assistant turns were empty and the session ended without naming
# the failure. The snippet is identical to the live detector finding.
#
# Live session: 2026-08-26T11-57:42-915Z_01a03dee-ea83-759b-8044-ba3adddcbe8b.jsonl
# The same session was also auto-filed as leftover duplicates #965,
# #970, #975, #980 (search-index delay, fleet-ops#951). The shape lock
# lives here; leftover-duplicate observe-to-close drain lives in
# tests/fleet-failed-command-observe-duplicate-open.test.sh (#965).
#
# Second live session of this class: 2026-08-27T08-42-19-241Z_01a04262-
# 62e9-7c55-8e9a-0ac4fdbc57d2, auto-filed as #1079. Same shape: the
# auditor's minimax-m3-free worker edited
# tests/seat-lib.test.sh with stale oldText (the insertion point line
# had drifted from an earlier nearby edit by the same session).
# The edit returned "Could not find the exact text in <path>",
# isError=true, details={}. The assistant walked past it with a
# silent `grep` recovery turn and never named the failure.
# observe-to-close: ages out at 2026-08-28T08:42:19Z.
# The worker edited
#   /home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/discover_v2.py
# with a stale `oldText` (`def fetch_0509_search(query: str, retries: int = 2)`).
# The edit tool returned isError=true, details={}, and the exact-text
# message (no "Command exited with code" line). The next turns were a
# silent `read`, a grep for the function, more reads, and a thinking
# block "Ah, the file is different from what I had in mind" — never a
# user-facing flag.
#
# fleet-ops#1139: the third sibling of this class is the NO-OP edit:
#   "No changes made to <path>. The replacement produced identical
#    content. This might indicate an issue with special characters or
#    the text not existing as expected."
# The edit tool matched, but the replacement equalled what was already
# there, so the intended change never landed. isError=true, details={},
# no "Command exited with code" line — the same envelope as #956/#1053.
# Live session: 2026-08-27T12-01-49-555Z_01a04319-09f3-7bed-ae2e-447e2307d778
# The worker was editing prompts/worker.md inside the issue-fleet-ops-1001
# worktree; the edit returned the no-op message; the next turn was
# cause-explaining prose ("The text is already the same. Let me check
# what's actually there:") plus a grep, then another grep, then four
# empty assistant turns. Cause prose is not a flag (same rule as the
# #1059 "The file was archived" shape). This is the shape most at risk
# of a future "benign no-op" exemption; scenarios 10-12 forbid it.
#
# Scenarios:
#   1. live #956 shape: edit unmatch + silent read/grep recovery -> finding.
#   2. same shape plus a later thinking-only note that the file was
#      different -> still a finding (thinking is not a flag).
#   3. same shape plus later unrelated user-facing prose that does NOT
#      name the failure -> still a finding.
#   4. same shape plus a later "the edit call failed" user-facing flag
#      -> clean.
#   5. live #1053 shape: edit "Found N occurrences" (multiple matches)
#      + empty assistant turns walking past -> finding. The detector must
#      flag this variant even when a refactor only pattern-matches the
#      0-match wording "Could not find". Live fingerprint: 4 empty
#      assistant turns with stopReason=error (503 overloaded).
#   6. same #1053 shape plus a later "the edit call failed" user-facing
#      flag -> clean.
#   7. worker.md cites fleet-ops#1053 and "Found N occurrences"
#      (prompt-side lock).
#   8. lib/failed-command-flagged.py docstring cites fleet-ops#1053
#      (detector-side lock).
#   9. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).
#  10. live #1139 shape: edit "No changes made ... The replacement
#      produced identical content" + cause-explaining prose ("The text
#      is already the same") + grep probes + empty turns -> finding.
#  11. same #1139 shape with only a silent grep recovery -> finding
#      (guards against a READ_OFFSET_RE-style no-op exemption).
#  12. same #1139 shape plus a later "the edit call failed" user-facing
#      flag -> clean.
#  13. worker.md cites fleet-ops#1139 and the no-op wording
#      (prompt-side lock).
#  14. lib/failed-command-flagged.py cites fleet-ops#1139
#      (detector-side lock).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"
worker="$repo_root/prompts/worker.md"

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

# --- 5. live #1053 shape: edit "Found N occurrences" + walked past ---------
# The live session slug 01a041fd was filed because an `edit` of
# AUDITOR-LOG.md returned isError=true with
# "Found 42 occurrences of the text in <path>. The text must be unique."
# (oldText matched multiple locations). The next 4 assistant turns were
# empty and the session ended without a user-facing flag. Replay that
# exact shape — the snippet must match the live detector finding.
write_session "edit-unmatch-found-occurrences" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit5","name":"edit","arguments":{"path":"/home/nish/workspaces/agent-state/AUDITOR-LOG.md","edits":[{"oldText":"If ALL five are clean, say so explicitly in your AUDITOR-LOG.md block\n(\"catch-all sweep: quiet on all 5 channels\") — quiet IS a valid outcome."}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit5","toolName":"edit","content":[{"type":"text","text":"Found 42 occurrences of the text in /home/nish/workspaces/agent-state/AUDITOR-LOG.md. The text must be unique. Please provide more context to make it unique."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[]}}
{"type":"message","message":{"role":"assistant","content":[]}}
{"type":"message","message":{"role":"assistant","content":[]}}
{"type":"message","message":{"role":"assistant","content":[]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "edit 'Found N occurrences' walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Found 42 occurrences' <<<"$snippet" \
  || fail "finding snippet should mention 'Found 42 occurrences' (got $snippet)"
grep -q 'AUDITOR-LOG.md' <<<"$snippet" \
  || fail "finding snippet should mention AUDITOR-LOG.md (got $snippet)"
ok "edit 'Found N occurrences' (multiple-match) unmatch with empty recovery turns is flagged"
rm -f "$sessions/edit-unmatch-found-occurrences.jsonl"

# --- 6. #1053 shape plus a later user-facing flag is clean -----------------
# Same discharge rule as scenario 4: naming the failure in user-facing
# text satisfies fleet-ops#535. Pin that FLAG_RE still matches this
# wording so a future FLAG_RE tighten cannot leave the 42-occurrence
# variant permanently pending.
write_session "edit-unmatch-found-occurrences-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit6","name":"edit","arguments":{"path":"/home/nish/workspaces/agent-state/AUDITOR-LOG.md","edits":[{"oldText":"If ALL five are clean, say so explicitly in your AUDITOR-LOG.md block\n(\"catch-all sweep: quiet on all 5 channels\") — quiet IS a valid outcome."}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit6","toolName":"edit","content":[{"type":"text","text":"Found 42 occurrences of the text in /home/nish/workspaces/agent-state/AUDITOR-LOG.md. The text must be unique. Please provide more context to make it unique."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the edit call failed with Found 42 occurrences — oldText matched multiple locations in AUDITOR-LOG.md, reading more context to make it unique."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "edit 'Found N occurrences' with later user-facing flag should be clean (got $count) $report"
ok "edit 'Found N occurrences' plus later user-facing flag is clean"
rm -f "$sessions/edit-unmatch-found-occurrences-flagged.jsonl"

# --- 7. worker.md cites fleet-ops#1053 (prompt-side lock) ------------------
# Dropping the #1053 citation or the live wording from the standing-rule
# paragraph is a regression even if the drill still passes: workers read
# worker.md, not this test.
grep -q 'fleet-ops#1053' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1053 (prompt-side lock for the Found N occurrences sibling shape)"
grep -q 'Found N occurrences' "$worker" \
  || fail "prompts/worker.md must name the live #1053 'Found N occurrences' wording so workers flag it"
grep -q 'AUDITOR-LOG.md' "$worker" \
  || fail "prompts/worker.md must name AUDITOR-LOG.md as the live #1053 path"
ok "worker.md cites fleet-ops#1053 and the live Found N occurrences wording"

# --- 8. lib/failed-command-flagged.py docstring cites fleet-ops#1053 ------
# The docstring is the standing-rule contract for the next detector
# maintainer. A future exemption for "Found N occurrences" (mirroring
# READ_OFFSET_RE) would silence this class; the docstring forbids it.
grep -q 'fleet-ops#1053' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1053 (detector-side lock)"
grep -q 'Found N occurrences' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live #1053 'Found N occurrences' wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1053 and Found N occurrences"

# --- 9. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ------
grep -Fq 'bash "$here/fleet-failed-command-edit-unmatch.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

# --- 10. live #1139 shape: no-op edit + cause prose + empty turns ---------
# Exact replay of session 01a04319: the `edit` of prompts/worker.md in the
# issue-fleet-ops-1001 worktree returned isError=true with the no-op
# message; the assistant answered with cause-explaining prose that names
# WHY the file was unchanged, never that the call failed, then grepped
# twice and emitted four empty turns. The snippet must match the live
# detector finding on issue #1139.
write_session "edit-noop-identical-content" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"I need to change the second occurrence to use `fleet-ops#1001` form. Let me update:"},{"type":"toolCall","id":"call_edit7","name":"edit","arguments":{"path":"/home/nish/workspaces/agent-worktrees/issue-fleet-ops-1001/prompts/worker.md","edits":[{"oldText":"fleet-ops#953, fleet-ops#958, #972, #967, #977, #1001","newText":"fleet-ops#953, fleet-ops#958, #972, #967, #977, #1001"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit7","toolName":"edit","content":[{"type":"text","text":"No changes made to /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1001/prompts/worker.md. The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The text is already the same. Let me check what's actually there:"},{"type":"toolCall","id":"call_grep7","name":"bash","arguments":{"command":"grep -o 'fleet-ops#953, fleet-ops#958, #972, #967, #977, #1001' /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1001/prompts/worker.md 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_grep7","toolName":"bash","isError":false,"content":[{"type":"text","text":"fleet-ops#953, fleet-ops#958, #972, #967, #977, #1001"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The chain has `fleet-ops#953, fleet-ops#958, #972, #967, #977, #1001` in the prompt. Let me look at the line number:"},{"type":"toolCall","id":"call_grep8","name":"bash","arguments":{"command":"grep -n 'fleet-ops#953, fleet-ops#958, #972, #967, #977, #1001' /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1001/prompts/worker.md 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_grep8","toolName":"bash","isError":false,"content":[{"type":"text","text":"28:- A failed command (non-zero exit, isError, timeout, GraphQL/HTTP error) is ALWAYS flagged"}]}}
{"type":"message","message":{"role":"assistant","content":[]}}
{"type":"message","message":{"role":"assistant","content":[]}}
{"type":"message","message":{"role":"assistant","content":[]}}
{"type":"message","message":{"role":"assistant","content":[]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1139 no-op edit walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'The replacement produced identical content' <<<"$snippet" \
  || fail "finding snippet should mention the no-op wording (got $snippet)"
grep -q 'issue-fleet-ops-1001/prompts/worker.md' <<<"$snippet" \
  || fail "finding snippet should mention the edited path (got $snippet)"
ok "live #1139: no-op edit with cause-explaining prose recovery is flagged"
rm -f "$sessions/edit-noop-identical-content.jsonl"

# --- 11. #1139 shape with a silent grep recovery only ---------------------
# The no-op wording is the shape most likely to attract a future
# "nothing actually broke" exemption mirroring READ_OFFSET_RE. It is not
# a negative-result probe: the worker asked for an edit and the edit did
# not happen. Pin that the bare shape is still a finding.
write_session "edit-noop-silent-recovery" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit8","name":"edit","arguments":{"path":"/home/nish/workspaces/agent-worktrees/issue-fleet-ops-1001/prompts/worker.md","edits":[{"oldText":"#977, #1001","newText":"#977, #1001"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit8","toolName":"edit","content":[{"type":"text","text":"No changes made to /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1001/prompts/worker.md. The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_grep9","name":"bash","arguments":{"command":"grep -c 'fleet-ops#1001' /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1001/prompts/worker.md"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_grep9","toolName":"bash","isError":false,"content":[{"type":"text","text":"2"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "no-op edit with silent grep recovery should be a finding (got $count) $report"
ok "#1139: no-op edit is not a benign probe — silent recovery still flagged"
rm -f "$sessions/edit-noop-silent-recovery.jsonl"

# --- 12. #1139 shape plus a later user-facing flag is clean ---------------
# Same discharge rule as scenarios 4 and 6: naming the failure in
# user-facing text satisfies fleet-ops#535, and FLAG_RE must keep
# matching this wording so the class cannot go permanently pending.
write_session "edit-noop-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit9","name":"edit","arguments":{"path":"/home/nish/workspaces/agent-worktrees/issue-fleet-ops-1001/prompts/worker.md","edits":[{"oldText":"#977, #1001","newText":"#977, #1001"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit9","toolName":"edit","content":[{"type":"text","text":"No changes made to /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1001/prompts/worker.md. The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the edit call failed with 'No changes made ... identical content' — my newText equalled the existing line, so nothing landed; rewriting the replacement."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "no-op edit with later user-facing flag should be clean (got $count) $report"
ok "#1139: no-op edit plus later user-facing flag is clean"
rm -f "$sessions/edit-noop-flagged.jsonl"

# --- 13. worker.md cites fleet-ops#1139 (prompt-side lock) ----------------
grep -q 'fleet-ops#1139' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1139 (prompt-side lock for the no-op edit shape)"
grep -q 'The replacement produced identical content' "$worker" \
  || fail "prompts/worker.md must name the live #1139 no-op wording so workers flag it"
grep -q "The text is already the same" "$worker" \
  || fail "prompts/worker.md must name the live #1139 cause-prose so workers know it is not a flag"
ok "worker.md cites fleet-ops#1139, the no-op wording, and the cause-prose"

# --- 14. lib/failed-command-flagged.py cites fleet-ops#1139 ---------------
# The comment above READ_OFFSET_RE is where a future maintainer would add
# a no-op exemption. It must name #1139 and forbid it.
grep -q 'fleet-ops#1139' "$lib" \
  || fail "lib/failed-command-flagged.py must cite fleet-ops#1139 (detector-side lock)"
grep -q 'The replacement produced identical content' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live #1139 no-op wording"
ok "lib/failed-command-flagged.py cites fleet-ops#1139 and the no-op wording"

echo "OK: fleet-failed-command-edit-unmatch: live #956/#1079/#1053/#1139 edit unmatch drills"
