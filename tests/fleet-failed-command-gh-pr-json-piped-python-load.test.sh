#!/usr/bin/env bash
# tests/fleet-failed-command-gh-pr-json-piped-python-load.test.sh
#
# fleet-ops#5010: the `gh pr view <N> --json <invalid-field> | python3 -c
# "import sys,json; ...json.load(sys.stdin)"` pipeline. Asking gh for a
# merge-queue field that does not exist on `gh pr view` (`isInMergeQueue`,
# `mergeQueueEntry`) makes gh print its field error to stderr, leave
# stdout empty, and exit non-zero; the trailing python reads empty stdin
# and fails `json.load` with `JSONDecodeError: Expecting value: line 1
# column 1 (char 0)`. Unlike the `| head` sibling (fleet-ops#1193), the
# `| python3` tail does NOT mask the failure: python exits 1, so the
# toolResult carries `isError=true` and `Command exited with code 1`.
# The assistant walked it past with cause-prose naming the field ("The
# `isInMergeQueue` field doesn't exist") — a cause, never a flag of the
# failed `json.load` — then silently retried. That is a genuine swallowed
# failure the detector MUST flag (fleet-ops#1052: cause-prose is not a
# flag).
#
# The detector already flags this class via the generic isError path.
# No `lib/failed-command-flagged.py` logic change is needed — a
# suppression would silence a real signal. The tempting future
# exemptions this file forbids:
#   - treating a `| python3 ... json.load` failure like the `| head`
#     pipe-mask (fleet-ops#1193): python exits 1, so this is NOT the
#     isError=false mask; it stays a finding.
#   - treating cause-prose that names the bogus field ("isInMergeQueue
#     doesn't exist") as discharging the pending failure (fleet-ops#1052)
#   - letting a same-turn silent retry (`--json autoMergeRequest,
#     mergeStateStatus`) clear the pending failure
#
# Distinct from:
#   - #1244 (gh-pr-view-merged.test.sh): UNPIPED `gh pr view --json
#     mergedAt,merged` — prints `Unknown JSON field: "merged"`, no pipe.
#     This lock is the PIPED-to-python variant that turns the gh field
#     error into a `JSONDecodeError` on empty stdin.
#   - #1193 / live #1074 sibling: the SAME field error piped through
#     `2>&1 | head` — head exits 0, isError=false, detector MUST stay
#     silent (pipe-masked; mechanism-impossible). `| python3` is the
#     OPPOSITE: it stays isError=true and must be flagged. Locking #5010
#     must not collapse the `| python3` shape into the `| head` shape.
#
# Live session: 2026-09-09T21-12-22-081Z_0509-2144-1788988341792251501.jsonl
# The 0509 worker checking PR #2232's merge-queue status ran
#   `gh pr view 2232 -R Nishfleet/0509 --json mergeStateStatus,isInMergeQueue,mergeQueueEntry 2>&1 | python3 -c "import sys,json; d=json.load(sys.stdin); print('mergeStateStatus:', d['mergeStateStatus']); print('isInMergeQueue:', d.get('isInMergeQueue')); print('mergeQueueEntry:', d.get('mergeQueueEntry'))" 2>&1`
# and got the live `JSONDecodeError` + `Command exited with code 1`
# (isError=true, details={}). The next turn was thinking-only cause-prose
# ("The `isInMergeQueue` field doesn't exist. Let me check the available
# fields and the merge queue state.") plus silent retries.
#
# Scenarios:
#   1. live #5010 shape: `gh pr view --json <invalid> | python3 -c
#      json.load`, isError=true, thinking-only cause-prose + silent
#      retry -> finding. Snippet must carry `json/__init__.py`.
#   2. same shape plus a later user-facing flag -> clean.
#   3. contrast: valid `gh pr view --json autoMergeRequest,mergeStateStatus`
#      piped to python success is not flagged (valid-field pipe is not a
#      false positive).
#   4. class lock: unpiped `gh pr view --json mergeStateStatus,mergeQueueEntry`
#      walked past is also a finding — the merge-queue-field class, not one
#      field id (live session also carried the unpiped sibling probe).
#   5. worker.md cites fleet-ops#5010 and the merge-queue json.load wording.
#   6. lib/failed-command-flagged.py docstring cites fleet-ops#5010.
#   7. seat.lib.test.sh hosts this file (CI cannot gain a P14 line).

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

