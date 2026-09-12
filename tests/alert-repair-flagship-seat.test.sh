#!/usr/bin/env bash
# tests/alert-repair-flagship-seat.test.sh
#
# fleet-ops#5785: an alert carrying label repair_seat=flagship (the new
# FleetProductionStale) must route to the senior_seats_in_order ladder from
# seat-caps.json FIRST — not the cheapest-healthy _pick_seat path. The live
# class: ProductDeployStalled dispatched cheap seats for ~2.5 days while
# 0509 production stayed broken; none of them fixed it.
#
# Proven hermetically (ALERT_REPAIR_NO_SPAWN=1, no live 9090/systemd):
#   1. A flagship alert picks the FIRST usable senior seat even when a
#      cheaper healthy seat would be picked by the normal path.
#   2. A walled senior seat is skipped for the NEXT senior seat.
#   3. All seniors walled -> loud FLAGSHIP-DEGRADED fallback to the normal
#      pick (a cheap repair attempt beats none — but never silent).
#   4. A NON-flagship alert never touches the senior ladder.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
dispatch_bin="$repo_root/libexec/alert-repair-dispatch"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$dispatch_bin" ]] || fail "not executable: $dispatch_bin"
python3 -m py_compile "$dispatch_bin" || fail "py_compile failed"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/seats" "$scratch/packets"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FUTURE=$(date -u -d "+1 hour" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

# seat-caps with an explicit senior ladder: devin/glm-5-2 first, then
# minimax/MiniMax-M3. The providers map must allowlist every seat the test
# uses (fleet-ops#3661 phantom-seat rejection) — including bai, the cheap
# healthy recorded seat the NORMAL path prefers.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "senior_seats_in_order": ["devin/glm-5-2", "minimax/MiniMax-M3"],
  "providers": {
    "bai":        { "cap": 4, "models": { "deepseek-v4-flash": 2 } },
    "devin":      { "cap": 4, "models": { "glm-5-2": 3 } },
    "minimax":    { "cap": 2, "models": { "MiniMax-M3": 2 } }
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

# The recorded seat is a CHEAP healthy seat — the normal _pick_seat path
# would take it. The flagship path must ignore it while a senior is usable.
cat >"$scratch/pi-seat-health.json" <<EOF
{"provider":"bai","model":"deepseek-v4-flash","health_class":"healthy","observed_at":"$NOW"}
EOF
cat >"$scratch/seats/bai__deepseek-v4-flash.json" <<EOF
{"provider":"bai","model":"deepseek-v4-flash","health_class":"healthy","observed_at":"$NOW","usable_at":null}
EOF

run_dispatch() { # $1=alertname $2=repair_seat-label-value-or-empty
    local env_args=(
        "ALERT_REPAIR_PACKET_DIR=$scratch/packets"
        "CLASS_PARK_DIR=$scratch/park"
        "SEAT_HEALTH_FILE=$scratch/pi-seat-health.json"
        "SEAT_LEDGER_DIR=$scratch/seats"
        "SEAT_CAPS_JSON=$scratch/seat-caps.json"
        "ALERT_REPAIR_CLAIM_BIN=/nonexistent"
        "ALERT_REPAIR_NO_SPAWN=1"
        "AMX_STATUS=firing"
        "AMX_RECEIVER=repair-dispatch"
        "AMX_LABEL_service=fleet"
        "AMX_ALERT_1_LABEL_alertname=$1"
        "AMX_ALERT_1_LABEL_repo=0509"
        "AMX_ALERT_1_STATUS=firing"
        "AMX_ALERT_1_START=$NOW"
        "AMX_ALERT_1_END=0"
    )
    [ -n "$2" ] && env_args+=("AMX_ALERT_1_LABEL_repair_seat=$2")
    env "${env_args[@]}" "$dispatch_bin" 2>&1
}

# --- 1. flagship alert -> first usable senior seat, not the cheap pick ----
cat >"$scratch/seats/devin__glm-5-2.json" <<EOF
{"provider":"devin","model":"glm-5-2","health_class":"healthy","observed_at":"$NOW","usable_at":null}
EOF
cat >"$scratch/seats/minimax__MiniMax-M3.json" <<EOF
{"provider":"minimax","model":"MiniMax-M3","health_class":"healthy","observed_at":"$NOW","usable_at":null}
EOF
out=$(run_dispatch FleetProductionStale flagship)
grep -q 'seat=devin/glm-5-2 reason=flagship' <<<"$out" \
    || fail "flagship alert must pick the first senior seat, got: $out"
grep -q 'seat=bai/' <<<"$out" \
    && fail "flagship path must NOT take the cheap healthy seat while a senior is usable: $out"
ok "repair_seat=flagship -> first senior seat (devin/glm-5-2), cheap seat untouched"

# --- 2. first senior walled -> NEXT senior seat ----------------------------
cat >"$scratch/seats/devin__glm-5-2.json" <<EOF
{"provider":"devin","model":"glm-5-2","health_class":"rate_limited","observed_at":"$NOW","usable_at":"$FUTURE","consecutive_failure_count":20}
EOF
out=$(run_dispatch FleetProductionStale flagship)
grep -q 'seat=minimax/MiniMax-M3 reason=flagship' <<<"$out" \
    || fail "walled first senior must fall to the next senior, got: $out"
ok "walled senior skipped -> next senior (minimax/MiniMax-M3)"

# --- 3. all seniors walled -> loud degraded fallback -----------------------
cat >"$scratch/seats/minimax__MiniMax-M3.json" <<EOF
{"provider":"minimax","model":"MiniMax-M3","health_class":"quota_exhausted","observed_at":"$NOW","usable_at":"$FUTURE"}
EOF
out=$(run_dispatch FleetProductionStale flagship)
grep -q 'FLAGSHIP-DEGRADED' <<<"$out" \
    || fail "all seniors walled must log FLAGSHIP-DEGRADED, got: $out"
grep -q 'seat=bai/deepseek-v4-flash reason=flagship-degraded' <<<"$out" \
    || fail "degraded flagship must fall back to the normal pick, got: $out"
ok "all seniors walled -> FLAGSHIP-DEGRADED + normal pick (loud, not silent)"

# --- 4. non-flagship alert -> normal cheapest-healthy path ------------------
rm -f "$scratch/seats/devin__glm-5-2.json" "$scratch/seats/minimax__MiniMax-M3.json"
cat >"$scratch/seats/devin__glm-5-2.json" <<EOF
{"provider":"devin","model":"glm-5-2","health_class":"healthy","observed_at":"$NOW","usable_at":null}
EOF
out=$(run_dispatch ProductDeployStalled "")
grep -q 'seat=bai/deepseek-v4-flash' <<<"$out" \
    || fail "non-flagship alert must use the normal pick (recorded healthy seat), got: $out"
grep -q 'reason=flagship' <<<"$out" \
    && fail "non-flagship alert must never route flagship: $out"
ok "non-flagship alert -> normal seat selection, senior ladder untouched"

echo
echo "all alert-repair-flagship-seat tests passed"
