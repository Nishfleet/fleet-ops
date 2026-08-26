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
#  10. Contracts: heartbeat wiring, MANIFEST, nested CI host, matrix.

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
      list)
        printf '[\n'
        first=1
        n=0
        for f in "$store"/*.body; do
          [ -f "$f" ] || continue
          n=$((n+1))
          body=$(tail -n +2 "$f")
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"title":"","body":%s}' "$n" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")"
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
# Make it long enough to trip the packet-size skip even without the marker.
python3 - "$sessions/packet.jsonl" "$packet_text" <<'PY'
import json, sys
path, text = sys.argv[1], sys.argv[2] * 40
obj = {"type":"message","message":{"role":"user","content":[{"type":"text","text": text}]}}
open(path, "w", encoding="utf-8").write(json.dumps(obj) + "\n")
PY
touch -d "2026-08-27T00:00:00Z" "$sessions/packet.jsonl"
# Three copies would still be one event per file if scanned; keep a single
# packet plus two real short corrections so a leak would fire.
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

# --- 10. contracts ----------------------------------------------------------
grep -q 'fleet-interventions-eliminated' "$tier1" \
  || fail "fleet-heartbeat-tier1 must invoke fleet-interventions-eliminated"
grep -q 'interventions_eliminated_rc' "$tier1" \
  || fail "fleet-heartbeat-tier1 must propagate interventions_eliminated_rc"
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

echo "OK: fleet-interventions-eliminated: two-strikes lint, third-attempt alarm, auto-file dedupe"
