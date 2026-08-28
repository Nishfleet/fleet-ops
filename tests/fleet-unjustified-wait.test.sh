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
#   7. READY-WORK stalled claim (CLAIMED, old, no DONE, no after:) with
#      REPAIR=0 -> exit 1 (audit-only path still LOUD).
#   7b. Same stalled claim with REPAIR=1 (default) -> strips CLAIMED:,
#      exits 0, UNJUSTIFIED-WAIT-REPAIR + UNJUSTIFIED-WAIT-OK (fleet-ops#852).
#   8. Auto-file: gh mock creates an issue with the signal key, deduped on
#      a second run (open issue already carries the signal).
#   8b. Observe-to-close: green tick with CLOSE_ISSUES=1 posts resolved-at
#       on an open signal issue; a later green tick closes it (#852).

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
# Also tracks comments + closed state for observe-to-close (fleet-ops#852).
gh_store="$scratch/gh-issues"
mkdir -p "$gh_store" "$gh_store/comments" "$gh_store/closed"
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
        # Support --json number,body[,comments] and --state open.
        want_comments=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --json)
              [[ "$2" == *comments* ]] && want_comments=1
              shift 2
              ;;
            --state) shift 2 ;;
            --limit|-R|--repo) shift 2 ;;
            *) shift ;;
          esac
        done
        printf '[\n'
        first=1
        for f in "$store"/issue-*.body; do
          [ -f "$f" ] || continue
          base=$(basename "$f" .body)           # issue-N
          num=${base#issue-}
          [ -f "$store/closed/$num" ] && continue
          body=$(tail -n +2 "$f")
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          body_json=$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")
          if [ "$want_comments" = 1 ]; then
            comments_json='[]'
            cdir="$store/comments/$num"
            if [ -d "$cdir" ]; then
              comments_json=$(python3 -c '
import json,sys,os
d=sys.argv[1]
out=[]
for name in sorted(os.listdir(d)):
    p=os.path.join(d,name)
    if os.path.isfile(p):
        out.append({"body": open(p).read()})
print(json.dumps(out))
' "$cdir")
            fi
            printf '{"number":%s,"title":"","body":%s,"comments":%s}' "$num" "$body_json" "$comments_json"
          else
            printf '{"number":%s,"title":"","body":%s}' "$num" "$body_json"
          fi
        done
        printf '\n]\n'
        ;;
      comment)
        num="$1"; shift
        body=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --body) body="$2"; shift 2 ;;
            -R|--repo) shift 2 ;;
            *) shift ;;
          esac
        done
        mkdir -p "$store/comments/$num"
        n=$(find "$store/comments/$num" -maxdepth 1 -type f 2>/dev/null | wc -l)
        printf '%s\n' "$body" > "$store/comments/$num/c$((n+1)).txt"
        echo "https://github.com/Nishfleet/fleet-ops/issues/$num#comment-1"
        ;;
      close)
        num="$1"; shift
        # Accept --reason completed and -R/--repo.
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --reason|-R|--repo) shift 2 ;;
            *) shift ;;
          esac
        done
        mkdir -p "$store/closed"
        : > "$store/closed/$num"
        echo "Closed #$num"
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/gh"

