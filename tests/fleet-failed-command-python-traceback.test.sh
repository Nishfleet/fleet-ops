#!/usr/bin/env bash
# tests/fleet-failed-command-python-traceback.test.sh
#
# fleet-ops#957 / #966: a `python3 -c` / `python3 << EOF` probe that crashes with
# a Python traceback (KeyError, NameError, etc.) is a real failure. The
# toolResult carries isError=true, the traceback text, and
# "Command exited with code 1". The command text is `python3 -c ...` or
# `python3 << 'EOF' ...`, which does NOT match BENIGN_STAGE_RE
# (grep/rg/diff/which) or LS_BENIGN_RE (ls) or GIT_BENIGN_RE — so it is
# not a no-match probe. The assistant almost always recovers by re-running
# a slightly different probe; that recovery is fine, but the failure must
# be NAMED in user-facing text in the same turn (fleet-ops#535 standing
# rule). A later `thinking` block, a toolCall-only recovery turn, or
# unrelated prose that moves on is not a user-facing flag.
#
# A future detector refactor must not:
#   - treat a Python traceback + "Command exited with code 1" as a probe
#     (it is not grep/rg/diff/ls/which/git-ref)
#   - let a `thinking` block discharge the class
#   - let a toolCall-only recovery turn discharge the class
#   - let later unrelated user-facing prose ("Now I have everything I
#     need. Let me write the synthesis report.") clear a pending failure
#
# No `lib/failed-command-flagged.py` change — a suppression would silence a
# real signal. The auto-filed issue closes via observe-to-close
# (fleet-ops#758) when the session mtime ages out of the 24h window after
# 2026-08-26T13:18:31Z.
#
# The same session was also auto-filed as leftover duplicates #952,
# #966, #971, #976, #981 (search-index delay, fleet-ops#951). The shape
# lock lives here; leftover-duplicate observe-to-close drain for that
# pile lives in
# tests/fleet-failed-command-observe-duplicate-python-traceback.test.sh
# (#966).
#
# Live session: 2026-08-26T13-18-31-426Z_01a03e38-e602-737c-b399-576dcf48d08e.jsonl
# The agent (writing the P18 v2 discovery-spike synthesis report) ran a
# series of `python3 -c` and `python3 << 'EOF'` probes to compare v1/v2
# eval results. The first probe crashed with
#   KeyError: 'input_domain'
# (it indexed `results['input_domain']` on a dict that was a per-domain
# record, not the array root). The agent retried with a different probe,
# hit the same KeyError twice more, then a NameError (`warns` vs `warms`),
# and never named any of the failures in user-facing text — it just
# re-probed until it got the shape it wanted, then wrote the report.
#
# Scenarios:
#   1. live #957 shape: python3 -c KeyError + toolCall-only recovery ->
#      finding.
#   2. same shape plus a later thinking-only recovery -> still a finding.
#   3. same shape plus later unrelated user-facing prose ("Now I have
#      everything I need. Let me write the synthesis report.") that does
#      NOT name the failure -> still a finding.
#   4. same shape plus a later "the python3 call failed" user-facing flag
#      -> clean.
#   5. worker.md cites fleet-ops#957 (prompt-side lock).
#   6. lib/failed-command-flagged.py docstring cites fleet-ops#957
#      (detector-side lock).
#   7. seat-lib.test.sh hosts this file (CI cannot gain a new workflow line).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-python-traceback.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-26T13:18:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-26T13:45:00Z"
}

