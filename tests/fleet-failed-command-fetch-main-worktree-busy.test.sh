#!/usr/bin/env bash
# tests/fleet-failed-command-fetch-main-worktree-busy.test.sh
#
# fleet-ops#949: a worker inside an issue worktree runs
#   cd <wrong-path> && git fetch origin 2>&1 | head -20
# where `<wrong-path>` is a worktree (or a symlink to one) that has
# already checked out `main`. `git fetch` itself is fine, but the path
# is itself another worktree, so the worker gets the side-effect
#   fatal: 'main' is already used by worktree at '/path/to/other-wt'
# (exit 128) and the next assistant turn is a recovery toolCall against
# the right path, with no user-facing text naming the failure.
#
# The detector already flags this class: the toolResult is
# `isError: true` + `Command exited with code 128` + a `fatal:`
# line. The command text does NOT match `GIT_BENIGN_RE` (the
# ref-existence probe exemption is `git log|rev-parse|show|diff|
# cat-file`, not `git fetch`). The fatal line is not in
# `GIT_CANONICAL_NO_REF_RE` and contains no canonical probe marker,
# so it falls through the "any fatal: is a real error" branch. This
# file locks the live #949 shape so a future detector refactor cannot
# regress it. No `lib/failed-command-flagged.py` change — a
# suppression would silence a real signal. The auto-filed issue
# closes via observe-to-close (fleet-ops#758) when the session mtime
# ages out of the 24h window after 2026-08-26T08:48:39Z.
#
# Live session: 2026-08-26T08-48-39-651Z_01a03d41-d4e3-70ae-9d9e-693beb93e54e.jsonl
# The agent (working on issue-fleet-ops-54) ran, from a worktree
# already on `claim/issue-54`, the same recovery script it ran for the
# previous failure class:
#   cd /home/nish/workspaces/products/fleet-ops && git fetch origin 2>&1 | head -20
# `/home/nish/workspaces/products/fleet-ops` is a symlink to
# `/home/nish/workspaces/tooling/fleet-ops` (the pre-rewrite worktree
# parent), which has `main` checked out. git returned
#   From https://github.com/Nishfleet/fleet-ops
#      ed0c3b1..013f8b7  main       -> origin/main
#   fatal: 'main' is already used by worktree at
#   '/home/nish/workspaces/tooling/fleet-ops'
# (exit 128) and the agent's next turn was a
# `cd /home/nish/workspaces/tooling/fleet-ops && git log --oneline -1`
# recovery toolCall with only a thinking-block reason and no
# user-facing text naming the failure.
#
# Scenarios:
#   1. live #949 shape: cd <already-checked-out-wt> && git fetch origin
#      exit 128 walked past -> finding. Snippet must carry the
#      "is already used by worktree at" + "Command exited with code 128"
#      signal.
#   2. same shape plus a later user-facing flag -> clean.
#   3. cross-check: `git fetch` against the canonical deploy-clone
#      (where `main` is checked out in a worktree that is NOT this
#      one) succeeds with exit 0 and is not flagged.
#   4. cross-check: `git log <bad-ref> 2>/dev/null` ref-existence
#      probe is the live #822 exemption — same command family, exit
#      128, but the agent silenced stderr on purpose. That must stay
#      exempt while the #949 worktree-busy shape is flagged.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-fetch-main-wt.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-26T08:50:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T05:00:00Z"
}

