#!/usr/bin/env bash
# tests/0509-surface-probe-deleted.test.sh
#
# fleet-ops#4150 (child of #4140 row 11): the hand-built 0509-surface-probe
# (~/.local/bin/0509-surface-probe 163 lines, plus fleet-surface-probe-0050
# systemd unit, plus the stale prom writers
# /var/lib/prometheus/node-exporter/fleet-surface-probe-0050.prom and
# fleet-surface-probe-0509.prom) was retired. It was a hand-built
# authenticated surface-matrix probe organ (routes x viewports x themes x
# fixture tiers) duplicating 0509's own CI surface audit. The 0509 repo ships
# e2e/surface-audit.mjs + cross-browser-matrix.yml workflow (nightly +
# on-demand) that covers the same surface.
#
# 0509-surface-probe was live-only (never tracked in this repo). This test
# pins the retirement so a future rebuild is caught:
#   1. No 0509-surface-probe script in the repo's active code dirs
#      (bin/, lib/, libexec/).
#   2. No reference to 0509-surface-probe in active code paths (prompts/,
#      config/, systemd/, MANIFEST).
#   3. The design doc row 11 0509-surface-probe verdict is recorded.
#
# A rebuild that re-adds any of these to active code without a Nish-endorsed
# exception fails this test. The machinery-authorization-gate (fleet-ops#1548)
# is the mechanical prevention; this test is the deletion pin.
#
# Note: tests/canary-effectiveness.test.sh uses "0509-surface-probe" as a
# fixture organ name in a generic canary-effectiveness metric test; that is
# test data, not a live reference, and is allowed.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- 1. no 0509-surface-probe script in active code dirs -------------------
for dir in bin lib libexec; do
  for name in 0509-surface-probe 0050-surface-probe; do
    f="$repo_root/$dir/$name"
    if [[ -e "$f" ]]; then
      fail "active code must not carry $f - 0509-surface-probe was retired (#4150)"
    fi
  done
done
ok "no 0509-surface-probe/0050-surface-probe script in bin/, lib/, libexec/"

# --- 2. no reference in active code paths -----------------------------------
# The design doc (docs/design/hand-built-vs-off-the-shelf.md) is the
# retirement record and is allowed. This test file is also allowed (it
# pins the retirement). tests/canary-effectiveness.test.sh uses the name
# as fixture data and is allowed. Everything else must be clean.
for path in prompts config systemd MANIFEST; do
  if grep -rIn '0509-surface-probe\|0050-surface-probe' \
       "$repo_root/$path" >/dev/null 2>&1; then
    fail "active code path $path must not reference 0509-surface-probe - retired (#4150)"
  fi
done
ok "no reference to 0509-surface-probe in prompts/, config/, systemd/, MANIFEST"

# --- 3. design doc row 11 0509-surface-probe verdict is recorded ------------
if ! grep -q '0509-surface-probe' \
     "$repo_root/docs/design/hand-built-vs-off-the-shelf.md"; then
  fail "design doc row 11 must record the 0509-surface-probe verdict (#4150)"
fi
ok "design doc row 11 records the 0509-surface-probe verdict"

exit 0
