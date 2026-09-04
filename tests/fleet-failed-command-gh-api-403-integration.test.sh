#!/usr/bin/env bash
# tests/fleet-failed-command-gh-api-403-integration.test.sh
#
# fleet-ops#1253: a `gh api /user` (or `gh api user`) call under a GitHub
# App installation token returns
#   Resource not accessible by integration (HTTP 403)
# and `Command exited with code 1` (isError=true). App tokens cannot call
# the Users API. The live session probed identity with a compound command
# that also ran `whoami`; both `gh api /user` legs 403'd and the assistant
# walked past them with more toolCalls and no user-facing text naming the
# failure.
#
# The detector already flags this class via isError + HTTP 403 /
# REAL_ERR_RE. A suppression would silence a real signal. This file locks
# the live #1253 shape, the FLAG_RE additions (`\b403\b` and
# `not accessible by integration`, parallel to `\b404\b` for #698), and
# the three-place citation (docstring, prompt, test host) so a future
# refactor cannot regress it. The auto-filed issue closes via
# observe-to-close (fleet-ops#650) when the session mtime ages out of the
# 24h window.
#
# Live session: 2026-08-27T16-15-45-417Z_01a04401-8509-7e94-8611-0fc81a5d1b85.jsonl
# Command:
#   echo "=== worker identity ==="; gh api /user 2>&1 | head -5;
#   echo "---"; whoami; echo "--- git identity ---";
#   gh api /user --jq '.login' 2>&1
# ToolResult concatenates the JSON body with `gh:` on the same line
# (`"}gh: Resource not accessible by integration (HTTP 403)`), then a
# successful `whoami` (`nish`), then a second 403, then
# `Command exited with code 1`. The next assistant turns were empty /
# toolCall-only; none named the 403.
#
# Scenarios:
#   1. live #1253 shape: gh api /user 403 + whoami in the same command,
#      then a silent toolCall recovery -> finding. Snippet must carry
#      `Resource not accessible by integration` and `HTTP 403`.
#   2. same shape plus a later thinking-only note -> still a finding.
#   3. same shape plus later unrelated user-facing prose -> still a finding.
#   4. same shape plus a later user-facing flag that names `403` -> clean.
#   5. same shape plus a later flag that quotes
#      `Resource not accessible by integration` (no "failed" / "403") ->
#      clean. Pins the FLAG_RE phrase so quoting the live wording counts.
#   6. cross-check: the #698 `gh: Not Found (HTTP 404)` walk-past
#      continues to be flagged so a refactor that only handles 403
#      does not break the original gh-api class.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-gh-api-403.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T16:16:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T18:00:00Z"
}

# Live toolResult text: JSON body concatenated with `gh:` (no newline
# between `}` and `gh:`), whoami output, second 403, exit 1.
LIVE_RESULT='{"type":"message","message":{"role":"toolResult","toolCallId":"call_id","toolName":"bash","isError":true,"content":[{"type":"text","text":"=== worker identity ===\n{\"message\":\"Resource not accessible by integration\",\"documentation_url\":\"https://docs.github.com/rest/users/users#get-the-authenticated-user\",\"status\":\"403\"}gh: Resource not accessible by integration (HTTP 403)\n---\nnish\n--- git identity ---\n{\"message\":\"Resource not accessible by integration\",\"documentation_url\":\"https://docs.github.com/rest/users/users#get-the-authenticated-user\",\"status\":\"403\"}gh: Resource not accessible by integration (HTTP 403)\n\n\nCommand exited with code 1"}]}}'
LIVE_CALL='{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_id","name":"bash","arguments":{"command":"echo \"=== worker identity ===\"; gh api /user 2>&1 | head -5; echo \"---\"; whoami; echo \"--- git identity ---\"; gh api /user --jq '"'"'.login'"'"' 2>&1"}}]}}'

# --- 1. live #1253 shape: gh api /user 403 walked past --------------------
{
  echo "$LIVE_CALL"
  echo "$LIVE_RESULT"
  echo '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_next","name":"bash","arguments":{"command":"gh issue view 1136 -R Nishfleet/fleet-ops --json number,title,body"}}]}}'
} >"$sessions/gh-api-403-walked.jsonl"
touch -d "2026-08-27T16:16:00Z" "$sessions/gh-api-403-walked.jsonl"

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1253 gh api /user 403 walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Resource not accessible by integration' <<<"$snippet" \
  || fail "finding snippet should mention 'Resource not accessible by integration' (got $snippet)"
grep -q 'status":"403"' <<<"$snippet" \
  || fail "finding snippet should mention status 403 (got $snippet)"
ok "live #1253: gh api /user 403 with silent toolCall recovery is flagged"
rm -f "$sessions/gh-api-403-walked.jsonl"

