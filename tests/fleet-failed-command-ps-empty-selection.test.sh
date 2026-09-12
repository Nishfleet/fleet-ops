#!/usr/bin/env bash
# tests/fleet-failed-command-ps-empty-selection.test.sh
#
# fleet-ops#5042: a `ps` exit-1 toolResult on an EMPTY SELECTION is a
# negative result, not a swallowed failure.
#
# procps-ng ps exits 1 in exactly two shapes:
#   1. empty selection (`ps --ppid <childless-pid>`, `ps -p <dead-pid>`,
#      `ps -C <missing-name>`): the output is the bare header row (or
#      nothing under --no-headers) with NO error text. The agent asked
#      "does this process have children / is this pid alive" and the
#      empty list IS the answer — the same no-match class as grep/rg/
#      which exit 1.
#   2. invocation failure (bad option, bad -o keyword, bad PID/user
#      list syntax): stderr always carries `error: <reason>` plus a
#      `Usage:` dump. That stays a real swallowed failure.
#
# The live session (2026-09-10T01-26-51-403Z_01a088ec-...) ran a
# process-monitor chain ending in `ps --ppid 1822243 -o
# pid,etime,pcpu,args` on a childless tsc build. ps printed the bare
# `PID ELAPSED %CPU COMMAND` header and exited 1; Pi set isError=true
# and the assistant correctly read the empty list as "no children"
# without flagging a failure — there was none. A stale detector
# classified the chain exit 1 as a swallowed failure and filed
# fleet-ops#5042.
#
# The detector must NOT flag the empty-selection shape, and must still
# flag real ps invocation failures. A future refactor must not:
#   - drop the PS_REAL_ERR_RE guard so `ps --bad-option` exit 1 (which
#     prints `error:` + `Usage:`) is silently exempted
#   - require a specific header layout (the -o columns make the header
#     arbitrary; --no-headers prints nothing at all)
#
# Scenarios:
#   1. live #5042 shape: monitor chain ending in `ps --ppid` on a
#      childless pid -> exit 1, header only, no flag -> clean.
#   2. `ps -p <pid> && echo alive` probe: exit 1, no error text -> clean.
#   3. `ps --no-headers -p <dead-pid>`: exit 1, empty output -> clean.
#   4. `ps --definitely-not-a-flag`: exit 1 + `error:`/`Usage:` -> finding.
#   5. `ps -u <nonexistent>`: exit 1 + `error: user name does not exist`
#      -> finding.
#   6. `ps --ppid <pid>` bad-pid syntax: exit 1 + `error: process ID list
#      syntax error` -> finding.
#   7. lib/failed-command-flagged.py cites fleet-ops#5042, the live
#      01a088ec session slug, and the live monitor-chain wording
#      (detector-side lock: case list moved to lib, fleet-ops#3246).
#   8. seat.lib.test.sh hosts this file (CI cannot gain a P14 line).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-ps-empty.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-09-10T07:00:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-09-10T20:00:00Z"
}