run_bin() {
  # Default REPAIR=0 so existing audit-only scenarios keep asserting the
  # LOUD finding. Scenario 7b opts into REPAIR=1 to prove the #852 fix.
  set +e
  FLEET_SEAT_LEDGER_DIR="$scratch/seats" \
  FLEET_STOP_REASON="$scratch/STOP-REASON.json" \
  FLEET_READY_WORK="$scratch/READY-WORK.md" \
  FLEET_UNJUSTIFIED_WAIT_NOW="2026-08-27T00:00:00Z" \
  FLEET_CLAIM_STALE_HOURS="24" \
  FLEET_UNJUSTIFIED_WAIT_REPAIR="${FLEET_UNJUSTIFIED_WAIT_REPAIR:-0}" \
  FLEET_UNJUSTIFIED_WAIT_CLOSE_ISSUES="${FLEET_UNJUSTIFIED_WAIT_CLOSE_ISSUES:-0}" \
  FLEET_UNJUSTIFIED_WAIT_FILE_ISSUES=0 \
  FLEET_OPS_REPO="$scratch" \
  SYSTEMD_ANALYZE="${SYSTEMD_ANALYZE:-systemd-analyze}" \
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

# --- 7. stalled READY-WORK claim (audit-only, REPAIR=0) ----------------------
printf '%s\n' "- [ ] Item A — a ready item without after:" >"$scratch/READY-WORK.md"
printf '%s\n' "- [ ] Item B CLAIMED:2026-08-25T00:00:00Z — stale claim, no DONE, no after:" >>"$scratch/READY-WORK.md"
rc=$(FLEET_UNJUSTIFIED_WAIT_REPAIR=0 run_bin)
[[ "$rc" == "1" ]] || fail "stale READY-WORK claim should exit 1 (got $rc)"
grep -q "stalled" "$scratch/err.log" || fail "missing stalled-claim mention"
ok "stalled READY-WORK claim is flagged (REPAIR=0)"

# --- 7b. stalled READY-WORK claim REPAIR=1 strips CLAIMED (fleet-ops#852) ----
# NOTE: do NOT put the prose "no after:" immediately before CLAIMED — the
# detector matches the substring "after: " (space required), and "no after: "
# would false-positive as a named clock.
printf '%s\n' "- [ ] Item A — a ready item" >"$scratch/READY-WORK.md"
printf '%s\n' "- [ ] Item B — stale claim without a named clock CLAIMED:2026-08-25T00:00:00Z" >>"$scratch/READY-WORK.md"
printf '%s\n' "- [ ] Item C after: test -f /tmp/does-not-exist CLAIMED:2026-08-25T00:00:00Z — gated, leave CLAIMED alone" >>"$scratch/READY-WORK.md"
rc=$(FLEET_UNJUSTIFIED_WAIT_REPAIR=1 run_bin)
[[ "$rc" == "0" ]] || { cat "$scratch/err.log"; fail "REPAIR=1 should exit 0 after unclaiming (got $rc)"; }
grep -q "UNJUSTIFIED-WAIT-REPAIR" "$scratch/err.log" || fail "missing REPAIR loud line"
grep -q "UNJUSTIFIED-WAIT-OK" "$scratch/err.log" || fail "missing OK line after repair"
# Item B must no longer carry CLAIMED:
grep "Item B" "$scratch/READY-WORK.md" | grep -q "CLAIMED:" \
  && { cat "$scratch/READY-WORK.md"; fail "Item B still carries CLAIMED after repair"; }
grep -q "Item B — stale claim without a named clock" "$scratch/READY-WORK.md" \
  || { cat "$scratch/READY-WORK.md"; fail "Item B should remain as ready-now without CLAIMED"; }
# Item C keeps CLAIMED because it has an after: gate (named clock).
grep "Item C" "$scratch/READY-WORK.md" | grep -q "CLAIMED:2026-08-25T00:00:00Z" \
  || { cat "$scratch/READY-WORK.md"; fail "Item C with after: must keep its CLAIMED marker"; }
ok "stalled READY-WORK claim is unclaimed by REPAIR=1 (fleet-ops#852)"

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

# --- 8b. observe-to-close on a green tick (fleet-ops#852) --------------------
# Seed an open signal issue (no finding this run) and prove the two-tick close.
rm -rf "$scratch/seats" "$scratch/gh-issues"
mkdir -p "$scratch/seats" "$scratch/gh-issues/comments" "$scratch/gh-issues/closed"
cat >"$scratch/seats/good.json" <<'JSON'
{"provider":"devin","model":"glm-5-2","health_class":"healthy","seat_dead":false,"observed_at":"2026-08-27T00:00:00Z"}
JSON
: >"$scratch/STOP-REASON.json"
: >"$scratch/READY-WORK.md"
# Pre-seed issue #1 with the signal key (as if a prior tick filed it).
printf '%s\n' "fix(unjustified-wait): top-gear-no-clock — deferral with no named clock" \
  >"$scratch/gh-issues/issue-1.body"
printf '%s\n' "finding body" "" "signal: unjustified-wait/top-gear-no-clock" \
  >>"$scratch/gh-issues/issue-1.body"

# Tick 1: green + CLOSE_ISSUES=1 -> posts resolved-at, does NOT close yet.
set +e
FLEET_SEAT_LEDGER_DIR="$scratch/seats" \
FLEET_STOP_REASON="$scratch/STOP-REASON.json" \
FLEET_READY_WORK="$scratch/READY-WORK.md" \
FLEET_UNJUSTIFIED_WAIT_NOW="2026-08-27T00:00:00Z" \
FLEET_UNJUSTIFIED_WAIT_REPAIR=0 \
FLEET_UNJUSTIFIED_WAIT_CLOSE_ISSUES=1 \
FLEET_UNJUSTIFIED_WAIT_FILE_ISSUES=0 \
FLEET_OPS_REPO="$scratch" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_UNJUSTIFIED_WAIT_ISSUE_REPO="Nishfleet/fleet-ops" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" "$scratch" >/dev/null 2>"$scratch/err-obs1.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || { cat "$scratch/err-obs1.log"; fail "observe tick1 should exit 0 (got $rc)"; }
grep -q "OBSERVED-RESOLVED" "$scratch/err-obs1.log" || { cat "$scratch/err-obs1.log"; fail "tick1 missing OBSERVED-RESOLVED"; }
[[ -f "$scratch/gh-issues/closed/1" ]] && fail "tick1 must NOT close yet (two-tick close)"
grep -Rq "resolved-at: signal: unjustified-wait/top-gear-no-clock" "$scratch/gh-issues/comments/1" \
  || { ls -la "$scratch/gh-issues/comments/1" 2>/dev/null; fail "tick1 did not post resolved-at marker"; }
ok "observe-to-close tick1 posts resolved-at without closing"

# Tick 2: green + CLOSE_ISSUES=1 with marker already present -> closes.
set +e
FLEET_SEAT_LEDGER_DIR="$scratch/seats" \
FLEET_STOP_REASON="$scratch/STOP-REASON.json" \
FLEET_READY_WORK="$scratch/READY-WORK.md" \
FLEET_UNJUSTIFIED_WAIT_NOW="2026-08-27T00:00:00Z" \
FLEET_UNJUSTIFIED_WAIT_REPAIR=0 \
FLEET_UNJUSTIFIED_WAIT_CLOSE_ISSUES=1 \
FLEET_UNJUSTIFIED_WAIT_FILE_ISSUES=0 \
FLEET_OPS_REPO="$scratch" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_UNJUSTIFIED_WAIT_ISSUE_REPO="Nishfleet/fleet-ops" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" "$scratch" >/dev/null 2>"$scratch/err-obs2.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || { cat "$scratch/err-obs2.log"; fail "observe tick2 should exit 0 (got $rc)"; }
grep -q "OBSERVE-CLOSED" "$scratch/err-obs2.log" || { cat "$scratch/err-obs2.log"; fail "tick2 missing OBSERVE-CLOSED"; }
[[ -f "$scratch/gh-issues/closed/1" ]] || fail "tick2 did not close the issue"
ok "observe-to-close tick2 closes after resolved-at marker (fleet-ops#852)"

# --- 9. timer gate audit ----------------------------------------------------
# Prepare a clean scratch repo with a systemd/ dir so the timer audit is
# exercised against fixtures, not the live VPS units.
rm -rf "$scratch/systemd"
mkdir -p "$scratch/systemd"

# 9a. periodic timer with Named reason is clean
printf '%s\n' '[Timer]' '# Named reason: daily signal is a true periodic cadence' 'OnCalendar=*-*-* 08:15:00' >"$scratch/systemd/periodic.timer"
rm -rf "$scratch/seats"
mkdir -p "$scratch/seats"
cat >"$scratch/seats/good.json" <<'JSON'
{"provider":"devin","model":"glm-5-2","health_class":"healthy","seat_dead":false,"observed_at":"2026-08-27T00:00:00Z"}
JSON
: >"$scratch/STOP-REASON.json"
: >"$scratch/READY-WORK.md"
rc=$(run_bin)
[[ "$rc" == "0" ]] || fail "periodic timer with Named reason should exit 0 (got $rc)"
ok "periodic timer with Named reason is clean"

# 9b. future one-shot with no named gate is a violation
rm -f "$scratch/systemd"/*.timer
printf '%s\n' '[Timer]' 'OnCalendar=2026-09-01 00:00:00' >"$scratch/systemd/future-nogate.timer"
rc=$(run_bin)
[[ "$rc" == "1" ]] || fail "future one-shot with no named gate should exit 1 (got $rc)"
grep -q "future-nogate.timer" "$scratch/err.log" || fail "missing future-nogate.timer mention"
grep -q "OnCalendar='2026-09-01 00:00:00'" "$scratch/err.log" || fail "missing OnCalendar mention"
ok "future one-shot with no named gate is flagged"

# 9c. future one-shot with named-gate comment is clean
rm -f "$scratch/systemd"/*.timer
printf '%s\n' '[Timer]' '# named-gate: third-party API rate-limit reset on 2026-09-01' 'OnCalendar=2026-09-01 00:00:00' >"$scratch/systemd/future-gate.timer"
rc=$(run_bin)
[[ "$rc" == "0" ]] || fail "future one-shot with named-gate comment should exit 0 (got $rc)"
ok "future one-shot with named-gate comment is clean"

# 9d. future one-shot with Named reason in linked .service file is clean
rm -f "$scratch/systemd"/*.timer
printf '%s\n' '[Timer]' 'OnCalendar=2026-09-01 00:00:00' 'Unit=future-svc.service' >"$scratch/systemd/future-svc.timer"
printf '%s\n' '[Unit]' 'Description=fixture' '# Named reason: data window closes on 2026-09-01' >"$scratch/systemd/future-svc.service"
rc=$(run_bin)
[[ "$rc" == "0" ]] || fail "future one-shot with Named reason in .service should exit 0 (got $rc)"
ok "future one-shot with Named reason in linked .service is clean"

# 9e. past one-shot is not a future deferral and is clean
rm -f "$scratch/systemd"/*.timer "$scratch/systemd"/*.service
printf '%s\n' '[Timer]' 'OnCalendar=2026-08-01 00:00:00' >"$scratch/systemd/past-nogate.timer"
rc=$(run_bin)
[[ "$rc" == "0" ]] || fail "past one-shot with no gate should exit 0 (got $rc)"
ok "past one-shot with no gate is ignored (not parked on a future date)"

# --- 10. heartbeat wiring contract (fleet-ops#852 / #820 class) --------------
# Production heartbeat is the only caller trusted to close. Pin the opt-in.
tier1="$repo_root/bin/fleet-heartbeat-tier1"
[[ -f "$tier1" ]] || fail "fleet-heartbeat-tier1 missing"
grep -q 'FLEET_UNJUSTIFIED_WAIT_CLOSE_ISSUES=1' "$tier1" \
  || fail "fleet-heartbeat-tier1 must set FLEET_UNJUSTIFIED_WAIT_CLOSE_ISSUES=1 (fleet-ops#852 observe-to-close opt-in)"
grep -q 'FLEET_UNJUSTIFIED_WAIT_CLOSE_ISSUES' "$bin" \
  || fail "fleet-unjustified-wait must gate close on FLEET_UNJUSTIFIED_WAIT_CLOSE_ISSUES"
ok "heartbeat wires CLOSE_ISSUES=1; detector gates on the flag"

echo "OK: fleet-unjustified-wait: clock audit, timer gates, loud fail, auto-file dedupe, repair, observe-to-close"
