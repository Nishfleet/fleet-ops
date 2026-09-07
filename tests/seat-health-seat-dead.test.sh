#!/usr/bin/env bash
# tests/seat-health-seat-dead.test.sh
#
# fleet-ops#2145: a seat that has failed past a threshold is a CORPSE
# (seat_dead=true), not a walled seat — so the router (seat_usable) and the
# census stop counting it as temporarily walled capacity. The 2026-08-30
# snapshot had opencode/muse-spark-1.2-contributor-free at 149 consecutive
# 500s (transient_http) and minimax/MiniMax-M3 at 69 consecutive 402s
# (quota_exhausted, usable_at +60m re-probed hourly). The 1422 quarantine
# (PR #2157) added the exponential usable_at wall but deliberately did NOT
# set seat_dead=true; 2145 is the remaining half: mark corpses dead, with a
# recovery path so it is never a permanent bench.
#
# This test is the closure condition for the out-of-repo extension at
# ~/.pi/agent/extensions/seat-health.ts (or FLEET_SEAT_HEALTH_TS). It imports
# the live extension, runs the seat_dead invariants from the issue's test
# plan, and asserts the results. Today (before the fix) writeSeatLedgerEntry
# never sets seat_dead=true for transient/quota modes; after the fix it does.
#
# Invariants:
#   D1  shouldMarkSeatDead(transient_http, c=24) = false (below threshold 25)
#   D2  shouldMarkSeatDead(transient_http, c=25) = true  (at threshold)
#   D3  shouldMarkSeatDead(transient_http, c=149) = true (live muse-spark)
#   D4  shouldMarkSeatDead(rate_limit, c=25) = true (transient class)
#   D5  shouldMarkSeatDead(empty_run, c=25) = true (transient class)
#   D6  shouldMarkSeatDead(quota_exhausted, c=73, age=25h) = true (402 not
#       cleared in 24h — the MiniMax-M3 corpse once it ages past 24h)
#   D7  shouldMarkSeatDead(quota_exhausted, c=73, age=23h) = false (fresh 402
#       is still a walled seat waiting for its reset window)
#   D8  shouldMarkSeatDead(none, c=100) = false (healthy never dead)
#   D9  shouldMarkSeatDead(credentials_bad, c=1) = true (401/403 already dead)
#   D10 writeSeatLedgerEntry: 25 transient_http failures -> seat_dead=true
#       AND the ledger class reclassifies to the TERMINAL "corpse" class
#       (fleet-ops#2327) — a corpse is retired, not a walled-transient seat
#       that "transient backoff keeps re-benching forever". The corpse
#       carries NO usable_at comeback clock (fleet-ops#2415): the 1422
#       quarantine wall (24h cap) is for WALLED seats that may recover,
#       never a retry schedule for a corpse — the 2026-08-30 heartbeat read
#       muse-spark at c=150 with usable_at +24h as "still on a 24h retry
#       cycle" consuming probe budget forever. A corpse's usable_at is null
#       so no reader sees a retry cycle.
#   D11 a healthy write after D10 resets seat_dead=false, count=0, and the
#       class back to "healthy" (recovery via a successful probe — never a
#       permanent bench).
#   D12 below threshold (c=24) seat_dead stays false and the class stays
#       "transient_fault" (the quarantine wall fires at 20 but the corpse
#       mark — and the reclassification — only at 25).
#   D13 quota_exhausted corpse (age 25h) also reclassifies to "corpse".
#   D14 a further failure write on the corpse (c=26) keeps seat_dead=true,
#       class corpse, and usable_at null — the cleared clock sticks.
#
# Environment seams:
#   FLEET_SEAT_HEALTH_TS    absolute path to seat-health.ts. Default:
#                           $HOME/.pi/agent/extensions/seat-health.ts
#   FLEET_SEAT_HEALTH_NODE  node binary. Default: node (must be >= 22.6
#                           for --experimental-strip-types)
#
# CI safety: if the extension is not installed, the test skips (exit 0 with
# a SKIP line). The gap is the issue, not the test; the test only makes
# sense where the extension is wired. Hosted by tests/ci-standards-audit
# (already in P14) so it runs in CI as a no-op and on the VPS as the
# real closure check.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
skip() { echo "SKIP: $*"; exit 0; }

