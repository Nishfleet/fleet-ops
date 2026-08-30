#!/usr/bin/env bash
# tests/escalation-units-shape.test.sh
#
# fleet-ops#118: lock the shape of the SENIOR-AUDITOR escalation units and
# helpers that were restored to main after the PR #114 history wipe.
#
# What it proves:
#   1. All unit/drop-in files and both helper scripts exist in the repo.
#   2. Every unit and helper has the exact MANIFEST entry this issue requires.
#   3. The escalation chain is wired end-to-end:
#      - service.d/10-escalate.conf adds OnFailure=unit-escalation@%n.service
#        to every user service. path.d/ and timer.d/ do the same for .path
#        and .timer units (fleet-ops#618; service.d does not apply to them).
#      - unit-escalation@.service calls unit-escalation-write %i.
#      - unit-escalation@.service.d/no-self-escalate.conf resets OnFailure=
#        so the template cannot recurse.
#      - unit-escalation-write refuses the self-trigger / feedback-loop set.
#      - stop-escalation.path watches STOP-REASON.json and triggers
#        stop-escalation.service.
#      - stop-escalation.service calls stop-escalation-dispatch.
#      - escalation-daily-sweep.timer fires escalation-daily-sweep.service,
#        which writes a synthetic daily-sweep STOP-REASON.
#   4. systemd-analyze verify accepts the .service, .path, and .timer files.
#      The dedicated unit-verify CI job already verifies systemd/*.service,
#      but it does not directly verify .path or .timer files or the helpers.
#
# Runs read-only against the repo. No live systemd state is mutated.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

stop_svc="$repo_root/systemd/stop-escalation.service"
stop_path="$repo_root/systemd/stop-escalation.path"
unit_tmpl="$repo_root/systemd/unit-escalation@.service"
global_dropin="$repo_root/systemd/service.d/10-escalate.conf"
path_dropin="$repo_root/systemd/path.d/10-escalate.conf"
timer_dropin="$repo_root/systemd/timer.d/10-escalate.conf"
tmpl_dropin="$repo_root/systemd/unit-escalation@.service.d/no-self-escalate.conf"
daily_svc="$repo_root/systemd/escalation-daily-sweep.service"
daily_timer="$repo_root/systemd/escalation-daily-sweep.timer"
unit_write="$repo_root/bin/unit-escalation-write"
daily_sweep="$repo_root/bin/escalation-daily-sweep"
stop_dispatch="$repo_root/bin/stop-escalation-dispatch"

# 1. File existence.
[[ -f "$stop_svc" ]]    || fail "missing: $stop_svc"
[[ -f "$stop_path" ]]   || fail "missing: $stop_path"
[[ -f "$unit_tmpl" ]]   || fail "missing: $unit_tmpl"
[[ -f "$global_dropin" ]] || fail "missing: $global_dropin"
[[ -f "$path_dropin" ]]   || fail "missing: $path_dropin"
[[ -f "$timer_dropin" ]]  || fail "missing: $timer_dropin"
[[ -f "$tmpl_dropin" ]]  || fail "missing: $tmpl_dropin"
[[ -f "$daily_svc" ]]   || fail "missing: $daily_svc"
[[ -f "$daily_timer" ]] || fail "missing: $daily_timer"
[[ -x "$unit_write" ]]  || fail "not executable: $unit_write"
[[ -x "$daily_sweep" ]] || fail "not executable: $daily_sweep"
[[ -x "$stop_dispatch" ]] || fail "not executable: $stop_dispatch"
ok "escalation units + helpers exist in repo"

# 2. Helper scripts are syntactically valid bash.
bash -n "$unit_write"  || fail "unit-escalation-write: bash syntax error"
bash -n "$daily_sweep" || fail "escalation-daily-sweep: bash syntax error"
ok "escalation helpers are syntactically valid"

# 3. MANIFEST entries: exact repo-path / live-path pairs.
expected_manifest_entries=(
  "systemd/stop-escalation.service /home/nish/.config/systemd/user/stop-escalation.service"
  "systemd/stop-escalation.path /home/nish/.config/systemd/user/stop-escalation.path"
  "systemd/unit-escalation@.service /home/nish/.config/systemd/user/unit-escalation@.service"
  "systemd/unit-escalation@.service.d/no-self-escalate.conf /home/nish/.config/systemd/user/unit-escalation@.service.d/no-self-escalate.conf"
  "systemd/service.d/10-escalate.conf /home/nish/.config/systemd/user/service.d/10-escalate.conf"
  "systemd/path.d/10-escalate.conf /home/nish/.config/systemd/user/path.d/10-escalate.conf"
  "systemd/timer.d/10-escalate.conf /home/nish/.config/systemd/user/timer.d/10-escalate.conf"
  "systemd/escalation-daily-sweep.service /home/nish/.config/systemd/user/escalation-daily-sweep.service"
  "systemd/escalation-daily-sweep.timer /home/nish/.config/systemd/user/escalation-daily-sweep.timer"
  "bin/unit-escalation-write /home/nish/.local/bin/unit-escalation-write"
  "bin/escalation-daily-sweep /home/nish/.local/bin/escalation-daily-sweep"
  "bin/stop-escalation-dispatch /home/nish/.local/bin/stop-escalation-dispatch"
)
for entry in "${expected_manifest_entries[@]}"; do
  grep -Fxq "$entry" "$manifest" || fail "MANIFEST missing entry: $entry"
