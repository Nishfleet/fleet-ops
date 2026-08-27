#!/usr/bin/env bash
# tests/fleet-failed-command-read-eisdir.test.sh
#
# fleet-ops#1170: a `read` tool result with
#   "EISDIR: illegal operation on a directory, read"
# (isError=true, details={}, no "Command exited with code" line) is a real
# swallowed failure. The `read` tool was pointed at a directory path
# instead of a file, and Pi's harness returns EISDIR without an exit
# code — distinct from the #651 "Offset N is beyond end of file"
# negative result (which is exempted via READ_OFFSET_RE) and the #953
# "ENOENT: no such file or directory, access '<path>'" class.
#
# The live sessions (2026-08-27T12-31-47-156Z_01a04334-... = #1170
# and 2026-08-27T15-54-44-133Z_01a043ee-... = #1243) both exhibit
# the same shape:
#   1. assistant calls `read` on a directory path
#   2. the read toolResult returns isError=true with
#      "EISDIR: illegal operation on a directory, read" and no exit code
#   3. the assistant never names the failure — thinking blocks and
#      recovery toolCalls carry on without a user-facing flag
#
# fleet-ops#1243 is a sibling on a DIFFERENT session slug (the
# 01a043ee EISDIR session): the worker `read`
# `/home/nish/workspaces/0509-work/e2e/fixtures` and walked past
# with later unrelated prose "Now let me also look at the
# printStackTrace threshold setting you mentioned:". Same class as
# #1170; different slug, so the citation chain must carry it.
#
# The detector must flag this. A future refactor must not:
#   - add a "directory read is just a negative result" exemption that
#     silently suppresses the EISDIR class
#   - let `_text_chunks` collecting `thinking` fields discharge the class
#   - let any later user-facing text that does not name the failure clear
#     the pending swallowed failure
#
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window.
#
# Scenarios:
#   1. live #1170 shape: read on a directory -> EISDIR + thinking-only
#      recovery -> finding.
#   2. same shape plus a thinking-only recovery toolCall -> still a
#      finding (thinking is not a user-facing flag).
#   3. same shape plus a later user-facing flag ("the read call failed
#      with EISDIR, it is now the blocker") -> clean.
#   4. live #1243: read on e2e/fixtures directory -> EISDIR +
#      unrelated prose -> still a finding.
#   5. worker.md cites fleet-ops#1170 and fleet-ops#1243
#      (prompt-side lock).
#   6. lib/failed-command-flagged.py docstring cites #1170 and
#      #1243 (lib contract for the next detector maintainer).
#   7. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-read-eisdir.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T12:31:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T12:45:00Z"
}