# --- 1. live #5042 shape: monitor chain ending in `ps --ppid` ----------
# The live session (2026-09-10T01-26-51-403Z_01a088ec-...) ran a
# childless-process check on tsc build pid 1822243; ps printed the bare
# header and exited 1, and the assistant's next turn correctly described
# the process state ("progressing ... D state") without naming a failure
# — there was none. Replay that exact shape; the scan must be clean.
write_session "ps-ppid-empty-monitor-chain" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ps1","name":"bash","arguments":{"command":"echo \"=== tsc 1822243 (38min) - progressing? ===\"; cat /proc/1822243/stat 2>/dev/null | awk '{print \"state:\", $3, \"utime+stime:\", $14+$15}'; sleep 3; cat /proc/1822243/stat 2>/dev/null | awk '{print \"after 3s:\", $14+$15}'; echo \"=== children ===\"; ps --ppid 1822243 -o pid,etime,pcpu,args 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ps1","toolName":"bash","content":[{"type":"text","text":"=== tsc 1822243 (38min) - progressing? ===\nstate: D utime+stime: 17094\nafter 3s: 17156\n=== children ===\n    PID     ELAPSED %CPU COMMAND\n\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The tsc build (1822243) is progressing (17094 → 17156 jiffies in 3s, ~2% CPU) but it's in D state. It's a legitimate build that's slowly progressing. It has no children."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "live #5042 ps --ppid empty selection should be clean (got $count) $report"
ok "live #5042: ps --ppid on a childless pid (bare header, exit 1) is clean"
rm -f "$sessions/ps-ppid-empty-monitor-chain.jsonl"

# --- 2. `ps -p <pid> && echo` short-circuit probe ----------------------
# The canonical "is this pid alive" probe: ps exits 1 on the empty
# selection, && short-circuits the echo, and the toolResult text carries
# only the bare header. No error markers -> negative result -> clean.
write_session "ps-p-and-echo-alive" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ps2","name":"bash","arguments":{"command":"ps -p 424242 -o pid,comm && echo alive"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ps2","toolName":"bash","content":[{"type":"text","text":"    PID COMMAND\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The pid is gone — the process already exited."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "ps -p dead-pid && echo short-circuit probe should be clean (got $count) $report"
ok "ps -p <dead-pid> && echo short-circuit probe is clean"
rm -f "$sessions/ps-p-and-echo-alive.jsonl"

# --- 3. `ps --no-headers` empty output probe ----------------------------
write_session "ps-no-headers-empty" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ps3","name":"bash","arguments":{"command":"ps --no-headers -C definitely-not-running-xyz -o pid,comm"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ps3","toolName":"bash","content":[{"type":"text","text":"\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"No such process is running."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "ps --no-headers -C empty selection should be clean (got $count) $report"
ok "ps --no-headers -C <missing-name> empty output is clean"
rm -f "$sessions/ps-no-headers-empty.jsonl"

# --- 4. `ps --definitely-not-a-flag` invocation failure -----------------
# procps-ng exits 1 AND prints `error: unknown gnu long option` plus a
# Usage dump. That is a real swallowed failure, not an empty selection.
write_session "ps-bad-flag" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ps4","name":"bash","arguments":{"command":"ps --definitely-not-a-flag"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ps4","toolName":"bash","content":[{"type":"text","text":"error: unknown gnu long option\n\nUsage:\n ps [options]\n\n Try 'ps --help <simple|list|output|threads|misc|all>'\n  or 'ps --help <s|l|o|t|m|a>'\n for additional help text.\n\nFor more details see ps(1).\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Let me check the process list a different way."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "ps bad-option invocation failure should be a finding (got $count) $report"
ok "ps --bad-flag (error: + Usage:) stays a finding"
rm -f "$sessions/ps-bad-flag.jsonl"

# --- 5. `ps -u <nonexistent>` user-list failure -------------------------
write_session "ps-bad-user" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ps5","name":"bash","arguments":{"command":"ps -u definitelynouserxyz -o pid,comm"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ps5","toolName":"bash","content":[{"type":"text","text":"error: user name does not exist\n\nUsage:\n ps [options]\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Let me try listing the users first."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "ps -u bad-user invocation failure should be a finding (got $count) $report"
ok "ps -u <nonexistent> (error: user name does not exist) stays a finding"
rm -f "$sessions/ps-bad-user.jsonl"

# --- 6. `ps --ppid notanumber` pid-list syntax failure -------------------
write_session "ps-bad-ppid" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ps6","name":"bash","arguments":{"command":"ps --ppid notanumber -o pid,comm"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ps6","toolName":"bash","content":[{"type":"text","text":"error: process ID list syntax error\n\nUsage:\n ps [options]\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The pid variable was empty; let me fix the quoting."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "ps --ppid bad-pid syntax failure should be a finding (got $count) $report"
ok "ps --ppid <bad-pid> (error: process ID list syntax error) stays a finding"
rm -f "$sessions/ps-bad-ppid.jsonl"

# --- 7. lib cites fleet-ops#5042 + the live session/wording -------------
grep -q 'fleet-ops#5042' "$lib" \
  || fail "lib/failed-command-flagged.py must cite fleet-ops#5042 (detector-side lock for the live ps empty-selection shape)"
grep -q '01a088ec' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live 01a088ec session slug so workers flag the shape"
grep -q 'ps --ppid 1822243' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live #5042 monitor-chain wording so workers flag the shape"
ok "lib/failed-command-flagged.py cites fleet-ops#5042, the 01a088ec session, and the live wording"

# --- 8. seat.lib.test.sh hosts this file (CI cannot gain a P14 line) ----
grep -Fq 'bash "$here/fleet-failed-command-ps-empty-selection.test.sh"' \
  "$here/seat.lib.test.sh" \
  || fail "seat.lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat.lib.test.sh hosts this file"

echo "OK: fleet-failed-command-ps-empty-selection: live #5042 ps empty-selection probe + invocation-failure drills"
