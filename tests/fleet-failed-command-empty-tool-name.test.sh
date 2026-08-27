#!/usr/bin/env bash
# tests/fleet-failed-command-empty-tool-name.test.sh
#
# fleet-ops#1242: a malformed Pi toolCall with an empty name
#   id "", name "", arguments the non-JSON string "command"
# that returns `Tool  not found` (two spaces because the name is
# empty; isError=true, details={}, no `Command exited with code`
# line) is a real swallowed failure. The live next turn was an empty
# assistant message with stopReason=error and an HTTP 400
# `Tool name must be nonempty` errorMessage. That errorMessage is
# harness metadata, not user-facing text, so it is not a flag.
#
# The detector already flags this class via the generic isError path.
# No `lib/failed-command-flagged.py` logic change is needed; a
# suppression would silence a real signal. The tempting future
# exemptions this file forbids:
#   - treating empty toolName / empty toolCallId as "the command never
#     ran" (harness-block class)
#   - treating `Tool  not found` as a grep/rg/which no-match probe
#     because FLAG_RE / the snippet contains "not found"
#   - treating the follow-up HTTP 400 errorMessage as a user-facing
#     flag (errorMessage is not in content; `_text_chunks` only reads
#     type=="text")
#   - collapsing internal double-spaces in snippets so the live
#     empty-name fingerprint `Tool  not found` disappears
# The auto-filed issue closes via observe-to-close (fleet-ops#650)
# when the session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T15-50-45-409Z_01a043ea-a1a1-79d2-b579-ef094ed1e3aa.jsonl
# The deepseek-v4-pro worker on fleet-ops#1009 emitted:
#   toolCall id="" name="" arguments="command"
# Pi answered:
#   toolResult toolCallId="" toolName="" isError=true details={}
#   text "Tool  not found"
# The session then ended on an empty assistant turn
# (stopReason=error, HTTP 400 Tool name must be nonempty). Detector
# snippet: `Tool  not found`.
#
# Distinct from:
#   - #937: python3 `ModuleNotFoundError: No module named '...'` +
#     `Command exited with code 1` — a bash probe, not an empty
#     tool name
#   - #698: `gh: Not Found (HTTP 404)` — a named bash call with a
#     GitHub 404, not Pi's missing-tool harness line
#   - grep/rg POSIX no-match (BENIGN_STAGE_RE)
#
# Scenarios:
#   1. live #1242 shape: empty-name toolCall + `Tool  not found` +
#      empty next assistant turn -> finding. Snippet must be the
#      two-space `Tool  not found` fingerprint.
#   2. same shape plus a later thinking-only note -> still a finding.
#   3. same shape plus later unrelated user-facing prose that does
#      NOT name the failure -> still a finding.
#   4. same shape plus an HTTP 400 errorMessage-only next turn
#      (the live end-of-session shape) -> still a finding.
#   5. same shape plus a later user-facing flag -> clean.
#   6. contrast: successful isError=false content that quotes
#      `Tool  not found` is content, not a finding.
#   7. worker.md cites fleet-ops#1242 and the live empty-name wording.
#   8. lib/failed-command-flagged.py docstring cites fleet-ops#1242.
#   9. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).

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

scratch="$(mktemp -d -t failed-command-empty-tool-name.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T16:22:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T17:00:00Z"
}

