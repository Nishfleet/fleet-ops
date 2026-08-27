#!/usr/bin/env bash
# tests/fleet-failed-command-gh-issue-view-unknown-field.test.sh
#
# fleet-ops#1219: a `gh issue view <N> -R ... --json <fields>` command with
# an unknown field (e.g. `label` instead of `labels`) is not valid. `gh issue
# view` rejects it with `Unknown JSON field: "<field>"` and the list of
# available fields, then exits 1. The assistant issued the same invalid
# `--json` filter alongside a second valid `gh issue view --json body` call in
# one turn, got the error, and later thinking-only plus follow-up toolCalls did
# not name the failure.
#
# The detector already flags this class: `gh issue view` is not in any
# no-match probe family (grep/rg/diff/ls/which/git-ref), and the toolResult has
# isError=true with `Command exited with code 1`. No `lib/failed-command-
# flagged.py` logic change is needed — a suppression would silence a real
# signal. This file locks the live #1219 shape and the three-place citation
# (docstring, prompt, test host) so a future refactor cannot regress it.
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when the
# session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T15-14-27-082Z_01a043c9-648a-75d9-add1-a7f78fe03f68.jsonl
# The agent first ran `gh issue view 1137 -R Nishfleet/fleet-ops` (no --json)
# successfully, then ran
#   `gh issue view 1137 -R Nishfleet/fleet-ops --json body,title,comments,label`
# and got the `Unknown JSON field: "label"` shape. The next assistant turn was
# a `thinking` block plus toolCalls, with no user-facing text naming the
# failure.
#
# Distinct from:
#   - #1055: `gh issue view ... --body` → `unknown flag: --body` (invalid flag,
#     not an unknown --json field)
#   - #1003: `gh issue view --json <valid fields> | python3 -c ...d['comments']`
#     → python `KeyError: 'comments'` (gh succeeded; the probe omitted a field
#     the python then tried to read)
#
# Scenarios:
#   1. live #1219 shape: `gh issue view ... --json body,title,comments,label`
#      exit 1, isError=true, thinking-only next turn -> finding. Snippet must
#      carry `Unknown JSON field: "label"`.
#   2. same shape plus a later user-facing flag -> clean.
#   3. cross-check: a valid `gh issue view ... --json body,comments,labels`
#      succeeds and is not flagged. Pin the contrast so a future refactor that
#      flags every `gh issue view` call (or the literal word `label`) is caught.
#   4. worker.md cites fleet-ops#1219 and the live `Unknown JSON field` wording
#      (prompt-side lock).
#   5. lib/failed-command-flagged.py docstring cites fleet-ops#1219
#      (detector-side lock).
#   6. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).

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

scratch="$(mktemp -d -t failed-command-gh-issue-view-unknown-field.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T08:07:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T10:00:00Z"
}

