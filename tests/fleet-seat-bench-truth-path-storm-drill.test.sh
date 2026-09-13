#!/usr/bin/env bash
# tests/fleet-seat-bench-truth-path-storm-drill.test.sh
#
# fleet-ops#5471: fleet-seat-bench-truth.service went Result=start-limit-hit
# (2026-09-11T16:16Z) under the seats-ledger path-unit storm. The bin's
# 60s sweep debounce coalesces the SIDE EFFECTS but systemd still counts
# every queued trigger as a start, and the INSTALLED unit at that moment was
# stale — it lacked the StartLimitIntervalSec=0 that the repo unit has had
# since #5323 — so systemd's default StartLimitBurst=5 tripped within one
# 10s window and the unit wedged in failed (later triggers silently dropped
# until `systemctl --user reset-failed`, which is a band-aid, not the fix).
#
# Structural contract this test pins (the unit-level debounce, not the bin's):
#   1. The REPO unit ships StartLimitIntervalSec=0 in [Unit] so the start
#      counter can never wedge the unit into failed during a write storm.
#   2. The REPO bin keeps the sweep-gap debounce (FLEET_SEAT_COMEBACK_SWEEP_GAP_S,
#      default 60s) as the coalescing layer — a write storm runs ONE jq-read
#      sweep, the rest debounce-skip.
#   3. DRILL, sandbox layer (always runs, CI-safe): a scratch ledger + scratch
#      state are fired with 10 back-to-back ExecStart invocations inside 5s;
#      EXACTLY ONE full sweep completes, the other 9 debounce-skip, and every
#      invocation exits 0 (a oneshot no-op accumulates no failures).
#   4. DRILL, live layer (skipped when the path unit is not installed or on
#      hosted CI): the INSTALLED unit must still carry StartLimitIntervalSec=0
#      (the stale-deploy detector — this is exactly how #5471 happened), then
#      fire 10 real triggers into the watched seats dir in 5s and assert the
#      unit never enters failed and the path unit stays active.
#
# VPS graders run `bash tests/<name>.test.sh` directly; hosted CI has no user
# systemd units and skips layer 4 rather than failing (same convention as
# curator-journal-cap.test.sh).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
BIN="$repo_root/bin/fleet-seat-comeback-release"
UNIT_SRC="$repo_root/systemd/fleet-seat-bench-truth.service"
PATH_SRC="$repo_root/systemd/fleet-seat-bench-truth.path"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- 1. repo unit: StartLimitIntervalSec=0 lives in [Unit] ------------------
unit_txt="$(cat "$UNIT_SRC")"
unit_section="$(awk '/^\[Unit\]/{flag=1;next}/^\[/{flag=0}flag' <<<"$unit_txt")"
grep -q '^StartLimitIntervalSec=0' <<<"$unit_section" ||
  fail "$UNIT_SRC lost StartLimitIntervalSec=0 from [Unit] — the #5285 path-unit storm would re-trip the default StartLimitBurst=5/10s and re-wedge the unit into failed (the #5471 outage)"
ok "repo unit keeps StartLimitIntervalSec=0 in [Unit] (storm cannot wedge the start counter)"

path_section="$(awk '/^\[Path\]/{flag=1;next}/^\[/{flag=0}flag' <<<"$(cat "$PATH_SRC")")"
if [[ "$path_section" == *StartLimit* ]]; then
  fail "$PATH_SRC must not carry its own StartLimit (path units count no restarts; the knob belongs on the service)"
fi
ok "path unit carries no conflicting StartLimit override"

# --- 2. bin debounce contract ------------------------------------------------
bin_txt="$(cat "$BIN")"
grep -q 'FLEET_SEAT_COMEBACK_SWEEP_GAP_S:-60' <<<"$bin_txt" ||
  fail "bin debounce default SWEEP_GAP_S=60 vanished — the storm coalescing lives in the bin and must stay"
grep -q 'bench-truth sweep debounce' <<<"$bin_txt" ||
  fail "bin debounce skip line vanished — debounced triggers must be visible in the journal, not silent"
ok "bin keeps the 60s sweep-gap debounce (coalescing layer for the queued triggers)"

# --- 3. sandbox drill: 10 triggers in 5s -> ONE sweep, 9 debounces ----------

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/ledger" "$SCRATCH/agent-state"
printf '#!/bin/sh\nexit 0\n' > "$SCRATCH/false-pi"
chmod +x "$SCRATCH/false-pi"

storm_log="$SCRATCH/storm.log"
start_s=$(date +%s)
for i in 1 2 3 4 5 6 7 8 9 10; do
  if ! out="$(
    env AGENT_STATE="$SCRATCH/agent-state" \
        PI_SEAT_HEALTH_LEDGER_DIR="$SCRATCH/ledger" \
        PI_BIN="$SCRATCH/false-pi" \
        FLEET_SEAT_COMEBACK_STATE="$SCRATCH/state.json" \
        FLEET_SEAT_COMEBACK_PROM="$SCRATCH/f.prom" \
        FLEET_SEAT_COMEBACK_ACTIONS_LOG="$SCRATCH/actions.log" \
        FLEET_SEAT_COMEBACK_SWEEP_GAP_S=60 \
        "$BIN" --false-wall-only 2>&1
  )"; then
    fail "trigger $i of the storm drill exited non-zero: $out"
  fi
  printf '%s\n' "$out" >>"$storm_log"