# --- 1. live #949 shape: git fetch from a worktree that already owns main
# The live session slug 01a03d41-d4e3-... was filed because the agent ran
#   cd /home/nish/workspaces/products/fleet-ops && git fetch origin 2>&1 | head -20
# where `products/fleet-ops` was a symlink to a worktree that had
# `main` checked out. git returned
#   From https://github.com/Nishfleet/fleet-ops
#      ed0c3b1..013f8b7  main       -> origin/main
#   fatal: 'main' is already used by worktree at
#   '/home/nish/workspaces/tooling/fleet-ops'
# followed by `Command exited with code 128`, then the agent
# recovered with a `cd /home/nish/workspaces/tooling/fleet-ops && git
# log --oneline -1` toolCall and only a thinking-block reason — no
# user-facing text naming the worktree-busy failure. Replay that
# exact shape.
write_session "git-fetch-main-worktree-busy" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_fetch","name":"bash","arguments":{"command":"cd /home/nish/workspaces/products/fleet-ops && git fetch origin 2>&1 | head -20"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_fetch","toolName":"bash","isError":true,"content":[{"type":"text","text":"fatal: 'main' is already used by worktree at '/home/nish/workspaces/tooling/fleet-ops'\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_recover","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops && git log --oneline -1 2>&1 | head"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_recover","toolName":"bash","isError":false,"content":[{"type":"text","text":"c4f3d6c P14: GitHub App fleet identity replaces fine-grained PAT for workers (#16)"}}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_followup","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-54 && git status 2>&1 | head -3 && git log --oneline -3 2>&1 | head"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #949 git fetch from a worktree that owns main walked past should be a finding (got $count) $report"
slug=$(jq -r '.findings[0].slug' <<<"$report")
[[ "$slug" == "git-fetch-main-worktree-busy" ]] || fail "finding slug should be git-fetch-main-worktree-busy (got $slug)"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# The snippet is the first 200 chars of the toolResult text. The live
# #949 toolResult was the fetch progress line + the "is already used
# by worktree at" fatal + "Command exited with code 128". Pin all
# three so a future refactor that drops one of them is caught — this
# is the class-prevention rule from fleet-ops#366.
grep -q 'is already used by worktree at' <<<"$snippet" \
  || fail "finding snippet should mention 'is already used by worktree at' (got $snippet)"
grep -q "'main'" <<<"$snippet" \
  || fail "finding snippet should mention the branch name 'main' (got $snippet)"
grep -q 'Command exited with code 128' <<<"$snippet" \
  || fail "finding snippet should mention 'Command exited with code 128' (got $snippet)"
ok "live #949 git fetch from a worktree that already owns main exit 128 walked past is flagged"
rm -f "$sessions/git-fetch-main-worktree-busy.jsonl"

# --- 2. same shape plus a later user-facing flag is clean -------------------
# The standing rule is satisfied when the assistant names the failure
# in the same turn's user-facing text. The detector must NOT flag
# this. Lock the contrast: a worker that flags the worktree-busy
# failure in plain text and then recovers is clean; a worker that
# only emits a recovery toolCall is filed.
write_session "git-fetch-main-worktree-busy-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_fetch2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/products/fleet-ops && git fetch origin 2>&1 | head -20"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_fetch2","toolName":"bash","isError":true,"content":[{"type":"text","text":"fatal: 'main' is already used by worktree at '/home/nish/workspaces/tooling/fleet-ops'\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the git fetch call failed with code 128 (fatal: 'main' is already used by worktree at /home/nish/workspaces/tooling/fleet-ops — products/fleet-ops is a symlink to the canonical deploy-clone, which has main checked out, so fetch inside it cannot move main). The recovery is to fetch from a worktree that does NOT own main. It is now the blocker."},{"type":"toolCall","id":"call_recover2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops && git log --oneline -1 2>&1 | head"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged git fetch from a worktree that owns main should be clean (got $count) $report"
ok "git fetch from a worktree that owns main exit 128 plus later user-facing flag is clean"
rm -f "$sessions/git-fetch-main-worktree-busy-flagged.jsonl"

# --- 3. cross-check: git fetch from a worktree that does NOT own main
# The detector's "is already used by worktree at" exit-128 path is a
# real failure only when git refuses because the path resolves to a
# worktree that already has the same branch checked out. A `git fetch`
# from any other worktree (one that has only a feature branch
# checked out) succeeds with exit 0 even if the repo's `main`
# ref-availability is unchanged. Pin the contrast so a future
# refactor that broadens the suppression to ALL `git fetch` exit-0 is
# caught — that refactor would silence the live #949 shape too,
# which is a real class of error to flag.
write_session "git-fetch-feature-worktree-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_fetch_ok","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-949 && git fetch origin 2>&1 | head -5 && git log --oneline -3 2>&1 | head"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_fetch_ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"79b13cf fix(auto-revert): mint nishfleet-worker App token, replacing under-scoped PAT for workers (#1012)\n16f0cdb fix(verify-harness-canary): re-check origin default-branch HEAD before filing (fleet-ops#927) (#1008)\n46b0d61 fix(failed-command): search closed issues and guard observe-to-close on in-flight sessions (fleet-ops#933) (#1007)"}}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Fetch from a feature-branch worktree succeeded. Continuing."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git fetch from a feature-branch worktree should be clean (got $count) $report"
ok "git fetch from a feature-branch worktree (not the one that owns main) is not flagged (contrast with #949)"
rm -f "$sessions/git-fetch-feature-worktree-ok.jsonl"

# --- 4. cross-check: git ref-existence probe is exempt (live #822) ----------
# Same `git ... <bad-ref>` exit-128 family, but the agent silenced
# stderr (`2>/dev/null`) and is testing whether a ref exists. That is
# the live #822 exemption: the canonical probe line is
# `fatal: ambiguous argument '<ref>'` (or `fatal: bad revision`) and
# the text carries NO other fatal. The live #949 shape carries a
# DIFFERENT fatal line — `is already used by worktree at` — which is
# NOT a probe, so it must NOT be exempt. Pin the contrast so a future
# refactor that broadens the suppression to any `fatal:` exit-128 is
# caught — that refactor would silence both the #822 probe AND the
# #949 swallowed failure, which is a real class of error to flag.
write_session "git-ref-probe-exempt-vs-949" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-949 && git log --oneline -10 origin/claim/issue-518 2>/dev/null; echo '---'; git log --oneline -10 origin/claim/issue-99999 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n---\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"origin/claim/issue-518 is empty or does not exist. Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git ref-existence probe should stay exempt (got $count) $report"
ok "git ref-existence probe is exempt (contrast: live #949 fatal: 'is already used by worktree at' is NOT)"
rm -f "$sessions/git-ref-probe-exempt-vs-949.jsonl"

echo "OK: fleet-failed-command-fetch-main-worktree-busy: live #949 git fetch from a worktree that owns main exit 128 drills"
