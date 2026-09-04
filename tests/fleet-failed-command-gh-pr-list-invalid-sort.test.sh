#!/usr/bin/env bash
# tests/fleet-failed-command-gh-pr-list-invalid-sort.test.sh
#
# fleet-ops#1107: a compound
#   echo "=== MERGED RECENT ==="
#   gh pr list -R ... --state merged --sort -mergedAt ... 2>/dev/null
# chain is a real swallowed failure. `--sort -mergedAt` is not a valid
# `gh pr list` sort value, stderr is silenced, and the toolResult is
# only the echo marker plus `Command exited with code 1` (isError=true).
# The assistant walked past it with thinking-only recovery and later
# "Now I have the full picture. Let me fix and re-dispatch." prose.
#
# The detector already flags this class via the generic isError path.
# No `lib/failed-command-flagged.py` logic change is needed; a
# suppression would silence a real signal. The tempting future
# exemptions this file forbids:
#   - treating `gh pr list` / `gh search prs` as a no-match probe
#   - treating a printed echo marker + empty failure as benign because
#     there is no `unknown flag` / HTTP error string (stderr silenced)
#   - treating `2>/dev/null` silenced gh failures as probes
#   - treating "Now I have the full picture" prose as naming the failure
#   - collapsing the lock into "every `=== MERGED RECENT ===` + exit 1
#     is a failure" (a `; grep` sibling with the same marker must stay
#     a POSIX no-match probe)
# Distinct from:
#   - #1055: `gh issue view --body` with visible `unknown flag: --body`
#   - #698: `gh api` HTTP 404 with visible `Not Found`
#   - #1217: racing silenced `cd` with `(no output)` and no marker
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T11-16-51-853Z_01a042ef-e00d-7ace-b43a-7e40a2623f48.jsonl
# Detector snippet: `=== MERGED RECENT ===   Command exited with code 1`.
#
# Scenarios:
#   1. live #1107 shape: silenced invalid `--sort -mergedAt` walked past
#      with thinking + "full picture" prose -> finding. Snippet must
#      carry `=== MERGED RECENT ===` and `Command exited with code 1`.
#   2. same shape plus a later thinking-only note -> still a finding.
#   3. same shape plus later unrelated user-facing prose that does NOT
#      name the failure -> still a finding.
#   4. same shape plus a later user-facing flag -> clean.
#   5. cross-check: `echo "=== MERGED RECENT ==="; grep ...` POSIX
#      no-match with the same marker stays a probe.
#   6. worker.md cites fleet-ops#1107 and the live wording.
#   7. lib/failed-command-flagged.py docstring cites fleet-ops#1107.
#   8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"
worker="$repo_root/lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-gh-pr-list-invalid-sort.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T11:16:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T13:00:00Z"
}

