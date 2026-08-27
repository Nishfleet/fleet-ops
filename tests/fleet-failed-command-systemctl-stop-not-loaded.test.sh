#!/usr/bin/env bash
# tests/fleet-failed-command-systemctl-stop-not-loaded.test.sh
#
# fleet-ops#1221: a compound `;`-separated `systemctl --user stop <unit>
# 2>&1; systemctl --user reset-failed <unit> 2>&1` (or the bare
# `systemctl --user stop <unit> 2>&1`) on a unit that is not currently
# loaded is a real swallowed failure. systemd prints
#   Failed to stop <unit>: Unit <unit> not loaded.
#   Failed to reset failed state of unit <unit>: Unit <unit> not loaded.
# on stderr, exits 1, the harness sets isError=true, and
# `Command exited with code 1` lands in the toolResult. The next
# assistant turn is a thinking-only note plus a `gh issue view` recovery
# toolCall with no user-facing text naming the failure. The detector
# already flags this class (isError + exit 1, command is not grep/rg/diff
# no-match). This file locks the live #1221 shape so a future detector
# refactor cannot regress it (e.g. by adding `systemctl` to
# BENIGN_STAGE_RE, treating `Unit ... not loaded.` as a probe line,
# or letting a same-turn sibling `systemctl --user status` success
# mask the failing `systemctl --user stop` tail).
#
# The class is distinct from #784 (`systemctl --user status` of an
# Active: failed unit, exit 3, `× unit`, `Active: failed`): the #1221
# shape is exit 1 with `Unit <name> not loaded.` and a non-silenced
# compound `;`-separated chain.
#
# Live session: 2026-08-27T15-29-03-179Z_01a043d6-c2cb-76cd-90c3-e9d8499c113d.jsonl
# The compound `;`-separated
#   systemctl --user stop 0509-devserver.service 2>&1;
#   systemctl --user reset-failed 0509-devserver.service 2>&1
# call returned 1 because the unit was not loaded, and the assistant
# continued in thinking plus a `gh issue view` recovery without naming
# the failure in user-facing text.
#
# Scenarios:
#   1. live #1221 shape: compound `;`-separated systemctl stop + reset-failed
#      on a not-loaded unit, exit 1, thinking-only follow-up -> finding.
#   2. bare `systemctl --user stop <unit> 2>&1` (no `;`-separated second
#      command) on a not-loaded unit, exit 1, thinking-only follow-up:
#      the same class -> finding.
#   3. same shape plus a later user-facing flag -> clean.
#   4. cross-check: #784 `systemctl --user status` exit 3 on a failed unit
#      is distinct; pin it separately so a future refactor that broadens
#      a systemctl exemption does not conflate them.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-systemctl-stop-not-loaded.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T15:34:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T16:30:00Z"
}

# --- 1. live #1221 shape: compound systemctl stop + reset-failed ------------
write_session "systemctl-stop-not-loaded" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_stop","name":"bash","arguments":{"command":"systemctl --user stop 0509-devserver.service 2>&1; systemctl --user reset-failed 0509-devserver.service 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_stop","toolName":"bash","isError":true,"content":[{"type":"text","text":"Failed to stop 0509-devserver.service: Unit 0509-devserver.service not loaded.\nFailed to reset failed state of unit 0509-devserver.service: Unit 0509-devserver.service not loaded.\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The unit 0509-devserver doesn't exist anymore\u2014it's been stopped and removed. Let me check the current state of the key items."},{"type":"toolCall","id":"call_gh","name":"bash","arguments":{"command":"gh issue list -R Nishfleet/0509 --state open --limit 5 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh","toolName":"bash","isError":false,"content":[{"type":"text","text":"Showing 5 of 48 open issues in Nishfleet/0509\n"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1221 systemctl stop not-loaded walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q '0509-devserver.service' <<<"$snippet" \
  || fail "finding snippet should mention 0509-devserver.service (got $snippet)"
ok "live #1221 systemctl stop not-loaded walked past is flagged"
rm -f "$sessions/systemctl-stop-not-loaded.jsonl"

# --- 2. bare systemctl stop (no ;-chain), same class -------------------------
write_session "systemctl-stop-bare-not-loaded" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_stop_bare","name":"bash","arguments":{"command":"systemctl --user stop some-other-unit.service 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_stop_bare","toolName":"bash","isError":true,"content":[{"type":"text","text":"Failed to stop some-other-unit.service: Unit some-other-unit.service not loaded.\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"That unit isn't loaded. Moving on to the next check."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "bare systemctl stop not-loaded walked past should be a finding (got $count) $report"
ok "bare systemctl stop not-loaded walked past is flagged"
rm -f "$sessions/systemctl-stop-bare-not-loaded.jsonl"

# --- 3. same shape plus later user-facing flag is clean ----------------------
write_session "systemctl-stop-not-loaded-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_stop3","name":"bash","arguments":{"command":"systemctl --user stop 0509-devserver.service 2>&1; systemctl --user reset-failed 0509-devserver.service 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_stop3","toolName":"bash","isError":true,"content":[{"type":"text","text":"Failed to stop 0509-devserver.service: Unit 0509-devserver.service not loaded.\nFailed to reset failed state of unit 0509-devserver.service: Unit 0509-devserver.service not loaded.\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the systemctl stop call failed with exit 1, Unit 0509-devserver.service not loaded. Checking the current state next."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged systemctl stop not-loaded should be clean (got $count) $report"
ok "systemctl stop not-loaded plus later user-facing flag is clean"
rm -f "$sessions/systemctl-stop-not-loaded-flagged.jsonl"

# --- 4. cross-check: #784 systemctl status failed unit exit 3 is distinct ---
write_session "systemctl-status-failed-784" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_status4","name":"bash","arguments":{"command":"systemctl --user status 'fleet-deploy-check.service' --no-pager 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_status4","toolName":"bash","isError":true,"content":[{"type":"text","text":"× fleet-deploy-check.service - Fleet merge-to-live deploy check\n     Active: failed (Result: exit-code)\n\n\nCommand exited with code 3"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The fleet-deploy-check failed. Let me check what's dirty."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "#784 systemctl status failed walk-past should still be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Command exited with code 3' <<<"$snippet" \
  || fail "#784 finding snippet should mention exit 3 (got $snippet)"
ok "cross-check: #784 systemctl status failed remained flagged"
rm -f "$sessions/systemctl-status-failed-784.jsonl"

echo "OK: fleet-failed-command-systemctl-stop-not-loaded: live #1221 stop-not-loaded + bare + flag + cross-check drills"