#!/usr/bin/env bash
# tests/fleet-failed-command-read-enoent-stale-rg.test.sh
#
# fleet-ops#1255: a `read` of
#   `/home/nish/workspaces/fleet-ops-rg/bin/salvage-secret-scan`
# returned the live
#   "ENOENT: no such file or directory, access '<path>'"
# shape (isError=true, details={}, no "Command exited with code" line).
# fleet-ops-rg is a stale, non-canonical checkout that does not carry
# the file (the helper lives on the canonical tooling checkout after
# PR #1214). The worker's recovery was thinking-only cause-prose:
#   "The salvage-secret-scan is in fleet-ops-sync (the sync copy), not
#    in fleet-ops-rg."
# followed by successful `read`s of unrelated files in the same stale
# checkout (pi-packet@.service, pi-issue-failed@.service,
# fleet-researcher-dispatch). The session then ended on a thinking-only
# turn. No user-facing text named the failure.
#
# That thinking names the CAUSE (the file lives in a different checkout)
# but NOT the FAILURE (the read returned ENOENT). Per the standing rule
# (fleet-ops#535), the flag must name the failure — "the read failed
# with ENOENT" — not just explain why the file is absent. Thinking-only
# cause that names the other checkout, then successful reads of
# unrelated files, is the same swallowed-failure class as the #953
# thinking-only recovery, the #1001 "clear picture" prose, and the
# #1059 "The file was archived" prose. A future detector refactor
# must not:
#   - treat "it's in fleet-ops-sync, not in fleet-ops-rg" as naming
#     the failure (it names the other checkout, not the ENOENT)
#   - treat later successful `read`s of unrelated files as discharging
#     the read-ENOENT of salvage-secret-scan
#   - treat a session that ends thinking-only (no user-facing text)
#     as clean
#   - treat fleet-ops-rg / salvage-secret-scan as a probe (the path
#     contains "rg" and the file is a scanner; neither is ls/grep)
#
# Distinct from:
#   - #1001: fleet-ops-sync + fleet-escalation-canary + canonical
#     `ls ~/.local/bin` + later "clear picture" prose
#   - #1059: archived Pi issue packet + USER-FACING cause prose
#     "The file was archived. Let me read it." + cat of archived copy
#   - #953: OVERNIGHT.md + thinking-only + later "full picture" prose
#
# The detector already flags this class. This drill pins the stale
# fleet-ops-rg salvage-scan recovery pattern so a future refactor that
# adds a "names the other checkout" or "later reads succeeded" discharge
# branch is caught.
#
# Live session: 2026-08-27T16-17-15-868Z_01a04402-e65c-7be5-b037-445eafba107d.jsonl
# Live signal:  failed-command-flagged/2026-08-27t16-17-15-868z-01a04402-e65c-7be5-b037-445eafba107d
#
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window after 2026-08-27T16:17:15Z.
#
# Scenarios:
#   1. live #1255 shape: read of salvage-secret-scan in fleet-ops-rg ->
#      ENOENT -> thinking-only cause naming fleet-ops-sync + successful
#      reads of unrelated files -> finding.
#   2. same shape plus later unrelated user-facing prose that does NOT
#      name the failure -> still a finding.
#   3. same shape plus a later user-facing flag that names the failure
#      -> clean.
#   4. user-facing cause prose that names the other checkout, without
#      naming ENOENT / failed, is still a finding (anti-exemption).
#   5. worker.md cites fleet-ops#1255 (prompt-side lock).
#   6. lib/failed-command-flagged.py docstring cites fleet-ops#1255.
#   7. seat-lib.test.sh hosts this file (CI cannot gain a new workflow line).

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

scratch="$(mktemp -d -t failed-command-read-enoent-stale-rg.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T16:17:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T18:00:00Z"
}

