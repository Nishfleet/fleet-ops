#!/usr/bin/env bash
# tests/pi-intake-tick-dropin.test.sh
#
# Locks the pi-intake@.service drop-in that switches the intake tick from the
# model-based pi-packet-run prompt (prompts/intake.md) to the deterministic
# lib/pi-intake-tick.sh (fleet-ops#1377).  Without this drop-in the repo
# installs the model path and the 50-issue visibility ceiling / empty-output
# no-op failure class that starved the fleet.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

dropin="$repo_root/systemd/pi-intake@.service.d/10-use-tick.conf"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$dropin" ]] || fail "missing drop-in: $dropin"

grep -q '^\[Service\]$' "$dropin" \
  || fail "drop-in must start with [Service]"
grep -q '^Type=oneshot$' "$dropin" \
  || fail "drop-in must set Type=oneshot for the synchronous tick"
grep -q '^ExecStartPre=$' "$dropin" \
  || fail "drop-in must clear the base ExecStartPre (model packet build)"
grep -q '^ExecStart=$' "$dropin" \
  || fail "drop-in must clear the base ExecStart (pi-intake-run %i)"
grep -q '^ExecStart=/home/nish/.local/lib/pi-packet/pi-intake-tick.sh %i$' "$dropin" \
  || fail "drop-in must run the deterministic pi-intake-tick.sh"

grep -Fxq "systemd/pi-intake@.service.d/10-use-tick.conf /home/nish/.config/systemd/user/pi-intake@.service.d/10-use-tick.conf" "$manifest" \
  || fail "MANIFEST must list the drop-in so install.sh ships it"

ok "pi-intake@ drop-in wired to deterministic tick and MANIFESTed (fleet-ops#1377)"
