#!/usr/bin/env bash
# tests/seat-health-quarantine.test.sh
#
# fleet-ops#1422: quarantine seats with runaway consecutive_failure_count.
# The 2026-08-27 22:30 snapshot showed opencode/mimo-v2.5-free at 67
# failures (http 429 rate_limit, flat 900s wall) and
# opencode/muse-spark-1.2-contributor-free at 80 (http 500 transient_http,
# flat 30s wall, "usable_at already in the past so re-probed every cycle");
# muse-spark reached 149 by 2026-08-30. The bash-side fences
# (fleet-ops#1362/#1408, lib/seat-lib.sh) only cover bash-written markers
# (spawn-fail cli_timeout, empty-run and quota/overload/hang benches). The
# extension-written markers (source=provider_fetch / after_provider_response,
# all wall classes) went through computeUsableAt with a FIXED per-mode backoff
# that ignored consecutive_failure_count, so the two seats were re-probed on
# the flat interval forever while contributing zero completions.
#
# This test is the closure condition for the out-of-repo extension at
# ~/.pi/agent/extensions/seat-health.ts (or FLEET_SEAT_HEALTH_TS). It imports
# the live extension, runs the quarantine invariants from the issue's test
# plan, and asserts the results. Today (before the fix) the flat-window
# invariants at count>=threshold fail; after the fix they pass. The PR body
# for the fix is the close PR; this test is the evidence.
#
# Invariants:
#   I1  below-threshold walls are unchanged (30s / 900s) — no behaviour
#       change for a seat that has not run away.
#   I2  AT the threshold (20) the wall jumps to the 1h floor.
#   I3  each further failure doubles the wall (21 -> 2h, 22 -> 4h).
#   I4  the live runaway counts (67 and 149) resolve to the 24h cap — the
#       two seats from the issue stop being re-probed every cycle.
#   I5  a LONGER provider retry-after (weekly quota / credentials_bad) is
#       kept — max(base, escalation), never shortened.
#   I6  healthy observations still return null usable_at (no wall).
#   I7  writeSeatLedgerEntry applies the escalation with the MERGED count
#       (a failure written on top of a prior failure carries the longer
#       wall immediately), and a healthy write resets the count to 0 —
#       the seat is cold only until one successful probe, never forever.
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
    skip "seat-health.ts not installed at $EXT_PATH — install the extension to run this gate (fleet-ops#1422)"
fi

NODE_BIN="${FLEET_SEAT_HEALTH_NODE:-node}"
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    fail "node missing ($NODE_BIN); need >= 22.6 for --experimental-strip-types"
fi

node_major=$("$NODE_BIN" -e 'console.log(Number.parseInt(process.versions.node.split(".")[0], 10))')
node_minor=$("$NODE_BIN" -e 'console.log(Number.parseInt(process.versions.node.split(".")[1], 10))')
if [[ "$node_major" -lt 22 ]] || { [[ "$node_major" -eq 22 ]] && [[ "$node_minor" -lt 6 ]]; }; then
    fail "node $node_major.$node_minor is too old; need >= 22.6 for --experimental-strip-types (fleet-ops#1422)"
fi

# Run a node --experimental-strip-types snippet that calls computeUsableAt
# for one (mode, retryAfter, count) triple and returns the wall-seconds
# (usable_at - observed_at) as the last line RESULT_JSON:{seconds,usable}.
# The observed anchor is passed in, so the diff is exact (no clock skew).
#
# $1 = invariant name
# $2 = mode (SeatFailureMode)
# $3 = retry-after seconds (or null)
# $4 = consecutive failure count
# $5 = expected wall seconds (or "null")
wall_invariant() {
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
    if [[ "$got" != "$want" ]]; then
        fail "${name}: wall-seconds ${got}, expected ${want} (usable=${payload})"
    fi
    ok "${name} (secs=${want})"
}

# --- I1: below-threshold flat windows unchanged ---------------------------
wall_invariant "I1a: transient_http at c=19 keeps the flat 30s wall" "transient_http" "null" "19" "30"
wall_invariant "I1b: rate_limit at c=19 keeps the flat 900s wall" "rate_limit" "null" "19" "900"

# --- I2/I3: at and past the threshold, exponential from the 1h floor ------
wall_invariant "I2: rate_limit at c=20 (threshold) jumps to the 1h floor" "rate_limit" "null" "20" "3600"
wall_invariant "I3a: rate_limit at c=21 doubles to 2h" "rate_limit" "null" "21" "7200"
wall_invariant "I3b: rate_limit at c=22 doubles to 4h" "rate_limit" "null" "22" "14400"

