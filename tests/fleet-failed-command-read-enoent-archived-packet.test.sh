#!/usr/bin/env bash
# tests/fleet-failed-command-read-enoent-archived-packet.test.sh
#
# fleet-ops#1059: a `read` of an archived Pi issue packet file
# (`/home/nish/.local/state/pi-issues/fleet-ops-938.in`) returned the live
#   "ENOENT: no such file or directory, access '<path>'"
# shape (isError=true, details={}, no "Command exited with code" line).
# The packet had been archived to
# `ARCHIVED-fleet-ops-938.in-20260827T071649Z` by the reap ladder before
# the worker's session started. The worker's recovery was
# cause-explaining prose:
#   "The file was archived. Let me read it."
# followed by a `cat` of the archived copy.
#
# That prose names the CAUSE (the file was archived) but NOT the FAILURE
# (the read returned ENOENT). Per the standing rule (fleet-ops#535), the
# flag must name the failure — "the read failed with ENOENT" — not just
# explain why the file is absent. Cause-explaining prose that moves on to
# a different path is the same swallowed-failure class as the #953
# thinking-only recovery and the #1001 "clear picture" prose: the user
# is told a story about why the file is missing, never that the command
# failed. A future detector refactor must not:
#   - treat "The file was archived" as naming the failure (it names the
#     cause, not the failure; the read still returned ENOENT and was
#     never flagged as a failure)
#   - treat a successful `cat` of the archived copy as discharging the
#     read-ENOENT of the original path (a different command succeeding
#     on a different path does not flag the original failure)
#   - let cause-explaining prose clear a pending swallowed read-ENOENT
#     (same class as #953 / #1001 unrelated-prose)
#
# The shape is the same read-ENOENT class as #953 / #1001 (live wording
# `ENOENT: no such file or directory, access '<path>'`, isError=true,
# details={}, no exit-code line). The detector already flags it; this
# drill pins the archived-packet recovery pattern so a future refactor
# that adds a "names the cause" discharge branch is caught.
#
# Live session: 2026-08-27T07-30-13-501Z_01a04220-617d-7dd0-8ec2-4f0a64c7a252.jsonl
# Live signal:  failed-command-flagged/2026-08-27t07-30-13-501z-01a04220-617d-7dd0-8ec2-4f0a64c7a252
#
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window after 2026-08-27T07:30:13Z.
#
# Scenarios:
#   1. live #1059 shape: read of archived packet -> ENOENT -> cause
#      prose "The file was archived. Let me read it." + cat of archived
#      copy -> finding.
#   2. same shape plus a later user-facing flag that names the failure
#      ("the read failed with ENOENT") -> clean.
#   3. cause prose alone (no later flag) is still a finding even when
#      the archived cat succeeds.
#   4. lib/failed-command-flagged.py cites fleet-ops#1059 (detector-side lock: case list moved to lib, fleet-ops#3246).
#   5. lib/failed-command-flagged.py docstring cites fleet-ops#1059.
#   6. seat-lib.test.sh hosts this file (CI cannot gain a new workflow line).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-read-enoent-archived.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T07:30:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T08:00:00Z"
}

