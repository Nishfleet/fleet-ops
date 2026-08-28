#!/usr/bin/env bash
# tests/fleet-failed-command-git-push-stale-info.test.sh
#
# fleet-ops#1188: a `git push origin <branch> --force-with-lease` (or a
# plain `git push` that hits a stale remote ref) command exits 1 with
# `isError: true` and the canonical git output
#   To https://github.com/Nishfleet/fleet-ops.git
#    ! [rejected]        ram-governor-20260827 -> ram-governor-20260827 (stale info)
#   error: failed to push some refs to 'https://github.com/Nishfleet/fleet-ops.git'
#   Command exited with code 1
# The assistant walks past it with a `git fetch` recovery toolCall plus
# a later `git push -f` (no user-facing text naming the failure) and
# finally an unrelated `gh pr list` toolCall. The next user-facing text
# after the failure is on a different topic ("Now deploy the console
# fix.") so the failure was swallowed.
#
# The class is distinct from the #954 / #962 / #968 git-checkout
# worktree-conflict shape (exit 128, `fatal: 'main' is already used by
# worktree`) and the #849 / #985 git-branch-force shape (exit 128,
# `fatal: cannot force update the branch`) and the #1065 git-cherry-pick
# empty shape (exit 1, no fatal, "The previous cherry-pick is now
# empty"). The #1188 push-stale-info shape is exit 1 with NO `fatal:`
# line, but the visible `! [rejected] ... (stale info)` plus `error:
# failed to push some refs` lines are unmistakable. `git push` is not
# in `GIT_BENIGN_RE` (which covers only `log|rev-parse|show|diff|
# cat-file|shortlog`) and not in `BENIGN_STAGE_RE`, so the exit-1 path
# (`is_benign_no_match` returns False for code != 1 unless the command
# matches `BENIGN_STAGE_RE`) flags it directly. A future refactor that
# adds `push` to `GIT_BENIGN_RE` (or to `BENIGN_STAGE_RE`) would
# silently suppress this real signal; this file pins that it does not.
# The auto-filed issue closes via observe-to-close (fleet-ops#758)
# when the session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T14-56-27-448Z_01a043b8-eb38-7261-b685-a9c004370fbb.jsonl
# The agent ran
#   echo "=== pushing ram-governor-20260827 ==="; \
#     git -C ~/workspaces/fleet-ops-rg push origin ram-governor-20260827 --force-with-lease 2>&1
# and got the (stale info) shape above, then continued with a
# `git fetch origin ram-governor-20260827` toolCall and a
# `git push origin ram-governor-20260827 -f` toolCall plus an
# unrelated `gh pr list` toolCall — no user-facing text naming the
# failure.
#
# Scenarios:
#   1. live #1188 shape: `git push ... --force-with-lease` exit 1,
#      isError=true, "[rejected] ... (stale info)" + "failed to push
#      some refs", walked past with a `git fetch` recovery toolCall ->
#      finding. Snippet must carry the "(stale info)" wording AND the
#      "failed to push some refs" wording — both, because dropping
#      either is a regression in the snippet-capture path.
#   2. same shape plus a later user-facing flag -> clean.
#   3. cross-check: a successful `git push` (new branch, no stale ref)
#      is exit 0, not flagged. Pin it so a future refactor that flags
#      ALL `git push` toolResults (treating the command itself as a
#      failure signal) is caught.
#   4. cross-check: a `git push --force-with-lease` that succeeds (the
#      force-lease check passes) is exit 0, not flagged. Same family
#      but a different git state. A future refactor that treats every
#      `git push` toolResult as a failure signal would silence the
#      live #1188 swallowed failure AND flag a clean force-lease push
#      — both real shapes that must stay distinct.
#   5. cross-check: a `git log <bad-ref> 2>/dev/null` ref-existence
#      probe is the live #822 exemption — same git family, exit 128,
#      but the agent silenced stderr on purpose. That must stay exempt
#      while the push-stale-info shape (exit 1, no fatal) is flagged.
#      Pin the contrast so a future refactor that broadens the git
#      exemption to `push` (silencing #1188) OR that broadens the flag
#      to `git log` probes (silencing #822) is caught.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-git-push-stale-info.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T15:10:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T16:00:00Z"
}

