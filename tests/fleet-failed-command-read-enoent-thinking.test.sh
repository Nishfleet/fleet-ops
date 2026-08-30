#!/usr/bin/env bash
# tests/fleet-failed-command-read-enoent-thinking.test.sh
#
# fleet-ops#953: a `read` tool result with
#   "ENOENT: no such file or directory, access '<path>'"
# is a real failure. It is not a probe like ls no-match, and it is not
# the #651 offset-beyond-end negative result. The live wording is
# `ENOENT: no such file or directory, access '<path>'` with isError=true,
# details={}, and no "Command exited with code" line — distinct from the
# #651 fixture text "Failed to read ...: No such file or directory".
#
# The live session (2026-08-26T14-02-29-714Z) issued three parallel
# toolCalls (ls, a successful read, and read of OVERNIGHT.md). OVERNIGHT.md
# returned ENOENT. The next assistant turns were `thinking` plus more
# toolCalls, then later unrelated user-facing prose ("Now I have the full
# picture. Let me plan and execute.") that never named the failure.
# A thinking block is not a user-facing flag (fleet-ops#535). Later
# unrelated prose that moves on is not a flag either (same class as #936).
#
# A future detector refactor must not:
#   - treat the live `ENOENT: ... access '<path>'` wording as an ls-style
#     probe (the #651 "Failed to read" fixture would still pass)
#   - let `_text_chunks` collecting `thinking` fields discharge the class
#   - let any later user-facing text clear a pending failure
#
# The auto-filed issue closes via observe-to-close (fleet-ops#758) when
# the session mtime ages out of the 24h window after 2026-08-26T14:02:29Z.
#
# Live session: 2026-08-26T14-02-29-714Z_01a03e61-27d2-7c3f-9101-da19c90f6ba5.jsonl
#
# fleet-ops#1001 is a sibling read-ENOENT shape on a DIFFERENT session
# slug (2026-08-27T05-15-24-019Z_01a041a4-...). The worker was building
# the completion-canary from a stale, non-canonical checkout
# (`/home/nish/workspaces/fleet-ops-sync/`) that does not carry
# `bin/fleet-escalation-canary`, and tried to read it. The live wording
# is identical to #953, but the recovery pattern is different: a
# `thinking`-only `ls ~/.local/bin/*canary*` (which DOES list the live
# symlink that resolves to the canonical
# `/home/nish/workspaces/tooling/fleet-ops-deploy-clone/bin/...`) and
# later "Now I have a clear picture" prose. A future detector refactor
# must not:
#   - treat the canonical `~/.local/bin/` symlink as a probe
#     (the live `ls` returned real output, not a no-match)
#   - treat a successful `ls` of the right file at the wrong path
#     as discharging the read-ENOENT of the wrong file
#   - let "Now I have a clear picture" prose clear a pending swallowed
#     failure (same class as the #953 / #958 sibling shape)
#
# Scenarios:
#   1. live #953 shape: parallel sibling calls + ENOENT + thinking-only
#      recovery -> finding.
#   2. same shape plus later unrelated user-facing prose ("Now I have the
#      full picture") that does NOT name the failure -> still a finding.
#   3. same shape plus a later "the OVERNIGHT.md read failed" flag -> clean.
#   4. live #1001 shape: stale-checkout read ENOENT + ls ~/.local/bin
#      finding the right file at the right symlink + later "clear
#      picture" prose that does NOT name the failure -> finding.
#   5. worker.md cites fleet-ops#953 (prompt-side lock).
#   6. worker.md cites fleet-ops#1001 (prompt-side lock for the
#      stale-checkout read-ENOENT class).
#   7. lib/failed-command-flagged.py docstring cites fleet-ops#1001.
#   8. seat-lib.test.sh hosts this file (CI cannot gain a new workflow line).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-read-enoent-thinking.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-26T14:02:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-26T14:30:00Z"
}

