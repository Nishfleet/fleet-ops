#!/usr/bin/env bash
# tests/fleet-failed-command-cd-non-git-repo.test.sh
#
# fleet-ops#765: a worker `cd`s into a path that is not a git checkout
# (or a path that does not exist) and then runs `git status` / `git log`
# against it. Both commands emit `fatal: not a git repository (or any of
# the parent directories): .git` and exit 128. The next assistant turn
# is a recovery toolCall with no user-facing text naming the failure.
# The detector already flags this class: the command text does not match
# `BENIGN_STAGE_RE` (no grep/rg/diff), `LS_BENIGN_RE` only short-circuits
# on exit 2, and the harness's `isError: true` + `Command exited with
# code 128` is a real ran-and-failed command. This file locks the live
# #765 shape so a future detector refactor cannot regress it. No
# `lib/failed-command-flagged.py` change — a suppression would silence
# a real signal. The auto-filed issue closes via observe-to-close
# (fleet-ops#758) when the session mtime ages out of the 24h window
# after 2026-08-27T01:17:50Z.
#
# Live session: 2026-08-27T01-17-50-330Z_01a040cb-7379-7e74-94f6-e1a7f7c5e7ef.jsonl
# A senior-auditor agent on a scout candidate issue ran:
#   ls ~/workspaces/lanes/0509 2>/dev/null | head; \
#   echo "---"; \
#   cd ~/workspaces/lanes/0509 2>/dev/null && \
#     git status 2>&1 | head -5 && \
#     git log --oneline -3 2>&1
# Both `git status` and `git log` failed with `fatal: not a git repository`
# (exit 128). The agent recovered by `cd`-ing into ~/workspaces/products/0509
# (the real checkout) without naming the failure in user-facing text.
#
# Scenarios:
#   1. live #765 shape: `cd <path>; git status; git log` -> `fatal: not a git
#      repository` exit 128 walked past -> finding (snippet carries
#      "fatal: not a git repository" + "Command exited with code 128").
#   2. same shape plus a later "the git status call failed with code 128
#      (fatal: not a git repository)" user-facing flag -> clean.
#   3. cross-check: `git status` against an actual non-empty repo succeeds
#      (exit 0) and is not flagged — the lane is the contrast between a
#      real repo and a not-a-repo path.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-cd-non-git.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T01:17:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T02:00:00Z"
}