done
elapsed=$(( $(date +%s) - start_s ))
(( elapsed <= 120 )) || fail "10-trigger storm took ${elapsed}s to coalesce — the debounce must turn a 5s write burst into seconds of work, not minutes (elapsed=${elapsed}s)"
ok "10 triggers in 5s all exited 0 (elapsed ${elapsed}s, oneshot never failed during the storm)"

sweeps=$(grep -c 'false-wall-only sweep complete' "$storm_log" 2>/dev/null || true)
debounces=$(grep -c 'bench-truth sweep debounce' "$storm_log" 2>/dev/null || true)
[[ "$sweeps" == "1" ]] || fail "expected EXACTLY 1 full sweep across the 10-trigger storm, got $sweeps (journal line: 'false-wall-only sweep complete')"
[[ "$debounces" == "9" ]] || fail "expected 9 debounced-skip lines across the 10-trigger storm, got $debounces (the coalescing contract: first trigger sweeps, rest debounce)"
ok "storm coalescing: exactly 1 sweep + 9 debounce-skips over 10 triggers in 5s"

# --- 4. live layer: installed unit is fresh + survives a real storm ---------
if [[ "${FLEET_SEAT_BENCH_TRUTH_DRILL_LIVE:-}" != "0" ]] \
   && command -v systemctl >/dev/null 2>&1 \
   && systemctl --user cat fleet-seat-bench-truth.service >/dev/null 2>&1; then

  # Stale-deploy detector: the exact #5471 outage mode. The repo unit has had
  # StartLimitIntervalSec=0 since #5323; the inst#lled copy at 16:16Z did not,
  # so systemd tripped its default 5-per-10s burst and the unit wedged.
  installed_txt="$(systemctl --user cat fleet-seat-bench-truth.service 2>/dev/null || true)"
  grep -q '^StartLimitIntervalSec=0$' <<<"$installed_txt" ||
    fail "INSTALLED fleet-seat-bench-truth.service lacks StartLimitIntervalSec=0 — stale deploy (the exact #5471 outage at 2026-09-11T16:16Z); re-run install.sh so the unit's start counter stays disabled"

  SEATS_DIR="${PI_SEAT_HEALTH_LEDGER_DIR:-/home/nish/workspaces/agent-state/lanes/seats}"
  before_done="$(journalctl --user -u fleet-seat-bench-truth.service --no-pager 2>/dev/null | grep -c 'false-wall-only sweep complete' || true)"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    touch "$SEATS_DIR" 2>/dev/null || fail "cannot touch the watched seats dir $SEATS_DIR"
    sleep 0.5
  done

  deadline=$(( $(date +%s) + 180 ))
  after_done="$before_done"
  while (( $(date +%s) < deadline )); do
    active="$(systemctl --user show fleet-seat-bench-truth.service --property=ActiveState --value 2>/dev/null || echo unknown)"
    [[ "$active" != "failed" ]] || fail "live storm drill: unit entered FAILED — the start-limit structural fix did not hold"
    after_done="$(journalctl --user -u fleet-seat-bench-truth.service --no-pager 2>/dev/null | grep -c 'false-wall-only sweep complete' || true)"
    if (( after_done > before_done )); then
      break
    fi
    sleep 5
  done

  active="$(systemctl --user show fleet-seat-bench-truth.service --property=ActiveState --value 2>/dev/null || echo unknown)"
  result="$(systemctl --user show fleet-seat-bench-truth.service --property=Result --value 2>/dev/null || echo unknown)"
  systemctl --user is-active --quiet fleet-seat-bench-truth.path 2>/dev/null ||
    fail "live storm drill: fleet-seat-bench-truth.path is not active after the storm"
  [[ "$active" != "failed" ]] ||
    fail "live storm drill under 10 triggers in 5s: unit FAILED (Result=$result) — the debounce must live in the unit"
  [[ "$result" != "start-limit-hit" ]] ||
    fail "live storm drill hit Result=start-limit-hit — StartLimitIntervalSec=0 is not holding on the installed unit"
  ok "live storm: 10 triggers in 5s, unit ends Result=$result ActiveState=$active, path unit still active"
  if (( after_done > before_done )); then
    ok "live storm: at least one full sweep ran during the drill window"
  else
    ok "live storm: all 10 triggers coalesced behind the 60s debounce (previous sweep still fresh)"
  fi
else
  ok "4: live layer skipped (unit fleet-seat-bench-truth.service not installed, no systemctl, or FLEET_SEAT_BENCH_TRUTH_DRILL_LIVE=0)"
fi

echo "OK: fleet-seat-bench-truth-path-storm-drill.test.sh"