# --- 1. live #1242 shape: empty-name toolCall walked past -----------------
# Replay slug 01a043ea: empty name/id, arguments the non-JSON string
# "command", harness `Tool  not found`, next turn empty content.
write_session "empty-tool-name-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Now run the pre-PR checks and then update the PR body."},{"type":"toolCall","id":"","name":"","arguments":"command"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"","toolName":"","content":[{"type":"text","text":"Tool  not found"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1242 empty-name Tool  not found walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Tool  not found' <<<"$snippet" \
  || fail "finding snippet must carry the two-space empty-name fingerprint 'Tool  not found' (got $snippet)"
ok "live #1242: empty-name toolCall with empty next turn is flagged"
rm -f "$sessions/empty-tool-name-walked.jsonl"

# --- 2. thinking-only recovery is still a finding --------------------------
write_session "empty-tool-name-thinking" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"","name":"","arguments":"command"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"","toolName":"","content":[{"type":"text","text":"Tool  not found"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Empty tool name. I will call bash instead."},{"type":"toolCall","id":"call_recover","name":"bash","arguments":{"command":"echo recovered"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "empty-name Tool  not found with thinking-only recovery should be a finding (got $count) $report"
ok "live #1242: empty-name toolCall with later thinking-only recovery is still flagged"
rm -f "$sessions/empty-tool-name-thinking.jsonl"

# --- 3. later unrelated user-facing prose does not discharge ---------------
write_session "empty-tool-name-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"","name":"","arguments":"command"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"","toolName":"","content":[{"type":"text","text":"Tool  not found"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Let me now update the PR body to reflect the latest checks."},{"type":"toolCall","id":"call_recover3","name":"bash","arguments":{"command":"echo recovered"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "empty-name Tool  not found followed by unrelated prose should be a finding (got $count) $report"
ok "live #1242: empty-name toolCall with unrelated user-facing prose is still flagged"
rm -f "$sessions/empty-tool-name-prose.jsonl"

# --- 4. HTTP 400 errorMessage-only next turn is not a flag -----------------
# The live session ended on stopReason=error with
# errorMessage "HTTP 400: ... Tool name must be nonempty ... arguments
# must be a valid JSON object string". errorMessage is not content, so
# FLAG_RE never sees it. Pin that a future refactor which walks
# errorMessage as user-facing text is a behaviour change that would
# silently close this class.
write_session "empty-tool-name-http400" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"","name":"","arguments":"command"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"","toolName":"","content":[{"type":"text","text":"Tool  not found"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"HTTP 400: Invalid request: messages.289.tool_calls.0.function.name: Tool name must be nonempty; messages.289.tool_calls.0.function.arguments: arguments must be a valid JSON object string"}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "empty-name Tool  not found with HTTP 400 errorMessage-only next turn should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Tool  not found' <<<"$snippet" \
  || fail "HTTP 400 fixture snippet must still be 'Tool  not found' (got $snippet)"
ok "live #1242: HTTP 400 errorMessage-only next turn is not a user-facing flag"
rm -f "$sessions/empty-tool-name-http400.jsonl"

# --- 5. same shape plus a later user-facing flag is clean ------------------
write_session "empty-tool-name-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"","name":"","arguments":"command"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"","toolName":"","content":[{"type":"text","text":"Tool  not found"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the empty-name tool call failed with Tool  not found, it is now the blocker."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "empty-name Tool  not found plus later user-facing flag should be clean (got $count) $report"
ok "empty-name Tool  not found plus later user-facing flag is clean"
rm -f "$sessions/empty-tool-name-flagged.jsonl"

# --- 6. contrast: isError=false content quoting the same text is clean -----
# A successful `git show` / `cat` of detector source that quotes
# `Tool  not found` must not be filed. Same class as #821 / #848 /
# #1074 (timeout / exit-code literals in successful content).
write_session "empty-tool-name-quoted-content" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_show","name":"bash","arguments":{"command":"git show HEAD:lib/failed-command-flagged.py | head"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_show","toolName":"bash","isError":false,"content":[{"type":"text","text":"# cites fleet-ops#1242 empty-name Tool  not found\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The detector docstring already names the empty-name shape."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "successful content quoting 'Tool  not found' should be clean (got $count) $report"
ok "successful isError=false content quoting Tool  not found is not flagged (contrast with #1242)"
rm -f "$sessions/empty-tool-name-quoted-content.jsonl"

# --- 7. prompts/worker.md cites fleet-ops#1242 (prompt-side lock) ----------
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1242' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1242 (prompt-side lock)"
grep -q 'Tool  not found' "$worker" \
  || fail "prompts/worker.md must name the live two-space 'Tool  not found' wording"
ok "worker.md cites fleet-ops#1242 and the live empty-name wording"

# --- 8. lib/failed-command-flagged.py docstring cites fleet-ops#1242 ------
grep -q 'fleet-ops#1242' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1242 (detector-side lock)"
grep -q 'Tool  not found' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live two-space 'Tool  not found' wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1242 and the empty-name shape"

# --- 9. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ------
grep -Fq 'bash "$here/fleet-failed-command-empty-tool-name.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-empty-tool-name: live #1242 empty-name Tool  not found drills"
