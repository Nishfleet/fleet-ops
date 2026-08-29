#!/usr/bin/env bash
# tests/fleet-failed-command-systemctl-status-failed.test.sh
#
# fleet-ops#784: `systemctl --user status` of a failed unit is a real
# swallowed failure when the assistant walks past the non-zero. systemd
# documents exit 3 for a unit that is not active; on a failed unit the
# output starts with `× unit` and `Active: failed (Result: exit-code)`,
# the harness sets isError=true, and `Command exited with code 3`.
# Burying that in a thinking block plus another probe does not count
# as a flag. The detector already flags this class (isError + exit 3,
# command is not a grep/rg/diff no-match). This file locks the live
# #784 shape so a future detector refactor cannot regress it.
#
# fleet-ops#879: the same `systemctl --user status` call piped through
# `head` is missed because bash has no `pipefail` by default. The
# pipeline exit is `head`'s 0, so isError=false and there is no
# `Command exited with code 3` trailer, but the output still shows
# `× unit` and `Active: failed`. Detect this from the command and the
# output content.
#
# Live session: 2026-08-27T01-49-30-032Z_01a040e8-7030-72f9-bb6c-ed7efd812bee.jsonl
# The unpiped `systemctl --user status 'fleet-deploy-check.service' --no-pager`
# call returned 3 because the unit was Active: failed, and the assistant
# continued in thinking ("The fleet-deploy-check failed because...") plus
# a git-status probe without naming the failure in user-facing text.
#
# Scenarios:
#   1. live #784 shape: systemctl status of a failed unit, exit 3,
#      thinking-only follow-up -> finding.
#   2. same shape plus a later user-facing flag -> clean.
#   3. same class, different unit name (pi-audit@...) walked past ->
#      finding. The lock is the systemd-status-failed class, not one
#      unit id.
#   4. `systemctl --user --failed` listing with isError=false is clean:
#      the list command itself succeeded. Failed units in successful
#      output are not a swallowed command failure.
#   5. fleet-ops#879: systemctl status of a failed unit piped through
#      `head`, isError=false, no exit-code trailer, thinking-only
#      follow-up -> finding.
#   6. same piped shape plus a later user-facing flag -> clean.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-systemctl-status.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T01:54:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T02:30:00Z"
}

# --- 1. live #784 shape: systemctl status failed unit walked past ------------
# Replay the unpiped status call, the × / Active: failed / exit 3
# toolResult, and the thinking-only follow-up that was the live miss.
write_session "systemctl-status-failed" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_status","name":"bash","arguments":{"command":"# fleet-deploy-check.service is also failed - this is critical\nsystemctl --user status 'fleet-deploy-check.service' --no-pager 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_status","toolName":"bash","isError":true,"content":[{"type":"text","text":"× fleet-deploy-check.service - Fleet merge-to-live deploy check (tight cadence, fleet-ops#468)\n     Loaded: loaded (/home/nish/.config/systemd/user/fleet-deploy-check.service; enabled; preset: enabled)\n     Active: failed (Result: exit-code) since Thu 2026-08-27 07:24:06 IST; 27s ago\n   Main PID: 907286 (code=exited, status=1/FAILURE)\n\nAug 27 07:24:06 netcup-rs2000 fleet-deploy-check[907286]: [2026-08-27T01:54:06Z] [fleet-deploy-check] LOUD DEPLOY-CHECK-FAILED fleet-ops-deploy exited rc=1 — merge-to-live gate red\nAug 27 07:24:06 netcup-rs2000 systemd[1125]: fleet-deploy-check.service: Failed with result 'exit-code'.\n\n\nCommand exited with code 3"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The fleet-deploy-check failed because the deploy-clone checkout has dirty tracked files. Let me check what's dirty."},{"type":"toolCall","id":"call_git","name":"bash","arguments":{"command":"git -C /home/nish/workspaces/tooling/fleet-ops-deploy-clone status --short 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_git","toolName":"bash","isError":false,"content":[{"type":"text","text":" M bin/pi-issue-run\n"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #784 systemctl status failed walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'fleet-deploy-check.service' <<<"$snippet" \
  || fail "finding snippet should mention fleet-deploy-check.service (got $snippet)"
ok "live #784 systemctl status of failed unit walked past is flagged"
rm -f "$sessions/systemctl-status-failed.jsonl"

