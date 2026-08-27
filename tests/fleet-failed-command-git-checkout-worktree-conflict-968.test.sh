#!/usr/bin/env bash
# tests/fleet-failed-command-git-checkout-worktree-conflict-968.test.sh
#
# fleet-ops#968: a `git checkout <branch>` command (or a compound
# `&&` chain whose tail is `git checkout <branch>`) fails because the
# target branch (`main`) is checked out in another worktree. git
# refuses with `fatal: '<branch>' is already used by worktree at
# '<path>'` and exits non-zero (typically 128). The assistant walks
# past it without naming the failure in user-facing text. The
# detector already flags this class (live #954 7h/7i, the dedicated
# #962 file) — the failure is `isError: true` + `Command exited with
# code N` and the fatal line is not a ref-existence probe (so neither
# `GIT_BENIGN_RE` nor `GIT_CANONICAL_NO_REF_RE` short-circuits it).
# This file locks the live #968 shape so a future detector refactor
# cannot regress it. No `lib/failed-command-flagged.py` change — a
# suppression would silence a real signal. The auto-filed issue
# closes via observe-to-close (fleet-ops#650) when the session mtime
# ages out of the 24h window.
#
# Live session: 2026-08-26T08-48-39-651Z_01a03d41-d4e3-70ae-9d9e-693beb93e54e.jsonl
# (the same origin session as #954, #949, and #962). The agent ran
# the compound command
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
# && ls scripts/...` (a toolCall only) with no user-facing text
# naming the failure. The session-close lint then auto-filed
# #762, #949, #954, #962, #968, #973, #978 — six duplicates of the
# same origin session — before the open-list dedup (PR #1021) landed.
# #762, #949, #954, and #962 are already closed; #968 is this PR's
# target. #973 and #978 are sibling duplicates tracked under
# separate fixes.
#
# The class is the same as the live #954 / #962 worktree-conflict
# shape, but #968 is its own auto-filed issue (same session, distinct
# filing under the same open-list-dedup gap) and gets its own
# dedicated regression test so a future refactor that drops the
# #968 citation from the detector docstring, the prompt, or the test
# host list is caught. The dedicated #962 file already pins the
# `git fetch origin && git checkout main && ls scripts/` &&-chain
# shape; this file adds the **`cd <worktree> && git checkout main`
# then `cd <deploy-clone> && ls`** standalone-then-recover shape
# that is also present in the same origin session as a SECOND
# worktree-conflict toolResult. The detector must catch BOTH
# shapes (the &&-chain prefix-with-fetch and the bare `git checkout
# main` after a `cd`) and emit the right snippet for each.
#
# Scenarios:
#   1. live #968 standalone shape: `cd <worktree> && git checkout main`
#      (no `git fetch` prefix, no `&&` chain into `ls`), exit 128,
#      walked past with a toolCall-only next turn -> finding. The
#      snippet must carry the fatal line AND "Command exited with
#      code 128" — both, because dropping either is a regression
#      in the snippet-capture path. The detector must NOT confuse
#      this shape with a `git log <bad-ref> 2>/dev/null` probe
#      (the live #822 exemption), because the fatal text is
#      `'main' is already used by worktree at`, not `ambiguous
#      argument` / `bad revision`.
#   2. live #968 next-turn `cd <deploy-clone> && ls scripts/` toolCall
#      (the `ls` itself returns a SEPARATE swallowed failure:
#      `ls: cannot access 'scripts/': No such file or directory`,
#      exit 2, but with `isError: false` because the `2>&1` redirect
#      captured the message and the shell exited the chain at the
#      ls-no-match stage). Pin it so a future detector refactor
#      that broadens the suppression to ALL `ls` exit 2 (including
#      the canonical "ls: cannot access" probe) does NOT silence
#      the worktree-conflict finding that came first in the same
#      session. The worktree-conflict toolResult is the finding;
#      the follow-up `ls scripts/` toolResult is a separate, clean
#      probe — they are TWO independent events in the same session.
#   3. same shape plus a later user-facing flag -> clean (the
#      standing rule, fleet-ops#535: name the failure in the same
#      turn's user-facing text, the recovery toolCall is fine).
#   4. cross-check: a `git checkout <branch>` that succeeds is
#      exit 0, not flagged. Pin the contrast: same command, but
#      a different git state. A future refactor that broadens the
#      suppression to ALL `git checkout` would silence both the
#      live #968 swallowed failure AND the live #822 probe — both
#      real shapes that must stay distinct.
#   5. cross-check: a `git log <bad-ref> 2>/dev/null` ref-existence
#      probe is the live #822 exemption — same command family,
#      exit 128, but the agent silenced stderr on purpose. That
#      must stay exempt while the live #968 worktree-conflict
#      shape is flagged. The fatal line for the probe is empty
#      (just "---" + blank), so the test pins the EMPTY-snippet
#      contrast against the live #968 NON-EMPTY snippet.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-git-checkout-worktree-968.XXXXXX)"
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

