#!/usr/bin/env bash
# tests/seat-health-ledger-noop-write.test.sh
#
# fleet-ops#5096: the seat-recovery hot loop's TRIGGER fix.
#
# fleet-seat-recovery.path watches the seat-ledger DIRECTORY
# (PathChanged=/home/nish/workspaces/agent-state/lanes/seats), so every
# ledger write starts the fleet-seat-recovery oneshot. Live 2026-09-11 that
# was 2471-2536 activations/h sustained (23 writes/30s, ~20 of them on one
# HEALTHY seat rewritten once per provider round-trip across ~32 workers),
# while seatlib.sh only distrusts a record once observed_at is older than
# STALE_SECS=21600 (6h). The write rate asked systemd to fork/exec ~2500x/h
# to refresh a timestamp no reader consults inside a 6h window.
#
# The writer is the OUT-OF-REPO seat-health extension
# (~/.pi/agent/extensions/seat-health.ts, FLEET_SEAT_HEALTH_TS). This test is
# the in-repo closure condition: it imports the LIVE extension and pins the
# writer's new contract.
#
# What we prove:
#   N1  WRITE-RATE DROP. 200 healthy observations of the same seat inside the
#       refresh interval produce 1 write, not 200 (>10x drop; live ratio is
#       ~1 write per refresh interval per seat instead of 1 per round-trip).
#   N2  REFRESH INTERVAL IS REAL. With a 1s interval, identical observations
#       more than 1s apart still write — so a record can never drift toward
#       the 6h STALE_SECS cliff while its content is unchanged.
#   N3  NEVER SKIP A ROUTING-RELEVANT CHANGE. Each of the five fields the
#       issue names (health_class, failure_mode, seat_dead, usable_at,
#       consecutive_failure_count) makes the write non-redundant on its own.
#   N4  STALENESS IS MEASURED FROM THE REAL CLOCK, not the entry's own
#       observed_at (a caller cannot back-date a record into looking fresh),
#       and an unparseable observed_at is never treated as fresh.
#   N5  A no-op write skip is INDISTINGUISHABLE to every reader: running the
#       same observation sequence with the skip ON and OFF (refresh 0) leaves
#       identical routing-relevant fields and identical `seat_usable`
#       verdicts for healthy, rate_limited, quota_exhausted and corpse
#       records. refresh=0 restores the pre-#5096 always-write behaviour.
#
# Environment seams (same convention as tests/seat-health-quarantine.test.sh):
#   FLEET_SEAT_HEALTH_TS    absolute path to seat-health.ts. Default:
#                           $HOME/.pi/agent/extensions/seat-health.ts
#   FLEET_SEAT_HEALTH_NODE  node binary. Default: node (needs >= 22.6 for
#                           --experimental-strip-types)
#
# CI safety: if the extension is not installed the test skips with a named
# reason (hosted runners have no ~/.pi/agent/extensions). Hosted by
# tests/ci-standards-audit.test.sh, which is listed in ci.yml's P14
# verify-command — so it runs on the VPS as the real closure check.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
skip() { echo "SKIP: $*"; exit 0; }

EXT_PATH="${FLEET_SEAT_HEALTH_TS:-$HOME/.pi/agent/extensions/seat-health.ts}"
if [[ ! -f "$EXT_PATH" ]]; then
    skip "seat-health.ts not installed at $EXT_PATH — the writer is out-of-repo (fleet-ops#5096); install the extension to run this gate"
fi

NODE_BIN="${FLEET_SEAT_HEALTH_NODE:-node}"
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    fail "node missing ($NODE_BIN); need >= 22.6 for --experimental-strip-types"
fi

node_major=$("$NODE_BIN" -e 'console.log(Number.parseInt(process.versions.node.split(".")[0], 10))')
node_minor=$("$NODE_BIN" -e 'console.log(Number.parseInt(process.versions.node.split(".")[1], 10))')
if [[ "$node_major" -lt 22 ]] || { [[ "$node_major" -eq 22 ]] && [[ "$node_minor" -lt 6 ]]; }; then
    fail "node $node_major.$node_minor is too old; need >= 22.6 for --experimental-strip-types (fleet-ops#5096)"
