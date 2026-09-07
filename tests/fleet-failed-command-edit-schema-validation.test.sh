#!/usr/bin/env bash
# tests/fleet-failed-command-edit-schema-validation.test.sh
#
# fleet-ops#1286: an `edit` tool call that omits a required top-level
# field (path, edits) is rejected by Pi's tool schema BEFORE the call
# is dispatched. The toolResult is
#
#     Validation failed for tool "edit":
#       - path: must have required properties path
#
#     Received arguments:
#     {
#       "edits": [ ... ]
#     }
#
# isError=true, details={}, no "Command exited with code" line. The call
# never ran, so no real file change was attempted and no `read` recovery
# is needed — but the user-facing signal is still a failure that must be
# named: the harness rejected the call because the arguments were
# malformed (path missing). The live session (2026-08-27T15-13-39-481Z
# 01a043c8-...) issued FOUR such calls in a row, each named inside the
# arguments as a successful retry plan rather than a recovery from a
# named failure. The assistant's recovery was thinking-only ("The edit
# tool requires the path field", "Odd. Let me check if the old text
# actually matches exactly."), then a successful `sed`/`edit` retry.
#
# This is the same edit-failure class as #956 / #965 / #1053 / #1139 /
# #1173 (a "Could not find ..." / "Found N occurrences" / "No changes
# made ..." / "edits[0] ..." toolResult) and the same CI constraint
# (worker token cannot add a new workflow line in ci.yml). The detector
# already catches it: the `edit` tool is not a no-match probe, the
# toolResult has isError=true, and there is no negative-result
# exemption for schema-validation. The risk is a future refactor that
# adds a "schema validation is just a negative result" exemption (the
# way READ_OFFSET_RE exempts the read-beyond-end class) and silently
# silences a real class. The edit tool's schema-validation failure is
# the assistant's MALFORMED ARGUMENTS, not a probe result: the worker
# believed the edit ran and it did not. This test pins the live #1286
# shape and the three-place citation (docstring, prompt, test host) so
# a future refactor cannot regress it.
#
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T15-13-39-481Z_01a043c8-aa99-7676-a8b7-bf39232cb196.jsonl
# The agent was working fleet-ops#1218 in /tmp/fleet-ops (a fresh clone);
# it called `edit` on bin/pi-issue-run, bin/pi-packet-run, bin/pi-scout-run,
# bin/agent-cron-run four times in a row, each with the same shape:
#   arguments = { "edits": [ { "oldText": ..., "newText": ... } ] }
#   (no top-level "path" field)
# The toolResult in each case was the schema-validation message with
# isError=true. The assistant's next turn was a thinking block plus a
# `sed`/`read` recovery toolCall, no user-facing text. A subsequent
# successful retry landed the change.
#
# Scenarios:
#   1. live #1286 shape: edit missing path field -> schema validation +
#      silent sed/read recovery -> finding. Snippet must carry the
#      schema-validation wording AND the path the worker intended.
#   2. same shape plus a later thinking-only note ("The edit tool
#      requires the path field") -> still a finding (thinking is not a
#      user-facing flag, fleet-ops#535).
#   3. same shape plus later unrelated user-facing prose that does NOT
#      name the failure -> still a finding.
#   4. same shape plus a later user-facing flag -> clean.
#   5. lib/failed-command-flagged.py cites fleet-ops#1286 and the schema-validation wording
#      (detector-side lock: case list moved to lib, fleet-ops#3246).
#   6. lib/failed-command-flagged.py docstring cites fleet-ops#1286
#      (detector-side lock, forbids a "schema validation is benign"
#      exemption).
#   7. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).

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

scratch="$(mktemp -d -t failed-command-edit-schema.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T15:13:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T15:30:00Z"
}