# --- 1. live #1170 shape: read on a directory -> EISDIR + thinking-only -----
# The live session (2026-08-27T12-31-47-156Z_01a04334-...) issued a
# `read` of `/home/nish/.pi/agent/sessions/--home-nish--` (a directory).
# The toolResult returned isError=true with
#   "EISDIR: illegal operation on a directory, read"
# and no "Command exited with code" line. The next assistant turn was a
# thinking block plus recovery toolCalls and no user-facing text naming
# the failure. Replay that exact shape.
write_session "read-eisdir-thinking-only" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me look at what sessions are recent and check the remaining items from the catch-all sweep."},{"type":"toolCall","id":"call_read","name":"read","arguments":{"path":"/home/nish/.pi/agent/sessions/--home-nish--"}},{"type":"toolCall","id":"call_bash1","name":"bash","arguments":{"command":"ls -lt /home/nish/.pi/agent/sessions/--home-nish-- | head -20"}},{"type":"toolCall","id":"call_bash2","name":"bash","arguments":{"command":"systemctl --user --state=failed --no-pager 2>/dev/null; echo \"---SYSTEM---\"; systemctl --state=failed --no-pager 2>/dev/null | head -20"}},{"type":"toolCall","id":"call_bash3","name":"bash","arguments":{"command":"hermes cron list 2>/dev/null; echo \"---HERMES HISTORY---\"; ls -t /home/nish/.local/state/hermes/cron/jobs/ 2>/dev/null | head -10"}},{"type":"toolCall","id":"call_bash4","name":"bash","arguments":{"command":"gh search issues \"AUTO-REVERT HALT\" --owner Nishfleet --state open 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read","toolName":"read","content":[{"type":"text","text":"EISDIR: illegal operation on a directory, read"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash1","toolName":"bash","isError":false,"content":[{"type":"text","text":"total 443708\n-rw-rw-r-- 1 nish nish 173771 Aug 27 18:04 2026-08-27T12-31-47-156Z_01a04334-77d4-7518-986f-6e007757ccab.jsonl"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash2","toolName":"bash","isError":false,"content":[{"type":"text","text":"  UNIT LOAD ACTIVE SUB DESCRIPTION\n\n0 loaded units listed."}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash3","toolName":"bash","isError":false,"content":[{"type":"text","text":"No scheduled jobs.\nCreate one with 'hermes cron create ...' or the /cron command in chat.\n---HERMES HISTORY---"}]}}
{"type":"message","message","role":"toolResult","toolCallId":"call_bash4","toolName":"bash","isError":false,"content":[{"type":"text","text":"Nishfleet/fleet-ops\t1116\topen\tfix(heartbeat-tier1): decouple detector-alarm rc from unit-failure exit (heartbeat trip-loop)\tagent-ready\t2026-08-27T12:09:19Z"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"OK, let me analyze:\n\n1. STOP-REASON.json: reason is boundary:money\n2. System failed units: 0 in both user and system scope - clean\n3. Hermes cron: No scheduled jobs, empty list - clean\n4. AUTO-REVERT HALT: 1 open issue (fleet-ops #1116)\n\nLet me read the most recent session to understand what the boundary:money trip was about."},{"type":"toolCall","id":"call_bash5","name":"bash","arguments":{"command":"head -5 /home/nish/.pi/agent/sessions/--home-nish--/2026-08-27T12-31-47-156Z_01a04334-77d4-7518-986f-6e007757ccab.jsonl 2>/dev/null; echo \"---TAIL---\"; tail -20 /home/nish/.pi/agent/sessions/--home-nish--/2026-08-27T12-31-47-156Z_01a04334-77d4-7518-986f-6e007757ccab.jsonl 2>/dev/null"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1170 read EISDIR with thinking-only recovery should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'EISDIR: illegal operation on a directory, read' <<<"$snippet" \
  || fail "finding snippet should mention live EISDIR wording (got $snippet)"
ok "live #1170: read EISDIR with thinking-only recovery is flagged"
rm -f "$sessions/read-eisdir-thinking-only.jsonl"

# --- 2. thinking-only recovery toolCalls do not discharge the failure ------
# The live #1243 session (2026-08-27T15-54-44-133Z_01a043ee-...)
# issued a `read` of `/home/nish/workspaces/0509-work/e2e/fixtures`
# (a directory) which returned EISDIR. The next assistant turn was:
#   "Now let me also look at the printStackTrace threshold setting..."
# followed by toolCalls — none named the EISDIR failure. A thinking-only
# recovery (toolCalls without user-facing text) is the same swallowed class
# as the #953 / #958 sibling shape. #1243 is the same EISDIR class as
# #1170 on a DIFFERENT session slug.
write_session "read-eisdir-thinking-recovery" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read2","name":"read","arguments":{"path":"/home/nish/workspaces/0509-work/e2e/fixtures"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read2","toolName":"read","content":[{"type":"text","text":"EISDIR: illegal operation on a directory, read"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now let me also look at the printStackTrace threshold setting you mentioned:"},{"type":"toolCall","id":"call_bash","name":"bash","arguments":{"command":"grep -n printStackTrace /home/nish/workspaces/0509-work/e2e/local-authenticated.spec.ts"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "read EISDIR followed by thinking-recovery text should be a finding (got $count) $report"
ok "read EISDIR with a thinking-only recovery turn is still flagged"
rm -f "$sessions/read-eisdir-thinking-recovery.jsonl"

# --- 3. later explicit user-facing flag keeps the result clean -------------
write_session "read-eisdir-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read3","name":"read","arguments":{"path":"/home/nish/workspaces/0509-work/e2e/fixtures"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read3","toolName":"read","content":[{"type":"text","text":"EISDIR: illegal operation on a directory, read"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the read call failed with EISDIR (illegal operation on a directory), it is now the blocker."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "read EISDIR with later user-facing flag should be clean (got $count) $report"
ok "read EISDIR plus later user-facing flag is clean"
rm -f "$sessions/read-eisdir-flagged.jsonl"

# --- 4. live #1243: read on a directory + later unrelated prose ----------
# The live #1243 session (2026-08-27T15-54-44-133Z_01a043ee-...)
# read `/home/nish/workspaces/0509-work/e2e/fixtures` and got EISDIR. The
# assistant's next turn was thinking + toolCalls with no name of the
# failure, then later user-facing prose ("Now I have full context.") that
# does NOT name the EISDIR. This must still be a finding: the prose moves
# on without naming the failure, exactly the #953 / #958 sibling class.
write_session "read-eisdir-unrelated-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read4","name":"read","arguments":{"path":"/home/nish/workspaces/0509-work/e2e/fixtures"}},{"type":"toolCall","id":"call_bash2","name":"bash","arguments":{"command":"ls /home/nish/workspaces/0509-work/e2e/"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read4","toolName":"read","content":[{"type":"text","text":"EISDIR: illegal operation on a directory, read"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash2","toolName":"bash","isError":false,"content":[{"type":"text","text":"local-authenticated.spec.ts\nplaywright.config.ts\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Got the e2e dir listing. Let me read the spec."},{"type":"toolCall","id":"call_read5","name":"read","arguments":{"path":"/home/nish/workspaces/0509-work/e2e/local-authenticated.spec.ts"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read5","toolName":"read","isError":false,"content":[{"type":"text","text":"// test file content"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now I have full context. Let me plan and execute."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "read EISDIR followed by unrelated prose should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'EISDIR: illegal operation on a directory, read' <<<"$snippet" \
  || fail "finding snippet should mention live EISDIR wording (got $snippet)"
ok "read EISDIR with later unrelated prose is still flagged"
rm -f "$sessions/read-eisdir-unrelated-prose.jsonl"

# --- 5. worker.md cites fleet-ops#1170 and fleet-ops#1243 ------------------
worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1170' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1170 (prompt-side lock for the live EISDIR wording)"
grep -q 'fleet-ops#1243' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1243 (prompt-side lock for the 01a043ee EISDIR sibling)"
grep -q "EISDIR: illegal operation on a directory, read" "$worker" \
  || fail "prompts/worker.md must name the live EISDIR wording so workers flag it"
grep -q '0509-work/e2e/fixtures' "$worker" \
  || fail "prompts/worker.md must name the live #1243 directory path so workers flag the shape"
grep -q 'printStackTrace threshold' "$worker" \
  || fail "prompts/worker.md must name the live #1243 printStackTrace prose so workers flag the shape"
ok "worker.md cites fleet-ops#1170, fleet-ops#1243, and the live EISDIR wording"

# --- 6. lib/failed-command-flagged.py docstring cites #1170 and #1243 ------
# The lib docstring is the standing-rule contract for the next detector
# maintainer. The read-tool failure class citation chain must carry #1170
# and #1243 so a future refactor that adds a "directory read is benign"
# exemption is caught by this test. Dropping the #1243 citation is a
# regression even if the #1170 drill still passes: #1243 is a sibling
# on a DIFFERENT session slug (01a043ee).
grep -q 'fleet-ops#1170' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1170 next to the read-tool failure class"
grep -q '#1170, #1243' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite #1243 next to #1170"
grep -q '01a043ee' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the 01a043ee EISDIR session next to the #1243 citation"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1170 and #1243"

# --- 7. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-read-eisdir.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-read-eisdir: live #1170 / #1243 read EISDIR + thinking-only recovery + unrelated prose drills"