# --- 1. live #1255 shape: stale-rg salvage-scan ENOENT walked past ----------
# Replay the 01a04402 session: read of
# /home/nish/workspaces/fleet-ops-rg/bin/salvage-secret-scan returns the
# live ENOENT wording, then thinking-only cause that names fleet-ops-sync
# plus successful reads of unrelated files in the same stale checkout.
# Session ends thinking-only. This must be a finding.
write_session "read-enoent-stale-rg" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me read the existing salvage scan helper."},{"type":"toolCall","id":"call_scan","name":"read","arguments":{"path":"/home/nish/workspaces/fleet-ops-rg/bin/salvage-secret-scan"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_scan","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/fleet-ops-rg/bin/salvage-secret-scan'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The salvage-secret-scan is in fleet-ops-sync (the sync copy), not in fleet-ops-rg. Let me check where the main work tree is."},{"type":"toolCall","id":"call_pkt","name":"read","arguments":{"path":"/home/nish/workspaces/fleet-ops-rg/systemd/pi-packet@.service"}},{"type":"toolCall","id":"call_fail","name":"read","arguments":{"path":"/home/nish/workspaces/fleet-ops-rg/systemd/pi-issue-failed@.service"}},{"type":"toolCall","id":"call_disp","name":"read","arguments":{"path":"/home/nish/workspaces/fleet-ops-rg/bin/fleet-researcher-dispatch"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_pkt","toolName":"read","isError":false,"content":[{"type":"text","text":"[Unit]\nDescription=Pi worker packet %i\n"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_fail","toolName":"read","isError":false,"content":[{"type":"text","text":"[Unit]\nDescription=Reap stale claim\n"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_disp","toolName":"read","isError":false,"content":[{"type":"text","text":"#!/usr/bin/env bash\n# fleet-researcher-dispatch\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Now I have a good understanding of the codebase."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1255 read ENOENT with thinking-only other-checkout cause should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'ENOENT: no such file or directory, access' <<<"$snippet" \
  || fail "finding snippet should mention live ENOENT wording (got $snippet)"
grep -q 'salvage-secret-scan' <<<"$snippet" \
  || fail "finding snippet should mention salvage-secret-scan (got $snippet)"
grep -q 'fleet-ops-rg' <<<"$snippet" \
  || fail "finding snippet should mention fleet-ops-rg (got $snippet)"
ok "live #1255: stale fleet-ops-rg salvage-scan ENOENT + thinking-only other-checkout cause is flagged"
rm -f "$sessions/read-enoent-stale-rg.jsonl"

# --- 2. later unrelated user-facing prose does not discharge ---------------
write_session "read-enoent-stale-rg-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_scan2","name":"read","arguments":{"path":"/home/nish/workspaces/fleet-ops-rg/bin/salvage-secret-scan"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_scan2","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/fleet-ops-rg/bin/salvage-secret-scan'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The salvage-secret-scan is in fleet-ops-sync, not in fleet-ops-rg."},{"type":"text","text":"Now I have a good understanding of the codebase. Let me plan and execute."},{"type":"toolCall","id":"call_pkt2","name":"read","arguments":{"path":"/home/nish/workspaces/fleet-ops-rg/systemd/pi-packet@.service"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "stale-rg read ENOENT followed by unrelated prose should be a finding (got $count) $report"
ok "live #1255: stale-rg salvage-scan ENOENT with later 'good understanding' prose is still flagged"
rm -f "$sessions/read-enoent-stale-rg-prose.jsonl"

# --- 3. same shape plus a later user-facing flag is clean ------------------
write_session "read-enoent-stale-rg-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_scan3","name":"read","arguments":{"path":"/home/nish/workspaces/fleet-ops-rg/bin/salvage-secret-scan"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_scan3","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/fleet-ops-rg/bin/salvage-secret-scan'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the read of fleet-ops-rg/bin/salvage-secret-scan failed with ENOENT — that checkout is stale, recovering from the canonical path."},{"type":"toolCall","id":"call_canon","name":"read","arguments":{"path":"/home/nish/workspaces/tooling/fleet-ops/bin/salvage-secret-scan"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "stale-rg read ENOENT with later user-facing flag should be clean (got $count) $report"
ok "stale-rg salvage-scan ENOENT plus later user-facing flag naming the failure is clean"
rm -f "$sessions/read-enoent-stale-rg-flagged.jsonl"

# --- 4. user-facing other-checkout cause is still a finding ----------------
# A future refactor might treat "not in fleet-ops-rg" / "it's in
# fleet-ops-sync" as a discharge because it explains the cause. Pin that
# it does not: the failure (the read returned ENOENT) was never named.
write_session "read-enoent-stale-rg-cause-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_scan4","name":"read","arguments":{"path":"/home/nish/workspaces/fleet-ops-rg/bin/salvage-secret-scan"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_scan4","toolName":"read","content":[{"type":"text","text":"ENOENT: no such file or directory, access '/home/nish/workspaces/fleet-ops-rg/bin/salvage-secret-scan'"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The salvage-secret-scan is in fleet-ops-sync (the sync copy), not in fleet-ops-rg. Let me check where the main work tree is."},{"type":"toolCall","id":"call_pkt4","name":"read","arguments":{"path":"/home/nish/workspaces/fleet-ops-rg/systemd/pi-packet@.service"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "other-checkout cause prose without naming the failure should still be a finding (got $count) $report"
ok "other-checkout cause prose alone (no failure named) is still flagged"
rm -f "$sessions/read-enoent-stale-rg-cause-prose.jsonl"

# --- 5. worker.md cites fleet-ops#1255 and fleet-ops#1100 (prompt-side lock) ---
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1255' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1255 (prompt-side lock for the stale-rg salvage-scan read-ENOENT class)"
grep -q 'fleet-ops#1100' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1100 (prompt-side lock for the stale-checkout read-ENOENT class)"
grep -q 'salvage-secret-scan' "$worker" \
  || fail "prompts/worker.md must name salvage-secret-scan so workers flag the live #1255 path"
grep -q 'fleet-ops-rg' "$worker" \
  || fail "prompts/worker.md must name fleet-ops-rg so workers flag the live #1255 stale-checkout shape"
grep -q 'fleet-failed-command-flagged' "$worker" \
  || fail "prompts/worker.md must name fleet-failed-command-flagged so workers flag the live #1100 stale-checkout shape"
ok "worker.md cites fleet-ops#1255, fleet-ops#1100 and the live stale-checkout paths"

# --- 6. lib/failed-command-flagged.py docstring cites fleet-ops#1255 and fleet-ops#1100 ---
grep -q 'fleet-ops#1255' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1255 (detector-side lock)"
grep -q 'fleet-ops#1100' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1100 (detector-side lock for the stale-checkout read-ENOENT class)"
grep -q '01a04402' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the 01a04402 salvage-scan session next to the #1255 citation"
grep -q '01a042d4' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the 01a042d4 failed-command-flagged session next to the #1100 citation"
grep -q 'salvage-secret-scan' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name salvage-secret-scan next to the #1255 citation"
grep -q 'fleet-failed-command-flagged' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name fleet-failed-command-flagged next to the #1100 citation"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1255 and fleet-ops#1100"

# --- 7. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) --------
grep -Fq 'bash "$here/fleet-failed-command-read-enoent-stale-rg.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-read-enoent-stale-rg: live #1255 stale fleet-ops-rg salvage-scan ENOENT drill + #1100 stale fleet-ops path drill"
