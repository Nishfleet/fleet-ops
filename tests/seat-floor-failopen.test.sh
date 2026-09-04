#!/usr/bin/env bash
# tests/seat-floor-failopen.test.sh
#
# fleet-ops#3324: when pick_seat's usable capable set is empty but at least
# one benched seat is a recoverable class (transient_fault, rate_limited,
# empty_run, overload_bench, hang_bench), fail-open the shortest remaining
# bench instead of stalling with NO USABLE SEAT. A money wall (402 /
# quota_exhausted / quota_bench / corpse / credentials_bad) is never
# fail-opened.
#
# Replay drill, fully offline: scratch models.json + seat-caps.json + ledger.
# Hosted from tests/seat-lib.test.sh (already listed in ci.yml) so the P14
# test-listing gate stays green without a workflow edit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"
rules="$repo_root/config/fleet_rules.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
[[ -f "$rules" ]] || fail "fleet_rules.yml not found: $rules"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-floor-failopen.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0
export PI_SEAT_CREDENTIAL_PRECHECK=0
export SEAT_FLOOR_FAILOPEN_PROM="$scratch/fleet-seat-floor-failopen.prom"

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "commandcode": {
      "models": [
        { "id": "minimax-m3-free", "cost": { "input": 0 } },
        { "id": "deepseek-v4-flash", "cost": { "input": 0 } }
      ]
    },
    "cline": {
      "models": [
        { "id": "cline-pass/minimax-m3", "cost": { "input": 0 } }
      ]
    }
  }
}
JSON

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["commandcode"],
  "providers": {
    "commandcode": {
      "cap": 2,
      "class": "free",
      "models": { "minimax-m3-free": 1, "deepseek-v4-flash": 1 }
    },
    "cline": {
      "cap": 1,
      "class": "prepaid-quota",
      "models": { "cline-pass/minimax-m3": 1 }
    }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export HOME="$scratch/home"
mkdir -p "$HOME"

fresh_obs=$(date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
now_s=$(date -u +%s)
short_bu=$(date -u -d "@$((now_s + 90))" +%Y-%m-%dT%H:%M:%SZ)
long_bu=$(date -u -d "@$((now_s + 3600))" +%Y-%m-%dT%H:%M:%SZ)

pick() {
    # Caller must export PI_PACKET_STATE before invoking: command
    # substitution runs this in a subshell, so an export here would not
    # reach the parent's grep of watch.log.
    mkdir -p "$PI_PACKET_STATE" "$scratch/ledger"
    export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
    : >"$PI_PACKET_STATE/watch.log"
    bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib"
}

reset_ledger() {
    rm -rf "$scratch/ledger"
    mkdir -p "$scratch/ledger"
}

# --- 1. overload_bench (only seat) fail-opens, logs the floor line, bumps the counter
reset_ledger
jq -n --arg obs "$fresh_obs" --arg bu "$short_bu" \
  '{health_class:"overload_bench",seat_dead:false,observed_at:$obs,bench_until:$bu,failure_mode:"overload_503"}' \
  > "$scratch/ledger/commandcode__minimax-m3-free.json"
jq -n --arg obs "$fresh_obs" --arg bu "$long_bu" \
  '{health_class:"overload_bench",seat_dead:false,observed_at:$obs,bench_until:$bu,failure_mode:"overload_503"}' \
  > "$scratch/ledger/commandcode__deepseek-v4-flash.json"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"quota_exhausted",http_status:402,seat_dead:false,observed_at:$obs,usable_at:"2099-01-01T00:00:00Z"}' \
  > "$scratch/ledger/cline__cline-pass_minimax-m3.json"

export PI_PACKET_STATE="$scratch/state-shortest"
set +e
out=$(pick 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "shortest: expected rc=0 (floor fail-open), got rc=$rc out='$out'"
[[ "$out" == $'commandcode\tminimax-m3-free' ]] \
  || fail "shortest: expected the 90s overload bench, got '$out'"
grep -q "seat-floor: fail-open commandcode/minimax-m3-free (bench had " "$PI_PACKET_STATE/watch.log" \
  || fail "shortest: must log 'seat-floor: fail-open <seat> (bench had <n>s left)'; log: $(cat "$PI_PACKET_STATE/watch.log")"
grep -q "NO USABLE SEAT" "$PI_PACKET_STATE/watch.log" \
  && fail "shortest: must NOT stall with NO USABLE SEAT after a recoverable bench"
[[ -f "$SEAT_FLOOR_FAILOPEN_PROM" ]] \
  || fail "shortest: counter file must be written at $SEAT_FLOOR_FAILOPEN_PROM"
cur=$(awk '/^fleet_seat_floor_failopen_total / {print $2; exit}' "$SEAT_FLOOR_FAILOPEN_PROM")
[[ "$cur" == "1" ]] || fail "shortest: counter expected 1, got '$cur'"
ok "shortest remaining recoverable bench is fail-opened; money wall ignored; counter=1"

# --- 2. money wall only (quota_exhausted) still stalls
reset_ledger
rm -f "$SEAT_FLOOR_FAILOPEN_PROM"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"quota_exhausted",http_status:402,seat_dead:false,observed_at:$obs,usable_at:"2099-01-01T00:00:00Z"}' \
  > "$scratch/ledger/commandcode__minimax-m3-free.json"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"quota_exhausted",http_status:402,seat_dead:false,observed_at:$obs,usable_at:"2099-01-01T00:00:00Z"}' \
  > "$scratch/ledger/commandcode__deepseek-v4-flash.json"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"quota_exhausted",http_status:402,seat_dead:false,observed_at:$obs,usable_at:"2099-01-01T00:00:00Z"}' \
  > "$scratch/ledger/cline__cline-pass_minimax-m3.json"

