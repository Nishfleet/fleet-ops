#!/usr/bin/env bash
# tests/fleet-decisions-ledger.test.sh
#
# fleet-ops#514: session-close lint for "check the decisions ledger
# before asking Nish". Offline. Live gh is stubbed. Proves:
#   1. Clean assistant text -> exit 0, DECISIONS-LEDGER-OK.
#   2. Unquoted overlapping ask with no ledger-checked -> exit 1.
#   3. Same ask plus ledger-checked -> exit 0.
#   4. AskUserQuestion tool call overlapping a ledger line -> exit 1.
#   5. Ask only in the user prompt -> exit 0.
#   6. Quoted ask in assistant text -> exit 0.
#   7. Ask with no ledger overlap -> exit 0.
#   8. Auto-file with signal key, deduped on a second run.
#   9. Missing helper / missing ledger fails loud.
#  10. Contracts: heartbeat wiring, MANIFEST, nested CI host.
#  11. Live #1138: systemd "should we read from the service" self-talk
#      overlapping generic `from`/`process`/`source` (the last from the
#      ledger context-pointer) is NOT a vacation-window re-ask.
#  12. Positive control for #1138: a real same-sentence vacation-window
#      question still flags.
#  13. Observe-to-close (fleet-ops#650 shape, #1138 drain): green tick
#      comments resolved-at; later tick closes; still-dirty slug is
#      neither commented nor closed.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-decisions-ledger"
lib="$repo_root/lib/decisions-ledger.py"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t decisions-ledger.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions/ws"
mkdir -p "$sessions"

cat >"$scratch/ledger.md" <<'EOF'
# Fixture ledger
- 2026-08-27 | Vacation window corrected | Nish departs 2026-08-28, returns 2026-09-08 (11 days). All vacation grants (D1 migrations via senior process, fleet-ops precedence) run through 2026-09-08. Anything needing Nish's input must be surfaced TODAY (08-27); from tomorrow only boundary-class texts reach him. Credential/token/quota expiry checks must cover through 2026-09-08 inclusive. | source: interactive Claude session 2026-08-27
- 2026-08-25 | 0509 deploys | auto deploy on green | test
- 2026-08-26 | bikeshed colour | never ask about zebras painted purple | test
- 2026-08-26 | worker-lane refresh | use whichever flash model is cheapest; caps land via seat-caps.json; file a wiring issue for the change | test
EOF

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
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift
              ;;
          esac
        done
        printf '%s\n' "$body" >"$store/issue-${num}.comments"
        printf '%s\n' "$num" >>"$store/commented"
        echo "https://github.com/Nishfleet/fleet-ops/issues/${num}#issuecomment-1"
        ;;
      close)
        num=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --reason|--repo|-R) shift 2 ;;
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift
              ;;
          esac
        done
        : >"$store/issue-${num}.closed"
        printf '%s\n' "$num" >>"$store/closed"
        echo "https://github.com/Nishfleet/fleet-ops/issues/${num}"
        ;;
      list)
        state_filter="open"
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --state) state_filter="$2"; shift 2 ;;
            --limit|--json|--repo|-R) shift 2 ;;
            *) shift ;;
          esac
        done
        printf '[\n'
        first=1
        for f in "$store"/issue-*.body; do
          [ -f "$f" ] || continue
          num=$(basename "$f" .body)
          num=${num#issue-}
          is_closed=""
          [ -f "$store/issue-${num}.closed" ] && is_closed="1"
          if [ "$state_filter" = "open" ] && [ -n "$is_closed" ]; then
            continue
          fi
          if [ "$state_filter" = "closed" ] && [ -z "$is_closed" ]; then
            continue
          fi
          body=$(tail -n +2 "$f")
          comments_file="$store/issue-${num}.comments"
          if [ -f "$comments_file" ]; then
            comments_json=$(python3 -c 'import json,sys;print(json.dumps([{"body": sys.stdin.read()}]))' <"$comments_file")
          else
            comments_json='[]'
          fi
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"title":"","body":%s,"comments":%s}' "$num" \
            "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")" \
            "$comments_json"
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
  touch -d "2026-08-27T00:00:00Z" "$sessions/$name.jsonl"
}

