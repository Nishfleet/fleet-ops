#!/usr/bin/env bash
# tests/fleet-heartbeat-failed-notify-threshold.test.sh
#
# fleet-ops#1399: the OnFailure Telegram page must only fire after N
# consecutive failures of the same unit within the configured window.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
helper="$repo_root/lib/fleet-heartbeat-failed-notify.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$helper" ]] || fail "missing helper: $helper"
python3 -m py_compile "$helper" >/dev/null 2>&1 || fail "helper does not compile"
ok "helper compiles"

scratch="$(mktemp -d -t notify-threshold.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

state="$scratch/state"
mkdir -p "$state"
hermes="$scratch/hermes"
cat >"$hermes" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$(dirname "$0")/argv"
EOF
chmod +x "$hermes"

run_helper() {
  local unit="$1"
  shift
  MONITOR_UNIT="$unit" \
  HERMES="$hermes" \
  FLEET_HEARTBEAT_FAILED_NOTIFY_THRESHOLD=3 \
  FLEET_HEARTBEAT_FAILED_NOTIFY_WINDOW=900 \
  FLEET_HEARTBEAT_FAILED_NOTIFY_STATE_DIR="$state" \
    python3 "$helper" "$@"
}

host="$(hostname -s)"
unit="fixture.service"

# --- Scenario A: 1st and 2nd failures are suppressed, 3rd pages. ------------
for i in 1 2; do
  run_helper "$unit"
  [[ ! -f "$scratch/argv" ]] || fail "failure $i should not invoke hermes"
  ok "failure $i suppressed"
done

run_helper "$unit"
[[ -f "$scratch/argv" ]] || fail "3rd consecutive failure must invoke hermes"
got="$(cat "$scratch/argv")"
[[ "$got" == *"$host"* ]] || fail "page must contain live hostname ($host); got: $got"
[[ "$got" == *"$unit"* ]] || fail "page must include MONITOR_UNIT; got: $got"
[[ "$got" != *hostinger-kvm4* ]] || fail "page still names hostinger-kvm4: $got"
[[ "$got" != *"unknown unit"* ]] || fail "page must never substitute 'unknown unit' (fleet-ops#1526); got: $got"
[[ "$got" == *"FLEET UNIT FAILED"* ]] || fail "page is not a FLEET UNIT FAILED page: $got"
ok "3rd consecutive failure pages with live host and real MONITOR_UNIT, never 'unknown unit'"

# --- Scenario B: 4th failure is suppressed (counter reset after page). ------
rm -f "$scratch/argv"
run_helper "$unit"
[[ ! -f "$scratch/argv" ]] || fail "4th failure must start a new streak, not page"
ok "4th failure starts a new streak and is suppressed"

# --- Scenario C: 2 failures, wait past the window, then 1 starts fresh. -----
state2="$scratch/state2"
mkdir -p "$state2"
run_helper2() {
  MONITOR_UNIT="$unit" \
  HERMES="$hermes" \
  FLEET_HEARTBEAT_FAILED_NOTIFY_THRESHOLD=3 \
  FLEET_HEARTBEAT_FAILED_NOTIFY_WINDOW=2 \
  FLEET_HEARTBEAT_FAILED_NOTIFY_STATE_DIR="$state2" \
    python3 "$helper"
}

run_helper2
run_helper2
sleep 3
run_helper2
[[ ! -f "$scratch/argv" ]] || fail "failure after window expiry should not page alone"
ok "window expiry resets the streak"

# --- Scenario D: threshold 1 pages immediately. -----------------------------
state3="$scratch/state3"
mkdir -p "$state3"
MONITOR_UNIT="$unit" \
HERMES="$hermes" \
FLEET_HEARTBEAT_FAILED_NOTIFY_THRESHOLD=1 \
FLEET_HEARTBEAT_FAILED_NOTIFY_WINDOW=900 \
FLEET_HEARTBEAT_FAILED_NOTIFY_STATE_DIR="$state3" \
  python3 "$helper"
[[ -f "$scratch/argv" ]] || fail "threshold 1 must page on the first failure"
ok "threshold 1 pages immediately"

# --- Scenario E: MONITOR_UNIT unset -> no page, and never an 'unknown ----
# unit' placeholder (fleet-ops#1526). When OnFailure= activates the notify
# without systemd passing the unit (or someone starts the unit by hand),
# the script must do nothing rather than page a name-less 'unknown unit'.
rm -f "$scratch/argv"
state4="$scratch/state4"
mkdir -p "$state4"
HERMES="$hermes" \
MONITOR_UNIT='' \
FLEET_HEARTBEAT_FAILED_NOTIFY_THRESHOLD=1 \
FLEET_HEARTBEAT_FAILED_NOTIFY_WINDOW=900 \
FLEET_HEARTBEAT_FAILED_NOTIFY_STATE_DIR="$state4" \
  python3 "$helper"
[[ ! -f "$scratch/argv" ]] || fail "unset MONITOR_UNIT must not invoke hermes (no 'unknown unit' page)"
[ -z "$(ls -A "$state4")" ] || fail "unset MONITOR_UNIT must not write per-unit state"
ok "MONITOR_UNIT unset -> no page, no state, never 'unknown unit'"

echo "OK: fleet-heartbeat-failed-notify threshold (#1399)"
