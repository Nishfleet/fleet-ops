#!/usr/bin/env bash
# tests/quality-baseline-research-deleted.test.sh
#
# fleet-ops#1497: the hand-placed quality-baseline-research dispatcher
# (quality-baseline-research.service / quality-baseline-research.timer +
# ~/.local/bin/quality-baseline-refresh) was a class-(c) unsanctioned build
# (hand-rolled dispatcher) that violated the no-new-machinery ban
# (decisions-ledger 2026-08-26). Adjudicated MECHANICAL-INSTEAD — deleted;
# quality research is owned by the sanctioned quality-research-weekly
# (class (a), repo-sourced) per docs/organ-catalog.md "Hand-rolled
# dispatcher -> Pi stock dispatch". Both runs (2026-08-25, 2026-08-28)
# produced SKIP-WITH-NUDGE — zero research ran because no gate the rotation
# loop depends on is live. visual-quality-waves.md stays (it is the canonical
# never-say-next SENIOR-AUDITOR escalation-layer program doc, referenced by
# stop-escalation-dispatch / escalation-daily-sweep / memory-index-autocompact);
# only the dispatcher was deleted. Same shape as the ready-work dispatcher
# adjudication (#1493).
#
# This test pins the deletion so a future rebuild is caught:
#   1. No systemd/quality-baseline-research* unit file in the repo.
#   2. No MANIFEST line installing any quality-baseline-research unit.
#   3. No quality-baseline-research.timer entry in timer-manifest.json.
#   4. The allowlist records the adjudication verdict (not still
#      "filed" with no resolution).
#   5. quality-baseline-research is NOT on the authorized allowlist.
#   6. organ-catalog names Pi stock dispatch as the dispatcher owner.
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
  f="$repo_root/systemd/quality-baseline-research${suf}"
  [[ ! -e "$f" ]] || fail "repo must not carry $f — quality-baseline-research was deleted (#1497)"
done
ok "no systemd/quality-baseline-research* unit file in repo"

# --- 2. no MANIFEST line installing the unit --------------------------------
if grep -nE 'systemd/quality-baseline-research\.(service|timer|path)' "$repo_root/MANIFEST" >/dev/null 2>&1; then
  fail "MANIFEST must not install any quality-baseline-research unit — deleted (#1497)"
fi
ok "MANIFEST has no quality-baseline-research install line"

# --- 3. no timer-manifest.json entry ----------------------------------------
if jq -e '.timers["quality-baseline-research.timer"]' "$repo_root/systemd/timer-manifest.json" >/dev/null 2>&1; then
  fail "timer-manifest.json must not carry quality-baseline-research.timer — deleted (#1497)"
fi
ok "timer-manifest.json has no quality-baseline-research.timer entry"

# --- 4. allowlist records the adjudication ----------------------------------
entry="$(jq -c '.pending_adjudication_class_c[] | select(.unit=="quality-baseline-research")' "$repo_root/config/machinery-allowlist.json")"
[[ -n "$entry" ]] || fail "allowlist must retain the quality-baseline-research adjudication record"
adj="$(jq -r '.pending_adjudication_class_c[] | select(.unit=="quality-baseline-research") | .adjudicated // empty' "$repo_root/config/machinery-allowlist.json")"
[[ -n "$adj" ]] || fail "allowlist quality-baseline-research record must carry an adjudicated verdict (#1497)"
[[ "$adj" == "MECHANICAL-INSTEAD" ]] \
  || fail "allowlist quality-baseline-research adjudicated must be MECHANICAL-INSTEAD, got '$adj'"
ok "allowlist records MECHANICAL-INSTEAD verdict for quality-baseline-research"

# --- 5. the unit is NOT on the authorized allowlist ------------------------
auth="$(jq -r '.authorized[] | select(.unit=="quality-baseline-research") | .unit // empty' "$repo_root/config/machinery-allowlist.json")"
[[ -z "$auth" ]] || fail "quality-baseline-research must not appear in the authorized allowlist — it was deleted, not endorsed"
ok "quality-baseline-research is not on the authorized allowlist"

# --- 6. organ-catalog names Pi stock dispatch as the dispatcher owner -------
grep -qi 'Pi stock dispatch' "$repo_root/docs/organ-catalog.md" \
  || fail "docs/organ-catalog.md must name Pi stock dispatch as the dispatcher owner"
grep -qi 'Hand-rolled dispatcher' "$repo_root/docs/organ-catalog.md" \
  || fail "docs/organ-catalog.md must name the Hand-rolled dispatcher banned class"
ok "organ-catalog names Pi stock dispatch as the dispatcher owner"

exit 0
