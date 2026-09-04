#!/usr/bin/env bash
# tests/fleet-failed-command-clone-ssh-publickey.test.sh
#
# fleet-ops#1185: a `git clone git@github.com:...` that returns
#   git@github.com: Permission denied (publickey).
#   fatal: Could not read from remote repository.
#   Command exited with code 128
# (isError=true) is a real swallowed failure. This host has no GitHub
# deploy SSH key. The live worker walked past it with a thinking-only
# "The SSH key doesn't have access. Let me try HTTPS" plus a silent
# HTTPS retry (blocked as dangerous) and then a successful
# `gh repo clone`. Thinking is not a user-facing flag. A later
# successful clone does not discharge the SSH failure. `git clone` is
# NOT in the git-ref probe family (GIT_BENIGN_RE covers only
# log|rev-parse|show|diff|cat-file|shortlog).
#
# The detector already flags this class via the generic
# `isError or code != 0` path. REAL_ERR_RE matches `Permission denied`
# so even a future refactor that added `git clone` to GIT_BENIGN_RE
# would still keep the toolResult as a finding — unless it also dropped
# `Permission denied` from REAL_ERR_RE. The tempting future exemptions
# this file forbids:
#   - treating `git clone git@github.com` as a probe (try SSH, then HTTPS)
#   - treating thinking "The SSH key doesn't have access" as a flag
#   - letting `_text_chunks` collect `thinking` fields so a FLAG_RE
#     match inside thinking discharges the pending failure
#   - treating a later successful `gh repo clone` / HTTPS clone as
#     discharging the SSH failure
#   - adding `git clone` to GIT_BENIGN_RE AND dropping
#     `Permission denied` from REAL_ERR_RE
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T14-20-10-780Z_01a04397-b49c-7f5e-8b60-46b28e3bed5d.jsonl
# The deepseek-v4-pro worker on fleet-ops#1134 ran
#   cd /home/nish/workspaces && mkdir -p .../fleet-ops-issue-1134 &&
#     cd .../fleet-ops-issue-1134 &&
#     git clone git@github.com:Nishfleet/fleet-ops.git . 2>&1
# git refused with exit 128. The next turn was thinking-only
# "The SSH key doesn't have access. Let me try HTTPS" plus
#   git clone https://github.com/Nishfleet/fleet-ops.git .
# which the harness blocked (`Dangerous command blocked`), then
# `gh repo clone` succeeded. Detector snippet starts
# `Cloning into '.'... git@github.com: Permission denied (publickey).`
#
# Distinct from:
#   - #1217: same-turn sibling of a successful HTTPS clone racing a
#     silenced `cd /tmp/<fresh-clone> && ls` — empty snippet, exit 1,
#     not SSH, not publickey
#   - #765: `cd <path> && git status` against a non-git path —
#     `fatal: not a git repository`, not a clone
#   - #822: `git log|rev-parse|show|diff|cat-file <bad-ref>` exit 128
#     (GIT_BENIGN_RE probe) — clone is not in that family
#   - #1061: compound-chain `ls` Permission denied — ls, not git clone
#
# Scenarios:
#   1. live #1185 shape: SSH clone publickey denial + thinking-only
#      HTTPS retry + successful gh repo clone -> finding. Snippet must
#      carry `Permission denied (publickey)` and
#      `Could not read from remote repository`.
#   2. same shape plus a thinking block that WOULD match FLAG_RE if it
#      were user-facing text -> still a finding (thinking is not a flag).
#   3. same shape plus later unrelated user-facing prose that does NOT
#      name the failure -> still a finding.
#   4. same shape plus a later user-facing flag -> clean.
#   5. cross-check: a `git log <bad-ref> 2>/dev/null` ref-existence
#      probe stays a probe (not a finding). Pins that locking #1185
#      must not collapse into "every git exit 128 is a failure".
#   6. worker.md cites fleet-ops#1185 and the live
#      `git clone git@github.com:Nishfleet/fleet-ops.git` wording
#      (prompt-side lock).
#   7. lib/failed-command-flagged.py docstring cites fleet-ops#1185
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

scratch="$(mktemp -d -t failed-command-clone-ssh-publickey.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

LIVE_CMD='cd /home/nish/workspaces && mkdir -p /home/nish/workspaces/agent-worktrees/fleet-ops-issue-1134 && cd /home/nish/workspaces/agent-worktrees/fleet-ops-issue-1134 && git clone git@github.com:Nishfleet/fleet-ops.git . 2>&1'
LIVE_ERR=$'Cloning into \'.\'...\ngit@github.com: Permission denied (publickey).\r\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n\n\nCommand exited with code 128'
export LIVE_CMD LIVE_ERR

json_env() {
  python3 -c 'import json,os,sys; print(json.dumps(os.environ[sys.argv[1]]))' "$1"
}

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T14:22:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T17:00:00Z"
}

