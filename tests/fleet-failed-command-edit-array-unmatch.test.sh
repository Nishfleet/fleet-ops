#!/usr/bin/env bash
# tests/fleet-failed-command-edit-array-unmatch.test.sh
#
# fleet-ops#1173: an `edit` tool with a multi-edit array can fail with
#   "Could not find edits[0] in <path>. The oldText must match exactly
#   including all whitespace and newlines."
# when the first `oldText` does not match. This is the same class as the
# single-edit "Could not find the exact text" shape (fleet-ops#956, #965):
# the worker's `oldText` was stale and the edit did not land. The recovery
# was a silent `read` of the same path and a second `edit` that succeeded.
# Because no user-facing text named the first failure, the detector flagged
# it.
#
# The detector already flags this class: the `edit` tool is not a no-match
# probe, and the toolResult has isError=true. No `lib/failed-command-
# flagged.py` logic change is needed — a suppression would silence a real
# signal. This file locks the live #1173 shape and the three-place citation
# (docstring, prompt, test host) so a future refactor cannot regress it.
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when the
# session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T13-43-31-730Z_01a04376-2692-7e57-b3fa-2c1c7b46ccb2.jsonl
# The agent attempted to edit
#   /home/nish/.local/libexec/alert-repair-dispatch
# with two `edits`; the first `oldText` did not match and the tool returned
# the `edits[0]` wording. The next assistant turn was a `read` of the same
# path and another `edit`, with no user-facing text naming the failure.
#
# Scenarios:
#   1. live #1173 shape: multi-edit unmatch + silent read/successful edit
#      recovery -> finding. Snippet must carry `edits[0]` and the path.
#   2. same shape plus a later thinking-only note -> still a finding.
#   3. same shape plus later unrelated user-facing prose -> still a finding.
#   4. same shape plus a later user-facing flag -> clean.
#   5. cross-check: a single-edit `Could not find the exact text` continues
#      to be flagged so a refactor that only handles the `edits[0]` wording
#      does not break the original shape.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-edit-array-unmatch.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T13:50:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T17:00:00Z"
}

