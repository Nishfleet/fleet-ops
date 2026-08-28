#!/usr/bin/env bash
# tests/opus-heartbeat-allowlist-gate.test.sh
#
# fleet-ops#1453: the opus-heartbeat launcher MUST reject
# `pi-systemd-run --unit <anything-but-repair>` and MUST reject
# `pi-systemd-run --unit repair-*` unless the snapshot proves the queue
# is frozen (`dispatches_last_2h <= 1 AND ready_work > 50`).
#
# Live #1453: the heartbeat tried `pi-systemd-run --unit repair-chain-verify`
# at 03:30:43Z against a snapshot that did NOT prove the queue frozen
# (dispatches_last_2h was 1, but the run had been working the queue in
# recent windows). The launcher correctly SKIP-NOT-ALLOWLISTED it, but
# had no queue-frozen lever at all — it would have accepted ANY
# `pi-systemd-run --unit <name>` if the snapshot had been friendlier.
# The fix narrows the lever AND gates it.
#
# The launcher is at /home/nish/.local/libexec/opus-heartbeat (the
# canonical install path). This test drives the gate end-to-end with a
# mocked snapshot via the `--check-allowlist "<line>"` self-check flag
# the launcher ships for exactly this purpose. The flag is short-circuit
# (BEFORE gather) so the test does not need live Prometheus, seat
# ledger, or Opus.
#
# Scenarios (fleet-ops#366 mechanical-fix shape):
#   1. Frozen snapshot (dispatches=0, ready=300) + `repair-x` line
#      -> ALLOW queue_frozen=1, rc=0.
#   2. Live snapshot (dispatches=2, ready=229) + `repair-x` line
#      -> SKIP-QUEUE-NOT-FROZEN, rc=1.
#   3. Boundary: dispatches=1 (== threshold) + ready=51 (just above
#      threshold) -> ALLOW (the gate is `<=` and `>`, not `<` and `>=`).
#   4. Boundary: dispatches=2 + ready=51 -> SKIP-QUEUE-NOT-FROZEN
#      (just one above threshold).
#   5. Low ready (ready=10, dispatches=0) -> SKIP-QUEUE-NOT-FROZEN
#      (queue isn't frozen if there's no backlog).
#   6. NON-repair `pi-systemd-run --unit ad-hoc-x` with frozen queue
#      -> SKIP-NOT-ALLOWLISTED (the narrow-lever rule; this is the
#      pre-#1453 loophole that must stay shut).
#   7. `nohup pi-systemd-run --unit repair-x ...` with frozen queue
#      -> SKIP-NOT-ALLOWLISTED (nohup ban preserved).
#   8. `gh issue create` with frozen queue -> ALLOW (unaffected by gate).
#   9. `systemctl --user start <concrete>.service` with frozen queue
#      -> ALLOW (unaffected by gate).
#  10. Boundary append to NISH-ESCALATIONS.md with frozen queue
#      -> ALLOW (unaffected by gate).
#  11. Env override (OPUS_HB_FROZEN_READY=5): ready=10 still rejected
#      under live snapshot but ALLOWED when lowered.
#  12. The launcher source MUST contain a `queue_frozen()` function
#      and a comment block referencing fleet-ops#1453, so a future
#      refactor cannot silently delete the gate.
#
# Out of scope (the tests do not assert these):
#   - Live `gh` / Opus / Prometheus / seat-ledger invocations (the
#     --check-allowlist flag skips gather entirely).
#   - The judge prompt content (covered by
#     tests/opus-heartbeat-follow-through.test.sh).
#   - The actions.log/journal.jsonl side effects (the flag does not
#     touch those).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

LAUNCHER="${OPUS_HB_LAUNCHER:-/home/nish/.local/libexec/opus-heartbeat}"
SNAP_LIVE="${OPUS_HB_SNAPSHOT_LIVE:-/home/nish/.local/state/opus-heartbeat/snapshot.json}"
SNAP_BACKUP="$(mktemp -t opus-1453-snap.XXXXXX.json)"
TMP_SNAP_DIR="$(mktemp -d -t opus-1453-snapdir.XXXXXX)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$LAUNCHER" ]] || fail "launcher not executable: $LAUNCHER"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

# Backup the live snapshot once. We never mutate the live snapshot in
# place during the test — every scenario writes its own fixture under
# TMP_SNAP_DIR and points OPUS_HB_STATE at it. This keeps the host's
# running heartbeat untouched (the live opus-heartbeat.timer fires on
# the hour; if it lands during the test, it reads from /home/nish/...
# via OPUS_HB_STATE, which we never override from outside this script).
if [[ -f "$SNAP_LIVE" ]]; then
  cp -f "$SNAP_LIVE" "$SNAP_BACKUP"