# --- 1. live #953 shape: parallel siblings + ENOENT + thinking-only --------
# The live session issued ls + a successful read + read of OVERNIGHT.md
# in one turn. OVERNIGHT.md returned isError=true with the live ENOENT
# wording, details={}, and no "Command exited with code" line. The next
# turn was a thinking block plus recovery toolCalls and no user-facing
# text. Replay that exact shape.
write_session "read-enoent-thinking-only" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me read the context files first."},{"type":"toolCall","id":"call_ls","name":"bash","arguments":{"command":"ls ~/workspaces/agent-state/ 2>/dev/null | head -30"}},{"type":"toolCall","id":"call_intake","name":"read","arguments":{"path":"/home/nish/workspaces/tooling/fleet-ops-deploy-clone/config/intake-repos.json"}},{"type":"toolCall","id":"call_overnight","name":"read","arguments":{"path":"/home/nish/workspaces/agent-state/OVERNIGHT.md"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ls","toolName":"bash","isError":false,"content":[{"type":"text","text":"AUDITOR-LOG.md\nFLEET-HEARTBEAT-TRIAGE.md\nlanes"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_intake","toolName":"read","isError":false,"content":[{"type":"text","text":"{\"repos\":[]}"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_overnight","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/agent-state/OVERNIGHT.md'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"OVERNIGHT.md is missing. Let me look elsewhere."},{"type":"toolCall","id":"call_find","name":"bash","arguments":{"command":"find /home/nish/workspaces/agent-state -maxdepth 2 -iname \"OVERNIGHT*\" 2>/dev/null"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #953 read ENOENT with thinking-only recovery should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'ENOENT: no such file or directory, access' <<<"$snippet" \
  || fail "finding snippet should mention live ENOENT wording (got $snippet)"
grep -q 'OVERNIGHT.md' <<<"$snippet" \
  || fail "finding snippet should mention OVERNIGHT.md (got $snippet)"
ok "live #953: read ENOENT with parallel siblings and thinking-only recovery is flagged"
rm -f "$sessions/read-enoent-thinking-only.jsonl"

# --- 2. later unrelated user-facing prose does not discharge ---------------
# The live session's first user-facing text was "Now I have the full
# picture. Let me plan and execute." — that does not name the failure.
# Same class as #936's 6j: real user-facing text that moves on without
# naming the failure must NOT clear the pending swallowed failure.
write_session "read-enoent-unrelated-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_overnight2","name":"read","arguments":{"path":"/home/nish/workspaces/agent-state/OVERNIGHT.md"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_overnight2","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/agent-state/OVERNIGHT.md'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Missing. Continue."},{"type":"toolCall","id":"call_find2","name":"bash","arguments":{"command":"find /home/nish/workspaces/agent-state -maxdepth 2 -iname \"OVERNIGHT*\" 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_find2","toolName":"bash","isError":false,"content":[{"type":"text","text":""}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now I have the full picture. Let me plan and execute."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "read ENOENT followed by unrelated prose should be a finding (got $count) $report"
ok "live #953: read ENOENT with later 'Now I have the full picture' prose is still flagged"
rm -f "$sessions/read-enoent-unrelated-prose.jsonl"

# --- 3. same shape plus a later user-facing flag is clean ------------------
write_session "read-enoent-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_overnight3","name":"read","arguments":{"path":"/home/nish/workspaces/agent-state/OVERNIGHT.md"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_overnight3","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/agent-state/OVERNIGHT.md'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the OVERNIGHT.md read failed with ENOENT — the AGENTS.md reference is dangling, it is now the blocker."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "read ENOENT with later user-facing flag should be clean (got $count) $report"
ok "read ENOENT plus later user-facing flag is clean"
rm -f "$sessions/read-enoent-flagged.jsonl"

# --- 4. live #1001: stale-checkout read ENOENT + canonical ls + prose -----
# The 01a041a4 completion-canary build session tried to read
# `/home/nish/workspaces/fleet-ops-sync/bin/fleet-escalation-canary` —
# a stale, non-canonical checkout that does not carry the file. It got
# the live `ENOENT: no such file or directory, access '<path>'` shape.
# Its next recovery turn was a thinking-only `ls ~/.local/bin/*canary*`
# that DID return the canonical symlink (a successful ls is not a
# discharge for a separate read-ENOENT), and later
# "Now I have a clear picture of what already exists" prose that does
# NOT name the failure. This must still be a finding: a successful
# read of the right file at the right symlink in the SAME turn that
# saw a read-ENOENT at the wrong file does not discharge the
# read-ENOENT, and "clear picture" prose is the same unrelated-prose
# class as the #953 / #958 sibling shape.
write_session "read-enoent-stale-checkout" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me read the existing escalation canary to understand what's already been built."},{"type":"toolCall","id":"call_canary_read","name":"read","arguments":{"path":"/home/nish/workspaces/fleet-ops-sync/bin/fleet-escalation-canary"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_canary_read","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/fleet-ops-sync/bin/fleet-escalation-canary'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The stale checkout doesn't have the file. Let me find where it actually lives."},{"type":"toolCall","id":"call_ls_local","name":"bash","arguments":{"command":"ls -la /home/nish/.local/bin/*canary* /home/nish/.local/bin/*escalation* /home/nish/.local/bin/*completion* 2>/dev/null"}},{"type":"toolCall","id":"call_ls_systemd","name":"bash","arguments":{"command":"ls -la /home/nish/.config/systemd/user/*canary* /home/nish/.config/systemd/user/*escalation* /home/nish/.config/systemd/user/*completion* 2>/dev/null"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ls_local","toolName":"bash","isError":false,"content":[{"type":"text","text":"lrwxrwxrwx 1 nish nish 80 Aug 27 10:47 /home/nish/.local/bin/fleet-escalation-canary -> /home/nish/workspaces/tooling/fleet-ops-deploy-clone/bin/fleet-escalation-canary"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_ls_systemd","toolName":"bash","isError":true,"content":[{"type":"text","text":""}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now I have a clear picture of what already exists. Let me plan and execute."},{"type":"toolCall","id":"call_todo1","name":"todo","arguments":{"action":"add","text":"Pin canary in stale-checkout map","id":1}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1001 read ENOENT with canonical ls + 'clear picture' prose should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'ENOENT: no such file or directory, access' <<<"$snippet" \
  || fail "finding snippet should mention live ENOENT wording (got $snippet)"
grep -q 'fleet-escalation-canary' <<<"$snippet" \
  || fail "finding snippet should mention fleet-escalation-canary (got $snippet)"
ok "live #1001: stale-checkout read ENOENT + canonical ls + 'clear picture' prose is flagged"
rm -f "$sessions/read-enoent-stale-checkout.jsonl"

# --- 5. worker.md cites fleet-ops#953 (prompt-side lock) -------------------
worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#953' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#953 (prompt-side lock for the live ENOENT wording)"
grep -q "ENOENT: no such file or directory, access" "$worker" \
  || fail "prompts/worker.md must name the live ENOENT wording so workers flag it"
ok "worker.md cites fleet-ops#953 and the live ENOENT wording"

# --- 6. worker.md cites fleet-ops#1001 (prompt-side lock) ------------------
# The 01a041a4 session's read-ENOENT is a sibling shape on a different
# session slug (a stale, non-canonical checkout). Dropping the #1001
# citation from the prompt is a regression even if the #953 lock and
# the live #1001 drill still pass.
grep -q 'fleet-ops#1001' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1001 (prompt-side lock for the stale-checkout read-ENOENT class)"
grep -q 'fleet-escalation-canary' "$worker" \
  || fail "prompts/worker.md must name the live #1001 path so workers flag the stale-checkout shape"
ok "worker.md cites fleet-ops#1001 and the live stale-checkout path"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#1001 -------
# The lib docstring is the standing-rule contract for the next detector
# maintainer. The same three-place pattern as the prompt + CI host:
# prompt, lib docstring, and the test that runs in CI.
lib="$repo_root/lib/failed-command-flagged.py"
[[ -f "$lib" ]] || fail "missing $lib"
grep -q 'fleet-ops#958, #972, #967, #977, #1001, #1059, #1100, #1170, #1243, #1255' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite #1001, #1100, #1255 next to the read-ENOENT citation chain"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1001, #1100, #1255"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-read-enoent-thinking.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-read-enoent-thinking: live #953 read ENOENT + thinking-only recovery + live #1001 stale-checkout drills"