scratch="$(mktemp -d -t failed-command-gh-pr-json-piped-python.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-09-09T22:00:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-09-09T23:00:00Z"
}

# --- 1. live #5010 shape: gh --json invalid-field piped to python json.load -
# The python tail keeps the exit (unlike `| head`), so isError=true and the
# JSONDecodeError-on-empty-stdin is a real swallowed failure. Cause-prose
# ("field doesn't exist") is not a flag (fleet-ops#1052).
write_session "gh-pr-json-piped-python-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Check whether PR #2232 is enqueued for merge under the merge queue."},{"type":"toolCall","id":"call_py1","name":"bash","arguments":{"command":"gh pr view 2232 -R Nishfleet/0509 --json mergeStateStatus,isInMergeQueue,mergeQueueEntry 2>&1 | python3 -c \"import sys,json; d=json.load(sys.stdin); print('mergeStateStatus:', d['mergeStateStatus']); print('isInMergeQueue:', d.get('isInMergeQueue')); print('mergeQueueEntry:', d.get('mergeQueueEntry'))\" 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_py1","toolName":"bash","content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\n  File \"/usr/lib/python3.12/json/__init__.py\", line 293, in load\n    return loads(fp.read(),\n           ^^^^^^^^^^^^^^^^\n  File \"/usr/lib/python3.12/json/__init__.py\", line 346, in loads\n    return _default_decoder.decode(s)\n           ^^^^^^^^^^^^^^^^^^^^^^^^^^\n  File \"/usr/lib/python3.12/json/decoder.py\", line 337, in decode\n    obj, end = self.raw_decode(s, idx=_w(s, 0).end())\n               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n  File \"/usr/lib/python3.12/json/decoder.py\", line 355, in raw_decode\n    raise JSONDecodeError(\"Expecting value\", s, err.value) from None\njson.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)\n\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The isInMergeQueue field doesn't exist. Let me check the available fields and the merge queue state."},{"type":"toolCall","id":"call_retry","name":"bash","arguments":{"command":"gh pr view 2232 -R Nishfleet/0509 --json autoMergeRequest,mergeStateStatus 2>&1"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #5010 gh pr view --json invalid piped to python json.load walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'json/__init__.py' <<<"$snippet" \
  || fail "finding snippet should carry the json.load traceback (got $snippet)"
ok "live #5010: gh pr view --json invalid-field | python json.load with cause-prose retry is flagged"
rm -f "$sessions/gh-pr-json-piped-python-walked.jsonl"

# --- 2. same shape plus a later user-facing flag is clean -------------------
write_session "gh-pr-json-piped-python-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_py2","name":"bash","arguments":{"command":"gh pr view 2232 -R Nishfleet/0509 --json mergeStateStatus,isInMergeQueue,mergeQueueEntry 2>&1 | python3 -c \"import sys,json; d=json.load(sys.stdin); print('mergeStateStatus:', d['mergeStateStatus'])\" 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_py2","toolName":"bash","content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\n  File \"/usr/lib/python3.12/json/__init__.py\", line 293, in load\n    return loads(fp.read(),\n           ^^^^^^^^^^^^^^^^\n  File \"/usr/lib/python3.12/json/__init__.py\", line 346, in loads\n    return _default_decoder.decode(s)\n           ^^^^^^^^^^^^^^^^^^^^^^^^^^\n  File \"/usr/lib/python3.12/json/decoder.py\", line 337, in decode\n    obj, end = self.raw_decode(s, idx=_w(s, 0).end())\n               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^\n  File \"/usr/lib/python3.12/json/decoder.py\", line 355, in raw_decode\n    raise JSONDecodeError(\"Expecting value\", s, err.value) from None\njson.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)\n\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the gh pr view --json isInMergeQueue,mergeQueueEntry call piped to python failed with JSONDecodeError on empty stdin, because those fields do not exist on gh pr view. I will use --json autoMergeRequest,mergeStateStatus instead."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "piped-to-python gh pr view --json invalid plus later user-facing flag should be clean (got $count) $report"
ok "gh pr view --json invalid-field | python json.load plus later user-facing flag is clean"
rm -f "$sessions/gh-pr-json-piped-python-flagged.jsonl"

# --- 3. valid gh pr view --json piped to python success is not flagged ------
write_session "gh-pr-json-piped-python-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_py3","name":"bash","arguments":{"command":"gh pr view 2232 -R Nishfleet/0509 --json autoMergeRequest,mergeStateStatus 2>&1 | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d.get('mergeStateStatus'))\" 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_py3","toolName":"bash","isError":false,"content":[{"type":"text","text":"CLEAN\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"PR #2232 is CLEAN. Continuing."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "valid gh pr view --json piped to python success should be clean (got $count) $report"
ok "valid gh pr view --json autoMergeRequest piped to python success is not flagged (contrast with #5010)"
rm -f "$sessions/gh-pr-json-piped-python-ok.jsonl"

# --- 4. class lock: unpiped merge-queue invalid-field walk past is flagged ---
# The live #5010 session also probed `gh pr view --json mergeQueueEntry`
# (unpiped) and got the `Unknown JSON field` shape. The lock is the
# merge-queue-field class, not one field id.
write_session "gh-pr-json-mergequeueentry-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_mq","name":"bash","arguments":{"command":"gh pr view 2232 -R Nishfleet/0509 --json mergeStateStatus,mergeQueueEntry 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_mq","toolName":"bash","content":[{"type":"text","text":"Unknown JSON field: \"mergeQueueEntry\"\nAvailable fields:\n  autoMergeRequest\n  mergeable\n  mergeStateStatus\n  state\n\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_mq2","name":"bash","arguments":{"command":"gh pr view 2232 -R Nishfleet/0509 --json autoMergeRequest,mergeStateStatus"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "unpiped gh pr view --json mergeQueueEntry walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Unknown JSON field: "mergeQueueEntry"' <<<"$snippet" \
  || fail "finding snippet should mention Unknown JSON field: \"mergeQueueEntry\" (got $snippet)"
ok "unpiped gh pr view --json mergeQueueEntry walked past is flagged (merge-queue-field class lock)"
rm -f "$sessions/gh-pr-json-mergequeueentry-walked.jsonl"

# --- 5. prompts/worker.md cites fleet-ops#5010 (prompt-side lock) -----------
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#5010' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#5010 (prompt-side lock)"
grep -q 'isInMergeQueue' "$worker" \
  || fail "prompts/worker.md must name the live '--json ... isInMergeQueue' field"
ok "worker.md cites fleet-ops#5010 and the piped-to-python merge-queue json.load shape"

# --- 6. lib/failed-command-flagged.py docstring cites fleet-ops#5010 --------
grep -q 'fleet-ops#5010' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#5010 (detector-side lock)"
grep -q 'isInMergeQueue' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'isInMergeQueue' wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#5010 and the gh --json | python json.load shape"

# --- 7. seat.lib.test.sh hosts this file (CI cannot gain a P14 line) --------
grep -Fq 'bash "$here/fleet-failed-command-gh-pr-json-piped-python-load.test.sh"' \
  "$here/seat.lib.test.sh" \
  || fail "seat.lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat.lib.test.sh hosts this file"