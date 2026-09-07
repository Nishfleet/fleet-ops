#!/usr/bin/env bash
# tests/hermes-staff-deleted.test.sh
#
# fleet-ops#4150 (child of #4140 row 11): the hand-built hermes-staff
# generator (~/.local/libexec/hermes-staff/ — gen_hermes_staff.py 147 +
# run-agent 54 + run-script 61 + run-common.sh 97 = 359 lines + jobs/ +
# prompts/, plus ~/.local/state/hermes-staff/ and 13 orphan
# stamp-hermes-staff-*.timer) was retired. It was a hand-built systemd-twin
# generator for hermes cron agent/script jobs, orphaned (generated units
# gone from systemd, ~/.hermes/cron/jobs.json empty since 2026-08-26, last
# run logs 2026-08-23). The scheduling it duplicated is owned by hermes
# cron (built into the hermes CLI, gateway live).
#
# hermes-staff was live-only (never tracked in this repo). This test pins
# the retirement so a future rebuild is caught:
#   1. No hermes-staff script/dir in the repo's active code dirs
#      (bin/, lib/, libexec/).
#   2. No reference to hermes-staff in active code paths (prompts/,
#      config/, systemd/, MANIFEST).
#   3. The design doc row 11 is marked DONE.
#
# A rebuild that re-adds any of these to active code without a Nish-endorsed
# exception fails this test. The machinery-authorization-gate (fleet-ops#1548)
# is the mechanical prevention; this test is the deletion pin.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- 1. no hermes-staff script/dir in active code dirs ---------------------
for dir in bin lib libexec; do
  f="$repo_root/$dir/hermes-staff"
  if [[ -e "$f" ]]; then
    fail "active code must not carry $f - hermes-staff was retired (#4150)"
  fi
  f="$repo_root/$dir/hermes-staff/gen_hermes_staff.py"
  if [[ -e "$f" ]]; then
    fail "active code must not carry $f - hermes-staff was retired (#4150)"
  fi
done
ok "no hermes-staff script/dir in bin/, lib/, libexec/"

# --- 2. no reference in active code paths -----------------------------------
# The design doc (docs/design/hand-built-vs-off-the-shelf.md) is the
# retirement record and is allowed. This test file is also allowed (it
# pins the retirement). Everything else must be clean.
for path in prompts config systemd MANIFEST; do
  if grep -rIn 'hermes-staff' "$repo_root/$path" >/dev/null 2>&1; then
    fail "active code path $path must not reference hermes-staff - retired (#4150)"
  fi
done
ok "no reference to hermes-staff in prompts/, config/, systemd/, MANIFEST"

# --- 3. design doc row 11 is marked DONE -----------------------------------
if ! grep -q 'row 11.*DONE\|11.*memory-index-dedupe.*DONE' \
     "$repo_root/docs/design/hand-built-vs-off-the-shelf.md"; then
  fail "design doc row 11 must be marked DONE (#4150)"
fi
ok "design doc row 11 is marked DONE"

exit 0
