#!/usr/bin/env bash
# tests/fleet-failed-command-git-cherry-pick-empty.test.sh
#
# fleet-ops#1065: a `git cherry-pick <sha>` command exits 1 with
# `isError: true` because the cherry-pick resulted in an empty commit
# (the change is already on the target). git prints
#   Auto-merging <path>
#   The previous cherry-pick is now empty, possibly due to conflict resolution.
#   If you wish to commit it anyway, use:
#       git commit --allow-empty
#   ...
#   Command exited with code 1
# The assistant walks past it with a thinking-only next turn (no
# user-facing text naming the failure). The detector already flags this
# class — the failure is `isError: true` + `Command exited with code 1`
# and `git cherry-pick` is NOT in the git-ref probe family
# (`GIT_BENIGN_RE` covers only `log|rev-parse|show|diff|cat-file|
# shortlog`), so neither `GIT_BENIGN_RE` nor `GIT_CANONICAL_NO_REF_RE`
# short-circuits it. This file locks the live #1065 shape so a future
# detector refactor cannot regress it (e.g. by broadening the git
# exemption to cover `cherry-pick`). No `lib/failed-command-flagged.py`
# change — a suppression would silence a real signal. The auto-filed
# issue closes via observe-to-close (fleet-ops#758) when the session
# mtime ages out of the 24h window.
#
# Live session: 2026-08-27T07-32-11-679Z_01a04222-2f1f-7823-9631-77df6b1ba95b.jsonl
# The agent ran
#   cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-943 \
#     && git cherry-pick 8ccae46 2>&1
# and got the empty-cherry-pick shape above, then continued with a
# thinking-only turn ("The cherry-pick says it's empty. That's because
# the test file might already have the change on origin/main? Let me
# check.") plus a `git log --oneline -1` toolCall — no user-facing text
# naming the failure.
#
# The class is distinct from the live #954 / #962 / #968 git-checkout
# worktree-conflict shape (exit 128, `fatal: 'main' is already used by
# worktree`) and the live #849 / #985 git-branch-force shape (exit 128,
# `fatal: cannot force update the branch`): those are exit 128 with a
# `fatal:` line; the cherry-pick empty shape is exit 1 with NO `fatal:`
# line. `git cherry-pick` is not in `GIT_BENIGN_RE`, so the exit-1 path
# (`is_benign_no_match` returns False for code != 1 unless the command
# matches `BENIGN_STAGE_RE`, which `git cherry-pick` does not) flags it
# directly. A future refactor that adds `cherry-pick` to `GIT_BENIGN_RE`
# (or to `BENIGN_STAGE_RE`) would silently suppress this real signal;
# this test pins that it does not.
#
# Scenarios:
#   1. live #1065 shape: `git cherry-pick <sha>` exit 1, isError=true,
#      "The previous cherry-pick is now empty", walked past with a
#      thinking-only + toolCall next turn -> finding. Snippet must carry
#      "previous cherry-pick is now empty" AND "Auto-merging" — both,
#      because dropping either is a regression in the snippet-capture
#      path.
#   2. same shape plus a later user-facing flag -> clean.
#   3. cross-check: a `git cherry-pick` that succeeds (clean, non-empty
#      cherry-pick) is exit 0, not flagged. Pin it so a future refactor
#      that flags ALL `git cherry-pick` (treating the command itself as
#      a failure signal) is caught.
#   4. cross-check: a `git log <bad-ref> 2>/dev/null` ref-existence
#      probe is the live #822 exemption — same git family, exit 128,
#      but the agent silenced stderr on purpose. That must stay exempt
#      while the cherry-pick empty shape (exit 1, no fatal) is flagged.
#      Pin the contrast so a future refactor that broadens the git
#      exemption to `cherry-pick` (and silences #1065) OR that broadens
#      the flag to `git log` probes (and silences #822) is caught.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-git-cherry-pick-empty.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T08:07:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T10:00:00Z"
}

