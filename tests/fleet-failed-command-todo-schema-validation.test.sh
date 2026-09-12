#!/usr/bin/env bash
# tests/fleet-failed-command-todo-schema-validation.test.sh
#
# fleet-ops#5011: a `todo` tool call whose `action` argument is not one
# of the allowed enum values (add/update/list/etc.) is rejected by Pi's
# tool schema BEFORE the call is dispatched. The toolResult is
#
#     Validation failed for tool "todo":
#       - action: must be equal to one of the allowed values
#
#     Received arguments:
#     {
#       "action": "Acceptance: tests green, jq checks, real end-to-end deepseek job prints OK"
#     }
#
# isError=true, details={}, no "Command exited with code" line. The call
# never ran, so no todo state changed — but the user-facing signal is
# still a failure that must be named: the harness rejected the call
# because the arguments were malformed (the worker passed a free-text
# todo-item string as the `action` enum). The live session
# (2026-09-09T21-18-20-872Z pi-issue-fleet-ops-4625-...) issued this
# call as the last of a batch of seven `todo` calls in one turn; the
# first six used `action: add` and succeeded, the seventh used the
# free-text acceptance bullet as the action. The assistant's next turn
# moved straight to a `bash` worktree-setup command with no user-facing
# text naming the failure.
#
# This is the same schema-validation class as fleet-ops#1286 (an `edit`
# call that omitted the top-level `path` field, rejected before dispatch
# with 'Validation failed for tool "edit": - path: must have required
# properties path') and the same CI constraint (worker token cannot add
# a new workflow line in ci.yml). The detector already catches it: the
# `todo` tool is not a no-match probe, the toolResult has isError=true,
# and there is no negative-result exemption for schema-validation. The
# risk is a future refactor that adds a "schema validation is just a
# negative result" exemption (the way READ_OFFSET_RE exempts the
# read-beyond-end class) and silently silences a real class. The todo
# tool's schema-validation failure is the assistant's MALFORMED
# ARGUMENTS, not a probe result: the worker believed the todo call ran
# and it did not. This test pins the live #5011 shape and the citation
# (docstring, prompt, test host) so a future refactor cannot regress it.
#
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window.
#
# Live session:
# 2026-09-09T21-18-20-872Z_fleet-ops-4625-1788988700527502823.jsonl
# The agent was working fleet-ops#4625; it called `todo` seven times in
# one turn, the first six with `action: add` (succeeded), the seventh
# with `action: "Acceptance: tests green, jq checks, real end-to-end
# deepseek job prints OK"` (rejected). The next turn was a `bash`
# worktree-setup command with no user-facing text naming the failure.
#
# Scenarios:
#   1. live #5011 shape: todo invalid action enum + silent bash recovery
#      -> finding. Snippet must carry the schema-validation wording AND
#      the invalid action value.
#   2. same shape plus a later thinking-only note -> still a finding
#      (thinking is not a user-facing flag, fleet-ops#535).
#   3. same shape plus later unrelated user-facing prose that does NOT
#      name the failure -> still a finding.
#   4. same shape plus a later user-facing flag -> clean.
#   5. lib/failed-command-flagged.py cites fleet-ops#5011 and the
#      todo schema-validation wording (detector-side lock).
#   6. seat.lib.test.sh hosts this file (CI cannot gain a P14 line).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-todo-schema.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-09-09T21:19:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-09-10T15:53:00Z"
}

# --- 1. live #5011 shape: todo invalid action + silent bash recovery --------
# Replay the live 4625 shape: the assistant called `todo` seven times in
# one turn; the seventh used a free-text acceptance bullet as the
# `action` enum. The harness returned the schema validation message.
# The next turn was a `bash` worktree-setup command with no user-facing
# text naming the failure.
write_session "todo-schema-invalid-action" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_todo1","name":"todo","arguments":{"action":"add","text":"Add deepseek provider to ~/.pi/agent/models.json (with .pre backup)"}},{"type":"toolCall","id":"call_todo2","name":"todo","arguments":{"action":"add","text":"config/seat-caps.json: deepseek metered last_resort, caps, _comment_order ladder"}},{"type":"toolCall","id":"call_todo7","name":"todo","arguments":{"action":"Acceptance: tests green, jq checks, real end-to-end deepseek job prints OK"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_todo1","toolName":"todo","content":[{"type":"text","text":"Added todo #1: Add deepseek provider to ~/.pi/agent/models.json (with .pre backup)"}],"details":{"action":"add","todos":[{"id":1,"text":"Add deepseek provider to ~/.pi/agent/models.json (with .pre backup)","done":false}],"nextId":2},"isError":false}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_todo2","toolName":"todo","content":[{"type":"text","text":"Added todo #2: config/seat-caps.json: deepseek metered last_resort, caps, _comment_order ladder"}],"details":{"action":"add","todos":[{"id":1,"text":"Add deepseek provider to ~/.pi/agent/models.json (with .pre backup)","done":false},{"id":2,"text":"config/seat-caps.json: deepseek metered last_resort, caps, _comment_order ladder","done":false}],"nextId":3},"isError":false}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_todo7","toolName":"todo","content":[{"type":"text","text":"Validation failed for tool \"todo\":\n  - action: must be equal to one of the allowed values\n\nReceived arguments:\n{\n  \"action\": \"Acceptance: tests green, jq checks, real end-to-end deepseek job prints OK\"\n}"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Let me set up the worktree and investigate the existing code. First, let me check the claim branch and set up the worktree."},{"type":"toolCall","id":"call_bash1","name":"bash","arguments":{"command":"cd /home/nish && whoami"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash1","toolName":"bash","isError":false,"content":[{"type":"text","text":"nish"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #5011 todo invalid-action schema validation should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Validation failed for tool "todo"' <<<"$snippet" \
  || fail "finding snippet should mention the schema-validation heading (got $snippet)"
