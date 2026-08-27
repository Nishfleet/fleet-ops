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
  # In-window, outside grace: stamp mtime to the frozen now.
  touch -d "2026-08-27T00:00:00Z" "$sessions/$name.jsonl"
}

run_bin() {
  local file_issues="${1:-0}"
  set +e
  FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
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

# --- 6. auto-file + dedupe --------------------------------------------------
write_session "ask-nofile" '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Should I file a new issue about the silent canary?"}]}}'
set +e
FLEET_FINDINGS_QUEUED_SESSIONS="$scratch/sessions" \
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
FLEET_FINDINGS_QUEUED_LIB="$scratch/no-such.py" \
FLEET_FINDINGS_QUEUED_FILE_ISSUES=0 \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err4.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "missing helper should exit 1 (got $rc) — guard did not win over installed fallback"
grep -q "FINDINGS-QUEUED-BROKEN" "$scratch/err4.log" || fail "missing helper must be LOUD"
ok "missing helper fails loud (guard wins over installed fallback)"

# --- 8. contracts -----------------------------------------------------------
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
