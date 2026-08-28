#!/usr/bin/env bash
# tests/stop-escalation-writer-class-gate.test.sh
#
# fleet-ops#1534: locks the writer class-gate in bin/stop-escalation-dispatch.
# The write_nish helper routes a line to NISH-ESCALATIONS.md ONLY if its class
# is a sanctioned Nish-reserved boundary class (MONEY-BOUNDARY, etc.). A
# non-boundary class (CAP-REACHED, KILL-ESCALATION) goes to AUDITOR-LOG.md
# only — it folds into the daily digest, not the phone. This stops the leak
# class where a CAP-REACHED/KILL-ESCALATION line pollutes NISH-ESCALATIONS.md
# (the file nish-boundary-notify scans for classes that page Nish).
#
# This is a static shape check (no live dispatch). It greps the script for:
#   1. write_nish helper exists with the NISH_CLASSES allowlist
#   2. no direct >> "$NISH" writes outside write_nish
#   3. CAP-REACHED and KILL-ESCALATION are routed via write_nish (not direct)
#   4. LADDER-WALLED is tagged MONEY-BOUNDARY (sanctioned) via write_nish
#   5. the NISH_CLASSES allowlist matches the nish-boundary-notify CLASSES set
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
dispatch="$repo_root/bin/stop-escalation-dispatch"
notify="$repo_root/bin/nish-boundary-notify"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$dispatch" ]] || fail "missing: $dispatch"
[[ -x "$dispatch" ]] || fail "not executable: $dispatch"

# --- 1. write_nish helper exists ---
grep -q '^write_nish()' "$dispatch" || fail "write_nish helper not defined"
grep -q 'NISH_CLASSES=' "$dispatch" || fail "NISH_CLASSES allowlist not defined"
ok "write_nish helper + NISH_CLASSES allowlist present"

# --- 2. no direct >> "$NISH" writes outside write_nish ---
# The only >> "$NISH" line should be inside write_nish itself.
direct_nish_writes=$(grep -c '>> "\$NISH"' "$dispatch" || true)
# write_nish has exactly one >> "$NISH" line (the sanctioned-class branch).
[[ "$direct_nish_writes" == "1" ]] \
  || fail "expected exactly 1 >> \"\$NISH\" line (inside write_nish), got $direct_nish_writes"
ok "only write_nish writes to \$NISH (no direct writes outside the helper)"

# --- 3. CAP-REACHED routed via write_nish ---
grep -q 'write_nish "CAP-REACHED"' "$dispatch" \
  || fail "CAP-REACHED must be routed via write_nish (not direct >> \$NISH)"
# And it must NOT have a direct >> "$NISH" write for CAP-REACHED.
! grep -q 'CAP-REACHED.*>> "\$NISH"' "$dispatch" \
  || fail "CAP-REACHED must NOT have a direct >> \$NISH write"
ok "CAP-REACHED routed via write_nish (auditor path, not NISH)"

# --- 4. KILL-ESCALATION routed via write_nish ---
grep -q 'write_nish "KILL-ESCALATION"' "$dispatch" \
  || fail "KILL-ESCALATION must be routed via write_nish"
! grep -q 'KILL-ESCALATION.*>> "\$NISH"' "$dispatch" \
  || fail "KILL-ESCALATION must NOT have a direct >> \$NISH write"
ok "KILL-ESCALATION routed via write_nish (auditor path, not NISH)"

# --- 5. LADDER-WALLED tagged MONEY-BOUNDARY via write_nish ---
grep -q 'write_nish "MONEY-BOUNDARY"' "$dispatch" \
  || fail "walled ladder must be tagged MONEY-BOUNDARY via write_nish"
grep -q 'reason=ladder-walled' "$dispatch" \
  || fail "MONEY-BOUNDARY line for walled ladder must carry reason=ladder-walled"
# The old LADDER-WALLED token must NOT appear as a direct NISH write.
! grep -q 'LADDER-WALLED.*>> "\$NISH"' "$dispatch" \
  || fail "LADDER-WALLED must NOT be written directly to \$NISH (tagged MONEY-BOUNDARY now)"
ok "walled ladder tagged MONEY-BOUNDARY via write_nish (sanctioned, pages Nish)"

# --- 6. NISH_CLASSES allowlist matches nish-boundary-notify CLASSES set ---
# Extract NISH_CLASSES from stop-escalation-dispatch.
nish_classes_line=$(grep -E '^NISH_CLASSES=' "$dispatch" | head -1)
nish_classes="${nish_classes_line#NISH_CLASSES=}"
nish_classes="${nish_classes#\"}"
nish_classes="${nish_classes%\"}"
nish_classes="${nish_classes#*\:-}"  # strip default prefix if any
# Re-extract cleanly: take the default value (after :-)
nish_classes=$(printf '%s' "$nish_classes_line" | sed -E 's/^NISH_CLASSES="\$\{[^}]*:-([^}]*)\}"/\1/')

# Extract CLASSES from nish-boundary-notify.
classes_line=$(grep -E '^CLASSES=' "$notify" | head -1)
classes="${classes_line#CLASSES=}"
classes="${classes#\'}"
classes="${classes%\'}"

# Every token in NISH_CLASSES must appear in CLASSES (the writer allowlist is a
# subset of the notify allowlist — a class the writer accepts must be one the
# notify path can match and page).
IFS='|' read -ra nish_tokens <<< "$nish_classes"
IFS='|' read -ra notify_tokens <<< "$classes"
for nt in "${nish_tokens[@]}"; do
  found=0
  for ct in "${notify_tokens[@]}"; do
    if [[ "$nt" == "$ct" ]]; then found=1; break; fi
  done
  [[ "$found" == "1" ]] \
    || fail "NISH_CLASSES token '$nt' not in nish-boundary-notify CLASSES (writer would accept a class the notify path cannot page)"
done
ok "NISH_CLASSES allowlist is a subset of nish-boundary-notify CLASSES"

# --- 7. write_nish routes non-boundary classes to LOG (auditor path) ---
# The write_nish function body must contain a >> "$LOG" line (the non-boundary
# branch). Grep the function body (from write_nish() to the closing }).
write_nish_body=$(sed -n '/^write_nish()/,/^}/p' "$dispatch")
printf '%s' "$write_nish_body" | grep -q '>> "\$LOG"' \
  || fail "write_nish must route non-boundary classes to \$LOG (auditor path)"
ok "write_nish routes non-boundary classes to \$LOG (auditor path)"

echo
echo "stop-escalation-writer-class-gate: all invariants pass (fleet-ops#1534)"