# --- 1. live #957 shape: python3 -c KeyError + toolCall-only recovery ---
# The live session slug 01a03e38 was filed because the agent ran a
# `python3 -c` probe that crashed with `KeyError: 'input_domain'`,
# isError=true, and "Command exited with code 1". The next assistant turn
# was a toolCall only (a re-probe) with no user-facing text. Replay that
# exact shape.
write_session "python-traceback-walked-past" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe1","name":"bash","arguments":{"command":"python3 -c \"\nimport json\nv1 = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike/results.json'))\ngt = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike/groundtruth.json'))\nimport re\ndef norm(s):\n    return re.sub(r'[^a-z0-9 ]', ' ', s.lower())\nfor d in v1:\n    dom = d['input_domain']\n    top5 = [norm(c) for c in d.get('top8', [])[:5]]\n    g = gt.get(dom, [])\n    hits = sum(1 for c in g if norm(c) in top5)\n    print(f'{dom:30s} hits={hits} p5={hits/5:.2f} top5={top5[:5]}')\n\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe1","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 10, in <module>\nKeyError: 'input_domain'\nallbirds.com                   hits=0 p5=0.00 top5=['Crocs', 'Dr. Martens', 'Foot Locker', 'Caleres', 'Cole Haan']\nnotion.so                      hits=1 p5=0.20 top5=['Easy8', 'ConnectedText', 'Mindomo', 'Microsoft Loop', 'BlueSpice']\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_retry1","name":"bash","arguments":{"command":"python3 -c \"import json; d=json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/results.json')); print(list(d[0].keys()))\""}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #957 python3 KeyError walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
# The snippet is the first 200 chars of the toolResult text. The live
# #957 toolResult carried the Python traceback + the KeyError line + the
# partial stdout (the allbirds/notion eval lines) + the exit-1 trailer.
# The partial stdout pushes the exit-1 trailer past the 200-char cutoff,
# so the live snippet carries Traceback + KeyError + the start of the
# stdout — pin those distinguishing signals. The exit-code-1 signal is
# pinned in scenarios 2/3/4, whose shorter toolResult text keeps the
# trailer inside the 200-char window.
grep -q 'Traceback' <<<"$snippet" \
  || fail "finding snippet should mention Traceback (got $snippet)"
grep -q "KeyError: 'input_domain'" <<<"$snippet" \
  || fail "finding snippet should mention KeyError: 'input_domain' (got $snippet)"
ok "live #957: python3 -c KeyError with toolCall-only recovery is flagged"
rm -f "$sessions/python-traceback-walked-past.jsonl"

# --- 2. python3 << EOF heredoc KeyError + thinking-only recovery --------
# The live session's second and third failures were `python3 << 'EOF'`
# heredoc probes that hit the same KeyError. The next turn was a `thinking`
# block plus a re-probe. Thinking is not a user-facing flag (fleet-ops#535
# / #953). Pin that a future `_text_chunks` change that starts collecting
# `thinking` fields still cannot discharge this class unless FLAG_RE
# matches — and this thinking text does not.
write_session "python-traceback-thinking-only" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe2","name":"bash","arguments":{"command":"python3 << 'EOF'\nimport json, re\n\nv1 = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike/results.json'))\nv2 = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/results.json'))\ngt = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike/groundtruth.json'))\ndef norm(s):\n    return re.sub(r'[^a-z0-9 ]', ' ', s.lower())\nfor d in v2:\n    dom = d['input_domain']\n    top5 = [norm(c) for c in d.get('top8', [])[:5]]\n    g = gt.get(dom, [])\n    hits = sum(1 for c in g if norm(c) in top5)\n    print(f'{dom:30s} hits={hits} p5={hits/5:.2f}')\nEOF"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe2","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<stdin>\", line 15, in <module>\nKeyError: 'input_domain'\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The v2 file is an array of per-domain records, but I indexed it like a dict. Let me check the actual shape of v2[0]."},{"type":"toolCall","id":"call_retry2","name":"bash","arguments":{"command":"python3 -c \"import json; v2=json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/results.json')); print('v2[0] input_domain? ->', v2[0].get('input_domain')); print('len v2:', len(v2))\""}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "python3 heredoc KeyError with thinking-only recovery should be a finding (got $count) $report"
ok "live #957: python3 << EOF KeyError with thinking-only recovery is still flagged"
rm -f "$sessions/python-traceback-thinking-only.jsonl"

