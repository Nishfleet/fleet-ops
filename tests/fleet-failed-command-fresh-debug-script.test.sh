#!/usr/bin/env bash
# tests/fleet-failed-command-fresh-debug-script.test.sh
#
# fleet-ops#793: a debug script just written with the `write` tool is
# then invoked with `bash /tmp/<script>` (no flags, no pipe, no
# `|| true`) and the script exits 1 with `(no output)  Command exited
# with code 1`. The next assistant turn is a recovery toolCall
# (`bash -x ... | tail ...`) with no user-facing text naming the
# failure. The detector already flags this class — the failure is
# `isError: true` + `Command exited with code 1` + no later assistant
# text, and the command text does not match `BENIGN_STAGE_RE`
# (grep/rg/diff) or `LS_BENIGN_RE` (ls) or `which` no-match. This file
# locks the live #793 shape so a future detector refactor cannot
# regress it. No `lib/failed-command-flagged.py` change — a
# suppression would silence a real signal. The auto-filed issue
# closes via observe-to-close (fleet-ops#758) when the session mtime
# ages out of the 24h window after 2026-08-27T01:15:01Z.
#
# Live session: 2026-08-27T01-15-01-912Z_01a040c8-e198-74d4-95ad-ea36a6a9214e.jsonl
# The agent (working on issue-fleet-ops-622 / -690) used the `write`
# tool to create `/tmp/fsr-debug.sh` (a Python-patch + bash-test
# harness), then ran `bash /tmp/fsr-debug.sh`. The script's
# `set -euo pipefail` killed it on the first error, the harness
# reported `(no output)  Command exited with code 1`, and the agent
# retried with `bash -x /tmp/fsr-debug.sh 2>&1 | tail -20` without
# naming the failure.
#
# Scenarios:
#   1. live #793 shape: bash /tmp/<fresh-script> exit 1 walked past -> finding.
#   2. same shape plus a later user-facing flag -> clean.
#   3. bash /tmp/<fresh-script> with `|| true` is still a finding: the
#      failure happened, the `|| true` only masks the shell exit, and
#      the harness still reports isError=true.
#   4. bash /tmp/<script-that-no-longer-exists> is the ENOENT cascade of
#      a harness block (fleet-ops#797) — out of scope here, but the
#      cross-check that the fresh-script shape is NOT a probe.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-fresh-debug.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T01:15:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T02:00:00Z"
}

# --- 1. live #793 shape: bash /tmp/<fresh-script> exit 1 walked past -------
# The live session slug 01a040c8 was filed because the agent ran
#   bash /tmp/fsr-debug.sh
# and got `(no output)  Command exited with code 1`, then continued
# with `bash -x /tmp/fsr-debug.sh 2>&1 | tail -20` (a toolCall, no
# user-facing text) without naming the failure. Replay that exact
# shape.
write_session "bash-fresh-debug-script" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_write","name":"write","arguments":{"content":"#!/usr/bin/env bash\nset -euo pipefail\ncd /home/nish/workspaces/tooling/fleet-ops-deploy-clone\npython3 <<'PYEOF'\nimport pathlib\np = pathlib.Path('tests/fleet-seat-recovery.test.sh')\np.write_text(p.read_text().replace('mktemp', 'mktemp-persist'))\nPYEOF\nbash tests/fleet-seat-recovery.test.sh\ngit checkout -- tests/fleet-seat-recovery.test.sh\n","path":"/tmp/fsr-debug.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_write","toolName":"write","isError":false,"content":[{"type":"text","text":"Successfully wrote 1207 bytes to /tmp/fsr-debug.sh"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bash","name":"bash","arguments":{"command":"bash /tmp/fsr-debug.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash","toolName":"bash","isError":true,"content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_recover","name":"bash","arguments":{"command":"bash -x /tmp/fsr-debug.sh 2>&1 | tail -20"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_recover","toolName":"bash","isError":false,"content":[{"type":"text","text":"+ set -euo pipefail\n+ cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone\n+ python3\n+ bash tests/fleet-seat-recovery.test.sh\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_followup","name":"bash","arguments":{"command":"git status --short; ls -la /tmp/fsr-debug.sh"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #793 fresh debug script exit 1 walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# The snippet is the first 200 chars of the toolResult text. The live
# #793 toolResult was `(no output)\n\nCommand exited with code 1`, so
# the snippet carries the no-output + exit-1 signal — pin both.
grep -q 'no output' <<<"$snippet" \
  || fail "finding snippet should mention (no output) (got $snippet)"
