#!/usr/bin/env bash
# tests/pi-transport-check-dropin-428.test.sh
#
# fleet-ops#428: pi-transport-check.service lives in the pi package, but its
# live OnFailure= was wired to the old direct Telegram page. The fleet-ops
# drop-in clears the notify and keeps only unit-escalation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
manifest="$repo_root/MANIFEST"
dropin="$repo_root/systemd/pi-transport-check.service.d/10-no-direct-notify.conf"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$dropin" ]] || fail "missing drop-in: $dropin"
grep -Fxq "systemd/pi-transport-check.service.d/10-no-direct-notify.conf /home/nish/.config/systemd/user/pi-transport-check.service.d/10-no-direct-notify.conf" "$manifest" \
  || fail "MANIFEST missing pi-transport-check drop-in"
ok "drop-in exists and is MANIFESTed"

grep -q '^\[Unit\]$' "$dropin" || fail "drop-in must have [Unit]"
grep -q '^OnFailure=$' "$dropin" || fail "drop-in must reset OnFailure"
grep -q '^OnFailure=unit-escalation@%n.service$' "$dropin" \
  || fail "drop-in must keep only unit-escalation OnFailure"
ok "drop-in clears direct notify and keeps unit-escalation"

ok "pi-transport-check-428: drop-in shape locked"
