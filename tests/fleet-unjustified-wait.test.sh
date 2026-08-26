#!/usr/bin/env bash
# tests/fleet-unjustified-wait.test.sh
#
# TOP GEAR invariant (fleet-ops#468, decisions-ledger 2026-08-27):
# "deferral requires a named clock". Every held/benched/waiting item must
# carry a machine-checkable justification; anything without one is a LOUD
# [UNJUSTIFIED-WAIT] that auto-files.
#
# What we prove:
#   1. Clean ledger (every seat has its clock) -> exit 0, UNJUSTIFIED-WAIT-OK.
#   2. quota_bench seat with NO bench_until -> exit 1, UNJUSTIFIED-WAIT.
#   3. quota_exhausted/rate_limited seat with NO usable_at -> exit 1.
#   4. credentials_bad seat WITHOUT seat_dead=true -> exit 1 (missing clock).
#   5. seat_dead=true with a non-dead class -> exit 1 (inconsistent).
#   6. STOP-REASON with an illegal reason -> exit 1.
#   7. READY-WORK stalled claim (CLAIMED, old, no DONE, no after:) -> exit 1.
#   8. Auto-file: gh mock creates an issue with the signal key, deduped on
#      a second run (open issue already carries the signal).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-unjustified-wait"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "fleet-unjustified-wait not found: $bin"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t unjustified.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# gh mock: per-issue body files under the store dir (multi-line bodies).
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
            --repo) shift 2 ;;
            *) shift ;;
          esac
        done
        n=$(ls "$store" | wc -l)
        f="$store/issue-$((n+1)).body"
        printf '%s\n' "$title" > "$f"
        printf '%s\n' "$body" >> "$f"
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        ;;
      list)
        printf '[\n'
        first=1
        for f in "$store"/*.body; do
          [ -f "$f" ] || continue
          # body = everything after the first line (the title).
          body=$(tail -n +2 "$f")
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":1,"title":"","body":%s}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")"
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

run_bin() {
  set +e
  FLEET_SEAT_LEDGER_DIR="$scratch/seats" \
  FLEET_STOP_REASON="$scratch/STOP-REASON.json" \
  FLEET_READY_WORK="$scratch/READY-WORK.md" \
  FLEET_UNJUSTIFIED_WAIT_NOW="2026-08-27T00:00:00Z" \
  FLEET_CLAIM_STALE_HOURS="24" \
  FLEET_UNJUSTIFIED_WAIT_FILE_ISSUES=0 \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$gh_store" \
  FLEET_UNJUSTIFIED_WAIT_ISSUE_REPO="Nishfleet/fleet-ops" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    "$bin" "$scratch" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

# --- 1. clean ledger --------------------------------------------------------
mkdir -p "$scratch/seats"
cat >"$scratch/seats/good.json" <<'JSON'
{"provider":"devin","model":"glm-5-2","health_class":"quota_bench","seat_dead":false,"observed_at":"2026-08-27T00:00:00Z","bench_until":"2026-08-27T01:00:00Z"}
JSON
cat >"$scratch/seats/healthy.json" <<'JSON'
{"provider":"cline","model":"x","health_class":"healthy","seat_dead":false,"observed_at":"2026-08-27T00:00:00Z"}
JSON
: >"$scratch/STOP-REASON.json"
: >"$scratch/READY-WORK.md"
rc=$(run_bin)
[[ "$rc" == "0" ]] || fail "clean ledger should exit 0 (got $rc)"
grep -q "UNJUSTIFIED-WAIT-OK" "$scratch/err.log" || fail "clean ledger missing OK line"
ok "clean ledger exits 0 with UNJUSTIFIED-WAIT-OK"

# --- 2. quota_bench without bench_until --------------------------------------
cat >"$scratch/seats/bench-noclock.json" <<'JSON'
{"provider":"devin","model":"y","health_class":"quota_bench","seat_dead":false,"observed_at":"2026-08-27T00:00:00Z"}
JSON
rc=$(run_bin)
[[ "$rc" == "1" ]] || fail "quota_bench without bench_until should exit 1 (got $rc)"
grep -q "UNJUSTIFIED-WAIT" "$scratch/err.log" || fail "missing UNJUSTIFIED-WAIT loud line"
grep -q "bench_until" "$scratch/err.log" || fail "missing bench_until mention"
ok "quota_bench without bench_until is flagged"

rm -f "$scratch/seats/bench-noclock.json"

# --- 3. quota_exhausted without usable_at ------------------------------------
cat >"$scratch/seats/exh-noclock.json" <<'JSON'
{"provider":"minimax","model":"m","health_class":"quota_exhausted","seat_dead":false,"observed_at":"2026-08-27T00:00:00Z"}
JSON
rc=$(run_bin)
[[ "$rc" == "1" ]] || fail "quota_exhausted without usable_at should exit 1 (got $rc)"
grep -q "usable_at" "$scratch/err.log" || fail "missing usable_at mention"
ok "quota_exhausted without usable_at is flagged"
rm -f "$scratch/seats/exh-noclock.json"

# --- 4. credentials_bad without seat_dead ------------------------------------
cat >"$scratch/seats/creds-nodead.json" <<'JSON'
{"provider":"grok","model":"g","health_class":"credentials_bad","seat_dead":false,"observed_at":"2026-08-27T00:00:00Z"}
JSON
rc=$(run_bin)
[[ "$rc" == "1" ]] || fail "credentials_bad without seat_dead should exit 1 (got $rc)"
grep -q "seat_dead" "$scratch/err.log" || fail "missing seat_dead mention"
ok "credentials_bad without seat_dead is flagged"
rm -f "$scratch/seats/creds-nodead.json"

# --- 5. seat_dead=true with non-dead class -----------------------------------
cat >"$scratch/seats/dead-healthy.json" <<'JSON'
{"provider":"grok","model":"g","health_class":"healthy","seat_dead":true,"observed_at":"2026-08-27T00:00:00Z"}
JSON
rc=$(run_bin)
[[ "$rc" == "1" ]] || fail "seat_dead=true with healthy class should exit 1 (got $rc)"
ok "seat_dead=true with non-dead class is flagged"
rm -f "$scratch/seats/dead-healthy.json"

# --- 6. STOP-REASON illegal reason -------------------------------------------
printf '%s\n' '{"reason":"mystery-wait","detail":{}}' >"$scratch/STOP-REASON.json"
rc=$(run_bin)
[[ "$rc" == "1" ]] || fail "illegal STOP-REASON reason should exit 1 (got $rc)"
grep -q "mystery-wait" "$scratch/err.log" || fail "missing reason mention"
ok "illegal STOP-REASON reason is flagged"
printf '%s\n' '{"reason":"unit-failure","detail":{}}' >"$scratch/STOP-REASON.json"

# --- 7. stalled READY-WORK claim ---------------------------------------------
printf '%s\n' "- [ ] Item A — a ready item without after:" >"$scratch/READY-WORK.md"
printf '%s\n' "- [ ] Item B CLAIMED:2026-08-25T00:00:00Z — stale claim, no DONE, no after:" >>"$scratch/READY-WORK.md"
rc=$(run_bin)
[[ "$rc" == "1" ]] || fail "stale READY-WORK claim should exit 1 (got $rc)"
grep -q "stalled" "$scratch/err.log" || fail "missing stalled-claim mention"
ok "stalled READY-WORK claim is flagged"

# --- 8. auto-file with signal key + dedupe -----------------------------------
: >"$scratch/READY-WORK.md"
: >"$scratch/STOP-REASON.json"
rm -rf "$scratch/seats"
mkdir -p "$scratch/seats"
cat >"$scratch/seats/bench-noclock.json" <<'JSON'
{"provider":"devin","model":"y","health_class":"quota_bench","seat_dead":false,"observed_at":"2026-08-27T00:00:00Z"}
JSON
set +e
FLEET_SEAT_LEDGER_DIR="$scratch/seats" \
FLEET_STOP_REASON="$scratch/STOP-REASON.json" \
FLEET_READY_WORK="$scratch/READY-WORK.md" \
FLEET_UNJUSTIFIED_WAIT_NOW="2026-08-27T00:00:00Z" \
FLEET_UNJUSTIFIED_WAIT_FILE_ISSUES=1 \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_UNJUSTIFIED_WAIT_ISSUE_REPO="Nishfleet/fleet-ops" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" "$scratch" >/dev/null 2>"$scratch/err2.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "auto-file run should exit 1 (got $rc)"
grep -q "FILED" "$scratch/err2.log" || { cat "$scratch/err2.log"; fail "auto-file did not file an issue"; }
grep -rq "signal: unjustified-wait/" "$scratch/gh-issues" || fail "filed issue body missing signal key"
ok "auto-file creates an issue with the signal key"

# Second run: same finding must dedupe (open issue already has the signal).
set +e
FLEET_SEAT_LEDGER_DIR="$scratch/seats" \
FLEET_STOP_REASON="$scratch/STOP-REASON.json" \
FLEET_READY_WORK="$scratch/READY-WORK.md" \
FLEET_UNJUSTIFIED_WAIT_NOW="2026-08-27T00:00:00Z" \
FLEET_UNJUSTIFIED_WAIT_FILE_ISSUES=1 \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_UNJUSTIFIED_WAIT_ISSUE_REPO="Nishfleet/fleet-ops" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" "$scratch" >/dev/null 2>"$scratch/err3.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "second auto-file run should still exit 1 (got $rc)"
grep -q "deduped" "$scratch/err3.log" || fail "second run did not dedupe"
grep -rl "signal: unjustified-wait/" "$scratch/gh-issues" | wc -l | grep -q "^1$" \
  || fail "signal key filed more than once (dedupe broken)"
ok "auto-file dedupes the signal key on a second run"

echo "OK: fleet-unjustified-wait: clock audit, loud fail, auto-file dedupe"