run_bin() {
  local file_issues="${1:-0}"
  set +e
  FLEET_DECISIONS_LEDGER_SESSIONS="$scratch/sessions" \
  FLEET_DECISIONS_LEDGER="$scratch/ledger.md" \
  FLEET_DECISIONS_LEDGER_LIB="$lib" \
  FLEET_DECISIONS_LEDGER_WINDOW_HOURS="24" \
  FLEET_DECISIONS_LEDGER_GRACE_MINUTES="0" \
  FLEET_DECISIONS_LEDGER_NOW="2026-08-27T00:10:00Z" \
  FLEET_DECISIONS_LEDGER_FILE_ISSUES="$file_issues" \
  FLEET_DECISIONS_LEDGER_ISSUE_REPO="Nishfleet/fleet-ops" \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$gh_store" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

# --- 1. clean session -------------------------------------------------------
write_session "clean" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Acting on auto deploy on green. Wiring the check now."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "clean session should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "DECISIONS-LEDGER-OK" "$scratch/err.log" || fail "clean session missing OK line"
ok "clean session exits 0"

# --- 2. unquoted overlapping ask --------------------------------------------
write_session "reask" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Nish, should we auto deploy on green for 0509?"}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "overlapping re-ask should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "DECISIONS-LEDGER-REASK" "$scratch/err.log" || fail "missing DECISIONS-LEDGER-REASK loud line"
ok "unquoted overlapping ask is flagged"
rm -f "$sessions/reask.jsonl"

# --- 3. overlapping ask plus ledger-checked ---------------------------------
write_session "checked" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Nish, should we auto deploy on green for 0509? ledger-checked: this is a genuinely new angle."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "ledger-checked ask should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "ledger-checked overlapping ask is clean"
rm -f "$sessions/checked.jsonl"

# --- 4. AskUserQuestion tool call -------------------------------------------
write_session "ask-tool" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"AskUserQuestion","arguments":{"questions":[{"question":"Should 0509 auto deploy on green?"}]}}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "AskUserQuestion overlap should exit 1 (got $rc) $(cat "$scratch/err.log")"
ok "AskUserQuestion tool call overlapping a ledger line is flagged"
rm -f "$sessions/ask-tool.jsonl"

# --- 5. ask only in the user prompt -----------------------------------------
write_session "prompt-only" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Nish, should we auto deploy on green?"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Acting on the standing decision."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "user-prompt ask should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "ask only in the user prompt is ignored"
rm -f "$sessions/prompt-only.jsonl"

# --- 6. quoted ask in assistant text ----------------------------------------
write_session "quoted" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The standing rule names \"Nish, should we auto deploy on green?\" as the failure mode this lint kills."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "quoted ask should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "quoted ask in assistant text is ignored"
rm -f "$sessions/quoted.jsonl"

# --- 7. ask with no ledger overlap ------------------------------------------
write_session "no-overlap" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Nish, should we rename the bikeshed teal?"}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "non-overlapping ask should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "ask with no ledger overlap is ignored"
rm -f "$sessions/no-overlap.jsonl"

# --- 7b. implementation "confirm that" is not an ask ------------------------
write_session "confirm-prose" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Let me confirm that this failure is a skip, not a real auto deploy on green regression."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "confirm-that prose should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "implementation confirm-that prose is ignored"
rm -f "$sessions/confirm-prose.jsonl"

