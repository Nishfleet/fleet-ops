#!/usr/bin/env bash
# tests/fleet-failed-command-git-checkout-worktree-conflict.test.sh
#
# fleet-ops#962: a `git checkout <branch>` command (or a compound
# `&&` chain whose tail is `git checkout <branch>`) fails because the
# target branch (`main`) is checked out in another worktree. git refuses
# with `fatal: '<branch>' is already used by worktree at '<path>'` and
# exits non-zero (typically 128). The assistant walks past it without
# naming the failure in user-facing text. The detector already flags
# this class — the failure is `isError: true` + `Command exited with
# code N` and the fatal line is not a ref-existence probe (so neither
# `GIT_BENIGN_RE` nor `GIT_CANONICAL_NO_REF_RE` short-circuits it).
# This file locks the live #962 shape so a future detector refactor
# cannot regress it. No `lib/failed-command-flagged.py` change — a
# suppression would silence a real signal. The auto-filed issue closes
# via observe-to-close (fleet-ops#758) when the session mtime ages out
# of the 24h window.
#
# Live session: 2026-08-26T08-48-39-651Z_01a03d41-d4e3-70ae-9d9e-693beb93e54e.jsonl
# (the same origin session as #954 and #949; the dedup regression is
# tracked separately under #1071). The agent ran the compound command
#   cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-54 \
#     && git fetch origin \
#     && git checkout main \
#     && ls scripts/ 2>&1 | head -20
# The `git fetch` prefix succeeded (printing "From github.com ..." +
# "ed0c3b1..013f8b7  main       -> origin/main"), but `git checkout
# main` failed with exit 128 because `main` was already checked out
# in /home/nish/workspaces/tooling/fleet-ops. The toolResult was
#   From https://github.com/Nishfleet/fleet-ops
#      ed0c3b1..013f8b7  main       -> origin/main
#   fatal: 'main' is already used by worktree at '/home/nish/workspaces/tooling/fleet-ops'
#   Command exited with code 128
# The agent's next turn was `cd /home/nish/workspaces/tooling/fleet-ops
# && ls scripts/...` (a toolCall only) with no user-facing text naming
# the failure.
#
# The class is the same as the live #954 / #949 worktree-conflict
# shape, but #962 is its own auto-filed issue (same session, distinct
# slug) and gets its own dedicated regression test so a future
# refactor that drops the #962 citation from the detector docstring,
# the prompt, or the test host list is caught. The detector already
# flags this in `result_failed` (live #954 7h/7i in
# `tests/fleet-failed-command-flagged.test.sh`); the gap is the
# dedicated file so the class is named in three places (test, prompt,
# detector docstring), not one.
#
# Scenarios:
#   1. live #962 shape: compound `&&` chain with a successful `git
#      fetch` prefix and a failing `git checkout main` tail, exit
#      128, walked past with a toolCall-only next turn -> finding.
#      Snippet must carry the "From github.com..." prefix AND the
#      "fatal: 'main' is already used by worktree at" line AND
#      "Command exited with code 128" — all three, because dropping
#      any one of them is a regression in the snippet-capture path.
#   2. same shape plus a later user-facing flag -> clean.
#   3. `git checkout` alone (no `&&` chain) with worktree conflict —
#      same fatal shape, same detector verdict. Pin it so a future
#      refactor that ONLY special-cases the &&-chain shape (and not
#      the standalone `git checkout` shape) is caught.
#   4. cross-check: a `git checkout <branch>` that succeeds (the
#      branch is NOT checked out elsewhere) is exit 0, not flagged.
#      Pin it so a future refactor that broadens the suppression to
#      ALL `git checkout` exit-128 is caught.
#   5. cross-check: a `git log <bad-ref> 2>/dev/null` ref-existence
#      probe is the live #822 exemption — same command family, exit
#      128, but the agent silenced stderr on purpose. That must
#      stay exempt while the worktree-conflict shape is flagged.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-git-checkout-worktree.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-26T08:48:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-26T10:00:00Z"
}