# --- 1. live #1219 shape: gh issue view --json with unknown field ----------
# Replay the exact `gh issue view 1137 -R Nishfleet/fleet-ops --json
# body,title,comments,label` failure and the thinking-only next turn that
# followed it in the live session. ToolResult text matches the live
# 01a043c9 session (includes closedByPullRequestsReferences).
write_session "gh-issue-view-unknown-field-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh1","name":"bash","arguments":{"command":"gh issue view 1137 -R Nishfleet/fleet-ops --json body,title,comments,label"}},{"type":"toolCall","id":"call_gh2","name":"bash","arguments":{"command":"gh issue view 1137 -R Nishfleet/fleet-ops --json body"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh1","toolName":"bash","isError":true,"content":[{"type":"text","text":"Unknown JSON field: \"label\"\nAvailable fields:\n  assignees\n  author\n  body\n  closed\n  closedAt\n  closedByPullRequestsReferences\n  comments\n  createdAt\n  id\n  isPinned\n  labels\n  milestone\n  number\n  projectCards\n  projectItems\n  reactionGroups\n  state\n  stateReason\n  title\n  updatedAt\n  url\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh2","toolName":"bash","isError":false,"content":[{"type":"text","text":"{\"body\":\"2026-08-27: a stale memory sent a senior worker on a goose-chase.\"}"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me also check the comments on the issue and get the full picture.","thinkingSignature":"reasoning"},{"type":"toolCall","id":"call_gh3","name":"bash","arguments":{"command":"gh issue view 1137 -R Nishfleet/fleet-ops --json comments"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1219 gh issue view --json unknown field should be a finding (got $count) $report"
slug=$(jq -r '.findings[0].slug' <<<"$report")
[[ "$slug" == "gh-issue-view-unknown-field-walked" ]] || fail "finding slug should be gh-issue-view-unknown-field-walked (got $slug)"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Unknown JSON field: "label"' <<<"$snippet" \
  || fail "finding snippet should mention 'Unknown JSON field: \"label\"' (got $snippet)"
ok "live #1219 gh issue view --json unknown field exit 1 walked past is flagged"
rm -f "$sessions/gh-issue-view-unknown-field-walked.jsonl"

# --- 2. same shape plus a later user-facing flag is clean ---------------------
# The standing rule is satisfied when the assistant names the failure in the
# same turn's user-facing text. The detector must NOT flag this. Lock the
# contrast: a worker that names the invalid field and recovers is clean.
write_session "gh-issue-view-unknown-field-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh1","name":"bash","arguments":{"command":"gh issue view 1137 -R Nishfleet/fleet-ops --json body,title,comments,label"}},{"type":"toolCall","id":"call_gh2","name":"bash","arguments":{"command":"gh issue view 1137 -R Nishfleet/fleet-ops --json body"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh1","toolName":"bash","isError":true,"content":[{"type":"text","text":"Unknown JSON field: \"label\"\nAvailable fields:\n  assignees\n  author\n  body\n  closed\n  closedAt\n  closedByPullRequestsReferences\n  comments\n  createdAt\n  id\n  isPinned\n  labels\n  milestone\n  number\n  projectCards\n  projectItems\n  reactionGroups\n  state\n  stateReason\n  title\n  updatedAt\n  url\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh2","toolName":"bash","isError":false,"content":[{"type":"text","text":"{\"body\":\"2026-08-27: a stale memory sent a senior worker on a goose-chase.\"}"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the gh issue view --json label call failed with 'Unknown JSON field: \"label\"'; I will use the correct labels field."},{"type":"toolCall","id":"call_gh3","name":"bash","arguments":{"command":"gh issue view 1137 -R Nishfleet/fleet-ops --json body,title,comments,labels"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged gh issue view --json unknown field should be clean (got $count) $report"
ok "gh issue view --json unknown field exit 1 plus later user-facing flag is clean"
rm -f "$sessions/gh-issue-view-unknown-field-flagged.jsonl"

# --- 3. cross-check: a valid gh issue view --json succeeds ------------------
# `gh issue view <N> -R ... --json body,comments,labels` is a canonical
# step-1 command and should be isError=false. Pin the contrast so a future
# refactor that flags every `gh issue view` call (or the word `label`) is
# caught.
write_session "gh-issue-view-json-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh3","name":"bash","arguments":{"command":"gh issue view 1137 -R Nishfleet/fleet-ops --json body,comments,labels"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh3","toolName":"bash","isError":false,"content":[{"type":"text","text":"{\"body\":\"2026-08-27: a stale memory sent a senior worker on a goose-chase.\",\"comments\":[]}"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Read the issue. Continuing with the implementation."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "valid gh issue view --json should be clean (got $count) $report"
ok "valid gh issue view --json success is not flagged (contrast with #1219)"
rm -f "$sessions/gh-issue-view-json-ok.jsonl"

# --- 4. prompts/worker.md cites fleet-ops#1219 (prompt-side lock) -----------
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1219' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1219 (prompt-side lock)"
grep -q 'Unknown JSON field' "$worker" \
  || fail "prompts/worker.md must name the live 'Unknown JSON field' wording"
grep -q "gh issue view" "$worker" \
  || fail "prompts/worker.md must name the live 'gh issue view' command"
ok "worker.md cites fleet-ops#1219 and the gh issue view --json unknown field live wording"

# --- 5. lib/failed-command-flagged.py docstring cites fleet-ops#1219 ---------
grep -q 'fleet-ops#1219' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1219 (detector-side lock)"
grep -q 'Unknown JSON field' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'Unknown JSON field' wording"
grep -q "gh issue view" "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'gh issue view' command"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1219 and the gh issue view --json unknown field shape"

# --- 6. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ---------
grep -Fq 'bash "$here/fleet-failed-command-gh-issue-view-unknown-field.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-gh-issue-view-unknown-field: live #1219 gh issue view --json unknown field drills"