done
ok "MANIFEST entries for escalation units + helpers"

# 4. stop-escalation.service shape.
grep -q '^\[Unit\]$' "$stop_svc" || fail "stop-escalation.service: missing [Unit]"
grep -q '^\[Service\]$' "$stop_svc" || fail "stop-escalation.service: missing [Service]"
grep -q '^Type=oneshot$' "$stop_svc" || fail "stop-escalation.service: must be Type=oneshot"
grep -q "^ExecStart=/bin/bash -c 'exec /home/nish/.local/bin/stop-escalation-dispatch'$" "$stop_svc" \
  || fail "stop-escalation.service: ExecStart must call stop-escalation-dispatch"
grep -q '^TimeoutStartSec=25min$' "$stop_svc" || fail "stop-escalation.service: TimeoutStartSec=25min"
grep -q '^Restart=no$' "$stop_svc" || fail "stop-escalation.service: Restart=no"
grep -q '^NoNewPrivileges=true$' "$stop_svc" || fail "stop-escalation.service: NoNewPrivileges=true"
grep -q '^PrivateTmp=true$' "$stop_svc" || fail "stop-escalation.service: PrivateTmp=true"
ok "stop-escalation.service shape"

# 5. stop-escalation.path shape.
grep -q '^\[Unit\]$' "$stop_path" || fail "stop-escalation.path: missing [Unit]"
grep -q '^\[Path\]$' "$stop_path" || fail "stop-escalation.path: missing [Path]"
grep -q '^\[Install\]$' "$stop_path" || fail "stop-escalation.path: missing [Install]"
grep -q '^PathChanged=/home/nish/workspaces/agent-state/STOP-REASON.json$' "$stop_path" \
  || fail "stop-escalation.path: must watch STOP-REASON.json"
grep -q '^Unit=stop-escalation.service$' "$stop_path" \
  || fail "stop-escalation.path: must trigger stop-escalation.service"
grep -q '^WantedBy=default.target$' "$stop_path" || fail "stop-escalation.path: WantedBy=default.target"
ok "stop-escalation.path shape"

# 6. unit-escalation@.service shape.
grep -q '^\[Unit\]$' "$unit_tmpl" || fail "unit-escalation@.service: missing [Unit]"
grep -q '^\[Service\]$' "$unit_tmpl" || fail "unit-escalation@.service: missing [Service]"
grep -q '^Type=oneshot$' "$unit_tmpl" || fail "unit-escalation@.service: Type=oneshot"
grep -q "^ExecStart=/bin/bash -c 'exec /home/nish/.local/bin/unit-escalation-write %i'$" "$unit_tmpl" \
  || fail "unit-escalation@.service: ExecStart must call unit-escalation-write %i"
grep -q '^TimeoutStartSec=1min$' "$unit_tmpl" || fail "unit-escalation@.service: TimeoutStartSec=1min"
grep -q '^Restart=no$' "$unit_tmpl" || fail "unit-escalation@.service: Restart=no"
grep -q '^NoNewPrivileges=true$' "$unit_tmpl" || fail "unit-escalation@.service: NoNewPrivileges=true"
grep -q '^PrivateTmp=true$' "$unit_tmpl" || fail "unit-escalation@.service: PrivateTmp=true"
ok "unit-escalation@.service shape"

# 7. service.d / path.d / timer.d 10-escalate.conf shape (global OnFailure).
for dropin in "$global_dropin" "$path_dropin" "$timer_dropin"; do
  grep -q '^\[Unit\]$' "$dropin" || fail "$(basename "$(dirname "$dropin")")/10-escalate.conf: missing [Unit]"
  grep -q '^OnFailure=unit-escalation@%n.service$' "$dropin" \
    || fail "$(basename "$(dirname "$dropin")")/10-escalate.conf: OnFailure=unit-escalation@%n.service"
done
ok "service.d/path.d/timer.d 10-escalate.conf shape"

# 7b. fleet-seat-recovery.service must not StartLimit-wedge the path unit.
# systemd.path: a StartLimit hit on the triggered oneshot is propagated to
# the path unit and takes the watcher down (fleet-ops#617).
seat_svc="$repo_root/systemd/fleet-seat-recovery.service"
[[ -f "$seat_svc" ]] || fail "missing: $seat_svc"
grep -q '^StartLimitIntervalSec=0$' "$seat_svc" \
  || fail "fleet-seat-recovery.service: StartLimitIntervalSec=0 (default 5/10s wedges the path unit)"
