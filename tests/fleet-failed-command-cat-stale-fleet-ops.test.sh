#!/usr/bin/env bash
# tests/fleet-failed-command-cat-stale-fleet-ops.test.sh
#
# fleet-ops#1097 / #1099: a bare `cat` of
#   /home/nish/workspaces/tooling/fleet-ops/bin/fleet-failed-command-flagged
# returned the live
#   cat: <path>: No such file or directory
#   Command exited with code 1
# shape (isError=true). At the time of the live sessions the
# `tooling/fleet-ops` checkout did not carry that bin (the canonical
# path is `tooling/fleet-ops-deploy-clone/bin/...`). The worker's next
# turn was thinking-only ("Let me find the correct path") plus a
# silent `find ...` recovery toolCall — no user-facing text named the
# failure.
#
# `cat` ENOENT is a REAL failure, not a benign no-match probe like
# `ls` exit 2 (live #794) or `git log <bad-ref>` exit 128 (live #822):
# there is no canonical-probe exemption for `cat`, and a later
# successful `find` / `cat` of the deploy-clone copy does NOT
# discharge the original failure. Thinking-only cause that names the
# path hunt is the same swallowed-failure class as the #953
# thinking-only recovery and the #1001 "clear picture" prose.
#
# Distinct from:
#   - #945: chained `ls | wc; echo ---; cat <missing-drop-in>` where a
#     successful prefix printed "1820" and the failing cat tail was
#     walked past with "PASS" prose (locked in
#     tests/fleet-failed-command-flagged.test.sh). #1097 is a bare
#     `cat` of the stale fleet-ops bin path, not a chain, and the
#     recovery is thinking-only + find, not "PASS" prose.
#   - #1001 / #1255: `read` tool ENOENT of a stale checkout
#     (fleet-ops-sync / fleet-ops-rg). Same stale-checkout family,
#     different tool (`read` vs `bash cat`) and different live path.
#   - #650: `cp /tmp/install.sh` cannot-stat walked past.
#
# The detector already flags this class via the generic isError /
# exit-1 path. This drill pins the live stale-fleet-ops `cat` recovery
# pattern so a future refactor that:
#   - treats `cat: ... No such file or directory` as an ls-style probe
#   - treats a later successful find/cat of the deploy-clone as
#     discharging the original cat failure
#   - treats thinking-only "let me find the correct path" as a flag
# is caught.
#
# Live session (#1097): 2026-08-27T10-16-56-750Z_01a042b9-04ad-72b0-8983-14a0d37b37aa.jsonl
# Live signal: failed-command-flagged/2026-08-27t10-16-56-750z-01a042b9-04ad-72b0-8983-14a0d37b37aa
# Sibling session (#1099, same class, DIFFERENT slug):
#   2026-08-27T10-38-06-022Z_01a042cc-62c6-7ab5-96bf-eb294f0654d5.jsonl
#
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window. Use `Relates to #<N>`,
# not `Closes #<N>`, for the worker PR (fleet-ops#535 observe-to-close).
#
# Scenarios:
#   1. live #1097 shape: bare cat of tooling/fleet-ops/bin/... ->
#      cat ENOENT + exit 1 -> thinking-only + find recovery -> finding.
#   2. same shape plus later successful cat of the deploy-clone copy
#      without naming the failure -> still a finding.
#   3. same shape plus a later user-facing flag that names the failure
#      -> clean.
#   4. lib/failed-command-flagged.py cites fleet-ops#1097 (detector-side lock: case list moved to lib, fleet-ops#3246).
#   5. lib/failed-command-flagged.py docstring cites fleet-ops#1097.
#   6. seat-lib.test.sh hosts this file (CI cannot gain a new workflow
#      line — the worker token has no Workflows permission).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"
worker="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-cat-stale-fleet-ops.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T10:16:56Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T11:00:00Z"
}

STALE_PATH="/home/nish/workspaces/tooling/fleet-ops/bin/fleet-failed-command-flagged"
CANON_PATH="/home/nish/workspaces/tooling/fleet-ops-deploy-clone/bin/fleet-failed-command-flagged"

