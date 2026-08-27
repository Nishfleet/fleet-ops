#!/usr/bin/env bash
# tests/fleet-failed-command-enoent-block.test.sh
#
# fleet-ops#677: a command that fails with exit 127 "No such file or
# directory" because the spawn-guard refused the heredoc/redirect that would
# have created the script is a downstream cascade of a harness block, not a
# swallowed command failure. The assistant recovers via the write tool. A
# real 127 ENOENT with no prior harness block is still a finding.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-enoent.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-26T16:20:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-26T16:30:00Z"
}

# --- 1. exact #677 shape: blocked heredoc -> bash 127 ENOENT -> write -> ok --
# The spawn-guard refused `cat > /tmp/check-stub.sh <<'EOF'` twice, so the
# file was never created. `bash /tmp/check-stub.sh` then fails 127 ENOENT.
# The assistant recovers via the write tool. Not a swallowed failure.
write_session "enoent-downstream" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cat1","name":"bash","arguments":{"command":"cat > /tmp/check-stub.sh <<'EOF'\n#!/usr/bin/env bash\necho hi\nEOF"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cat1","toolName":"bash","isError":true,"content":[{"type":"text","text":"Dangerous command blocked (no UI for confirmation)"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_cat2","name":"bash","arguments":{"command":"cat > /tmp/check-stub.sh <<'EOF'\n#!/usr/bin/env bash\necho hi\nEOF"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_cat2","toolName":"bash","isError":true,"content":[{"type":"text","text":"Dangerous command blocked (no UI for confirmation)"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bash","name":"bash","arguments":{"command":"bash /tmp/check-stub.sh 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash","toolName":"bash","isError":true,"content":[{"type":"text","text":"bash: /tmp/check-stub.sh: No such file or directory\n\n\nCommand exited with code 127"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_write","name":"write","arguments":{"path":"/tmp/check-stub.sh","content":"#!/usr/bin/env bash\necho hi"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_write","toolName":"write","isError":false,"content":[{"type":"text","text":"Successfully wrote 23 bytes to /tmp/check-stub.sh"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bash2","name":"bash","arguments":{"command":"bash /tmp/check-stub.sh 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash2","toolName":"bash","isError":false,"content":[{"type":"text","text":"hi"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The stub works now."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "downstream-of-block ENOENT should not be a finding (got $count) $report"
ok "127 ENOENT downstream of a harness block is not a swallowed failure"
rm -f "$sessions/enoent-downstream.jsonl"

# --- 2. real 127 ENOENT with NO prior block is still a finding --------------
# No harness block preceded this; the assistant just invoked a missing script
# and walked past it. That is a real swallowed failure.
write_session "enoent-real" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bash3","name":"bash","arguments":{"command":"bash /tmp/never-created.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bash3","toolName":"bash","isError":true,"content":[{"type":"text","text":"bash: /tmp/never-created.sh: No such file or directory\n\nCommand exited with code 127"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on to the next task."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "real 127 ENOENT with no prior block should be a finding (got $count) $report"
ok "real 127 ENOENT with no prior block is still flagged"
rm -f "$sessions/enoent-real.jsonl"

# --- 3. SPAWN_BLOCKED (not "Dangerous command blocked") also seeds the flag --
# The live #648 git_stash_forbidden shape is a different harness-block wording;
# a downstream ENOENT after it must also be exempt.
write_session "spawn-block-downstream" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_st","name":"bash","arguments":{"command":"git stash list"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_st","toolName":"bash","isError":true,"content":[{"type":"text","text":"SPAWN_BLOCKED reason=git_stash_forbidden. git stash is forbidden."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_run","name":"bash","arguments":{"command":"bash /tmp/stash-out.sh"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_run","toolName":"bash","isError":true,"content":[{"type":"text","text":"bash: /tmp/stash-out.sh: No such file or directory\n\nCommand exited with code 127"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Switching approach."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "ENOENT downstream of SPAWN_BLOCKED should not be a finding (got $count) $report"
ok "127 ENOENT downstream of SPAWN_BLOCKED is not a swallowed failure"
rm -f "$sessions/spawn-block-downstream.jsonl"

# --- 4. a non-127 failure after a block is still flagged --------------------
# A prior harness block must NOT exempt an unrelated real failure later.
write_session "block-then-real-fail" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_blk","name":"bash","arguments":{"command":"rm -rf /"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_blk","toolName":"bash","isError":true,"content":[{"type":"text","text":"Dangerous command blocked (no UI for confirmation)"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_false","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_false","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "non-127 failure after a block should still be a finding (got $count) $report"
ok "a real (non-ENOENT-127) failure after a block is still flagged"

echo "OK: fleet-failed-command-enoent-block: downstream-of-block ENOENT exempt, real 127 still flagged"
