#!/usr/bin/env bash
# tests/fleet-failed-command-systemctl-stop-not-loaded.test.sh
#
# fleet-ops#1221: `systemctl --user stop <unit>` (or
# `systemctl --user reset-failed <unit>`) on a unit that is not
# currently loaded is a real swallowed failure when the assistant
# walks past the non-zero. systemd prints
#   Failed to stop <unit>: Unit <unit> not loaded.
#   Failed to reset failed state of unit <unit>: Unit <unit> not loaded.
# on stderr and exits 1, the harness sets isError=true, and
# `Command exited with code 1` lands in the toolResult. The class
# is distinct from the live #784 `systemctl --user status` of an
# Active: failed unit (exit 3, `× unit`, `Active: failed (Result:
# exit-code)`) and from the live #1061 silenced-tail `ls` permission
# denied shape: the #1221 shape is exit 1 with the canonical
# `Unit <name> not loaded.` lines and a non-silenced compound
# `;`-separated chain whose tail is `systemctl --user reset-failed`.
# Burying that in a thinking block plus another probe is not a
# user-facing flag. The detector already flags this class (isError +
# exit 1, command is not a grep/rg/diff/ls/which no-match). This
# file locks the live #1221 shape so a future detector refactor
# cannot regress it.
#
# Live session: 2026-08-27T15-29-03-179Z_01a043d6-c2cb-76cd-90c3-e9d8499c113d.jsonl
# The compound `systemctl --user stop 0509-devserver.service 2>&1;
# systemctl --user reset-failed 0509-devserver.service 2>&1` call
# returned 1 because the unit was not loaded, and the assistant
# continued in thinking ("The unit 0509-devserver.service doesn't
# exist anymore...") plus a `gh issue view ...` recovery toolCall
# without naming the failure in user-facing text.
#
# Scenarios:
#   1. live #1221 shape: systemctl stop + reset-failed on a not-loaded
#      unit, exit 1, thinking-only follow-up -> finding.
#   2. same shape plus a later user-facing flag -> clean.
#   3. same class, different unit name (fleet-deploy-check.service)
#      walked past -> finding. The lock is the systemd-stop-not-loaded
#      class, not one unit id.
#   4. bare `systemctl --user stop <unit>` (no chain) on a not-loaded
#      unit walked past -> finding. The single-command shape carries
#      only one `Failed to stop` line, not two.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

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
  touch -d "2026-08-27T15:30:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T16:30:00Z"
}

# --- 1. live #1221 shape: compound stop+reset-failed not-loaded walked past ----
# Replay the compound `;`-separated chain, the
# `Failed to stop ...: Unit ... not loaded.` /
# `Failed to reset failed state of unit ...: Unit ... not loaded.` /
# exit 1 toolResult, and the thinking-only follow-up that was the
# live miss.
write_session "systemctl-stop-not-loaded" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_status","name":"bash","arguments":{"command":"# Check 0509-devserver status + failed units + worktree\nsystemctl --user status 0509-devserver.service --no-pager 2>&1; echo \"---\"; systemctl --user list-units --state=failed --no-pager 2>&1; echo \"---\"; ls -la /home/nish/workspaces/products/0509-worktrees/widefix/ 2>&1 | head -10"}},{"type":"toolCall","id":"call_stop","name":"bash","arguments":{"command":"systemctl --user stop 0509-devserver.service 2>&1; systemctl --user reset-failed 0509-devserver.service 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_status","toolName":"bash","isError":false,"content":[{"type":"text","text":"Unit 0509-devserver.service could not be found.\n---\n  UNIT LOAD ACTIVE SUB DESCRIPTION\n\n0 loaded units listed.\n---\ntotal 488\ndrwxrwxr-x 24 nish nish   4096 Aug 27 20:56 .\n"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_stop","toolName":"bash","isError":true,"content":[{"type":"text","text":"Failed to stop 0509-devserver.service: Unit 0509-devserver.service not loaded.\nFailed to reset failed state of unit 0509-devserver.service: Unit 0509-devserver.service not loaded.\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The unit 0509-devserver.service doesn't exist anymore - it was either removed or the unit file was never installed persistently."},{"type":"toolCall","id":"call_recover","name":"bash","arguments":{"command":"gh issue view 1116 -R Nishfleet/fleet-ops --json title,body,state,labels,updatedAt 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_recover","toolName":"bash","isError":false,"content":[{"type":"text","text":"{\"body\":\"## Symptom\\n\\n`fleet-heartbeat.service` lands in `--state=failed`\\n"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1221 systemctl stop+reset-failed not-loaded walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q '0509-devserver.service' <<<"$snippet" \
  || fail "finding snippet should mention 0509-devserver.service (got $snippet)"
