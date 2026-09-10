#!/usr/bin/env bash
# tests/fleet-failed-command-output-token-limit-never-ran.test.sh
#
# fleet-ops#4944: a tool call that was never executed because pi's response
# hit the output-token budget is reported by a toolResult of the form
#
#     Tool call "bash" was not executed: the response hit the output token
#     limit, so its arguments may be truncated. Re-issue the tool call with
#     complete arguments.
#
# (live variant: `Tool call "bash" was not executed: output token limit`)
#
# with isError=true, details={}, and NO "Command exited with code" line. The
# command never ran: there is no output and no exit code to walk past, so it
# is not a swallowed failed command. This is the same never-ran principle as
# HARNESS_BLOCK_RE / SPAWN_BLOCKED (fleet-ops#755). A live single assistant
# turn hit the token budget and emitted a dozen such toolResults in one
# session (0509-2133), each previously mis-counted as a swallowed failure and
# inflating the FAILED-COMMAND-FAIL aggregate this issue tracks.
#
# The exemption must NOT live inside HARNESS_BLOCK_RE: HARNESS_BLOCK_RE also
# seeds `had_prior_block`, which exempts a later 127 "No such file or
# directory" as a #677 cascade. A never-executed batch is not a spawn-guard
# block and must not explain a later ENOENT.
#
# And this is NOT the edit schema-validation class (fleet-ops#1286,
# `Validation failed for tool "edit": - path: ...`): there the worker's own
# arguments were malformed and the worker believed the edit ran. Here the
# tool was not dispatched at all — nothing was attempted.
#
# Same CI constraint (worker token cannot add a P14 line in ci.yml).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-never-ran.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-09-10T12:00:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-09-10T12:30:00Z"
}

# --- 1. the exact live shape: never-executed due to output token limit ------
# isError=true, no exit-code line, the wording "was not executed: ... output
# token limit". The bath never ran, so nothing to swallow.
write_session "never-ran" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bash","name":"bash","arguments":{"command":"gh pr view 2278 -R Nishfleet/0509 --json mergeQueueEntry"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash","toolName":"bash","isError":true,"details":{},"content":[{"type":"text","text":"Tool call \"bash\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Re-issuing the merge-queue status check."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "output-token-limit never-ran should not be a finding (got $count) $report"
ok "never-executed output-token-limit tool call is not a swallowed failure"
rm -f "$sessions/never-ran.jsonl"

# --- 2. the shorter live variant: `... was not executed: output token limit`
write_session "never-ran-short" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"echo hi"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"c2","toolName":"bash","isError":true,"content":[{"type":"text","text":"Tool call \"bash\" was not executed: output token limit"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Re-issuing."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "short output-token-limit never-ran should not be a finding (got $count) $report"
ok "short never-executed output-token-limit variant is not a swallowed failure"
rm -f "$sessions/never-ran-short.jsonl"

# --- 3. a REAL swallowed failure in the same session is still flagged -------
# A never-executed tool call must NOT exempt a genuinely ran-and-failed
# command later in the same session.
write_session "never-ran-then-real" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"c3","name":"bash","arguments":{"command":"echo hi"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"c3","toolName":"bash","isError":true,"content":[{"type":"text","text":"Tool call \"bash\" was not executed: output token limit"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"c4","name":"bash","arguments":{"command":"git status"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"c4","toolName":"bash","isError":true,"content":[{"type":"text","text":"fatal: not a git repository (or any of the parent directories): .git\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on to the next task."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "a real failure after a never-ran call must still be a finding (got $count) $report"
ok "a real ran-and-failed command after a never-ran call is still flagged"
rm -f "$sessions/never-ran-then-real.jsonl"

# --- 4. the edit schema-validation class must NOT be exempted --------------
# fleet-ops#1286: the harness rejected the edit before dispatch because the
# worker's arguments were malformed and the worker believed it ran. That is a
# real swallowed failure, NOT a never-ran exemption.
write_session "edit-schema" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"c5","name":"edit","arguments":{"path":"app/f.ts","edits":[{"oldText":"x","newText":"y"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"c5","toolName":"edit","isError":true,"content":[{"type":"text","text":"Validation failed for tool \"edit\":\n  - path: must have required properties path"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The edit tool requires the path field."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "edit schema-validation must remain a finding (got $count) $report"
ok "edit schema-validation is still a real swallowed failure"
rm -f "$sessions/edit-schema.jsonl"

echo "OK: fleet-failed-command-output-token-limit-never-ran: never-ran exempt, real failures still flagged"