# --- I4: the live runaway counts hit the 24h cap --------------------------
wall_invariant "I4a: mimo-v2.5-free at c=67 (issue snapshot) parks 24h" "rate_limit" "null" "67" "86400"
wall_invariant "I4b: muse-spark at c=149 (live 2026-08-30) parks 24h" "transient_http" "null" "149" "86400"

# --- I5: a longer provider retry-after is never shortened -----------------
wall_invariant "I5: c=149 keeps a weekly retry-after (604800)" "transient_http" "604800" "149" "604800"
wall_invariant "I5b: credentials_bad base (weekly) is never shortened" "credentials_bad" "null" "149" "604800"

# --- I6: healthy stays wall-less ------------------------------------------
wall_invariant "I6: healthy (mode none) returns null usable_at" "none" "null" "50" "null"

# --- I7: the write path escalates on the MERGED count and resets on healthy
scratch=$(mktemp -d -t seat-quarantine.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM
caps="$scratch/seat-caps.json"
ledger="$scratch/ledger"
mkdir -p "$ledger"
# Tiny threshold so the whole ladder is reachable in three writes.
cat >"$caps" <<'JSON'
{
  "walled_comeback": {
    "min_probe_interval_s": 900,
    "rate_limit_s": 900,
    "daily_quota_s": 3600,
    "monthly_quota_s": 86400,
    "free_balance_exhausted_s": 86400,
    "credentials_bad_s": 604800,
    "quarantine_threshold": 2,
    "quarantine_floor_s": 3600,
    "quarantine_cap_s": 86400
  }
}
JSON
# Env must be set at the PROCESS level before import: LEDGER_DIR and
# SEAT_CAPS_JSON_PATH are import-time consts in seat-health.ts.
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
// write 1: c=1 below the tiny threshold (2) -> flat 30s
writeSeatLedgerEntry(obs({}));
let e = read();
out.push(['w1-count', e.consecutive_failure_count, 'w1-diff', Math.round((Date.parse(e.usable_at) - now) / 1000)]);
// write 2: c=2 at threshold -> 1h floor
writeSeatLedgerEntry(obs({}));
e = read();
out.push(['w2-count', e.consecutive_failure_count, 'w2-diff', Math.round((Date.parse(e.usable_at) - now) / 1000)]);
// write 3: c=3 -> doubled 2h
writeSeatLedgerEntry(obs({}));
e = read();
out.push(['w3-count', e.consecutive_failure_count, 'w3-diff', Math.round((Date.parse(e.usable_at) - now) / 1000)]);
// healthy write resets to 0 and clears the wall
writeSeatLedgerEntry({ ...base, http_status: 200, health_class: 'healthy', failure_mode: 'none', observed_at: new Date(now + 1000).toISOString(), usable_at: null, consecutive_failure_count: 0 });
e = read();
out.push(['w4-count', e.consecutive_failure_count, 'w4-usable', String(e.usable_at)]);
console.log('RESULT_JSON:' + JSON.stringify(out));
" 2>&1 | tail -n1)
if [[ "$last" != RESULT_JSON:* ]]; then
    fail "I7: node write-path output did not contain a RESULT_JSON line (got: $last)"
fi
payload="${last#RESULT_JSON:}"
# Assert the four writes in bash.
expect_i7() {
    local want="$1" idx="$2" value="$3"
    local got
    got=$(node -e "const p = JSON.parse(process.argv[1]); const [o,i] = '${idx}'.split(',') .map(Number); console.log(String(p[o][i]))" "$payload" 2>/dev/null || echo "?")
    if [[ "$got" != "$want" ]]; then
        fail "I7: $value=${got}, expected ${want} (payload=${payload})"
    fi
}
expect_i7 "1" "0,1" "w1-count"
expect_i7 "30" "0,3" "w1-diff (below threshold keeps flat wall)"
expect_i7 "2" "1,1" "w2-count"
expect_i7 "3600" "1,3" "w2-diff (at threshold -> 1h floor)"
expect_i7 "3" "2,1" "w3-count"
expect_i7 "7200" "2,3" "w3-diff (doubled)"
expect_i7 "0" "3,1" "w4-count (healthy resets)"
expect_i7 "null" "3,3" "w4-usable (wall cleared)"
ok "I7: writeSeatLedgerEntry merges the count, escalates the wall, and a healthy write resets the seat"

ok "fleet-ops#1422 closure: runaway seats quarantine to the 1h-min/24h-cap exponential wall; below-threshold and healthy behaviour unchanged"