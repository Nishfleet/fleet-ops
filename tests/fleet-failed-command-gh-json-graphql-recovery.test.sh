#!/usr/bin/env bash
# tests/fleet-failed-command-gh-json-graphql-recovery.test.sh
#
# fleet-ops#1142: the same `gh issue view --comments --json
# author,body,createdAt | python3 -c "...d['comments']..."` pipe that
# #1003 locked, on a DIFFERENT session, recovered via a successful
# `gh api graphql` comments query with only a thinking-block note
# ("the same bug"). That is still a swallowed failure.
#
# The detector already flags this class via the generic python-traceback
# / isError path (#957 / #1003). No `lib/failed-command-flagged.py`
# logic change is needed; a suppression would silence a real signal.
# The tempting future exemptions this file forbids:
#   - treating a later successful `gh api graphql` comments query as
#     discharging the KeyError (the GraphQL call did not name the
#     failed command)
#   - treating a thinking block that says "the same bug" as a
#     user-facing flag (thinking is not user-facing; FLAG_RE also does
#     not match "bug")
#   - treating `KeyError: 'comments'` as a benign JSON no-match probe
#   - letting the #1003 toolCall-only re-probe lock stand in for this
#     GraphQL-recovery fingerprint so the live #1142 wording can drop
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when
# the session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T12-16-45-004Z_01a04326-b3cc-707d-bc8e-51c4cc683322.jsonl
# The worker claiming fleet-ops#1003 ran:
#   gh issue view 1003 -R Nishfleet/fleet-ops --comments --json
#   author,body,createdAt 2>&1 | python3 -c "...d['comments']..."
# which crashed with
#   Traceback (most recent call last):
#     File "<string>", line 1, in <module>
#   KeyError: 'comments'
#   Command exited with code 1
# (isError=true, details={}). The next turn was thinking
# ("Ha - the same bug!") plus a successful
#   gh api graphql ... issue(number: 1003) { comments(last: 20) ... }
# pipe. No user-facing text named the failure. Detector snippet:
#   Traceback ... KeyError: 'comments' ... Command exited with code 1
#
# Distinct from:
#   - #1003 / 01a041a5: same KeyError pipe against issue 844, recovered
#     with a toolCall-only re-probe of a slightly different --json
#     filter (still the broken python), not GraphQL
#   - #957: python3 -c KeyError: 'input_domain' against eval JSON, not
#     a gh | python3 pipe
#
# Scenarios:
#   1. live #1142 shape: gh --json + python3 KeyError: 'comments' +
#      thinking + successful graphql recovery -> finding. Snippet must
#      carry Traceback and KeyError: 'comments'.
#   2. same shape plus a later thinking-only note -> still a finding.
#   3. same shape plus later unrelated user-facing prose that does NOT
#      name the failure -> still a finding.
#   4. same shape plus a later user-facing flag -> clean.
#   5. cross-check: a successful `gh api graphql` comments query with
#      no prior KeyError stays clean (locking #1142 must not collapse
#      into "every graphql comments query is a failure").
#   6. worker.md cites fleet-ops#1142 and the live `gh issue view 1003`
#      + `gh api graphql` wording (prompt-side lock).
#   7. lib/failed-command-flagged.py docstring cites fleet-ops#1142
#      (detector-side lock).
#   8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line).

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

scratch="$(mktemp -d -t failed-command-gh-json-graphql.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions"
mkdir -p "$sessions"

write_session() {
  local name="$1"
  cat >"$sessions/$name.jsonl"
  touch -d "2026-08-27T12:16:00Z" "$sessions/$name.jsonl"
}

run_scan() {
  python3 "$lib" scan \
    --root "$sessions" \
    --window-hours 24 \
    --grace-minutes 0 \
    --now "2026-08-27T13:00:00Z"
}