# --- 1. live #1173 shape: multi-edit array unmatch walked past -------------
write_session "edit-array-unmatch-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit1","name":"edit","arguments":{"path":"/home/nish/.local/libexec/alert-repair-dispatch","edits":[{"oldText":"# Skip: Watchdog (heartbeat) and FleetTestAlert (synthetic) — both go to\n# Telegram but must NOT spawn a repair worker.","newText":"# Skip: Watchdog (heartbeat) and FleetTestAlert (synthetic) — both go to\n# Telegram but must NOT spawn a repair worker.\n# CanaryDrill is the synthetic stalled-chain probe used by\n# fleet-completion-canary (packet 11, fleet-ops#468) — also must not\n# spawn a real repair worker; the canary drives the drill by faking a\n# DISPATCH line + a transient unit and watching the ladder."},{"oldText":"SKIP_SET = {\"Watchdog\", \"FleetTestAlert\", \"LoadStorm\"}","newText":"SKIP_SET = {\"Watchdog\", \"FleetTestAlert\", \"LoadStorm\", \"CanaryDrill\"}"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit1","toolName":"edit","content":[{"type":"text","text":"Could not find edits[0] in /home/nish/.local/libexec/alert-repair-dispatch. The oldText must match exactly including all whitespace and newlines."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read1","name":"read","arguments":{"path":"/home/nish/.local/libexec/alert-repair-dispatch","offset":14,"limit":20}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read1","toolName":"read","isError":false,"content":[{"type":"text","text":"# Skip: Watchdog (heartbeat) and FleetTestAlert (synthetic) — both go to\n# Telegram but must NOT spawn a repair worker.\n# Canary\n# Drilled is the synthetic stalled-chain probe used by\n# fleet-completion-canary."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1173 edit array unmatch walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q "edits\[0\]" <<<"$snippet" \
  || fail "finding snippet should mention 'edits[0]' (got $snippet)"
grep -q "alert-repair-dispatch" <<<"$snippet" \
  || fail "finding snippet should mention alert-repair-dispatch (got $snippet)"
ok "live #1173: multi-edit 'edits[0]' unmatch with silent read recovery is flagged"
rm -f "$sessions/edit-array-unmatch-walked.jsonl"

# --- 2. live #1173 thinking-only recovery is still a finding ---------------
write_session "edit-array-unmatch-thinking" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit2","name":"edit","arguments":{"path":"/home/nish/.local/libexec/alert-repair-dispatch","edits":[{"oldText":"# Skip: Watchdog (heartbeat) and FleetTestAlert (synthetic) — both go to\n# Telegram but must NOT spawn a repair worker.","newText":"# Skip: Watchdog (heartbeat) and FleetTestAlert (synthetic) — both go to\n# Telegram but must NOT spawn a repair worker.\n# CanaryDrill is the synthetic stalled-chain probe used by\n# fleet-completion-canary (packet 11, fleet-ops#468) — also must not\n# spawn a real repair worker; the canary drives the drill by faking a\n# DISPATCH line + a transient unit and watching the ladder."},{"oldText":"SKIP_SET = {\"Watchdog\", \"FleetTestAlert\", \"LoadStorm\"}","newText":"SKIP_SET = {\"Watchdog\", \"FleetTestAlert\", \"LoadStorm\", \"CanaryDrill\"}"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit2","toolName":"edit","content":[{"type":"text","text":"Could not find edits[0] in /home/nish/.local/libexec/alert-repair-dispatch. The oldText must match exactly including all whitespace and newlines."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The first oldText is slightly different in the installed copy. I will read the file and try the edit again."},{"type":"toolCall","id":"call_read2","name":"read","arguments":{"path":"/home/nish/.local/libexec/alert-repair-dispatch","offset":14,"limit":20}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "edit array unmatch with thinking-only recovery should be a finding (got $count) $report"
ok "live #1173: multi-edit 'edits[0]' unmatch with later thinking-only recovery is still flagged"
rm -f "$sessions/edit-array-unmatch-thinking.jsonl"

# --- 3. later unrelated user-facing prose does not discharge ---------------
write_session "edit-array-unmatch-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit3","name":"edit","arguments":{"path":"/home/nish/.local/libexec/alert-repair-dispatch","edits":[{"oldText":"# Skip: Watchdog (heartbeat) and FleetTestAlert (synthetic) — both go to\n# Telegram but must NOT spawn a repair worker.","newText":"# Skip: Watchdog (heartbeat) and FleetTestAlert (synthetic) — both go to\n# Telegram but must NOT spawn a repair worker.\n# CanaryDrill is the synthetic stalled-chain probe used by\n# fleet-completion-canary (packet 11, fleet-ops#468) — also must not\n# spawn a real repair worker; the canary drives the drill by faking a\n# DISPATCH line + a transient unit and watching the ladder."},{"oldText":"SKIP_SET = {\"Watchdog\", \"FleetTestAlert\", \"LoadStorm\"}","newText":"SKIP_SET = {\"Watchdog\", \"FleetTestAlert\", \"LoadStorm\", \"CanaryDrill\"}"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit3","toolName":"edit","content":[{"type":"text","text":"Could not find edits[0] in /home/nish/.local/libexec/alert-repair-dispatch. The oldText must match exactly including all whitespace and newlines."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read3","name":"read","arguments":{"path":"/home/nish/.local/libexec/alert-repair-dispatch","offset":14,"limit":20}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_read3","toolName":"read","isError":false,"content":[{"type":"text","text":"# Skip: Watchdog (heartbeat) and FleetTestAlert (synthetic) — both go to\n# Telegram but must NOT spawn a repair worker.\n# Canary\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The installed copy has a slightly different comment. I will adjust the edit and try again."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "edit array unmatch followed by unrelated prose should be a finding (got $count) $report"
ok "live #1173: multi-edit 'edits[0]' unmatch with unrelated user-facing prose is still flagged"
rm -f "$sessions/edit-array-unmatch-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean ------------------
write_session "edit-array-unmatch-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit4","name":"edit","arguments":{"path":"/home/nish/.local/libexec/alert-repair-dispatch","edits":[{"oldText":"# Skip: Watchdog (heartbeat) and FleetTestAlert (synthetic) — both go to\n# Telegram but must NOT spawn a repair worker.","newText":"# Skip: Watchdog (heartbeat) and FleetTestAlert (synthetic) — both go to\n# Telegram but must NOT spawn a repair worker.\n# CanaryDrill is the synthetic stalled-chain probe used by\n# fleet-completion-canary (packet 11, fleet-ops#468) — also must not\n# spawn a real repair worker; the canary drives the drill by faking a\n# DISPATCH line + a transient unit and watching the ladder."},{"oldText":"SKIP_SET = {\"Watchdog\", \"FleetTestAlert\", \"LoadStorm\"}","newText":"SKIP_SET = {\"Watchdog\", \"FleetTestAlert\", \"LoadStorm\", \"CanaryDrill\"}"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit4","toolName":"edit","content":[{"type":"text","text":"Could not find edits[0] in /home/nish/.local/libexec/alert-repair-dispatch. The oldText must match exactly including all whitespace and newlines."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the edit call failed with Could not find edits[0] — the first oldText was stale, reading the file to find the right text."},{"type":"toolCall","id":"call_read4","name":"read","arguments":{"path":"/home/nish/.local/libexec/alert-repair-dispatch","offset":14,"limit":20}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "edit array unmatch with later user-facing flag should be clean (got $count) $report"
ok "multi-edit 'edits[0]' unmatch plus later user-facing flag is clean"
rm -f "$sessions/edit-array-unmatch-flagged.jsonl"

# --- 5. cross-check: single-edit 'Could not find the exact text' still flagged
write_session "edit-single-unmatch-contrast" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_edit5","name":"edit","arguments":{"path":"/home/nish/.local/libexec/alert-repair-dispatch","edits":[{"oldText":"SKIP_SET = {\"Watchdog\", \"FleetTestAlert\", \"LoadStorm\"}"}]}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_edit5","toolName":"edit","content":[{"type":"text","text":"Could not find the exact text in /home/nish/.local/libexec/alert-repair-dispatch. The old text must match exactly including all whitespace and newlines."}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_read5","name":"read","arguments":{"path":"/home/nish/.local/libexec/alert-repair-dispatch","offset":14,"limit":20}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "single-edit 'Could not find the exact text' must still be flagged (got $count) $report"
ok "single-edit 'Could not find the exact text' continues to be flagged (contrast with #1173)"
rm -f "$sessions/edit-single-unmatch-contrast.jsonl"

# --- 6. prompts/worker.md cites fleet-ops#1173 (prompt-side lock) -----------
worker="$repo_root/lib/failed-command-flagged.py"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1173' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1173 (prompt-side lock)"
grep -q "edits\[0\]" "$worker" \
  || fail "prompts/worker.md must name the live 'edits[0]' wording"
ok "worker.md cites fleet-ops#1173 and the 'edits[0]' live wording"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#1173 -------
grep -q 'fleet-ops#1173' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1173 (detector-side lock)"
grep -q "edits\[0\]" "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'edits[0]' wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1173 and the 'edits[0]' shape"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-edit-array-unmatch.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-edit-array-unmatch: live #1173 multi-edit 'edits[0]' drills"
