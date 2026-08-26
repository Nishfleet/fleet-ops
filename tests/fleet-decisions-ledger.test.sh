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
- 2026-08-25 | 0509 deploys | auto deploy on green | test
- 2026-08-26 | bikeshed colour | never ask about zebras painted purple | test
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
set +e
FLEET_DECISIONS_LEDGER_SESSIONS="$scratch/sessions" \
FLEET_DECISIONS_LEDGER="$scratch/ledger.md" \
FLEET_DECISIONS_LEDGER_LIB="$scratch/no-such.py" \
FLEET_DECISIONS_LEDGER_FILE_ISSUES=0 \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err4.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "missing helper should exit 1 (got $rc)"
grep -q "DECISIONS-LEDGER-BROKEN" "$scratch/err4.log" || fail "missing helper must be LOUD"
ok "missing helper fails loud"

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

echo "OK: fleet-decisions-ledger: re-ask lint, ledger-checked escape, auto-file dedupe"