else
  fail "live snapshot missing at $SNAP_LIVE — heartbeat gather has not run yet?"
fi

cleanup() {
  if [[ -s "$SNAP_BACKUP" ]]; then
    cp -f "$SNAP_BACKUP" "$SNAP_LIVE"
    rm -f "$SNAP_BACKUP"
  fi
  rm -rf "$TMP_SNAP_DIR"
}
trap cleanup EXIT INT TERM

# Build a minimal-but-complete snapshot fixture with the requested
# ready_work / dispatches_last_2h values. Mirrors the live schema so
# queue_frozen() can read it without surprises. Takes the full output
# path (not a name) so the caller picks the directory layout.
write_fixture() {
  local outpath="$1" ready="$2" dispatches="$3"
  python3 - "$outpath" "$ready" "$dispatches" <<'PY'
import json, sys, os
path, ready, dispatches = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
snap = {
    "ts": "2026-08-28T10:00:00Z",
    "epoch": 1756372800,
    "window_s": 7200,
    "host": {"load1": 1.0, "mem_avail_bytes": 8e9, "mem_total_bytes": 16e9,
              "ram_used_pct": 50.0, "disk_avail_bytes": 50e9, "disk_size_bytes": 100e9,
              "disk_free_pct": 50.0},
    "failed_units": {"user": {"names": [], "count": 0}, "system": {"names": [], "count": 0}},
    "prometheus_alerts": {"firing_n": 0, "pending_n": 0, "firing": [], "pending": []},
    "fleet_chain": {"present": False},
    "seats": {"present": False, "n": 0, "healthy_n": 0, "walled_n": 0, "seats": []},
    "fleet": {"ready_work": ready, "fleet_main_ci_green": {}, "present": True},
    "claims_last_2h": {"present": True, "n": 0, "samples": []},
    "waste": {
        "empty_runs_last_2h": 0, "at_capacity_events_last_2h": 0,
        "redispatches_last_2h": 0, "dispatches_last_2h": dispatches,
        "skips_last_2h": 0, "watch_present": False, "actions_present": False,
        "empty_run_samples": [], "at_capacity_samples": [], "redispatch_samples": [],
    },
    "digest": {"rc": 0, "result": "success", "exec_main_status": "0",
                "exec_main_exit_timestamp": "Thu 2026-08-28 10:00:00 IST",
                "active_state": "inactive", "error": None},
    "scout": {"rc": 0, "n": 0, "oldest_age_s": None, "timers": [], "error": None},
    "disputed_tiles": {"source": "missing", "n": 0, "tiles": []},
    "gh_rate_limit": {"limit": 5000, "remaining": 5000, "reset": 0, "used": 0},
    "flat": {},
    "delta": {"present": False},
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(snap, fh, separators=(",", ":"), default=str)
PY
}

# Point OPUS_HB_STATE at the scratch dir so the launcher's SNAP /
# STATE / PROMPT_FILE all resolve under TMP_SNAP_DIR. The launcher
# also writes to ACTIONS_LOG / JOURNAL / RUNLOG / CLAUDE_OUT /
# VERDICT_FILE / TEXTFILE; OPUS_HB_STATE moves every one of those
# inside the scratch dir, keeping the host clean. The launcher resolves
# SNAP as $STATE/snapshot.json (NOT $STATE/state/snapshot.json), so
# the fixture goes at $d/snapshot.json directly.
make_state_dir() {
  local d="$1"
  mkdir -p "$d"
  : >"$d/journal.jsonl"
  : >"$d/actions.log"
  : >"$d/run.log"
}

# Run the launcher's gate for a single line + fixture. Echoes stdout
# and rc. The fall-through `$()` would lose rc on success, so we
# capture both via a tempfile.
check_allowlist() {
  local state_dir="$1" line="$2"
  local out rc
  out="$(OPUS_HB_STATE="$state_dir" "$LAUNCHER" --check-allowlist "$line" 2>&1)" && rc=0 || rc=$?
  printf '%s\n' "$out"
  return $rc
}

# --- fixtures ---------------------------------------------------------------
FROZEN_DIR="$TMP_SNAP_DIR/frozen"
LIVE_DIR="$TMP_SNAP_DIR/live"
LOWREADY_DIR="$TMP_SNAP_DIR/lowready"
BOUNDARY_DIR="$TMP_SNAP_DIR/boundary"
OVERRIDE_DIR="$TMP_SNAP_DIR/override"
D2_DIR="$TMP_SNAP_DIR/d2"

make_state_dir "$FROZEN_DIR";     write_fixture "$FROZEN_DIR/snapshot.json"   300 0
make_state_dir "$LIVE_DIR";       write_fixture "$LIVE_DIR/snapshot.json"     229 2
make_state_dir "$LOWREADY_DIR";   write_fixture "$LOWREADY_DIR/snapshot.json" 10  0
make_state_dir "$BOUNDARY_DIR";   write_fixture "$BOUNDARY_DIR/snapshot.json" 51  1
make_state_dir "$OVERRIDE_DIR";   write_fixture "$OVERRIDE_DIR/snapshot.json" 10  0

REPAIR_LINE='pi-systemd-run --unit repair-chain-verify --stdin /tmp/p.md -- pi --print --provider straitly --model deepseek/deepseek-v4-pro'
ADHOC_LINE='pi-systemd-run --unit ad-hoc-verify --stdin /tmp/p.md -- pi --print --provider straitly --model deepseek/deepseek-v4-pro'
NOHUP_LINE='nohup pi-systemd-run --unit repair-chain-verify --stdin /tmp/p.md -- pi --print --provider straitly --model deepseek/deepseek-v4-pro'
GH_LINE='gh issue create --repo Nishfleet/fleet-ops --label agent-ready --title x --body y'
SYSD_LINE='systemctl --user start fleet-heartbeat.service'
BOUNDARY_LINE='echo "x" >> /home/nish/workspaces/agent-state/NISH-ESCALATIONS.md'

# --- 1. frozen + repair -> ALLOW --------------------------------------------
out="$(check_allowlist "$FROZEN_DIR" "$REPAIR_LINE")" || fail "test 1: expected rc=0, got rc=$? ($out)"
case "$out" in
  "ALLOW queue_frozen=1"*) : ;;
  *) fail "test 1: expected 'ALLOW queue_frozen=1' prefix, got: $out" ;;
