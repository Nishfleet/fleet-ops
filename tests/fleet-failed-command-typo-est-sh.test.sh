#!/usr/bin/env bash
# tests/fleet-failed-command-typo-est-sh.test.sh
#
# fleet-ops#1254: `bash tests/<lock-test>.est.sh` (truncated `.test.sh`
# typo) returns
#   bash: tests/<lock-test>.est.sh: No such file or directory
#   Command exited with code 127
# and the next assistant turn is a thinking-only "The path is wrong"
# plus a silent retry with the correct `.test.sh`. That is a real
# swallowed failure. There is no prior harness block, so the #677
# cascade exemption does not apply.
#
# The detector already flags this class via the generic
# `isError or code != 0` path. No `lib/failed-command-flagged.py`
# logic change is needed — a suppression would silence a real signal.
# The tempting future exemptions this file forbids:
#   - dropping the `had_prior_block` gate on the #677 127-ENOENT
#     cascade so ANY `bash <missing>` exit 127 is treated as a probe
#   - treating a truncated `.est.sh` / `.test.sh` typo as an existence
#     probe (like ls no-match)
#   - treating thinking-only "The path is wrong" as a user-facing flag
#   - letting a later successful `bash ... .test.sh` sibling discharge
#     the 127
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T16-16-10-880Z_01a04401-e880-7f21-b990-b20a28e67e9d.jsonl
# The worker on fleet-ops#1140 (worktree issue-fleet-ops-1140) ran
#   bash tests/fleet-failed-command-edit-unmatch.est.sh 2>&1
# got exit 127, then thought "The path is wrong. Let me use the full
# path." and retried
#   bash tests/fleet-failed-command-edit-unmatch.test.sh 2>&1
# which succeeded. Detector snippet:
#   bash: tests/fleet-failed-command-edit-unmatch.est.sh: No such file
#   or directory   Command exited with code 127
#
# Distinct from:
#   - #677: 127 ENOENT downstream of a harness block (spawn-guard
#     refused the heredoc that would have created the script). That
#     cascade is exempt. #1254 has no prior block.
#   - #793: `bash /tmp/<fresh-script>` exit 1 with `(no output)` — the
#     file existed; the script's set -e killed it.
#   - read-ENOENT (#651 / #953 / #1001 / #1059): `read` tool, no
#     `Command exited with code` line. The live #1254 session also
#     carried an earlier garbled-path read ENOENT
#     (`tesrs/fleet-ailed-command-edit-unmatch.est.sh`); that class is
#     already locked. This file pins the bash-127 `.est.sh` typo.
#   - ls no-match (#794): exit 2, canonical `ls: cannot access` line.
#
# Scenarios:
#   1. live #1254 shape: bash `.est.sh` 127 + thinking-only recovery
#      + silent `.test.sh` retry -> finding. Snippet must carry the
#      `.est.sh` path and `Command exited with code 127`.
#   2. same shape plus later thinking-only note -> still a finding.
#   3. same shape plus later unrelated user-facing prose that does NOT
#      name the failure -> still a finding.
#   4. same shape plus a later user-facing flag -> clean.
#   5. cross-check: the same `.est.sh` 127 AFTER a harness block stays
#      a #677 cascade (not a finding). Pins that locking #1254 must
#      not drop the `had_prior_block` gate.
#   6. worker.md cites fleet-ops#1254 and the live
#      `tests/fleet-failed-command-edit-unmatch.est.sh` wording
#      (prompt-side lock).
#   7. lib/failed-command-flagged.py docstring cites fleet-ops#1254
#      (detector-side lock).
#   8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"
worker="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-typo-est-sh.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T16:19:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T17:30:00Z"
}