# --- 1. live #962 shape: &&-chain with successful git fetch prefix and -------
#      failing git checkout main tail, exit 128, walked past -----------------
# The live session slug 01a03d41 was filed because the agent ran the
# compound `cd <worktree> && git fetch origin && git checkout main && ls ...`
# and got:
#   From https://github.com/Nishfleet/fleet-ops
#      ed0c3b1..013f8b7  main       -> origin/main
#   fatal: 'main' is already used by worktree at '/home/nish/workspaces/tooling/fleet-ops'
# followed by `Command exited with code 128`, then continued with a
# toolCall-only next turn. Replay that exact shape.
write_session "git-checkout-worktree-conflict-andchain" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_chain","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-54 && git fetch origin && git checkout main && ls scripts/ 2>&1 | head -20"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_chain","toolName":"bash","isError":true,"content":[{"type":"text","text":"From https://github.com/Nishfleet/fleet-ops\n   ed0c3b1..013f8b7  main       -> origin/main\nfatal: 'main' is already used by worktree at '/home/nish/workspaces/tooling/fleet-ops'\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_recover","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops && ls scripts/ 2>&1 | head -20"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_recover","toolName":"bash","isError":false,"content":[{"type":"text","text":"ls: cannot access 'scripts/': No such file or directory\n\nCommand exited with code 2"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"On to the next check."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #962 &&-chain with successful git fetch prefix and failing git checkout main tail walked past should be a finding (got $count) $report"
slug=$(jq -r '.findings[0].slug' <<<"$report")
[[ "$slug" == "git-checkout-worktree-conflict-andchain" ]] || fail "finding slug should be git-checkout-worktree-conflict-andchain (got $slug)"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# Pin the unique signals from the live #962 toolResult so a future
# refactor that drops one of them is caught. The snippet is
# truncated to 200 chars, so the trailing "Command exited with
# code 128" is the line that gets cut; check the unique prefix
# signals instead (the prefix is the live #962 fingerprint).
grep -q 'From https://github.com/Nishfleet/fleet-ops' <<<"$snippet" \
  || fail "finding snippet should mention 'From https://github.com/Nishfleet/fleet-ops' (got $snippet)"
grep -q 'ed0c3b1..013f8b7' <<<"$snippet" \
  || fail "finding snippet should mention the 'ed0c3b1..013f8b7 main -> origin/main' fetch line (got $snippet)"
grep -q "already used by worktree at" <<<"$snippet" \
  || fail "finding snippet should mention 'already used by worktree at' (got $snippet)"
grep -q "main'" <<<"$snippet" \
  || fail "finding snippet should mention the 'main' branch name (got $snippet)"
ok "live #962 &&-chain (successful git fetch prefix + failing git checkout main tail, exit 128) walked past is flagged"
rm -f "$sessions/git-checkout-worktree-conflict-andchain.jsonl"

# --- 2. same shape plus a later user-facing flag is clean -------------------
# The standing rule is satisfied when the assistant names the failure
# in the same turn's user-facing text. The detector must NOT flag
# this. Lock the contrast: a worker that names the worktree-conflict
# failure in plain text and then recovers is clean; a worker that
# only emits a recovery toolCall is filed.
write_session "git-checkout-worktree-conflict-andchain-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_chain2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-54 && git fetch origin && git checkout main && ls scripts/ 2>&1 | head -20"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_chain2","toolName":"bash","isError":true,"content":[{"type":"text","text":"From https://github.com/Nishfleet/fleet-ops\n   ed0c3b1..013f8b7  main       -> origin/main\nfatal: 'main' is already used by worktree at '/home/nish/workspaces/tooling/fleet-ops'\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the git checkout main call failed with code 128 (fatal: 'main' is already used by worktree at /home/nish/workspaces/tooling/fleet-ops — main is checked out in the deploy-clone worktree). Falling back to a temp branch."},{"type":"toolCall","id":"call_recover2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-54 && git checkout -b main-temp origin/main 2>&1 | head"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged &&-chain git checkout worktree conflict should be clean (got $count) $report"
ok "&&-chain git checkout worktree conflict exit 128 plus later user-facing flag is clean"
rm -f "$sessions/git-checkout-worktree-conflict-andchain-flagged.jsonl"

# --- 3. standalone `git checkout` with worktree conflict --------------------
# The same fatal shape, but the command is just `git checkout main`
# (no `&&` chain, no successful `git fetch` prefix). The agent ran
# `git checkout main` directly, and git refused because main is
# checked out in another worktree. Pin it so a future refactor that
# ONLY catches the &&-chain shape (because it relies on the
# "From github.com..." prefix to trigger detection) is caught. The
# detector must catch the standalone `git checkout` shape too —
# the `fatal: 'main' is already used by worktree` line is itself
# the failure signal, regardless of what came before.
write_session "git-checkout-worktree-conflict-standalone" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_co","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-54 && git checkout main 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_co","toolName":"bash","isError":true,"content":[{"type":"text","text":"fatal: 'main' is already used by worktree at '/home/nish/workspaces/tooling/fleet-ops'\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_log","name":"bash","arguments":{"command":"git log --oneline -3 2>&1"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "standalone git checkout worktree conflict exit 128 walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# The standalone shape has no "From github.com..." prefix, so the
# snippet is shorter and the full "fatal: 'main' is already used
# by worktree at '<path>'" line is in the snippet. Pin it.
grep -q "already used by worktree at" <<<"$snippet" \
  || fail "finding snippet should mention 'already used by worktree at' (got $snippet)"
grep -q "main'" <<<"$snippet" \
  || fail "finding snippet should mention the 'main' branch name (got $snippet)"
ok "standalone git checkout worktree conflict exit 128 walked past is flagged"
rm -f "$sessions/git-checkout-worktree-conflict-standalone.jsonl"

# --- 4. cross-check: git checkout that succeeds is not flagged ------------
# A `git checkout <branch>` whose target is NOT checked out
# elsewhere succeeds with exit 0, and the toolResult has
# `isError: false` and no `Command exited with code` line. The
# detector must NOT flag it. Pin the contrast: same command, but
# a different git state, exit 0. A future refactor that broadens
# the suppression to ALL `git checkout` (or that treats every
# `fatal:` line in a `git checkout` toolResult as a probe) would
# silence both the live #962 swallowed failure AND the live #822
# probe — both real shapes that must stay distinct.
write_session "git-checkout-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ok","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-54 && git checkout -b temp-branch origin/main 2>&1 | head -3"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"Switched to a new branch 'temp-branch'\nbranch 'temp-branch' set up to track 'origin/main'.\n"}}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Branched. Continuing."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git checkout that succeeds should be clean (got $count) $report"
ok "git checkout that succeeds (new branch from origin) is not flagged (contrast with #962)"
rm -f "$sessions/git-checkout-ok.jsonl"

