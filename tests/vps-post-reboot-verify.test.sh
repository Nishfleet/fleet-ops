#!/usr/bin/env bash
# tests/vps-post-reboot-verify.test.sh
#
# fleet-ops#1160: weekly-update reboot must recover Tailscale/SSH, not
# announce-only. Hosted from tests/system-dropins-shape.test.sh (already
# in P14) so CI cannot skip it without a workflow edit this token cannot
# push.
#
# What it proves:
#   1. Scripts + system unit + Persistent retry timer exist and are in
#      MANIFEST / install.sh.
#   2. recover_tailscale re-enables/restarts (and `tailscale up`), not
#      status-and-FAIL.
#   3. An announce-only fixture FAILS the same checker (fleet-ops#366).
#   4. resume-after-boot is kept until verify succeeds, so the retry
#      timer can re-run.
#   5. vps-weekly-update probes sudo after set_flag paused and fail-fasts
#      before QUIESCE when the probe file is empty.
#   6. recover_tailscale and probe_privileged_path run against stubs
#      (the real functions, not a copy of their predicate).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

lib="$repo_root/bin/vps-maintenance-lib"
verify="$repo_root/bin/vps-post-reboot-verify"
weekly="$repo_root/bin/vps-weekly-update"
svc="$repo_root/systemd/system/vps-post-reboot-verify.service"
timer="$repo_root/systemd/system/vps-post-reboot-verify.timer"
manifest="$repo_root/MANIFEST"
install_sh="$repo_root/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -x "$verify" ]] || fail "not executable: $verify"
[[ -x "$weekly" ]] || fail "not executable: $weekly"
[[ -f "$svc" ]] || fail "missing $svc"
[[ -f "$timer" ]] || fail "missing $timer"
bash -n "$lib" || fail "vps-maintenance-lib: bash syntax error"
bash -n "$verify" || fail "vps-post-reboot-verify: bash syntax error"
bash -n "$weekly" || fail "vps-weekly-update: bash syntax error"

# ---------------------------------------------------------------------------
# Shape: recover is restart/up, not announce-only
# ---------------------------------------------------------------------------
recovers_tailscale() {
  local f="$1"
  grep -qE 'systemctl .*enable .*tailscaled|systemctl .*restart .*tailscaled' "$f" \
    && grep -qE 'tailscale up' "$f"
}

recovers_tailscale "$lib" \
  || fail "vps-maintenance-lib must re-enable/restart tailscaled AND run tailscale up"
grep -qE '^recover_tailscale\(\)' "$lib" \
  || fail "vps-maintenance-lib must define recover_tailscale()"
grep -qE '^[[:space:]]*recover_tailscale' "$verify" \
  || fail "vps-post-reboot-verify must call recover_tailscale"
if grep -qE 'FAIL\+=\("tailscale DOWN' "$verify"; then
  grep -qE 'after recover' "$verify" \
    || fail "verify still announces tailscale DOWN without a recover step"
fi
ok "verify recovers tailscale (enable/restart + up)"

# fleet-ops#366 drill: the same checker MUST reject announce-only.
scratch="$(mktemp -d -t vps-reboot-verify.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
cat >"$scratch/announce-only" <<'EOF'
#!/usr/bin/env bash
# The pre-#1160 shape: status check, then FAIL, no recover.
sudo -n tailscale status >/dev/null 2>&1 || FAIL+=("tailscale DOWN — SSH path at risk")
EOF
if recovers_tailscale "$scratch/announce-only"; then
  fail "announce-only fixture must FAIL the recover checker (fleet-ops#366)"
fi
ok "announce-only fixture is rejected (fleet-ops#366 drill)"

# ---------------------------------------------------------------------------
# Marker must survive a failed recover so the retry timer can re-run
# ---------------------------------------------------------------------------
python3 - "$verify" <<'PY' || fail "resume-after-boot must be removed only after recover succeeds"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
i_rec = text.find("recover_tailscale")
i_rm = text.find('rm -f "$STATE/resume-after-boot"')
if i_rec < 0:
    raise SystemExit("recover_tailscale call missing")
if i_rm < 0:
    raise SystemExit("resume-after-boot cleanup missing")
if i_rm < i_rec:
    raise SystemExit("resume-after-boot is cleared before recover_tailscale")
# The rm must sit on the success path, after the FAIL array check.
i_fail = text.find("if [ ${#FAIL[@]} -gt 0 ]")
if i_fail < 0 or not (i_rec < i_fail < i_rm):
    raise SystemExit("resume-after-boot cleanup is not after the FAIL check")
PY
ok "resume-after-boot is kept until verify succeeds"

# ---------------------------------------------------------------------------
# Timer + service shape
# ---------------------------------------------------------------------------
grep -q '^# Named reason:' "$timer" \
  || fail "timer must carry a Named reason (fleet-unjustified-wait)"
grep -q '^OnBootSec=30min$' "$timer" \
  || fail "timer must fire 30 min after boot (OnBootSec=30min)"
