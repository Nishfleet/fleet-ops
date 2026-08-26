#!/usr/bin/env bash
# tests/heartbeat-watchman.test.sh
#
# fleet-ops#76: the watchman has no watchman.
#   1. Dead-man ping fires on success only, never fails the tick.
#   2. Failed units: repair first, telegram+triage only if still failed.
#   3. Seat-health: stale/unparseable triggers pi-transport-check then reports.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/heartbeat-watchman.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
chmod +x "$lib"

scratch="$(mktemp -d -t heartbeat-watchman.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

fake="$scratch/bin"
mkdir -p "$fake"
triage="$scratch/triage.md"
: >"$triage"

# --- fake curl: records URL, optional fail --------------------------------
curl_rc=0
cat >"$fake/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
# last arg is the URL
url=""
for a in "$@"; do url="$a"; done
printf '%s\n' "$url" >>"$CURL_URLS"
exit "${CURL_RC:-0}"
FAKE
chmod +x "$fake/curl"

# --- fake hermes: records argv -------------------------------------------
cat >"$fake/hermes" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERMES_LOG"
exit 0
FAKE
chmod +x "$fake/hermes"

# --- fake journalctl ------------------------------------------------------
cat >"$fake/journalctl" <<'FAKE'
#!/usr/bin/env bash
echo "journal excerpt for fake unit"
exit 0
FAKE
chmod +x "$fake/journalctl"

# --- fake systemctl -------------------------------------------------------
# State file: FAILED_UNITS one unit per line. REPAIR_OK=1 clears them on start.
cat >"$fake/systemctl" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
cmd="$1"; shift || true
case "$cmd" in
  --state=failed)
    if [[ -s "$FAILED_FILE" ]]; then
      while IFS= read -r u; do
        [ -z "$u" ] && continue
        printf '%s loaded failed failed\tfake\n' "$u"
      done <"$FAILED_FILE"
    fi
    exit 0
    ;;
  reset-failed)
    printf 'reset-failed %s\n' "${1:-}" >>"$SYSTEMCTL_LOG"
    exit 0
    ;;
  start)
    printf 'start %s\n' "${1:-}" >>"$SYSTEMCTL_LOG"
    if [[ "${REPAIR_OK:-0}" == "1" ]]; then
      : >"$FAILED_FILE"
    fi
    exit 0
    ;;
  *)
    printf 'unexpected: %s %s\n' "$cmd" "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$fake/systemctl"

export CURL="$fake/curl"
export HERMES="$fake/hermes"
export JOURNALCTL="$fake/journalctl"
export SYSTEMCTL="$fake/systemctl"
export CURL_LOG="$scratch/curl.log"
export CURL_URLS="$scratch/curl.urls"
export CURL_RC=0
export HERMES_LOG="$scratch/hermes.log"
export SYSTEMCTL_LOG="$scratch/systemctl.log"
export FAILED_FILE="$scratch/failed.units"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_SEAT_HEALTH="$scratch/seat.json"
export FLEET_SEAT_HEALTH_MAX_AGE_SEC=5400
export FLEET_SEAT_LEDGER_DIR="$scratch/seats"
export FLEET_SEAT_PER_SEAT_STALE_SEC=21600
export FLEET_SEAT_PER_SEAT_STALE_PCT=50
export PI_TRANSPORT_CHECK_UNIT="pi-transport-check.service"
mkdir -p "$FLEET_SEAT_LEDGER_DIR"

run_wm() { "$lib" "$@"; }

# ============================================================================
# 1. Dead-man ping
# ============================================================================
: >"$CURL_LOG"; : >"$CURL_URLS"
unset HC_URL || true
run_wm ping
[[ ! -s "$CURL_URLS" ]] || fail "ping must not curl when HC_URL unset"
ok "dead-man: no ping when HC_URL unset"

: >"$CURL_LOG"; : >"$CURL_URLS"
export HC_URL="https://example.test/hc-ping/fake"
run_wm ping
grep -qx "https://example.test/hc-ping/fake" "$CURL_URLS" \
  || fail "ping must curl HC_URL, got: $(cat "$CURL_URLS")"
ok "dead-man: pings HC_URL on success path"

: >"$CURL_LOG"; : >"$CURL_URLS"
export CURL_RC=1
set +e
run_wm ping
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "failed ping must still exit 0, got $rc"
ok "dead-man: ping failure does not fail the tick"
export CURL_RC=0

