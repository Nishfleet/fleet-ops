#!/usr/bin/env bash
# tests/fleet-failed-command-keyerror-walked-past.test.sh
#
# fleet-ops#661: a `python3 -c "..."` / `python3 << 'EOF'` call that raises
# `KeyError: 'input_domain'` (or any Python traceback ending in
# "Command exited with code 1" with isError=true) and is walked past is a
# real swallowed failure. The detector already flags this class via the
# `isError=True` short-circuit (and the EXIT_RE / "Command exited with
# code 1" path), but no test pinned the exact #661 snippet, so a future
# refactor that touches is_benign_no_match could regress the class.
#
# Live origin: 2026-08-26T13:18:31Z session slug
# 01a03e38-e602-737c-b399-576dcf48d08e, three KeyError 'input_domain'
# toolResults in a row, each followed by a fresh tool call with no
# user-facing text naming the failure. The detector caught the third.
#
# This test locks four scenarios:
#   1. Live #661 shape: python KeyError 'input_domain' walked past (count=1).
#   2. Same shape with a later assistant text naming the failure (count=0).
#   3. Three KeyErrors in a row (the actual live pattern), all walked past
#      (count=3 — every KeyError is a separate finding).
#   4. A KeyError that is *the command's purpose* (intentional probe) AND
#      the assistant names the traceback in the same turn's user-facing
#      text (count=0 — flagged text satisfies the standing rule).
#
# Closes #661 mechanism gap (fleet-ops#366).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-keyerror-XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-26T13:19:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T03:10:00Z"
}

# --- 1. live #661 shape: python KeyError walked past --------------------------
# The third toolResult in the live session: a `python3 << 'EOF'` that builds
# v1_lookup/v2_lookup dicts. v1 has 13 records, one with input_domain=None;
# iterating raises KeyError 'input_domain'. The next assistant turn is a
# fresh `python3` probe (no user-facing text naming the failure). The
# detector must flag this (count=1).
write_session "keyerror-661" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_kx","name":"bash","arguments":{"command":"python3 << 'EOF'\nimport json, re\nv2 = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/results.json'))\nv1 = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike/results.json'))\ngt = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike/groundtruth.json'))\n\ndef norm(s):\n    return re.sub(r'[^a-z0-9 ]', '', s.lower()).strip()\n\ndomains = [k for k in gt if k != '_about']\n\nv2_lookup = {r['input_domain']: r for r in v2}\nv1_lookup = {r['input_domain']: r for r in v1}\nprint('=== Per-domain comparison (programmatic) ===')\nEOF"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_kx","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<stdin>\", line 14, in <module>\nKeyError: 'input_domain'\n\n\nCommand exited with code 1\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_kx2","name":"bash","arguments":{"command":"python3 << 'EOF'\nimport json\nv1 = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike/results.json'))\nprint('type v1:', type(v1))\nif isinstance(v1, dict):\n    print('keys:', list(v1.keys())[:20])\nelse:\n    print('len:', len(v1))\n    print('first keys:', list(v1[0].keys()) if v1 else 'empty')\nEOF"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #661 KeyError walked past should be a finding (got $count) $report"
grep -q "KeyError" <<<"$(jq -r '.findings[0].snippet' <<<"$report")" \
  || fail "finding snippet should mention KeyError (got $(jq -r '.findings[0].snippet' <<<"$report"))"
grep -q "input_domain" <<<"$(jq -r '.findings[0].snippet' <<<"$report")" \
  || fail "finding snippet should mention input_domain (got $(jq -r '.findings[0].snippet' <<<"$report"))"
ok "live #661 KeyError 'input_domain' walked past is flagged"
rm -f "$sessions/keyerror-661.jsonl"

# --- 2. same shape plus a later user-facing flag is clean ---------------------
# The standing rule (fleet-ops#535) is satisfied when the assistant names the
# failure in the same turn's user-facing text. The detector must NOT flag.
write_session "keyerror-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_kxf","name":"bash","arguments":{"command":"python3 << 'EOF'\nimport json\nv1 = json.load(open('/tmp/nonexistent.json'))\nprint(v1)\nEOF"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_kxf","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<stdin>\", line 2, in <module>\nFileNotFoundError: [Errno 2] No such file or directory: '/tmp/nonexistent.json'\n\n\nCommand exited with code 1\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the python3 call failed with FileNotFoundError on /tmp/nonexistent.json — that's the blocker. Switching to a hardcoded dict and retrying."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "KeyError with later user-facing flag should be clean (got $count) $report"
ok "python traceback + later user-facing flag is clean"
rm -f "$sessions/keyerror-flagged.jsonl"

# --- 3. three KeyErrors in a row (the live #661 pattern) ---------------------
# The live session had three separate KeyError 'input_domain' toolResults
# in a row, each followed by a fresh tool call. The detector's scan_session
# returns one finding per session (first swallowed snippet). The standing
# rule still trips on the live #661 pattern — the same class, repeated,
# must keep producing a single flagged session. A future refactor that
# drops pending.append() for any toolResult would regress this to count=0.
write_session "keyerror-triple" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"kx1","name":"bash","arguments":{"command":"python3 -c \"import json; v=json.load(open('/tmp/a.json')); d={r['input_domain']:r for r in v}; print(d)\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"kx1","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\nKeyError: 'input_domain'\nCommand exited with code 1\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"kx2","name":"bash","arguments":{"command":"python3 -c \"import json; v=json.load(open('/tmp/b.json')); d={r['input_domain']:r for r in v}; print(d)\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"kx2","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\nKeyError: 'input_domain'\nCommand exited with code 1\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"kx3","name":"bash","arguments":{"command":"python3 -c \"import json; v=json.load(open('/tmp/c.json')); d={r['input_domain']:r for r in v}; print(d)\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"kx3","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\nKeyError: 'input_domain'\nCommand exited with code 1\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"kx4","name":"bash","arguments":{"command":"python3 -c \"import json; v=json.load(open('/tmp/d.json')); d={r['input_domain']:r for r in v}; print(d)\""}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "three KeyErrors walked past in one session should be 1 finding (got $count) $report"
# Snippet must be the FIRST swallowed KeyError, not some later one — locks
# scan_session's first-pending contract.
grep -q 'KeyError' <<<"$(jq -r '.findings[0].snippet' <<<"$report")" \
  || fail "triple KeyError finding snippet should mention KeyError (got $(jq -r '.findings[0].snippet' <<<"$report"))"
ok "three KeyErrors walked past produce one finding (first pending snippet)"
rm -f "$sessions/keyerror-triple.jsonl"

# --- 4. a KeyError that is intentional (the command's purpose) AND named ------
# An agent deliberately calls a python script that is expected to raise
# (e.g. for a negative-test fixture). If the assistant names the failure in
# the same turn's user-facing text, the standing rule is satisfied — clean.
write_session "keyerror-named" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"kxn","name":"bash","arguments":{"command":"python3 -c \"raise KeyError('intentional')\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"kxn","toolName":"bash","isError":true,"content":[{"type":"text","text":"KeyError: 'intentional'\nCommand exited with code 1\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the intentional KeyError failed as expected — that's the failure this fixture is here to prove, so the negative path is wired. Moving on."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "intentional KeyError with later flag should be clean (got $count) $report"
ok "intentional KeyError with later user-facing flag is clean"
rm -f "$sessions/keyerror-named.jsonl"

echo "OK: fleet-failed-command-keyerror-walked-past: live #661 + flag drill"