# --- 1. live #968 standalone `git checkout main` worktree-conflict ---------
# The live origin session has TWO worktree-conflict toolResults:
# the FIRST is the &&-chain `git fetch origin && git checkout main &&
# ls scripts/` (covered by the dedicated #962 file), the SECOND is
# a follow-up `cd <worktree> && git checkout main` after the agent
# tried to recover. Both fail with the same fatal line; both are
# isError + Command exited with code 128. Pin the SECOND shape
# here so a future refactor that ONLY catches the &&-chain-with-
# git-fetch-prefix shape (and treats the standalone `git checkout
# main` after a recovery cd as a probe) is caught.
write_session "git-checkout-worktree-conflict-968-standalone" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_co","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-54 && git checkout main 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_co","toolName":"bash","isError":true,"content":[{"type":"text","text":"fatal: 'main' is already used by worktree at '/home/nish/workspaces/tooling/fleet-ops'\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_recover","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops && ls 2>&1 | head -20"}}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #968 standalone git checkout worktree conflict exit 128 walked past should be a finding (got $count) $report"
slug=$(jq -r '.findings[0].slug' <<<"$report")
[[ "$slug" == "git-checkout-worktree-conflict-968-standalone" ]] || fail "finding slug should be git-checkout-worktree-conflict-968-standalone (got $slug)"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# Pin the unique signals from the live #968 standalone toolResult so
# a future refactor that drops one of them is caught. The snippet
# is truncated to 200 chars; the trailing "Command exited with
# code 128" is the line most likely to be cut, so check the unique
# prefix signals (the worktree-conflict fingerprint) instead.
grep -q "already used by worktree at" <<<"$snippet" \
  || fail "finding snippet should mention 'already used by worktree at' (got $snippet)"
grep -q "main'" <<<"$snippet" \
  || fail "finding snippet should mention the 'main' branch name (got $snippet)"
grep -q "Command exited with code 128" <<<"$snippet" \
  || fail "finding snippet should mention 'Command exited with code 128' (got $snippet)"
# The live #968 standalone shape has NO "From github.com..." prefix
# (the &&-chain's git fetch prefix is in the OTHER toolResult, not
# this one). Pin the negative: the snippet must NOT carry the
# &&-chain's "From https://github.com" line, because that would
# mean the detector mixed the two toolResults in the same session.
# A future refactor that always emits the full session snippet
# (across multiple toolResults) would fail this check.
if grep -q "From https://github.com" <<<"$snippet"; then
  fail "finding snippet should NOT carry 'From https://github.com' (the &&-chain's git fetch line is in the OTHER toolResult, not this one): $snippet"
fi
ok "live #968 standalone git checkout worktree conflict exit 128 walked past is flagged"
rm -f "$sessions/git-checkout-worktree-conflict-968-standalone.jsonl"