# --- 1. live #1059 shape: read archived packet -> ENOENT -> cause prose -----
# The live session's user prompt was the packet path itself. The worker
# `read` it, got ENOENT (the reap ladder had archived it), then said
# "The file was archived. Let me read it." and `cat`d the archived copy.
# The cause prose names why the file is missing, not that the read
# failed. A successful cat of a different path does not discharge the
# read-ENOENT of the original. This must be a finding.
write_session "read-enoent-archived-packet" <<'JSONL'
{"type":"message","message":{"role":"user","content":[{"type":"text","text":"/home/nish/.local/state/pi-issues/fleet-ops-938.in"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me read the file to understand what the task is."},{"type":"toolCall","id":"call_read","name":"read","arguments":{"path":"/home/nish/.local/state/pi-issues/fleet-ops-938.in"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/.local/state/pi-issues/fleet-ops-938.in'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The file doesn't exist. Let me check the directory to see what's there."},{"type":"toolCall","id":"call_ls","name":"bash","arguments":{"command":"ls -la /home/nish/.local/state/pi-issues/ 2>&1 | head -50"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ls","toolName":"bash","isError":false,"content":[{"type":"text","text":"ARCHIVED-fleet-ops-938.in-20260827T071649Z"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The file has been archived. Let me look at the archived files."},{"type":"text","text":"The file was archived. Let me read it."},{"type":"toolCall","id":"call_cat","name":"bash","arguments":{"command":"cat /home/nish/.local/state/pi-issues/ARCHIVED-fleet-ops-938.in-20260827T071649Z"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cat","toolName":"bash","isError":false,"content":[{"type":"text","text":"# Pi fleet issue worker\nYou implement exactly ONE GitHub issue."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1059 read ENOENT with cause prose should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'ENOENT: no such file or directory, access' <<<"$snippet" \
  || fail "finding snippet should mention live ENOENT wording (got $snippet)"
grep -q 'fleet-ops-938.in' <<<"$snippet" \
  || fail "finding snippet should mention the archived packet path (got $snippet)"
ok "live #1059: read ENOENT of archived packet + cause prose 'The file was archived' is flagged"
rm -f "$sessions/read-enoent-archived-packet.jsonl"

# --- 2. same shape plus a later user-facing flag that names the failure -----
# Cause prose alone does not flag; a real flag names the failure itself.
# "the read failed with ENOENT — the packet was archived, recovering from
# the archived copy" names the failure AND the cause. That is a real flag.
write_session "read-enoent-archived-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read2","name":"read","arguments":{"path":"/home/nish/.local/state/pi-issues/fleet-ops-938.in"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read2","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/.local/state/pi-issues/fleet-ops-938.in'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the read of fleet-ops-938.in failed with ENOENT — the packet was archived by the reap ladder, recovering from the archived copy."},{"type":"toolCall","id":"call_cat2","name":"bash","arguments":{"command":"cat /home/nish/.local/state/pi-issues/ARCHIVED-fleet-ops-938.in-20260827T071649Z"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "read ENOENT with later user-facing flag naming the failure should be clean (got $count) $report"
ok "read ENOENT plus later user-facing flag naming the failure is clean"
rm -f "$sessions/read-enoent-archived-flagged.jsonl"

# --- 3. cause prose alone is still a finding even when cat succeeds ---------
# A future refactor might treat "The file was archived" as a discharge
# because it explains the cause. Pin that it does not: the failure (the
# read returned ENOENT) was never named as a failure, only explained.
write_session "read-enoent-cause-prose-only" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read3","name":"read","arguments":{"path":"/home/nish/.local/state/pi-issues/fleet-ops-938.in"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read3","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/.local/state/pi-issues/fleet-ops-938.in'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The file was archived. Let me read it."},{"type":"toolCall","id":"call_cat3","name":"bash","arguments":{"command":"cat /home/nish/.local/state/pi-issues/ARCHIVED-fleet-ops-938.in-20260827T071649Z"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cat3","toolName":"bash","isError":false,"content":[{"type":"text","text":"# Pi fleet issue worker"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "cause prose 'The file was archived' without naming the failure should still be a finding (got $count) $report"
ok "cause prose alone (no failure named) is still flagged even when the archived cat succeeds"
rm -f "$sessions/read-enoent-cause-prose-only.jsonl"

# --- 4. lib/failed-command-flagged.py cites fleet-ops#1059 (detector-side lock: case list moved to lib, fleet-ops#3246) -------------------
worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1059' "$lib" \
  || fail "lib/failed-command-flagged.py must cite fleet-ops#1059 (detector-side lock for the archived-packet read-ENOENT class)"
grep -q 'fleet-ops-938.in' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live #1059 archived-packet path so workers flag the shape"
ok "lib/failed-command-flagged.py cites fleet-ops#1059 and the live archived-packet path"

# --- 5. lib/failed-command-flagged.py docstring cites fleet-ops#1059 --------
# The lib docstring is the standing-rule contract for the next detector
# maintainer. The same three-place pattern as the prompt + CI host:
# prompt, lib docstring, and the test that runs in CI.
libdoc="$repo_root/lib/failed-command-flagged.py"
[[ -f "$libdoc" ]] || fail "missing $libdoc"
grep -q 'fleet-ops#958, #972, #967, #977, #1001, #1059' "$libdoc" \
  || fail "lib/failed-command-flagged.py docstring must cite #1059 at the end of the read-ENOENT citation chain"
grep -q '01a04220 archived-packet session' "$libdoc" \
  || fail "lib/failed-command-flagged.py docstring must name the 01a04220 archived-packet session next to the #1059 citation"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1059"

# --- 6. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) --------
grep -Fq 'bash "$here/fleet-failed-command-read-enoent-archived-packet.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-read-enoent-archived-packet: live #1059 read ENOENT + cause prose 'The file was archived' drill"
