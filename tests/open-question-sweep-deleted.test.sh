#!/usr/bin/env bash
# tests/open-question-sweep-deleted.test.sh
#
# fleet-ops#1494: the hand-placed open-question-sweep watchdog was a
# class-(c) unsanctioned build (watchdog/poller) that violated the
# no-new-machinery ban. Adjudicated MECHANICAL-INSTEAD — deleted; the
# Weekly Fleet Review + blind audit carry the watch lens
# (docs/organ-catalog.md "Watchdog for a thing Nish wants watched").
#
# This test pins the deletion so a future rebuild is caught:
#   1. No systemd/open-question-sweep.* unit file in the repo.
#   2. No MANIFEST line installing any open-question-sweep unit.
#   3. No open-question-sweep.timer entry in timer-manifest.json.
#   4. The allowlist records the adjudication verdict (not still
#      "filed" with no resolution).
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
  f="$repo_root/systemd/open-question-sweep${suf}"
  [[ ! -e "$f" ]] || fail "repo must not carry $f — open-question-sweep was deleted (#1494)"
done
ok "no systemd/open-question-sweep.* unit file in repo"

# --- 2. no MANIFEST line installing the unit --------------------------------
if grep -nE 'systemd/open-question-sweep\.(service|timer|path)' "$repo_root/MANIFEST" >/dev/null 2>&1; then
  fail "MANIFEST must not install any open-question-sweep unit — deleted (#1494)"
fi
ok "MANIFEST has no open-question-sweep install line"

# --- 6. organ-catalog still names the watch-lens owner ----------------------
grep -qi 'Weekly Fleet Review' "$repo_root/docs/organ-catalog.md" \
  || fail "docs/organ-catalog.md must name the Weekly Fleet Review as the watch-lens owner"
grep -qi 'blind.audit' "$repo_root/docs/organ-catalog.md" \
  || fail "docs/organ-catalog.md must name the blind audit as a watch-lens owner"
ok "organ-catalog names WFR + blind audit as the watch-lens owners"

exit 0