# ============================================================================
# 2. Failed units: repair first, page only if still failed
# ============================================================================
: >"$HERMES_LOG"; : >"$SYSTEMCTL_LOG"; : >"$triage"
: >"$FAILED_FILE"
export REPAIR_OK=0
run_wm process-failed
[[ ! -s "$HERMES_LOG" ]] || fail "no telegram when no failed units: $(cat "$HERMES_LOG")"
grep -q "UNIT-FAILED" "$triage" && fail "no triage UNIT-FAILED when none failed"
ok "failed-units: none -> no page"

: >"$HERMES_LOG"; : >"$SYSTEMCTL_LOG"; : >"$triage"
printf 'pi-issue@fleet-ops-1.service\n' >"$FAILED_FILE"
export REPAIR_OK=1
run_wm process-failed
grep -q 'reset-failed pi-issue@fleet-ops-1.service' "$SYSTEMCTL_LOG" \
  || fail "must reset-failed: $(cat "$SYSTEMCTL_LOG")"
grep -q 'start pi-issue@fleet-ops-1.service' "$SYSTEMCTL_LOG" \
  || fail "must start after reset: $(cat "$SYSTEMCTL_LOG")"
[[ ! -s "$HERMES_LOG" ]] || fail "no telegram after successful repair: $(cat "$HERMES_LOG")"
grep -q "UNIT-FAILED" "$triage" && fail "no UNIT-FAILED page after successful repair"
ok "failed-units: repair succeeds -> no telegram"

: >"$HERMES_LOG"; : >"$SYSTEMCTL_LOG"; : >"$triage"
printf 'dummy-fail.service\n' >"$FAILED_FILE"
export REPAIR_OK=0
run_wm process-failed
grep -q 'reset-failed dummy-fail.service' "$SYSTEMCTL_LOG" \
  || fail "must attempt repair before paging: $(cat "$SYSTEMCTL_LOG")"
grep -q 'start dummy-fail.service' "$SYSTEMCTL_LOG" \
  || fail "must start as the repair attempt: $(cat "$SYSTEMCTL_LOG")"
grep -q "send -t telegram --urgent" "$HERMES_LOG" \
  || fail "must hermes send --urgent after failed repair: $(cat "$HERMES_LOG")"
grep -q "dummy-fail.service" "$HERMES_LOG" \
  || fail "telegram must name the unit: $(cat "$HERMES_LOG")"
grep -q "UNIT-FAILED" "$triage" || fail "triage missing UNIT-FAILED: $(cat "$triage")"
grep -q "dummy-fail.service" "$triage" || fail "triage must name the unit"
ok "failed-units: still failed after repair -> triage + telegram --urgent"

# Heartbeat's own unit is skipped (would recurse / double-page).
: >"$HERMES_LOG"; : >"$SYSTEMCTL_LOG"; : >"$triage"
printf 'fleet-heartbeat.service\n' >"$FAILED_FILE"
export REPAIR_OK=0
run_wm process-failed
[[ ! -s "$HERMES_LOG" ]] || fail "must not page fleet-heartbeat.service itself"
ok "failed-units: skips fleet-heartbeat.service"

# ============================================================================
# 3. Seat-health freshness
# ============================================================================
python3 - "$scratch/seat.json" <<'PY'
import json, datetime
from pathlib import Path
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
Path(__import__('sys').argv[1]).write_text(json.dumps({
    "provider": "minimax", "model": "MiniMax-M3",
    "health_class": "healthy", "observed_at": now, "source": "test"
}))
PY
: >"$SYSTEMCTL_LOG"; : >"$triage"
run_wm seat-health
grep -q "start pi-transport-check.service" "$SYSTEMCTL_LOG" \
  && fail "fresh seat-health must not trigger transport-check: $(cat "$SYSTEMCTL_LOG")"
grep -q "SEAT-HEALTH" "$triage" && fail "fresh must not loud-report: $(cat "$triage")"
ok "seat-health: fresh observed_at -> no repair"