# --- 7c. directive "ask Nish to land this" + later-sentence "?" --------
# fleet-ops#846: "ask Nish to land this." is a directive (file an issue for
# Nish to push a workflow change), NOT a question. A "?" in a LATER
# sentence ("What about using a fork to use a PR?") was falling inside the
# 320-char window, so the old window-based "?" check mis-flagged it as a
# re-ask of the worker-lane-refresh line on 4 generic words (change, issue,
# land, use). The same-sentence "?" check must reject it.
write_session "directive-later-q" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Open a new issue explaining the worker scope cant push workflow change, and ask Nish to land this.\n\nWhat about using a fork to use a PR? The worker could push the change to a fork."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "directive + later-sentence ? should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "directive ask-Nish-to-land-this with a later-sentence ? is ignored"
rm -f "$sessions/directive-later-q.jsonl"

# --- 7d. same-sentence question overlapping the same line IS flagged ----
# Positive control for 7c: a real same-sentence question that overlaps the
# worker-lane-refresh line on its distinctive tokens must still be flagged.
write_session "real-reask-same-line" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Nish, should we use the cheapest flash model for the worker-lane refresh?"}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "same-sentence re-ask of worker-lane-refresh should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "DECISIONS-LEDGER-REASK" "$scratch/err.log" || fail "missing REASK for same-sentence question"
ok "same-sentence question overlapping the same ledger line is flagged"
rm -f "$sessions/real-reask-same-line.jsonl"

# --- 8. auto-file + dedupe --------------------------------------------------
write_session "reask" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Nish, should we auto deploy on green for 0509?"}]}}'
set +e
FLEET_DECISIONS_LEDGER_SESSIONS="$scratch/sessions" \
FLEET_DECISIONS_LEDGER="$scratch/ledger.md" \
FLEET_DECISIONS_LEDGER_LIB="$lib" \
FLEET_DECISIONS_LEDGER_WINDOW_HOURS="24" \
FLEET_DECISIONS_LEDGER_GRACE_MINUTES="0" \
FLEET_DECISIONS_LEDGER_NOW="2026-08-27T00:10:00Z" \
FLEET_DECISIONS_LEDGER_FILE_ISSUES=1 \
FLEET_DECISIONS_LEDGER_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err2.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "auto-file run should exit 1 (got $rc) $(cat "$scratch/err2.log")"
grep -q "FILED" "$scratch/err2.log" || { cat "$scratch/err2.log"; fail "auto-file did not file an issue"; }
grep -rq "signal: decisions-ledger/" "$scratch/gh-issues" || fail "filed issue body missing signal key"
ok "auto-file creates an issue with the signal key"

set +e
FLEET_DECISIONS_LEDGER_SESSIONS="$scratch/sessions" \
FLEET_DECISIONS_LEDGER="$scratch/ledger.md" \
FLEET_DECISIONS_LEDGER_LIB="$lib" \
FLEET_DECISIONS_LEDGER_WINDOW_HOURS="24" \
FLEET_DECISIONS_LEDGER_GRACE_MINUTES="0" \
FLEET_DECISIONS_LEDGER_NOW="2026-08-27T00:10:00Z" \
FLEET_DECISIONS_LEDGER_FILE_ISSUES=1 \
FLEET_DECISIONS_LEDGER_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err3.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "second auto-file run should still exit 1 (got $rc)"
grep -q "deduped" "$scratch/err3.log" || fail "second run did not dedupe $(cat "$scratch/err3.log")"
grep -rl "signal: decisions-ledger/" "$scratch/gh-issues" | wc -l | grep -q "^1$" \
  || fail "signal key filed more than once (dedupe broken)"
ok "auto-file dedupes the signal key on a second run"
rm -f "$sessions/reask.jsonl"

