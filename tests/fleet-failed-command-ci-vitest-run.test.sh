#!/usr/bin/env bash
# tests/fleet-failed-command-ci-vitest-run.test.sh
#
# fleet-ops#4933: verification test commands that fail because the
# product worktree has no installed dependencies are real swallowed
# failures. The live 0509 reviewer session 2026-09-10T10-44-02 ran
# `npm test -- tests/pricing.test.ts` (which drives
# scripts/ci-vitest-run.sh) and got
#   ./scripts/ci-vitest-run.sh: line 57: vitest: command not found
#   ci-vitest-run: suite failed with exit 127
#   Command exited with code 127
# then tried `npx vitest run ... --project node tests/pricing.test.ts`
# and got
#   Error: Cannot find module '@react-router/dev/vite' imported from
#   .../vite.config.ts
# (both isError=true). The reviewer walked past BOTH failures — no
# user-facing flag — and the session ended without delivering a review
# verdict. The snippet the detector filed was the ci-vitest-run 127:
#   > 0509@0.1.0 test > bash ./scripts/ci-vitest-run.sh -- vitest run
#   --configLoader runner --project node
#
# `vitest: command not found` (exit 127) is NOT a grep/rg/diff/which
# no-match probe and NOT an ls no-match probe: the test suite silently
# could not run. `Cannot find module` is likewise a real failure. The
# detector already flags this class via the generic `isError or
# code != 0` path. No `lib/failed-command-flagged.py` logic change is
# needed — a suppression would silence a real signal (a reviewer who
# cannot run the suite must say so, not walk into the void). The
# tempting future exemptions this file forbids:
#   - treating `vitest: command not found` / exit 127 as a "dependency
#     not installed" probe, on the theory that a verify command that
#     cannot run is innocuous
#   - treating `Cannot find module` (a missing top-level dep in a
#     verify run) as benign
#   - treating a thinking-only "let me try npx instead" as a flag of
#     the first failure, or a successful later verify as discharging
#     the earlier 127
#   - exempting reviewer sessions (any agent role) from the flag
#     contract
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window.
#
# Live session: 2026-09-10T10-44-02-253Z_01a08aea-da4d-789b-af53-fed178b63056.jsonl
# (0509 issue-2309 review worktree; no node_modules installed).
#
# Distinct from:
#   - #677 (127 ENOENT downstream of a harness block, exempt when a
#     prior block exists), and #1254 (a `bash <missing>.est.sh` typo).
#   - read-ENOENT and EISDIR (no `Command exited with code` line in
#     the toolResult).
#   - grep/rg/diff/which no-match exit 1 (BENIGN_STAGE_RE).
#
# Scenarios:
#   1. live #4933 shape: `npm test` (ci-vitest-run) 127 walked past
#      without a flag, next turn a different `npx vitest` verify also
#      fails -> finding. Snippet must carry `vitest: command not found`
#      and `Command exited with code 127`.
#   2. same shape with a thinking-only "let me try npx" in between ->
#      still a finding (thinking is not a user-facing flag).
#   3. same shape plus later unrelated user-facing prose that does not
#      name the failure -> still a finding.
#   4. same shape plus a later user-facing flag -> clean.
#   5. cross-check: an `npm test` run that SUCCEEDS (no failure) is not
#      a finding (guards the probe/test-command framing).
#   6. lib/failed-command-flagged.py cites fleet-ops#4933 and the live
#      `ci-vitest-run.sh` / `vitest: command not found` wording
#      (detector-side lock).
#   7. lib/failed-command-flagged.py docstring cites fleet-ops#4933
#      (detector-side lock).
#   8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-ci-vitest.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-09-10T11:50:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-09-10T12:10:00Z"
}

