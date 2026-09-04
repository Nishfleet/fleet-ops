#!/usr/bin/env bash
# tests/fleet-failed-command-detector-bin-exit.test.sh
#
# fleet-ops#1220: a `bin/fleet-failed-command-flagged` invocation
# (FILE_ISSUES=0, pointed at `/tmp`) that returns `findings=N` +
# `LOUD [FAILED-COMMAND-SWALLOWED]` + `Command exited with code 1`
# is a real swallowed failure. The detector's contract is to exit 1
# when it finds things; that does not make the non-zero a probe. The
# FAILED-COMMAND-SWALLOWED lines in the toolResult are about OTHER
# sessions, not a user-facing flag of THIS command. The next assistant
# turn is thinking-only ("the detector IS working") plus a grep, with
# no user-facing text naming the failure.
#
# The detector already flags this class via the generic
# `isError or code != 0` path. No `lib/failed-command-flagged.py` logic
# change is needed — a suppression would silence a real signal. The
# tempting future exemptions this file forbids:
#   - treating `bin/fleet-failed-command-flagged` exit 1 as expected
#     because the detector's contract is to exit 1 on findings
#   - treating FAILED-COMMAND-SWALLOWED in the toolResult as already
#     flagged (those lines name OTHER sessions)
#   - treating a thinking-only note that "the detector is working"
#     as a user-facing flag (thinking is not scanned by FLAG_RE)
#   - collapsing into "every empty exit-1 is a failure" — the live
#     session also carried an earlier grep POSIX no-match
#
# The auto-filed issue closes via observe-to-close (fleet-ops#650)
# when the session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T15-16-17-039Z_01a043cb-120f-7fe1-952d-b01474cd5852.jsonl
# The minimax worker on fleet-ops#1054 ran:
#   cd .../issue-fleet-ops-1054 &&
#   FLEET_FAILED_COMMAND_SESSIONS=/tmp
#   FLEET_FAILED_COMMAND_LIB=lib/failed-command-flagged.py
#   FLEET_FAILED_COMMAND_WINDOW_HOURS=24
#   FLEET_FAILED_COMMAND_GRACE_MINUTES=0
#   FLEET_FAILED_COMMAND_NOW="2026-08-27T07:30:00Z"
#   FLEET_FAILED_COMMAND_FILE_ISSUES=0
#   bin/fleet-failed-command-flagged 2>&1
# The bin scanned leftover /tmp fixtures (scanned=25 old=829
# grace=20 findings=11), printed LOUD [FAILED-COMMAND-SWALLOWED]
# for each, then `FAILED-COMMAND-FAIL swallowed failures=11` and
# `Command exited with code 1` (isError=true, details={}). The next
# turn was thinking ("The detector scanned many existing sessions
# in /tmp and found 11 swallowed failures ... The detector IS
# working.") plus `grep -n "origin #650" ...`. Detector snippet:
# `[fleet-failed-command-flagged] scanned=25 old=829 grace=20
# findings=11 ... LOUD [FAILED-COMMAND-SWALLOWED]`.
#
# Distinct from:
#   - #727: `npm run canary:bet2` exit 1 on a failed gate — different
#     command (a node canary, not the detector bin itself)
#   - #793: `bash /tmp/<fresh-script>` exit 1 with `(no output)`
#   - grep/rg POSIX no-match (BENIGN_STAGE_RE) — the live session also
#     carried an earlier `grep "fleet-heartbeat.service.d"` exit 1
#     with `(no output)`; that is a probe and must stay clean
#
# Scenarios:
#   1. live #1220 shape: detector bin exit 1 + thinking-only grep
#      recovery -> finding. Snippet must carry `findings=11` and
#      `FAILED-COMMAND-SWALLOWED`.
#   2. same shape plus a later thinking-only note -> still a finding.
#   3. same shape plus later unrelated user-facing prose that does NOT
#      name the failure -> still a finding.
#   4. same shape plus a later user-facing flag -> clean.
#   5. cross-check: a later `grep "fleet-heartbeat.service.d"` exit 1
#      with `(no output)` stays a probe (not a finding). Pins that
#      locking #1220 must not collapse into "every empty exit-1 is
#      a failure".
#   6. worker.md cites fleet-ops#1220 and the live
#      `FLEET_FAILED_COMMAND_SESSIONS=/tmp` wording (prompt-side lock).
#   7. lib/failed-command-flagged.py docstring cites fleet-ops#1220
#      (detector-side lock).
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

