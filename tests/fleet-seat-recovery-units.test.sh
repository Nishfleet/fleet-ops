#!/usr/bin/env bash
# tests/fleet-seat-recovery-units.test.sh
#
# fleet-ops#622: fleet-seat-recovery.path fails to start (unit-start-limit-hit).
# The seats ledger is written every few seconds (every seat-health extension
# update), so fleet-seat-recovery.path fires fleet-seat-recovery.service
# ~30x/min. The DEFAULT StartLimitBurst=5 / StartLimitIntervalSec=10s is blown
# through in well under a minute of normal fleet traffic, which wedges BOTH
# the service AND the .path unit with unit-start-limit-hit (proven live
# 2026-08-27: the path unit went inactive/failed 12min after start). The bin's
# own FLEET_SEAT_RECOVERY_COOLDOWN (default 120s) is the real rate-limiter for
# the side effect (the intake fire); the systemd start limit only needs to
# tolerate the no-op trigger storm, not gate the fire.
#
# This test is split from tests/fleet-seat-recovery.test.sh (which exercises
# the bin's transition/cooldown logic) so the unit-shape + live wedge-recovery
# assertions run independently of the bin test. It is invoked from the listed
# tests/fleet-seat-recovery.test.sh (p14-test-listing-gate: transitively
# invoked from a listed test).
#
# What we prove:
#   1. fleet-seat-recovery.service carries a storm-tolerant StartLimit guard
#      in [Unit] (StartLimitIntervalSec=1h, StartLimitBurst>1800) so a healthy
#      fleet cannot wedge its own seat-recovery fast path.
#   2. StartLimit* does NOT leak into [Service] (systemd rejects it there).
#   3. systemd-analyze verify accepts both unit files (syntax + directives).
#   4. Live wedge-recovery drill: 60 .path triggers in ~3s (far past the old
#      5/10s default) leaves the .path unit active(waiting), not failed.
#      Skipped outside a user-systemd session (CI hosted runners).
#
# Runs read-only against the repo except for the live drill, which installs
# throwaway *-drill unit files into the user systemd scope and removes them.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

svc_unit="$repo_root/systemd/fleet-seat-recovery.service"
path_unit="$repo_root/systemd/fleet-seat-recovery.path"
[[ -f "$svc_unit" ]] || fail "missing: $svc_unit"
[[ -f "$path_unit" ]] || fail "missing: $path_unit"

# --- 1. StartLimit guard in [Unit] -------------------------------------------
# StartLimit* must live in [Unit] (systemd rejects them in [Service]).
# Extract the [Unit] section and assert both directives are present and high
# enough to survive a sustained ledger-write storm.
unit_section=$(awk '/^\[Unit\]/{f=1} /^\[/{if(f&&$0!~/^\[Unit\]/)f=0} f' "$svc_unit")
[[ -n "$unit_section" ]] || fail "no [Unit] section in $svc_unit"
echo "$unit_section" | grep -qE '^StartLimitIntervalSec=1h$' \
  || fail "StartLimitIntervalSec=1h missing from [Unit] in $svc_unit"
echo "$unit_section" | grep -qE '^StartLimitBurst=[0-9]+$' \
  || fail "StartLimitBurst missing from [Unit] in $svc_unit"
burst=$(echo "$unit_section" | sed -nE 's/^StartLimitBurst=([0-9]+)$/\1/p')
[[ -n "$burst" ]] || fail "could not parse StartLimitBurst"
# 30 triggers/min * 60min = 1800/hr worst case; the guard must clear that
# with headroom so a healthy fleet cannot wedge its own fast path.
(( burst > 1800 )) \
  || fail "StartLimitBurst=$burst too low for ~1800/hr trigger storm (need >1800)"
ok "fleet-seat-recovery.service carries a storm-tolerant StartLimit guard in [Unit] (burst=$burst)"

# --- 2. StartLimit* must not leak into [Service] -----------------------------
svc_section=$(awk '/^\[Service\]/{f=1} /^\[/{if(f&&$0!~/^\[Service\]/)f=0} f' "$svc_unit")
if echo "$svc_section" | grep -qE '^StartLimit'; then
  fail "StartLimit* must not appear in [Service] (systemd rejects it there)"
fi
ok "StartLimit* confined to [Unit] (not in [Service])"