# --- 1. live #1107 shape: silenced invalid sort walked past ----------------
# Replay the exact compound from slug 01a042ef: echo prints the marker,
# `gh pr list --sort -mergedAt ... 2>/dev/null` exits 1 with no stderr,
# next turns are thinking then "Now I have the full picture...".
write_session "gh-pr-list-invalid-sort-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_merged","name":"bash","arguments":{"command":"gh search prs -R Nishfleet/fleet-ops --state open --json number,title,mergedAt --jq '.[:20]' 2>/dev/null\necho \"=== MERGED RECENT ===\"\ngh pr list -R Nishfleet/fleet-ops --state merged --sort -mergedAt --json number,title --limit 20 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_merged","toolName":"bash","isError":true,"content":[{"type":"text","text":"=== MERGED RECENT ===\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The merged-PR list did not come back. I will keep diagnosing from what I already have."},{"type":"toolCall","id":"call_next","name":"bash","arguments":{"command":"gh pr view 1071 -R Nishfleet/fleet-ops --json title,state"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_next","toolName":"bash","isError":false,"content":[{"type":"text","text":"{\"title\":\"fix(failed-command): local ledger dedup\",\"state\":\"MERGED\"}"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now I have the full picture. Let me fix and re-dispatch."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1107 gh pr list --sort -mergedAt walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q '=== MERGED RECENT ===' <<<"$snippet" \
  || fail "finding snippet should mention === MERGED RECENT === (got $snippet)"
grep -q 'Command exited with code 1' <<<"$snippet" \
  || fail "finding snippet should mention Command exited with code 1 (got $snippet)"
ok "live #1107: silenced invalid gh pr list --sort -mergedAt with full-picture prose is flagged"
rm -f "$sessions/gh-pr-list-invalid-sort-walked.jsonl"

# --- 2. thinking-only recovery is still a finding --------------------------
write_session "gh-pr-list-invalid-sort-thinking" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_merged2","name":"bash","arguments":{"command":"echo \"=== MERGED RECENT ===\"\ngh pr list -R Nishfleet/fleet-ops --state merged --sort -mergedAt --json number,title --limit 20 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_merged2","toolName":"bash","isError":true,"content":[{"type":"text","text":"=== MERGED RECENT ===\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"gh pr list rejected --sort -mergedAt. I will use --limit without that sort."},{"type":"toolCall","id":"call_retry2","name":"bash","arguments":{"command":"gh pr list -R Nishfleet/fleet-ops --state merged --limit 20 --json number,title"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "silenced invalid sort with thinking-only recovery should be a finding (got $count) $report"
ok "live #1107: silenced invalid sort with later thinking-only recovery is still flagged"
rm -f "$sessions/gh-pr-list-invalid-sort-thinking.jsonl"

# --- 3. later unrelated user-facing prose does not discharge ---------------
write_session "gh-pr-list-invalid-sort-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_merged3","name":"bash","arguments":{"command":"echo \"=== MERGED RECENT ===\"\ngh pr list -R Nishfleet/fleet-ops --state merged --sort -mergedAt --json number,title --limit 20 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_merged3","toolName":"bash","isError":true,"content":[{"type":"text","text":"=== MERGED RECENT ===\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now I have the full picture. Let me fix and re-dispatch."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "silenced invalid sort followed by unrelated prose should be a finding (got $count) $report"
ok "live #1107: silenced invalid sort with unrelated user-facing prose is still flagged"
rm -f "$sessions/gh-pr-list-invalid-sort-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean ------------------
write_session "gh-pr-list-invalid-sort-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_merged4","name":"bash","arguments":{"command":"echo \"=== MERGED RECENT ===\"\ngh pr list -R Nishfleet/fleet-ops --state merged --sort -mergedAt --json number,title --limit 20 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_merged4","toolName":"bash","isError":true,"content":[{"type":"text","text":"=== MERGED RECENT ===\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the gh pr list --sort -mergedAt call failed with exit 1 (=== MERGED RECENT ===, stderr silenced). I will list merged PRs without that sort."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "silenced invalid sort with later user-facing flag should be clean (got $count) $report"
ok "silenced invalid gh pr list sort plus later user-facing flag is clean"
rm -f "$sessions/gh-pr-list-invalid-sort-flagged.jsonl"

# --- 5. cross-check: echo marker + grep POSIX no-match stays a probe -------
# The live #1107 session also carried a later
#   grep -n "953-requeue.*ENOS" ...; echo "==="; grep -n "fleet-ops-965-requeue..."
# that exited 1. That is BENIGN_STAGE_RE. Locking the invalid-sort shape
# must not collapse into "every === MERGED RECENT === + exit 1 is a failure".
write_session "merged-recent-grep-no-match" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_grep","name":"bash","arguments":{"command":"grep -n \"953-requeue.*ENOS\" /home/nish/workspaces/agent-state/READY-WORK.md\necho \"=== MERGED RECENT ===\"\ngrep -n \"fleet-ops-965-requeue.*fixed-command\" /home/nish/workspaces/agent-state/READY-WORK.md"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_grep","toolName":"bash","isError":true,"content":[{"type":"text","text":"=== MERGED RECENT ===\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_next5","name":"bash","arguments":{"command":"wc -l /home/nish/workspaces/agent-state/READY-WORK.md"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "echo marker plus grep POSIX no-match must stay a probe (got $count) $report"
ok "grep POSIX no-match with the same === MERGED RECENT === snippet stays a probe (contrast with #1107)"
rm -f "$sessions/merged-recent-grep-no-match.jsonl"

# --- 6. prompts/worker.md cites fleet-ops#1107 (prompt-side lock) -----------
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1107' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1107 (prompt-side lock)"
grep -q -- '--sort -mergedAt' "$worker" \
  || fail "prompts/worker.md must name the live '--sort -mergedAt' wording"
grep -q '=== MERGED RECENT ===' "$worker" \
  || fail "prompts/worker.md must name the live '=== MERGED RECENT ===' wording"
ok "worker.md cites fleet-ops#1107 and the live invalid-sort wording"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#1107 -------
grep -q 'fleet-ops#1107' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1107 (detector-side lock)"
grep -q -- '--sort -mergedAt' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live '--sort -mergedAt' wording"
grep -q '=== MERGED RECENT ===' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live '=== MERGED RECENT ===' wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1107 and the invalid-sort shape"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-gh-pr-list-invalid-sort.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-gh-pr-list-invalid-sort: live #1107 silenced invalid-sort drills"
