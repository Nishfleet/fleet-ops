#!/usr/bin/env bash
# tests/fleet-failed-command-gh-pr-view-merged.test.sh
#
# fleet-ops#1244: an UNPIPED `gh pr view <N> --json mergedAt,merged`
# (or `--json merged`) is not valid because `gh pr view` has no JSON
# field named `merged`. The valid fields are `mergedAt` / `mergedBy` /
# `state`. `gh` prints `Unknown JSON field: "merged"` and exits 1 with
# isError=true. The assistant walked past it with a thinking-only note
# ("doesn't have the mergedAt field") plus a silent retry
# (`gh pr view --json title,state`), never naming the failure in
# user-facing text.
#
# The detector already flags this class via the generic isError path.
# No `lib/failed-command-flagged.py` logic change is needed — a
# suppression would silence a real signal. The tempting future
# exemptions this file forbids:
#   - treating `Unknown JSON field` as content whenever the command
#     text contains `gh` (it is a real failure, not a probe)
#   - treating a thinking-only note that guesses at the field as a flag
#   - letting a same-turn silent retry (`--json title,state`) discharge
#     the pending failure
#   - adding `Unknown JSON field` to REAL_ERR_RE and checking it when
#     isError is false (that would break the #1048 / #1122 / #1074
#     contract: successful output that quotes error strings is content)
#
# Distinct from:
#   - #1055: `gh issue view ... --body` -> `unknown flag: --body`
#   - #1003: valid `gh issue view --json <fields>` piped to python3
#     hitting KeyError because the --json filter omitted a field
#   - #1219: `gh issue view ... --json ... label` ->
#     `Unknown JSON field: "label"` (issue view, wrong field name;
#     this lock is pr view + `merged`)
#   - #1193 / live #1074 sibling: the SAME `Unknown JSON field: "merged"`
#     text piped through `head`, so bash exits 0, isError=false, and
#     the detector MUST stay silent (pipe-masked; mechanism-impossible)
#
# Live session: 2026-08-27T15-58-21-599Z_01a043f1-979f-75e8-93f5-9b72f5c84db9.jsonl
# The senior-auditor session ran
#   `gh pr view 392 -R Nishfleet/fleet-ops --json mergedAt,merged 2>&1`
# and got the live `Unknown JSON field: "merged"` + Available fields
# listing `mergedAt`/`mergedBy` but not `merged` +
# `Command exited with code 1` (isError=true, details={}). The next
# turn was thinking-only plus `gh pr view 392 ... --json title,state`.
#
# Scenarios:
#   1. live #1244 shape: unpiped `--json mergedAt,merged` exit 1,
#      isError=true, thinking-only silent retry -> finding. Snippet
#      must carry `Unknown JSON field: "merged"`.
#   2. same shape plus a later user-facing flag -> clean.
#   3. cross-check: valid `gh pr view --json mergedAt` success is
#      not flagged. Pin so a future refactor that flags every
#      `gh pr view` call (or the literal `merged`) is caught.
#   4. cross-check: the SAME error text piped through `head` with
#      isError=false stays clean (#1193 pipe-mask). Locking #1244
#      must not collapse into "every Unknown JSON field is a failure".
#   5. class lock: unpiped `--json closedReason` walked past is
#      also a finding. The lock is the invalid-field class, not
#      one field id (live session also carried this sibling).
#   6. worker.md cites fleet-ops#1244 and the live wording.
#   7. lib/failed-command-flagged.py docstring cites fleet-ops#1244.
#   8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"
worker="$repo_root/lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-gh-pr-view-merged.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T16:02:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T18:00:00Z"
}