# --- 3. systemd-analyze verify accepts both unit files -----------------------
# Same convention as tests/escalation-units-shape.test.sh. The CI unit-verify
# job already verifies systemd/*.service, but it does NOT verify .path files
# directly — this does.
#
# fleet-ops#622: the service's ExecStart points at a VPS-only binary path
# (/home/nish/.local/bin/fleet-seat-recovery). The dedicated `systemd-analyze`
# job in .github/workflows/ci.yml stubs that path before verify, but P14 has
# no such stubs and re-adding that pattern trips the #154 class lock. So this
# test creates its OWN stub, scoped to its own scratch dir, by copying the
# service with the ExecStart retargeted at /bin/true, and verifies the copy
# (real syntax + directives) plus the untouched .path (no ExecStart to fail
# on). The shipped unit files are never modified.
if command -v systemd-analyze >/dev/null 2>&1; then
  verify_scratch="$(mktemp -d -t fleet-seat-recovery-verify.XXXXXX)"
  # shellcheck disable=SC2064  # we WANT verify_scratch to expand now; the
  # trap fires on EXIT from THIS test process, not the caller's.
  trap "rm -rf '$verify_scratch'" EXIT INT TERM
  verify_svc="$verify_scratch/fleet-seat-recovery.service"
  verify_path="$verify_scratch/fleet-seat-recovery.path"
  # Retarget ExecStart to /bin/true so the VPS binary is not required.
  # Keep everything else (StartLimit* guards, [Install], comments) byte-identical
  # so the verify proves what the shipped unit proves.
  sed 's|^ExecStart=.*|ExecStart=/bin/true|' "$svc_unit" > "$verify_svc"
  cp "$path_unit" "$verify_path"
  for f in "$verify_svc" "$verify_path"; do
    if ! out=$(systemd-analyze verify --man=no "$f" 2>&1); then
      fail "systemd-analyze verify failed for $(basename "$f"): $out"
    fi
  done
  ok "systemd-analyze verify accepts fleet-seat-recovery.{service,path} (with ExecStart retargeted for P14)"
else
  echo "SKIP: systemd-analyze not on PATH (unit verify)"
fi

# --- 4. live wedge-recovery drill --------------------------------------------
# Prove the fix end-to-end: install the SHIPPED unit files (name-swapped) into
# a throwaway user systemd scope, drive the .path trigger well past the OLD
# default limit (5/10s), and assert the path unit stays active (waiting) —
# i.e. the storm no longer wedges it. Skipped outside the VPS (no user systemd
# session) so CI hosted runners don't false-positive.
#
# fleet-ops#622: the original gate only checked for an XDG_RUNTIME_DIR socket
# and a systemctl binary. GitHub-hosted runners (Ubuntu 24.04 image) provide
# BOTH, and HOME has no `~/.config/systemd/user/` directory by default — so
# the test's `sed > "$drill_svc"` opened a non-existent path and red'd P14 on
# a runner that has no user-systemd-managed services to actually wedge.
# Gate on the existence of the per-user unit dir (the VPS has it; CI does
# not) so the drill only runs where it can actually exercise the real
# path-watcher storm.
if [[ -n "${XDG_RUNTIME_DIR:-}" ]] && [[ -S "${XDG_RUNTIME_DIR}/systemd/private" ]] \
   && [[ -d "$HOME/.config/systemd/user" ]] \
   && command -v systemctl >/dev/null 2>&1; then
  drill_unit="fleet-seat-recovery-drill"
  drill_svc="$HOME/.config/systemd/user/${drill_unit}.service"
  drill_path="$HOME/.config/systemd/user/${drill_unit}.path"
  trigger="$(mktemp -t sr-drill-trigger.XXXXXX)"
  # Copy the SHIPPED unit files with the unit name swapped in, so the drill
  # exercises the real StartLimit guard, not a hand-written stand-in.
  sed "s/fleet-seat-recovery/${drill_unit}/g" "$svc_unit" > "$drill_svc"
  sed "s|/home/nish/workspaces/agent-state/lanes/seats|${trigger}|g; s/fleet-seat-recovery/${drill_unit}/g" "$path_unit" > "$drill_path"
  # The shipped ExecStart points at a VPS bin; point it at /bin/true so the
  # drill only exercises the trigger/rate-limit path, not the real bin.
  sed -i 's|^ExecStart=.*|ExecStart=/bin/true|' "$drill_svc"
  cleanup_drill() {
    systemctl --user stop "${drill_unit}.service" "${drill_unit}.path" 2>/dev/null || true
    systemctl --user reset-failed "${drill_unit}.service" "${drill_unit}.path" 2>/dev/null || true
    rm -f "$drill_svc" "$drill_path" "$trigger"
    systemctl --user daemon-reload 2>/dev/null || true
  }
  trap cleanup_drill EXIT INT TERM
  systemctl --user daemon-reload
  systemctl --user reset-failed "${drill_unit}.service" "${drill_unit}.path" 2>/dev/null || true
  systemctl --user stop "${drill_unit}.service" "${drill_unit}.path" 2>/dev/null || true
  systemctl --user start "${drill_unit}.path" 2>/dev/null || fail "could not start drill .path"
  # Hammer the trigger ~60x in ~3s — far past the old 5/10s default limit.
  for _ in $(seq 1 60); do : > "$trigger"; sleep 0.05; done
  sleep 0.5
  st=$(systemctl --user show -p ActiveState -p Result "${drill_unit}.path" 2>/dev/null)
  echo "$st" | grep -q 'ActiveState=active' \
    || fail "drill .path wedged under trigger storm: $st (StartLimit guard not effective)"
  echo "$st" | grep -q 'Result=success' \
    || fail "drill .path Result not success: $st"
  ok "live drill: 60 triggers in 3s does not wedge fleet-seat-recovery.path ($st)"
  cleanup_drill
  trap - EXIT INT TERM
else
  echo "SKIP: live wedge-recovery drill (no user systemd session)"
fi

echo "OK: fleet-seat-recovery-units: StartLimit guard + verify + wedge drill"