# --- 9. missing helper / missing ledger fails loud --------------------------
# Harden the drill (fleet-ops#707): install a WORKING fake helper at the
# fallback dest under a scratch HOME so the drill proves the guard (env-var
# pin wins over the installed copy) regardless of whether the real machine
# already has ~/.local/lib/pi-packet/decisions-ledger.py. Without the guard
# the bin would fall back to the fake helper, scan clean, and exit 0 — the
# drill would fail. With the guard the pin wins, LIB stays missing, exit 1.
fake_home="$scratch/home"
mkdir -p "$fake_home/.local/lib/pi-packet"
cat >"$fake_home/.local/lib/pi-packet/decisions-ledger.py" <<'FAKE_HELPER'
#!/usr/bin/env python3
import argparse, json, sys
p = argparse.ArgumentParser()
sub = p.add_subparsers(dest="cmd", required=True)
s = sub.add_parser("scan")
s.add_argument("--root", required=True)
s.add_argument("--ledger", required=True)
s.add_argument("--now", default="")
s.add_argument("--window-hours", type=float, default=24.0)
s.add_argument("--grace-minutes", type=float, default=20.0)
a = p.parse_args()
json.dump({"findings": [], "scanned": 0, "skipped_old": 0,
           "skipped_grace": 0, "skipped_unreadable": 0,
           "ledger_lines": 0, "root": a.root}, sys.stdout)
sys.stdout.write("\n")
FAKE_HELPER
chmod +x "$fake_home/.local/lib/pi-packet/decisions-ledger.py"
set +e
HOME="$fake_home" \
FLEET_DECISIONS_LEDGER_SESSIONS="$scratch/sessions" \
FLEET_DECISIONS_LEDGER="$scratch/ledger.md" \
FLEET_DECISIONS_LEDGER_LIB="$scratch/no-such.py" \
FLEET_DECISIONS_LEDGER_FILE_ISSUES=0 \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err4.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "missing helper should exit 1 (got $rc) — guard did not win over installed fallback"
grep -q "DECISIONS-LEDGER-BROKEN" "$scratch/err4.log" || fail "missing helper must be LOUD"
ok "missing helper fails loud (guard wins over installed fallback)"

# Citation lock for #631 (missing-helper guard). The guard above (env-var pin
# wins over installed fallback) is the fix for fleet-ops#631, the sibling of
# the findings-queued guard. Pin the issue number next to the guard in the bin
# so a future refactor that removes the guard also has to remove the citation.
grep -q 'fleet-ops#631' "$bin" \
  || fail "bin/fleet-decisions-ledger must cite fleet-ops#631 next to the missing-helper guard"
ok "citation lock: #631 pinned to the missing-helper guard in bin/fleet-decisions-ledger"

set +e
FLEET_DECISIONS_LEDGER_SESSIONS="$scratch/sessions" \
FLEET_DECISIONS_LEDGER="$scratch/no-such-ledger.md" \
FLEET_DECISIONS_LEDGER_LIB="$lib" \
FLEET_DECISIONS_LEDGER_FILE_ISSUES=0 \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err5.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "missing ledger should exit 1 (got $rc)"
grep -q "DECISIONS-LEDGER-BROKEN" "$scratch/err5.log" || fail "missing ledger must be LOUD"
ok "missing ledger fails loud"

# --- 10. contracts ----------------------------------------------------------
grep -q 'fleet-decisions-ledger' "$tier1" \
  || fail "fleet-heartbeat-tier1 must invoke fleet-decisions-ledger"
grep -q 'decisions_ledger_rc' "$tier1" \
  || fail "fleet-heartbeat-tier1 must propagate decisions_ledger_rc"
grep -q 'bin/fleet-decisions-ledger' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-decisions-ledger"
grep -q 'lib/decisions-ledger.py' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install lib/decisions-ledger.py"
grep -Fq 'bash "$here/fleet-decisions-ledger.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
jq -e '.rules[] | select(.id == "sr-decisions-ledger" and .status == "enforced")' \
  "$repo_root/config/rule-enforcement.json" >/dev/null \
  || fail "sr-decisions-ledger must be status=enforced in the matrix"
ok "contracts: heartbeat-tier1, MANIFEST, nested CI host, matrix enforced"