# --- 1. live #765 shape: cd <not-a-git> && git status / git log exit 128 ----
# The live session slug 01a040cb-7379-... was filed because the agent ran
#   ls ~/workspaces/lanes/0509 2>/dev/null | head; \
#   echo "---"; \
#   cd ~/workspaces/lanes/0509 2>/dev/null && \
#     git status 2>&1 | head -5 && \
#     git log --oneline -3 2>&1
# and got `---\nfatal: not a git repository...\n\n\nCommand exited with
# code 128`, then continued with a `cd ~/workspaces/products/0509` recovery
# toolCall and a `git log --oneline -3` against the real checkout, with no
# user-facing text naming the lane-repo failure. Replay that exact shape.
write_session "cd-non-git-repo" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cdgit","name":"bash","arguments":{"command":"ls ~/workspaces/lanes/0509 2>/dev/null | head; echo \"---\"; cd ~/workspaces/lanes/0509 2>/dev/null && git status 2>&1 | head -5 && git log --oneline -3 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cdgit","toolName":"bash","isError":true,"content":[{"type":"text","text":"---\nfatal: not a git repository (or any of the parent directories): .git\nfatal: not a git repository (or any of the parent directories): .git\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_recover","name":"bash","arguments":{"command":"ls ~/workspaces/products/0509 2>/dev/null | head; echo \"---\"; cd ~/workspaces/products/0509 && git log --oneline -3 2>&1 | head"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_recover","toolName":"bash","isError":false,"content":[{"type":"text","text":"AGENTS.md\napp\nautomation\n..."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Verified all repo claims. Deciding now."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #765 cd-non-git-repo walked past should be a finding (got $count) $report"
slug=$(jq -r '.findings[0].slug' <<<"$report")
[[ "$slug" == "cd-non-git-repo" ]] || fail "finding slug should be cd-non-git-repo (got $slug)"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# The snippet is the first 200 chars of the toolResult text. The live
# #765 toolResult was `---\nfatal: not a git repository...\n\nCommand
# exited with code 128`, so the snippet must carry both the git-fatal
# signal and the exit-128 signal — pin both so a future refactor that
# drops one of them is caught.
grep -q 'fatal: not a git repository' <<<"$snippet" \
  || fail "finding snippet should mention 'fatal: not a git repository' (got $snippet)"
grep -q 'Command exited with code 128' <<<"$snippet" \
  || fail "finding snippet should mention 'Command exited with code 128' (got $snippet)"
ok "live #765 cd-non-git-repo exit 128 walked past is flagged"
rm -f "$sessions/cd-non-git-repo.jsonl"

# --- 2. same shape plus a later user-facing flag is clean -------------------
# The standing rule is satisfied when the assistant names the failure in
# the same turn's user-facing text. The detector must NOT flag this.
# Lock the contrast: a worker that flags the lane-repo failure in plain
# text and then recovers is clean; a worker that only emits a recovery
# toolCall is filed.
write_session "cd-non-git-repo-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cdgit2","name":"bash","arguments":{"command":"ls ~/workspaces/lanes/0509 2>/dev/null | head; echo \"---\"; cd ~/workspaces/lanes/0509 2>/dev/null && git status 2>&1 | head -5 && git log --oneline -3 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cdgit2","toolName":"bash","isError":true,"content":[{"type":"text","text":"---\nfatal: not a git repository (or any of the parent directories): .git\nfatal: not a git repository (or any of the parent directories): .git\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the git status / git log call failed with code 128 (fatal: not a git repository — lanes/0509 is not a checkout). The recovery cd into products/0509 is the actual repo. It is now the blocker if the lane path was expected to exist."},{"type":"toolCall","id":"call_recover2","name":"bash","arguments":{"command":"ls ~/workspaces/products/0509 2>/dev/null | head; echo \"---\"; cd ~/workspaces/products/0509 && git log --oneline -3 2>&1 | head"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_recover2","toolName":"bash","isError":false,"content":[{"type":"text","text":"AGENTS.md\napp\nautomation\n..."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Verified all repo claims. Deciding now."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged cd-non-git-repo exit 128 should be clean (got $count) $report"
ok "cd-non-git-repo exit 128 plus later user-facing flag is clean"
rm -f "$sessions/cd-non-git-repo-flagged.jsonl"

# --- 3. cross-check: git status against a real repo is not flagged ---------
# The detector's `fatal: not a git repository` exit-128 path is a real
# failure because the cwd is not a git repo. A real checkout, with
# `git status` succeeding, is the contrast: same `git` command, different
# cwd, exit 0. Pin it so a future refactor that broadens the suppression
# (e.g. suppressing all `git ... && git ...` chains on exit 128) cannot
# silently file every real checkout.
write_session "git-real-repo-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_realrepo","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && git status 2>&1 | head -5 && git log --oneline -3 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_realrepo","toolName":"bash","isError":false,"content":[{"type":"text","text":"On branch claim/issue-765\nYour branch is up to date with 'origin/main'.\n\nnothing to commit, working tree clean\nd6d3d30 test(p14-listing-gate): hard-pin dirty-worktree-audit host (fleet-ops#777) (#901)\n8d590f4 test(p14-listing-gate): hard-pin dirty-worktree-audit host (fleet-ops#777)\naa96f13 wip(issue-652): 503 / upstream-overload bench (uncommitted hot-patch in progress)"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Working tree clean on the live fleet-ops deploy-clone. Continuing."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git status against a real repo should be clean (got $count) $report"
ok "git status against a real repo is not flagged (contrast with cd-non-git-repo)"
rm -f "$sessions/git-real-repo-ok.jsonl"

echo "OK: fleet-failed-command-cd-non-git-repo: live #765 cd-non-git-repo exit 128 drills"
