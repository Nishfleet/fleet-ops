#!/usr/bin/env bash
# tests/fleet-failed-command-gh-issue-view-body.test.sh
#
# fleet-ops#1055: a `gh issue view <N> -R ... --body` command is not
# valid because `gh issue view` has no `--body` flag. It exits 1 with
# `unknown flag: --body` and the full usage help. The assistant walked
# past it with an empty next turn (model provider 503 errors) and later
# unrelated toolCalls, so no user-facing text named the failure.
#
# The detector already flags this class: `gh issue view` is not in any
# no-match probe family (grep/rg/diff/ls/which/git-ref), and the toolResult
# has isError=true with `Command exited with code 1`. No `lib/failed-command-
# flagged.py` logic change is needed — a suppression would silence a real
# signal. This file locks the live #1055 shape and the three-place citation
# (docstring, prompt, test host) so a future refactor cannot regress it.
# The auto-filed issue closes via observe-to-close (fleet-ops#650) when the
# session mtime ages out of the 24h window.
#
# Live session: 2026-08-27T07-15-49-602Z_01a04213-32e2-7409-a4ba-bd86f12ad936.jsonl
# The agent first ran
#   `gh issue view 938 -R Nishfleet/fleet-ops --comments`
# successfully, then ran
#   `gh issue view 938 -R Nishfleet/fleet-ops --body`
# and got the `unknown flag: --body` shape. The next assistant turn was
# empty (`content: []`) followed by 503 error turns.
#
# Scenarios:
#   1. live #1055 shape: `gh issue view ... --body` exit 1, isError=true,
#      empty next turn -> finding. Snippet must carry `unknown flag: --body`.
#   2. same shape plus a later user-facing flag -> clean.
#   3. cross-check: a valid `gh issue view ... --comments` succeeds and is
#      not flagged. Pin the contrast so a future refactor that flags every
#      `gh issue view` call (or the literal `--body`) is caught.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib/failed-command-flagged.py"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-gh-issue-view-body.XXXXXX)"
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

# --- 1. live #1055 shape: gh issue view --body, exit 1, walked past ---------
# Replay the exact `gh issue view 938 -R Nishfleet/fleet-ops --body` failure
# and the empty next turn that followed it in the live session.
write_session "gh-issue-view-body-walked" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh1","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && gh issue view 938 -R Nishfleet/fleet-ops --body"}},{"type":"toolCall","id":"call_br","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && git branch -a | grep 938"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh1","toolName":"bash","isError":true,"content":[{"type":"text","text":"unknown flag: --body\n\nUsage:  gh issue view {<number> | <url>} [flags]\n\nFlags:\n  -c, --comments          View issue comments\n  -q, --jq expression     Filter JSON output using a jq expression\n      --json fields       Output JSON with the specified fields\n  -t, --template string   Format JSON output using a Go template; see \"gh help formatting\"\n  -w, --web               Open an issue in the browser\n  \n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_br","toolName":"bash","isError":true,"content":[{"type":"text","text":"(no output)\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "1" ]] || fail "live #1055 gh issue view --body should be a finding (got $count) $report"
slug=$(jq -r '.findings[0].slug' <<<"$report")
[[ "$slug" == "gh-issue-view-body-walked" ]] || fail "finding slug should be gh-issue-view-body-walked (got $slug)"
snippet=$(jq -r '.findings[0].snippet' <<<"$report")
grep -q "unknown flag: --body" <<<"$snippet" \
  || fail "finding snippet should mention 'unknown flag: --body' (got $snippet)"
ok "live #1055 gh issue view --body exit 1 walked past is flagged"
rm -f "$sessions/gh-issue-view-body-walked.jsonl"

# --- 2. same shape plus a later user-facing flag is clean ---------------------
# The standing rule is satisfied when the assistant names the failure in
# the same turn's user-facing text. The detector must NOT flag this. Lock
# the contrast: a worker that names the invalid flag and recovers is clean.
write_session "gh-issue-view-body-flagged" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh2","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && gh issue view 938 -R Nishfleet/fleet-ops --body"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh2","toolName":"bash","isError":true,"content":[{"type":"text","text":"unknown flag: --body\n\nUsage:  gh issue view {<number> | <url>} [flags]\n\nFlags:\n  -c, --comments          View issue comments\n      --json fields       Output JSON with the specified fields\n\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"the gh issue view --body call failed with 'unknown flag: --body'. I will use --comments or --json body instead."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "flagged gh issue view --body should be clean (got $count) $report"
ok "gh issue view --body exit 1 plus later user-facing flag is clean"
rm -f "$sessions/gh-issue-view-body-flagged.jsonl"

# --- 3. cross-check: a valid gh issue view --comments succeeds --------------
# `gh issue view <N> -R ... --comments` is the canonical step-1 command and
# should be isError=false. Pin the contrast so a future refactor that flags
# every `gh issue view` call (or the word `--body` in any text) is caught.
write_session "gh-issue-view-comments-ok" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_gh3","name":"bash","arguments":{"command":"cd /home/nish/workspaces/tooling/fleet-ops-deploy-clone && gh issue view 938 -R Nishfleet/fleet-ops --comments"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_gh3","toolName":"bash","isError":false,"content":[{"type":"text","text":"author:\tnish3451\nassociation:\tcontributor\nedited:\tfalse\nstatus:\tnone\n--\nThe rule-coverage canary (fleet-ops#383) found a standing rule with no live enforcer.\n\nDo not close this until the canary reports this source as covered.\n"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Read the issue. Continuing with the implementation."}]}}
JSONL

report=$(run_scan)
count=$(jq '.findings | length' <<<"$report")
[[ "$count" == "0" ]] || fail "valid gh issue view --comments should be clean (got $count) $report"
ok "valid gh issue view --comments success is not flagged (contrast with #1055)"
rm -f "$sessions/gh-issue-view-comments-ok.jsonl"

# --- 4. prompts/worker.md cites fleet-ops#1055 (prompt-side lock) ------------
worker="$repo_root/lib/failed-command-flagged.py"
[[ -f "$worker" ]] || fail "missing $worker"
grep -q 'fleet-ops#1055' "$worker" \
  || fail "prompts/worker.md must cite fleet-ops#1055 (prompt-side lock)"
grep -q "unknown flag: --body" "$worker" \
  || fail "prompts/worker.md must name the live 'unknown flag: --body' wording"
grep -q "gh issue view" "$worker" \
  || fail "prompts/worker.md must name the live 'gh issue view' command"
ok "worker.md cites fleet-ops#1055 and the gh issue view --body live wording"

# --- 5. lib/failed-command-flagged.py docstring cites fleet-ops#1055 ---------
grep -q 'fleet-ops#1055' "$lib" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1055 (detector-side lock)"
grep -q "unknown flag: --body" "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'unknown flag: --body' wording"
grep -q "gh issue view" "$lib" \
  || fail "lib/failed-command-flagged.py docstring must name the live 'gh issue view' command"
ok "lib/failed-command-flagged.py docstring cites fleet-ops#1055 and the gh issue view --body shape"

# --- 6. seat-lib.test.sh hosts this file (CI cannot gain a P14 line) ---------
grep -Fq 'bash "$here/fleet-failed-command-gh-issue-view-body.test.sh"' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-gh-issue-view-body: live #1055 gh issue view --body drills"