# --- 11. live #1138: systemd self-talk is not a vacation-window re-ask ------
# Live session 01a04318: "what should we read from the service?" is
# implementation self-talk. ASK_RE matches `should we`. Overlap with the
# vacation line was exactly {from, process, source} — `from` is a
# preposition that STOP omitted, `source` came from the ledger
# context-pointer (`| source: interactive Claude session ...`), `process`
# is "senior process" / "main process started". That is not a re-ask of
# the vacation window. The class is: generic `should we` prose overlapping
# stop-word-adjacent tokens plus provenance metadata.
write_session "oneshot-service" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"I can rename without breaking public API.\n\nLet me now look at the source — what should we read from the service?\nHmm,   is empty for oneshot services.   is set to when the service last started.   is when the main process started.   is when the state last changed (i.e. when it last went from active to inactive — which is when it"}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "live #1138 systemd self-talk should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "live #1138: systemd should-we-read-from-the-service self-talk is ignored"
rm -f "$sessions/oneshot-service.jsonl"

# --- 12. positive control: a real vacation-window re-ask still flags --------
write_session "vacation-reask" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Nish, should we keep the vacation window grants running only through 2026-09-08?"}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "real vacation-window re-ask should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "DECISIONS-LEDGER-REASK" "$scratch/err.log" || fail "missing REASK for real vacation-window question"
ok "live #1138 positive: same-sentence vacation-window re-ask is flagged"
rm -f "$sessions/vacation-reask.jsonl"

# --- 13. observe-to-close (fleet-ops#650 shape; #1138 drain) ----------------
# Isolate the mock store from the auto-file test's leftover issue.
rm -f "$gh_store"/issue-* "$gh_store"/commented "$gh_store"/closed
: >"$gh_store/commented"
: >"$gh_store/closed"
printf '%s\n' "fix(decisions-ledger): vacation-window-corrected" >"$gh_store/issue-1138.body"
printf '%s\n' "Do not close until the detector reports this clean.

signal: decisions-ledger/vacation-window-corrected" >>"$gh_store/issue-1138.body"

# Green tick (the live #1138 self-talk session, now clean) comments
# resolved-at; does not close yet.
write_session "oneshot-observe" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"I can rename without breaking public API.\n\nLet me now look at the source — what should we read from the service?\nHmm,   is empty for oneshot services.   is set to when the service last started.   is when the main process started."}]}}'
set +e
FLEET_DECISIONS_LEDGER_SESSIONS="$scratch/sessions" \
FLEET_DECISIONS_LEDGER="$scratch/ledger.md" \
FLEET_DECISIONS_LEDGER_LIB="$lib" \
FLEET_DECISIONS_LEDGER_WINDOW_HOURS="24" \
FLEET_DECISIONS_LEDGER_GRACE_MINUTES="0" \
FLEET_DECISIONS_LEDGER_NOW="2026-08-27T00:10:00Z" \
FLEET_DECISIONS_LEDGER_FILE_ISSUES=1 \
FLEET_DECISIONS_LEDGER_CLOSE_ISSUES=1 \
FLEET_DECISIONS_LEDGER_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-obs.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "observe-to-close green tick should exit 0 (got $rc) $(cat "$scratch/err-obs.log")"
grep -q "OBSERVED-RESOLVED" "$scratch/err-obs.log" || fail "green tick must log OBSERVED-RESOLVED $(cat "$scratch/err-obs.log")"
grep -q '^1138$' "$gh_store/commented" || fail "green tick must comment on #1138 (commented=$(cat "$gh_store/commented"))"
grep -q "resolved-at: signal: decisions-ledger/vacation-window-corrected" "$gh_store/issue-1138.comments" \
  || fail "comment missing resolved-at marker"
if [ -s "$gh_store/closed" ]; then
  fail "same-tick must not close (closed=$(cat "$gh_store/closed"))"
fi
ok "observe-to-close: green tick comments resolved-at, does not close same tick"
rm -f "$sessions/oneshot-observe.jsonl"