scratch="$(mktemp -d -t failed-command-detector-bin-exit.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T15:43:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T17:00:00Z"
}

LIVE_CMD='cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1054 && FLEET_FAILED_COMMAND_SESSIONS=/tmp FLEET_FAILED_COMMAND_LIB=lib/failed-command-flagged.py FLEET_FAILED_COMMAND_WINDOW_HOURS=24 FLEET_FAILED_COMMAND_GRACE_MINUTES=0 FLEET_FAILED_COMMAND_NOW="2026-08-27T07:30:00Z" FLEET_FAILED_COMMAND_FILE_ISSUES=0 bin/fleet-failed-command-flagged 2>&1'

LIVE_OUT='[2026-08-27T15:43:19Z] [fleet-failed-command-flagged] scanned=25 old=829 grace=20 findings=11
[2026-08-27T15:43:19Z] [fleet-failed-command-flagged] LOUD [FAILED-COMMAND-SWALLOWED] session=session path=/tmp/664-test/session.jsonl snippet=ENOENT: no such file or directory, access '"'"'/home/nish/workspaces/products/fleet-ops/tests/fleet-heartbeat-verify-timers.test.sh'"'"'
[2026-08-27T15:43:19Z] [fleet-failed-command-flagged] LOUD [FAILED-COMMAND-FAIL] swallowed failures=11 — a failed command was walked past; heartbeat tick will fail

Command exited with code 1'

