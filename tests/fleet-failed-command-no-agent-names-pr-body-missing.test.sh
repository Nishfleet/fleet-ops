#!/usr/bin/env bash
# tests/fleet-failed-command-no-agent-names-pr-body-missing.test.sh
#
# fleet-ops#1241: a `bin/fleet-no-agent-names-check --pr-body
# /tmp/pr-body-<N>.md` run against a PR body file that has not been
# written yet fails with
#   fleet-no-agent-names-check: cannot read /tmp/pr-body-<N>.md:
#   [Errno 2] No such file or directory: '/tmp/pr-body-<N>.md'
# and `Command exited with code 2`. The worker walks past it with a
# thinking-only next turn plus a recovery toolCall that writes the
# missing file. No user-facing text named the failure (the standing
# rule, fleet-ops#535).
#
# The detector already flags this class: `fleet-no-agent-names-check`
# is not in any no-match probe family (grep/rg/diff/ls/which/git-ref),
# and the toolResult has isError=true with `Command exited with code 2`.
# No `lib/failed-command-flagged.py` detection-logic change — a
# suppression would silence a real signal. The gap is the dedicated
# file so the class is named in three places (test, prompt, detector
# docstring), not one. The auto-filed issue closes via observe-to-close
# (fleet-ops#650) when the session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T15-47-35-701Z_01a043e7-bc95-7fb9-83a7-6e127fc31341.jsonl
# The agent (working on fleet-ops#1079) ran
#   cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1079 && \
#     bin/fleet-no-agent-names-check --pr-body /tmp/pr-body-1079.md \
#     --commit-range origin/main..HEAD 2>&1
# before writing `/tmp/pr-body-1079.md`. The checker refused with
#   fleet-no-agent-names-check: cannot read /tmp/pr-body-1079.md:
#   [Errno 2] No such file or directory: '/tmp/pr-body-1079.md'
#   Command exited with code 2
# then continued with a thinking-only turn plus a `cat >
# /tmp/pr-body-1079.md << 'PRBODY'` recovery toolCall — no
# user-facing text named the failure. The retry after the write
# succeeded; the first failure had already been walked past.
#
# The class is distinct from the live #794 ls no-match exemption
# (canonical `ls: cannot access '<path>': No such file or directory`
# line, command is `ls`, exit 2). This command is
# `fleet-no-agent-names-check`, not `ls`, so `LS_BENIGN_RE` does not
# apply even though the error text contains `No such file or
# directory`. A future refactor that broadens the ls exemption to any
# `No such file or directory` line (regardless of command) would
# silently suppress this real signal.
#
# Scenarios:
#   1. live #1241 shape: fleet-no-agent-names-check --pr-body
#      /tmp/pr-body-1079.md against a missing file, exit 2, isError=true,
#      thinking-only + write-the-file recovery -> finding. Snippet must
#      carry `fleet-no-agent-names-check: cannot read`,
#      `/tmp/pr-body-1079.md`, `No such file or directory`, and
#      `Command exited with code 2` — dropping any one is a regression
#      in the snippet-capture path.
#   2. same shape plus a later user-facing flag naming the failure ->
#      clean.
#   3. cross-check: fleet-no-agent-names-check against an existing
#      PR body file succeeds (isError=false) and is not flagged. Pin
#      the contrast so a future refactor that flags every
#      `fleet-no-agent-names-check` call is caught.
#   4. cross-check: `ls <nonexistent>` exit 2 with the canonical
#      no-match line is the live #794 exemption — same
#      `No such file or directory` wording, different command. That
#      must stay exempt while the missing-pr-body shape is flagged.
#      Pin the contrast so a future refactor that broadens the ls
#      exemption to any `No such file or directory` (silencing #1241)
#      OR that drops the canonical ls no-match probe (silencing #794)
#      is caught.
#   5. worker.md cites fleet-ops#1241 (prompt-side lock).
#   6. lib/failed-command-flagged.py docstring cites fleet-ops#1241
#      (detector-side lock).
#   7. seat-lib.test.sh hosts this file (CI cannot gain a new P14
#      workflow line — the worker token has no Workflows permission).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-no-agent-names-pr-body-missing.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T15:47:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T16:00:00Z"
}