# Later tick: marker already present, slug still absent -> close
: >"$gh_store/commented"
: >"$gh_store/closed"
write_session "clean-observe2" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Still clean."}]}}'
set +e
FLEET_DECISIONS_LEDGER_SESSIONS="$scratch/sessions" \
FLEET_DECISIONS_LEDGER="$scratch/ledger.md" \
FLEET_DECISIONS_LEDGER_LIB="$lib" \
FLEET_DECISIONS_LEDGER_WINDOW_HOURS="24" \
FLEET_DECISIONS_LEDGER_GRACE_MINUTES="0" \
FLEET_DECISIONS_LEDGER_NOW="2026-08-27T00:10:00Z" \
FLEET_DECISIONS_LEDGER_FILE_ISSUES=1 \
FLEET_DECISIONS_LEDGER_CLOSE_ISSUES=1 \
FLEET_DECISIONS_LEDGER_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-close.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "observe close tick should exit 0 (got $rc) $(cat "$scratch/err-close.log")"
grep -q "OBSERVE-CLOSED" "$scratch/err-close.log" || fail "later tick must log OBSERVE-CLOSED $(cat "$scratch/err-close.log")"
grep -q '^1138$' "$gh_store/closed" || fail "later tick must close #1138 (closed=$(cat "$gh_store/closed"))"
if [ -s "$gh_store/commented" ]; then
  fail "later tick must not comment again (commented=$(cat "$gh_store/commented"))"
fi
ok "observe-to-close: later tick with resolved-at marker closes"
rm -f "$sessions/clean-observe2.jsonl"

# Still-dirty slug: even with a resolved-at marker, do not close
: >"$gh_store/commented"
: >"$gh_store/closed"
rm -f "$gh_store/issue-1138.closed"
write_session "still-dirty" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Nish, should we keep the vacation window grants running only through 2026-09-08?"}]}}'
set +e
FLEET_DECISIONS_LEDGER_SESSIONS="$scratch/sessions" \
FLEET_DECISIONS_LEDGER="$scratch/ledger.md" \
FLEET_DECISIONS_LEDGER_LIB="$lib" \
FLEET_DECISIONS_LEDGER_WINDOW_HOURS="24" \
FLEET_DECISIONS_LEDGER_GRACE_MINUTES="0" \
FLEET_DECISIONS_LEDGER_NOW="2026-08-27T00:10:00Z" \
FLEET_DECISIONS_LEDGER_FILE_ISSUES=1 \
FLEET_DECISIONS_LEDGER_CLOSE_ISSUES=1 \
FLEET_DECISIONS_LEDGER_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-dirty.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "still-dirty slug should exit 1 (got $rc) $(cat "$scratch/err-dirty.log")"
if [ -s "$gh_store/closed" ]; then
  fail "still-dirty slug must not close (closed=$(cat "$gh_store/closed"))"
fi
if [ -s "$gh_store/commented" ]; then
  fail "still-dirty slug must not comment resolved-at (commented=$(cat "$gh_store/commented"))"
fi
ok "observe-to-close: still-dirty slug is neither commented nor closed"
rm -f "$sessions/still-dirty.jsonl"

# Three-place citation lock for #1138
grep -q 'fleet-ops#1138' "$lib" \
  || fail "lib/decisions-ledger.py must cite fleet-ops#1138"
grep -q 'fleet-ops#1138' "$bin" \
  || fail "bin/fleet-decisions-ledger must cite fleet-ops#1138"
grep -q 'fleet-ops#1138' "$repo_root/prompts/worker.md" \
  || fail "prompts/worker.md must cite fleet-ops#1138"
grep -Fq 'bash "$here/fleet-decisions-ledger.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file"
grep -q '#1138' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must cite #1138 next to the nested host"
ok "citation lock: #1138 in helper, bin, worker prompt, and nested CI host"

echo "OK: fleet-decisions-ledger: re-ask lint, ledger-checked escape, auto-file dedupe, #1138 false-positive class, observe-to-close"
