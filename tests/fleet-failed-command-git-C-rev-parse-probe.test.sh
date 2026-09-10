#!/usr/bin/env bash
# tests/fleet-failed-command-git-C-rev-parse-probe.test.sh
#
# fleet-ops#5033: `git -C <dir> rev-parse ...` is the same ref/existence
# probe as the live #822 shape, but GIT_BENIGN_RE required the subcommand
# to sit IMMEDIATELY after `git`. With git's global options in front
# (`-C <path>`, `-c name=value`, `--no-pager`, `--git-dir=`, ...) the
# family never matched, so the probe fell through to the generic
# "Command exited with code 128" path and was filed as a swallowed
# failure.
#
# Live session: 2026-09-09T21-36-15-377Z_01a08819-9e11-7570-ba6b-594c776c3fe2.jsonl
# The agent was verifying the agent-state escalation file and ran a
# compound command ending in
#   git -C /home/nish/workspaces/agent-state rev-parse --is-inside-work-tree 2>/dev/null
# agent-state is not a checkout, so git exited 128 with stderr silenced
# (`fatal: not a git repository` never reached the toolResult). That is
# a yes/no "is this a git work tree" probe — exit 0 = yes, 128 = no —
# exactly the #822 shape-2 intent. The detector keyed the alarm on it
# and filed issue #5033, which could only clear when the session aged
# out; the finding was a false positive. `git -C <dir> ...` is the
# standard idiom in this fleet's prompts, so the class is not rare.
#
# Fix shape: allow git's global options before the subcommand, nothing
# else. The exit-128 + no-real-fatal-line guards in _git_canonical_probe
# still decide, so a real `fatal: not a git repository` (#765) or a
# `Permission denied (publickey)` clone (#1185) stays a finding, and a
# `-C` form of a NON-probe subcommand (`git -C <dir> status`) is not
# exempted at all.
#
# Scenarios:
#   1. live #5033 shape -> clean (probe, not a swallowed failure).
#   2. same command with the `fatal: not a git repository` line present
#      -> still a finding (the real-error guard is intact).
#   3. contrast: `git -C <dir> status --short 2>/dev/null` exit 128 ->
#      still a finding (status is not in the probe family).
#   4. contrast: `git -C <dir> clone git@...` + Permission denied ->
#      still a finding (clone is not in the family; REAL_ERR_RE holds).
#   5. sibling option forms: `--no-pager log -5 2>/dev/null` and
#      `-c core.pager=cat show 2>/dev/null` -> clean.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-git-C-probe.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-09-10T22:02:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-09-10T22:30:00Z"
}

# --- 1. live #5033 shape: `git -C <not-a-repo> rev-parse ...` silenced ----
write_session "git-C-rev-parse-probe" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cprobe","name":"bash","arguments":{"command":"ls -la /home/nish/workspaces/agent-state/NISH-ESCALATIONS.md; echo \"=== now ===\"; date -u +%Y-%m-%dT%H:%M:%SZ; echo \"=== check for sync-conflict ===\"; ls -la /home/nish/workspaces/agent-state/*.sync-conflict* 2>/dev/null; echo \"=== check git status of agent-state ===\"; cd /home/nish/workspaces/agent-state 2>/dev/null && git status --short 2>/dev/null | head; echo \"=== is agent-state a git repo? ===\"; git -C /home/nish/workspaces/agent-state rev-parse --is-inside-work-tree 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cprobe","toolName":"bash","isError":true,"content":[{"type":"text","text":"-rw------- 1 nish nish 14917 Sep 10 03:13 /home/nish/workspaces/agent-state/NISH-ESCALATIONS.md\n=== now ===\n2026-09-09T22:02:52Z\n=== check for sync-conflict ===\n=== check git status of agent-state ===\n=== is agent-state a git repo? ===\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The mtime matches when I wrote the line. Let me grep the file for the MONEY-BOUNDARY line."},{"type":"toolCall","id":"call_grep","name":"bash","arguments":{"command":"grep -c \"MONEY-BOUNDARY\" /home/nish/workspaces/agent-state/NISH-ESCALATIONS.md"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_grep","toolName":"bash","isError":false,"content":[{"type":"text","text":"3"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "live #5033 git -C rev-parse probe should be clean (got $count) $report"
ok "live #5033 git -C rev-parse existence probe is not a swallowed failure"
rm -f "$sessions/git-C-rev-parse-probe.jsonl"

# --- 2. same command, real `fatal: not a git repository` line -> finding ---
# The live #765 class. The `-C` option form must not suppress a real
# git fatal: the probe exemption rests on the ABSENCE of a real error
# line, not on the subcommand name alone.
write_session "git-C-fatal-real" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cfatal","name":"bash","arguments":{"command":"git -C /home/nish/workspaces/agent-state rev-parse --is-inside-work-tree 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cfatal","toolName":"bash","isError":true,"content":[{"type":"text","text":"fatal: not a git repository (or any of the parent directories): .git\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_next","name":"bash","arguments":{"command":"ls /home/nish/workspaces/agent-state | head"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_next","toolName":"bash","isError":false,"content":[{"type":"text","text":"NISH-ESCALATIONS.md"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "real fatal: not a git repository must stay a finding (got $count) $report"
grep -q 'fatal: not a git repository' <<<"$(jq -r '.findings[0].snippet' <<<"$report")" \
  || fail "finding snippet should carry the real git fatal line"
ok "git -C + real 'fatal: not a git repository' is still a finding"
rm -f "$sessions/git-C-fatal-real.jsonl"

# --- 3. contrast: `git -C <dir> status` is not in the probe family --------
write_session "git-C-status" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cstatus","name":"bash","arguments":{"command":"git -C /home/nish/workspaces/agent-state status --short 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cstatus","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_next2","name":"bash","arguments":{"command":"ls /home/nish/workspaces/agent-state | head"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_next2","toolName":"bash","isError":false,"content":[{"type":"text","text":"NISH-ESCALATIONS.md"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "git -C status exit 128 must stay a finding (got $count) $report"
ok "git -C <dir> status is not covered by the probe exemption"
rm -f "$sessions/git-C-status.jsonl"

# --- 4. contrast: `git -C <dir> clone git@...` Permission denied ----------
write_session "git-C-clone-ssh" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cclone","name":"bash","arguments":{"command":"git -C /tmp/fleet-clone-5033 clone git@github.com:Nishfleet/fleet-ops.git ."}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cclone","toolName":"bash","isError":true,"content":[{"type":"text","text":"Cloning into '.'...\nPermission denied (publickey).\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_next3","name":"bash","arguments":{"command":"ls /tmp/fleet-clone-5033 | head"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_next3","toolName":"bash","isError":false,"content":[{"type":"text","text":"(no output)"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "git -C clone Permission denied must stay a finding (got $count) $report"
ok "git -C <dir> clone publickey denial is still a finding"
rm -f "$sessions/git-C-clone-ssh.jsonl"

# --- 5. sibling global-option forms are probes too ------------------------
write_session "git-global-opts" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_pager","name":"bash","arguments":{"command":"git --no-pager log -5 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_pager","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_copt","name":"bash","arguments":{"command":"git -c core.pager=cat show --stat HEAD 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_copt","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_next4","name":"bash","arguments":{"command":"ls /tmp | head"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_next4","toolName":"bash","isError":false,"content":[{"type":"text","text":"(no output)"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "global-option git probes should be clean (got $count) $report"
ok "git --no-pager / git -c global-option probes are clean"
rm -f "$sessions/git-global-opts.jsonl"

echo "OK: fleet-failed-command-git-C-rev-parse-probe: live #5033 git -C probe drills"
