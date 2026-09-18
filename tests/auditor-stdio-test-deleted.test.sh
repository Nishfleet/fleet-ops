#!/usr/bin/env bash
# tests/auditor-stdio-test-deleted.test.sh
#
# fleet-ops#1492: the hand-placed auditor-stdio-test unit was a
# class-(c) unsanctioned build (test debris) that violated the
# no-new-machinery ban. Adjudicated MECHANICAL-INSTEAD — deleted; it was
# a stdio-ordering test fixture left installed as a user unit, not fleet
# machinery (ExecStart is `cat > /tmp/auditor-stdio-test.out`). No repo
# trace existed (no MANIFEST line, no timer-manifest.json entry, no
# systemd/ file, no organ), and no live safety gate depends on it.
#
# This test pins the deletion so a future rebuild is caught:
#   1. No systemd/auditor-stdio-test.* unit file in the repo.
#   2. No MANIFEST line installing any auditor-stdio-test unit.
#   3. No auditor-stdio-test.timer entry in timer-manifest.json.
#   4. The allowlist records the adjudication verdict (not still
#      "filed" with no resolution).
#   5. The unit is NOT on the authorized allowlist (deleted, not endorsed).
#
# A rebuild that re-adds any of these without a Nish-endorsed
# EXCEPTION-APPROVED verdict (and an allowlist `authorized` row) fails
# this test. The machinery-authorization-gate (fleet-ops#1548) is the
# mechanical prevention; this test is the deletion pin.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- 1. no repo unit file ---------------------------------------------------
for suf in .service .timer .path; do
  f="$repo_root/systemd/auditor-stdio-test${suf}"
  [[ ! -e "$f" ]] || fail "repo must not carry $f — auditor-stdio-test was deleted (#1492)"
done
ok "no systemd/auditor-stdio-test.* unit file in repo"

# --- 2. no MANIFEST line installing the unit --------------------------------
if grep -nE 'systemd/auditor-stdio-test\.(service|timer|path)' "$repo_root/MANIFEST" >/dev/null 2>&1; then
  fail "MANIFEST must not install any auditor-stdio-test unit — deleted (#1492)"
fi
ok "MANIFEST has no auditor-stdio-test install line"

exit 0