# --- 2. same shape plus a later user-facing flag is clean --------------------
write_session "systemctl-status-failed-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_status2","name":"bash","arguments":{"command":"systemctl --user status 'fleet-deploy-check.service' --no-pager 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_status2","toolName":"bash","isError":true,"content":[{"type":"text","text":"× fleet-deploy-check.service - Fleet merge-to-live deploy check (tight cadence, fleet-ops#468)\n     Active: failed (Result: exit-code)\n\n\nCommand exited with code 3"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the systemctl status call failed with exit 3, fleet-deploy-check.service is Active: failed. Checking the journal next."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged systemctl status failed should be clean (got $count) $report"
ok "systemctl status failed plus later user-facing flag is clean"
rm -f "$sessions/systemctl-status-failed-flagged.jsonl"

# --- 3. same class, different unit name --------------------------------------
write_session "systemctl-status-piaudit-failed" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_audit","name":"bash","arguments":{"command":"systemctl --user status 'pi-audit@0509--1256--free-glm-5-3.service' --no-pager 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_audit","toolName":"bash","isError":true,"content":[{"type":"text","text":"× pi-audit@0509--1256--free-glm-5-3.service - Senior auditor panel vote for 0509--1256--free-glm-5-3 (fleet-ops#146)\n     Active: failed (Result: exit-code)\n   Main PID: 1 (code=exited, status=1/FAILURE)\n\n\nCommand exited with code 3"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next check."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "systemctl status of a different failed unit walked past should be a finding (got $count) $report"
ok "systemctl status of a different failed unit walked past is flagged"
rm -f "$sessions/systemctl-status-piaudit-failed.jsonl"

# --- 4. successful --failed listing is not a swallowed failure ---------------
write_session "systemctl-failed-list-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_list","name":"bash","arguments":{"command":"systemctl --user --failed --no-pager"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_list","toolName":"bash","isError":false,"content":[{"type":"text","text":"  UNIT                                      LOAD   ACTIVE SUB    DESCRIPTION\n● fleet-deploy-check.service                loaded failed failed Fleet merge-to-live deploy check (tight cadence, fleet-ops#468)\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Four failed units listed. Checking fleet-deploy-check first."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "successful systemctl --failed listing should be clean (got $count) $report"
ok "successful systemctl --failed listing is clean"
rm -f "$sessions/systemctl-failed-list-ok.jsonl"

# --- 5. piped through `head`, isError=false, no exit-code trailer ----------
# fleet-ops#879: the pipeline exit is `head`'s 0, so Pi sees isError=false
# and no `Command exited with code` line. The output still contains
# `× unit` and `Active: failed (Result: exit-code)`.
write_session "systemctl-status-failed-piped" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_piped","name":"bash","arguments":{"command":"systemctl --user status 'fleet-deploy-check.service' --no-pager | head -15"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_piped","toolName":"bash","isError":false,"content":[{"type":"text","text":"× fleet-deploy-check.service - Fleet merge-to-live deploy check (tight cadence, fleet-ops#468)\n     Loaded: loaded (/home/nish/.config/systemd/user/fleet-deploy-check.service; enabled; preset: enabled)\n     Active: failed (Result: exit-code) since Thu 2026-08-27 07:24:06 IST; 27s ago\n   Main PID: 907286 (code=exited, status=1/FAILURE)\n\nAug 27 07:24:06 netcup-rs2000 fleet-deploy-check[907286]: [2026-08-27T01:54:06Z] [fleet-deploy-check] LOUD DEPLOY-CHECK-FAILED fleet-ops-deploy exited rc=1 — merge-to-live gate red\nAug 27 07:24:06 netcup-rs2000 systemd[1125]: fleet-deploy-check.service: Failed with result 'exit-code'.\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next check."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "piped systemctl status failed walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'fleet-deploy-check.service' <<<"$snippet" \
  || fail "finding snippet should mention fleet-deploy-check.service (got $snippet)"
ok "piped systemctl status of failed unit walked past is flagged"
rm -f "$sessions/systemctl-status-failed-piped.jsonl"

# --- 6. same piped shape plus a later user-facing flag is clean --------------
write_session "systemctl-status-failed-piped-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_piped2","name":"bash","arguments":{"command":"systemctl --user status 'fleet-deploy-check.service' --no-pager | head -15"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_piped2","toolName":"bash","isError":false,"content":[{"type":"text","text":"× fleet-deploy-check.service - Fleet merge-to-live deploy check (tight cadence, fleet-ops#468)\n     Active: failed (Result: exit-code)\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the systemctl status call shows Active: failed, fleet-deploy-check.service is down. Checking the journal next."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged piped systemctl status failed should be clean (got $count) $report"
ok "piped systemctl status failed plus later user-facing flag is clean"
rm -f "$sessions/systemctl-status-failed-piped-flagged.jsonl"

echo "OK: fleet-failed-command-systemctl-status-failed: live #784 status-failed + #879 piped + flag drill"
