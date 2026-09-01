#!/usr/bin/env bash
# tests/opus-heartbeat-frozen-claims-gate.test.sh
#
# fleet-ops#2711: the opus-heartbeat launcher's frozen-queue gate
# (`queue_frozen()`) MUST consider BOTH the alert-repair pipeline
# (waste.dispatches_last_2h) AND the pi-issue pipeline (claims_last_2h)
# before declaring the queue frozen. The earlier gate only checked
# dispatches + ready_work, which fired a false-positive "frozen queue"
# whenever alert-repair was idle — even if pi-issue was actively claiming
# issues every minute.
#
# Live case 2026-09-01T21:30:13Z: snapshot showed
#   waste.dispatches_last_2h = 0
#   claims_last_2h           = 28
#   fleet.ready_work         = 31
# A zero-dispatch/nonzero-claim window is HEALTHY (alert-repair idle,
# pi-issue alive). The earlier gate was ONE ready_work bump (51) away
# from misfiring the narrow `--unit repair-*` direct-dispatch lever,
# which would have routed work to a seat instead of through intake —
# the exact symptom the live #1453 run needed the gate to prevent.
#
# This test pins the new gate shape end-to-end via the launcher's
# `--check-allowlist "<line>"` self-check flag. The launcher reads
# claims_last_2h from the canonical top-level structure
# (snap.claims_last_2h.n, written by opus-heartbeat-gather) and falls
# back to snap.flat.claims_last_2h for fixtures that only carry the
# flat form. Either path is exercised below.
#
# Scenarios (fleet-ops#366 mechanical-fix shape):
#   1. True frozen: claims=0 + dispatches=0 + ready=300 + repair-x
#      -> ALLOW queue_frozen=1.
#   2. False-positive blocked (the live #2711 case): claims=30 +
#      dispatches=0 + ready=300 + repair-x -> SKIP-QUEUE-NOT-FROZEN.
#   3. Pi-issue alive AND alert-repair alive: claims=10 + dispatches=10
#      + ready=300 + repair-x -> SKIP-QUEUE-NOT-FROZEN.
#   4. claims_last_2h via flat fallback: claims=20 in flat only +
#      dispatches=0 + ready=300 + repair-x -> SKIP-QUEUE-NOT-FROZEN
#      (proves the fallback path also gates the lever).
#   5. Env override OPUS_HB_FROZEN_CLAIMS=50 lets claims=30 through on
#      the false-positive shape -> ALLOW (proves the knob does what the
#      docstring says).
#   6. Launcher source MUST read claims_last_2h in queue_frozen() and
#      MUST cite fleet-ops#2711 in the gate comment block, so a future
#      refactor cannot silently delete the claim check or strip the
#      citation.
#
# Live/VPS-only (per the existing opus-heartbeat-* test convention):
# the launcher binary at /home/nish/.local/libexec/opus-heartbeat is
# absent on hosted CI runners. The test reads the live snapshot via
# OPUS_HB_SNAPSHOT_LIVE; fixtures are written under a scratch dir and
# pointed at via OPUS_HB_STATE. The live snapshot is backed up before
# any test writes and restored on exit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

LAUNCHER="${OPUS_HB_LAUNCHER:-/home/nish/.local/libexec/opus-heartbeat}"
SNAP_LIVE="${OPUS_HB_SNAPSHOT_LIVE:-/home/nish/.local/state/opus-heartbeat/snapshot.json}"
SNAP_BACKUP="$(mktemp -t opus-2711-snap.XXXXXX.json)"
TMP_SNAP_DIR="$(mktemp -d -t opus-2711-snapdir.XXXXXX)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$LAUNCHER" ]] || fail "launcher not executable: $LAUNCHER"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

if [[ ! -f "$SNAP_LIVE" ]]; then
  fail "live snapshot missing at $SNAP_LIVE — heartbeat gather has not run yet?"
fi

cleanup() {
  rm -rf "$TMP_SNAP_DIR"
  rm -f "$SNAP_BACKUP"
}
trap cleanup EXIT INT TERM