# --- 1. live #1286 shape: edit missing path + silent sed recovery -----------
# Replay the live 01a043c8 shape: the assistant called `edit` with only
# an `edits` field (no `path`). The harness returned the schema
# validation message. The next turn was a silent `sed`/`read` recovery
# with no user-facing text. The intended file path is in the schema
# validation's "Received arguments" block but the call never ran.
write_session "edit-schema-missing-path" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit1","name":"edit","arguments":{"edits":[{"oldText":"weight=$(task_weight \"$PROMPT\")\nneed_capable=0\n[[ \"$weight\" == \"heavy\" ]] && need_capable=1\n\nseat=$(pick_seat \"\" \"\" \"$need_capable\" \"$tried_file\" || true)","newText":"diff=$(packet_difficulty \"$PROMPT\")\nneed_capable=0\n[[ \"$diff\" == \"heavy\" || \"$diff\" == \"keystone\" ]] && need_capable=1\n\nseat=$(pick_seat \"\" \"\" \"$need_capable\" \"$tried_file\" \"$diff\" || true)"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit1","toolName":"edit","content":[{"type":"text","text":"Validation failed for tool \"edit\":\n  - path: must have required properties path\n\nReceived arguments:\n{\n  \"edits\": [\n    {\n      \"oldText\": \"weight=$(task_weight \\\"$PROMPT\\\")\\nneed_capable=0\\n[[ \\\"$weight\\\" == \\\"heavy\\\" ]] && need_capable=1\\n\\nseat=$(pick_seat \\\"\\\" \\\"\\\" \\\"$need_capable\\\" \\\"$tried_file\\\" || true)\",\n      \"newText\": \"diff=$(packet_difficulty \\\"$PROMPT\\\")\\nneed_capable=0\\n[[ \\\"$diff\\\" == \\\"heavy\\\" || \\\"$diff\\\" == \\\"keystone\\\" ]] && need_capable=1\\n\\nseat=$(pick_seat \\\"\\\" \\\"\\\" \\\"$need_capable\\\" \\\"$tried_file\\\" \\\"$diff\\\" || true)\"\n    }\n  ]\n}"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_sed1","name":"bash","arguments":{"command":"sed -i 's|weight=$(task_weight \"$PROMPT\")|diff=$(packet_difficulty \"$PROMPT\")|; s|[[ \"$weight\" == \"heavy\" ]] && need_capable=1|[[ \"$diff\" == \"heavy\" || \"$diff\" == \"keystone\" ]] && need_capable=1|; s|seat=$(pick_seat \"\" \"\" \"$need_capable\" \"$tried_file\" || true)|seat=$(pick_seat \"\" \"\" \"$need_capable\" \"$tried_file\" \"$diff\" || true)|' /tmp/fleet-ops/bin/agent-cron-run"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_sed1","toolName":"bash","isError":false,"content":[{"type":"text","text":""}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1286 edit missing-path schema validation should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Validation failed for tool "edit"' <<<"$snippet" \
  || fail "finding snippet should mention the schema-validation heading (got $snippet)"
grep -q 'must have required properties path' <<<"$snippet" \
  || fail "finding snippet should mention the live 'must have required properties path' wording (got $snippet)"
ok "live #1286: edit missing-path schema validation with silent sed recovery is flagged"
rm -f "$sessions/edit-schema-missing-path.jsonl"

# --- 2. same shape plus thinking-only recovery is still a finding ----------
# The live session's next turn was a thinking block ("The edit tool
# requires the path field") plus a recovery toolCall. Thinking is not a
# user-facing flag (fleet-ops#535 / #953). Pin that a future
# `_text_chunks` change that starts collecting `thinking` fields still
# cannot discharge this class unless FLAG_RE matches.
write_session "edit-schema-thinking-only" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit2","name":"edit","arguments":{"edits":[{"oldText":"weight=$(task_weight \"$prompt_file\")\nneed_capable=0\n[[ \"$weight\" == \"heavy\" ]] && need_capable=1\n\nseat=$(pick_seat \"\" \"\" \"$need_capable\" || true)","newText":"diff=$(packet_difficulty \"$prompt_file\")\nneed_capable=0\n[[ \"$diff\" == \"heavy\" || \"$diff\" == \"keystone\" ]] && need_capable=1\n\nseat=$(pick_seat \"\" \"\" \"$need_capable\" \"\" \"$diff\" || true)"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit2","toolName":"edit","content":[{"type":"text","text":"Validation failed for tool \"edit\":\n  - path: must have required properties path\n\nReceived arguments:\n{\n  \"edits\": [\n    {\n      \"oldText\": \"weight=$(task_weight \\\"$prompt_file\\\")\\nneed_capable=0\\n[[ \\\"$weight\\\" == \\\"heavy\\\" ]] && need_capable=1\\n\\nseat=$(pick_seat \\\"\\\" \\\"\\\" \\\"$need_capable\\\" || true)\",\n      \"newText\": \"diff=$(packet_difficulty \\\"$prompt_file\\\")\\nneed_capable=0\\n[[ \\\"$diff\\\" == \\\"heavy\\\" || \\\"$diff\\\" == \\\"keystone\\\" ]] && need_capable=1\\n\\nseat=$(pick_seat \\\"\\\" \\\"\\\" \\\"$need_capable\\\" \\\"\\\" \\\"$diff\\\" || true)\"\n    }\n  ]\n}"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The edit tool requires the path field. I omitted it. Let me retry with the path included."},{"type":"toolCall","id":"call_read2","name":"read","arguments":{"path":"/tmp/fleet-ops/bin/pi-scout-run","offset":50,"limit":15}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "edit schema validation with thinking-only recovery should be a finding (got $count) $report"
ok "edit schema validation with thinking-only recovery is still flagged"
rm -f "$sessions/edit-schema-thinking-only.jsonl"

# --- 3. later unrelated user-facing prose does not discharge --------------
# Real user-facing text that moves on without naming the failure must
# NOT clear the pending swallowed failure (same rule as the #953 / #958
# siblings).
write_session "edit-schema-unrelated-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit3","name":"edit","arguments":{"edits":[{"oldText":"weight=$(task_weight \"$prompt_file\")\nneed_capable=0","newText":"diff=$(packet_difficulty \"$prompt_file\")\nneed_capable=0"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit3","toolName":"edit","content":[{"type":"text","text":"Validation failed for tool \"edit\":\n  - path: must have required properties path\n\nReceived arguments:\n{\n  \"edits\": [\n    {\n      \"oldText\": \"weight=$(task_weight \\\"$prompt_file\\\")\\nneed_capable=0\",\n      \"newText\": \"diff=$(packet_difficulty \\\"$prompt_file\\\")\\nneed_capable=0\"\n    }\n  ]\n}"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read3","name":"read","arguments":{"path":"/tmp/fleet-ops/bin/pi-scout-run","offset":50,"limit":15}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read3","toolName":"read","isError":false,"content":[{"type":"text","text":"weight=$(task_weight \"$prompt_file\")\nneed_capable=0\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now I have the file in front of me. Let me plan the next edit."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "edit schema validation followed by unrelated prose should be a finding (got $count) $report"
ok "edit schema validation with later unrelated user-facing prose is still flagged"
rm -f "$sessions/edit-schema-unrelated-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean -----------------
# The standing rule is satisfied when the assistant names the failure in
# user-facing text. The detector must NOT flag this.
write_session "edit-schema-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit4","name":"edit","arguments":{"edits":[{"oldText":"weight=$(task_weight \"$prompt_file\")\nneed_capable=0","newText":"diff=$(packet_difficulty \"$prompt_file\")\nneed_capable=0"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit4","toolName":"edit","content":[{"type":"text","text":"Validation failed for tool \"edit\":\n  - path: must have required properties path\n\nReceived arguments:\n{\n  \"edits\": [\n    {\n      \"oldText\": \"weight=$(task_weight \\\"$prompt_file\\\")\\nneed_capable=0\",\n      \"newText\": \"diff=$(packet_difficulty \\\"$prompt_file\\\")\\nneed_capable=0\"\n    }\n  ]\n}"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the edit call failed with 'Validation failed for tool \"edit\": path: must have required properties path' — I omitted the top-level path field, retrying with it included."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "edit schema validation with later user-facing flag should be clean (got $count) $report"
ok "edit schema validation plus later user-facing flag is clean"
rm -f "$sessions/edit-schema-flagged.jsonl"

# --- 5. lib/failed-command-flagged.py cites fleet-ops#1286 (detector-side lock: case list moved to lib, fleet-ops#3246) ------------------
grep -q 'fleet-ops#1286' "$lib" \
  || fail "lib/failed-command-flagged.py must cite fleet-ops#1286 (detector-side lock for the edit schema-validation shape)"
grep -q 'must have required properties path' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live 'must have required properties path' wording so workers flag it"
grep -q 'Validation failed for tool "edit"' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live 'Validation failed for tool \"edit\"' heading so workers flag it"
grep -q 'The edit tool requires the path field' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live #1286 thinking-only recovery text so workers know it is not a flag"
ok "lib/failed-command-flagged.py cites fleet-ops#1286, the schema-validation wording, and the thinking-only recovery"

# --- 6. lib/failed-command-flagged.py cites fleet-ops#1286 ----------------
# The lib docstring is the standing-rule contract for the next detector
# maintainer. A future refactor that adds a "schema validation is just
# a negative result" exemption (mirroring READ_OFFSET_RE) would silence
# this class; the docstring forbids it. The docstring is a Python
# triple-quoted string, so the inner double-quotes are escaped as \"
# on disk — we check the unescaped wording fragments, which appear
# in the docstring AND in the comment block above result_failed and
# the comment block above READ_OFFSET_RE (where a future maintainer
# would add an exemption).
grep -q 'fleet-ops#1286' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1286 (detector-side lock)"
grep -q 'must have required properties path' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'must have required properties path' wording"
grep -q 'Validation failed for tool' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'Validation failed for tool' heading"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1286 and the schema-validation wording"

# --- 7. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-edit-schema-validation.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-edit-schema-validation: live #1286 edit schema-validation drills"
