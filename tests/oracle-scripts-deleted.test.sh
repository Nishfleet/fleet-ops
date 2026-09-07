#!/usr/bin/env bash
# tests/oracle-scripts-deleted.test.sh
#
# fleet-ops#4150 (child of #4140 row 11): the hand-built oracle-* scripts
# (~/.local/bin/oracle-arm-fish 147 + ~/.local/bin/oracle-bootstrap-micro 186
# = 333 lines, plus oracle-arm-fish.service/.timer) were retired. They were a
# hand-built OCI Always Free ARM capacity poller + bootstrap provisioner; the
# timer ran every 10 min in standdown (no-arm-env) since 2026-09-07 00:16 IST
# because bootstrap was never run. The off-the-shelf community tool
# hitrov/oci-arm-host-capacity (1305 stars, actively maintained) covers the
# same capacity-grab use case.
#
# oracle-* was live-only (never tracked in this repo). This test pins the
# retirement so a future rebuild is caught:
#   1. No oracle-* script in the repo's active code dirs (bin/, lib/, libexec/).
#   2. No reference to oracle-arm-fish/oracle-bootstrap-micro in active code
#      paths (prompts/, config/, systemd/, MANIFEST).
#   3. The design doc row 11 oracle verdict is recorded.
#
# A rebuild that re-adds any of these to active code without a Nish-endorsed
# exception fails this test. The machinery-authorization-gate (fleet-ops#1548)
# is the mechanical prevention; this test is the deletion pin.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- 1. no oracle-* script in active code dirs -----------------------------
for dir in bin lib libexec; do
  for name in oracle-arm-fish oracle-bootstrap-micro; do
    f="$repo_root/$dir/$name"
    if [[ -e "$f" ]]; then
      fail "active code must not carry $f - oracle-* was retired (#4150)"
    fi
  done
done
ok "no oracle-arm-fish/oracle-bootstrap-micro script in bin/, lib/, libexec/"

# --- 2. no reference in active code paths -----------------------------------
# The design doc (docs/design/hand-built-vs-off-the-shelf.md) is the
# retirement record and is allowed. This test file is also allowed (it
# pins the retirement). Everything else must be clean.
for path in prompts config systemd MANIFEST; do
  if grep -rIn 'oracle-arm-fish\|oracle-bootstrap-micro' \
       "$repo_root/$path" >/dev/null 2>&1; then
    fail "active code path $path must not reference oracle-* - retired (#4150)"
  fi
done
ok "no reference to oracle-* in prompts/, config/, systemd/, MANIFEST"

# --- 3. design doc row 11 oracle verdict is recorded ------------------------
if ! grep -q 'oracle-arm-fish.*oracle-bootstrap-micro' \
     "$repo_root/docs/design/hand-built-vs-off-the-shelf.md"; then
  fail "design doc row 11 must record the oracle verdict (#4150)"
fi
ok "design doc row 11 records the oracle verdict"

exit 0
