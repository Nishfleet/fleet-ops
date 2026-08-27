#!/usr/bin/env bash
# tests/fleet-failed-command-git-branch-cannot-force-update.test.sh
#
# fleet-ops#849: a worker in `cd <worktree>` runs `git branch -f
# <branch> origin/main` (or `git push --force` / `git reset --hard`) on
# the very branch that worktree has checked out. git refuses with
# `fatal: cannot force update the branch '<branch>' used by worktree
# at '<path>'` and exits 128. The next assistant turn is a recovery
# toolCall (`git checkout -b tmp-clean origin/main ...`) with no
# user-facing text naming the failure. The detector already flags
# this class — the failure is `isError: true` + `Command exited with
# code 128` and the command text is `git branch -f`, not a ref-
# existence probe (so neither `GIT_BENIGN_RE` nor `GIT_CANONICAL_NO_REF_RE`
# short-circuits it). This file locks the live #849 shape so a future
# detector refactor cannot regress it. No `lib/failed-command-flagged.py`
# change — a suppression would silence a real signal. The auto-filed
# issue closes via observe-to-close (fleet-ops#758) when the session
# mtime ages out of the 24h window after 2026-08-27T02:21:40Z.
#
# Live session: 2026-08-27T02-21-40-527Z_01a04105-e52f-78bf-9056-ca05fae95a80.jsonl
# The agent (working on issue-fleet-ops-650 / an observe-to-close PR
# that needed to be re-pushed on top of origin/main) ran
#   cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-650 && \
#     git branch -f claim/issue-650 origin/main && \
#     git status 2>&1 | head -5 && \
#     git log --oneline -3
# git returned
#   fatal: cannot force update the branch 'claim/issue-650' used by
#   worktree at '/home/nish/workspaces/agent-worktrees/issue-fleet-ops-650'
# (exit 128) because the branch is checked out in the same worktree
# where the command ran. The agent's next turn was a `git checkout -b
# tmp-clean origin/main` recovery toolCall with only a thinking-block
# reason and no user-facing text naming the failure.
#
# Scenarios:
#   1. live #849 shape: cd <worktree> && git branch -f <branch> <ref>
#      exit 128 walked past -> finding. Snippet must carry the
#      "cannot force update the branch" + "used by worktree at" +
#      "Command exited with code 128" signal.
#   2. same shape plus a later user-facing flag -> clean.
#   3. `git push --force-with-lease` to a branch checked out in the
#      same worktree — same fatal shape, same detector verdict.
#   4. cross-check: `git branch -f` against a branch that ISN'T
#      checked out (the contrast) succeeds, exit 0, not flagged.
#   5. cross-check: a `git log <bad-ref> 2>/dev/null` ref-existence
#      probe is the live #822 exemption — same command family, exit
#      128, but the agent silenced stderr on purpose. That must stay
#      exempt while the force-update shape is flagged.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-git-branch-force.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T02:22:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T03:00:00Z"
}