# --- 1. live #1065 shape: git cherry-pick empty, exit 1, walked past -------
# The live session slug 01a04222 was filed because the agent ran
#   cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-943 && git cherry-pick 8ccae46 2>&1
# and got the empty-cherry-pick shape:
#   Auto-merging tests/fleet-failed-command-flagged.test.sh
#   The previous cherry-pick is now empty, possibly due to conflict resolution.
#   If you wish to commit it anyway, use:
#       git commit --allow-empty
#   ...
#   Command exited with code 1
# then continued with a thinking-only turn + a `git log --oneline -1`
# toolCall. Replay that exact shape.
write_session "git-cherry-pick-empty-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Now let me cherry-pick the fix commit 8ccae46."},{"type":"toolCall","id":"call_cp","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-943 && git cherry-pick 8ccae46 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cp","toolName":"bash","isError":true,"content":[{"type":"text","text":"Auto-merging tests/fleet-failed-command-flagged.test.sh\nThe previous cherry-pick is now empty, possibly due to conflict resolution.\nIf you wish to commit it anyway, use:\n\n    git commit --allow-empty\n\nOtherwise, please use 'git cherry-pick --skip'\nOn branch claim/issue-943\nYour branch is up to date with 'origin/main'.\n\nYou are currently cherry-picking commit 8ccae46.\n  (all conflicts fixed: run \"git cherry-pick --continue\")\n  (use \"git cherry-pick --skip\" to skip this patch)\n  (use \"git cherry-pick --abort\" to cancel the cherry-pick operation)\n\nnothing to commit, working tree clean\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The cherry-pick says it's empty. That's because the test file might already have the change on origin/main? Let me check."},{"type":"toolCall","id":"call_log","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-943 && git log --oneline -1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_log","toolName":"bash","isError":false,"content":[{"type":"text","text":"a8dd525 fix(tests): CI-safe no-agent-names rev range"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next check."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1065 git cherry-pick empty exit 1 walked past should be a finding (got $count) $report"
slug=$(jq -r '.findings[0].slug' <<<"$report")
[[ "$slug" == "git-cherry-pick-empty-walked" ]] || fail "finding slug should be git-cherry-pick-empty-walked (got $slug)"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# Pin the unique signals from the live #1065 toolResult so a future
# refactor that drops one of them is caught. The snippet is truncated
# to 200 chars; the leading "Auto-merging" + "previous cherry-pick is
# now empty" lines are the live #1065 fingerprint and fit in 200 chars.
grep -q "previous cherry-pick is now empty" <<<"$snippet" \
  || fail "finding snippet should mention 'previous cherry-pick is now empty' (got $snippet)"
grep -q "Auto-merging" <<<"$snippet" \
  || fail "finding snippet should mention 'Auto-merging' (got $snippet)"
ok "live #1065 git cherry-pick empty exit 1 walked past is flagged"
rm -f "$sessions/git-cherry-pick-empty-walked.jsonl"

# --- 2. same shape plus a later user-facing flag is clean -------------------
# The standing rule is satisfied when the assistant names the failure
# in the same turn's user-facing text. The detector must NOT flag this.
# Lock the contrast: a worker that names the empty-cherry-pick failure
# in plain text and then recovers is clean; a worker that only emits a
# thinking-only recovery toolCall is filed.
write_session "git-cherry-pick-empty-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cp2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-943 && git cherry-pick 8ccae46 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cp2","toolName":"bash","isError":true,"content":[{"type":"text","text":"Auto-merging tests/fleet-failed-command-flagged.test.sh\nThe previous cherry-pick is now empty, possibly due to conflict resolution.\nIf you wish to commit it anyway, use:\n\n    git commit --allow-empty\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the git cherry-pick 8ccae46 call failed with code 1 (the previous cherry-pick is now empty — the change is already on origin/main). Aborting the cherry-pick and moving on."},{"type":"toolCall","id":"call_abort","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-943 && git cherry-pick --abort 2>&1"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged git cherry-pick empty exit 1 should be clean (got $count) $report"
ok "git cherry-pick empty exit 1 plus later user-facing flag is clean"
rm -f "$sessions/git-cherry-pick-empty-flagged.jsonl"

# --- 3. cross-check: git cherry-pick that succeeds is not flagged ----------
# A `git cherry-pick <sha>` that applies cleanly succeeds with exit 0,
# and the toolResult has `isError: false` and no `Command exited with
# code` line. The detector must NOT flag it. Pin the contrast: same
# command, but a different git state, exit 0. A future refactor that
# treats every `git cherry-pick` toolResult as a failure signal (or
# that flags the word "cherry-pick" in any toolResult text) would
# silence the live #1065 swallowed failure AND flag a clean cherry-pick
# — both real shapes that must stay distinct.
write_session "git-cherry-pick-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ok","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-943 && git cherry-pick abcd123 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"[abcd123] fix(example): a real change\n Date: Thu Aug 27 12:00:00 2026 +0000\n 1 file changed, 1 insertion(+)\nSuccessfully applied."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Cherry-pick applied. Continuing."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git cherry-pick that succeeds should be clean (got $count) $report"
ok "git cherry-pick that succeeds (clean, non-empty) is not flagged (contrast with #1065)"
rm -f "$sessions/git-cherry-pick-ok.jsonl"

# --- 4. cross-check: git ref-existence probe is exempt (live #822) ---------
# Same git family, but the agent silenced stderr (`2>/dev/null`) and is
# testing whether a ref exists. That is the live #822 exemption: the
# canonical probe line is `fatal: ambiguous argument '<ref>'` (or
# `fatal: bad revision`), and the text carries NO other fatal. The live
# #1065 shape carries NO `fatal:` line at all (it is exit 1, not 128,
# and the text is the empty-cherry-pick notice). Pin the contrast so a
# future refactor that broadens the git exemption to `cherry-pick`
# (silencing #1065) OR that broadens the flag to `git log` probes
# (silencing #822) is caught.
write_session "git-ref-probe-exempt-vs-1065" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && git log --oneline -10 origin/claim/issue-99999 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"origin/claim/issue-99999 does not exist. Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git ref-existence probe should stay exempt (got $count) $report"
ok "git ref-existence probe is exempt (contrast: live #1065 cherry-pick empty exit 1 is NOT)"
rm -f "$sessions/git-ref-probe-exempt-vs-1065.jsonl"

# --- 5. worker.md cites fleet-ops#1065 (prompt-side lock) ------------------
# The prompt is the standing-rule contract for the next worker; dropping
# the #1065 citation is a regression even if the drill still passes.
worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1065' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1065 (prompt-side lock for the live cherry-pick empty shape)"
grep -q "previous cherry-pick is now empty" "$worker" \
  || fail "prompts/worker.md must name the live 'previous cherry-pick is now empty' wording so workers flag it"
grep -q "git cherry-pick" "$worker" \
  || fail "prompts/worker.md must name the live 'git cherry-pick' command so workers flag it"
ok "worker.md cites fleet-ops#1065 and the live cherry-pick empty wording"

# --- 6. lib/failed-command-flagged.py docstring cites fleet-ops#1065 -------
# (detector-side lock). The docstring is the standing-rule contract for
# the next detector maintainer; dropping the #1065 citation is a
# regression even if the drill still passes.
grep -q 'fleet-ops#1065' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1065 (detector-side lock)"
grep -q "previous cherry-pick is now empty" "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'previous cherry-pick is now empty' wording"
grep -q 'git cherry-pick' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'git cherry-pick' command"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1065 and the cherry-pick empty shape"

# --- 7. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-git-cherry-pick-empty.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-git-cherry-pick-empty: live #1065 git cherry-pick empty exit 1 drills"
