#!/usr/bin/env bash
# tests/fleet-failed-command-canary-script-exit-1.test.sh
#
# fleet-ops#727: a verification canary script (`npm run canary:*`,
# `node scripts/*-verification.mjs`, etc.) that legitimately exits 1 on
# a failed gate is a real swallowed failure when the assistant walks
# past the non-zero exit without naming it. The detector already flags
# this class — the failure is `isError: true` + `Command exited with
# code 1` + no later assistant text naming the failure, and the
# command text does not match the BENIGN_STAGE_RE (grep/rg/diff no-match
# probe). This file locks the live #727 shape so a future detector
# refactor cannot regress it.
#
# Live session: 2026-08-27T00-01-33-243Z_01a04085-9c3b-7194-a332-20e86c213e81.jsonl
# The `npm run canary:bet2` call (a node-based canary) returned 1 because
# the gate's `zero_dead_ends` check failed (2 dead-end empty states), and
# the assistant continued diagnosing with curl probes without naming the
# canary failure in the user-facing text.
#
# Scenarios:
#   1. live #727 shape: npm run canary exit 1 walked past -> finding.
#   2. same shape plus a later user-facing flag -> clean.
#   3. node verification script exit 1 walked past -> finding. (Same
#      class, different command shape; also seen in fleet-ops#661.)
#   4. Same canary exit 1 with a benign-stage `| tail` pipeline is still a
#      finding: the failed command is the script, not the pipe tail.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-canary-exit-1.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T00:01:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T02:30:00Z"
}

# --- 1. live #727 shape: npm run canary exit 1 walked past ------------------
# The live session slug 01a04085 was filed because `npm run canary:bet2`
# exited 1 (gate FAIL: `zero_dead_ends` observed 2 > threshold 0), the
# toolResult was isError=true, and the assistant moved on to diagnostic
# curl probes without naming the canary failure. Replay that shape.
write_session "npm-run-canary-exit-1" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_canary","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-0509-973 && timeout 1800 npm run canary:bet2 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_canary","toolName":"bash","isError":true,"content":[{"type":"text","text":"{\n  \"termination\": {\n    \"pass\": false,\n    \"checks\": [\n      {\"name\": \"zero_dead_ends\", \"ok\": false, \"observed\": 2, \"threshold\": 0, \"detail\": \"dead-end empty states: 2\"},\n      {\"name\": \"verified_share_at_or_above_floor\", \"ok\": true, \"observed\": 0.84, \"threshold\": 0.8}\n    ]\n  }\n}\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe","name":"bash","arguments":{"command":"for domain in salesforce.com shopify.com stripe.com; do\n  echo -n \"$domain: \"\n  curl -s --max-time 10 \"https://0509.io/search?website=$domain\" -H \"user-agent: 0509-bet2/1.0\" 2>&1 | grep -oE '\"rowCount\":[0-9]+' | head -1\ndone"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe","toolName":"bash","isError":false,"content":[{"type":"text","text":"salesforce.com: \"rowCount\":0\nshopify.com: \"rowCount\":0\nstripe.com: \"rowCount\":0\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_file_issue","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-0509-973 && gh issue create -R Nishfleet/0509 --title \"BET 2 dead-ends: slack.com and tcs.com return 0 rows\" --body \"## Observed\" 2>&1"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #727 canary exit 1 walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# The snippet is the first 200 chars of the toolResult text (newlines
# collapsed). The live #727 toolResult began with the JSON gate-FAIL
# block, so the snippet carries the gate FAIL signal — pin that.
grep -q 'zero_dead_ends' <<<"$snippet" \
  || fail "finding snippet should mention zero_dead_ends gate (got $snippet)"
ok "live #727 canary exit 1 walked past is flagged"
rm -f "$sessions/npm-run-canary-exit-1.jsonl"

# --- 2. same shape plus a later user-facing flag is clean -------------------
# The standing rule is satisfied when the assistant names the failure in
# the same turn's user-facing text. The detector must NOT flag this.
write_session "npm-run-canary-exit-1-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_canary2","name":"bash","arguments":{"command":"cd /home/nish/agent-worktrees/issue-0509-973 && timeout 1800 npm run canary:bet2 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_canary2","toolName":"bash","isError":true,"content":[{"type":"text","text":"{\n  \"termination\": {\"pass\": false, \"checks\": [{\"name\": \"zero_dead_ends\", \"ok\": false, \"observed\": 2, \"threshold\": 0}]\n  }\n}\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the canary run failed with exit 1, the zero_dead_ends gate tripped on 2 dead-end empty states. It is now the blocker for the BET 2 close-out. Filing the diagnostic issues next."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe2","name":"bash","arguments":{"command":"for domain in salesforce.com shopify.com; do curl -s --max-time 10 \"https://0509.io/search?website=$domain\" -H \"user-agent: 0509-bet2/1.0\" | head -c 80; echo; done"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged canary exit 1 should be clean (got $count) $report"
ok "canary exit 1 plus later user-facing flag is clean"
rm -f "$sessions/npm-run-canary-exit-1-flagged.jsonl"

# --- 3. same class, different command shape: a bare `node` verification
# script that exits 1 on a failed gate. The live #727 was `npm run`; this
# pins the direct `node scripts/*-verification.mjs` shape (also seen in
# the fleet, fleet-ops#661).
write_session "node-verification-exit-1" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_node_canary","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-1234 && node scripts/bet3-verification.mjs --json 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_node_canary","toolName":"bash","isError":true,"content":[{"type":"text","text":"{\n  \"termination\": {\"pass\": false, \"checks\": [{\"name\": \"timeline_three_states\", \"ok\": false, \"observed\": 1, \"threshold\": 3, \"detail\": \"only 1 watched-competitor state\"}]}\n}\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_followup","name":"bash","arguments":{"command":"ls /home/nish/workspaces/agent-worktrees/issue-1234/docs 2>/dev/null"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "node verification script exit 1 walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'timeline_three_states' <<<"$snippet" \
  || fail "finding snippet should mention timeline_three_states gate (got $snippet)"
ok "node verification script exit 1 walked past is flagged"
rm -f "$sessions/node-verification-exit-1.jsonl"

# --- 4. canary exit 1 with a benign `| tail` tail is still a finding --------
# A `... | tail -1` on a canary that returned 1 is still a real swallowed
# failure: the failed stage is the canary itself, not the tail. The
# detector must not be tricked by the trailing tail into marking it
# benign. (The `| tail` does not match BENIGN_STAGE_RE because tail is
# not in the allow-list, but pin the behavior anyway.)
write_session "canary-piped-tail" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_canary_tail","name":"bash","arguments":{"command":"npm run canary:bet2 2>&1 | tail -40"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_canary_tail","toolName":"bash","isError":true,"content":[{"type":"text","text":"{\n  \"termination\": {\"pass\": false, \"checks\": [{\"name\": \"zero_dead_ends\", \"ok\": false, \"observed\": 2, \"threshold\": 0}]\n  }\n}\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next item."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "canary piped through tail exit 1 walked past should be a finding (got $count) $report"
ok "canary piped through tail exit 1 walked past is flagged"
rm -f "$sessions/canary-piped-tail.jsonl"

echo "OK: fleet-failed-command-canary-script-exit-1: live #727 canary + node verification exit 1 drills"
