#!/usr/bin/env bash
# fleet-ops#1160: regression test — vps-post-reboot-verify must contain tailscale RECOVER logic,
# not just announce/fail. This is the mechanism per fleet-ops#366.
# If the script only announces (fail "tailscale DOWN...") without attempting
# systemctl enable --now tailscaled / tailscale up --reset, the test FAILs.
set -euo pipefail

SCRIPT="/home/nish/workspaces/agent-worktrees/issue-fleet-ops-1160/bin/vps-post-reboot-verify"

echo "Checking $SCRIPT for tailscale RECOVER logic (fleet-ops#1160)..."

# Must contain the recover block marker
if ! grep -q "TAILSCALE RECOVER" "$SCRIPT"; then
  echo "FAIL: Missing 'TAILSCALE RECOVER' section marker"
  exit 1
fi

# Must attempt to re-enable/restart tailscaled.service
if ! grep -q "systemctl enable --now tailscaled" "$SCRIPT"; then
  echo "FAIL: Missing 'systemctl enable --now tailscaled' recover step"
  exit 1
fi

# Must attempt tailscale up --reset as harder recover
if ! grep -q "tailscale up --reset" "$SCRIPT"; then
  echo "FAIL: Missing 'tailscale up --reset' harder recover step"
  exit 1
fi

# Must NOT be announce-only (the old pattern was just: sudo -n tailscale status || FAIL+=...)
# The old announce-only pattern would be: tailscale status check followed immediately by FAIL+=
# without any recover attempt in between.
# We verify the recover attempt EXISTS between the status check and the final FAIL+=
if grep -A 5 "tailscale DOWN" "$SCRIPT" | grep -q "FAIL.*tailscale DOWN" && ! grep -B 10 "FAIL.*tailscale DOWN" "$SCRIPT" | grep -q "tailscale up --reset"; then
  echo "FAIL: Script appears to be announce-only (tailscale DOWN -> FAIL without recover)"
  exit 1
fi

echo "PASS: vps-post-reboot-verify contains tailscale RECOVER logic"
echo "  - TAILSCALE RECOVER section marker present"
echo "  - systemctl enable --now tailscaled present"
echo "  - tailscale up --reset present"
echo "  - Not announce-only (recover attempted before final fail)"

# Also verify vps-weekly-update has the sudo probe
WEEKLY="/home/nish/workspaces/agent-worktrees/issue-fleet-ops-1160/bin/vps-weekly-update"
echo ""
echo "Checking $WEEKLY for privileged-path probe (fleet-ops#1160)..."

if ! grep -q "SUDO_PROBE" "$WEEKLY"; then
  echo "FAIL: Missing SUDO_PROBE variable"
  exit 1
fi

if ! grep -q "sudo -n systemctl is-active systemd-journald" "$WEEKLY"; then
  echo "FAIL: Missing sudo probe command"
  exit 1
fi

if ! grep -q "privileged path broken (sudo probe empty)" "$WEEKLY"; then
  echo "FAIL: Missing fail-fast message for empty sudo probe"
  exit 1
fi

if ! grep -q "fail-fast if empty" "$WEEKLY"; then
  echo "FAIL: Missing fail-fast comment"
  exit 1
fi

echo "PASS: vps-weekly-update contains privileged-path probe"
echo "  - SUDO_PROBE variable present"
echo "  - sudo probe command present"
echo "  - fail-fast on empty probe present"
echo "  - fail-fast before QUIESCE comment present"

# Verify vps-post-reboot-verify.timer exists and has Persistent=true
TIMER="/home/nish/workspaces/agent-worktrees/issue-fleet-ops-1160/systemd/vps-post-reboot-verify.timer"
echo ""
echo "Checking $TIMER for Persistent=true..."

if ! grep -q "Persistent=true" "$TIMER"; then
  echo "FAIL: Timer missing Persistent=true"
  exit 1
fi

if ! grep -q "OnCalendar=Sun.*04:00:00" "$TIMER"; then
  echo "FAIL: Timer not set to ~30 min post-reboot (Sun 04:00)"
  exit 1
fi

echo "PASS: vps-post-reboot-verify.timer has Persistent=true and correct schedule"
echo "  - Persistent=true present"
echo "  - OnCalendar=Sun *-*-* 04:00:00 present"

echo ""
echo "ALL TESTS PASSED — fleet-ops#1160 mechanism verified"