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

echo ""
echo "ALL TESTS PASSED -- fleet-ops#1160 mechanism verified"
