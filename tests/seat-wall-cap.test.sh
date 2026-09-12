#!/usr/bin/env bash
# tests/seat-wall-cap.test.sh
#
# fleet-ops#4640: a wrapper exit code is evidence about the LANE, not a
# provider wall. This file pins the writer invariant:
#   a) no_block:rc=N -> LANE-FAULT, ledger untouched
#   b) 429 without a window uses the provider default, hard-capped at 6h
#   c) 401 -> credentials_bad 1h; corpse only after 24 consecutive
#   d) a 7d wall from rc=1 is WALL-REFUSED
#
# Hosted from tests/seat.lib.test.sh (P14). Offline scratch only.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-wall-cap.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_SEAT_HEALTH_SIDECAR="$scratch/pi-seat-health.json"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_LIB_CHECK_TRANSPORT=0
export SEAT_LOG_FILE="$scratch/watch.log"
export SEAT_DEAD_CONSECUTIVE_THRESHOLD=999999
export SEAT_LIVE_QUOTA_PROM="$scratch/no-live-quota.prom"
mkdir -p "$XDG_RUNTIME_DIR"
: >"$SEAT_LOG_FILE"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "devin": { "models": [ { "id": "glm-5-2" } ] },
    "opencode": { "models": [ { "id": "mimo-v2.5-free" } ] },
    "cline": { "models": [ { "id": "cline-pass/minimax-m3" } ] }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "providers": {
    "devin": { "cap": 4, "class": "subscription", "quota_window": "daily", "quota_bench_default_s": 900, "models": { "glm-5-2": 4 } },
    "opencode": { "cap": 1, "class": "free", "quota_bench_default_s": 900, "models": { "mimo-v2.5-free": 1 } },
    "cline": { "cap": 2, "class": "subscription", "quota_bench_default_s": 604800, "models": { "cline-pass/minimax-m3": 2 } }
  }
}
JSON

# shellcheck disable=SC1091
source "$seat_lib"

ledger_file() {
    local p="$1" m="$2"
    printf '%s/%s__%s.json' "$LEDGER" \
        "${p//[^A-Za-z0-9._-]/_}" "${m//[^A-Za-z0-9._-]/_}"
}

p="devin"; m="glm-5-2"
lf=$(ledger_file "$p" "$m")
mf="$LEDGER/${p//[^A-Za-z0-9._-]/_}__${m//[^A-Za-z0-9._-]/_}.spawn-bench.json"

# --- a) no_block:rc=1 is a LANE-FAULT, not a seat wall ---------------------
rm -f "$lf" "$mf"
: >"$SEAT_LOG_FILE"
set +e
mark_seat_spawn_fail "$p" "$m" "no_block:rc=1" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "a: mark_seat_spawn_fail no_block:rc=1 must refuse"
[[ ! -f "$lf" ]] || fail "a: ledger must be untouched after no_block:rc=1"
[[ ! -f "$mf" ]] || fail "a: spawn-bench must not be written after no_block:rc=1"
grep -q "LANE-FAULT" "$SEAT_LOG_FILE" \
    || fail "a: must log LANE-FAULT: $(cat "$SEAT_LOG_FILE")"
ok "a: no_block:rc=1 -> LANE-FAULT, ledger untouched"

# --- d) 7d wall from rc=1 is WALL-REFUSED ----------------------------------
rm -f "$lf" "$mf"
: >"$SEAT_LOG_FILE"
far=$(date -u -d "@$(( $(date -u +%s) + 604800 ))" +%Y-%m-%dT%H:%M:%SZ)
set +e
_seat_write_spawn_bench "$p" "$m" "$far" "no_block:rc=1" 604800 1 "spawn_fail" "false" "" >/dev/null 2>&1
rc=$?
set -e
# no_block is refused before the length check.
[[ "$rc" != "0" ]] || fail "d: 7d no_block write must refuse"
grep -qE "LANE-FAULT|WALL-REFUSED" "$SEAT_LOG_FILE" \
    || fail "d: must log LANE-FAULT or WALL-REFUSED: $(cat "$SEAT_LOG_FILE")"
[[ ! -f "$mf" ]] || fail "d: 7d no_block wall must not land a spawn-bench marker"
ok "d: 7d wall from rc=1 is refused"

# Same length, non-no_block reason, empty source -> WALL-REFUSED.
rm -f "$lf" "$mf"
: >"$SEAT_LOG_FILE"
set +e
_seat_write_spawn_bench "$p" "$m" "$far" "test:seven-day" 604800 1 "spawn_fail" "false" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "d2: 7d wall without justified source must refuse"
grep -q "WALL-REFUSED" "$SEAT_LOG_FILE" \
    || fail "d2: must log WALL-REFUSED: $(cat "$SEAT_LOG_FILE")"