# --- 5. cross-check: git ref-existence probe is exempt (live #822) ----------
# Same exit-128 family, but the agent silenced stderr
# (`2>/dev/null`) and is testing whether a ref exists. That is
# the live #822 exemption: the canonical probe line is
# `fatal: ambiguous argument '<ref>'` (or `fatal: bad revision`),
# and the text carries NO other fatal. The live #962 shape carries
# a DIFFERENT fatal line — `'main' is already used by worktree at` —
# which is NOT a probe, so it must NOT be exempt. Pin the contrast
# so a future refactor that broadens the suppression to any
# `fatal:` exit-128 is caught — that refactor would silence both
# the #822 probe AND the #962 swallowed failure, both of which are
# real failures to flag.
write_session "git-ref-probe-exempt-vs-962" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && git log --oneline -10 origin/claim/issue-518 2>/dev/null; echo '---'; git log --oneline -10 origin/claim/issue-99999 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n---\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"origin/claim/issue-518 is empty or does not exist. Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git ref-existence probe should stay exempt (got $count) $report"
ok "git ref-existence probe is exempt (contrast: live #962 fatal: 'main' is already used by worktree is NOT)"
rm -f "$sessions/git-ref-probe-exempt-vs-962.jsonl"

echo "OK: fleet-failed-command-git-checkout-worktree-conflict: live #962 git checkout main worktree-conflict exit 128 drills"
