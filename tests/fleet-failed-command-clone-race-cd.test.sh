#!/usr/bin/env bash
# tests/fleet-failed-command-clone-race-cd.test.sh
#
# fleet-ops#1217: a same-turn sibling of a `git clone` into
# `/tmp/<fresh-clone>` that races with
#   `cd /tmp/<fresh-clone> 2>/dev/null && ls ...`
# and returns `(no output)  Command exited with code 1` is a real
# swallowed failure. The clone is still in flight, `cd` fails, stderr
# is silenced so the snippet is empty, and the next assistant turn is a
# silent `cd && ls` recovery with no user-facing text naming the failure.
#
# The detector already flags this class via the generic
# `isError or code != 0` path. No `lib/failed-command-flagged.py` logic
# change is needed — a suppression would silence a real signal. The
# tempting future exemptions this file forbids:
#   - treating `cd ... 2>/dev/null` as a no-match probe (like which/ls)
#   - treating `(no output)` + exit 1 as benign whenever stderr is
#     silenced
#   - broadening `LS_BENIGN_RE` to code==1 because the command text
#     contains `ls` and `2>/dev/null` (`LS_BENIGN_RE` only short-circuits
#     on exit 2)
#   - letting the same-turn clone success mask the sibling failure
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T15-13-39-420Z_01a043c8-aa5c-72cb-9f02-d452218d767f.jsonl
# The minimax-m3-free worker on fleet-ops#1165 fired TWO bash toolCalls
# in one turn:
#   1. `git clone --depth 50 ... /tmp/fleet-ops-fresh-1165 && cd ... &&
#      git log ...` (succeeded)
#   2. `cd /tmp/fleet-ops-fresh-1165 2>/dev/null && ls bin/ 2>/dev/null |
#      head -20 && echo "---PROMPTS---" && ls prompts/ 2>/dev/null`
#      (failed: clone still in flight, cd failed, 2>/dev/null swallowed
#      the error, harness reported `(no output)  Command exited with
#      code 1`, isError=true, details={})
# The next turn was `cd /tmp/fleet-ops-fresh-1165 && ls -la` with no
# user-facing text. Detector snippet: `(no output)  Command exited with
# code 1`.
#
# Distinct from:
#   - #793: `bash /tmp/<fresh-script>` exit 1 with the same empty
#     snippet — different command (a written script, not a racing cd)
#   - #765: `cd <path> 2>/dev/null && git status` against a non-git
#     path — exit 128 with `fatal: not a git repository`, not exit 1
#     with empty output
#   - #794: single-command `ls` exit 2 with the canonical no-match line
#   - grep/rg POSIX no-match (BENIGN_STAGE_RE) — the live session also
#     carried a later `grep -nF` exit 1 with `(no output)`; that is a
#     probe and must stay clean
#
# Scenarios:
#   1. live #1217 shape: same-turn clone success + racing silenced cd
#      + silent ls recovery -> finding. Snippet must carry
#      `(no output)` and `Command exited with code 1`.
#   2. same shape plus a later thinking-only note -> still a finding.
#   3. same shape plus later unrelated user-facing prose that does NOT
#      name the failure -> still a finding.
#   4. same shape plus a later user-facing flag -> clean.
#   5. cross-check: a later `grep -nF` exit 1 with `(no output)` stays
#      a probe (not a finding). Pins that locking #1217 must not
#      collapse into "every empty exit-1 is a failure".
#   6. worker.md cites fleet-ops#1217 and the live `cd /tmp/fleet-ops-fresh-1165`
#      wording (prompt-side lock).
#   7. lib/failed-command-flagged.py docstring cites fleet-ops#1217
#      (detector-side lock).
#   8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).

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

scratch="$(mktemp -d -t failed-command-clone-race-cd.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T15:22:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T17:00:00Z"
}

