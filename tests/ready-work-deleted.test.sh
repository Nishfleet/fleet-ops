#!/usr/bin/env bash
# tests/ready-work-deleted.test.sh
#
# fleet-ops#1493: the hand-placed ready-work dispatcher trio
# (ready-work.service / ready-work.path / ready-work-recheck.path /
# ready-work-recheck.timer + ~/.local/bin/ready-work-dispatch) was a
# class-(c) unsanctioned build (queue-daemon + dispatcher + poller) that
# violated the no-new-machinery ban (decisions-ledger 2026-08-26).
# Adjudicated MECHANICAL-INSTEAD — deleted; the never-say-next doctrine is
# enforced by layers 1-2 stop-hooks (continuation_judge.py / stop-judge.ts),
# not a dispatcher. Continuation packets route through Pi stock dispatch
# (pi-packet@) per docs/organ-catalog.md "Hand-rolled dispatcher -> Pi stock
# dispatch".
#
# This test pins the deletion so a future rebuild is caught:
#   1. No systemd/ready-work* unit file in the repo.
#   2. No MANIFEST line installing any ready-work unit.
#   3. No ready-work-recheck.timer entry in timer-manifest.json.
#   4. The allowlist records the adjudication verdict (not still
#      "filed" with no resolution).
#   5. ready-work is NOT on the authorized allowlist.
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
  f="$repo_root/systemd/ready-work${suf}"
  [[ ! -e "$f" ]] || fail "repo must not carry $f — ready-work was deleted (#1493)"
done
for suf in .service .timer .path; do
  f="$repo_root/systemd/ready-work-recheck${suf}"
  [[ ! -e "$f" ]] || fail "repo must not carry $f — ready-work-recheck was deleted (#1493)"
done
ok "no systemd/ready-work* or ready-work-recheck* unit file in repo"

# --- 2. no MANIFEST line installing the unit --------------------------------
if grep -nE 'systemd/ready-work(-recheck)?\.(service|timer|path)' "$repo_root/MANIFEST" >/dev/null 2>&1; then
  fail "MANIFEST must not install any ready-work unit — deleted (#1493)"
fi
ok "MANIFEST has no ready-work install line"

# --- 3. no timer-manifest.json entry ----------------------------------------
if jq -e '.timers["ready-work-recheck.timer"]' "$repo_root/systemd/timer-manifest.json" >/dev/null 2>&1; then
  fail "timer-manifest.json must not carry ready-work-recheck.timer — deleted (#1493)"
fi
ok "timer-manifest.json has no ready-work-recheck.timer entry"

# --- 4. allowlist records the adjudication ----------------------------------
entry="$(jq -c '.pending_adjudication_class_c[] | select(.unit=="ready-work")' "$repo_root/config/machinery-allowlist.json")"
[[ -n "$entry" ]] || fail "allowlist must retain the ready-work adjudication record"
adj="$(jq -r '.pending_adjudication_class_c[] | select(.unit=="ready-work") | .adjudicated // empty' "$repo_root/config/machinery-allowlist.json")"
[[ -n "$adj" ]] || fail "allowlist ready-work record must carry an adjudicated verdict (#1493)"
[[ "$adj" == "MECHANICAL-INSTEAD" ]] \
  || fail "allowlist ready-work adjudicated must be MECHANICAL-INSTEAD, got '$adj'"
ok "allowlist records MECHANICAL-INSTEAD verdict for ready-work"

# --- 5. the unit is NOT on the authorized allowlist ------------------------
auth="$(jq -r '.authorized[] | select(.unit=="ready-work") | .unit // empty' "$repo_root/config/machinery-allowlist.json")"
[[ -z "$auth" ]] || fail "ready-work must not appear in the authorized allowlist — it was deleted, not endorsed"
ok "ready-work is not on the authorized allowlist"

# --- 6. organ-catalog names Pi stock dispatch as the dispatcher owner -------
grep -qi 'Pi stock dispatch' "$repo_root/docs/organ-catalog.md" \
  || fail "docs/organ-catalog.md must name Pi stock dispatch as the dispatcher owner"
grep -qi 'Hand-rolled dispatcher' "$repo_root/docs/organ-catalog.md" \
  || fail "docs/organ-catalog.md must name the Hand-rolled dispatcher banned class"
ok "organ-catalog names Pi stock dispatch as the dispatcher owner"

exit 0
