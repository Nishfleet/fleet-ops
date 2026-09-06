#!/usr/bin/env bash
# fleet-ops#1160: regression test — vps-post-reboot-verify must contain tailscale
# RECOVER logic, the weekly-update sudo probe, and a working system-scope timer.
# This is the mechanism per fleet-ops#366.
# If the script only announces (fail "tailscale DOWN...") without attempting
# systemctl enable --now tailscaled / tailscale up --reset, the test FAILs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/vps-post-reboot-verify"
WEEKLY="$REPO_ROOT/bin/vps-weekly-update"
MANIFEST="$REPO_ROOT/MANIFEST"
INSTALL_SH="$REPO_ROOT/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --------------------------------------------------------------- 1. TAILSCALE RECOVER
echo "Checking $SCRIPT for tailscale RECOVER logic (fleet-ops#1160)..."

# Must contain the recover block marker
if ! grep -q "TAILSCALE RECOVER" "$SCRIPT"; then
  fail "Missing 'TAILSCALE RECOVER' section marker"
fi

# Must attempt to re-enable/restart tailscaled.service
if ! grep -q "systemctl enable --now tailscaled" "$SCRIPT"; then
  fail "Missing 'systemctl enable --now tailscaled' recover step"
fi

# Must attempt tailscale up --reset as harder recover
if ! grep -q "tailscale up --reset" "$SCRIPT"; then
  fail "Missing 'tailscale up --reset' harder recover step"
fi

# Must NOT be announce-only: the recover attempt must exist between the
# tailscale DOWN detection and the final FAIL+= for tailscale.
if grep -A 5 "tailscale DOWN" "$SCRIPT" | grep -q "FAIL.*tailscale DOWN" \
   && ! grep -B 10 "FAIL.*tailscale DOWN" "$SCRIPT" | grep -q "tailscale up --reset"; then
  fail "Script appears to be announce-only (tailscale DOWN -> FAIL without recover)"
fi

ok "vps-post-reboot-verify contains tailscale RECOVER logic (not announce-only)"

# --------------------------------------------------------------- 2. SUDO PROBE
echo ""
echo "Checking $WEEKLY for privileged-path probe (fleet-ops#1160)..."

if ! grep -q "SUDO_PROBE" "$WEEKLY"; then
  fail "Missing SUDO_PROBE variable"
fi

if ! grep -q "sudo -n systemctl is-active systemd-journald" "$WEEKLY"; then
  fail "Missing sudo probe command"
fi

if ! grep -q "privileged path broken (sudo probe empty)" "$WEEKLY"; then
  fail "Missing fail-fast message for empty sudo probe"
fi

if ! grep -q "fail-fast" "$WEEKLY"; then
  fail "Missing fail-fast comment"
fi

ok "vps-weekly-update contains privileged-path probe (fail-fast before QUIESCE)"

# --------------------------------------------------------------- 3. TIMER SCOPE + MANIFEST
echo ""
echo "Checking timer scope and configuration (fleet-ops#1160)..."

# The timer MUST be system-scope (systemd/system/) because the service it
# triggers is system-scope. A user-scope timer cannot activate a system-scope
# service — systemd refuses with "unit to trigger not loaded" (fleet-ops#1160).
TIMER="$REPO_ROOT/systemd/system/vps-post-reboot-verify.timer"

if [ ! -f "$TIMER" ]; then
  fail "Timer missing from systemd/system/ (must be system-scope to trigger system-scope service)"
fi

if grep -q "Persistent=true" "$TIMER"; then
  ok "timer has Persistent=true"
else
  fail "Timer missing Persistent=true"
fi

if grep -q "OnCalendar=Sun.*04:00:00" "$TIMER"; then
  ok "timer schedules ~30 min post-reboot (Sun 04:00 IST)"
else
  fail "Timer not set to ~30 min post-reboot (Sun 04:00)"
fi

# The timer must NOT be in the user-scope directory — that was the bug.
if [ -f "$REPO_ROOT/systemd/vps-post-reboot-verify.timer" ]; then
  fail "Timer still in user-scope systemd/ — moved to systemd/system/ was incomplete"
fi

# MANIFEST must install the timer at system scope (/etc/systemd/system/),
# not user scope (~/.config/systemd/user/).
if ! grep -Fxq "systemd/system/vps-post-reboot-verify.timer /etc/systemd/system/vps-post-reboot-verify.timer" "$MANIFEST"; then
  fail "MANIFEST must install timer at /etc/systemd/system/ (system scope)"
fi

# The old user-scope MANIFEST entry must be gone.
if grep -q "vps-post-reboot-verify.timer /home/nish/.config/systemd/user/vps-post-reboot-verify.timer" "$MANIFEST"; then
  fail "MANIFEST still has the old user-scope timer entry"
fi

ok "timer is system-scope in repo, MANIFEST, and correctly scheduled"

# --------------------------------------------------------------- 4. install.sh enables system timer
echo ""
echo "Checking install.sh enables the system-scope timer (fleet-ops#1160)..."

if ! grep -q "vps-post-reboot-verify.timer" "$INSTALL_SH"; then
  fail "install.sh does not reference vps-post-reboot-verify.timer"
fi

if ! grep -q "sudo systemctl enable.*vps-post-reboot-verify.timer" "$INSTALL_SH"; then
  fail "install.sh does not enable vps-post-reboot-verify.timer at system scope"
fi

ok "install.sh enables vps-post-reboot-verify.timer at system scope"