# --- 1. live #1188 shape: git push --force-with-lease stale-info, exit 1,
#       walked past with a `git fetch` recovery toolCall -----------------
# The live session slug 01a043b8 was filed because the agent ran
#   echo "=== pushing ram-governor-20260827 ==="; \
#     git -C ~/workspaces/fleet-ops-rg push origin ram-governor-20260827 --force-with-lease 2>&1
# and got the (stale info) shape:
#   To https://github.com/Nishfleet/fleet-ops.git
#    ! [rejected]        ram-governor-20260827 -> ram-governor-20260827 (stale info)
#   error: failed to push some refs to 'https://github.com/Nishfleet/fleet-ops.git'
#   Command exited with code 1
# then continued with a `git fetch origin ram-governor-20260827`
# toolCall and a `git push -f` toolCall — no user-facing text naming
# the failure. The next user-facing text was on an unrelated topic
# ("Now deploy the console fix."). Replay that exact shape.
write_session "git-push-stale-info-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_push","name":"bash","arguments":{"command":"echo \"=== pushing ram-governor-20260827 ===\"; git -C ~/workspaces/fleet-ops-rg push origin ram-governor-20260827 --force-with-lease 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_push","toolName":"bash","isError":true,"content":[{"type":"text","text":"=== pushing ram-governor-20260827 ===\nTo https://github.com/Nishfleet/fleet-ops.git\n ! [rejected]        ram-governor-20260827 -> ram-governor-20260827 (stale info)\nerror: failed to push some refs to 'https://github.com/Nishfleet/fleet-ops.git'\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_fetch","name":"bash","arguments":{"command":"git -C ~/workspaces/fleet-ops-rg fetch origin ram-governor-20260827 2>&1; echo \"---\"; git -C ~/workspaces/fleet-ops-rg log --oneline origin/ram-governor-20260827 -3 2>&1; echo \"---\"; git -C ~/workspaces/fleet-ops-rg log --oneline ram-governor-20260827 -3 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_fetch","toolName":"bash","isError":false,"content":[{"type":"text","text":"From https://github.com/Nishfleet/fleet-ops\n * branch            ram-governor-20260827 -> FETCH_HEAD"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_force","name":"bash","arguments":{"command":"git -C ~/workspaces/fleet-ops-rg push origin ram-governor-20260827 -f 2>&1"}}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now deploy the console fix."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1188 git push --force-with-lease stale info exit 1 walked past should be a finding (got $count) $report"
slug=$(jq -r '.findings[0].slug' <<<"$report")
[[ "$slug" == "git-push-stale-info-walked" ]] || fail "finding slug should be git-push-stale-info-walked (got $slug)"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# Pin the unique signals from the live #1188 toolResult so a future
# refactor that drops one of them is caught. The snippet is truncated
# to 200 chars; the leading "[rejected] ... (stale info)" + "failed to
# push some refs" lines are the live #1188 fingerprint and fit in 200
# chars.
grep -q "stale info" <<<"$snippet" \
  || fail "finding snippet should mention 'stale info' (got $snippet)"
grep -q "failed to push some refs" <<<"$snippet" \
  || fail "finding snippet should mention 'failed to push some refs' (got $snippet)"
ok "live #1188 git push --force-with-lease stale info exit 1 walked past is flagged"
rm -f "$sessions/git-push-stale-info-walked.jsonl"

# --- 2. same shape plus a later user-facing flag is clean ----------------
# The standing rule is satisfied when the assistant names the failure
# in the same turn's user-facing text. The detector must NOT flag this.
# Lock the contrast: a worker that names the stale-info push failure in
# plain text and then recovers is clean; a worker that only emits
# recovery toolCalls and later unrelated prose is filed.
write_session "git-push-stale-info-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_push2","name":"bash","arguments":{"command":"git push origin ram-governor-20260827 --force-with-lease 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_push2","toolName":"bash","isError":true,"content":[{"type":"text","text":"To https://github.com/Nishfleet/fleet-ops.git\n ! [rejected]        ram-governor-20260827 -> ram-governor-20260827 (stale info)\nerror: failed to push some refs to 'https://github.com/Nishfleet/fleet-ops.git'\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the git push --force-with-lease call failed with code 1 (stale info — the remote ref moved). Fetching the remote ref and retrying."},{"type":"toolCall","id":"call_fetch2","name":"bash","arguments":{"command":"git fetch origin ram-governor-20260827 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_fetch2","toolName":"bash","isError":false,"content":[{"type":"text","text":"From https://github.com/Nishfleet/fleet-ops\n * branch            ram-governor-20260827 -> FETCH_HEAD"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"OK, fetched. Retrying push."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged git push --force-with-lease stale info should be clean (got $count) $report"
ok "git push --force-with-lease stale info exit 1 plus later user-facing flag is clean"
rm -f "$sessions/git-push-stale-info-flagged.jsonl"

# --- 3. cross-check: successful git push (new branch) is not flagged ------
# A `git push origin <new-branch>` that creates the branch cleanly
# succeeds with exit 0 and the toolResult has `isError: false` and no
# `Command exited with code` line. The detector must NOT flag it. Pin
# the contrast: same `git push` command, but a different git state,
# exit 0. A future refactor that treats every `git push` toolResult
# as a failure signal (or that flags the word "stale info" in any
# toolResult text, even successful ones) would silence the live #1188
# swallowed failure AND flag a clean push — both real shapes that
# must stay distinct.
write_session "git-push-new-branch-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ok","name":"bash","arguments":{"command":"git push origin feature-branch 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"To https://github.com/Nishfleet/fleet-ops.git\n * [new branch]      feature-branch -> feature-branch"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Branch pushed. Continuing."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git push new branch (success) should be clean (got $count) $report"
ok "git push new branch (success) is not flagged (contrast with #1188)"
rm -f "$sessions/git-push-new-branch-ok.jsonl"

# --- 4. cross-check: successful git push --force-with-lease is not flagged
# A `git push origin <branch> --force-with-lease` that succeeds (the
# lease check passes) succeeds with exit 0 and the toolResult has
# `isError: false`. Same command, different git state. The detector
# must NOT flag it. Pin the contrast: a future refactor that treats
# every `git push --force-with-lease` toolResult as a failure signal
# would silence the live #1188 swallowed failure AND flag a clean
# force-lease push — both real shapes that must stay distinct.
write_session "git-push-force-with-lease-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_ok2","name":"bash","arguments":{"command":"git push origin feature-branch --force-with-lease 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ok2","toolName":"bash","isError":false,"content":[{"type":"text","text":"To https://github.com/Nishfleet/fleet-ops.git\n + deadbeef...1234567 feature-branch -> feature-branch (forced update)"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Force-lease push succeeded. Continuing."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git push --force-with-lease (success) should be clean (got $count) $report"
ok "git push --force-with-lease (success) is not flagged (contrast with #1188)"
rm -f "$sessions/git-push-force-with-lease-ok.jsonl"

# --- 5. cross-check: git ref-existence probe is exempt (live #822) ------
# Same git family, but the agent silenced stderr (`2>/dev/null`) and is
# testing whether a ref exists. That is the live #822 exemption: the
# canonical probe line is `fatal: ambiguous argument '<ref>'` (or
# `fatal: bad revision`), and the text carries NO other fatal. The live
# #1188 shape carries NO `fatal:` line at all (it is exit 1, not 128,
# and the text is the (stale info) rejection notice). Pin the contrast
# so a future refactor that broadens the git exemption to `push`
# (silencing #1188) OR that broadens the flag to `git log` probes
# (silencing #822) is caught.
write_session "git-ref-probe-exempt-vs-1188" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && git log --oneline -10 origin/claim/issue-99999 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 128"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"origin/claim/issue-99999 does not exist. Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "git ref-existence probe should stay exempt (got $count) $report"
ok "git ref-existence probe is exempt (contrast: live #1188 push stale info exit 1 is NOT)"
rm -f "$sessions/git-ref-probe-exempt-vs-1188.jsonl"

# --- 6. worker.md cites fleet-ops#1188 (prompt-side lock) ----------------
# The prompt is the standing-rule contract for the next worker; dropping
# the #1188 citation is a regression even if the drill still passes.
worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1188' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1188 (prompt-side lock for the live push stale-info shape)"
grep -q "stale info" "$worker" \
  || fail "prompts/worker.md must name the live 'stale info' wording so workers flag it"
grep -q "git push" "$worker" \
  || fail "prompts/worker.md must name the live 'git push' command so workers flag it"
ok "worker.md cites fleet-ops#1188 and the live push stale-info wording"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#1188 -----
# (detector-side lock). The docstring is the standing-rule contract for
# the next detector maintainer; dropping the #1188 citation is a
# regression even if the drill still passes.
grep -q 'fleet-ops#1188' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1188 (detector-side lock)"
grep -q "stale info" "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'stale info' wording"
grep -q 'git push' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'git push' command"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1188 and the push stale-info shape"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ----
grep -Fq 'bash "$here/fleet-failed-command-git-push-stale-info.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-git-push-stale-info: live #1188 git push stale info exit 1 drills"
