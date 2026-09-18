#!/usr/bin/env bash
# tests/pi-transport-check-dropin-428.test.sh
#
# fleet-ops#428: pi-transport-check.service lives in the pi package, but its
# live OnFailure= was wired to the old direct Telegram page. The fleet-ops
# drop-in resets OnFailure. Second cut 2026-09-18: the notify target
# (fleet-heartbeat-failed-notify.service) was deleted with the heartbeat tower,
# so 10-no-direct-notify.conf folded into 20-self-heal.conf — the reset now
# blanks OnFailure outright and this unit's own ExecStart is the repair. The
# base unit is owned by the pi package and still names the deleted service, so
# the reset must survive or the OnFailure dangles.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
manifest="$repo_root/MANIFEST"
dropin="$repo_root/systemd/pi-transport-check.service.d/20-self-heal.conf"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$dropin" ]] || fail "missing drop-in: $dropin"
grep -Fxq "systemd/pi-transport-check.service.d/20-self-heal.conf /home/nish/.config/systemd/user/pi-transport-check.service.d/20-self-heal.conf" "$manifest" \
  || fail "MANIFEST missing pi-transport-check drop-in"
ok "drop-in exists and is MANIFESTed"

grep -q '^\[Unit\]$' "$dropin" || fail "drop-in must have [Unit]"
grep -q '^OnFailure=$' "$dropin" || fail "drop-in must reset OnFailure"
grep -qE '^OnFailure=.+' "$dropin" \
  && fail "drop-in must not name any OnFailure target — the reset is the point"
grep -q '^ExecStart=/home/nish/.local/bin/pi-transport-self-heal$' "$dropin" \
  || fail "drop-in must keep the self-heal ExecStart (the repair)"
ok "drop-in blanks OnFailure and keeps the self-heal ExecStart"

ok "pi-transport-check-428: drop-in shape locked"