[[ ! -f "$mf" ]] || fail "d2: refused 7d wall must not write a marker"
ok "d2: 7d wall without money/quota source is WALL-REFUSED"

# --- b) 429 without a window uses the provider default, capped at 6h -------
p="opencode"; m="mimo-v2.5-free"
lf=$(ledger_file "$p" "$m")
rm -f "$lf"
mark_seat_quota_bench "$p" "$m" "HTTP 429 rate limit exceeded" >/dev/null 2>&1 \
    || fail "b: mark_seat_quota_bench 429 without window failed"
bench=$(jq -r '.bench_until // empty' "$lf")
[[ -n "$bench" ]] || fail "b: quota bench must set bench_until"
now_s=$(date -u +%s)
be=$(date -u -d "$bench" +%s)
remain=$(( be - now_s ))
(( remain > 0 && remain <= 21600 )) \
    || fail "b: 429 default wall ${remain}s must be >0 and <=6h"
ok "b: 429 without window benches the provider default, <=6h (remain=${remain}s)"

# --- b2) a pin longer than 6h still wins (ClinePass weekly, no quota_window)
p="cline"; m="cline-pass/minimax-m3"
lf=$(ledger_file "$p" "$m")
rm -f "$lf"
mark_seat_quota_bench "$p" "$m" "INFERENCE_CAP_ERROR: weekly Clinepass limit." >/dev/null 2>&1 \
    || fail "b2: cline quota_bench_default_s write failed"
bw=$(jq -r '.bench_window_s' "$lf")
# fleet-ops#5285 (2026-09-11): the weekly pin is a static default, i.e. a guess,
# not an advertised reset — the writer caps it at 900s so the bench-truth PONG
# re-checks the seat at 15 min (a real weekly 402 fails the probe and stays).
# Parsed windows, live quota resets, money walls and ceiling parks keep theirs.
[[ "$bw" == "900" ]] || fail "b2: cline bench_window_s expected 900 (static weekly default capped by the bench-truth contract, fleet-ops#5285), got $bw"
ok "b2: cline weekly static default is capped at 900 for the bench-truth probe (fleet-ops#5285)"

# --- c) 401 -> 1h credentials_bad; corpse only after 24 --------------------
p="devin"; m="glm-5-2"
lf=$(ledger_file "$p" "$m")
rm -f "$lf"
mark_seat_credentials_bad "$p" "$m" "HTTP 401 unauthorized" >/dev/null 2>&1 \
    || fail "c: mark_seat_credentials_bad failed"
hc=$(jq -r '.health_class' "$lf")
[[ "$hc" == "credentials_bad" ]] || fail "c: health_class=$hc, want credentials_bad"
dead=$(jq -r '.seat_dead' "$lf")
[[ "$dead" == "false" ]] || fail "c: first 401 must not corpse, seat_dead=$dead"
st=$(jq -r '.http_status' "$lf")
[[ "$st" == "401" ]] || fail "c: http_status=$st, want 401"
usable=$(jq -r '.usable_at' "$lf")
ue=$(date -u -d "$usable" +%s)
remain=$(( ue - $(date -u +%s) ))
(( remain >= 3600 - 30 && remain <= 3600 + 30 )) \
    || fail "c: 401 bench remain=${remain}s, want ~3600"
ok "c: first 401 -> credentials_bad 1h, not a corpse"

rm -f "$lf"
for i in $(seq 1 23); do
    mark_seat_credentials_bad "$p" "$m" "HTTP 401 unauthorized" >/dev/null 2>&1 \
        || fail "c24: 401 #$i failed"
done
dead=$(jq -r '.seat_dead' "$lf")
[[ "$dead" == "false" ]] || fail "c24: 23rd 401 must not corpse, seat_dead=$dead"
mark_seat_credentials_bad "$p" "$m" "HTTP 401 unauthorized" >/dev/null 2>&1 \
    || fail "c24: 24th 401 failed"
dead=$(jq -r '.seat_dead' "$lf")
c=$(jq -r '.consecutive_failure_count' "$lf")
[[ "$dead" == "true" ]] || fail "c24: 24th 401 must corpse, seat_dead=$dead count=$c"
[[ "$c" == "24" ]] || fail "c24: count=$c, want 24"
ok "c24: corpse only after 24 consecutive 401s"

echo "ALL OK: seat wall cap (fleet-ops#4640 LANE-FAULT / 6h clamp / 401 1h/24)"