esac
[[ "$out" == *"$REPAIR_LINE" ]] || fail "test 1: missing line echo in: $out"
ok "test 1: frozen snapshot + repair-* → ALLOW queue_frozen=1"

# --- 2. live + repair -> SKIP-QUEUE-NOT-FROZEN -----------------------------
set +e
out="$(check_allowlist "$LIVE_DIR" "$REPAIR_LINE")"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "test 2: expected rc=1, got rc=$rc ($out)"
[[ "$out" == SKIP-QUEUE-NOT-FROZEN* ]] || fail "test 2: expected SKIP-QUEUE-NOT-FROZEN prefix, got: $out"
ok "test 2: live snapshot + repair-* → SKIP-QUEUE-NOT-FROZEN"

# --- 3. boundary: dispatches=1 + ready=51 -> ALLOW -------------------------
out="$(check_allowlist "$BOUNDARY_DIR" "$REPAIR_LINE")" || fail "test 3: expected rc=0, got rc=$? ($out)"
case "$out" in
  "ALLOW queue_frozen=1"*) : ;;
  *) fail "test 3: expected ALLOW queue_frozen=1, got: $out" ;;
esac
ok "test 3: dispatches=1 + ready=51 (boundary, inclusive '<=' and exclusive '>') → ALLOW"

# --- 4. dispatches=2 + ready=51 -> SKIP-QUEUE-NOT-FROZEN ------------------
# Sanity: confirm the frozen fixture is still frozen by spot-checking
# with a known-dispatches=2 fixture. Build one inline.
make_state_dir "$D2_DIR"; write_fixture "$D2_DIR/snapshot.json" 51 2
set +e
out="$(check_allowlist "$D2_DIR" "$REPAIR_LINE")"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "test 4: expected rc=1, got rc=$rc ($out)"
[[ "$out" == SKIP-QUEUE-NOT-FROZEN* ]] || fail "test 4: expected SKIP-QUEUE-NOT-FROZEN, got: $out"
ok "test 4: dispatches=2 + ready=51 (one above threshold) → SKIP-QUEUE-NOT-FROZEN"

# --- 5. ready=10 + dispatches=0 -> SKIP-QUEUE-NOT-FROZEN -------------------
set +e
out="$(check_allowlist "$LOWREADY_DIR" "$REPAIR_LINE")"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "test 5: expected rc=1, got rc=$rc ($out)"
[[ "$out" == SKIP-QUEUE-NOT-FROZEN* ]] || fail "test 5: expected SKIP-QUEUE-NOT-FROZEN, got: $out"
ok "test 5: low ready_work (no backlog) → SKIP-QUEUE-NOT-FROZEN"