# --------------------------------------------------------------- 5. EXEC BIT
# fleet-ops#3829: install.sh symlinks these scripts to ~/.local/bin/<name> and
# systemd ExecStart runs them directly. A script tracked 100644 comes out of a
# fresh checkout / `git reset --hard` without the executable bit, the symlink
# target is then not executable, and systemd aborts the service with status
# 203/EXEC — the weekly maintenance window silently never runs and the reboot
# flag is never cleared (lived root cause on netcup-rs2000, 2026-09-06).
echo ""
for vps_script in bin/vps-weekly-update bin/vps-post-reboot-verify; do
  f="$REPO_ROOT/$vps_script"
  if [ ! -f "$f" ]; then
    fail "missing $vps_script"
  fi
  mode=$(git -C "$REPO_ROOT" ls-files -s "$vps_script" | awk '{print $1}')
  # 100644 is git's not-executable blob mode; 100755 is executable.
  if [ "$mode" = "100644" ]; then
    fail "$vps_script is git-tracked non-executable (mode $mode) but is run directly by systemd ExecStart -> 203/EXEC (fleet-ops#3829)"
  fi
  if [ ! -x "$f" ]; then
    fail "$vps_script is not executable in the working tree (mode $(stat -c '%A' "$f"))"
  fi
  ok "$vps_script is executable (git mode $mode, worktree $(stat -c '%A' "$f"))"
done

# General class lock: every non-python/non-TS script under bin/ must be
# git-tracked executable. install.sh symlinks these to ~/.local/bin and other
# systemd ExecStart units run them directly; a 100644 blob silently breaks the
# unit at exec time. (bin/*.py and bin/*.ts are invoked via their interpreter
# or imported as modules, so the exec bit does not apply to them.)
for script in "$REPO_ROOT"/bin/*; do
  rel=${script#"$REPO_ROOT"/}
  case "$rel" in
    *.py|*.ts) continue ;;
  esac
  mode=$(git -C "$REPO_ROOT" ls-files -s "$rel" | awk '{print $1}')
  if [ "$mode" = "100644" ]; then
    fail "bin/$rel is git-tracked non-executable (100644) but is run directly -> systemd 203/EXEC class (fleet-ops#3829)"
  fi
done
ok "all non-py/ts scripts under bin/ are git-tracked executable (fleet-ops#3829 class lock)"

# --------------------------------------------------------------- 6. REBOOT-REQUIRED SURVIVAL DETECTOR
# fleet-ops#3994: when the maintenance window fails (e.g. 203/EXEC from #3829,
# or any other failure), the deadman resumes agents but never checks the
# reboot-required flag. The flag then sits unnoticed until a THOROUGH heartbeat
# LLM happens to file it — 14h in the lived case. The fix: vps-post-reboot-verify
# now runs every Sun 04:00 (ConditionPathExists removed from the service) and,
# when no reboot happened (no resume-after-boot marker), checks
# /var/run/reboot-required and surfaces it loudly.
echo ""
echo "Checking reboot-required survival detector (fleet-ops#3994)..."

SVC="$REPO_ROOT/systemd/system/vps-post-reboot-verify.service"
TIMER_UNIT="$REPO_ROOT/systemd/system/vps-post-reboot-verify.timer"

# The service must NOT gate on ConditionPathExists — that made it skip when no
# reboot happened, which is exactly the case where the flag survives.
if grep -q "ConditionPathExists" "$SVC"; then
  fail "vps-post-reboot-verify.service still has ConditionPathExists — skips the no-reboot path where the flag survives (fleet-ops#3994)"
fi
ok "vps-post-reboot-verify.service runs every Sun 04:00 regardless of reboot (no ConditionPathExists)"

# The script must check /var/run/reboot-required in the no-marker branch.
if ! grep -q "fleet-ops#3994" "$SCRIPT"; then
  fail "vps-post-reboot-verify missing fleet-ops#3994 marker — no-marker reboot-required check not added"
fi
if ! grep -q "/var/run/reboot-required" "$SCRIPT"; then
  fail "vps-post-reboot-verify does not check /var/run/reboot-required in the no-marker path (fleet-ops#3994)"
fi
if ! grep -q "REBOOT-REQUIRED SURVIVED" "$SCRIPT"; then
  fail "vps-post-reboot-verify missing the SURVIVED surface line (fleet-ops#3994)"
fi
# Must NOT auto-reboot outside the sanctioned window — only surface.
if grep -q "systemctl reboot" "$SCRIPT"; then
  fail "vps-post-reboot-verify must never reboot directly — only surface a surviving flag inside the sanctioned window logic (fleet-ops#3994)"
fi
# Must skip the check while the window is still in progress (pause flag set)
# so a long apt that hasn't reached the reboot step is not a false alarm.
if ! grep -q "agent-maintenance-status" "$SCRIPT"; then
  fail "vps-post-reboot-verify must gate the no-marker check on agent-maintenance-status to skip while the window is still running (fleet-ops#3994)"
fi
ok "vps-post-reboot-verify surfaces a surviving reboot-required flag, skips while window is in progress, never auto-reboots (fleet-ops#3994)"

# The timer description must no longer reference ConditionPathExists.
if grep -q "ConditionPathExists" "$TIMER_UNIT"; then
  fail "vps-post-reboot-verify.timer still references ConditionPathExists in its comment (fleet-ops#3994)"
fi
ok "vps-post-reboot-verify.timer comment updated for the no-condition path (fleet-ops#3994)"

echo ""
echo "ALL TESTS PASSED -- fleet-ops#1160 mechanism verified + #3829 exec-bit guard + #3994 reboot-required survival detector"