# Backdated > 90 min
python3 - "$scratch/seat.json" <<'PY'
import json, datetime
from pathlib import Path
old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=91)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
Path(__import__('sys').argv[1]).write_text(json.dumps({
    "provider": "minimax", "model": "MiniMax-M3",
    "health_class": "healthy", "observed_at": old, "source": "test"
}))
PY
: >"$SYSTEMCTL_LOG"; : >"$triage"
run_wm seat-health
grep -q "start pi-transport-check.service" "$SYSTEMCTL_LOG" \
  || fail "stale must start pi-transport-check: $(cat "$SYSTEMCTL_LOG")"
grep -q "SEAT-HEALTH" "$triage" || fail "stale must report: $(cat "$triage")"
ok "seat-health: stale observed_at -> trigger + report"

printf 'not-json\n' >"$scratch/seat.json"
: >"$SYSTEMCTL_LOG"; : >"$triage"
run_wm seat-health
grep -q "start pi-transport-check.service" "$SYSTEMCTL_LOG" \
  || fail "unparseable must start pi-transport-check"
grep -q "SEAT-HEALTH" "$triage" || fail "unparseable must report"
ok "seat-health: unparseable -> trigger + report"

rm -f "$scratch/seat.json"
: >"$SYSTEMCTL_LOG"; : >"$triage"
run_wm seat-health
grep -q "start pi-transport-check.service" "$SYSTEMCTL_LOG" \
  || fail "missing file must start pi-transport-check"
grep -q "SEAT-HEALTH" "$triage" || fail "missing file must report"
ok "seat-health: missing file -> trigger + report"

# ============================================================================
# 3b. Per-seat ledger vs summary (fleet-ops#156 finding 14)
# ============================================================================
write_ledger() {
  # $1=filename $2=age_minutes (0 = now)
  python3 - "$FLEET_SEAT_LEDGER_DIR/$1" "$2" <<'PY'
import json, datetime, sys
from pathlib import Path
path, age_min = sys.argv[1], int(sys.argv[2])
when = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=age_min)
Path(path).write_text(json.dumps({
    "provider": "x", "model": "y",
    "health_class": "healthy",
    "observed_at": when.strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
}))
PY
}

write_summary_now() {
  python3 - "$scratch/seat.json" <<'PY'
import json, datetime
from pathlib import Path
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
Path(__import__('sys').argv[1]).write_text(json.dumps({
    "provider": "minimax", "model": "MiniMax-M3",
    "health_class": "healthy", "observed_at": now, "source": "test"
}))
PY
}

# missing ledger dir -> skip, no trigger
export FLEET_SEAT_LEDGER_DIR="$scratch/no-such-seats"
write_summary_now
: >"$SYSTEMCTL_LOG"; : >"$triage"
run_wm seat-health-per-seat
grep -q "start pi-transport-check.service" "$SYSTEMCTL_LOG" \
  && fail "missing ledger dir must not trigger: $(cat "$SYSTEMCTL_LOG")"
grep -q "SEAT-HEALTH-PER-SEAT" "$triage" \
  && fail "missing ledger dir must not loud-report: $(cat "$triage")"
ok "seat-health-per-seat: missing ledger dir -> skip"