# --- 6. non-repair pi-systemd-run + frozen -> SKIP-NOT-ALLOWLISTED ----------
set +e
out="$(check_allowlist "$FROZEN_DIR" "$ADHOC_LINE")"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "test 6: expected rc=1, got rc=$rc ($out)"
[[ "$out" == SKIP-NOT-ALLOWLISTED* ]] || fail "test 6: expected SKIP-NOT-ALLOWLISTED (not SKIP-QUEUE-NOT-FROZEN), got: $out"
# Negative control: this is the loophole; it must NOT be ALLOW.
[[ "$out" == ALLOW* ]] && fail "test 6: non-repair was ALLOWED — narrow-lever rule broken"
ok "test 6: non-repair pi-systemd-run --unit ad-hoc-x → SKIP-NOT-ALLOWLISTED (loophole shut)"

# --- 7. nohup in repair-* + frozen -> SKIP-NOT-ALLOWLISTED ------------------
set +e
out="$(check_allowlist "$FROZEN_DIR" "$NOHUP_LINE")"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "test 7: expected rc=1, got rc=$rc ($out)"
[[ "$out" == SKIP-NOT-ALLOWLISTED* ]] || fail "test 7: expected SKIP-NOT-ALLOWLISTED (not SKIP-QUEUE-NOT-FROZEN), got: $out"
ok "test 7: nohup pi-systemd-run --unit repair-* → SKIP-NOT-ALLOWLISTED (nohup ban)"

# --- 8. gh issue create + frozen -> ALLOW (unaffected) ---------------------
out="$(check_allowlist "$FROZEN_DIR" "$GH_LINE")" || fail "test 8: expected rc=0, got rc=$? ($out)"
[[ "$out" == ALLOW* ]] || fail "test 8: expected ALLOW, got: $out"
[[ "$out" != *queue_frozen=1* ]] || fail "test 8: gh ALLOW should NOT print queue_frozen, got: $out"
ok "test 8: 'gh issue create' → ALLOW (queue state does not affect)"

# --- 9. systemctl --user start + frozen -> ALLOW (unaffected) ---------------
out="$(check_allowlist "$FROZEN_DIR" "$SYSD_LINE")" || fail "test 9: expected rc=0, got rc=$? ($out)"
[[ "$out" == ALLOW* ]] || fail "test 9: expected ALLOW, got: $out"
ok "test 9: 'systemctl --user start' → ALLOW (queue state does not affect)"

# --- 10. boundary append + frozen -> ALLOW (unaffected) --------------------
out="$(check_allowlist "$FROZEN_DIR" "$BOUNDARY_LINE")" || fail "test 10: expected rc=0, got rc=$? ($out)"
[[ "$out" == ALLOW* ]] || fail "test 10: expected ALLOW, got: $out"
ok "test 10: '>> NISH-ESCALATIONS.md' → ALLOW (queue state does not affect)"

# --- 11. env override OPUS_HB_FROZEN_READY=5 lets ready=10 through ----------
set +e
out="$(OPUS_HB_STATE="$OVERRIDE_DIR" OPUS_HB_FROZEN_READY=5 \
        "$LAUNCHER" --check-allowlist "$REPAIR_LINE" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "test 11: expected rc=0 with OPUS_HB_FROZEN_READY=5, got rc=$rc ($out)"
case "$out" in
  "ALLOW queue_frozen=1"*) : ;;
  *) fail "test 11: expected ALLOW queue_frozen=1, got: $out" ;;
esac
ok "test 11: env override OPUS_HB_FROZEN_READY=5 lowers threshold → ALLOW"

# Negative control: env override alone does NOT also lower dispatches.
# With OPUS_HB_FROZEN_DISPATCHES=0 the live fixture (dispatches=2)
# still rejects.
set +e
out="$(OPUS_HB_STATE="$LIVE_DIR" OPUS_HB_FROZEN_DISPATCHES=0 \
        "$LAUNCHER" --check-allowlist "$REPAIR_LINE" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "test 11b: expected rc=1 with dispatches=2 even when frozen_dispatches=0, got rc=$rc ($out)"
ok "test 11b: env override does NOT bypass dispatches threshold (frozen_dispatches=0 still rejects dispatches=2)"

# --- 12. launcher source locks the gate -------------------------------------
grep -qE 'queue_frozen[[:space:]]*\(\)' "$LAUNCHER" \
  || fail "launcher missing queue_frozen() function"
grep -q 'fleet-ops#1453' "$LAUNCHER" \
  || fail "launcher does not cite fleet-ops#1453 in the gate block"
grep -q 'repair-' "$LAUNCHER" \
  || fail "launcher does not require the repair- prefix on direct dispatch"
ok "test 12: launcher source contains queue_frozen() + #1453 citation + repair- prefix"

exit 0