# --- 1. live #1244 shape: unpiped --json merged walked past ----------------
# Replay the exact `gh pr view 392 ... --json mergedAt,merged 2>&1`
# failure and the thinking-only silent retry that followed it.
write_session "gh-pr-view-merged-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Check if PR #392 is merged."},{"type":"toolCall","id":"call_gh1","name":"bash","arguments":{"command":"gh pr view 392 -R Nishfleet/fleet-ops --json mergedAt,merged 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh1","toolName":"bash","content":[{"type":"text","text":"Unknown JSON field: \"merged\"\nAvailable fields:\n  additions\n  assignees\n  author\n  autoMergeRequest\n  baseRefName\n  baseRefOid\n  body\n  changedFiles\n  closed\n  closedAt\n  closingIssuesReferences\n  comments\n  mergeStateStatus\n  mergeable\n  mergedAt\n  mergedBy\n  state\n  title\n  url\n\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Good. PR #392 doesn't exist or doesn't have the mergedAt field. Let me check if PR #392 exists at all, and also check the rc propagation."},{"type":"toolCall","id":"call_retry","name":"bash","arguments":{"command":"gh pr view 392 -R Nishfleet/fleet-ops --json title,state 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_retry","toolName":"bash","isError":false,"content":[{"type":"text","text":"{\"title\":\"ci: auto-revert on red required checks\",\"state\":\"CLOSED\"}\n"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1244 gh pr view --json merged walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Unknown JSON field: "merged"' <<<"$snippet" \
  || fail "finding snippet should mention Unknown JSON field: \"merged\" (got $snippet)"
ok "live #1244: unpiped gh pr view --json merged with thinking-only retry is flagged"
rm -f "$sessions/gh-pr-view-merged-walked.jsonl"

# --- 2. same shape plus a later user-facing flag is clean ------------------
write_session "gh-pr-view-merged-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh2","name":"bash","arguments":{"command":"gh pr view 392 -R Nishfleet/fleet-ops --json mergedAt,merged 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh2","toolName":"bash","content":[{"type":"text","text":"Unknown JSON field: \"merged\"\nAvailable fields:\n  mergedAt\n  mergedBy\n  state\n\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the gh pr view --json mergedAt,merged call failed with Unknown JSON field: \"merged\". I will use --json mergedAt,state instead."},{"type":"toolCall","id":"call_ok","name":"bash","arguments":{"command":"gh pr view 392 -R Nishfleet/fleet-ops --json mergedAt,state"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged gh pr view --json merged should be clean (got $count) $report"
ok "unpiped gh pr view --json merged plus later user-facing flag is clean"
rm -f "$sessions/gh-pr-view-merged-flagged.jsonl"

# --- 3. valid gh pr view --json mergedAt success is not flagged ------------
write_session "gh-pr-view-mergedAt-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh3","name":"bash","arguments":{"command":"gh pr view 392 -R Nishfleet/fleet-ops --json mergedAt,state"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh3","toolName":"bash","isError":false,"content":[{"type":"text","text":"{\"mergedAt\":null,\"state\":\"CLOSED\"}\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"PR 392 is CLOSED and was not merged. Continuing."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "valid gh pr view --json mergedAt should be clean (got $count) $report"
ok "valid gh pr view --json mergedAt success is not flagged (contrast with #1244)"
rm -f "$sessions/gh-pr-view-mergedAt-ok.jsonl"

# --- 4. pipe-masked Unknown JSON field (isError=false) stays clean ---------
# Live #1193 / #1074 sibling: `gh pr view --json ... merged 2>&1 | head -40`
# prints the same error text but head exits 0, so Pi reports isError=false.
# The detector contract is isError=true = failure. Locking #1244 must not
# add Unknown JSON field to REAL_ERR_RE for isError=false content.
write_session "gh-pr-view-merged-piped-head" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh4","name":"bash","arguments":{"command":"gh pr view 1026 -R Nishfleet/fleet-ops --json number,title,state,body,url,headRefName,merged 2>&1 | head -40"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh4","toolName":"bash","isError":false,"content":[{"type":"text","text":"Unknown JSON field: \"merged\"\nAvailable fields:\n  additions\n  assignees\n  author\n  mergedAt\n  mergedBy\n  state\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Continuing with the rest of the checks."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "pipe-masked Unknown JSON field with isError=false must stay clean (got $count) $report"
ok "piped gh pr view --json merged through head (isError=false) stays clean (contrast with #1244)"
rm -f "$sessions/gh-pr-view-merged-piped-head.jsonl"

# --- 5. class lock: unpiped --json closedReason walked past is flagged -----
# The live #1244 session also ran `gh pr view --json closedReason` and got
# the same Unknown JSON field shape. The lock is the class, not one field.
write_session "gh-pr-view-closedReason-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh5","name":"bash","arguments":{"command":"gh pr view 392 -R Nishfleet/fleet-ops --json closedReason 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh5","toolName":"bash","content":[{"type":"text","text":"Unknown JSON field: \"closedReason\"\nAvailable fields:\n  additions\n  closedAt\n  mergedAt\n  state\n\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_next","name":"bash","arguments":{"command":"gh pr view 392 -R Nishfleet/fleet-ops --json title,state"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "unpiped gh pr view --json closedReason walked past should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Unknown JSON field: "closedReason"' <<<"$snippet" \
  || fail "finding snippet should mention Unknown JSON field: \"closedReason\" (got $snippet)"
ok "unpiped gh pr view --json closedReason walked past is flagged (class lock)"
rm -f "$sessions/gh-pr-view-closedReason-walked.jsonl"

# --- 6. prompts/worker.md cites fleet-ops#1244 (prompt-side lock) ----------
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1244' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1244 (prompt-side lock)"
grep -q 'Unknown JSON field: "merged"' "$worker" \
  || fail "prompts/worker.md must name the live 'Unknown JSON field: \"merged\"' wording"
grep -q 'gh pr view' "$worker" \
  || fail "prompts/worker.md must name the live 'gh pr view' command"
ok "worker.md cites fleet-ops#1244 and the live gh pr view --json merged wording"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#1244 -------
grep -q 'fleet-ops#1244' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1244 (detector-side lock)"
grep -q 'Unknown JSON field: "merged"' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'Unknown JSON field: \"merged\"' wording"
grep -q 'gh pr view 392' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'gh pr view 392' wording"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1244 and the gh pr view --json merged shape"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-gh-pr-view-merged.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-gh-pr-view-merged: live #1244 unpiped --json merged drills"