# --- 1. live #1097 shape: bare cat of stale tooling/fleet-ops bin -------
# Replay the exact live shape from session 01a042b9: bare `cat` of the
# stale path, isError=true, `cat: ... No such file or directory` +
# `Command exited with code 1`, next turn thinking-only + `find`
# recovery with no user-facing text.
write_session "cat-stale-fleet-ops-walked-past" <<JSONL
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me understand the detector and what fix is needed."},{"type":"toolCall","id":"call_cat","name":"bash","arguments":{"command":"cat ${STALE_PATH}"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cat","toolName":"bash","isError":true,"content":[{"type":"text","text":"cat: ${STALE_PATH}: No such file or directory\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me find the correct path for the fleet-ops repo and the detector script."},{"type":"toolCall","id":"call_find","name":"bash","arguments":{"command":"find /home/nish -name \"fleet-failed-command-flagged\" 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_find","toolName":"bash","isError":false,"content":[{"type":"text","text":"${CANON_PATH}\n/home/nish/workspaces/_claude-worktrees/fleet-ops-gate-attest-fix/bin/fleet-failed-command-flagged"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1097 bare cat of stale tooling/fleet-ops walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'cat: .*: No such file or directory' <<<"$snippet" \
  || fail "finding snippet should mention live cat ENOENT wording (got $snippet)"
grep -q 'tooling/fleet-ops/bin/fleet-failed-command-flagged' <<<"$snippet" \
  || fail "finding snippet should mention the live stale path (got $snippet)"
grep -q 'Command exited with code 1' <<<"$snippet" \
  || fail "finding snippet should mention Command exited with code 1 (got $snippet)"
ok "live #1097: bare cat of stale tooling/fleet-ops + thinking-only find recovery is flagged"
rm -f "$sessions/cat-stale-fleet-ops-walked-past.jsonl"

# --- 2. later successful cat of the deploy-clone does NOT discharge -----
# Same failure, then a successful `cat` of the canonical path, then
# "Now I understand" prose that does NOT name the failure. A future
# refactor that treats a later successful read of the right file as
# discharging a separate earlier cat-ENOENT must fail this drill.
write_session "cat-stale-then-canon-success" <<JSONL
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cat2","name":"bash","arguments":{"command":"cat ${STALE_PATH}"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cat2","toolName":"bash","isError":true,"content":[{"type":"text","text":"cat: ${STALE_PATH}: No such file or directory\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Wrong checkout. Trying the deploy-clone."},{"type":"toolCall","id":"call_canon","name":"bash","arguments":{"command":"cat ${CANON_PATH} | head -5"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_canon","toolName":"bash","isError":false,"content":[{"type":"text","text":"#!/usr/bin/env bash\n# fleet-failed-command-flagged — session-close lint (fleet-ops#535).\n#\n# Standing rule: a failed command is ALWAYS flagged, never walked past.\n# This detector scans recent Pi session JSONL for toolResults with isError /"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now I understand the detector. Let me plan and execute."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1097 cat stale then successful canon cat without naming failure should still be a finding (got $count) $report"
ok "live #1097: later successful cat of deploy-clone without naming the failure still flags"
rm -f "$sessions/cat-stale-then-canon-success.jsonl"

# --- 3. same shape plus a later user-facing flag is clean ---------------
write_session "cat-stale-flagged" <<JSONL
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cat3","name":"bash","arguments":{"command":"cat ${STALE_PATH}"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cat3","toolName":"bash","isError":true,"content":[{"type":"text","text":"cat: ${STALE_PATH}: No such file or directory\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the cat call failed with 1 — tooling/fleet-ops/bin/fleet-failed-command-flagged does not exist (stale checkout; canonical is fleet-ops-deploy-clone), it is now the blocker. Switching to the deploy-clone."},{"type":"toolCall","id":"call_canon3","name":"bash","arguments":{"command":"cat ${CANON_PATH} | head -5"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged bare cat of stale tooling/fleet-ops should be clean (got $count) $report"
ok "live #1097: bare cat of stale tooling/fleet-ops plus later user-facing flag is clean"
rm -f "$sessions/cat-stale-flagged.jsonl"

# --- 4. lib/failed-command-flagged.py cites fleet-ops#1097 (detector-side lock: case list moved to lib, fleet-ops#3246) ---------------
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1097' "$lib" \
  || fail "lib/failed-command-flagged.py must cite fleet-ops#1097 (detector-side lock for the live stale-fleet-ops cat shape)"
grep -q 'tooling/fleet-ops/bin/fleet-failed-command-flagged' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live #1097 stale path so workers flag it"
ok "lib/failed-command-flagged.py cites fleet-ops#1097 and the live stale tooling/fleet-ops path"

# --- 5. lib/failed-command-flagged.py docstring cites fleet-ops#1097 ----
grep -q 'fleet-ops#1097' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1097 (detector-side lock)"
grep -q 'tooling/fleet-ops/bin/fleet-failed-command-flagged' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live #1097 stale path"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1097 and the live stale path"

# --- 6. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ---
grep -Fq 'bash "$here/fleet-failed-command-cat-stale-fleet-ops.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-cat-stale-fleet-ops: live #1097 / #1099 bare cat of stale tooling/fleet-ops walked-past drills"