grep -q 'not loaded' <<<"$snippet" \
  || fail "finding snippet should carry the not-loaded line (got $snippet)"
grep -q 'Failed to stop' <<<"$snippet" \
  || fail "finding snippet should carry the Failed-to-stop line (got $snippet)"
grep -q 'Failed to reset failed state' <<<"$snippet" \
  || fail "finding snippet should carry the Failed-to-reset-failed-state line (got $snippet)"
ok "live #1221 systemctl stop+reset-failed not-loaded walked past is flagged"
rm -f "$sessions/systemctl-stop-not-loaded.jsonl"

# --- 2. same shape plus a later user-facing flag is clean ---------------------
write_session "systemctl-stop-not-loaded-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_stop2","name":"bash","arguments":{"command":"systemctl --user stop 0509-devserver.service 2>&1; systemctl --user reset-failed 0509-devserver.service 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_stop2","toolName":"bash","isError":true,"content":[{"type":"text","text":"Failed to stop 0509-devserver.service: Unit 0509-devserver.service not loaded.\nFailed to reset failed state of unit 0509-devserver.service: Unit 0509-devserver.service not loaded.\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the systemctl stop+reset-failed call on 0509-devserver.service exited 1 with \"Unit 0509-devserver.service not loaded.\". The devserver is already gone, so the worktree audit is the next step."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged systemctl stop+reset-failed not-loaded should be clean (got $count) $report"
ok "systemctl stop+reset-failed not-loaded plus later user-facing flag is clean"
rm -f "$sessions/systemctl-stop-not-loaded-flagged.jsonl"

# --- 3. same class, different unit name --------------------------------------
write_session "systemctl-stop-not-loaded-fleetdeploy" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_stop3","name":"bash","arguments":{"command":"systemctl --user stop fleet-deploy-check.service 2>&1; systemctl --user reset-failed fleet-deploy-check.service 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_stop3","toolName":"bash","isError":true,"content":[{"type":"text","text":"Failed to stop fleet-deploy-check.service: Unit fleet-deploy-check.service not loaded.\nFailed to reset failed state of unit fleet-deploy-check.service: Unit fleet-deploy-check.service not loaded.\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Fleet-deploy-check.service was rotated out."},{"type":"toolCall","id":"call_recover3","name":"bash","arguments":{"command":"ls /home/nish/workspaces/tooling/fleet-ops-deploy/bin/"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "systemctl stop+reset-failed on a different not-loaded unit walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'fleet-deploy-check.service' <<<"$snippet" \
  || fail "finding snippet should mention fleet-deploy-check.service (got $snippet)"
ok "systemctl stop+reset-failed on a different not-loaded unit walked past is flagged"
rm -f "$sessions/systemctl-stop-not-loaded-fleetdeploy.jsonl"

# --- 4. bare systemctl stop (no chain) on a not-loaded unit walked past -------
write_session "systemctl-stop-not-loaded-bare" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_stop4","name":"bash","arguments":{"command":"systemctl --user stop 0509-devserver.service 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_stop4","toolName":"bash","isError":true,"content":[{"type":"text","text":"Failed to stop 0509-devserver.service: Unit 0509-devserver.service not loaded.\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next check."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "bare systemctl stop on a not-loaded unit walked past should be a finding (got $count) $report"
ok "bare systemctl stop on a not-loaded unit walked past is flagged"
rm -f "$sessions/systemctl-stop-not-loaded-bare.jsonl"

# --- 5. prompts/worker.md cites fleet-ops#1221 (prompt-side lock) ----------
worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1221' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1221 (prompt-side lock)"
grep -q 'not loaded' "$worker" \
  || fail "prompts/worker.md must name the live 'not loaded' wording"
ok "worker.md cites fleet-ops#1221 and the 'not loaded' live wording"

# --- 6. lib/failed-command-flagged.py docstring cites fleet-ops#1221 ------
grep -q 'fleet-ops#1221' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1221 (detector-side lock)"
grep -q 'Failed to stop' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'Failed to stop' wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1221 and the 'Failed to stop' shape"

# --- 7. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -----
grep -Fq 'bash "$here/fleet-failed-command-systemctl-stop-not-loaded.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-systemctl-stop-not-loaded: live #1221 not-loaded + flag drill"