# --- 1. live #4933 shape: ci-vitest-run 127 walked past, then a second
# verify (npx vitest) also fails, both un-flagged -------------------------
write_session "ci-vitest-run-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_v1","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-0509-2309 && npm test -- tests/pricing.test.ts 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_v1","toolName":"bash","content":[{"type":"text","text":"\n> 0509@0.1.0 test\n> bash ./scripts/ci-vitest-run.sh -- vitest run --configLoader runner --project node && bash ./scripts/ci-vitest-run.sh -- vitest run --configLoader runner --project workers tests/pricing.test.ts\n\nci-vitest-run: attempt 1/2: vitest run --configLoader runner --project node\n./scripts/ci-vitest-run.sh: line 57: vitest: command not found\nci-vitest-run: suite failed with exit 127 (not a worker startup timeout; not retrying)\n\n\nCommand exited with code 127"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_v2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-0509-2309 && npx vitest run --configLoader runner --project node tests/pricing.test.ts 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_v2","toolName":"bash","content":[{"type":"text","text":"failed to load config from /home/nish/workspaces/agent-worktrees/issue-0509-2309/vite.config.ts\n\n⎯⎯⎯⎯⎯⎯⎯ Startup Error ⎯⎯⎯⎯⎯⎯⎯⎯\nError: Cannot find module '@react-router/dev/vite' imported from '/home/nish/workspaces/agent-worktrees/issue-0509-2309/vite.config.ts'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The diff touches pricing-section.tsx, pricing.test.ts, and stripe-checkout.route.test.ts."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #4933 ci-vitest-run 127 + npx vitest failure walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'ci-vitest-run.sh' <<<"$snippet" \
  || fail "finding snippet should mention the failing ci-vitest-run.sh command (got $snippet)"
ok "live #4933: ci-vitest-run/npx-vitest verify failures walked past are flagged"
rm -f "$sessions/ci-vitest-run-walked.jsonl"

# --- 2. thinking-only recovery between the failures is not a flag -------
write_session "ci-vitest-run-thinking" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_t1","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-0509-2309 && npm test -- tests/pricing.test.ts 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_t1","toolName":"bash","content":[{"type":"text","text":"> 0509@0.1.0 test\n> bash ./scripts/ci-vitest-run.sh -- vitest run --configLoader runner --project node\n\nci-vitest-run: attempt 1/2: vitest run --configLoader runner --project node\n./scripts/ci-vitest-run.sh: line 57: vitest: command not found\nci-vitest-run: suite failed with exit 127\n\n\nCommand exited with code 127"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Dependencies are not installed, let me try npx vitest instead."},{"type":"toolCall","id":"call_t2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-0509-2309 && npx vitest run --configLoader runner --project node tests/pricing.test.ts 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_t2","toolName":"bash","content":[{"type":"text","text":"Error: Cannot find module '@react-router/dev/vite'"}],"details":{},"isError":true}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "ci-vitest-run 127 with thinking-only recovery should be a finding (got $count) $report"
ok "live #4933: thinking-only 'let me try npx' does not flag the ci-vitest-run 127"
rm -f "$sessions/ci-vitest-run-thinking.jsonl"

# --- 3. unrelated user-facing prose does not discharge -------------------
# FLAG_RE matches 'failed', so the prose must avoid that verb.
write_session "ci-vitest-run-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_p1","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-0509-2309 && npm test -- tests/pricing.test.ts 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_p1","toolName":"bash","content":[{"type":"text","text":"> 0509@0.1.0 test\n> bash ./scripts/ci-vitest-run.sh -- vitest run --configLoader runner --project node\n\n./scripts/ci-vitest-run.sh: line 57: vitest: command not found\n\n\nCommand exited with code 127"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Let me review the pricing-section.tsx diff and open the PR next."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "ci-vitest-run 127 followed by unrelated prose should be a finding (got $count) $report"
ok "live #4933: ci-vitest-run 127 with unrelated user-facing prose is still flagged"
rm -f "$sessions/ci-vitest-run-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean ----------------
write_session "ci-vitest-run-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_f1","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-0509-2309 && npm test -- tests/pricing.test.ts 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_f1","toolName":"bash","content":[{"type":"text","text":"> 0509@0.1.0 test\n> bash ./scripts/ci-vitest-run.sh -- vitest run --configLoader runner --project node\n\n./scripts/ci-vitest-run.sh: line 57: vitest: command not found\nci-vitest-run: suite failed with exit 127\n\n\nCommand exited with code 127"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the npm test call failed with exit 127 — vitest is not installed in this worktree. I cannot run the verify suite here."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "ci-vitest-run 127 with a later user-facing flag should be clean (got $count) $report"
ok "live #4933: ci-vitest-run 127 plus a later user-facing flag is clean"
rm -f "$sessions/ci-vitest-run-flagged.jsonl"

# --- 5. cross-check: a SUCCESSFUL test run is not a finding --------------
write_session "ci-vitest-run-success" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_s1","name":"bash","arguments":{"command":"cd /home/nish/workspaces/agent-worktrees/issue-0509-2309 && npm test -- tests/pricing.test.ts 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_s1","toolName":"bash","content":[{"type":"text","text":"> 0509@0.1.0 test\n> bash ./scripts/ci-vitest-run.sh -- vitest run --configLoader runner --project node\n\n ✓ tests/pricing.test.ts (1) 123ms\n\n Test Files  1 passed (1)      Tests  1 passed (1)"}],"details":{},"isError":false}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "a successful npm test run should not be a finding (got $count) $report"
ok "successful test run is clean"

# --- 6. lib/failed-command-flagged.py cites fleet-ops#4933 and the live
# ci-vitest-run wording (detector-side lock) ------------------------------
grep -q 'fleet-ops#4933' "$lib" \
  || fail "lib/failed-command-flagged.py must cite fleet-ops#4933 (detector-side lock)"
grep -q 'ci-vitest-run' "$lib" \
  || fail "lib/failed-command-flagged.py must name the live 'ci-vitest-run' wording"
ok "lib/failed-command-flagged.py cites fleet-ops#4933 and the ci-vitest-run wording"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#4933 -----
grep -q 'fleet-ops#4933' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#4933 (detector-side lock)"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#4933"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -----
grep -Fq 'bash "$here/fleet-failed-command-ci-vitest-run.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-ci-vitest-run: live #4933 ci-vitest-run 127 verify-failure drills"