# --- 1. live #1220 shape: detector bin exit 1 walked past ------------------
# Replay the exact invocation from slug 01a043cb: FILE_ISSUES=0 pointed
# at /tmp, 11 leftover-fixture findings, next turn is thinking plus
# grep with no user-facing text.
write_session "detector-bin-walked" <<JSONL
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Now let me run the detector on this test session."},{"type":"toolCall","id":"call_det","name":"bash","arguments":{"command":$(jq -cn --arg c "$LIVE_CMD" '$c')}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_det","toolName":"bash","content":[{"type":"text","text":$(jq -cn --arg t "$LIVE_OUT" '$t')}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The detector scanned many existing sessions in /tmp and found 11 swallowed failures (not including my test session because it was written after the scan started). The detector IS working. Now let me add a test."},{"type":"toolCall","id":"call_grep","name":"bash","arguments":{"command":"grep -n \"origin #650\" /home/nish/workspaces/tooling/fleet-ops-deploy-clone/tests/fleet-failed-command-flagged.test.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_grep","toolName":"bash","isError":false,"content":[{"type":"text","text":"966:# --- 7b. origin #650: cp /tmp/install.sh cannot-stat walked past -------------\n"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1220 detector-bin exit 1 walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'findings=11' <<<"$snippet" \
  || fail "finding snippet should mention findings=11 (got $snippet)"
grep -q 'FAILED-COMMAND-SWALLOWED' <<<"$snippet" \
  || fail "finding snippet should mention FAILED-COMMAND-SWALLOWED (got $snippet)"
ok "live #1220: detector bin exit 1 with thinking-only grep recovery is flagged"
rm -f "$sessions/detector-bin-walked.jsonl"

# --- 2. thinking-only recovery is still a finding --------------------------
write_session "detector-bin-thinking" <<JSONL
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_det2","name":"bash","arguments":{"command":$(jq -cn --arg c "$LIVE_CMD" '$c')}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_det2","toolName":"bash","content":[{"type":"text","text":$(jq -cn --arg t "$LIVE_OUT" '$t')}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The detector scanned leftover /tmp fixtures and found 11 swallowed failures. The detector IS working."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "detector-bin exit 1 with thinking-only recovery should be a finding (got $count) $report"
ok "live #1220: detector bin exit 1 with later thinking-only recovery is still flagged"
rm -f "$sessions/detector-bin-thinking.jsonl"

# --- 3. later unrelated user-facing prose does not discharge ---------------
# Deliberately avoid FLAG_RE words (failed/failure/error/...). Cause
# explaining ("the scan of /tmp leftover fixtures finished") names
# the CAUSE, not the FAILURE, same class as #1059 "The file was archived".
write_session "detector-bin-prose" <<JSONL
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_det3","name":"bash","arguments":{"command":$(jq -cn --arg c "$LIVE_CMD" '$c')}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_det3","toolName":"bash","content":[{"type":"text","text":$(jq -cn --arg t "$LIVE_OUT" '$t')}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The scan of /tmp leftover fixtures finished. Adding the cat ENOENT test next."},{"type":"toolCall","id":"call_grep3","name":"bash","arguments":{"command":"grep -n \"origin #650\" /home/nish/workspaces/tooling/fleet-ops-deploy-clone/tests/fleet-failed-command-flagged.test.sh"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "detector-bin exit 1 followed by unrelated prose should be a finding (got $count) $report"
ok "live #1220: detector bin exit 1 with unrelated user-facing prose is still flagged"
rm -f "$sessions/detector-bin-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean ------------------
write_session "detector-bin-flagged" <<JSONL
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_det4","name":"bash","arguments":{"command":$(jq -cn --arg c "$LIVE_CMD" '$c')}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_det4","toolName":"bash","content":[{"type":"text","text":$(jq -cn --arg t "$LIVE_OUT" '$t')}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the fleet-failed-command-flagged call failed with exit 1 (11 findings from leftover /tmp fixtures). continuing."},{"type":"toolCall","id":"call_grep4","name":"bash","arguments":{"command":"grep -n \"origin #650\" /home/nish/workspaces/tooling/fleet-ops-deploy-clone/tests/fleet-failed-command-flagged.test.sh"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "detector-bin exit 1 with later user-facing flag should be clean (got $count) $report"
ok "detector bin exit 1 plus later user-facing flag is clean"
rm -f "$sessions/detector-bin-flagged.jsonl"

# --- 5. cross-check: grep POSIX no-match with the same empty snippet stays a probe
# The live #1220 session also carried an earlier
#   grep "fleet-heartbeat.service.d" .../MANIFEST
# that exited 1 with `(no output)`. That is BENIGN_STAGE_RE. Locking the
# detector-bin shape must not collapse into "every empty exit-1 is a failure".
write_session "grep-no-match-empty-snippet" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The directory systemd/fleet-heartbeat.service.d/ does not exist. Let me check the MANIFEST entry."},{"type":"toolCall","id":"call_grep5","name":"bash","arguments":{"command":"grep \"fleet-heartbeat.service.d\" /home/nish/workspaces/tooling/fleet-ops-deploy-clone/MANIFEST"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_grep5","toolName":"bash","content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The MANIFEST does not have that entry. Let me cat | grep -i fleet-heartbeat."},{"type":"toolCall","id":"call_next","name":"bash","arguments":{"command":"cat /home/nish/workspaces/tooling/fleet-ops-deploy-clone/MANIFEST | grep -i fleet-heartbeat"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "grep POSIX no-match with (no output) exit 1 must stay a probe (got $count) $report"
ok "grep POSIX no-match with the same empty snippet stays a probe (contrast with #1220)"
rm -f "$sessions/grep-no-match-empty-snippet.jsonl"

# --- 6. prompts/worker.md cites fleet-ops#1220 (prompt-side lock) -----------
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1220' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1220 (prompt-side lock)"
grep -q 'FLEET_FAILED_COMMAND_SESSIONS=/tmp' "$worker" \
  || fail "prompts/worker.md must name the live 'FLEET_FAILED_COMMAND_SESSIONS=/tmp' wording"
ok "worker.md cites fleet-ops#1220 and the live detector-bin wording"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#1220 -------
grep -q 'fleet-ops#1220' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1220 (detector-side lock)"
grep -q 'FLEET_FAILED_COMMAND_SESSIONS=/tmp' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'FLEET_FAILED_COMMAND_SESSIONS=/tmp' wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1220 and the detector-bin shape"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-detector-bin-exit.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-detector-bin-exit: live #1220 detector-bin exit-1 drills"