# --- 1. live #1217 shape: racing silenced cd walked past -------------------
# Replay the exact same-turn pair from slug 01a043c8-aa5c: clone succeeds,
# sibling `cd /tmp/fleet-ops-fresh-1165 2>/dev/null && ls ...` exits 1
# with `(no output)`, next turn is a silent `cd && ls -la`.
write_session "clone-race-cd-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Claim branch is free. Let me do a fresh clone to a worktree."},{"type":"toolCall","id":"call_clone","name":"bash","arguments":{"command":"git clone --depth 50 https://github.com/Nishfleet/fleet-ops.git /tmp/fleet-ops-fresh-1165 2>&1 | tail -5 && cd /tmp/fleet-ops-fresh-1165 && git log --oneline -3 && git branch -a 2>&1 | head -10"}},{"type":"toolCall","id":"call_race","name":"bash","arguments":{"command":"cd /tmp/fleet-ops-fresh-1165 2>/dev/null && ls bin/ 2>/dev/null | head -20 && echo \"---PROMPTS---\" && ls prompts/ 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_clone","toolName":"bash","isError":false,"content":[{"type":"text","text":"Cloning into '/tmp/fleet-ops-fresh-1165'...\n0fba855 feat(pi-packet-verdict): checker engine + unit tests (#1134, slice 1) (#1159)\n* main\n  remotes/origin/HEAD -> origin/main\n  remotes/origin/main\n"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_race","toolName":"bash","content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_recover","name":"bash","arguments":{"command":"cd /tmp/fleet-ops-fresh-1165 && ls -la"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_recover","toolName":"bash","isError":false,"content":[{"type":"text","text":"total 7836\ndrwxrwxr-x 15 nish nish 4096 Aug 27 20:44 .\n"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1217 clone-race silenced cd walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'no output' <<<"$snippet" \
  || fail "finding snippet should mention (no output) (got $snippet)"
grep -q 'Command exited with code 1' <<<"$snippet" \
  || fail "finding snippet should mention Command exited with code 1 (got $snippet)"
ok "live #1217: racing silenced cd with silent ls recovery is flagged"
rm -f "$sessions/clone-race-cd-walked.jsonl"

# --- 2. thinking-only recovery is still a finding --------------------------
write_session "clone-race-cd-thinking" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_clone2","name":"bash","arguments":{"command":"git clone --depth 50 https://github.com/Nishfleet/fleet-ops.git /tmp/fleet-ops-fresh-1165 2>&1 | tail -5"}},{"type":"toolCall","id":"call_race2","name":"bash","arguments":{"command":"cd /tmp/fleet-ops-fresh-1165 2>/dev/null && ls bin/ 2>/dev/null | head -20 && echo \"---PROMPTS---\" && ls prompts/ 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_clone2","toolName":"bash","isError":false,"content":[{"type":"text","text":"Cloning into '/tmp/fleet-ops-fresh-1165'...\n"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_race2","toolName":"bash","content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The cd raced the clone. The directory exists now. I will list it."},{"type":"toolCall","id":"call_recover2","name":"bash","arguments":{"command":"cd /tmp/fleet-ops-fresh-1165 && ls -la"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "clone-race silenced cd with thinking-only recovery should be a finding (got $count) $report"
ok "live #1217: racing silenced cd with later thinking-only recovery is still flagged"
rm -f "$sessions/clone-race-cd-thinking.jsonl"

# --- 3. later unrelated user-facing prose does not discharge ---------------
write_session "clone-race-cd-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_clone3","name":"bash","arguments":{"command":"git clone --depth 50 https://github.com/Nishfleet/fleet-ops.git /tmp/fleet-ops-fresh-1165 2>&1 | tail -5"}},{"type":"toolCall","id":"call_race3","name":"bash","arguments":{"command":"cd /tmp/fleet-ops-fresh-1165 2>/dev/null && ls bin/ 2>/dev/null | head -20 && echo \"---PROMPTS---\" && ls prompts/ 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_clone3","toolName":"bash","isError":false,"content":[{"type":"text","text":"Cloning into '/tmp/fleet-ops-fresh-1165'...\n"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_race3","toolName":"bash","content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The clone finished. Listing bin/ and prompts/ next."},{"type":"toolCall","id":"call_recover3","name":"bash","arguments":{"command":"cd /tmp/fleet-ops-fresh-1165 && ls -la"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "clone-race silenced cd followed by unrelated prose should be a finding (got $count) $report"
ok "live #1217: racing silenced cd with unrelated user-facing prose is still flagged"
rm -f "$sessions/clone-race-cd-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean ------------------
write_session "clone-race-cd-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_clone4","name":"bash","arguments":{"command":"git clone --depth 50 https://github.com/Nishfleet/fleet-ops.git /tmp/fleet-ops-fresh-1165 2>&1 | tail -5"}},{"type":"toolCall","id":"call_race4","name":"bash","arguments":{"command":"cd /tmp/fleet-ops-fresh-1165 2>/dev/null && ls bin/ 2>/dev/null | head -20 && echo \"---PROMPTS---\" && ls prompts/ 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_clone4","toolName":"bash","isError":false,"content":[{"type":"text","text":"Cloning into '/tmp/fleet-ops-fresh-1165'...\n"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_race4","toolName":"bash","content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the cd /tmp/fleet-ops-fresh-1165 call failed with exit 1 (no output, the clone was still in flight). fixing."},{"type":"toolCall","id":"call_recover4","name":"bash","arguments":{"command":"cd /tmp/fleet-ops-fresh-1165 && ls -la"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "clone-race silenced cd with later user-facing flag should be clean (got $count) $report"
ok "racing silenced cd plus later user-facing flag is clean"
rm -f "$sessions/clone-race-cd-flagged.jsonl"

# --- 5. cross-check: grep POSIX no-match with the same empty snippet stays a probe
# The live #1217 session also carried a later
#   grep -nF "skipped-vacation-0509-protected" .../pi-intake-tick.sh
# that exited 1 with `(no output)`. That is BENIGN_STAGE_RE. Locking the
# clone-race shape must not collapse into "every empty exit-1 is a failure".
write_session "grep-no-match-empty-snippet" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Let me look at what the test expected:"},{"type":"toolCall","id":"call_grep","name":"bash","arguments":{"command":"grep -nF \"skipped-vacation-0509-protected\" /tmp/fleet-ops-fresh-1165/lib/pi-intake-tick.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_grep","toolName":"bash","content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_next","name":"bash","arguments":{"command":"ls /tmp/fleet-ops-fresh-1165/lib/pi-intake-tick.sh"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "grep POSIX no-match with (no output) exit 1 must stay a probe (got $count) $report"
ok "grep POSIX no-match with the same empty snippet stays a probe (contrast with #1217)"
rm -f "$sessions/grep-no-match-empty-snippet.jsonl"

# --- 6. prompts/worker.md cites fleet-ops#1217 (prompt-side lock) -----------
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1217' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1217 (prompt-side lock)"
grep -q 'cd /tmp/fleet-ops-fresh-1165' "$worker" \
  || fail "prompts/worker.md must name the live 'cd /tmp/fleet-ops-fresh-1165' wording"
ok "worker.md cites fleet-ops#1217 and the live racing-cd wording"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#1217 -------
grep -q 'fleet-ops#1217' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1217 (detector-side lock)"
grep -q 'cd /tmp/fleet-ops-fresh-1165' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'cd /tmp/fleet-ops-fresh-1165' wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1217 and the racing-cd shape"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-clone-race-cd.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-clone-race-cd: live #1217 racing silenced-cd drills"
