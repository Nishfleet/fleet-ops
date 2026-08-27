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
      comment)
        num=""; body=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --body) body="$2"; shift 2 ;;
            --repo|-R) shift 2 ;;
            [0-9]*) num="$1"; shift ;;
            *) shift ;;
          esac
        done
        cf="$store/issue-${num}.comments"
        printf '%s\n' "$body" >> "$cf"
        echo "https://github.com/Nishfleet/fleet-ops/issues/${num}#comment"
        ;;
      close)
        num=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --reason) shift 2 ;;
            --repo|-R) shift 2 ;;
            [0-9]*) num="$1"; shift ;;
            *) shift ;;
          esac
        done
        : >"$store/issue-${num}.closed"
        ;;
      list)
        printf '[\n'
        first=1
        n=0
        for f in "$store"/*.body; do
          [ -f "$f" ] || continue
          n=$((n+1))
          # Skip closed issues for --state open (the detector lists open).
          [ -f "$store/issue-${n}.closed" ] && continue
          body=$(tail -n +2 "$f")
          cf="$store/issue-${n}.comments"
          comments="[]"
          if [ -f "$cf" ]; then
            comments=$(python3 -c '
import json, sys
cfile = sys.argv[1]
out = []
with open(cfile) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if line:
            out.append({"body": line})
print(json.dumps(out))
' "$cf")
          fi
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"title":"","body":%s,"comments":%s}' \
            "$n" \
            "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")" \
            "$comments"
        done
        printf '\n]\n'
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

# --- 6b. observe-to-close: file -> age out -> observe -> close ---------------
# The class of failure (fleet-ops#722): the detector auto-filed issues but
# had no observe-to-close, so an auto-filed issue could never close once the
# session aged out of the window. This proves the two-step wiring:
#   tick 1: flagged session -> auto-file issue (signal: findings-queued/<slug>)
#   tick 2: session gone (aged out) -> clean scan -> post resolved-at: marker
#   tick 3: still clean + marker persisted -> close as completed
# Same-tick comment-then-close is avoided so the green report is durable.
oc_sessions="$scratch/sessions/ws"
mkdir -p "$oc_sessions"
printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The canary is silent. Want me to file it?"}]}}' >"$oc_sessions/oc-offer.jsonl"
touch -d "2026-08-27T00:00:00Z" "$oc_sessions/oc-offer.jsonl"
oc_store="$scratch/gh-issues-oc"
mkdir -p "$oc_store"
# tick 1: auto-file.
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_OBSERVE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_CLOSE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$oc_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/oc1.log"
oc1_rc=$?
set -e
[[ "$oc1_rc" == "1" ]] || fail "observe-close tick1 should exit 1 (got $oc1_rc) $(cat "$scratch/oc1.log")"
grep -q "FILED" "$scratch/oc1.log" || fail "observe-close tick1 did not file"
grep -rq "signal: findings-queued/" "$oc_store" || fail "observe-close tick1 missing signal"
# tick 1 must NOT close or observe (slug still active).
grep -q "OBSERVED-CLEAN\|OBSERVE-CLOSED" "$scratch/oc1.log" \
  && fail "observe-close tick1 must not observe/close an active slug" || true
ok "observe-close tick1: auto-files, no observe/close on active slug"

# tick 2: session aged out of the window -> clean scan -> observe (post marker).
rm -f "$oc_sessions/oc-offer.jsonl"
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_OBSERVE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_CLOSE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$oc_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/oc2.log"
oc2_rc=$?
set -e
[[ "$oc2_rc" == "0" ]] || fail "observe-close tick2 (clean) should exit 0 (got $oc2_rc) $(cat "$scratch/oc2.log")"
grep -q "OBSERVED-CLEAN" "$scratch/oc2.log" || fail "observe-close tick2 did not post marker $(cat "$scratch/oc2.log")"
grep -rq "resolved-at: findings-queued/" "$oc_store" || fail "observe-close tick2 missing resolved-at comment"
# tick 2 must NOT close yet (no prior marker before this tick).
grep -q "OBSERVE-CLOSED" "$scratch/oc2.log" \
  && fail "observe-close tick2 must not close same-tick as the marker" || true
ok "observe-close tick2: clean scan posts resolved-at marker, no same-tick close"

# tick 3: still clean + marker persisted from tick 2 -> close as completed.
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_OBSERVE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_CLOSE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$oc_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/oc3.log"
oc3_rc=$?
set -e
[[ "$oc3_rc" == "0" ]] || fail "observe-close tick3 (clean) should exit 0 (got $oc3_rc) $(cat "$scratch/oc3.log")"
grep -q "OBSERVE-CLOSED" "$scratch/oc3.log" || fail "observe-close tick3 did not close $(cat "$scratch/oc3.log")"
[[ -f "$oc_store/issue-1.closed" ]] || fail "observe-close tick3 did not mark issue closed"
ok "observe-close tick3: marker persisted + still clean -> closed as completed"

# tick 4: issue is now closed -> list returns empty -> no further action.
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" \
FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" \
FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_OBSERVE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_CLOSE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$oc_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/oc4.log"
oc4_rc=$?
set -e
[[ "$oc4_rc" == "0" ]] || fail "observe-close tick4 should exit 0 (got $oc4_rc) $(cat "$scratch/oc4.log")"
grep -q "OBSERVED-CLEAN\|OBSERVE-CLOSED" "$scratch/oc4.log" \
  && fail "observe-close tick4 must not re-observe/close a closed issue" || true
ok "observe-close tick4: closed issue is not re-observed or re-closed"

# Observe/close gates: OBSERVE_ISSUES=0 suppresses the marker; CLOSE_ISSUES=0
# suppresses the close even when the marker is present.
gate_store="$scratch/gh-issues-gate"
mkdir -p "$gate_store"
printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Silent again. Want me to file it?"}]}}' >"$oc_sessions/gate-offer.jsonl"
touch -d "2026-08-27T00:00:00Z" "$oc_sessions/gate-offer.jsonl"
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" FLEET_FINDINGS_QUEUED_FILE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_OBSERVE_ISSUES=1 FLEET_FINDINGS_QUEUED_CLOSE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" GH="$scratch/gh" \
GH_MOCK_STORE="$gate_store" FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/gate1.log"
set -e
grep -q "FILED" "$scratch/gate1.log" || fail "gate setup did not file"
rm -f "$oc_sessions/gate-offer.jsonl"
# OBSERVE=0 -> no marker posted on a clean tick.
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" FLEET_FINDINGS_QUEUED_FILE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_OBSERVE_ISSUES=0 FLEET_FINDINGS_QUEUED_CLOSE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" GH="$scratch/gh" \
GH_MOCK_STORE="$gate_store" FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/gate2.log"
set -e
grep -q "OBSERVED-CLEAN" "$scratch/gate2.log" \
  && fail "OBSERVE_ISSUES=0 must suppress the marker" || true
grep -rq "resolved-at: findings-queued/" "$gate_store" \
  && fail "OBSERVE_ISSUES=0 must not post a resolved-at comment" || true
ok "observe-close gate: OBSERVE_ISSUES=0 suppresses the marker"
# Manually plant the marker, then CLOSE=0 -> no close.
printf 'resolved-at: findings-queued/gate-offer\n' >>"$gate_store/issue-1.comments"
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" FLEET_FINDINGS_QUEUED_CURSOR_ROOTS="" \
FLEET_FINDINGS_QUEUED_CLAUDE_ROOTS="" FLEET_FINDINGS_QUEUED_LIB="$lib" \
FLEET_FINDINGS_QUEUED_WINDOW_HOURS="24" FLEET_FINDINGS_QUEUED_GRACE_MINUTES="0" \
FLEET_FINDINGS_QUEUED_NOW="2026-08-27T00:10:00Z" FLEET_FINDINGS_QUEUED_FILE_ISSUES=1 \
FLEET_FINDINGS_QUEUED_OBSERVE_ISSUES=1 FLEET_FINDINGS_QUEUED_CLOSE_ISSUES=0 \
FLEET_FINDINGS_QUEUED_ISSUE_REPO="Nishfleet/fleet-ops" GH="$scratch/gh" \
GH_MOCK_STORE="$gate_store" FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/gate3.log"
set -e
grep -q "OBSERVE-CLOSED" "$scratch/gate3.log" \
  && fail "CLOSE_ISSUES=0 must suppress the close" || true
[[ -f "$gate_store/issue-1.closed" ]] \
  && fail "CLOSE_ISSUES=0 must not close the issue" || true
ok "observe-close gate: CLOSE_ISSUES=0 suppresses the close"
rm -f "$oc_sessions/gate-offer.jsonl"

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
ok "contracts: heartbeat-tier1, MANIFEST, nested CI host"

echo "OK: fleet-findings-queued: offer lint, queue evidence, auto-file dedupe"