# --- 2. thinking-only recovery is still a finding -------------------------
{
  echo "$LIVE_CALL"
  echo "$LIVE_RESULT"
  echo '{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"gh api /user 403d because this is an App token. I will skip identity and read the issue."},{"type":"toolCall","id":"call_next2","name":"bash","arguments":{"command":"gh issue view 1136 -R Nishfleet/fleet-ops --comments"}}]}}'
} >"$sessions/gh-api-403-thinking.jsonl"
touch -d "2026-08-27T16:16:00Z" "$sessions/gh-api-403-thinking.jsonl"

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "gh api /user 403 with thinking-only recovery should be a finding (got $count) $report"
ok "live #1253: gh api /user 403 with later thinking-only recovery is still flagged"
rm -f "$sessions/gh-api-403-thinking.jsonl"

# --- 3. later unrelated user-facing prose does not discharge --------------
{
  echo "$LIVE_CALL"
  echo "$LIVE_RESULT"
  echo '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now let me look at the issue body and the existing claim branch."}]}}'
} >"$sessions/gh-api-403-prose.jsonl"
touch -d "2026-08-27T16:16:00Z" "$sessions/gh-api-403-prose.jsonl"

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "gh api /user 403 followed by unrelated prose should be a finding (got $count) $report"
ok "live #1253: gh api /user 403 with unrelated user-facing prose is still flagged"
rm -f "$sessions/gh-api-403-prose.jsonl"

# --- 4. later user-facing flag that names 403 is clean --------------------
{
  echo "$LIVE_CALL"
  echo "$LIVE_RESULT"
  echo '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the gh api /user call returned HTTP 403, App tokens cannot call the Users API, using whoami."}]}}'
} >"$sessions/gh-api-403-flagged-code.jsonl"
touch -d "2026-08-27T16:16:00Z" "$sessions/gh-api-403-flagged-code.jsonl"

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "gh api /user 403 plus later flag naming 403 should be clean (got $count) $report"
ok "gh api /user 403 plus later user-facing flag naming 403 is clean"
rm -f "$sessions/gh-api-403-flagged-code.jsonl"

# --- 5. quoting the live wording (no failed / 403) is also clean ----------
{
  echo "$LIVE_CALL"
  echo "$LIVE_RESULT"
  echo '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"gh api /user returned Resource not accessible by integration; expected for an App token, moving on with whoami."}]}}'
} >"$sessions/gh-api-403-flagged-phrase.jsonl"
touch -d "2026-08-27T16:16:00Z" "$sessions/gh-api-403-flagged-phrase.jsonl"

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "quoting 'Resource not accessible by integration' should be clean (got $count) $report"
ok "quoting live 'Resource not accessible by integration' wording is a flag"
rm -f "$sessions/gh-api-403-flagged-phrase.jsonl"

# --- 6. cross-check: #698 HTTP 404 walk-past still flagged ----------------
write_session "gh-api-404-contrast" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_wf","name":"bash","arguments":{"command":"gh api \"repos/Nishfleet/0509/actions/workflow-runs?head_sha=deadbeef&per_page=100\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_wf","toolName":"bash","isError":true,"content":[{"type":"text","text":"{\n  \"message\": \"Not Found\",\n  \"documentation_url\": \"https://docs.github.com/rest\",\n  \"status\": \"404\"\n}gh: Not Found (HTTP 404)\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"All node tests pass. Now let me look at the Class B PRs."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "HTTP 404 walk-past must still be flagged (got $count) $report"
ok "HTTP 404 walk-past continues to be flagged (contrast with #1253)"
rm -f "$sessions/gh-api-404-contrast.jsonl"

# --- 7. prompts/worker.md cites fleet-ops#1253 (prompt-side lock) ---------
worker="$repo_root/lib/failed-command-flagged.py"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1253' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1253 (prompt-side lock)"
grep -q 'Resource not accessible by integration' "$worker" \
  || fail "prompts/worker.md must name the live 'Resource not accessible by integration' wording"
grep -q 'gh api /user' "$worker" \
  || fail "prompts/worker.md must name the live 'gh api /user' command"
ok "worker.md cites fleet-ops#1253 and the live gh api /user 403 wording"

# --- 8. lib/failed-command-flagged.py docstring cites fleet-ops#1253 ------
grep -q 'fleet-ops#1253' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1253 (detector-side lock)"
grep -q 'Resource not accessible by integration' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 403 wording"
grep -q '\\b403\\b' "$lib" \
  || fail "lib/failed-command-flagged.py FLAG_RE must include \\\\b403\\\\b"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1253 and FLAG_RE includes 403"

# --- 9. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ------
grep -Fq 'bash "$here/fleet-failed-command-gh-api-403-integration.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-gh-api-403-integration: live #1253 gh api /user 403 drills"
