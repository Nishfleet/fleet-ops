#!/usr/bin/env bash
# tests/fleet-interventions-eliminated.test.sh
#
# fleet-ops#526: session-close lint for "interventions get eliminated,
# not repeated". Offline. Live gh is stubbed. Proves:
#   1. Clean assistant/user text -> exit 0, INTERVENTIONS-OK.
#   2. One correction -> exit 0 (first strike is not the alarm).
#   3. Two similar corrections across sessions -> exit 0 (two strikes).
#   4. Third identical attempt -> exit 1, INTERVENTIONS-REPEAT.
#   5. Three unrelated corrections -> exit 0 (not the same intervention).
#   6. Quoted correction in assistant docs -> exit 0.
#   7. Packet-sized user dump containing the phrase -> exit 0.
#   8. Auto-file with signal key, deduped on a second run.
#   9. Missing helper fails loud.
#  10. Observe-to-close: green tick comments resolved-at; later tick
#      closes; still-dirty slug is neither commented nor closed.
#  11. Contracts: heartbeat wiring, MANIFEST, nested CI host, matrix.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-interventions-eliminated"
lib="$repo_root/lib/interventions-eliminated.py"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t interventions-eliminated.XXXXXX)"
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

reset_sessions() {
  rm -f "$sessions"/*.jsonl
}

write_session() {
  local name="$1"
  local jsonl="$2"
  printf '%s\n' "$jsonl" >"$sessions/$name.jsonl"
  touch -d "2026-08-27T00:00:00Z" "$sessions/$name.jsonl"
}

run_bin() {
  local file_issues="${1:-0}"
  set +e
  FLEET_INTERVENTIONS_SESSIONS="$scratch/sessions" \
  FLEET_INTERVENTIONS_LIB="$lib" \
  FLEET_INTERVENTIONS_WINDOW_HOURS="336" \
  FLEET_INTERVENTIONS_GRACE_MINUTES="0" \
  FLEET_INTERVENTIONS_NOW="2026-08-27T00:10:00Z" \
  FLEET_INTERVENTIONS_THRESHOLD="3" \
  FLEET_INTERVENTIONS_FILE_ISSUES="$file_issues" \
  FLEET_INTERVENTIONS_CLOSE_ISSUES=1 \
  FLEET_INTERVENTIONS_ISSUE_REPO="Nishfleet/fleet-ops" \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$gh_store" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

# --- 1. clean session -------------------------------------------------------
reset_sessions
write_session "clean" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Opened the PR. Nothing to correct."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "clean session should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "INTERVENTIONS-OK" "$scratch/err.log" || fail "clean session missing OK line"
ok "clean session exits 0"

# --- 2. one correction is not the alarm -------------------------------------
reset_sessions
write_session "once" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I already told you not to spawn subagents."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "single correction should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "first strike is not flagged"

# --- 3. two similar corrections (two strikes) -------------------------------
reset_sessions
write_session "strike1" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I already told you not to spawn subagents."}]}}'
write_session "strike2" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I told you not to spawn subagents. Stop doing that."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "two strikes should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "two strikes are not the alarm"

# --- 4. third identical attempt ---------------------------------------------
reset_sessions
write_session "strike1" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I already told you not to spawn subagents."}]}}'
write_session "strike2" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I told you not to spawn subagents. Stop doing that."}]}}'
write_session "strike3" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Third time: don'\''t spawn subagents again."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "third identical attempt should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "INTERVENTIONS-REPEAT" "$scratch/err.log" || fail "missing INTERVENTIONS-REPEAT loud line"
ok "third identical attempt is flagged"

# --- 5. three unrelated corrections do not cluster --------------------------
reset_sessions
write_session "a" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I already told you not to spawn subagents."}]}}'
write_session "b" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I already told you never to merge onto main."}]}}'
write_session "c" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I already told you to stop rotating secrets in chat."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "unrelated corrections should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "unrelated corrections do not cluster"

# --- 6. quoted correction in assistant docs ---------------------------------
reset_sessions
write_session "quoted" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The standing rule names \"I already told you not to spawn subagents\" as the failure mode this lint kills."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "quoted docs should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "quoted correction in assistant text is ignored"

# --- 7. packet-sized user dump is ignored -----------------------------------
reset_sessions
packet_text="You implement exactly ONE GitHub issue. TARGET: repo Nishfleet/fleet-ops issue 526. Hard rules: I already told you not to spawn subagents. "
packet_text="${packet_text}${packet_text}${packet_text}${packet_text}${packet_text}"
python3 - "$sessions/packet.jsonl" "$packet_text" <<'PY'
import json, sys
path, text = sys.argv[1], sys.argv[2] * 40
obj = {"type":"message","message":{"role":"user","content":[{"type":"text","text": text}]}}
open(path, "w", encoding="utf-8").write(json.dumps(obj) + "\n")
PY
touch -d "2026-08-27T00:00:00Z" "$sessions/packet.jsonl"
write_session "p1" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I already told you not to spawn subagents."}]}}'
write_session "p2" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I told you not to spawn subagents. Stop doing that."}]}}'
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "packet dump must not count as a third strike (got $rc) $(cat "$scratch/err.log")"
ok "packet-sized user dump is ignored"

# --- 8. auto-file + dedupe --------------------------------------------------
reset_sessions
write_session "strike1" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I already told you not to spawn subagents."}]}}'
write_session "strike2" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I told you not to spawn subagents. Stop doing that."}]}}'
write_session "strike3" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Third time: don'\''t spawn subagents again."}]}}'
set +e
FLEET_INTERVENTIONS_SESSIONS="$scratch/sessions" \
FLEET_INTERVENTIONS_LIB="$lib" \
FLEET_INTERVENTIONS_WINDOW_HOURS="336" \
FLEET_INTERVENTIONS_GRACE_MINUTES="0" \
FLEET_INTERVENTIONS_NOW="2026-08-27T00:10:00Z" \
FLEET_INTERVENTIONS_THRESHOLD="3" \
FLEET_INTERVENTIONS_FILE_ISSUES=1 \
FLEET_INTERVENTIONS_CLOSE_ISSUES=1 \
FLEET_INTERVENTIONS_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err2.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "auto-file run should exit 1 (got $rc) $(cat "$scratch/err2.log")"
grep -q "FILED" "$scratch/err2.log" || { cat "$scratch/err2.log"; fail "auto-file did not file an issue"; }
grep -rq "signal: interventions-eliminated/" "$scratch/gh-issues" || fail "filed issue body missing signal key"
ok "auto-file creates an issue with the signal key"

set +e
FLEET_INTERVENTIONS_SESSIONS="$scratch/sessions" \
FLEET_INTERVENTIONS_LIB="$lib" \
FLEET_INTERVENTIONS_WINDOW_HOURS="336" \
FLEET_INTERVENTIONS_GRACE_MINUTES="0" \
FLEET_INTERVENTIONS_NOW="2026-08-27T00:10:00Z" \
FLEET_INTERVENTIONS_THRESHOLD="3" \
FLEET_INTERVENTIONS_FILE_ISSUES=1 \
FLEET_INTERVENTIONS_CLOSE_ISSUES=1 \
FLEET_INTERVENTIONS_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err3.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "second auto-file run should still exit 1 (got $rc)"
grep -q "deduped" "$scratch/err3.log" || fail "second run did not dedupe $(cat "$scratch/err3.log")"
grep -rl "signal: interventions-eliminated/" "$scratch/gh-issues" | wc -l | grep -q "^1$" \
  || fail "signal key filed more than once (dedupe broken)"
ok "auto-file dedupes the signal key on a second run"
rm -f "$sessions/strike1.jsonl" "$sessions/strike2.jsonl" "$sessions/strike3.jsonl"

# --- 9. missing helper fails loud -------------------------------------------
set +e
FLEET_INTERVENTIONS_SESSIONS="$scratch/sessions" \
FLEET_INTERVENTIONS_LIB="$scratch/no-such.py" \
FLEET_INTERVENTIONS_FILE_ISSUES=0 \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err4.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "missing helper should exit 1 (got $rc)"
grep -q "INTERVENTIONS-BROKEN" "$scratch/err4.log" || fail "missing helper must be LOUD"
ok "missing helper fails loud"

# --- 10. observe-to-close (fleet-ops#650 shape) -----------------------------
reset_sessions
rm -f "$gh_store"/issue-* "$gh_store"/commented "$gh_store"/closed
: >"$gh_store/commented"
: >"$gh_store/closed"
printf '%s\n' "fix(interventions-eliminated): spawn-subagents" >"$gh_store/issue-526.body"
printf '%s\n' "Do not close until the detector reports this clean.

signal: interventions-eliminated/spawn-subagents" >>"$gh_store/issue-526.body"

write_session "clean-obs" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Opened the PR. Nothing to correct."}]}}'
set +e
FLEET_INTERVENTIONS_SESSIONS="$scratch/sessions" \
FLEET_INTERVENTIONS_LIB="$lib" \
FLEET_INTERVENTIONS_WINDOW_HOURS="336" \
FLEET_INTERVENTIONS_GRACE_MINUTES="0" \
FLEET_INTERVENTIONS_NOW="2026-08-27T00:10:00Z" \
FLEET_INTERVENTIONS_THRESHOLD="3" \
FLEET_INTERVENTIONS_FILE_ISSUES=1 \
FLEET_INTERVENTIONS_CLOSE_ISSUES=1 \
FLEET_INTERVENTIONS_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-obs.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "observe-to-close green tick should exit 0 (got $rc) $(cat "$scratch/err-obs.log")"
grep -q "OBSERVED-RESOLVED" "$scratch/err-obs.log" || fail "green tick must log OBSERVED-RESOLVED $(cat "$scratch/err-obs.log")"
grep -q '^526$' "$gh_store/commented" || fail "green tick must comment on #526 (commented=$(cat "$gh_store/commented"))"
grep -q "resolved-at: signal: interventions-eliminated/spawn-subagents" "$gh_store/issue-526.comments" \
  || fail "comment missing resolved-at marker"
if [ -s "$gh_store/closed" ]; then
  fail "same-tick must not close (closed=$(cat "$gh_store/closed"))"
fi
ok "observe-to-close: green tick comments resolved-at, does not close same tick"
rm -f "$sessions/clean-obs.jsonl"

: >"$gh_store/commented"
: >"$gh_store/closed"
write_session "clean-obs2" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Still clean."}]}}'
set +e
FLEET_INTERVENTIONS_SESSIONS="$scratch/sessions" \
FLEET_INTERVENTIONS_LIB="$lib" \
FLEET_INTERVENTIONS_WINDOW_HOURS="336" \
FLEET_INTERVENTIONS_GRACE_MINUTES="0" \
FLEET_INTERVENTIONS_NOW="2026-08-27T00:10:00Z" \
FLEET_INTERVENTIONS_THRESHOLD="3" \
FLEET_INTERVENTIONS_FILE_ISSUES=1 \
FLEET_INTERVENTIONS_CLOSE_ISSUES=1 \
FLEET_INTERVENTIONS_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-close.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "observe close tick should exit 0 (got $rc) $(cat "$scratch/err-close.log")"
grep -q "OBSERVE-CLOSED" "$scratch/err-close.log" || fail "later tick must log OBSERVE-CLOSED $(cat "$scratch/err-close.log")"
grep -q '^526$' "$gh_store/closed" || fail "later tick must close #526 (closed=$(cat "$gh_store/closed"))"
if [ -s "$gh_store/commented" ]; then
  fail "later tick must not comment again (commented=$(cat "$gh_store/commented"))"
fi
ok "observe-to-close: later tick with resolved-at marker closes"
rm -f "$sessions/clean-obs2.jsonl"

: >"$gh_store/commented"
: >"$gh_store/closed"
rm -f "$gh_store/issue-526.closed"
write_session "strike1" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I already told you not to spawn subagents."}]}}'
write_session "strike2" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"I told you not to spawn subagents. Stop doing that."}]}}'
write_session "strike3" '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Third time: don'\''t spawn subagents again."}]}}'
# The dirty cluster slug is spawn-subagents (from token overlap). Pre-seed
# the open issue with that live slug so observe-to-close sees a still-dirty
# finding and refuses to close.
rm -f "$gh_store"/issue-*
dirty_slug=$(python3 "$lib" scan --root "$scratch/sessions" --now "2026-08-27T00:10:00Z" --window-hours 336 --grace-minutes 0 --threshold 3 \
  | jq -r '.findings[0].slug')
[[ -n "$dirty_slug" && "$dirty_slug" != "null" ]] || fail "dirty cluster must produce a slug"
printf '%s\n' "fix(interventions-eliminated): $dirty_slug" >"$gh_store/issue-526.body"
printf '%s\n' "Do not close until the detector reports this clean.

signal: interventions-eliminated/${dirty_slug}" >>"$gh_store/issue-526.body"
printf '%s\n' "resolved-at: signal: interventions-eliminated/${dirty_slug}" >"$gh_store/issue-526.comments"
set +e
FLEET_INTERVENTIONS_SESSIONS="$scratch/sessions" \
FLEET_INTERVENTIONS_LIB="$lib" \
FLEET_INTERVENTIONS_WINDOW_HOURS="336" \
FLEET_INTERVENTIONS_GRACE_MINUTES="0" \
FLEET_INTERVENTIONS_NOW="2026-08-27T00:10:00Z" \
FLEET_INTERVENTIONS_THRESHOLD="3" \
FLEET_INTERVENTIONS_FILE_ISSUES=1 \
FLEET_INTERVENTIONS_CLOSE_ISSUES=1 \
FLEET_INTERVENTIONS_ISSUE_REPO="Nishfleet/fleet-ops" \
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
ok "observe-to-close: still-dirty slug is neither commented nor closed"

# --- 11. contracts ----------------------------------------------------------
grep -q 'fleet-interventions-eliminated' "$tier1" \
  || fail "fleet-heartbeat-tier1 must invoke fleet-interventions-eliminated"
grep -q 'interventions_eliminated_rc' "$tier1" \
  || fail "fleet-heartbeat-tier1 must propagate interventions_eliminated_rc"
grep -qE 'if \[ "\$\{interventions_eliminated_rc:-0\}" -ge 2 \]; then' "$tier1" \
  || fail "heartbeat must only propagate interventions_eliminated_rc on crash (rc >= 2)"
if grep -nE 'if \[ "\$\{interventions_eliminated_rc:-0\}" -ne 0 \]; then' "$tier1" | grep -q .; then
  fail "heartbeat must not trip the unit on interventions alarm (rc=1)"
fi
grep -q 'bin/fleet-interventions-eliminated' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-interventions-eliminated"
grep -q 'lib/interventions-eliminated.py' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install lib/interventions-eliminated.py"
grep -Fq 'bash "$here/fleet-interventions-eliminated.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
jq -e '.rules[] | select(.id == "sr-interventions-eliminated" and .status == "enforced")' \
  "$repo_root/config/rule-enforcement.json" >/dev/null \
  || fail "sr-interventions-eliminated must be status=enforced in the matrix"
ok "contracts: heartbeat-tier1, MANIFEST, nested CI host, matrix enforced"

echo "OK: fleet-interventions-eliminated: two-strikes lint, third-attempt alarm, auto-file dedupe, observe-to-close"