# --- 1. live #1241 shape: missing --pr-body file, exit 2, walked past ------
# The live session slug 01a043e7 was filed because the agent ran
# fleet-no-agent-names-check against /tmp/pr-body-1079.md before
# writing that file, then recovered by writing the file with no
# user-facing flag. Replay that exact shape.
write_session "no-agent-names-pr-body-missing-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_check1","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1079 && bin/fleet-no-agent-names-check --pr-body /tmp/pr-body-1079.md --commit-range origin/main..HEAD 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_check1","toolName":"bash","isError":true,"content":[{"type":"text","text":"fleet-no-agent-names-check: cannot read /tmp/pr-body-1079.md: [Errno 2] No such file or directory: '/tmp/pr-body-1079.md'\n\nCommand exited with code 2"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Need to write the PR body file first, then re-run the check."},{"type":"toolCall","id":"call_write1","name":"bash","arguments":{"command":"cat > /tmp/pr-body-1079.md << 'PRBODY'\nRelates to #1079\nPRBODY\necho \"PR body written\""}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1241 fleet-no-agent-names-check missing --pr-body walked past should be a finding (got $count) $report"
slug=$(jq -r '.findings[0].slug' <<<"$report")
[[ "$slug" == "no-agent-names-pr-body-missing-walked" ]] || fail "finding slug should be no-agent-names-pr-body-missing-walked (got $slug)"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'fleet-no-agent-names-check: cannot read' <<<"$snippet" \
  || fail "finding snippet should mention fleet-no-agent-names-check: cannot read (got $snippet)"
grep -q '/tmp/pr-body-1079.md' <<<"$snippet" \
  || fail "finding snippet should mention /tmp/pr-body-1079.md (got $snippet)"
grep -q 'No such file or directory' <<<"$snippet" \
  || fail "finding snippet should mention No such file or directory (got $snippet)"
grep -q 'Command exited with code 2' <<<"$snippet" \
  || fail "finding snippet should mention Command exited with code 2 (got $snippet)"
ok "live #1241: fleet-no-agent-names-check --pr-body missing file + thinking-only write recovery is flagged"
rm -f "$sessions/no-agent-names-pr-body-missing-walked.jsonl"

# --- 2. same shape plus a later user-facing flag is clean -----------------
# The standing rule is satisfied when the assistant names the failure
# in user-facing text in the same turn. The detector must NOT flag
# this. Lock the contrast: a worker that names the missing-file
# failure in plain text and then writes the file is clean; a worker
# that only emits a recovery toolCall is filed.
write_session "no-agent-names-pr-body-missing-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_check2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1079 && bin/fleet-no-agent-names-check --pr-body /tmp/pr-body-1079.md --commit-range origin/main..HEAD 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_check2","toolName":"bash","isError":true,"content":[{"type":"text","text":"fleet-no-agent-names-check: cannot read /tmp/pr-body-1079.md: [Errno 2] No such file or directory: '/tmp/pr-body-1079.md'\n\nCommand exited with code 2"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the fleet-no-agent-names-check call failed with cannot read /tmp/pr-body-1079.md: [Errno 2] No such file or directory, fixing — writing the PR body file first."},{"type":"toolCall","id":"call_write2","name":"bash","arguments":{"command":"cat > /tmp/pr-body-1079.md << 'PRBODY'\nRelates to #1079\nPRBODY"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged fleet-no-agent-names-check missing --pr-body should be clean (got $count) $report"
ok "fleet-no-agent-names-check missing --pr-body plus later user-facing flag is clean"
rm -f "$sessions/no-agent-names-pr-body-missing-flagged.jsonl"

# --- 3. successful check against an existing PR body is not flagged ------
# A `fleet-no-agent-names-check --pr-body FILE` that finds the file
# and reports OK is exit 0, isError=false. The detector must NOT flag
# it. Pin the contrast: a successful check is clean, a missing-file
# check walked past is not. A future refactor that flags every
# `fleet-no-agent-names-check` call would fire on every worker PR.
write_session "no-agent-names-pr-body-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ok","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1079 && bin/fleet-no-agent-names-check --pr-body /tmp/pr-body-1079.md --commit-range origin/main..HEAD 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"OK: no agent attribution detected\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Check is clean."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "successful fleet-no-agent-names-check should be clean (got $count) $report"
ok "successful fleet-no-agent-names-check against an existing PR body is not flagged (contrast with #1241)"
rm -f "$sessions/no-agent-names-pr-body-ok.jsonl"

# --- 4. cross-check: ls no-match exemption still holds --------------------
# Same `No such file or directory` wording, different command. Live
# #794: `ls <nonexistent>` exit 2 with the canonical probe line is
# a deliberate existence probe, not a swallowed failure. Pin both
# verdicts so a future refactor cannot collapse them.
write_session "ls-no-match-exempt" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ls","name":"bash","arguments":{"command":"ls /tmp/this-path-does-not-exist-1241 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ls","toolName":"bash","isError":true,"content":[{"type":"text","text":"ls: cannot access '/tmp/this-path-does-not-exist-1241': No such file or directory\n\nCommand exited with code 2"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_next","name":"bash","arguments":{"command":"echo next"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "live #794 ls no-match should stay exempt (got $count) $report"
ok "ls no-match (No such file or directory, exit 2) stays exempt (contrast with #1241)"
rm -f "$sessions/ls-no-match-exempt.jsonl"

# --- 5. worker.md cites fleet-ops#1241 (prompt-side lock) -----------------
worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1241' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1241 (prompt-side lock for the live missing --pr-body shape)"
grep -q 'fleet-no-agent-names-check: cannot read' "$worker" \
  || fail "prompts/worker.md must name the live #1241 cannot-read wording so workers flag it"
grep -q '/tmp/pr-body-1079.md' "$worker" \
  || fail "prompts/worker.md must cite the live /tmp/pr-body-1079.md path"
ok "worker.md cites fleet-ops#1241 and the live cannot-read wording"

# --- 6. lib/failed-command-flagged.py docstring cites fleet-ops#1241 ----
grep -q 'fleet-ops#1241' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1241 (detector-side lock)"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1241"

# --- 7. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ---
grep -Fq 'bash "$here/fleet-failed-command-no-agent-names-pr-body-missing.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-no-agent-names-pr-body-missing: live #1241 fleet-no-agent-names-check missing --pr-body walked-past drills"