grep -q 'must be equal to one of the allowed values' <<<"$snippet" \
  || fail "finding snippet should mention the live 'must be equal to one of the allowed values' wording (got $snippet)"
ok "live #5011: todo invalid-action schema validation with silent bash recovery is flagged"
rm -f "$sessions/todo-schema-invalid-action.jsonl"

# --- 2. same shape plus thinking-only recovery is still a finding ----------
# Thinking is not a user-facing flag (fleet-ops#535 / #953). Pin that a
# future `_text_chunks` change that starts collecting `thinking` fields
# still cannot discharge this class unless FLAG_RE matches.
write_session "todo-schema-thinking-only" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_todo2","name":"todo","arguments":{"action":"Acceptance: tests green, jq checks, real end-to-end deepseek job prints OK"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_todo2","toolName":"todo","content":[{"type":"text","text":"Validation failed for tool \"todo\":\n  - action: must be equal to one of the allowed values\n\nReceived arguments:\n{\n  \"action\": \"Acceptance: tests green, jq checks, real end-to-end deepseek job prints OK\"\n}"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The todo tool rejected my action. I passed a free-text string instead of the add enum. Let me retry with action add."},{"type":"toolCall","id":"call_todo_retry","name":"todo","arguments":{"action":"add","text":"Acceptance: tests green, jq checks, real end-to-end deepseek job prints OK"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_todo_retry","toolName":"todo","content":[{"type":"text","text":"Added todo #7: Acceptance: tests green, jq checks, real end-to-end deepseek job prints OK"}],"isError":false}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "todo schema validation with thinking-only recovery should be a finding (got $count) $report"
ok "todo schema validation with thinking-only recovery is still flagged"
rm -f "$sessions/todo-schema-thinking-only.jsonl"

# --- 3. later unrelated user-facing prose does not discharge --------------
# Real user-facing text that moves on without naming the failure must
# NOT clear the pending swallowed failure (same rule as the #953 / #958
# siblings).
write_session "todo-schema-unrelated-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_todo3","name":"todo","arguments":{"action":"Acceptance: tests green, jq checks, real end-to-end deepseek job prints OK"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_todo3","toolName":"todo","content":[{"type":"text","text":"Validation failed for tool \"todo\":\n  - action: must be equal to one of the allowed values\n\nReceived arguments:\n{\n  \"action\": \"Acceptance: tests green, jq checks, real end-to-end deepseek job prints OK\"\n}"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bash3","name":"bash","arguments":{"command":"git fetch origin 2>&1 | tail -2"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash3","toolName":"bash","isError":false,"content":[{"type":"text","text":""}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now I have the full picture. Let me set up the worktree and start implementing."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "todo schema validation followed by unrelated prose should be a finding (got $count) $report"
ok "todo schema validation with later unrelated user-facing prose is still flagged"
rm -f "$sessions/todo-schema-unrelated-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean -----------------
# The standing rule is satisfied when the assistant names the failure in
# user-facing text. The detector must NOT flag this.
write_session "todo-schema-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_todo4","name":"todo","arguments":{"action":"Acceptance: tests green, jq checks, real end-to-end deepseek job prints OK"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_todo4","toolName":"todo","content":[{"type":"text","text":"Validation failed for tool \"todo\":\n  - action: must be equal to one of the allowed values\n\nReceived arguments:\n{\n  \"action\": \"Acceptance: tests green, jq checks, real end-to-end deepseek job prints OK\"\n}"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the todo call failed with 'Validation failed for tool \"todo\": action: must be equal to one of the allowed values' — I passed a free-text string as the action enum, retrying with action add."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "todo schema validation with later user-facing flag should be clean (got $count) $report"
ok "todo schema validation plus later user-facing flag is clean"
rm -f "$sessions/todo-schema-flagged.jsonl"

# --- 5. lib/failed-command-flagged.py cites fleet-ops#5011 (detector-side lock) ------------------
grep -q 'fleet-ops#5011' "$lib" \
  || fail "lib/failed-command-flagged.py must cite fleet-ops#5011 (detector-side lock for the todo schema-validation shape)"
grep -q 'must be equal to one of the allowed values' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live 'must be equal to one of the allowed values' wording so workers flag it"
grep -q 'Validation failed for tool "todo"' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live 'Validation failed for tool \"todo\"' heading so workers flag it"
ok "lib/failed-command-flagged.py cites fleet-ops#5011 and the todo schema-validation wording"

# --- 6. seat.lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-todo-schema-validation.test.sh"' \
  "$here/seat""-lib.test.sh" \
  || fail "seat.lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat.lib.test.sh hosts this file"

echo "OK: fleet-failed-command-todo-schema-validation: live #5011 todo schema-validation drills"