# --- 1. live #1185 shape: SSH publickey walked past ------------------------
write_session "clone-ssh-publickey-walked" <<JSONL
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_clone_ssh","name":"bash","arguments":{"command":$(json_env LIVE_CMD)}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_clone_ssh","toolName":"bash","content":[{"type":"text","text":$(json_env LIVE_ERR)}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The SSH key doesn't have access. Let me try HTTPS"},{"type":"toolCall","id":"call_https","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/fleet-ops-issue-1134 && git clone https://github.com/Nishfleet/fleet-ops.git . 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_https","toolName":"bash","content":[{"type":"text","text":"Dangerous command blocked (no UI for confirmation)"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The git clone with HTTPS was blocked as a dangerous command."},{"type":"text","text":"\n"},{"type":"toolCall","id":"call_gh","name":"bash","arguments":{"command":"gh repo clone Nishfleet/fleet-ops /home/nish/workspaces/agent-worktrees/fleet-ops-issue-1134 -- --depth 1 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh","toolName":"bash","isError":false,"content":[{"type":"text","text":"Cloning into '/home/nish/workspaces/agent-worktrees/fleet-ops-issue-1134'...\n"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1185 SSH publickey walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Permission denied (publickey)' <<<"$snippet" \
  || fail "finding snippet should mention Permission denied (publickey) (got $snippet)"
grep -q 'Could not read from remote repository' <<<"$snippet" \
  || fail "finding snippet should mention Could not read from remote repository (got $snippet)"
grep -q "Cloning into" <<<"$snippet" \
  || fail "finding snippet should mention Cloning into (got $snippet)"
ok "live #1185: SSH clone publickey with thinking-only HTTPS retry is flagged"
rm -f "$sessions/clone-ssh-publickey-walked.jsonl"

# --- 2. thinking that would match FLAG_RE still does not discharge ---------
write_session "clone-ssh-publickey-thinking-flag-words" <<JSONL
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ssh2","name":"bash","arguments":{"command":$(json_env LIVE_CMD)}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ssh2","toolName":"bash","content":[{"type":"text","text":$(json_env LIVE_ERR)}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"the git clone call failed with Permission denied (publickey), fixing"},{"type":"toolCall","id":"call_https2","name":"bash","arguments":{"command":"git clone https://github.com/Nishfleet/fleet-ops.git /tmp/x"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "SSH publickey with FLAG_RE words only in thinking should still be a finding (got $count) $report"
ok "live #1185: FLAG_RE words inside thinking do not discharge the SSH failure"
rm -f "$sessions/clone-ssh-publickey-thinking-flag-words.jsonl"

# --- 3. later unrelated user-facing prose does not discharge ---------------
write_session "clone-ssh-publickey-prose" <<JSONL
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ssh3","name":"bash","arguments":{"command":$(json_env LIVE_CMD)}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ssh3","toolName":"bash","content":[{"type":"text","text":$(json_env LIVE_ERR)}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"No claim branch — good. Now claim it"},{"type":"toolCall","id":"call_next3","name":"bash","arguments":{"command":"git checkout -b claim/issue-1134"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "SSH publickey followed by unrelated prose should be a finding (got $count) $report"
ok "live #1185: SSH publickey with unrelated user-facing prose is still flagged"
rm -f "$sessions/clone-ssh-publickey-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean ------------------
write_session "clone-ssh-publickey-flagged" <<JSONL
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ssh4","name":"bash","arguments":{"command":$(json_env LIVE_CMD)}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ssh4","toolName":"bash","content":[{"type":"text","text":$(json_env LIVE_ERR)}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the git clone git@github.com call failed with Permission denied (publickey), fixing."},{"type":"toolCall","id":"call_https4","name":"bash","arguments":{"command":"git clone --reference-if-able /home/nish/workspaces/.mirrors/fleet-ops.git https://github.com/Nishfleet/fleet-ops.git /tmp/x"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "SSH publickey with later user-facing flag should be clean (got $count) $report"
ok "SSH publickey plus later user-facing flag is clean"
rm -f "$sessions/clone-ssh-publickey-flagged.jsonl"

# --- 5. cross-check: git log bad-ref probe stays a probe -------------------
write_session "git-log-bad-ref-probe" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Checking whether origin/claim/issue-1134 exists:"},{"type":"toolCall","id":"call_probe","name":"bash","arguments":{"command":"git log origin/claim/issue-1134 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe","toolName":"bash","content":[{"type":"text","text":"Command exited with code 128"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_next","name":"bash","arguments":{"command":"git checkout -b claim/issue-1134"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git log bad-ref probe with silenced stderr must stay a probe (got $count) $report"
ok "git log bad-ref probe stays a probe (contrast with #1185)"
rm -f "$sessions/git-log-bad-ref-probe.jsonl"

# --- 6. prompts/worker.md cites fleet-ops#1185 (prompt-side lock) -----------
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1185' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1185 (prompt-side lock)"
grep -q 'git clone git@github.com:Nishfleet/fleet-ops.git' "$worker" \
  || fail "prompts/worker.md must name the live 'git clone git@github.com:Nishfleet/fleet-ops.git' wording"
ok "worker.md cites fleet-ops#1185 and the live SSH-clone wording"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#1185 -------
grep -q 'fleet-ops#1185' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1185 (detector-side lock)"
grep -q 'git clone git@github.com:Nishfleet/fleet-ops.git' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live SSH clone wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1185 and the SSH-clone shape"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-clone-ssh-publickey.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-clone-ssh-publickey: live #1185 SSH publickey drills"