grep -q '^OnCalendar=Sun \*\-\*\-\* 04:00:00$' "$timer" \
  || fail "timer must have Sunday 04:00 calendar (30 min after weekly-update 03:30)"
grep -q '^Persistent=true$' "$timer" \
  || fail "timer must be Persistent=true so a missed Sunday still fires"
grep -q '^Unit=vps-post-reboot-verify.service$' "$timer" \
  || fail "timer must start vps-post-reboot-verify.service"
grep -q '^\[Install\]$' "$timer" \
  || fail "timer must carry [Install]"
grep -q '^WantedBy=timers.target$' "$timer" \
  || fail "timer [Install] must WantedBy=timers.target"
ok "retry timer is Persistent, OnBootSec=30min, Sunday 04:00"

grep -q '^After=.*network-online.target' "$svc" \
  || fail "service must After=network-online.target"
grep -q '^After=.*tailscaled.service' "$svc" \
  || fail "service must After=tailscaled.service"
grep -q '^ConditionPathExists=/home/nish/.local/state/vps-maintenance/resume-after-boot$' "$svc" \
  || fail "service must no-op unless resume-after-boot is set"
grep -q '^ExecStart=/home/nish/.local/bin/vps-post-reboot-verify$' "$svc" \
  || fail "service ExecStart must be vps-post-reboot-verify"
ok "service waits on network+tailscaled and gates on resume-after-boot"

# ---------------------------------------------------------------------------
# MANIFEST + install.sh enable
# ---------------------------------------------------------------------------
grep -Fxq "bin/vps-maintenance-lib /home/nish/.local/bin/vps-maintenance-lib" "$manifest" \
  || fail "MANIFEST missing vps-maintenance-lib"
grep -Fxq "bin/vps-post-reboot-verify /home/nish/.local/bin/vps-post-reboot-verify" "$manifest" \
  || fail "MANIFEST missing vps-post-reboot-verify"
grep -Fxq "bin/vps-weekly-update /home/nish/.local/bin/vps-weekly-update" "$manifest" \
  || fail "MANIFEST missing vps-weekly-update"
grep -Fxq "systemd/system/vps-post-reboot-verify.service /etc/systemd/system/vps-post-reboot-verify.service" "$manifest" \
  || fail "MANIFEST missing system vps-post-reboot-verify.service"
grep -Fxq "systemd/system/vps-post-reboot-verify.timer /etc/systemd/system/vps-post-reboot-verify.timer" "$manifest" \
  || fail "MANIFEST missing system vps-post-reboot-verify.timer"
ok "MANIFEST ships scripts + system unit + timer"

grep -Fq -- 'sudo -n systemctl enable --now vps-post-reboot-verify.timer' "$install_sh" \
  || fail "install.sh must enable --now vps-post-reboot-verify.timer"
# Default (user) install must also copy the system units: fleet-ops-deploy
# never passes --system, and vacation SSH cannot wait for a hand run.
grep -Fq -- '/etc/systemd/system/vps-post-reboot-verify.timer' "$install_sh" \
  || fail "install.sh default pass must install the system retry timer when sudo -n works"
ok "install.sh enables the system retry timer"

# ---------------------------------------------------------------------------
# weekly-update: sudo probe after set_flag paused, before QUIESCE
# ---------------------------------------------------------------------------
grep -qE '^probe_privileged_path\(\)' "$lib" \
  || fail "vps-maintenance-lib must define probe_privileged_path()"
grep -q 'sudo-probe.txt' "$lib" \
  || fail "probe must write \$STATE/sudo-probe.txt"
grep -q 'probe_privileged_path' "$weekly" \
  || fail "vps-weekly-update must call probe_privileged_path"
python3 - "$weekly" <<'PY' || fail "sudo probe is not after set_flag paused and before QUIESCE"
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
i_flag = text.find('set_flag paused')
i_probe = text.find("if ! probe_privileged_path; then")
i_quiesce = text.find('if [ ! -s "$STATE/paused-timers" ]; then')
if i_flag < 0 or i_probe < 0 or i_quiesce < 0:
    raise SystemExit("missing set_flag paused / probe / paused-timers gate")
if not (i_flag < i_probe < i_quiesce):
    raise SystemExit("probe must sit after set_flag paused and before QUIESCE")
if "aborting before QUIESCE" not in text:
    raise SystemExit("fail-fast must say aborting before QUIESCE")
PY
ok "weekly-update probes sudo after pause and fail-fasts before QUIESCE"

# ---------------------------------------------------------------------------
# Live functions against stubs
# ---------------------------------------------------------------------------
export STATE="$scratch/state"
mkdir -p "$STATE" "$scratch/bin"
export MAINT_PATH_PREPEND="$scratch/bin"
export TAILSCALE_RECOVER_SLEEP=0
export TAILSCALE_UP_SLEEP=0

# sudo stub: strip -n and exec the rest so we can stub tailscale/systemctl.
cat >"$scratch/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-n" ] && shift
exec "$@"
EOF
chmod +x "$scratch/bin/sudo"