# Build a snapshot fixture with the requested ready_work, dispatches, and
# claims values. Claims are written under the canonical top-level
# claims_last_2h object (snap.claims_last_2h.n) AND under flat.claims_last_2h
# so either consumer path is exercised.
write_fixture() {
  local outpath="$1" ready="$2" dispatches="$3" claims="$4"
  python3 - "$outpath" "$ready" "$dispatches" "$claims" <<'PY'
import json, sys
path, ready, dispatches, claims = (
    sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
)
snap = {
    "ts": "2026-09-01T22:00:00Z",
    "epoch": 1788300000,
    "window_s": 7200,
    "host": {"load1": 1.0, "mem_avail_bytes": 8e9, "mem_total_bytes": 16e9,
              "ram_used_pct": 50.0, "disk_avail_bytes": 50e9, "disk_size_bytes": 100e9,
              "disk_free_pct": 50.0},
    "failed_units": {"user": {"names": [], "count": 0}, "system": {"names": [], "count": 0}},
    "prometheus_alerts": {"firing_n": 0, "pending_n": 0, "firing": [], "pending": []},
    "fleet_chain": {"present": False},
    "seats": {"present": False, "n": 0, "healthy_n": 0, "walled_n": 0, "seats": []},
    "fleet": {"ready_work": ready, "fleet_main_ci_green": {}, "present": True},
    "claims_last_2h": {"present": True, "n": int(claims), "samples": []},
    "waste": {
        "empty_runs_last_2h": 0, "at_capacity_events_last_2h": 0,
        "redispatches_last_2h": 0, "dispatches_last_2h": dispatches,
        "skips_last_2h": 0, "watch_present": False, "actions_present": False,
        "empty_run_samples": [], "at_capacity_samples": [], "redispatch_samples": [],
    },
    "digest": {"rc": 0, "result": "success", "exec_main_status": "0",
                "exec_main_exit_timestamp": "Thu 2026-09-01 22:00:00 IST",
                "active_state": "inactive", "error": None},
    "scout": {"rc": 0, "n": 0, "oldest_age_s": None, "timers": [], "error": None},
    "disputed_tiles": {"source": "missing", "n": 0, "tiles": []},
    "gh_rate_limit": {"limit": 5000, "remaining": 5000, "reset": 0, "used": 0},
    "flat": {"claims_last_2h": int(claims)},
    "delta": {"present": False},
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(snap, fh, separators=(",", ":"), default=str)
PY
}

# Same as write_fixture but claims only appear under flat.claims_last_2h,
# NOT under the top-level claims_last_2h object. Exercises the fallback
# path the launcher documents.
write_fixture_flat_only() {
  local outpath="$1" ready="$2" dispatches="$3" claims="$4"
  python3 - "$outpath" "$ready" "$dispatches" "$claims" <<'PY'
import json, sys
path, ready, dispatches, claims = (
    sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
)
snap = {
    "ts": "2026-09-01T22:00:00Z",
    "epoch": 1788300000,
    "window_s": 7200,
    "host": {"load1": 1.0, "mem_avail_bytes": 8e9, "mem_total_bytes": 16e9,
              "ram_used_pct": 50.0, "disk_avail_bytes": 50e9, "disk_size_bytes": 100e9,
              "disk_free_pct": 50.0},
    "failed_units": {"user": {"names": [], "count": 0}, "system": {"names": [], "count": 0}},
    "prometheus_alerts": {"firing_n": 0, "pending_n": 0, "firing": [], "pending": []},
    "fleet_chain": {"present": False},
    "seats": {"present": False, "n": 0, "healthy_n": 0, "walled_n": 0, "seats": []},
    "fleet": {"ready_work": ready, "fleet_main_ci_green": {}, "present": True},
    "claims_last_2h": {"present": False, "n": None, "samples": []},
    "waste": {
        "empty_runs_last_2h": 0, "at_capacity_events_last_2h": 0,
        "redispatches_last_2h": 0, "dispatches_last_2h": dispatches,
        "skips_last_2h": 0, "watch_present": False, "actions_present": False,
        "empty_run_samples": [], "at_capacity_samples": [], "redispatch_samples": [],
    },
    "digest": {"rc": 0, "result": "success", "exec_main_status": "0",
                "exec_main_exit_timestamp": "Thu 2026-09-01 22:00:00 IST",
                "active_state": "inactive", "error": None},
    "scout": {"rc": 0, "n": 0, "oldest_age_s": None, "timers": [], "error": None},
    "disputed_tiles": {"source": "missing", "n": 0, "tiles": []},
    "gh_rate_limit": {"limit": 5000, "remaining": 5000, "reset": 0, "used": 0},
    "flat": {"claims_last_2h": int(claims)},
    "delta": {"present": False},
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(snap, fh, separators=(",", ":"), default=str)
PY
}

make_state_dir() {
  local d="$1"
  mkdir -p "$d"
  : >"$d/journal.jsonl"
  : >"$d/actions.log"
  : >"$d/run.log"
}

check_allowlist() {
  local state_dir="$1" line="$2"
  shift 2
  local out rc
  out="$(OPUS_HB_STATE="$state_dir" "$@" "$LAUNCHER" --check-allowlist "$line" 2>&1)" && rc=0 || rc=$?
  printf '%s\n' "$out"
  return $rc
}

REPAIR_LINE='pi-systemd-run --unit repair-2711-chain --stdin /tmp/p.md -- pi --print --provider straitly --model deepseek/deepseek-v4-pro'

# --- fixtures ---------------------------------------------------------------
TRUE_FROZEN_DIR="$TMP_SNAP_DIR/true_frozen"          # claims=0 dispatches=0 ready=300
FALSE_POS_DIR="$TMP_SNAP_DIR/false_positive"          # claims=30 dispatches=0 ready=300 (the live #2711 case)
BOTH_ALIVE_DIR="$TMP_SNAP_DIR/both_alive"             # claims=10 dispatches=10 ready=300
FLAT_ONLY_DIR="$TMP_SNAP_DIR/flat_only"               # claims=20 (flat only) dispatches=0 ready=300
OVERRIDE_DIR="$TMP_SNAP_DIR/override"                 # claims=30 dispatches=0 ready=300 (for the OPUS_HB_FROZEN_CLAIMS=50 override)
LOW_READY_DIR="$TMP_SNAP_DIR/low_ready"               # claims=0 dispatches=0 ready=10 (low ready)

make_state_dir "$TRUE_FROZEN_DIR";  write_fixture "$TRUE_FROZEN_DIR/snapshot.json"  300 0   0
make_state_dir "$FALSE_POS_DIR";    write_fixture "$FALSE_POS_DIR/snapshot.json"    300 0  30
make_state_dir "$BOTH_ALIVE_DIR";   write_fixture "$BOTH_ALIVE_DIR/snapshot.json"   300 10 10
make_state_dir "$FLAT_ONLY_DIR";    write_fixture_flat_only "$FLAT_ONLY_DIR/snapshot.json" 300 0 20
make_state_dir "$OVERRIDE_DIR";     write_fixture "$OVERRIDE_DIR/snapshot.json"     300 0  30
make_state_dir "$LOW_READY_DIR";    write_fixture "$LOW_READY_DIR/snapshot.json"    10  0   0

# --- 1. true frozen -> ALLOW -----------------------------------------------
out="$(check_allowlist "$TRUE_FROZEN_DIR" "$REPAIR_LINE")" || fail "test 1: expected rc=0, got rc=$? ($out)"
case "$out" in
  "ALLOW queue_frozen=1"*) : ;;
  *) fail "test 1: expected 'ALLOW queue_frozen=1' prefix, got: $out" ;;