# --- 2. live #968 follow-up `ls scripts/` after the worktree-conflict -------
# In the live origin session, the agent's next turn after the
# worktree-conflict toolResult was `cd /home/nish/workspaces/tooling/
# fleet-ops && ls scripts/ 2>&1 | head -20`. The `ls scripts/`
# toolResult is a SEPARATE event with `isError: false` and
# `ls: cannot access 'scripts/': No such file or directory` + exit 2
# (the canonical ls-no-match probe family). It is NOT a finding —
# the worktree-conflict toolResult that came before it is the
# finding. Pin it so a future detector refactor that broadens the
# ls exit 2 suppression to ANY `ls` toolResult (including the
# `ls scripts/` after a `cd <deploy-clone>`) does NOT silence the
# earlier worktree-conflict finding AND does NOT introduce a false
# positive for the clean `ls` event. The worktree-conflict
# toolResult (scenario 1) is the only finding; the `ls scripts/`
# is a separate, clean event.
write_session "git-checkout-worktree-conflict-968-with-ls-probe" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_co2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-54 && git checkout main 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_co2","toolName":"bash","isError":true,"content":[{"type":"text","text":"fatal: 'main' is already used by worktree at '/home/nish/workspaces/tooling/fleet-ops'\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ls","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops && ls scripts/ 2>&1 | head -20"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ls","toolName":"bash","isError":false,"content":[{"type":"text","text":"ls: cannot access 'scripts/': No such file or directory\n\nCommand exited with code 2"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #968 worktree conflict + follow-up ls scripts/ probe should produce ONE finding (the worktree conflict), not zero or two (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q "already used by worktree at" <<<"$snippet" \
  || fail "the single finding should be the worktree conflict (got snippet: $snippet)"
# The follow-up `ls scripts/` probe must NOT have been registered
# as a separate finding. The detector's ls-no-match exemption
# (canonical 'ls: cannot access' line) is the right call here.
ok "live #968 worktree conflict + follow-up ls scripts/ probe = ONE finding (the worktree conflict), ls probe is exempt"
rm -f "$sessions/git-checkout-worktree-conflict-968-with-ls-probe.jsonl"

# --- 3. same shape plus a later user-facing flag is clean -------------------
# The standing rule (fleet-ops#535) is satisfied when the assistant
# names the failure in the same turn's user-facing text. The detector
# must NOT flag this. Lock the contrast: a worker that names the
# worktree-conflict failure in plain text and then recovers is
# clean; a worker that only emits a recovery toolCall is filed.
write_session "git-checkout-worktree-conflict-968-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_co3","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-54 && git checkout main 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_co3","toolName":"bash","isError":true,"content":[{"type":"text","text":"fatal: 'main' is already used by worktree at '/home/nish/workspaces/tooling/fleet-ops'\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the git checkout main call failed with code 128 (fatal: 'main' is already used by worktree at /home/nish/workspaces/tooling/fleet-ops — main is checked out in the deploy-clone worktree). Falling back to a temp branch."},{"type":"toolCall","id":"call_recover3","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-54 && git checkout -b main-temp origin/main 2>&1 | head"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged standalone git checkout worktree conflict should be clean (got $count) $report"
ok "standalone git checkout worktree conflict exit 128 plus later user-facing flag is clean"
rm -f "$sessions/git-checkout-worktree-conflict-968-flagged.jsonl"

# --- 4. cross-check: git checkout that succeeds is not flagged ------------
# A `git checkout <branch>` whose target is NOT checked out
# elsewhere succeeds with exit 0, and the toolResult has
# `isError: false` and no `Command exited with code` line. The
# detector must NOT flag it. Pin the contrast: same command, but
# a different git state, exit 0. A future refactor that broadens
# the suppression to ALL `git checkout` (or that treats every
# `fatal:` line in a `git checkout` toolResult as a probe) would
# silence both the live #968 swallowed failure AND the live #822
# probe — both real shapes that must stay distinct.
write_session "git-checkout-ok-968" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ok","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-54 && git checkout -b temp-branch origin/main 2>&1 | head -3"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"Switched to a new branch 'temp-branch'\nbranch 'temp-branch' set up to track 'origin/main'.\n"}}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Branched. Continuing."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git checkout that succeeds should be clean (got $count) $report"
ok "git checkout that succeeds (new branch from origin) is not flagged (contrast with #968)"
rm -f "$sessions/git-checkout-ok-968.jsonl"

# --- 5. cross-check: git ref-existence probe is exempt (live #822) ----------
# Same exit-128 family, but the agent silenced stderr
# (`2>/dev/null`) and is testing whether a ref exists. That is
# the live #822 exemption: the canonical probe line is
# `fatal: ambiguous argument '<ref>'` (or `fatal: bad revision`),
# and the text carries NO other fatal. The live #968 shape carries
# a DIFFERENT fatal line — `'main' is already used by worktree at` —
# which is NOT a probe, so it must NOT be exempt. Pin the contrast
# so a future refactor that broadens the suppression to any
# `fatal:` exit-128 is caught — that refactor would silence both
# the #822 probe AND the #968 swallowed failure, both of which are
# real failures to flag.
write_session "git-ref-probe-exempt-vs-968" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && git log --oneline -10 origin/claim/issue-518 2>/dev/null; echo '---'; git log --oneline -10 origin/claim/issue-99999 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n---\n\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"origin/claim/issue-518 is empty or does not exist. Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git ref-existence probe should stay exempt (got $count) $report"
ok "git ref-existence probe is exempt (contrast: live #968 fatal: 'main' is already used by worktree is NOT)"
rm -f "$sessions/git-ref-probe-exempt-vs-968.jsonl"

echo "OK: fleet-failed-command-git-checkout-worktree-conflict-968: live #968 standalone git checkout main worktree-conflict exit 128 drills"
