#!/usr/bin/env bash
# tests/seat-health-overload-bench.test.sh
#
# fleet-ops#5430: a sustained upstream 503 outage with a compliant
# Retry-After: 30 re-anchored usable_at = observed + 30s on EVERY failure,
# so the heartbeat failed-requeue tick kept re-picking the same walled seat
# every ~30s (blind-audit-cap-fix died twice in 4 minutes). The provider's
# short Retry-After must stop being honored once the failure is REPEATED:
# after 3+ consecutive overload failures the bench is floored at the
# overload_bench default (>= 300s, fleet-ops#652). Single-shot 503 still
# honors Retry-After.
#
# Closure condition for the out-of-repo extension at
# ~/.pi/agent/extensions/seat-health.ts (or FLEET_SEAT_HEALTH_TS); same
# import-the-live-extension shape as tests/seat-health-quarantine.test.sh.
#
# Invariants:
#   OB1  a single-shot (c<3) 503 with Retry-After: 30 still walls 30s.
#   OB2  at c=3 the bench jumps to the overload default (>= 300s), not +30s.
#   OB3  c=4, c=5 stay >= 300s (the wall does not re-shrink on each requeue).
#   OB4  a LONGER Retry-After (> default) is kept — floor, never a cap.
#   OB5  the overload corpse path already exists: shouldMarkSeatDead('overload')
#        converges at the seat_dead_consecutive_threshold (25 default).

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
skip() { echo "SKIP: $*"; exit 0; }

EXT_PATH="${FLEET_SEAT_HEALTH_TS:-$HOME/.pi/agent/extensions/seat-health.ts}"
if [[ ! -f "$EXT_PATH" ]]; then
    skip "seat-health.ts not installed at $EXT_PATH — install the extension to run this gate (fleet-ops#5430)"
fi

NODE_BIN="${FLEET_SEAT_HEALTH_NODE:-node}"
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    fail "node missing ($NODE_BIN); need >= 22.6 for --experimental-strip-types"
fi

node_major=$("$NODE_BIN" -e 'console.log(Number.parseInt(process.versions.node.split(".")[0], 10))')
node_minor=$("$NODE_BIN" -e 'console.log(Number.parseInt(process.versions.node.split(".")[1], 10))')
if [[ "$node_major" -lt 22 ]] || { [[ "$node_major" -eq 22 ]] && [[ "$node_minor" -lt 6 ]]; }; then
    fail "node $node_major.$node_minor is too old; need >= 22.6 for --experimental-strip-types (fleet-ops#5430)"
fi

# Compute the wall-seconds computeUsableAt gives one (mode, retryAfter, count)
# triple and compare against a bash-side predicate ($5: exact seconds or a
# ">=N" / "<=N" floor at least / at most comparison).
# $1 = invariant name, $2 = mode, $3 = retry-after, $4 = count, $5 = expectation
wall_check() {
    local name="$1" mode="$2" retry="$3" count="$4" want="$5"
    local last
    last=$("$NODE_BIN" \
        --experimental-strip-types --no-warnings=ExperimentalWarning \
        --input-type=module -e "
import { computeUsableAt } from ${EXT_PATH@Q};
const now = Date.now();
const usable = computeUsableAt(${mode@Q}, ${retry}, now, ${count});
const seconds = usable === null ? null : Math.round((Date.parse(usable) - now) / 1000);
console.log('RESULT_JSON:' + JSON.stringify({ seconds, usable }));
" 2>&1 | tail -n1)
    if [[ "$last" != RESULT_JSON:* ]]; then
        fail "${name}: node output did not contain a RESULT_JSON line (got: $last)"
    fi
    local payload="${last#RESULT_JSON:}"
    local got
    got=$(node -e "const p = JSON.parse(process.argv[1]); console.log(p.seconds === null ? 'null' : String(p.seconds))" "$payload" 2>/dev/null || echo "?")
    if [[ "$want" == ">="* ]]; then
        if [[ ! "$got" =~ ^[0-9]+$ ]] || (( got < ${want#>=} )); then
            fail "${name}: wall-seconds ${got}, expected >= ${want#>=} (usable=${payload})"
        fi
    elif [[ "$got" != "$want" ]]; then
        fail "${name}: wall-seconds ${got}, expected ${want} (usable=${payload})"
    fi
    ok "${name} (got=${got}, want=${want})"
}

# --- OB1: single-shot overload still honors Retry-After --------------------
wall_check "OB1: overload c=0 with Retry-After 30 walls exactly 30s" "overload" "30" "0" "30"
wall_check "OB1b: overload c=2 (below the cap) still walls exactly 30s" "overload" "30" "2" "30"

# --- OB2/OB3: repeated failure floors at the overload bench default --------
wall_check "OB2: overload c=3 with Retry-After 30 floors at >= 300s" "overload" "30" "3" ">=300"
wall_check "OB3a: overload c=4 stays >= 300s" "overload" "30" "4" ">=300"
wall_check "OB3b: overload c=10 stays >= 300s" "overload" "30" "5" ">=300"

# --- OB4: a longer Retry-After is a floor, never a cap ----------------------
wall_check "OB4: overload c=3 keeps a longer Retry-After (900s)" "overload" "900" "3" ">=900"

# --- OB5: overload converges to a corpse at the dead threshold -------------
last=$("$NODE_BIN" \
    --experimental-strip-types --no-warnings=ExperimentalWarning \
    --input-type=module -e "
import { shouldMarkSeatDead } from ${EXT_PATH@Q};
console.log('RESULT_JSON:' + JSON.stringify({
    c24: shouldMarkSeatDead('overload', 24, Date.now()),
    c25: shouldMarkSeatDead('overload', 25, Date.now()),
}));
" 2>&1 | tail -n1)
if [[ "$last" != RESULT_JSON:* ]]; then
    fail "OB5: node output did not contain a RESULT_JSON line (got: $last)"
fi
dead_c24=$(node -e "console.log(JSON.parse('${last#RESULT_JSON:}').c24)")
dead_c25=$(node -e "console.log(JSON.parse('${last#RESULT_JSON:}').c25)")
if [[ "$dead_c24" != "false" || "$dead_c25" != "true" ]]; then
    fail "OB5: overload corpse convergence wrong (c24=${dead_c24}, c25=${dead_c25}); expected dead at the default threshold 25"
fi
ok "OB5: overload converges to seat_dead at threshold 25 (c24=${dead_c24}, c25=${dead_c25})"

echo "ALL OK: seat-health overload Retry-After cap (fleet-ops#5430)"
