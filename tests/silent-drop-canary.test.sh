#!/usr/bin/env bash
# Silent-drop canary (fleet PR 2026-09-11, Nish: "EVERY FINDING WILL BE QUEUED
# FOR FIXING AND NOT DROPPED SILENTLY? NO DUCT TAPE ANYWHERE!!!").
#
# Greps bin/ and lib/ (repo-canonical; the vendored mirror under lib/pi-packet
# and installed copies under ~/.local/bin + ~/.local/lib/pi-packet are deploy
# surfaces, not sources of truth) for two textual drop patterns:
#
#   1. a findings/work-item cap token: MAX_FINDINGS / MAX_FILINGS /
#      MAX_ISSUES / MAX_ACTIONS / auto_file_cap
#   2. a single-line `gh ["$GH"] issue comment|create|edit ... || true`
#      (a comment or filing call whose failure is swallowed)
#
# Any hit must either be allowlisted below (with a matching row in
# docs/silent-drop-ledger.md) or the test fails. Adding code with the pattern
# without editing the allowlist + ledger is the signal the check exists for.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
LEDGER="docs/silent-drop-ledger.md"
fail=0

# Explicit allowlist — every entry must have a row in docs/silent-drop-ledger.md.
CAP_ALLOWLIST=(
  "bin/fleet-blind-audit"          # AUDIT_MAX_FINDINGS filing cap; carry-over ledger fix in flight (unit blind-audit-cap-fix-2)
  "bin/fleet-rulebook-redteam"     # RULEBOOK_MAX_FINDINGS=5 findings per report; ledger row (queued)
  "bin/fleet-role-gate-audit"      # auto_file_cap_per_tick (row role-gate)
  "bin/fleet-escalation-canary"    # auto_file_cap_per_tick; LOUD PENDING + rows re-derived each tick (by-design)
  "lib/rule-enforcement.py"        # defines auto_file_cap_per_tick in the matrix parser (by-design)
  "lib/scout-money-path-walk.mjs"  # MAX_FINDINGS=4; LOUD suppressed count (fixed 2026-09-11)
)
DROP_ALLOWLIST=(
  "bin/lifecycle-label-sweep"      # 4 comment-only `|| true` notices (queued issue)
  "lib/pi-intake-tick.sh"          # observe-to-close park comments; park re-derived next tick (by-design)
  "lib/spec-judge.sh"              # judge failure-fallback + apply-step comments (queued issue)
)
# Fix assertions (introduced by the 2026-09-11 sweep PR). New `|| true` drops
# in these files must never come back.
MUST_STAY_CLEAN=(
  "bin/claim-reconcile"
  "lib/fleet-questions.sh"
)

say(){ printf '%s\n' "$*"; }
fail_row(){
  say "FAIL: $1"
  fail=1
}

check_pattern(){
  local -n allow=$1; shift
  local label=$1; shift
  local re=$1
  local datasrc=(bin lib)
  local seen
  seen=$(grep -rlE "$re" "${datasrc[@]}" 2>/dev/null | grep -v 'lib/pi-packet/' | grep -v '__pycache__/' | sort || true)
  local f ok
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    ok=0
    for allow_n in "${allow[@]}"; do
      [ "$f" = "${allow_n%%:*}" ] && ok=1
    done
    if [ "$ok" -ne 1 ]; then
      fail_row "new silent-drop pattern ($label) in $f — not in the 2026-09-11 allowlist."
      say "      Either remove the drop, or add the file to $0 ALLOWLIST AND a row to $LEDGER."
    fi
  done <<<"$seen"
  # every allowlisted file must be referenced in the durable ledger
  for allow_n in "${allow[@]}"; do
    f="${allow_n%%:*}"
    if ! grep -qF "$f" "$LEDGER" 2>/dev/null; then
      fail_row "allowlisted file $f has no row in $LEDGER"
    fi
  done
}

check_pattern CAP_ALLOWLIST  "findings-cap token" 'MAX_(FINDINGS|FILINGS|ISSUES|ACTIONS)|auto_file_cap'
check_pattern DROP_ALLOWLIST "gh-issue-write || true" 'issue (comment|create|edit) .*\|\| true'

for f in "${MUST_STAY_CLEAN[@]}"; do
  if grep -nE 'issue (comment|create|edit) .*\|\| true' "$f" >/dev/null 2>&1; then
    fail_row "$f reintroduced an 'gh issue ... || true' silent drop (fixed in the 2026-09-11 sweep)"
  fi
done
grep -q 'suppressedFindings' lib/scout-money-path-walk.mjs \
  || fail_row "lib/scout-money-path-walk.mjs lost the LOUD suppressed-findings counter (silent-drop sweep 2026-09-11)"
[ -f "$LEDGER" ] || fail_row "$LEDGER missing"

if [ "$fail" -eq 0 ]; then
  say "silent-drop canary: PASS ($(printf '%s\n' "${CAP_ALLOWLIST[@]}" | wc -l | tr -d ' ') cap allowlist entries, $(printf '%s\n' "${DROP_ALLOWLIST[@]}" | wc -l | tr -d ' ') drop allowlist entries)"
fi
exit "$fail"