# empty ledger dir -> skip
export FLEET_SEAT_LEDGER_DIR="$scratch/seats"
rm -f "$FLEET_SEAT_LEDGER_DIR"/*.json
write_summary_now
: >"$SYSTEMCTL_LOG"; : >"$triage"
run_wm seat-health-per-seat
grep -q "start pi-transport-check.service" "$SYSTEMCTL_LOG" \
  && fail "empty ledger must not trigger: $(cat "$SYSTEMCTL_LOG")"
ok "seat-health-per-seat: empty ledger -> skip"

# summary fresh + 2/3 stale (>50%) -> trigger + loud
# 400 min = 6.6h > STALE_SECS 6h; 1 min is fresh.
write_summary_now
write_ledger "a.json" 400
write_ledger "b.json" 400
write_ledger "c.json" 1
: >"$SYSTEMCTL_LOG"; : >"$triage"
run_wm seat-health-per-seat
grep -q "start pi-transport-check.service" "$SYSTEMCTL_LOG" \
  || fail "majority-stale must start pi-transport-check: $(cat "$SYSTEMCTL_LOG")"
grep -q "SEAT-HEALTH-PER-SEAT" "$triage" \
  || fail "majority-stale must report: $(cat "$triage")"
ok "seat-health-per-seat: summary fresh + majority stale -> trigger + report"

# summary fresh + 1/3 stale (<=50%) -> no trigger
rm -f "$FLEET_SEAT_LEDGER_DIR"/*.json
write_summary_now
write_ledger "a.json" 400
write_ledger "b.json" 1
write_ledger "c.json" 1
: >"$SYSTEMCTL_LOG"; : >"$triage"
run_wm seat-health-per-seat
grep -q "start pi-transport-check.service" "$SYSTEMCTL_LOG" \
  && fail "minority-stale must not trigger: $(cat "$SYSTEMCTL_LOG")"
grep -q "SEAT-HEALTH-PER-SEAT" "$triage" \
  && fail "minority-stale must not loud-report: $(cat "$triage")"
ok "seat-health-per-seat: summary fresh + minority stale -> no alarm"

# summary stale + majority stale -> no extra alarm (summary check owns it)
rm -f "$FLEET_SEAT_LEDGER_DIR"/*.json
python3 - "$scratch/seat.json" <<'PY'
import json, datetime
from pathlib import Path
old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=91)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
Path(__import__('sys').argv[1]).write_text(json.dumps({
    "provider": "minimax", "model": "MiniMax-M3",
    "health_class": "healthy", "observed_at": old, "source": "test"
}))
PY
write_ledger "a.json" 400
write_ledger "b.json" 400
write_ledger "c.json" 400
: >"$SYSTEMCTL_LOG"; : >"$triage"
run_wm seat-health-per-seat
grep -q "start pi-transport-check.service" "$SYSTEMCTL_LOG" \
  && fail "stale summary must not extra-trigger per-seat: $(cat "$SYSTEMCTL_LOG")"
ok "seat-health-per-seat: summary already stale -> no extra alarm"

# never fails the tick
set +e
run_wm seat-health-per-seat
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "per-seat check must exit 0, got $rc"
ok "seat-health-per-seat: never fails the tick"

# ============================================================================
# 4. fleet-heartbeat wrapper: ping on exit 0, not on failure
# ============================================================================
hb="$repo_root/bin/fleet-heartbeat"
[[ -x "$hb" ]] || fail "not executable: $hb"

plan="$scratch/plan.md"
printf 'last-heartbeat: 2000-01-01T00:00:00Z (durable-timer)\n' >"$plan"
tier1_ok="$scratch/tier1-ok"
printf '#!/bin/true\n' >"$tier1_ok"
chmod +x "$tier1_ok"
tier1_fail="$scratch/tier1-fail"
printf '#!/bin/false\n' >"$tier1_fail"
chmod +x "$tier1_fail"

: >"$CURL_URLS"
export FLEET_PLAN_FILE="$plan"
export FLEET_HEARTBEAT_TIER1="$tier1_ok"
export FLEET_HEARTBEAT_WATCHMAN="$lib"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_HEARTBEAT_LOG_DIR="$scratch/hb-logs"
export HC_URL="https://example.test/hc-ping/wrapper"
set +e
out="$("$hb" 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "wrapper success should exit 0, got $rc ($out)"
grep -qx "https://example.test/hc-ping/wrapper" "$CURL_URLS" \
  || fail "wrapper success must ping, got: $(cat "$CURL_URLS") out=$out"
ok "wrapper: successful tick pings dead-man"

: >"$CURL_URLS"
export FLEET_HEARTBEAT_TIER1="$tier1_fail"
set +e
out="$("$hb" 2>&1)"
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "wrapper must not exit 0 when tier1 fails ($out)"
[[ ! -s "$CURL_URLS" ]] || fail "wrapper must not ping on failure: $(cat "$CURL_URLS")"
ok "wrapper: failed tick does not ping"

# Freshness skip is still a successful timer fire — ping so a masked timer is
# the thing healthchecks notices, not a live interactive session.
: >"$CURL_URLS"
python3 - "$plan" <<'PY'
import datetime, pathlib
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
pathlib.Path(__import__('sys').argv[1]).write_text(f"last-heartbeat: {now} (durable-timer)\n")
PY
export FLEET_HEARTBEAT_TIER1="$tier1_fail"
set +e
out="$("$hb" 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "freshness skip should exit 0, got $rc ($out)"
grep -qx "https://example.test/hc-ping/wrapper" "$CURL_URLS" \
  || fail "freshness skip must still ping: $(cat "$CURL_URLS") out=$out"
ok "wrapper: freshness skip still pings dead-man"

echo "ALL OK"