grep -q 'Command exited with code 1' <<<"$snippet" \
  || fail "finding snippet should mention Command exited with code 1 (got $snippet)"
ok "live #793 fresh debug script exit 1 walked past is flagged"
rm -f "$sessions/bash-fresh-debug-script.jsonl"

# --- 2. same shape plus a later user-facing flag is clean -------------------
# The standing rule is satisfied when the assistant names the failure in
# the same turn's user-facing text. The detector must NOT flag this.
write_session "bash-fresh-debug-script-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_write2","name":"write","arguments":{"content":"#!/usr/bin/env bash\nset -euo pipefail\necho 'before'\nbash tests/fleet-seat-recovery.test.sh\necho 'after'\n","path":"/tmp/fsr-debug.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_write2","toolName":"write","isError":false,"content":[{"type":"text","text":"Successfully wrote 96 bytes to /tmp/fsr-debug.sh"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bash2","name":"bash","arguments":{"command":"bash /tmp/fsr-debug.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash2","toolName":"bash","isError":true,"content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the bash /tmp/fsr-debug.sh call failed with exit 1 (no output, the script's set -e killed it before any echo). It is now the blocker for the seat-recovery test run."},{"type":"toolCall","id":"call_recover2","name":"bash","arguments":{"command":"bash -x /tmp/fsr-debug.sh 2>&1 | tail -20"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged fresh debug script exit 1 should be clean (got $count) $report"
ok "fresh debug script exit 1 plus later user-facing flag is clean"
rm -f "$sessions/bash-fresh-debug-script-flagged.jsonl"

# --- 3. fresh debug script exit 1 with `|| true` is still a finding ---------
# Some workers try to mask the failure with `bash /tmp/x.sh || true`. The
# harness still reports isError=true on the original `bash /tmp/x.sh`
# invocation (the `|| true` only changes the *shell* exit; the tool
# invocation's isError flag is the harness's report on whether the
# command itself failed). A worker that walks past the failure with a
# `|| true` is still walking past a real failure. Pin the shape.
write_session "bash-fresh-debug-script-or-true" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bash3","name":"bash","arguments":{"command":"bash /tmp/fsr-debug.sh || true"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash3","toolName":"bash","isError":true,"content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_followup3","name":"bash","arguments":{"command":"echo 'moving on'; ls -la /tmp/fsr-debug.sh"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "fresh debug script exit 1 with || true walked past should be a finding (got $count) $report"
ok "fresh debug script exit 1 with || true walked past is flagged"
rm -f "$sessions/bash-fresh-debug-script-or-true.jsonl"

# --- 4. cross-check: a `which` no-match probe is NOT a fresh-script shape --
# `which nonexistent-binary` exits 1 with no output. That is the
# `which`-no-match probe (treated as benign, not a swallowed failure).
# The fresh-debug-script shape is different: the script EXISTS (just
# written), the failure is internal to the script, and the snippet
# carries the script's own silent failure signal. Pin the contrast.
write_session "which-nomatch-vs-fresh-script" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_which","name":"bash","arguments":{"command":"which nonexistent-binary 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_which","toolName":"bash","isError":true,"content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Binary not in PATH. Need to install or use full path."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "which no-match probe should be benign (got $count) $report"
ok "which no-match probe is benign (contrast with fresh-debug-script shape)"
rm -f "$sessions/which-nomatch-vs-fresh-script.jsonl"

echo "OK: fleet-failed-command-fresh-debug-script: live #793 fresh debug script exit 1 drills"