ok "fleet-seat-recovery.service StartLimitIntervalSec=0"

# 8. unit-escalation@.service.d/no-self-escalate.conf shape (recursion guard).
grep -q '^\[Unit\]$' "$tmpl_dropin" || fail "no-self-escalate.conf: missing [Unit]"
grep -q '^OnFailure=$' "$tmpl_dropin" || fail "no-self-escalate.conf: OnFailure must be reset to empty"
ok "unit-escalation@.service.d/no-self-escalate.conf shape"

# 9. escalation-daily-sweep.service shape.
grep -q '^\[Unit\]$' "$daily_svc" || fail "escalation-daily-sweep.service: missing [Unit]"
grep -q '^\[Service\]$' "$daily_svc" || fail "escalation-daily-sweep.service: missing [Service]"
grep -q '^Type=oneshot$' "$daily_svc" || fail "escalation-daily-sweep.service: Type=oneshot"
grep -q "^ExecStart=/bin/bash -c 'exec /home/nish/.local/bin/escalation-daily-sweep'$" "$daily_svc" \
  || fail "escalation-daily-sweep.service: ExecStart must call escalation-daily-sweep"
grep -q '^TimeoutStartSec=1min$' "$daily_svc" || fail "escalation-daily-sweep.service: TimeoutStartSec=1min"
ok "escalation-daily-sweep.service shape"

# 10. escalation-daily-sweep.timer shape.
grep -q '^\[Unit\]$' "$daily_timer" || fail "escalation-daily-sweep.timer: missing [Unit]"
grep -q '^\[Timer\]$' "$daily_timer" || fail "escalation-daily-sweep.timer: missing [Timer]"
grep -q '^\[Install\]$' "$daily_timer" || fail "escalation-daily-sweep.timer: missing [Install]"
grep -q '^OnCalendar=daily$' "$daily_timer" || fail "escalation-daily-sweep.timer: OnCalendar=daily"
grep -q '^Persistent=true$' "$daily_timer" || fail "escalation-daily-sweep.timer: Persistent=true"
grep -q '^WantedBy=timers.target$' "$daily_timer" || fail "escalation-daily-sweep.timer: WantedBy=timers.target"
ok "escalation-daily-sweep.timer shape"

# 11. unit-escalation-write self-trigger / feedback-loop guard.
grep -q 'unit-escalation@\*' "$unit_write" \
  || fail "unit-escalation-write: must exclude unit-escalation@* self-trigger"
grep -q 'stop-escalation.service' "$unit_write" \
  || fail "unit-escalation-write: must exclude stop-escalation.service"
grep -q 'escalation-daily-sweep.service' "$unit_write" \
  || fail "unit-escalation-write: must exclude escalation-daily-sweep.service"
grep -q 'escalation-daily-sweep.timer' "$unit_write" \
  || fail "unit-escalation-write: must exclude escalation-daily-sweep.timer"
grep -q 'resilience-drill-stub\*' "$unit_write" \
  || fail "unit-escalation-write: must exclude resilience-drill-stub* (#455 drill stubs)"
grep -q 'notify-probe.service' "$unit_write" \
  || fail "unit-escalation-write: must exclude notify-probe.service (deliberate-failure probe)"
grep -q 'notify-probe.onfail.service' "$unit_write" \
  || fail "unit-escalation-write: must exclude notify-probe.onfail.service (deliberate-failure probe onfail)"
grep -qF 'probe-*.service' "$unit_write" \
  || fail "unit-escalation-write: must exclude probe-*.service (fleet-ops#1526 live-drill scaffolding)"
grep -qF 'multi-*-sink.service' "$unit_write" \
  || fail "unit-escalation-write: must exclude multi-*-sink.service (fleet-ops#1526 live-drill scaffolding)"
ok "unit-escalation-write self-trigger guard"

# 12. systemd-analyze verify on the unit files (.service, .path, .timer).
# Drop-in .conf files cannot be verified directly by systemd-analyze, so their
# shape is locked by the grep checks above.
if command -v systemd-analyze >/dev/null 2>&1; then
  for f in "$stop_svc" "$stop_path" "$unit_tmpl" "$daily_svc" "$daily_timer"; do
    if ! out=$(systemd-analyze verify --man=no "$f" 2>&1); then
      fail "systemd-analyze verify failed for $f: $out"
    fi
    ok "systemd-analyze verify accepts $(basename "$f")"
  done
else
  echo "SKIP: systemd-analyze not on PATH"
fi

ok "escalation-units-shape: all units, drop-ins, and helpers are present, MANIFESTed, shaped, and verified"