EXT_PATH="${FLEET_SEAT_HEALTH_TS:-$HOME/.pi/agent/extensions/seat-health.ts}"
if [[ ! -f "$EXT_PATH" ]]; then
    skip "seat-health.ts not installed at $EXT_PATH — install the extension to run this gate (fleet-ops#2145)"
fi

NODE_BIN="${FLEET_SEAT_HEALTH_NODE:-node}"
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    fail "node missing ($NODE_BIN); need >= 22.6 for --experimental-strip-types"
fi

node_major=$("$NODE_BIN" -e 'console.log(Number.parseInt(process.versions.node.split(".")[0], 10))')
node_minor=$("$NODE_BIN" -e 'console.log(Number.parseInt(process.versions.node.split(".")[1], 10))')
if [[ "$node_major" -lt 22 ]] || { [[ "$node_major" -eq 22 ]] && [[ "$node_minor" -lt 6 ]]; }; then
    fail "node $node_major.$node_minor is too old; need >= 22.6 for --experimental-strip-types (fleet-ops#2145)"
fi

# Hermetic config so the thresholds are deterministic regardless of the live
# seat-caps.json. seat_dead_consecutive_threshold=25 and seat_dead_quota_age_s
# =86400 match the issue wording and the repo defaults.
scratch=$(mktemp -d -t seat-dead.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM
caps="$scratch/seat-caps.json"
cat >"$caps" <<'JSON'
{
  "walled_comeback": {
    "min_probe_interval_s": 900,
    "rate_limit_s": 900,
    "daily_quota_s": 3600,
    "monthly_quota_s": 86400,
    "free_balance_exhausted_s": 86400,
    "credentials_bad_s": 604800,
    "quarantine_threshold": 20,
    "quarantine_floor_s": 3600,
    "quarantine_cap_s": 86400,
    "seat_dead_consecutive_threshold": 25,
    "seat_dead_quota_age_s": 86400
  }
}
JSON

# Run a node --experimental-strip-types snippet under the hermetic config and
# return its last RESULT_JSON: line. $1 = the JS body.
run_node() {
    PI_SEAT_CAPS_JSON="$caps" "$NODE_BIN" \
        --experimental-strip-types --no-warnings=ExperimentalWarning \
        --input-type=module -e "$1" 2>&1 | tail -n1
}

# shouldMarkSeatDead invariant. $1=name $2=mode $3=count $4=observedAgeHours(or "")
# $5=expected ("true"|"false")
smd_invariant() {
    local name="$1" mode="$2" count="$3" age_h="$4" want="$5"
    local last
    if [[ -z "$age_h" ]]; then
        last=$(run_node "
import { shouldMarkSeatDead } from ${EXT_PATH@Q};
const now = Date.now();
const r = shouldMarkSeatDead(${mode@Q}, ${count}, now);
console.log('RESULT_JSON:' + r);
")
    else
        last=$(run_node "
import { shouldMarkSeatDead } from ${EXT_PATH@Q};
const now = Date.now();
const obs = now - ${age_h} * 3600 * 1000;
const r = shouldMarkSeatDead(${mode@Q}, ${count}, obs, now);
console.log('RESULT_JSON:' + r);
")
    fi
    if [[ "$last" != RESULT_JSON:* ]]; then
        fail "${name}: node output did not contain a RESULT_JSON line (got: $last)"
    fi
    local got="${last#RESULT_JSON:}"
    if [[ "$got" != "$want" ]]; then
        fail "${name}: got ${got}, expected ${want}"
    fi
    ok "${name} (${want})"
}

# --- D1-D5: transient-class count threshold -------------------------------
smd_invariant "D1: transient_http c=24 below threshold -> not dead" "transient_http" "24" "" "false"
smd_invariant "D2: transient_http c=25 at threshold -> dead" "transient_http" "25" "" "true"
smd_invariant "D3: transient_http c=149 (live muse-spark) -> dead" "transient_http" "149" "" "true"
smd_invariant "D4: rate_limit c=25 -> dead (transient class)" "rate_limit" "25" "" "true"
smd_invariant "D5: empty_run c=25 -> dead (transient class)" "empty_run" "25" "" "true"

# --- D6-D7: quota_exhausted time threshold --------------------------------
smd_invariant "D6: quota_exhausted c=73 age=25h -> dead (402 not cleared in 24h)" "quota_exhausted" "73" "25" "true"
smd_invariant "D7: quota_exhausted c=73 age=23h -> not dead (fresh 402 still walled)" "quota_exhausted" "73" "23" "false"

# --- D8-D9: healthy / credentials_bad -------------------------------------
smd_invariant "D8: none c=100 -> not dead (healthy)" "none" "100" "" "false"
smd_invariant "D9: credentials_bad c=1 -> dead (401/403)" "credentials_bad" "1" "" "true"

# --- D10-D12: writeSeatLedgerEntry applies seat_dead on the MERGED count --
ledger="$scratch/ledger"
mkdir -p "$ledger"
last=$(PI_SEAT_HEALTH_LEDGER_DIR="$ledger" PI_SEAT_CAPS_JSON="$caps" "$NODE_BIN" \
    --experimental-strip-types --no-warnings=ExperimentalWarning \
    --input-type=module -e "
import { readFileSync } from 'node:fs';
const { writeSeatLedgerEntry, seatLedgerPath } = await import(${EXT_PATH@Q});
const now = Date.now();
const base = { provider: 'opencode', model: 'muse-spark-1.2-contributor-free', http_status: 500, retry_after: null, health_class: 'transient_fault', retryable: true, seat_dead: false, poison_ladder: false, source: 'provider_fetch', failure_mode: 'transient_http' };
const obs = (extra) => ({ ...base, observed_at: new Date(now).toISOString(), usable_at: new Date(now + 30 * 1000).toISOString(), consecutive_failure_count: 0, ...extra });
const p = seatLedgerPath('opencode', 'muse-spark-1.2-contributor-free');
const read = () => JSON.parse(readFileSync(p, 'utf8'));
const out = [];
// 24 failures: c climbs 1..24, all below the corpse threshold (25). The
// quarantine wall fires at c=20 (1h->...->24h cap) but seat_dead stays false
// and the class stays transient_fault (the corpse mark — and the fleet-ops#2327
// terminal reclassification — only at 25).
for (let i = 0; i < 24; i++) writeSeatLedgerEntry(obs({}));
let e = read();
out.push(['c24-count', e.consecutive_failure_count, 'c24-dead', String(e.seat_dead), 'c24-class', e.health_class, 'c24-wall', Math.round((Date.parse(e.usable_at) - now) / 1000)]);
// 25th failure: c=25 -> seat_dead=true, class reclassifies to corpse, wall
// cleared (fleet-ops#2415: corpse is retired — no comeback clock).
writeSeatLedgerEntry(obs({}));
e = read();
out.push(['c25-count', e.consecutive_failure_count, 'c25-dead', String(e.seat_dead), 'c25-class', e.health_class, 'c25-usable', String(e.usable_at)]);
// 26th failure: the corpse's count climbs but seat_dead/class/usable_at do
// not regress — the cleared clock sticks (D14).
writeSeatLedgerEntry(obs({}));
e = read();
out.push(['c26-count', e.consecutive_failure_count, 'c26-dead', String(e.seat_dead), 'c26-class', e.health_class, 'c26-usable', String(e.usable_at)]);
// healthy write: count -> 0, seat_dead -> false, class -> healthy (recovery
// via a probe).
writeSeatLedgerEntry({ ...base, http_status: 200, health_class: 'healthy', failure_mode: 'none', observed_at: new Date(now + 1000).toISOString(), usable_at: null, consecutive_failure_count: 0 });
e = read();
out.push(['healthy-count', e.consecutive_failure_count, 'healthy-dead', String(e.seat_dead), 'healthy-class', e.health_class, 'healthy-usable', String(e.usable_at)]);
// D13: quota_exhausted corpse (402 observed 25h ago, count 73) also
// reclassifies to corpse — the billing wall that has not cleared is a corpse
// too, with the same terminal class.
const qp = seatLedgerPath('minimax', 'MiniMax-M3');
writeSeatLedgerEntry({ ...base, provider: 'minimax', model: 'MiniMax-M3', http_status: 402, health_class: 'quota_exhausted', failure_mode: 'quota_exhausted', observed_at: new Date(now - 25 * 3600 * 1000).toISOString(), usable_at: null, consecutive_failure_count: 73 });
const qe = JSON.parse(readFileSync(qp, 'utf8'));
out.push(['quota-count', qe.consecutive_failure_count, 'quota-dead', String(qe.seat_dead), 'quota-class', qe.health_class]);
console.log('RESULT_JSON:' + JSON.stringify(out));
" 2>&1 | tail -n1)
if [[ "$last" != RESULT_JSON:* ]]; then
    fail "D10-D12: node write-path output did not contain a RESULT_JSON line (got: $last)"
fi
payload="${last#RESULT_JSON:}"
expect() {
    local want="$1" idx="$2" label="$3"
    local got
    got=$("$NODE_BIN" -e "const p = JSON.parse(process.argv[1]); const [o,i] = '${idx}'.split(',').map(Number); console.log(String(p[o][i]))" "$payload" 2>/dev/null || echo "?")
    if [[ "$got" != "$want" ]]; then
        fail "${label}: got ${got}, expected ${want} (payload=${payload})"
    fi
    ok "${label} (${want})"
}
# c24: count=24, seat_dead=false, class=transient_fault, wall=57600 (16h quarantine step, c>=20)
expect "24" "0,1" "D12: c24-count (below corpse threshold)"
expect "false" "0,3" "D12: c24-dead (quarantine wall fires, corpse mark does not)"
expect "transient_fault" "0,5" "D12: c24-class (class unchanged below the corpse threshold)"
expect "57600" "0,7" "D12: c24-wall (16h quarantine step at c=24)"
# c25: count=25, seat_dead=true, class=corpse, usable_at=null
expect "25" "1,1" "D10: c25-count (at corpse threshold)"
expect "true" "1,3" "D10: c25-dead (corpse marked)"
expect "corpse" "1,5" "D10: c25-class (fleet-ops#2327 terminal reclassification)"
expect "null" "1,7" "D10: c25-usable (corpse carries NO retry clock — fleet-ops#2415 permanent retirement)"
# c26: count=26, seat_dead/class/usable_at unchanged (clock stays cleared)
expect "26" "2,1" "D14: c26-count (still failing past the corpse threshold)"
expect "true" "2,3" "D14: c26-dead (corpse stays dead)"
expect "corpse" "2,5" "D14: c26-class (corpse class sticks)"
expect "null" "2,7" "D14: c26-usable (cleared clock sticks — no retry cycle reappears)"
# healthy: count=0, seat_dead=false, class=healthy, usable_at=null
expect "0" "3,1" "D11: healthy-count (probe recovery resets)"
expect "false" "3,3" "D11: healthy-dead (corpse cleared on success)"
expect "healthy" "3,5" "D11: healthy-class (class rebuilt on recovery)"
expect "null" "3,7" "D11: healthy-usable (wall cleared)"
# quota corpse: seat_dead=true, class=corpse. count is merged prev+1 (fresh
# file -> 1); the 402-death path is TIME-based (age >= 24h) so the count is
# not what drives the corpse mark — the class reclassification is.
expect "1" "4,1" "D13: quota-count (first write on a fresh file)"
expect "true" "4,3" "D13: quota-dead (402 not cleared in 24h -> corpse)"
expect "corpse" "4,5" "D13: quota-class (terminal reclassification, billing wall)"

ok "fleet-ops#2145/#2327/#2415 closure: corpses (transient c>=25, quota age>=24h) are seat_dead=true, reclassify to the terminal corpse class, and carry NO usable_at retry clock (the cleared clock sticks on further failures); below-threshold and healthy behaviour unchanged; a successful probe recovers"
