#!/usr/bin/env bash
# tests/fleet-worker-prompt-gh-pr-view-unknown-field.test.sh
#
# fleet-ops#1193: a `gh pr view <N> -R ... --json <fields>` command with an
# unknown field (e.g. `merged` instead of the valid `mergedAt`) is rejected by
# `gh` with `Unknown JSON field: "<field>"` and a non-zero exit. When the call
# is piped through `2>&1 | head`, the harness reports `isError: false` (head
# exits 0) so the failure is masked and the worker walks past it.
#
# The detector cannot catch the piped shape (the #1048/#1122 isError
# contract treats isError:false as content). Prevention is worker-side:
# prompts/worker.md must warn about the class and that piping masks the
# exit code. This file also locks the detector 0-findings contract for
# the live piped shape so a future refactor cannot add `Unknown JSON
# field` to REAL_ERR_RE (or anywhere before the isError=false
# short-circuit) without going red.
#
# Live session: 2026-08-27T08-16-44-255Z_01a0424a-f6df-7cc2-b1c3-f5db8df57d11.jsonl
#   `gh pr view 1026 -R Nishfleet/fleet-ops --json number,title,state,body,url,headRefName,merged 2>&1 | head -40`
#   toolResult isError:false, text starts with `Unknown JSON field: "merged"`
#   next 4 assistant turns empty (lines 33-36). Distinct from #1219
#   (unpiped `gh issue view --json label`, isError=true).
#
# Scenarios:
#   1. worker.md wording lock (gh pr view, Unknown JSON field, 2>&1 | head,
#      isError: false, fleet-ops#1193).
#   2. live piped shape: isError:false + Unknown JSON field + empty next
#      turns -> 0 findings (mechanism-impossible; a5022b8 / #1048 / #1122).
#   3. unpiped positive control: same body with isError:true and
#      `Command exited with code 1` + empty next turns -> 1 finding.
#   4. lib/failed-command-flagged.py docstring cites fleet-ops#1193.
#   5. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
prompt="$repo_root/prompts/worker.md"
lib="$repo_root/lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$prompt" ]] || fail "missing $prompt"
[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

grep -q 'gh pr view' "$prompt" \
  || fail "worker.md must warn about gh pr view --json invalid-field (fleet-ops#1193)"
ok "worker.md warns about gh pr view --json invalid-field"

grep -q 'Unknown JSON field' "$prompt" \
  || fail "worker.md must cite the gh pr view mergedAt/merged class (fleet-ops#1193)"
ok "worker.md cites the mergedAt/merged class"

grep -q '2>&1 | head' "$prompt" \
  || fail "worker.md must warn that piping gh pr view through head masks the exit code (fleet-ops#1193)"
ok "worker.md warns that piping through head masks the exit code"

grep -q 'isError: false' "$prompt" \
  || fail "worker.md must state the isError:false pipe-mask consequence (fleet-ops#1193)"
ok "worker.md states the isError:false pipe-mask consequence"

grep -q 'fleet-ops#1193' "$prompt" \
  || fail "worker.md must cite fleet-ops#1193"
ok "worker.md cites fleet-ops#1193"

scratch="$(mktemp -d -t worker-prompt-gh-pr-view-unknown-field.XXXXXX)"
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

# Live piped body from 01a0424a (head -40 truncated the Available-fields
# list; no `Command exited with code` trailer because head exited 0).
# --- 2. live #1193 piped shape: isError:false is content, not a finding -----
write_session "gh-pr-view-unknown-field-piped" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_pr1","name":"bash","arguments":{"command":"gh pr view 1026 -R Nishfleet/fleet-ops --json number,title,state,body,url,headRefName,merged 2>&1 | head -40"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_pr1","toolName":"bash","isError":false,"content":[{"type":"text","text":"Unknown JSON field: \"merged\"\nAvailable fields:\n  additions\n  assignees\n  author\n  autoMergeRequest\n  baseRefName\n  baseRefOid\n  body\n  changedFiles\n  closed\n  closedAt\n  closingIssuesReferences\n  comments\n  commits\n  createdAt\n  deletions\n  files\n  fullDatabaseId\n  headRefName\n  headRefOid\n  headRepository\n  headRepositoryOwner\n  id\n  isCrossRepository\n  isDraft\n  labels\n  latestReviews\n  maintainerCanModify\n  mergeCommit\n  mergeStateStatus\n  mergeable\n  mergedAt\n  mergedBy\n  milestone\n  number\n  potentialMergeCommit\n  projectCards\n  projectItems\n  reactionGroups\n"}]}}
{"type":"message","message":{"role":"assistant","content":[]}}
{"type":"message","message":{"role":"assistant","content":[]}}
{"type":"message","message":{"role":"assistant","content":[]}}
{"type":"message","message":{"role":"assistant","content":[]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "piped gh pr view --json unknown field (isError:false) must be 0 findings (got $count) $report"
ok "live #1193 piped gh pr view --json unknown field isError:false is not a detector finding"
rm -f "$sessions/gh-pr-view-unknown-field-piped.jsonl"

# --- 3. unpiped positive control: isError:true is still flagged -------------
write_session "gh-pr-view-unknown-field-unpiped" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_pr2","name":"bash","arguments":{"command":"gh pr view 1026 -R Nishfleet/fleet-ops --json number,title,state,body,url,headRefName,merged 2>&1"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_pr2","toolName":"bash","isError":true,"content":[{"type":"text","text":"Unknown JSON field: \"merged\"\nAvailable fields:\n  additions\n  assignees\n  author\n  autoMergeRequest\n  baseRefName\n  mergedAt\n  mergedBy\n  number\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "unpiped gh pr view --json unknown field (isError:true) should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Unknown JSON field: "merged"' <<<"$snippet" \
  || fail "unpiped finding snippet should mention Unknown JSON field: \"merged\" (got $snippet)"
ok "unpiped gh pr view --json unknown field isError:true is flagged (contrast with #1193 pipe-mask)"
rm -f "$sessions/gh-pr-view-unknown-field-unpiped.jsonl"

# --- 4. detector docstring cites fleet-ops#1193 -----------------------------
grep -q 'fleet-ops#1193' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1193 (detector-side lock)"
grep -q 'gh pr view' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live gh pr view command"
grep -q 'mergedAt' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the valid mergedAt field"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1193 and the gh pr view pipe-mask shape"

# --- 5. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) --------
grep -Fq 'bash "$here/fleet-worker-prompt-gh-pr-view-unknown-field.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

ok "worker-prompt gh pr view unknown-field wording locked (fleet-ops#1193)"