# --- 1. live #1142 shape: KeyError + thinking + graphql recovery ----------
# Replay slug 01a04326: gh --json omits comments, python indexes
# d['comments'], next turn is thinking "the same bug" plus a successful
# gh api graphql comments query.
write_session "gh-json-graphql-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh1","name":"bash","arguments":{"command":"gh issue view 1003 -R Nishfleet/fleet-ops --comments --json author,body,createdAt 2>&1 | python3 -c \"import json,sys; d=json.load(sys.stdin); [print(c['author']['login'],c['createdAt'],':',c['body'][:300]) for c in d['comments']]\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh1","toolName":"bash","content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\nKeyError: 'comments'\n\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Ha - the same bug! The Python script tries to access d['comments'] but gh issue view --json author,body,createdAt doesn't include comments. Let me try a different approach."},{"type":"toolCall","id":"call_gql1","name":"bash","arguments":{"command":"gh api graphql -f query='query { repository(owner: \"Nishfleet\", name: \"fleet-ops\") { issue(number: 1003) { comments(last: 20) { nodes { author { login } body createdAt } } } } }' 2>&1 | python3 -c \"import json,sys; d=json.load(sys.stdin); [print(c['author']['login'],c['createdAt'],':',c['body'][:300]) for c in d['data']['repository']['issue']['comments']['nodes']]\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gql1","toolName":"bash","isError":false,"content":[{"type":"text","text":"nish3451 2026-08-27T12:16:43Z : claimed by pi-issue-fleet-ops-1003 at 2026-08-27T12:16:41Z\n"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1142 gh --json KeyError with graphql recovery should be a finding (got $count) $report"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q 'Traceback' <<<"$snippet" \
  || fail "finding snippet should mention Traceback (got $snippet)"
grep -q "KeyError: 'comments'" <<<"$snippet" \
  || fail "finding snippet should mention KeyError: 'comments' (got $snippet)"
ok "live #1142: gh --json KeyError: 'comments' with silent graphql recovery is flagged"
rm -f "$sessions/gh-json-graphql-walked.jsonl"

# --- 2. thinking-only recovery is still a finding --------------------------
write_session "gh-json-graphql-thinking" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh2","name":"bash","arguments":{"command":"gh issue view 1003 -R Nishfleet/fleet-ops --comments --json author,body,createdAt 2>&1 | python3 -c \"import json,sys; d=json.load(sys.stdin); [print(c['author']['login'],c['createdAt'],':',c['body'][:300]) for c in d['comments']]\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh2","toolName":"bash","content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\nKeyError: 'comments'\n\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"The same bug. Switching to graphql for the comments."},{"type":"toolCall","id":"call_gql2","name":"bash","arguments":{"command":"gh api graphql -f query='query { repository(owner: \"Nishfleet\", name: \"fleet-ops\") { issue(number: 1003) { comments(last: 20) { nodes { author { login } } } } } }'"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1142 KeyError with later thinking-only recovery should be a finding (got $count) $report"
ok "live #1142: gh --json KeyError: 'comments' with later thinking-only recovery is still flagged"
rm -f "$sessions/gh-json-graphql-thinking.jsonl"

# --- 3. later unrelated user-facing prose does not discharge ---------------
write_session "gh-json-graphql-prose" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh3","name":"bash","arguments":{"command":"gh issue view 1003 -R Nishfleet/fleet-ops --comments --json author,body,createdAt 2>&1 | python3 -c \"import json,sys; d=json.load(sys.stdin); [print(c['author']['login'],c['createdAt'],':',c['body'][:300]) for c in d['comments']]\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh3","toolName":"bash","content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\nKeyError: 'comments'\n\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The claim comment names my unit. Creating the worktree next."},{"type":"toolCall","id":"call_gql3","name":"bash","arguments":{"command":"gh api graphql -f query='query { repository(owner: \"Nishfleet\", name: \"fleet-ops\") { issue(number: 1003) { comments(last: 20) { nodes { author { login } } } } } }'"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1142 KeyError followed by unrelated prose should be a finding (got $count) $report"
ok "live #1142: gh --json KeyError: 'comments' with unrelated user-facing prose is still flagged"
rm -f "$sessions/gh-json-graphql-prose.jsonl"

# --- 4. same shape plus a later user-facing flag is clean ------------------
write_session "gh-json-graphql-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh4","name":"bash","arguments":{"command":"gh issue view 1003 -R Nishfleet/fleet-ops --comments --json author,body,createdAt 2>&1 | python3 -c \"import json,sys; d=json.load(sys.stdin); [print(c['author']['login'],c['createdAt'],':',c['body'][:300]) for c in d['comments']]\""}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh4","toolName":"bash","content":[{"type":"text","text":"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\nKeyError: 'comments'\n\n\nCommand exited with code 1"}],"details":{},"isError":true}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the python3 -c probe failed with KeyError: 'comments' (gh --json omitted the field). switching to graphql."},{"type":"toolCall","id":"call_gql4","name":"bash","arguments":{"command":"gh api graphql -f query='query { repository(owner: \"Nishfleet\", name: \"fleet-ops\") { issue(number: 1003) { comments(last: 20) { nodes { author { login } } } } } }'"}}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "live #1142 KeyError with later user-facing flag should be clean (got $count) $report"
ok "gh --json KeyError: 'comments' plus later user-facing flag is clean"
rm -f "$sessions/gh-json-graphql-flagged.jsonl"

# --- 5. cross-check: successful graphql with no prior KeyError stays clean
# Locking the #1142 graphql-recovery fingerprint must not collapse into
# "every gh api graphql comments query is a failure".
write_session "graphql-only-clean" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Pulling the claim comments via graphql."},{"type":"toolCall","id":"call_gql5","name":"bash","arguments":{"command":"gh api graphql -f query='query { repository(owner: \"Nishfleet\", name: \"fleet-ops\") { issue(number: 1003) { comments(last: 20) { nodes { author { login } body createdAt } } } } }'"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gql5","toolName":"bash","isError":false,"content":[{"type":"text","text":"{\"data\":{\"repository\":{\"issue\":{\"comments\":{\"nodes\":[{\"author\":{\"login\":\"nish3451\"}}]}}}}}\n"}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "successful gh api graphql with no prior KeyError must stay clean (got $count) $report"
ok "successful gh api graphql with no prior KeyError stays clean (contrast with #1142)"
rm -f "$sessions/graphql-only-clean.jsonl"

# --- 6. prompts/worker.md cites fleet-ops#1142 (prompt-side lock) -----------
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1142' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1142 (prompt-side lock)"
grep -q 'gh issue view 1003' "$worker" \
  || fail "prompts/worker.md must name the live 'gh issue view 1003' wording"
grep -q 'gh api graphql' "$worker" \
  || fail "prompts/worker.md must name the live 'gh api graphql' recovery wording"
ok "worker.md cites fleet-ops#1142 and the live gh --json + graphql wording"

# --- 7. lib/failed-command-flagged.py docstring cites fleet-ops#1142 -------
grep -q 'fleet-ops#1142' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1142 (detector-side lock)"
grep -q 'gh api graphql' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live gh api graphql recovery"
grep -q '01a04326' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live #1142 session slug 01a04326"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1142 and the graphql-recovery shape"

# --- 8. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) -------
grep -Fq 'bash "$here/fleet-failed-command-gh-json-graphql-recovery.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-gh-json-graphql-recovery: live #1142 gh--json KeyError graphql-recovery drills"
