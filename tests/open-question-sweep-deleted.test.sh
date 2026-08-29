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

# --- 3. no timer-manifest.json entry ----------------------------------------
if jq -e '.timers["open-question-sweep.timer"]' "$repo_root/systemd/timer-manifest.json" >/dev/null 2>&1; then
  fail "timer-manifest.json must not carry open-question-sweep.timer — deleted (#1494)"
fi
ok "timer-manifest.json has no open-question-sweep.timer entry"

# --- 4. allowlist records the adjudication ----------------------------------
entry="$(jq -c '.pending_adjudication_class_c[] | select(.unit=="open-question-sweep")' "$repo_root/config/machinery-allowlist.json")"
[[ -n "$entry" ]] || fail "allowlist must retain the open-question-sweep adjudication record"
adj="$(jq -r '.pending_adjudication_class_c[] | select(.unit=="open-question-sweep") | .adjudicated // empty' "$repo_root/config/machinery-allowlist.json")"
[[ -n "$adj" ]] || fail "allowlist open-question-sweep record must carry an adjudicated verdict (#1494)"
[[ "$adj" == "MECHANICAL-INSTEAD" ]] \
  || fail "allowlist open-question-sweep adjudicated must be MECHANICAL-INSTEAD, got '$adj'"
ok "allowlist records MECHANICAL-INSTEAD verdict for open-question-sweep"

# --- 5. the unit is NOT on the authorized allowlist ------------------------
auth="$(jq -r '.authorized[] | select(.unit=="open-question-sweep") | .unit // empty' "$repo_root/config/machinery-allowlist.json")"
[[ -z "$auth" ]] || fail "open-question-sweep must not appear in the authorized allowlist — it was deleted, not endorsed"
ok "open-question-sweep is not on the authorized allowlist"

# --- 6. organ-catalog still names the watch-lens owner ----------------------
grep -qi 'Weekly Fleet Review' "$repo_root/docs/organ-catalog.md" \
  || fail "docs/organ-catalog.md must name the Weekly Fleet Review as the watch-lens owner"
grep -qi 'blind.audit' "$repo_root/docs/organ-catalog.md" \
  || fail "docs/organ-catalog.md must name the blind audit as a watch-lens owner"
ok "organ-catalog names WFR + blind audit as the watch-lens owners"

exit 0
