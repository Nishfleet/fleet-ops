#!/usr/bin/env bash
# tests/fleet-findings-queued.test.sh
#
# fleet-ops#515: session-close lint for "every finding gets queued".
# Offline. Live gh is stubbed. Proves:
#   1. Clean assistant text -> exit 0, FINDINGS-QUEUED-OK.
#   2. Unquoted "want me to file" with no queue action -> exit 1.
#   3. Same offer plus gh issue create in a toolCall -> exit 0.
#   4. Offer only in the user prompt (quoted failure-mode docs) -> exit 0.
#   5. Quoted offer in assistant text (PR naming the failure mode) -> exit 0.
#   6. Auto-file with signal key, deduped on a second run.
#   6b. Observe-to-close: a clean tick closes the filed issue.
#   6c. Observe-to-close leaves a still-active slug open.
#   6d. Incident #724 snippet ("say the word" + deck kicker) is clean (non-filing).
#   7. Missing helper fails loud.
#   8. Contracts: heartbeat wiring, MANIFEST, nested CI host.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-findings-queued"
lib="$repo_root/lib/findings-queued.py"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t findings-queued.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions/ws"
mkdir -p "$sessions"

gh_store="$scratch/gh-issues"
mkdir -p "$gh_store"
cat >"$scratch/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
store="${GH_MOCK_STORE:?}"
cmd="$1"; shift
case "$cmd" in
  issue)
    sub="$1"; shift
    case "$sub" in
      create)
        title=""; body=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --title) title="$2"; shift 2 ;;
            --body) body="$2"; shift 2 ;;
            --repo|-R) shift 2 ;;
            *) shift ;;
          esac
        done
        n=$(find "$store" -maxdepth 1 -name 'issue-*.body' | wc -l)
        f="$store/issue-$((n+1)).body"
        printf '%s\n' "$title" > "$f"
        printf '%s\n' "$body" >> "$f"
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        ;;
      list)
        printf '[\n'
        first=1
        n=0
        for f in "$store"/*.body; do
          [ -f "$f" ] || continue
          n=$((n+1))
          # Skip closed issues (issue-N.closed marker exists)
          [ -f "$store/issue-$n.closed" ] && continue
          body=$(tail -n +2 "$f")
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"title":"","body":%s}' "$n" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")"
        done
        printf '\n]\n'
        ;;
      close)
        num=""; comment=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            [0-9]*) num="$1"; shift ;;
            --comment) comment="$2"; shift 2 ;;
            --repo|-R) shift 2 ;;
            --reason) shift 2 ;;
            *) shift ;;
          esac
        done
        [ -n "$num" ] || exit 1
        : > "$store/issue-$num.closed"
        [ -n "$comment" ] && printf '%s\n' "$comment" > "$store/issue-$num.close-comment"
        echo "Closed issue #$num"
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/gh"

write_session() {
  local name="$1"
  local jsonl="$2"
  printf '%s\n' "$jsonl" >"$sessions/$name.jsonl"
  # In-window, outside grace: stamp mtime to the frozen now.
  touch -d "2026-08-27T00:00:00Z" "$sessions/$name.jsonl"
}

run_bin() {
  local file_issues="${1:-0}"
  set +e
  FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
  FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
  FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
  FLEET_FINDINGS_QUEUED_LIB="$lib" \
  FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
  FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
  FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
  FLEET_FINDINGS_QUEUED_FILE_ISSUES="$file_issues" \
  FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$gh_store" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

# --- 1. clean session -------------------------------------------------------
write_session "clean" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Queued the follow-up as a new issue and opened the PR."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "clean session should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "FINDINGS-QUEUED-OK" "$scratch/err.log" || fail "clean session missing OK line"
ok "clean session exits 0"

# --- 2. unquoted offer, no queue --------------------------------------------
write_session "ask-nofile" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"I noticed the canary is silent. Want me to file it?"}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "unqueued offer should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FINDINGS-UNQUEUED" "$scratch/err.log" || fail "missing FINDINGS-UNQUEUED loud line"
ok "unquoted offer without queue is flagged"
rm -f "$sessions/ask-nofile.jsonl"

# --- 3. offer plus gh issue create ------------------------------------------
write_session "ask-filed" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Out of scope here. Want me to file it?"},{"type":"toolCall","name":"bash","arguments":{"command":"gh issue create -R Nishfleet/fleet-ops --title t --body b"}}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "offer with gh issue create should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "offer plus gh issue create is clean"
rm -f "$sessions/ask-filed.jsonl"

# --- 4. offer only in the user prompt ---------------------------------------
write_session "prompt-only" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Say the word and I will dig in is the failure mode. Want me to file it?"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Queued nothing because there was no finding."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "user-prompt offer should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "offer only in the user prompt is ignored"
rm -f "$sessions/prompt-only.jsonl"

# --- 5. quoted offer in assistant text --------------------------------------
write_session "quoted" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The standing rule names \"want me to file it?\" as the failure mode this lint kills."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "quoted offer should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "quoted offer in assistant text is ignored"
rm -f "$sessions/quoted.jsonl"

# --- 5b. "say the word" with a non-filing action is not a finding (fleet-ops#723)
write_session "say-word-action" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Wiring is a two-line job. Say the word once there is balance and I will land it and prove it with a live call. Money is yours, so I stopped there rather than topping it up."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "say the word with non-filing action should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "FINDINGS-QUEUED-OK" "$scratch/err.log" || fail "say the word with non-filing action missing OK line"
ok "say the word with non-filing action is not flagged"
rm -f "$sessions/say-word-action.jsonl"

# --- 5c. "say the word" with an explicit file/queue action is still a finding
write_session "say-word-file" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"I noticed the canary is silent. Say the word and I will file it."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "say the word with file action should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FINDINGS-UNQUEUED" "$scratch/err.log" || fail "say the word with file action missing FINDINGS-UNQUEUED"
ok "say the word with explicit file action is still flagged"
rm -f "$sessions/say-word-file.jsonl"

# --- 5d. fleet-ops#721 origin session: colloquial hard-line "say the word"
# is not a finding (irreversible delete, token scope, product-direction flip).
write_session "say-word-721" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"I did archive it to a single tarball. Say the word and that goes too; I kept it only so a deletion is not irreversible, not to keep it alive."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Either you delete it in Settings, or say the word and I will refresh the token scope."}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Some runs sat 1,200+ minutes as cancelled-while-queued. Separate work item. Say the word on aiconverter-app and I will flip it."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "721 origin say-the-word should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "721 origin colloquial say-the-word is not flagged"
rm -f "$sessions/say-word-721.jsonl"

# Named failure mode still flags: "Say the word and I'll dig in".
write_session "say-word-digin" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The canary is silent. Say the word and I will dig in."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "say-the-word dig-in should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FINDINGS-UNQUEUED" "$scratch/err.log" || fail "dig-in offer missing FINDINGS-UNQUEUED"
ok "say the word and I will dig in is still flagged"
rm -f "$sessions/say-word-digin.jsonl"

# --- 6. auto-file + dedupe --------------------------------------------------
write_session "ask-nofile" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Should I file a new issue about the silent canary?"}]}}'
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err2.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "auto-file run should exit 1 (got $rc) $(cat "$scratch/err2.log")"
grep -q "FILED" "$scratch/err2.log" || { cat "$scratch/err2.log"; fail "auto-file did not file an issue"; }
grep -rq "signal: findings-queued/" "$scratch/gh-issues" || fail "filed issue body missing signal key"
ok "auto-file creates an issue with the signal key"

set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err3.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "second auto-file run should still exit 1 (got $rc)"
grep -q "deduped" "$scratch/err3.log" || fail "second run did not dedupe $(cat "$scratch/err3.log")"
grep -rl "signal: findings-queued/" "$scratch/gh-issues" | wc -l | grep -q "^1$" \
  || fail "signal key filed more than once (dedupe broken)"
ok "auto-file dedupes the signal key on a second run"
rm -f "$sessions/ask-nofile.jsonl"

# --- 6b. observe-to-close: clean tick closes the filed issue ----------------
# The auto-file run above filed one issue (issue-1.body) with a signal key.
# A clean tick (no findings) must close it via observe-to-close.
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-close.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "clean tick should exit 0 (got $rc) $(cat "$scratch/err-close.log")"
grep -q "observe-to-close: CLOSED" "$scratch/err-close.log" \
  || fail "clean tick did not close the filed issue $(cat "$scratch/err-close.log")"
[ -f "$gh_store/issue-1.closed" ] \
  || fail "issue-1 was not marked closed by observe-to-close"
grep -q "observe-to-close" "$gh_store/issue-1.close-comment" \
  || fail "close comment missing observe-to-close evidence"
ok "observe-to-close closes a filed issue on a clean tick"

# --- 6c. observe-to-close: still-active slug is NOT closed ------------------
write_session "ask-nofile" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Should I file a new issue about the silent canary?"}]}}'
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-noclose.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "active slug should exit 1 (got $rc)"
new_issue=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[ -f "$gh_store/issue-$new_issue.closed" ] \
  && fail "active slug issue #$new_issue was closed (should stay open)" || true
ok "observe-to-close leaves an active slug open"
rm -f "$sessions/ask-nofile.jsonl"

# --- 6d. incident #724 snippet is clean (non-filing "say the word") ---------
# Exact offer from the auto-filed session: putting a line back as a deck
# kicker is implementation, not "file/queue it". After fleet-ops#815 this
# must stay FINDINGS-QUEUED-OK so observe-to-close can close #724.
write_session "deck-kicker" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The deck still says saves the screenshots, and files the brief — but say the word and I will put the line back as a deck kicker."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "incident #724 snippet should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "FINDINGS-QUEUED-OK" "$scratch/err.log" || fail "incident #724 snippet missing OK line"
ok "incident #724 deck-kicker snippet is clean (non-filing)"
rm -f "$sessions/deck-kicker.jsonl"

# --- 7. missing helper fails loud -------------------------------------------
# Harden the drill (fleet-ops#612): install a WORKING fake helper at the
# fallback dest under a scratch HOME so the drill proves the guard (env-var
# pin wins over the installed copy) regardless of whether the real machine
# already has ~/.local/lib/pi-packet/findings-queued.py. Without the guard
# the bin would fall back to the fake helper, scan clean, and exit 0 — the
# drill would fail. With the guard the pin wins, LIB stays missing, exit 1.
fake_home="$scratch/home"
mkdir -p "$fake_home/.local/lib/pi-packet"
cat >"$fake_home/.local/lib/pi-packet/findings-queued.py" <<'FAKE_HELPER'
#!/usr/bin/env python3
import argparse, json, sys
p = argparse.ArgumentParser()
sub = p.add_subparsers(dest="cmd", required=True)
s = sub.add_parser("scan")
s.add_argument("--root", required=True)
s.add_argument("--now", default="")
s.add_argument("--window-hours", type=float, default=24.0)
s.add_argument("--grace-minutes", type=float, default=20.0)
a = p.parse_args()
json.dump({"findings": [], "scanned": 0, "skipped_old": 0,
           "skipped_grace": 0, "skipped_unreadable": 0, "root": a.root},
          sys.stdout)
sys.stdout.write("\n")
FAKE_HELPER
chmod +x "$fake_home/.local/lib/pi-packet/findings-queued.py"
set +e
HOME="$fake_home" \
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$scratch/no-such.py" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES=0 \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err4.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "missing helper should exit 1 (got $rc) — guard did not win over installed fallback"
grep -q "FINDINGS-QUEUED-BROKEN" "$scratch/err4.log" || fail "missing helper must be LOUD"
ok "missing helper fails loud (guard wins over installed fallback)"

# --- 7b. observe-to-close: backticked <slug> example is NOT closed (fleet-ops#820) ---
# A body that contains the literal text `signal: findings-queued/<slug>`
# as a code-fence example (not an actual signal) must not be closed. The
# regex must skip backticked placeholders so a meta-issue about the rule
# is not closed as if it were a real auto-filed finding. Without the
# backtick guard, the previous regex captured the backtick of the literal
# `\`<slug>\`` and treated the example as a real signal, phantom-closing
# the meta-issue. Start clean so prior tests' auto-filed issues do not
# leak into this drill (issue-2 from case 6c carries a real signal and
# would otherwise be closed here for the wrong reason).
rm -f "$gh_store"/*.body "$gh_store"/*.closed "$gh_store"/*.close-comment
printf 'Title of a meta-issue\n\nSee `signal: findings-queued/<slug>` for the rule format.\n' >"$gh_store/issue-1.body"
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-backtick.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "clean tick with backtick example should exit 0 (got $rc) $(cat "$scratch/err-backtick.log")"
# The meta-issue must NOT have been closed (backticked <slug> is prose).
[ -f "$gh_store/issue-1.closed" ] \
  && fail "meta-issue was closed on a backtick slug match (should be left open) $(cat "$scratch/err-backtick.log")" || true
grep -q "observe-to-close" "$scratch/err-backtick.log" \
  && fail "observe-to-close fired on a backtick example — should be skipped $(cat "$scratch/err-backtick.log")" || true
ok "observe-to-close skips backticked <slug> placeholder (fleet-ops#820 regression)"
rm -f "$gh_store"/*.body "$gh_store"/*.closed "$gh_store"/*.close-comment

# --- 8. Cursor transcript shape (fleet-ops#602) -----------------------------
# Cursor transcripts: top-level role, no `type`, tool_use chunks with `input`.
cursor_root="$scratch/cursor/projects/proj-x/agent-transcripts/sess-cursor"
mkdir -p "$cursor_root"
printf '%s\n' '{"role":"assistant","message":{"content":[{"type":"text","text":"The canary is silent again. Want me to file it?"}]}}' >"$cursor_root/sess-cursor.jsonl"
touch -d "2026-08-27T00:00:00Z" "$cursor_root/sess-cursor.jsonl"
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="$scratch/cursor/projects" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES="0" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-cur.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "Cursor unqueued offer should exit 1 (got $rc) $(cat "$scratch/err-cur.log")"
grep -q "FINDINGS-UNQUEUED" "$scratch/err-cur.log" || fail "Cursor offer missing FINDINGS-UNQUEUED"
ok "Cursor transcript: unqueued offer is flagged"
rm -rf "$scratch/cursor"

# Cursor offer plus a tool_use that runs gh issue create -> clean.
cursor_root="$scratch/cursor/projects/proj-y/agent-transcripts/sess-cursor-ok"
mkdir -p "$cursor_root"
printf '%s\n' '{"role":"assistant","message":{"content":[{"type":"text","text":"Out of scope. Want me to file it?"},{"type":"tool_use","name":"bash","input":{"command":"gh issue create -R Nishfleet/fleet-ops --title t --body b"}}]}}' >"$cursor_root/sess-cursor-ok.jsonl"
touch -d "2026-08-27T00:00:00Z" "$cursor_root/sess-cursor-ok.jsonl"
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="$scratch/cursor/projects" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES="0" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-cur2.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "Cursor offer with gh issue create should exit 0 (got $rc) $(cat "$scratch/err-cur2.log")"
ok "Cursor transcript: offer plus tool_use gh issue create is clean"
rm -rf "$scratch/cursor"

# --- 9. Claude session shape (fleet-ops#602) --------------------------------
# Claude: top-level type user/assistant, tool_use/tool_result chunks; an
# issue URL in a tool_result counts as queue evidence.
claude_proj="$scratch/claude/projects/proj-claude"
mkdir -p "$claude_proj"
printf '%s\n' \
'{"type":"user","message":{"role":"user","content":[{"type":"text","text":"check the build"}]}}' \
'{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Build is red. Want me to file it?"},{"type":"tool_use","name":"bash","input":{"command":"gh issue create -R Nishfleet/fleet-ops --title t --body b"}}]}}' \
'{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"https://github.com/Nishfleet/fleet-ops/issues/4321"}]}}' \
  >"$claude_proj/sess-claude.jsonl"
touch -d "2026-08-27T00:00:00Z" "$claude_proj/sess-claude.jsonl"
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="$scratch/claude/projects" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES="0" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-cla.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "Claude offer with tool_result issue URL should exit 0 (got $rc) $(cat "$scratch/err-cla.log")"
ok "Claude session: offer plus tool_result issue URL is clean"
rm -rf "$scratch/claude"

# Claude offer with no queue action -> flagged.
claude_proj="$scratch/claude/projects/proj-claude2"
mkdir -p "$claude_proj"
printf '%s\n' \
'{"type":"user","message":{"role":"user","content":[{"type":"text","text":"check the build"}]}}' \
'{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","text":"reasoning"},{"type":"text","text":"Build is red. Should I file a new issue?"}]}}' \
  >"$claude_proj/sess-claude2.jsonl"
touch -d "2026-08-27T00:00:00Z" "$claude_proj/sess-claude2.jsonl"
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="$scratch/claude/projects" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES="0" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-cla2.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "Claude unqueued offer should exit 1 (got $rc) $(cat "$scratch/err-cla2.log")"
grep -q "FINDINGS-UNQUEUED" "$scratch/err-cla2.log" || fail "Claude offer missing FINDINGS-UNQUEUED"
ok "Claude session: unqueued offer is flagged (thinking chunk ignored)"
rm -rf "$scratch/claude"

# --- 10. multi-root merge (fleet-ops#602) -----------------------------------
# A finding in Pi sessions AND a finding in Cursor transcripts both surface
# in one run (one detector, three roots).
sessions="$scratch/sessions/ws"
mkdir -p "$sessions"
printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Pi side. Want me to file it?"}]}}' >"$sessions/pi-multi.jsonl"
touch -d "2026-08-27T00:00:00Z" "$sessions/pi-multi.jsonl"
cursor_root="$scratch/cursor/projects/p/agent-transcripts/s"
mkdir -p "$cursor_root"
printf '%s\n' '{"role":"assistant","message":{"content":[{"type":"text","text":"Cursor side. Say the word and I will file it."}]}}' >"$cursor_root/s.jsonl"
touch -d "2026-08-27T00:00:00Z" "$cursor_root/s.jsonl"
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="$scratch/cursor/projects" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES="0" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-multi.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "multi-root merge should exit 1 (got $rc) $(cat "$scratch/err-multi.log")"
count=$(grep -c "FINDINGS-UNQUEUED" "$scratch/err-multi.log")
[[ "$count" -ge 2 ]] || fail "multi-root merge should report >=2 findings (got $count)"
ok "multi-root merge: Pi + Cursor findings both surface in one run"
rm -rf "$scratch/cursor" "$sessions/pi-multi.jsonl"

# --- 11. contracts ----------------------------------------------------------
grep -q 'fleet-findings-queued' "$tier1" \
  || fail "fleet-heartbeat-tier1 must invoke fleet-findings-queued"
grep -q 'findings_queued_rc' "$tier1" \
  || fail "fleet-heartbeat-tier1 must propagate findings_queued_rc"
grep -q 'bin/fleet-findings-queued' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-findings-queued"
grep -q 'lib/findings-queued.py' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install lib/findings-queued.py"
grep -Fq 'bash "$here/fleet-findings-queued.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
grep -q 'observe-to-close' "$bin" \
  || fail "fleet-findings-queued must observe-to-close auto-filed findings (fleet-ops#724)"
ok "contracts: heartbeat-tier1, MANIFEST, nested CI host, observe-to-close"

echo "OK: fleet-findings-queued: offer lint, queue evidence, auto-file dedupe, observe-to-close"
