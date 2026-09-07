#!/usr/bin/env bash
# tests/fleet-failed-command-read-enoent-skip-todos.test.sh
#
# fleet-ops#958: same origin session as #953/#662
# (2026-08-26T14-02-29-714Z_01a03e61-27d2-7c3f-9101-da19c90f6ba5.jsonl).
# PR #1050 locked one thinking-only recovery turn plus a later bare
# "Now I have the full picture. Let me plan and execute." text message.
# The live session was longer than that fixture:
#
#   - several thinking-only recovery turns in a row (find OVERNIGHT*,
#     then skip, then more probes), including a thinking block that
#     decides to skip ("Let me look for it elsewhere or skip")
#   - the first user-facing text is that same "Now I have the full
#     picture. Let me plan and execute." line bundled with todo
#     toolCalls in the SAME assistant turn
#
# A thinking block that names the miss and decides to skip is not a
# user-facing flag (fleet-ops#535). Todo toolCalls next to unrelated
# prose do not name the failure either. A future detector refactor
# must not:
#   - treat "skip" in a thinking field as a discharge
#   - treat the first user-facing turn as a flag just because it also
#     carries todo toolCalls
#   - only inspect the immediately-next assistant turn (the live
#     session had many thinking-only turns before the prose)
#
# The auto-filed issue closes via observe-to-close (fleet-ops#758)
# when the session mtime ages out of the 24h window.
#
# Scenarios:
#   1. live #958 shape: parallel siblings + ENOENT + several
#      thinking-only recoveries (including an explicit skip) + later
#      "full picture" prose bundled with todos -> finding.
#   2. same shape plus a later user-facing flag that NAMES the
#      failure -> clean.
#   3. lib/failed-command-flagged.py cites fleet-ops#958 (detector-side lock: case list moved to lib, fleet-ops#3246).
#   4. seat-lib.test.sh hosts this file (CI cannot gain a new P14 line).
#   5. guard-fires drill: a worker.md copy stripped of the locked
#      wording fails the scenario-3 checks (fleet-ops#2101 prevention).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-read-enoent-skip-todos.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-26T14:02:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-26T14:30:00Z"
}