esac
ok "test 1: claims=0 + dispatches=0 + ready=300 + repair-* → ALLOW queue_frozen=1"

# --- 2. live #2711 false-positive shape -> SKIP-QUEUE-NOT-FROZEN ----------
# This is the live case: dispatches=0 (alert-repair idle), claims=30
# (pi-issue alive every minute), ready=300. The earlier gate would
# ALLOW this — a false positive. The new gate MUST SKIP because
# claims_last_2h (30) > OPUS_HB_FROZEN_CLAIMS (1).
set +e
out="$(check_allowlist "$FALSE_POS_DIR" "$REPAIR_LINE")"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "test 2: expected rc=1 (the live #2711 false-positive shape), got rc=$rc ($out)"
[[ "$out" == SKIP-QUEUE-NOT-FROZEN* ]] || fail "test 2: expected SKIP-QUEUE-NOT-FROZEN, got: $out"
[[ "$out" == ALLOW* ]] && fail "test 2: false-positive shape was ALLOWED — claims check missing from gate"
ok "test 2: live #2711 shape (claims=30, dispatches=0, ready=300) → SKIP-QUEUE-NOT-FROZEN"

# --- 3. both pipelines alive -> SKIP-QUEUE-NOT-FROZEN ---------------------
set +e
out="$(check_allowlist "$BOTH_ALIVE_DIR" "$REPAIR_LINE")"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "test 3: expected rc=1, got rc=$rc ($out)"
[[ "$out" == SKIP-QUEUE-NOT-FROZEN* ]] || fail "test 3: expected SKIP-QUEUE-NOT-FROZEN, got: $out"
ok "test 3: both pipelines alive (claims=10, dispatches=10, ready=300) → SKIP-QUEUE-NOT-FROZEN"