# --- 3. later unrelated user-facing prose does not discharge ------------
# The live session's first user-facing text after the string of failures
# was "Now I have everything I need. Let me write the synthesis report."
# — that does not name the failure. Same class as #936's 6j and #953's
# scenario 2: real user-facing text that moves on without naming the
# failure must NOT clear the pending swallowed failure.
write_session "python-traceback-unrelated-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe3","name":"bash","arguments":{"command":"python3 << 'EOF'\nimport json, re\nv2 = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/results.json'))\nv1 = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike/results.json'))\ngt = json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike/groundtruth.json'))\ndef norm(s):\n    return re.sub(r'[^a-z0-9 ]', ' ', s.lower())\nfor d in v2:\n    dom = d['input_domain']\n    top5 = [norm(c) for c in d.get('top8', [])[:5]]\n    g = gt.get(dom, [])\n    hits = sum(1 for c in g if norm(c) in top5)\n    print(f'{dom:30s} hits={hits} p5={hits/5:.2f}')\nEOF"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe3","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<stdin>\", line 14, in <module>\nKeyError: 'input_domain'\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_retry3","name":"bash","arguments":{"command":"python3 -c \"import json; v1=json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike/results.json')); print('type v1:', type(v1).__name__); print('len:', len(v1)); print('first keys:', list(v1[0].keys()))\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_retry3","toolName":"bash","isError":false,"content":[{"type":"text","text":"type v1: <class 'list'>\nlen: 13\nfirst keys: ['input_domain', 'brand', 'site_ok', 'site_title', 'site_keywords', 'wiki_brand_page', 'wiki_categories_explored', 'wiki_sibling_count', 'ddg_ia_hit', 'openalex_work_count', 'top8', 'signals_exercised', 'signals_skipped', 'eval']"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Now I have everything I need. Let me write the synthesis report."},{"type":"toolCall","id":"call_write3","name":"bash","arguments":{"command":"python3 -c \"import json; v2=json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/results.json')); print('len v2:', len(v2))\""}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "python3 KeyError followed by unrelated prose should be a finding (got $count) $report"
ok "live #957: python3 KeyError with later 'Now I have everything I need' prose is still flagged"
rm -f "$sessions/python-traceback-unrelated-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean ---------------
# The standing rule is satisfied when the assistant names the failure in
# user-facing text in the same turn. The detector must NOT flag this.
write_session "python-traceback-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_probe4","name":"bash","arguments":{"command":"python3 -c \"import json; d=json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/results.json')); print(d['input_domain'])\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_probe4","toolName":"bash","isError":true,"content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\nKeyError: 'input_domain'\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the python3 -c probe failed with KeyError: 'input_domain' — v2 is an array, not a dict; I indexed it wrong. Re-probing with v2[0]."},{"type":"toolCall","id":"call_retry4","name":"bash","arguments":{"command":"python3 -c \"import json; v2=json.load(open('/home/nish/workspaces/agent-state/0509-transformation/discovery-spike-v2/results.json')); print(v2[0]['input_domain'])\""}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "python3 KeyError with later user-facing flag should be clean (got $count) $report"
ok "python3 KeyError plus later user-facing flag is clean"
rm -f "$sessions/python-traceback-flagged.jsonl"

# --- 5. worker.md cites fleet-ops#957 (prompt-side lock) ----------------
worker="$repo_root/prompts/worker.md"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#957' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#957 (prompt-side lock for the live Python traceback shape)"
grep -q "KeyError: 'input_domain'" "$worker" \
  || fail "prompts/worker.md must name the live KeyError wording so workers flag it"
ok "worker.md cites fleet-ops#957 and the live KeyError wording"

# --- 6. lib/failed-command-flagged.py docstring cites fleet-ops#957 ----
# (detector-side lock). The docstring is the standing-rule contract
# for the next detector maintainer, and dropping the #957 citation
# is a regression even if the drill still passes. Same pattern as
# #937 scenario 6: a future refactor that drops the citation from
# the docstring still has the prompt lock and the drill, but the
# docstring is what the next maintainer reads to know which
# session/signal the class came from.
grep -q 'fleet-ops#957' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#957 (detector-side lock)"
grep -q "KeyError, NameError" "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the Python traceback family (KeyError, NameError) for #957"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#957 and the Python traceback family"

# --- 7. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ----
grep -Fq 'bash "$here/fleet-failed-command-python-traceback.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-python-traceback: live #957 python3 KeyError/Traceback walked-past drills"