# --- 1. live #849 shape: git branch -f in the worktree that owns the branch
# The live session slug 01a04105 was filed because the agent ran
#   cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-650 && \
#     git branch -f claim/issue-650 origin/main && \
#     git status 2>&1 | head -5 && \
#     git log --oneline -3
# and got
#   fatal: cannot force update the branch 'claim/issue-650' used by
#   worktree at '/home/nish/workspaces/agent-worktrees/issue-fleet-ops-650'
# followed by `Command exited with code 128`, then continued with a
# `git checkout -b tmp-clean origin/main` recovery toolCall and only
# a thinking-block reason — no user-facing text naming the failure.
# Replay that exact shape.
write_session "git-branch-cannot-force-update" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_force","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-650 && git branch -f claim/issue-650 origin/main && git status 2>&1 | head -5 && git log --oneline -3"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_force","toolName":"bash","isError":true,"content":[{"type":"text","text":"fatal: cannot force update the branch 'claim/issue-650' used by worktree at '/home/nish/workspaces/agent-worktrees/issue-fleet-ops-650'\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_recover","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-650 && git checkout -b tmp-clean origin/main 2>&1 | head -3 && git log --oneline -3 && git branch | head -5"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_recover","toolName":"bash","isError":false,"content":[{"type":"text","text":"Switched to a new branch 'tmp-clean'\na468d9f fix(tests): align exec-review 4a/9a1 with the #728 lenient-colon canary (fleet-ops#622) (#941)\nfc77e3d test(p14): lock the #830 fleet-seat-recovery inline-verify re-breakage shape (#940)\n0caa450 test(p14-listing-gate): record #831 as duplicate-of-#824 closure (fleet-ops#831) (#939)\n  claim/issue-650\n* tmp-clean\n  fix/issue-661-keyerror-walked-past\n"}}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The worktree dir is the same but I'm now on tmp-clean. I want to keep my commit but on top of origin/main. Let me cherry-pick my commit onto tmp-clean, then move the worktree back to claim/issue-650 pointing at the cherry-picked result."},{"type":"toolCall","id":"call_followup","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-650 && git checkout claim/issue-650 2>&1 | head -3 && git log --oneline -3 && git status 2>&1 | head -3"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #849 git branch -f in own worktree walked past should be a finding (got $count) $report"
slug=$(jq -r '.findings[0].slug' <<<"$report")
[[ "$slug" == "git-branch-cannot-force-update" ]] || fail "finding slug should be git-branch-cannot-force-update (got $slug)"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# The snippet is the first 200 chars of the toolResult text. The live
# #849 toolResult was the "cannot force update" fatal + the
# "used by worktree at" pointer + "Command exited with code 128".
# Pin all three so a future refactor that drops one of them is
# caught — this is the class-prevention rule from fleet-ops#366.
grep -q 'cannot force update the branch' <<<"$snippet" \
  || fail "finding snippet should mention 'cannot force update the branch' (got $snippet)"
grep -q 'used by worktree at' <<<"$snippet" \
  || fail "finding snippet should mention 'used by worktree at' (got $snippet)"
grep -q 'Command exited with code 128' <<<"$snippet" \
  || fail "finding snippet should mention 'Command exited with code 128' (got $snippet)"
ok "live #849 git branch -f in own worktree exit 128 walked past is flagged"
rm -f "$sessions/git-branch-cannot-force-update.jsonl"

# --- 2. same shape plus a later user-facing flag is clean -------------------
# The standing rule is satisfied when the assistant names the failure in
# the same turn's user-facing text. The detector must NOT flag this.
# Lock the contrast: a worker that flags the force-update failure in
# plain text and then recovers is clean; a worker that only emits a
# recovery toolCall is filed.
write_session "git-branch-cannot-force-update-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_force2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-650 && git branch -f claim/issue-650 origin/main && git status 2>&1 | head -5 && git log --oneline -3"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_force2","toolName":"bash","isError":true,"content":[{"type":"text","text":"fatal: cannot force update the branch 'claim/issue-650' used by worktree at '/home/nish/workspaces/agent-worktrees/issue-fleet-ops-650'\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the git branch -f call failed with code 128 (fatal: cannot force update the branch 'claim/issue-650' — the branch is checked out in this worktree, so -f is refused). The recovery is to checkout a fresh branch from origin/main and cherry-pick the commit. It is now the blocker."},{"type":"toolCall","id":"call_recover2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-650 && git checkout -b tmp-clean origin/main 2>&1 | head -3 && git log --oneline -3"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged git branch -f in own worktree should be clean (got $count) $report"
ok "git branch -f in own worktree exit 128 plus later user-facing flag is clean"
rm -f "$sessions/git-branch-cannot-force-update-flagged.jsonl"

# --- 3. git push --force-with-lease to a branch checked out in the same worktree
# `git push --force-with-lease` to origin/<branch> when the local
# <branch> is checked out in this worktree produces a different
# message ("[remote rejected] ... branch is currently checked out")
# but the same class: a swallowed real failure on a force-push to a
# branch the worker cannot legally move. Pin the shape so a future
# refactor that broadens GIT_BENIGN_RE to swallow all `fatal:`
# exit-128 git output (instead of only the canonical ref-existence
# probe) is caught — that refactor would silence both the live #822
# and live #849 cases, both of which are real failures to flag.
write_session "git-push-force-to-checked-out" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_push","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-650 && git push --force-with-lease origin claim/issue-650 2>&1 | head -5"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_push","toolName":"bash","isError":true,"content":[{"type":"text","text":"To github.com:Nishfleet/fleet-ops.git\n ! [remote rejected] claim/issue-650 -> claim/issue-650 (deny updating a hidden ref)\nerror: failed to push some refs to 'github.com:Nishfleet/fleet-ops.git'\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_recover_push","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-650 && git log --oneline -3"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "git push --force-with-lease to checked-out branch exit 1 walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'remote rejected' <<<"$snippet" \
  || fail "finding snippet should mention 'remote rejected' (got $snippet)"
ok "git push --force-with-lease to checked-out branch exit 1 walked past is flagged"
rm -f "$sessions/git-push-force-to-checked-out.jsonl"

# --- 4. cross-check: git branch -f against a branch that ISN'T checked out
# The same `git branch -f` command, against a branch this worktree is
# not on, succeeds with exit 0 and is not flagged. The detector's
# `fatal: cannot force update the branch` exit-128 path is a real
# failure only when git refuses because of the worktree ownership;
# a successful force-update of a foreign branch is the contrast: same
# command, different cwd/checked-out state, exit 0. Pin it so a future
# refactor that broadens the suppression to ALL `git branch -f` exit-0
# is caught — that refactor would also silence the live #849 shape.
write_session "git-branch-force-foreign-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_foreign","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && git branch -f tmp-clean origin/main 2>&1 | head -3 && git log --oneline -3"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_foreign","toolName":"bash","isError":false,"content":[{"type":"text","text":"a468d9f fix(tests): align exec-review 4a/9a1 with the #728 lenient-colon canary (fleet-ops#622) (#941)\nfc77e3d test(p14): lock the #830 fleet-seat-recovery inline-verify re-breakage shape (#940)\n0caa450 test(p14-listing-gate): record #831 as duplicate-of-#824 closure (fleet-ops#831) (#939)\n"}}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Branch updated to origin/main. Continuing."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git branch -f against a foreign branch should be clean (got $count) $report"
ok "git branch -f against a foreign branch (not checked out here) is not flagged (contrast with #849)"
rm -f "$sessions/git-branch-force-foreign-ok.jsonl"

# --- 5. cross-check: git ref-existence probe is exempt (live #822) ----------
# Same `git ... <bad-ref>` exit-128 family, but the agent silenced
# stderr (`2>/dev/null`) and is testing whether a ref exists. That is
# the live #822 exemption: the canonical probe line is
# `fatal: ambiguous argument '<ref>'` (or `fatal: bad revision`) and
# the text carries NO other fatal. The live #849 shape carries a
# DIFFERENT fatal line — `cannot force update the branch` — which is
# NOT a probe, so it must NOT be exempt. Pin the contrast so a future
# refactor that broadens the suppression to any `fatal:` exit-128 is
# caught — that refactor would silence both the #822 probe AND the
# #849 swallowed failure, which is a real class of error to flag.
write_session "git-ref-probe-exempt-vs-849" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && git log --oneline -10 origin/claim/issue-518 2>/dev/null; echo '---'; git log --oneline -10 origin/claim/issue-99999 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n---\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"origin/claim/issue-518 is empty or does not exist. Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git ref-existence probe should stay exempt (got $count) $report"
ok "git ref-existence probe is exempt (contrast: live #849 fatal: cannot force update is NOT)"
rm -f "$sessions/git-ref-probe-exempt-vs-849.jsonl"

echo "OK: fleet-failed-command-git-branch-cannot-force-update: live #849 git branch -f in own worktree exit 128 drills"