# --- probe_privileged_path ---
cat >"$scratch/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "is-active" ] && [ "${2:-}" = "systemd-journald" ]; then
  if [ "${PROBE_EMPTY:-0}" = 1 ]; then
    exit 1
  fi
  printf 'active\n'
  exit 0
fi
exit 0
EOF
chmod +x "$scratch/bin/systemctl"

# shellcheck source=/dev/null
. "$lib"

if ! probe_privileged_path; then
  fail "probe_privileged_path should succeed when sudo writes 'active'"
fi
[[ -s "$STATE/sudo-probe.txt" ]] || fail "sudo-probe.txt must be non-empty on success"
[[ "$(cat "$STATE/sudo-probe.txt")" == "active" ]] \
  || fail "sudo-probe.txt should contain systemd-journald is-active output"
ok "probe_privileged_path writes a non-empty sudo-probe.txt"

export PROBE_EMPTY=1
if probe_privileged_path; then
  fail "probe_privileged_path must fail when the privileged path returns empty"
fi
[[ ! -s "$STATE/sudo-probe.txt" ]] \
  || fail "sudo-probe.txt must be empty when the privileged path is dead"
ok "probe_privileged_path fail-fasts on an empty privileged path"
unset PROBE_EMPTY

# --- recover_tailscale ---
: >"$scratch/calls"
cat >"$scratch/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-}"
echo "tailscale $*" >>"${CALLS:?}"
if [ "$cmd" = "status" ]; then
  case "${TS_STATUS_MODE:-up}" in
    up) exit 0 ;;
    down-then-up)
      if [ "${TS_STATUS_N:-0}" -ge 1 ]; then exit 0; fi
      echo $((TS_STATUS_N + 1)) >"${TS_STATUS_FILE:?}"
      exit 1
      ;;
    down) exit 1 ;;
    *) exit 1 ;;
  esac
fi
if [ "$cmd" = "up" ]; then
  exit "${TS_UP_RC:-0}"
fi
exit 0
EOF
chmod +x "$scratch/bin/tailscale"

cat >"$scratch/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"${CALLS:?}"
exit 0
EOF
chmod +x "$scratch/bin/systemctl"

export CALLS="$scratch/calls"
export TS_STATUS_FILE="$scratch/ts-status-n"
echo 0 >"$TS_STATUS_FILE"

TS_STATUS_MODE=up
: >"$CALLS"
recover_tailscale || fail "recover_tailscale should succeed when status is already up"
if grep -q 'restart' "$CALLS"; then
  fail "recover_tailscale must not restart when tailscale is already up"
fi
ok "recover_tailscale is a no-op when tailscale is already up"

TS_STATUS_MODE=down-then-up
echo 0 >"$TS_STATUS_FILE"
# The stub's down-then-up increments a file, but the script is a new process
# each sudo exec so we need shared state. Use TS_STATUS_FILE.
cat >"$scratch/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-}"
echo "tailscale $*" >>"${CALLS:?}"
n=$(cat "${TS_STATUS_FILE:?}")
if [ "$cmd" = "status" ]; then
  if [ "$n" -ge 1 ]; then exit 0; fi
  echo $((n + 1)) >"$TS_STATUS_FILE"
  exit 1
fi
exit 0
EOF
chmod +x "$scratch/bin/tailscale"
: >"$CALLS"
echo 0 >"$TS_STATUS_FILE"
recover_tailscale || fail "recover_tailscale should succeed after restart"
grep -q 'systemctl enable --now tailscaled.service' "$CALLS" \
  || fail "recover must systemctl enable --now tailscaled.service"
grep -q 'systemctl restart tailscaled.service' "$CALLS" \
  || fail "recover must systemctl restart tailscaled.service"
ok "recover_tailscale restarts tailscaled when status is down"

TS_STATUS_MODE=down
cat >"$scratch/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-}"
echo "tailscale $*" >>"${CALLS:?}"
if [ "$cmd" = "status" ]; then
  # succeed only after `tailscale up`
  if grep -q 'tailscale up' "${CALLS:?}"; then exit 0; fi
  exit 1
fi
exit 0
EOF
chmod +x "$scratch/bin/tailscale"
: >"$CALLS"
recover_tailscale || fail "recover_tailscale should succeed after tailscale up"
grep -q 'tailscale up' "$CALLS" || fail "recover must run tailscale up when restart was not enough"
ok "recover_tailscale runs tailscale up when restart was not enough"

cat >"$scratch/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
echo "tailscale $*" >>"${CALLS:?}"
exit 1
EOF
chmod +x "$scratch/bin/tailscale"
: >"$CALLS"
if recover_tailscale; then
  fail "recover_tailscale must return 1 when still down after up"
fi
ok "recover_tailscale returns 1 when still down after recover"

echo "OK: vps-post-reboot-verify recovers Tailscale, retries on a Persistent timer, and fail-fasts a dead sudo path"
