#!/usr/bin/env bash
# tests/guard-cursor-packet.test.sh
#
# Proves the cursor keystone lane packet guard (fleet-ops#1545) catches empty
# runs and lane faults in cursor agent-transcripts, reusing the canonical
# verdict-line grammar from lib/guard_pi_packet.py (no new checker logic).
# Runs offline — no cursor-agent, no network.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/.." && pwd)
export PYTHONPATH="$repo_root/lib"
guard="$repo_root/lib/guard_cursor_packet.py"
hook="$repo_root/bin/guard_cursor_packet_hook.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch=$(mktemp -d -t guard-cursor-packet.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

write_transcript() { # name, then lines
    local name="$1"; shift
    local path="$scratch/$name.jsonl"
    : > "$path"
    local line
    for line in "$@"; do printf '%s\n' "$line" >> "$path"; done
    echo "$path"
}

# --- 1. clean packet run: claim in first turn + PACKET-VERDICT verdict line last -----
clean=$(write_transcript clean \
'{"role":"user","message":{"content":[{"type":"text","text":"Handle Nishfleet/fleet-ops#1545 claim/issue-1545"}]}}' \
'{"role":"assistant","message":{"content":[{"type":"text","text":"Implementing"}]}}' \
'{"role":"assistant","message":{"content":[{"type":"text","text":"PACKET-VERDICT tools=3 class=worked"}]}}' \
'{"type":"turn_ended","status":"success"}')
set +e
out=$(python3 "$guard" "$clean" 2>&1); rc=$?
set -e
[[ "$rc" == 0 ]] || fail "clean run with verdict must exit 0, got $rc ($out)"
ok "clean packet run with verdict line exits 0"

# --- 2. empty run: claimed an issue, short output, no verdict line ----------------
empty=$(write_transcript empty \
'{"role":"user","message":{"content":[{"type":"text","text":"Fix Nishfleet/fleet-ops#991 claim/issue-991"}]}}' \
'{"role":"assistant","message":{"content":[{"type":"text","text":"say the word and I'"'"'ll dig in"}]}}' \
'{"type":"turn_ended","status":"success"}')
set +e
out=$(python3 "$guard" "$empty" 2>&1); rc=$?
set -e
[[ "$rc" == 2 ]] || fail "empty run must exit 2, got $rc ($out)"
printf '%s\n' "$out" | grep -qi 'verdict' || fail "stderr must mention verdict line: $out"
printf '%s\n' "$out" | grep -qi 'narrate-and-quit\|empty' || fail "stderr must mention narrate-and-quit/empty: $out"
ok "empty run (no verdict line) exits 2 and is flagged"

# --- 3. lane fault: rate_limit in output is a lane fault ---------------------------
lane=$(write_transcript lane \
'{"role":"user","message":{"content":[{"type":"text","text":"Handle Nishfleet/fleet-ops#42 claim/issue-42"}]}}' \
'{"role":"assistant","message":{"content":[{"type":"text","text":"rate_limit_error: retry after 60s"}]}}' \
'{"type":"turn_ended","status":"success"}')
set +e
out=$(python3 "$guard" "$lane" 2>&1); rc=$?
set -e
[[ "$rc" == 2 ]] || fail "lane fault must exit 2, got $rc ($out)"
printf '%s\n' "$out" | grep -qi 'lane fault' || fail "stderr must mention 'lane fault': $out"
ok "lane fault (rate_limit) exits 2 and tells agent to rotate"

# --- 4. non-packet interactive chat (no claim, no tools) is not judged ------------
chat=$(write_transcript chat \
'{"role":"user","message":{"content":[{"type":"text","text":"explain tailscale to me"}]}}' \
'{"role":"assistant","message":{"content":[{"type":"text","text":"Tailscale is a mesh VPN..."}]}}' \
'{"type":"turn_ended","status":"success"}')
set +e
out=$(python3 "$guard" "$chat" 2>&1); rc=$?
set -e
[[ "$rc" == 0 ]] || fail "non-packet chat must exit 0, got $rc ($out)"
ok "non-packet interactive chat is not judged"

# --- 5. missing transcript is fail-open (exit 0), not a crash ----------------------
set +e
out=$(python3 "$guard" "$scratch/does-not-exist.jsonl" 2>&1); rc=$?
set -e
[[ "$rc" == 0 ]] || fail "missing transcript must exit 0, got $rc ($out)"
ok "missing transcript is fail-open"

# --- 6. sessionEnd hook shim flags the latest empty run ----------------------------
# The hook shim scans the projects root; point it at a synthetic root.
hookroot="$scratch/projects"
mkdir -p "$hookroot/p1/agent-transcripts/aaa/aaa"
cp "$empty" "$hookroot/p1/agent-transcripts/aaa/aaa/aaa.jsonl"
set +e
out=$(CURSOR_TRANSCRIPT_ROOT="$hookroot" python3 "$hook" <<< '{"conversation_id":"aaa"}' 2>&1); rc=$?
set -e
[[ "$rc" == 2 ]] || fail "sessionEnd hook must exit 2 on empty run, got $rc ($out)"
printf '%s\n' "$out" | grep -qi 'guard-cursor-packet' || fail "hook stderr must carry the guard label: $out"
ok "sessionEnd hook shim flags the empty run"

# --- 7. hook treats a clean run as clean -------------------------------------------
cleanroot="$scratch/projects-clean"
mkdir -p "$cleanroot/p1/agent-transcripts/bbb/bbb"
cp "$clean" "$cleanroot/p1/agent-transcripts/bbb/bbb/bbb.jsonl"
set +e
out=$(CURSOR_TRANSCRIPT_ROOT="$cleanroot" python3 "$hook" <<< '{"conversation_id":"bbb"}' 2>&1); rc=$?
set -e
[[ "$rc" == 0 ]] || fail "sessionEnd hook must exit 0 on clean run, got $rc ($out)"
ok "sessionEnd hook shim passes the clean run"

echo "guard-cursor-packet: all online"