export PI_PACKET_STATE="$scratch/state-money"
set +e
out=$(pick 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "money: expected rc=1 (never fail-open a 402), got rc=$rc out='$out'"
[[ -z "$out" ]] || fail "money: stdout must be empty, got '$out'"
grep -q "NO USABLE SEAT" "$PI_PACKET_STATE/watch.log" \
  || fail "money: must log NO USABLE SEAT"
grep -q "seat-floor: fail-open" "$PI_PACKET_STATE/watch.log" \
  && fail "money: must NOT log seat-floor fail-open for a 402 wall"
[[ -f "$SEAT_FLOOR_FAILOPEN_PROM" ]] \
  && fail "money: counter must not increment on a money-wall stall"
ok "quota_exhausted money wall still stalls; counter stays flat"

# --- 3. quota_bench (weekly cap) still stalls
reset_ledger
jq -n --arg obs "$fresh_obs" --arg bu "$short_bu" \
  '{health_class:"quota_bench",seat_dead:false,observed_at:$obs,bench_until:$bu,failure_mode:"quota_cap"}' \
  > "$scratch/ledger/commandcode__minimax-m3-free.json"
jq -n --arg obs "$fresh_obs" --arg bu "$short_bu" \
  '{health_class:"quota_bench",seat_dead:false,observed_at:$obs,bench_until:$bu,failure_mode:"quota_cap"}' \
  > "$scratch/ledger/commandcode__deepseek-v4-flash.json"
jq -n --arg obs "$fresh_obs" --arg bu "$short_bu" \
  '{health_class:"quota_bench",seat_dead:false,observed_at:$obs,bench_until:$bu,failure_mode:"quota_cap"}' \
  > "$scratch/ledger/cline__cline-pass_minimax-m3.json"

export PI_PACKET_STATE="$scratch/state-qbench"
set +e
out=$(pick 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "qbench: expected rc=1 (quota_bench is a money wall), got rc=$rc out='$out'"
grep -q "seat-floor: fail-open" "$PI_PACKET_STATE/watch.log" \
  && fail "qbench: must NOT fail-open a quota_bench"
ok "quota_bench weekly cap still stalls"

# --- 4. corpse / credentials_bad still stalls
reset_ledger
jq -n --arg obs "$fresh_obs" \
  '{health_class:"corpse",seat_dead:true,observed_at:$obs,failure_mode:"credentials_bad"}' \
  > "$scratch/ledger/commandcode__minimax-m3-free.json"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"credentials_bad",seat_dead:false,observed_at:$obs}' \
  > "$scratch/ledger/commandcode__deepseek-v4-flash.json"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"corpse",seat_dead:true,observed_at:$obs}' \
  > "$scratch/ledger/cline__cline-pass_minimax-m3.json"

export PI_PACKET_STATE="$scratch/state-corpse"
set +e
out=$(pick 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "corpse: expected rc=1, got rc=$rc out='$out'"
grep -q "seat-floor: fail-open" "$PI_PACKET_STATE/watch.log" \
  && fail "corpse: must NEVER fail-open a corpse / credentials_bad seat"
ok "corpse and credentials_bad still stall"

# --- 5. rate_limited fail-opens
reset_ledger
jq -n --arg obs "$fresh_obs" --arg use "$short_bu" \
  '{health_class:"rate_limited",seat_dead:false,observed_at:$obs,usable_at:$use}' \
  > "$scratch/ledger/commandcode__minimax-m3-free.json"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"quota_exhausted",http_status:402,seat_dead:false,observed_at:$obs,usable_at:"2099-01-01T00:00:00Z"}' \
  > "$scratch/ledger/commandcode__deepseek-v4-flash.json"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"quota_exhausted",http_status:402,seat_dead:false,observed_at:$obs,usable_at:"2099-01-01T00:00:00Z"}' \
  > "$scratch/ledger/cline__cline-pass_minimax-m3.json"

export PI_PACKET_STATE="$scratch/state-rl"
set +e
out=$(pick 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "rate_limited: expected rc=0, got rc=$rc out='$out'"
[[ "$out" == $'commandcode\tminimax-m3-free' ]] \
  || fail "rate_limited: expected commandcode/minimax-m3-free, got '$out'"
grep -q "seat-floor: fail-open commandcode/minimax-m3-free" "$PI_PACKET_STATE/watch.log" \
  || fail "rate_limited: must log seat-floor fail-open"
ok "rate_limited fail-opens"

# --- 6. empty_run (failure_mode on transient_fault) fail-opens
reset_ledger
jq -n --arg obs "$fresh_obs" --arg use "$short_bu" \
  '{health_class:"transient_fault",seat_dead:false,observed_at:$obs,usable_at:$use,failure_mode:"empty_run"}' \
  > "$scratch/ledger/commandcode__minimax-m3-free.json"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"quota_exhausted",http_status:402,seat_dead:false,observed_at:$obs,usable_at:"2099-01-01T00:00:00Z"}' \
  > "$scratch/ledger/commandcode__deepseek-v4-flash.json"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"quota_exhausted",http_status:402,seat_dead:false,observed_at:$obs,usable_at:"2099-01-01T00:00:00Z"}' \
  > "$scratch/ledger/cline__cline-pass_minimax-m3.json"

export PI_PACKET_STATE="$scratch/state-empty"
set +e
out=$(pick 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "empty_run: expected rc=0, got rc=$rc out='$out'"
[[ "$out" == $'commandcode\tminimax-m3-free' ]] \
  || fail "empty_run: expected commandcode/minimax-m3-free, got '$out'"
ok "empty_run (failure_mode on transient_fault) fail-opens"

# --- 7. hang_bench fail-opens
reset_ledger
jq -n --arg obs "$fresh_obs" --arg bu "$short_bu" \
  '{health_class:"hang_bench",seat_dead:false,observed_at:$obs,bench_until:$bu,failure_mode:"hang_no_response"}' \
  > "$scratch/ledger/commandcode__minimax-m3-free.json"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"quota_exhausted",http_status:402,seat_dead:false,observed_at:$obs,usable_at:"2099-01-01T00:00:00Z"}' \
  > "$scratch/ledger/commandcode__deepseek-v4-flash.json"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"quota_exhausted",http_status:402,seat_dead:false,observed_at:$obs,usable_at:"2099-01-01T00:00:00Z"}' \
  > "$scratch/ledger/cline__cline-pass_minimax-m3.json"

export PI_PACKET_STATE="$scratch/state-hang"
set +e
out=$(pick 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "hang_bench: expected rc=0, got rc=$rc out='$out'"
[[ "$out" == $'commandcode\tminimax-m3-free' ]] \
  || fail "hang_bench: expected commandcode/minimax-m3-free, got '$out'"
ok "hang_bench fail-opens"

# --- 8. private privacy never fail-opens a free-class seat
reset_ledger
jq -n --arg obs "$fresh_obs" --arg bu "$short_bu" \
  '{health_class:"overload_bench",seat_dead:false,observed_at:$obs,bench_until:$bu}' \
  > "$scratch/ledger/commandcode__minimax-m3-free.json"
jq -n --arg obs "$fresh_obs" --arg bu "$short_bu" \
  '{health_class:"overload_bench",seat_dead:false,observed_at:$obs,bench_until:$bu}' \
  > "$scratch/ledger/commandcode__deepseek-v4-flash.json"
jq -n --arg obs "$fresh_obs" \
  '{health_class:"quota_exhausted",http_status:402,seat_dead:false,observed_at:$obs,usable_at:"2099-01-01T00:00:00Z"}' \
  > "$scratch/ledger/cline__cline-pass_minimax-m3.json"

mkdir -p "$scratch/state-priv"
export PI_PACKET_STATE="$scratch/state-priv"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
: >"$PI_PACKET_STATE/watch.log"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "" light private' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "private: expected rc=1 (free-class floor blocked), got rc=$rc out='$out'"
grep -q "seat-floor: fail-open commandcode/" "$PI_PACKET_STATE/watch.log" \
  && fail "private: must not fail-open a free-class seat"
grep -q "NO USABLE SEAT" "$PI_PACKET_STATE/watch.log" \
  || fail "private: must stall (privacy line)"
ok "private-repo target never fail-opens a free-class bench"

# --- 9. alert rule is in fleet_rules.yml, warning (am-executor), not page
grep -q "alert: FleetSeatFloorFailopen" "$rules" \
  || fail "fleet_rules.yml missing FleetSeatFloorFailopen (fleet-ops#3324)"
grep -q "increase(fleet_seat_floor_failopen_total\\[5m\\]) > 0" "$rules" \
  || fail "FleetSeatFloorFailopen must trip on increase(fleet_seat_floor_failopen_total[5m]) > 0"
python3 - "$rules" <<'PY' || fail "FleetSeatFloorFailopen labels/for: must be warning + 30m"
import sys, re
text = open(sys.argv[1]).read()
m = re.search(r"- alert: FleetSeatFloorFailopen\n(.*?)(?:\n      - alert:|\n  - name:)", text, re.S)
if not m:
    print("FAIL: could not slice FleetSeatFloorFailopen block", file=sys.stderr)
    sys.exit(1)
block = m.group(1)
if "for: 30m" not in block:
    print("FAIL: missing for: 30m", file=sys.stderr); sys.exit(1)
if "severity: warning" not in block:
    print("FAIL: must be severity: warning (am-executor, not Nish)", file=sys.stderr); sys.exit(1)
if "severity: page" in block:
    print("FAIL: must not page Nish", file=sys.stderr); sys.exit(1)
print("OK: FleetSeatFloorFailopen is warning/30m")
PY
ok "FleetSeatFloorFailopen alert: increase() over 5m, for 30m, severity=warning"

echo "OK: seat-floor fail-open replay drill (fleet-ops#3324)"
