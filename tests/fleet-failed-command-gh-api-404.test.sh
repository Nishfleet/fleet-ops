#!/usr/bin/env bash
# tests/fleet-failed-command-gh-api-404.test.sh
#
# fleet-ops#698: a `gh api` call that returns 404 (e.g. workflow-runs for a
# non-existent head_sha) and is walked past is a real swallowed failure.
# The detector already flags this class via the "Not Found" / "HTTP 4xx"
# REAL_ERR_RE; this file locks the exact #698 shape so a future detector
# refactor cannot regress it. A worker that names the failure in the same
# turn's user-facing text is clean; a worker that walks past it (the live
# #698 case) is filed.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-gh-api-404.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-26T15:55:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-26T16:30:00Z"
}

# --- 1. live #698 shape: gh api 404 walked past ------------------------------
# The live session slug 01a03ec8 was filed because a `gh api` workflow-runs
# query for a non-existent head_sha returned `Not Found (HTTP 404)` and the
# assistant never named the failure in later text. Replay that exact shape.
write_session "gh-api-404" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_wf","name":"bash","arguments":{"command":"gh api \"repos/Nishfleet/0509/actions/workflow-runs?head_sha=353bbc79ea7d601b84b8c8fe93c008eeaada05ed&per_page=100\" --jq '.total_count, .workflow_runs[] | {id, name, event, conclusion, status}' 2>&1 | head -30"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_wf","toolName":"bash","isError":true,"content":[{"type":"text","text":"{\n  \"message\": \"Not Found\",\n  \"documentation_url\": \"https://docs.github.com/rest\",\n  \"status\": \"404\"\n}gh: Not Found (HTTP 404)\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"All node tests pass on all three PRs. Now let me look at the Class B PRs."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #698 gh api 404 walked past should be a finding (got $count) $report"
grep -q 'Not Found' <<<"$(jq -r '.findings[0].snippet' <<<"$report")" \
  || fail "finding snippet should mention Not Found (got $(jq -r '.findings[0].snippet' <<<"$report"))"
ok "live #698 gh api 404 walked past is flagged"
rm -f "$sessions/gh-api-404.jsonl"

# --- 2. same shape plus a later flag is clean --------------------------------
# The standing rule is satisfied when the assistant names the failure in the
# same turn's user-facing text. The detector should NOT flag this.
write_session "gh-api-404-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_wf2","name":"bash","arguments":{"command":"gh api \"repos/Nishfleet/0509/actions/workflow-runs?head_sha=353bbc79ea7d601b84b8c8fe93c008eeaada05ed&per_page=100\" --jq '.total_count' 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_wf2","toolName":"bash","isError":true,"content":[{"type":"text","text":"{\n  \"message\": \"Not Found\",\n  \"documentation_url\": \"https://docs.github.com/rest\",\n  \"status\": \"404\"\n}gh: Not Found (HTTP 404)\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the gh api workflow-runs call failed with 404, that head_sha has no runs. Skipping the run check, moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged gh api 404 should be clean (got $count) $report"
ok "gh api 404 plus later user-facing flag is clean"
rm -f "$sessions/gh-api-404-flagged.jsonl"

# --- 3. a 4xx with no real error text is still a finding ---------------------
# Plain `gh api ... -X PATCH /repos/.../branches/main/protection` with the
# origin #650 Not Found shape. Already locked by the main test, but a small
# cross-check here keeps the dedicated test honest about HTTP 4xx in general.
write_session "gh-api-4xx" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_patch","name":"bash","arguments":{"command":"gh api -X PATCH repos/Nishfleet/0509/branches/main/protection -f required_status_checks='{}' 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_patch","toolName":"bash","isError":true,"content":[{"type":"text","text":"{\n  \"message\": \"Not Found\",\n  \"documentation_url\": \"https://docs.github.com/rest\",\n  \"status\": \"404\"\n}\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"verify: strict is still true. Next task."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "gh api 4xx walked past should be a finding (got $count) $report"
ok "gh api 4xx walked past is flagged"
rm -f "$sessions/gh-api-4xx.jsonl"

# --- 4. 5xx walked past is also a finding ------------------------------------
# A 502 Bad Gateway from `gh api` is the same class — a real gh error,
# not a grep/rg/diff no-match. The detector must still flag it.
write_session "gh-api-5xx" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_5xx","name":"bash","arguments":{"command":"gh api repos/Nishfleet/0509/contents/AGENTS.md 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_5xx","toolName":"bash","isError":true,"content":[{"type":"text","text":"gh: HTTP 502 (curl exit code 22)\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next check."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "gh api 5xx walked past should be a finding (got $count) $report"
ok "gh api 5xx walked past is flagged"
rm -f "$sessions/gh-api-5xx.jsonl"

echo "OK: fleet-failed-command-gh-api-404: live #698 404 + flag drill"