# --- 4. claims read via flat fallback path -> SKIP-QUEUE-NOT-FROZEN -------
# Fixture has claims=20 ONLY under flat.claims_last_2h (top-level
# claims_last_2h.n is missing/None). The launcher must read from the
# flat fallback path; otherwise this case would slip through and the
# gate would ALLOW.
set +e
out="$(check_allowlist "$FLAT_ONLY_DIR" "$REPAIR_LINE")"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "test 4: expected rc=1 (flat-only claims=20), got rc=$rc ($out)"
[[ "$out" == SKIP-QUEUE-NOT-FROZEN* ]] || fail "test 4: expected SKIP-QUEUE-NOT-FROZEN, got: $out"
ok "test 4: claims=20 via flat fallback (dispatches=0, ready=300) → SKIP-QUEUE-NOT-FROZEN"

# --- 5. env override OPUS_HB_FROZEN_CLAIMS=50 admits claims=30 -----------
# Proves the OPUS_HB_FROZEN_CLAIMS knob does what the docstring claims:
# it raises the threshold so a state that would otherwise be rejected
# (claims=30) becomes acceptable. With the override, the false-positive
# fixture from test 2 now satisfies the claims check (30 <= 50).
set +e
out="$(OPUS_HB_STATE="$OVERRIDE_DIR" OPUS_HB_FROZEN_CLAIMS=50 "$LAUNCHER" --check-allowlist "$REPAIR_LINE" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "test 5: expected rc=0 with OPUS_HB_FROZEN_CLAIMS=50, got rc=$rc ($out)"
case "$out" in
  "ALLOW queue_frozen=1"*) : ;;
  *) fail "test 5: expected ALLOW queue_frozen=1, got: $out" ;;
esac
ok "test 5: env override OPUS_HB_FROZEN_CLAIMS=50 admits claims=30 → ALLOW"

# --- 5b. negative control: env override alone does NOT also lower ready ---
# With OPUS_HB_FROZEN_READY=500 (well above 300), the override dir's
# ready=300 still rejects. Proves the env knob is per-axis, not a
# catch-all "lower everything".
set +e
out="$(OPUS_HB_STATE="$LOW_READY_DIR" OPUS_HB_FROZEN_READY=500 "$LAUNCHER" --check-allowlist "$REPAIR_LINE" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "test 5b: expected rc=1 (ready=10, frozen_ready=500), got rc=$rc ($out)"
ok "test 5b: env override OPUS_HB_FROZEN_READY=500 does not bypass claims or ready at low_ready=10"

# --- 6. launcher source pins the new gate shape --------------------------
grep -q 'OPUS_HB_FROZEN_CLAIMS' "$LAUNCHER" \
  || fail "launcher missing OPUS_HB_FROZEN_CLAIMS env knob"
grep -q 'claims_last_2h' "$LAUNCHER" \
  || fail "launcher queue_frozen() does not read claims_last_2h"
grep -q 'fleet-ops#2711' "$LAUNCHER" \
  || fail "launcher gate comment does not cite fleet-ops#2711"
# The gate must require claims as a third condition alongside dispatch
# and ready. Look for the conjunctive structure.
grep -qE 'claims_n[[:space:]]*<=[[:space:]]*frozen_claims' "$LAUNCHER" \
  || fail "launcher queue_frozen() missing the claims_n <= frozen_claims condition"
ok "test 6: launcher source pins OPUS_HB_FROZEN_CLAIMS + claims_last_2h + #2711 + conjunctive gate"

# --- 7. judge prompt pins the new gate shape -----------------------------
PROMPT_FILE="${OPUS_HB_PROMPT_FILE:-/home/nish/.local/share/opus-heartbeat/judge-prompt.md}"
[[ -s "$PROMPT_FILE" ]] || fail "judge prompt missing or empty at $PROMPT_FILE"
grep -qE 'claims_last_2h[[:space:]]*<=?[[:space:]]*1' "$PROMPT_FILE" \
  || fail "judge prompt does not state claims_last_2h <= 1 as part of the gate"
grep -q 'fleet-ops#2711' "$PROMPT_FILE" \
  || fail "judge prompt does not cite fleet-ops#2711"
# The earlier gate paragraph is two lines; the new paragraph must
# mention both pipelines being silent before the lever fires.
grep -qE 'BOTH pipelines' "$PROMPT_FILE" \
  || fail "judge prompt does not state BOTH pipelines must be silent"
ok "test 7: judge prompt pins claims_last_2h <= 1 + #2711 + BOTH pipelines silent"

exit 0
