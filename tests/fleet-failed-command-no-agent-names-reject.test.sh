#!/usr/bin/env bash
# tests/fleet-failed-command-no-agent-names-reject.test.sh
#
# fleet-ops#1052: a bin/fleet-no-agent-names-check REJECT (exit 1 with
# REJECT: agent attribution found) is a real swallowed failure when the
# worker walks past it by explaining the output as the test exercising the
# tool. The live 01a041ea session was filing fleet-ops#926; it ran
#   fleet-no-agent-names-check --pr-body tests/fleet-no-agent-names.test.sh
# and got REJECT because the drill file contains example attribution
# strings. The next turn said "Good - this is testing the tool's behavior..."
# and moved on. That prose does NOT name the failure; it is the same
# walked-past class as #936 / #943.
#
# A worker that names the failure in user-facing text is clean. A worker
# that explains it away is filed. The detector already flags this class; this
# file locks the shape and adds the prompt-side + lib-docstring citations.
#
# The auto-filed issue closes via observe-to-close when the session mtime
# ages out of the 24h window.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-no-agent-names-reject.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T06:30:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T07:00:00Z"
}

# --- 1. live #1052 shape: no-agent-names REJECT explained away as test data --
write_session "no-agent-names-reject-walked-past" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_nanc","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-926 && bin/fleet-no-agent-names-check --pr-body tests/fleet-no-agent-names.test.sh 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_nanc","toolName":"bash","isError":true,"content":[{"type":"text","text":"REJECT: agent attribution found\n  - PR body line 124: Co-Authored-By trailer is forbidden: 'Co-Authored-By: Claude <claude@example.com>'\n  - PR body line 125: Generated-with/by footer is forbidden: 'Generated with Devin\"'\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Good - this is testing the tool's behavior. These are intentional agent names in the test cases. The test is designed to verify the tool REJECTS these patterns. So the test should fail when run with \u0060--pr-body\u0060 against itself (which is the correct behavior)."},{"type":"toolCall","id":"call_next","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-926 && bin/fleet-no-agent-names-check --commit-range 'HEAD~1..HEAD' 2>&1"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1052 no-agent-names REJECT walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'REJECT: agent attribution found' <<<"$snippet" \
  || fail "finding snippet should mention no-agent-names REJECT (got $snippet)"
ok "live #1052: no-agent-names REJECT explained away as test data is flagged"
rm -f "$sessions/no-agent-names-reject-walked-past.jsonl"

# --- 2. same shape plus a user-facing flag is clean --------------------------
write_session "no-agent-names-reject-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_nanc2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-926 && bin/fleet-no-agent-names-check --pr-body tests/fleet-no-agent-names.test.sh 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_nanc2","toolName":"bash","isError":true,"content":[{"type":"text","text":"REJECT: agent attribution found\n  - PR body line 124: Co-Authored-By trailer is forbidden: 'Co-Authored-By: Claude <claude@example.com>'\n  - PR body line 125: Generated-with/by footer is forbidden: 'Generated with Devin\"'\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the fleet-no-agent-names-check call failed with REJECT: agent attribution found, it is now the blocker"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged no-agent-names REJECT should be clean (got $count) $report"
ok "no-agent-names REJECT plus user-facing flag is clean"
rm -f "$sessions/no-agent-names-reject-flagged.jsonl"

# --- 3. prompts/worker.md must forbid explaining a REJECT as test data -------
worker="$repo_root/lib/failed-command-flagged.py"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1052' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1052 (prompt-side lock for no-agent-names REJECT walk-past)"
grep -q 'REJECT: agent attribution found' "$worker" \
  || fail "prompts/worker.md must name the REJECT wording so workers flag it"
grep -q 'explain it away' "$worker" \
  || fail "prompts/worker.md must forbid explaining a no-agent-names REJECT as test data"
ok "worker.md cites #1052 and forbids explaining the REJECT as test data"

# --- 4. lib/failed-command-flagged.py docstring cites #1052 ------------------
[[ -f "$lib" ]] || fail "missing $lib"
grep -q 'fleet-ops#1052' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1052 (detector contract for no-agent-names REJECT)"
grep -q 'REJECT: agent attribution found' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live REJECT wording"
grep -q 'fleet-no-agent-names-check' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the tool"
ok "lib/failed-command-flagged.py docstring cites #1052 and the REJECT shape"

# --- 5. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ---------
seat_lib="$here/seat-lib.test.sh"
[[ -f "$seat_lib" ]] || fail "missing $seat_lib"
pattern='bash "$here/fleet-failed-command-no-agent-names-reject.test.sh"'
grep -Fq "$pattern" "$seat_lib" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-no-agent-names-reject: live #1052 shape + prompt/lib/CI locks"