fi

scratch=$(mktemp -d -t seat-noop.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

# Hermetic seat-caps so the walled-comeback ladder is deterministic.
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

driver="$scratch/driver.mjs"
cat >"$driver" <<'MJS'
import { readFileSync } from "node:fs";

const ext = process.env.EXT_PATH;
const mode = process.argv[2];
const {
  writeSeatLedgerEntry,
  seatLedgerPath,
  ledgerWriteIsRedundant,
  LEDGER_NOOP_REFRESH_SECS,
} = await import(ext);

const out = { refresh: LEDGER_NOOP_REFRESH_SECS };

const read = (p) => JSON.parse(readFileSync(p, "utf8"));

if (mode === "rate") {
  // N1: 200 healthy observations of ONE seat, 1.5s of simulated round-trip
  // time apart (the live cadence). Count writes as distinct on-disk
  // observed_at values — the cheapest unambiguous "did a write land?" probe.
  const p = seatLedgerPath("bench", "healthy-hot-loop");
  const t0 = Date.now();
  const base = {
    provider: "bench", model: "healthy-hot-loop", http_status: 200,
    retry_after: null, health_class: "healthy", retryable: false,
    seat_dead: false, poison_ladder: false, source: "provider_fetch",
    failure_mode: "none",
  };
  let writes = 0;
  let last = null;
  let firstOnDisk = null;
  for (let i = 0; i < 200; i++) {
    writeSeatLedgerEntry({
      ...base,
      observed_at: new Date(t0 + i * 1500).toISOString(),
      usable_at: null,
      consecutive_failure_count: 0,
    });
    const on = read(p).observed_at;
    if (on !== last) { writes++; last = on; }
    if (firstOnDisk === null) firstOnDisk = on;
  }
  out.calls = 200;
  out.writes = writes;
  out.firstOnDisk = firstOnDisk;
  out.lastOnDisk = last;
  out.firstExpected = new Date(t0).toISOString();
  out.lastExpected = new Date(t0 + 199 * 1500).toISOString();
}

if (mode === "expiry") {
  // N2: refresh interval 1s (env), real sleeps, identical routing content.
  // Every observation must land on disk once the on-disk record is older
  // than the interval — a skipped write can never let a record drift toward
  // the 6h STALE_SECS cliff.
  const p = seatLedgerPath("bench", "refreshed");
  const base = {
    provider: "bench", model: "refreshed", http_status: 200, retry_after: null,
    health_class: "healthy", retryable: false, seat_dead: false,
    poison_ladder: false, source: "provider_fetch", failure_mode: "none",
    usable_at: null, consecutive_failure_count: 0,
  };
  let writes = 0;
  let last = null;
  for (let i = 0; i < 3; i++) {
    writeSeatLedgerEntry({ ...base, observed_at: new Date().toISOString() });
    const on = read(p).observed_at;
    if (on !== last) { writes++; last = on; }
    if (i < 2) await new Promise((r) => setTimeout(r, 1100));
  }
  out.writes = writes;
}

if (mode === "predicate") {
  // N3/N4/N5-predicate: drive ledgerWriteIsRedundant directly with an
  // explicit nowMs so the staleness comparison is exact and clock-free.
  const now = Date.now();
  const rec = {
    provider: "bench", model: "pred", http_status: 200, retry_after: null,
    health_class: "healthy", retryable: false, seat_dead: false,
    poison_ladder: false, source: "provider_fetch", failure_mode: "none",
    usable_at: null, consecutive_failure_count: 0,
    observed_at: new Date(now).toISOString(),
  };
  const mk = (patch) => ({ ...rec, ...patch });
  const same = mk({});
  out.identical = ledgerWriteIsRedundant(rec, same, now);
  out.fields = {};
  for (const [name, patch] of [
    ["health_class", { health_class: "rate_limited" }],
    ["failure_mode", { failure_mode: "rate_limit" }],
    ["seat_dead", { seat_dead: true }],
    ["usable_at", { usable_at: new Date(now + 60000).toISOString() }],
    ["consecutive_failure_count", { consecutive_failure_count: 1 }],
  ]) {
    // Keep observed_at identical to `prev` so ONLY the named field differs.
    out.fields[name] = ledgerWriteIsRedundant(rec, mk(patch), now);
  }
  out.age = {
    fresh: ledgerWriteIsRedundant(
      mk({ observed_at: new Date(now - 29 * 60 * 1000).toISOString() }), same, now),
    at_interval: ledgerWriteIsRedundant(
      mk({ observed_at: new Date(now - 30 * 60 * 1000).toISOString() }), same, now),
    stale_6h: ledgerWriteIsRedundant(
      mk({ observed_at: new Date(now - 6 * 3600 * 1000).toISOString() }), same, now),
  };
  out.no_prev = ledgerWriteIsRedundant(null, same, now);
  out.unparseable = ledgerWriteIsRedundant(
    mk({ observed_at: "not-a-timestamp" }), same, now);
  // A caller cannot fabricate freshness: the age is measured from the record
  // that is ALREADY on disk, against the real clock, so stamping a future
  // observed_at on the incoming entry cannot suppress a write for a stale
  // on-disk record.
  out.future_next = ledgerWriteIsRedundant(
    mk({ observed_at: new Date(now - 6 * 3600 * 1000).toISOString() }),
    mk({ observed_at: new Date(now + 3600 * 1000).toISOString() }),
    now);
  // A future-stamped ON-DISK record is fresh by definition — skipping it is
  // correct (it is not near the STALE_SECS cliff from any reader's view).
  out.future_prev = ledgerWriteIsRedundant(
    mk({ observed_at: new Date(now + 2000).toISOString() }), same, now);
}

if (mode === "seats") {
  // N5: the same observation sequence for one healthy seat, two walled seats
  // and one seat driven to corpse. Run once with the skip ON (default
  // refresh) and once with refresh=0 (the pre-#5096 always-write path), so
  // the two ledgers can be compared field-for-field and verdict-for-verdict.
  const mk = (provider, model, extra) => ({
    provider, model, http_status: 200, retry_after: null,
    health_class: "healthy", retryable: false, seat_dead: false,
    poison_ladder: false, source: "provider_fetch", failure_mode: "none",
    usable_at: null, consecutive_failure_count: 0,
    observed_at: new Date().toISOString(),
    ...extra,
  });
  out.seats = {};
  // A FIXED wall time for the failure seats, shared by both runs, so the two
  // ledgers are comparable field-for-field (usable_at is derived from the
  // observation instant). Set by the test harness via BENCH_OBS.
  const failObs = process.env.BENCH_OBS || new Date().toISOString();

  // healthy: 50 no-op observations 1.5s of simulated time apart.
  {
    const model = "healthy";
    const p = seatLedgerPath("bench", model);
    const t0 = Date.now();
    let writes = 0;
    let last = null;
    for (let i = 0; i < 50; i++) {
      writeSeatLedgerEntry(mk("bench", model, {
        observed_at: new Date(t0 + i * 1500).toISOString(),
      }));
      const on = read(p).observed_at;
      if (on !== last) { writes++; last = on; }
    }
    out.seats.healthy = { writes, record: read(p) };
  }

  // rate_limited: a fixed Retry-After wall; every failure bumps the merged
  // consecutive_failure_count, so each observation is a real change.
  {
    const model = "rate-limited";
    const p = seatLedgerPath("bench", model);
    const obs = failObs;
    let writes = 0;
    let last = null;
    for (let i = 0; i < 5; i++) {
      writeSeatLedgerEntry(mk("bench", model, {
        http_status: 429, health_class: "rate_limited", retryable: true,
        failure_mode: "rate_limit", retry_after: 900, observed_at: obs,
      }));
      const on = read(p).observed_at;
      if (on !== last) { writes++; last = on; }
    }
    out.seats["rate-limited"] = { writes: read(p).consecutive_failure_count, record: read(p) };
  }

  // quota_exhausted: same shape on the 402 wall.
  {
    const model = "quota-exhausted";
    const p = seatLedgerPath("bench", model);
    const obs = failObs;
    let writes = 0;
    let last = null;
    for (let i = 0; i < 5; i++) {
      writeSeatLedgerEntry(mk("bench", model, {
        http_status: 402, health_class: "quota_exhausted", retryable: true,
        failure_mode: "quota_exhausted", observed_at: obs,
      }));
      const on = read(p).observed_at;
      if (on !== last) { writes++; last = on; }
    }
    out.seats["quota-exhausted"] = { writes: read(p).consecutive_failure_count, record: read(p) };
  }

  // corpse: 25 transient 500s at one instant -> seat_dead=true, class corpse,
  // usable_at cleared (fleet-ops#2145/#2327/#2415).
  {
    const model = "corpse";
    const p = seatLedgerPath("bench", model);
    const obs = failObs;
    let writes = 0;
    let last = null;
    for (let i = 0; i < 25; i++) {
      writeSeatLedgerEntry(mk("bench", model, {
        http_status: 500, health_class: "transient_fault", retryable: true,
        failure_mode: "transient_http", observed_at: obs,
      }));
      const on = read(p).observed_at;
      if (on !== last) { writes++; last = on; }
    }
    out.seats.corpse = { writes: read(p).consecutive_failure_count, record: read(p) };
  }
}

console.log("RESULT_JSON:" + JSON.stringify(out));
MJS

export EXT_PATH
BENCH_OBS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export BENCH_OBS

run_driver() {
    # $1 = mode, $2 = refresh secs, $3 = ledger dir, $4 = sidecar path
    local mode="$1" refresh="$2" ledger="$3" sidecar="$4"
    mkdir -p "$ledger"
    PI_SEAT_HEALTH_LEDGER_DIR="$ledger" \
    PI_SEAT_HEALTH_SIDECAR="$sidecar" \
    PI_SEAT_CAPS_JSON="$caps" \
    PI_SEAT_HEALTH_NOOP_REFRESH_SECS="$refresh" \
    BENCH_OBS="$BENCH_OBS" \
    "$NODE_BIN" --experimental-strip-types --no-warnings=ExperimentalWarning \
        "$driver" "$mode" 2>&1 | tail -n1 || true
}

jget() {
    # $1 = payload, $2 = js expression on `p`
    "$NODE_BIN" -e "const p = JSON.parse(process.argv[1]); console.log(String($2))" "$1"
}

jseat() {
    # $1 = payload, $2 = seat model, $3 = dotted path under p.seats[model]
    "$NODE_BIN" -e "const p = JSON.parse(process.argv[1]); const m = p.seats[process.argv[2]]; console.log(String(eval('m.' + process.argv[3])))" \
        "$1" "$2" "$3"
}

# --- N1: write-rate drop for the healthy hot loop ----------------------------
ledger_a="$scratch/ledger-n1"
payload="$(run_driver rate 1800 "$ledger_a" "$scratch/sidecar-a.json")"
[[ "$payload" == RESULT_JSON:* ]] || fail "N1: driver produced no RESULT_JSON (got: $payload)"
pa="${payload#RESULT_JSON:}"
[[ "$(jget "$pa" p.refresh)" == "1800" ]] || fail "N1: expected default refresh 1800, got $(jget "$pa" p.refresh)"
calls="$(jget "$pa" p.calls)"
writes="$(jget "$pa" p.writes)"
[[ "$calls" == "200" ]] || fail "N1: expected 200 calls, got $calls"
if (( writes * 10 > calls )); then
    fail "N1: no-op writes not suppressed — $calls calls produced $writes writes (need <= $((calls / 10)) for a >10x drop)"
fi
[[ "$(jget "$pa" p.firstOnDisk)" == "$(jget "$pa" p.firstExpected)" ]] \
    || fail "N1: first on-disk observed_at is not the first observation — the write path changed shape"
[[ "$(jget "$pa" p.lastOnDisk)" != "$(jget "$pa" p.lastExpected)" ]] \
    || fail "N1: every observation wrote (no skip happened)"
ok "N1: $calls healthy observations inside the refresh interval produced $writes ledger write(s) — $((calls / (writes == 0 ? 1 : writes)))x drop, expected >10x"

# --- N2: the refresh interval is real, not a permanent freeze ----------------
ledger_b="$scratch/ledger-n2"
payload="$(run_driver expiry 1 "$ledger_b" "$scratch/sidecar-b.json")"
[[ "$payload" == RESULT_JSON:* ]] || fail "N2: driver produced no RESULT_JSON (got: $payload)"
pb="${payload#RESULT_JSON:}"
w2="$(jget "$pb" p.writes)"
[[ "$w2" == "3" ]] || fail "N2: with a 1s refresh, 3 identical observations >1s apart must each write (got $w2 writes)"
ok "N2: refresh interval honoured — 3 identical observations past the 1s interval wrote 3 times"

# --- N3/N4: the redundancy predicate --------------------------------------
ledger_c="$scratch/ledger-n3"
mkdir -p "$ledger_c"
payload="$(run_driver predicate 1800 "$ledger_c" "$scratch/sidecar-c.json")"
[[ "$payload" == RESULT_JSON:* ]] || fail "N3: driver produced no RESULT_JSON (got: $payload)"
pc="${payload#RESULT_JSON:}"
[[ "$(jget "$pc" p.identical)" == "true" ]] \
    || fail "N3: an identical record must be redundant (got $(jget "$pc" p.identical))"
for f in health_class failure_mode seat_dead usable_at consecutive_failure_count; do
    got="$(jget "$pc" "p.fields.$f")"
    [[ "$got" == "false" ]] \
        || fail "N3: a change to $f must never be skipped (predicate said redundant=$got)"
done
ok "N3: each of the five routing-relevant fields alone makes the write non-redundant"

expect_age() {
    local want="$1" key="$2" why="$3"
    local got
    got="$(jget "$pc" "p.age.$key")"
    [[ "$got" == "$want" ]] || fail "N4: $why — age.$key=$got, expected $want"
}
expect_age "true"  fresh      "a record 29 min old is still inside the 30 min refresh interval"
expect_age "false" at_interval "a record AT the refresh interval must write (never drift toward STALE_SECS)"
expect_age "false" stale_6h   "a record at the 6h STALE_SECS cliff must write"
[[ "$(jget "$pc" p.no_prev)" == "false" ]] \
    || fail "N4: no on-disk record must never be treated as redundant"
[[ "$(jget "$pc" p.unparseable)" == "false" ]] \
    || fail "N4: an unparseable observed_at must never be treated as fresh"
[[ "$(jget "$pc" p.future_next)" == "false" ]] \
    || fail "N4: freshness must come from the on-disk record, not the incoming entry — a future-stamped entry must not suppress a write for a stale record"
[[ "$(jget "$pc" p.future_prev)" == "true" ]] \
    || fail "N4: a future-stamped on-disk record is fresh and may be skipped (got $(jget "$pc" p.future_prev))"
ok "N4: refresh-interval boundary, STALE_SECS cliff, no-record, unparseable and caller-stamped-freshness cases all behave"

# --- N5: indistinguishable to every reader (A/B: skip ON vs OFF) -------------
ledger_skip="$scratch/ledger-skip"
ledger_write="$scratch/ledger-write"
pskip="$(run_driver seats 1800 "$ledger_skip" "$scratch/sidecar-skip.json")"
[[ "$pskip" == RESULT_JSON:* ]] || fail "N5: skip-ON driver produced no RESULT_JSON (got: $pskip)"
pskip="${pskip#RESULT_JSON:}"
pwrite="$(run_driver seats 0 "$ledger_write" "$scratch/sidecar-write.json")"
[[ "$pwrite" == RESULT_JSON:* ]] || fail "N5: skip-OFF driver produced no RESULT_JSON (got: $pwrite)"
pwrite="${pwrite#RESULT_JSON:}"

h_skip="$(jseat "$pskip" healthy writes)"
h_write="$(jseat "$pwrite" healthy writes)"
[[ "$h_write" == "50" ]] \
    || fail "N5: refresh=0 must restore the always-write path (50 healthy observations -> $h_write writes)"
if (( h_skip * 10 > 50 )); then
    fail "N5: healthy seat wrote $h_skip times with the skip ON vs $h_write with it OFF — need a >10x drop"
fi

# Source lib/litellm-seat.sh against the same scratch ledger dirs so the ROUTER
# (seat_usable) is the judge of "indistinguishable", not this test's own
# reading of the JSON.
router() {
    # $1 = ledger dir, $2 = model
    PI_SEAT_HEALTH_LEDGER_DIR="$1" PI_SEAT_CAPS_JSON="$caps" \
    _SEAT_USABLE_SILENT=1 bash -c '
        source "$1/lib/litellm-seat.sh" >/dev/null 2>&1 || true
        if seat_usable bench "$2"; then echo usable; else echo unusable; fi
    ' _ "$repo_root" "$2"
}

expect_seat() {
    local model="$1" want_verdict="$2" want_writes="$3"
    for key in health_class seat_dead usable_at consecutive_failure_count; do
        local a b
        a="$(jseat "$pskip" "$model" "record.$key")"
        b="$(jseat "$pwrite" "$model" "record.$key")"
        [[ "$a" == "$b" ]] \
            || fail "N5: $model.$key differs between skip-ON ($a) and skip-OFF ($b) — the skip is visible to a reader"
    done
    local v_skip v_write ws ww
    ws="$(jseat "$pskip" "$model" writes)"
    ww="$(jseat "$pwrite" "$model" writes)"
    if [[ "$want_writes" != "-" ]]; then
        # Failure seats: the on-disk consecutive_failure_count IS the write
        # count (it only advances when a write lands), so an exact match
        # proves no observation was skipped.
        [[ "$ws" == "$ww" ]] \
            || fail "N5: $model write count differs with the skip ON ($ws) vs OFF ($ww)"
        [[ "$ws" == "$want_writes" ]] \
            || fail "N5: $model on-disk failure count=$ws, expected $want_writes — an observation was skipped and the record went stale"
    fi
    v_skip="$(router "$ledger_skip" "$model")"
    v_write="$(router "$ledger_write" "$model")"
    [[ "$v_skip" == "$v_write" ]] \
        || fail "N5: seat_usable(bench/$model) differs: skip-ON=$v_skip skip-OFF=$v_write"
    [[ "$v_skip" == "$want_verdict" ]] \
        || fail "N5: seat_usable(bench/$model)=$v_skip, expected $want_verdict"
    echo "  $model: skip-ON writes=$ws skip-OFF writes=$ww verdict=$v_skip"
}

# The corpse seat is produced by the writer (25 transient 500s), and the
# walled seats by their own failure ladders — so this also proves the skip
# never suppressed a routing-relevant change.
expect_seat "healthy" "usable" "-"
expect_seat "rate-limited" "unusable" "5"
expect_seat "quota-exhausted" "unusable" "5"
expect_seat "corpse" "unusable" "25"
ok "N5: identical routing fields and identical seat_usable verdicts with the no-op skip ON vs OFF (healthy/rate_limited/quota_exhausted/corpse)"

echo "OK: fleet-ops#5096 closure: the seat-health writer skips unchanged ledger writes inside a documented refresh interval (>10x fewer writes), never skips a routing-relevant change or a near-STALE_SECS record, and leaves every seat_usable verdict identical"