# --- 1. live #1254 shape: typo `.est.sh` 127 walked past -------------------
# Replay slug 01a04401-e880: bash the truncated `.est.sh` name, get
# exit 127, next turn is thinking-only "The path is wrong" plus a
# silent retry of the real `.test.sh`.
write_session "typo-est-sh-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Let me verify the detector catches this exact session shape."},{"type":"toolCall","id":"call_est","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1140\nbash tests/fleet-failed-command-edit-unmatch.est.sh 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_est","toolName":"bash","content":[{"type":"text","text":"bash: tests/fleet-failed-command-edit-unmatch.est.sh: No such file or directory\n\n\nCommand exited with code 127"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The path is wrong. Let me use the full path."},{"type":"toolCall","id":"call_retry","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1140\nbash tests/fleet-failed-command-edit-unmatch.test.sh 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_retry","toolName":"bash","isError":false,"content":[{"type":"text","text":"OK: fleet-failed-command-edit-unmatch: live #956/#1079/#1053 edit unmatch drills\n"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1254 typo .est.sh 127 walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'fleet-failed-command-edit-unmatch.est.sh' <<<"$snippet" \
  || fail "finding snippet should mention the live .est.sh path (got $snippet)"
grep -q 'No such file or directory' <<<"$snippet" \
  || fail "finding snippet should mention No such file or directory (got $snippet)"
grep -q 'Command exited with code 127' <<<"$snippet" \
  || fail "finding snippet should mention Command exited with code 127 (got $snippet)"
ok "live #1254: typo .est.sh 127 with silent .test.sh retry is flagged"
rm -f "$sessions/typo-est-sh-walked.jsonl"

# --- 2. thinking-only recovery is still a finding --------------------------
write_session "typo-est-sh-thinking" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_est2","name":"bash","arguments":{"command":"bash tests/fleet-failed-command-edit-unmatch.est.sh 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_est2","toolName":"bash","content":[{"type":"text","text":"bash: tests/fleet-failed-command-edit-unmatch.est.sh: No such file or directory\n\n\nCommand exited with code 127"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The path is wrong. Let me use the full path."},{"type":"toolCall","id":"call_retry2","name":"bash","arguments":{"command":"bash tests/fleet-failed-command-edit-unmatch.test.sh 2>&1"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "typo .est.sh 127 with thinking-only recovery should be a finding (got $count) $report"
ok "live #1254: typo .est.sh 127 with later thinking-only recovery is still flagged"
rm -f "$sessions/typo-est-sh-thinking.jsonl"

# --- 3. later unrelated user-facing prose does not discharge ---------------
# FLAG_RE matches 'failed', so the prose must not contain that verb or
# the live recovery would be a false clean. The live session's earlier
# "fix(failed-command)" prose sat BEFORE the 127, not after.
write_session "typo-est-sh-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_est3","name":"bash","arguments":{"command":"bash tests/fleet-failed-command-edit-unmatch.est.sh 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_est3","toolName":"bash","content":[{"type":"text","text":"bash: tests/fleet-failed-command-edit-unmatch.est.sh: No such file or directory\n\n\nCommand exited with code 127"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The lock test already covers this class. Opening the PR next."},{"type":"toolCall","id":"call_retry3","name":"bash","arguments":{"command":"bash tests/fleet-failed-command-edit-unmatch.test.sh 2>&1"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "typo .est.sh 127 followed by unrelated prose should be a finding (got $count) $report"
ok "live #1254: typo .est.sh 127 with unrelated user-facing prose is still flagged"
rm -f "$sessions/typo-est-sh-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean ------------------
write_session "typo-est-sh-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_est4","name":"bash","arguments":{"command":"bash tests/fleet-failed-command-edit-unmatch.est.sh 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_est4","toolName":"bash","content":[{"type":"text","text":"bash: tests/fleet-failed-command-edit-unmatch.est.sh: No such file or directory\n\n\nCommand exited with code 127"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the bash tests/fleet-failed-command-edit-unmatch.est.sh call failed with exit 127 (No such file or directory). fixing."},{"type":"toolCall","id":"call_retry4","name":"bash","arguments":{"command":"bash tests/fleet-failed-command-edit-unmatch.test.sh 2>&1"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "typo .est.sh 127 with later user-facing flag should be clean (got $count) $report"
ok "typo .est.sh 127 plus later user-facing flag is clean"
rm -f "$sessions/typo-est-sh-flagged.jsonl"

# --- 5. cross-check: same `.est.sh` 127 AFTER a harness block stays #677 ---
# Locking #1254 must not drop the had_prior_block gate. A spawn-guard
# block, then bash of a missing `.est.sh`, is still a cascade.
write_session "typo-est-sh-after-block" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_blk","name":"bash","arguments":{"command":"cat > tests/fleet-failed-command-edit-unmatch.est.sh <<'EOF'\n#!/usr/bin/env bash\necho hi\nEOF"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_blk","toolName":"bash","isError":true,"content":[{"type":"text","text":"Dangerous command blocked (no UI for confirmation)"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_est5","name":"bash","arguments":{"command":"bash tests/fleet-failed-command-edit-unmatch.est.sh 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_est5","toolName":"bash","content":[{"type":"text","text":"bash: tests/fleet-failed-command-edit-unmatch.est.sh: No such file or directory\n\n\nCommand exited with code 127"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Switching approach."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "typo .est.sh 127 downstream of a harness block must stay a #677 cascade (got $count) $report"
ok "same .est.sh 127 after a harness block stays a #677 cascade (contrast with #1254)"
rm -f "$sessions/typo-est-sh-after-block.jsonl"

# --- 6. prompts/worker.md cites fleet-ops#1254 (prompt-side lock) -----------
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1254' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1254 (prompt-side lock)"
grep -q 'tests/fleet-failed-command-edit-unmatch.est.sh' "$worker" \
  || fail "prompts/worker.md must name the live 'tests/fleet-failed-command-edit-unmatch.est.sh' wording"
ok "worker.md cites fleet-ops#1254 and the live .est.sh wording"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#1254 -------
grep -q 'fleet-ops#1254' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1254 (detector-side lock)"
grep -q 'tests/fleet-failed-command-edit-unmatch.est.sh' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'tests/fleet-failed-command-edit-unmatch.est.sh' wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1254 and the .est.sh shape"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-typo-est-sh.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-typo-est-sh: live #1254 typo .est.sh 127 drills"