# --- 1. live #958: many thinking-only turns, skip, then todos + prose ------
# Replay the live remainder that #1050 simplified away: three thinking-only
# recovery turns (find / skip / "full picture" still inside thinking),
# then the first user-facing text bundled with todo toolCalls.
write_session "read-enoent-skip-todos" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me read the context files first."},{"type":"toolCall","id":"call_ls","name":"bash","arguments":{"command":"ls ~/workspaces/agent-state/ 2>/dev/null | head -30 && echo \"---\" && ls ~/workspaces/agent-state/FLEET-PAUSED 2>/dev/null"}},{"type":"toolCall","id":"call_intake","name":"read","arguments":{"path":"/home/nish/workspaces/tooling/fleet-ops-deploy-clone/config/intake-repos.json"}},{"type":"toolCall","id":"call_overnight","name":"read","arguments":{"path":"/home/nish/workspaces/agent-state/OVERNIGHT.md"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ls","toolName":"bash","isError":false,"content":[{"type":"text","text":"AUDITOR-LOG.md\nFLEET-HEARTBEAT-TRIAGE.md\nlanes\n---"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_intake","toolName":"read","isError":false,"content":[{"type":"text","text":"{\"repos\":[]}"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_overnight","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/agent-state/OVERNIGHT.md'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"OVERNIGHT.md is missing. Let me look for it elsewhere or skip."},{"type":"toolCall","id":"call_find","name":"bash","arguments":{"command":"find /home/nish/workspaces/agent-state -maxdepth 2 -iname \"OVERNIGHT*\" 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_find","toolName":"bash","isError":false,"content":[{"type":"text","text":""}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Important findings: OVERNIGHT.md missing from agent-state dir. Let me look for it elsewhere or skip. Confirm fleet state."},{"type":"toolCall","id":"call_timers","name":"bash","arguments":{"command":"XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers --no-pager | head"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_timers","toolName":"bash","isError":false,"content":[{"type":"text","text":"NEXT LEFT LAST PASSED UNIT"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Excellent. Now I have the full picture: fleet is RESTORED. OVERNIGHT.md is still missing; skip it and execute."},{"type":"toolCall","id":"call_log","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && git log --oneline -3"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_log","toolName":"bash","isError":false,"content":[{"type":"text","text":"a8dd525 fix(tests): CI-safe no-agent-names"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now I have the full picture. Let me plan and execute."},{"type":"toolCall","id":"call_todo1","name":"todo","arguments":{"action":"add","text":"Create branch","id":1}},{"type":"toolCall","id":"call_todo2","name":"todo","arguments":{"action":"add","text":"Edit intake-repos.json","id":2}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #958 multi-turn skip + todos prose should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'ENOENT: no such file or directory, access' <<<"$snippet" \
  || fail "finding snippet should mention live ENOENT wording (got $snippet)"
grep -q 'OVERNIGHT.md' <<<"$snippet" \
  || fail "finding snippet should mention OVERNIGHT.md (got $snippet)"
ok "live #958: several thinking-only recoveries (skip) then todos + 'full picture' prose is flagged"
rm -f "$sessions/read-enoent-skip-todos.jsonl"

# --- 2. same shape plus a later user-facing flag is clean ------------------
write_session "read-enoent-skip-todos-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_overnight2","name":"read","arguments":{"path":"/home/nish/workspaces/agent-state/OVERNIGHT.md"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_overnight2","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/agent-state/OVERNIGHT.md'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"OVERNIGHT.md is missing. Let me look for it elsewhere or skip."},{"type":"toolCall","id":"call_find2","name":"bash","arguments":{"command":"find /home/nish/workspaces/agent-state -maxdepth 2 -iname \"OVERNIGHT*\" 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_find2","toolName":"bash","isError":false,"content":[{"type":"text","text":""}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Excellent. Now I have the full picture."},{"type":"toolCall","id":"call_todo3","name":"todo","arguments":{"action":"add","text":"Plan","id":1}}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the OVERNIGHT.md read failed with ENOENT — the AGENTS.md reference is dangling, it is now the blocker."},{"type":"toolCall","id":"call_todo4","name":"todo","arguments":{"action":"add","text":"File the dangling path","id":2}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "read ENOENT with later user-facing flag should be clean (got $count) $report"
ok "live #958 positive: skip-then-todos shape plus later named flag is clean"
rm -f "$sessions/read-enoent-skip-todos-flagged.jsonl"

# --- 3. lib/failed-command-flagged.py cites fleet-ops#958 (detector-side lock: case list moved to lib, fleet-ops#3246) -------------------
worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#958' "$lib" \
  || fail "lib/failed-command-flagged.py must cite fleet-ops#958 (detector-side lock for the live skip-then-todos ENOENT shape)"
grep -q "ENOENT: no such file or directory, access" "$lib" \
  || fail "lib/failed-command-flagged.py must name the live ENOENT wording so workers flag it"
ok "lib/failed-command-flagged.py cites fleet-ops#958 and the live ENOENT wording"

# --- 5. guard-fires drill: drift in the #958 citation fails scenario 3 ------
# fleet-ops#2101: prompts/worker.md lost the #958 citation (plus 17 siblings)
# and the P14 suite caught it red on main (FleetMainRed). The scenario-3
# greps are the guard. This drill proves the guard FIRES: a worker.md copy
# with the locked wording stripped must fail the exact scenario-3 checks, so
# a future refactor cannot soften those greps without a named FAIL here.
drift="$scratch/worker.md"
cp "$worker" "$drift" || fail "could not copy worker.md to scratch"
sed -i 's/fleet-ops#958//g' "$drift" || fail "could not strip #958 citation from drill copy"
sed -i 's/ENOENT: no such file or directory, access/ENOENT-X/g' "$drift" || fail "could not strip ENOENT wording from drill copy"
if grep -q 'fleet-ops#958' "$drift"; then
  fail "drill: stripped copy still cites fleet-ops#958"
fi
set +e
grep -q 'fleet-ops#958' "$drift"
rc=$?
set -e
[[ "$rc" == 1 ]] || fail "guard must fire when worker.md loses the fleet-ops#958 citation (got rc=$rc)"
set +e
grep -q 'ENOENT: no such file or directory, access' "$drift"
rc=$?
set -e
[[ "$rc" == 1 ]] || fail "guard must fire when worker.md loses the ENOENT wording (got rc=$rc)"
ok "guard fires when worker.md drifts off the fleet-ops#958 lock wording"

# --- 4. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-read-enoent-skip-todos.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-read-enoent-skip-todos: live #958 multi-turn skip + todos drills"
