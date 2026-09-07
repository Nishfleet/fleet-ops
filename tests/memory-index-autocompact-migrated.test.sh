#!/usr/bin/env bash
# tests/memory-index-autocompact-migrated.test.sh
#
# fleet-ops#1498: the hand-placed memory-index-autocompact maintenance script
# was a class (b) "sanctioned-class, no explicit endorsement" unit from the
# #1480 machinery audit. Adjudicated EXCEPTION-APPROVED — migrated into the
# repo as a sanctioned maintenance script. Distinct from nish-memory-curator
# (vault memory vs Claude auto-memory). The script has tier-1 deterministic
# dedupe + tier-2 Opus headless compaction; path unit triggers on MEMORY.md
# growth.
#
# This test pins the migration so a future regression is caught:
#   1. bin/memory-index-autocompact script exists in the repo.
#   2. systemd/memory-index-autocompact.{service,path} unit files exist in the repo.
#   3. MANIFEST installs the script + both unit files.
#   4. The allowlist records the EXCEPTION-APPROVED verdict (authorized class b).
#   5. The audit report is annotated with the adjudication.
#
# A regression that removes any of these without a Nish-endorsed
# re-adjudication fails this test. The machinery-authorization-gate
# (fleet-ops#1548) is the mechanical prevention; this test is the migration pin.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- 1. repo script file ----------------------------------------------------
f="$repo_root/bin/memory-index-autocompact"
[[ -f "$f" ]] || fail "repo must carry bin/memory-index-autocompact — migrated (#1498)"
[[ -x "$f" ]] || fail "bin/memory-index-autocompact must be executable"
ok "repo carries bin/memory-index-autocompact (executable)"

# --- 2. repo unit files -----------------------------------------------------
for suf in .service .path; do
  f="$repo_root/systemd/memory-index-autocompact${suf}"
  [[ -f "$f" ]] || fail "repo must carry systemd/memory-index-autocompact${suf} — migrated (#1498)"
  # provenance header check
  grep -q "fleet-ops#1498" "$f" || fail "systemd/memory-index-autocompact${suf} must carry fleet-ops#1498 provenance header"
done
ok "repo carries systemd/memory-index-autocompact.{service,path} with provenance"

# --- 3. MANIFEST install lines ----------------------------------------------
for pattern in \
  'bin/memory-index-autocompact /home/nish/.local/bin/memory-index-autocompact' \
  'systemd/memory-index-autocompact.service /home/nish/.config/systemd/user/memory-index-autocompact.service' \
  'systemd/memory-index-autocompact.path /home/nish/.config/systemd/user/memory-index-autocompact.path'; do
  grep -qF "$pattern" "$repo_root/MANIFEST" \
    || fail "MANIFEST must install $pattern — migrated (#1498)"
done
ok "MANIFEST has all three memory-index-autocompact install lines"

# --- 4. allowlist records EXCEPTION-APPROVED (authorized class b) ----------
auth="$(jq -r '.authorized[] | select(.unit=="memory-index-autocompact") | .unit // empty' "$repo_root/config/machinery-allowlist.json")"
[[ -n "$auth" ]] || fail "allowlist must carry memory-index-autocompact in authorized[] (#1498)"
cls="$(jq -r '.authorized[] | select(.unit=="memory-index-autocompact") | .class // empty' "$repo_root/config/machinery-allowlist.json")"
[[ "$cls" == "b" ]] || fail "allowlist memory-index-autocompact class must be b, got '$cls'"
src="$(jq -r '.authorized[] | select(.unit=="memory-index-autocompact") | .source // empty' "$repo_root/config/machinery-allowlist.json")"
[[ "$src" == "repo" ]] || fail "allowlist memory-index-autocompact source must be repo, got '$src'"
ok "allowlist records memory-index-autocompact as authorized class b repo"

# --- 5. allowlist pending_adjudication entry has adjudicated verdict --------
entry="$(jq -c '.pending_adjudication_class_c[] | select(.unit=="memory-index-autocompact")' "$repo_root/config/machinery-allowlist.json")"
[[ -n "$entry" ]] || fail "allowlist must retain the memory-index-autocompact adjudication record"
adj="$(jq -r '.pending_adjudication_class_c[] | select(.unit=="memory-index-autocompact") | .adjudicated // empty' "$repo_root/config/machinery-allowlist.json")"
[[ -n "$adj" ]] || fail "allowlist memory-index-autocompact record must carry an adjudicated verdict (#1498)"
[[ "$adj" == "EXCEPTION-APPROVED" ]] || fail "allowlist memory-index-autocompact adjudicated must be EXCEPTION-APPROVED, got '$adj'"
verdict="$(jq -r '.pending_adjudication_class_c[] | select(.unit=="memory-index-autocompact") | .verdict // empty' "$repo_root/config/machinery-allowlist.json")"
[[ -n "$verdict" ]] || fail "allowlist memory-index-autocompact verdict must be non-empty"
[[ "$verdict" == *"migrated to repo as class (b)"* ]] || fail "allowlist memory-index-autocompact verdict must mention migration to repo class b, got '$verdict'"
ok "allowlist records EXCEPTION-APPROVED verdict for memory-index-autocompact"

# --- 6. audit report annotated ----------------------------------------------
grep -q "ADJUDICATED 2026-08-30: EXCEPTION-APPROVED" "$repo_root/reports/machinery-audit-2026-08-28.md" \
  || fail "reports/machinery-audit-2026-08-28.md must be annotated with EXCEPTION-APPROVED adjudication (#1498)"
ok "audit report annotated with EXCEPTION-APPROVED adjudication"

# --- 7. script validates (basic syntax + shebang) ---------------------------
head -n1 "$repo_root/bin/memory-index-autocompact" | grep -q '^#!/usr/bin/env bash' \
  || fail "bin/memory-index-autocompact must have bash shebang"
bash -n "$repo_root/bin/memory-index-autocompact" \
  || fail "bin/memory-index-autocompact must pass bash -n syntax check"
ok "bin/memory-index-autocompact passes syntax check"

# --- 8. unit files validate (systemd-analyze verify) ------------------------
# Note: systemd-analyze verify needs the target paths to exist. Since the
# binaries are VPS-only, we only verify the unit file syntax here.
systemd-analyze verify "$repo_root/systemd/memory-index-autocompact.service" 2>&1 \
  || fail "systemd/memory-index-autocompact.service must pass systemd-analyze verify"
systemd-analyze verify "$repo_root/systemd/memory-index-autocompact.path" 2>&1 \
  || fail "systemd/memory-index-autocompact.path must pass systemd-analyze verify"
ok "systemd/memory-index-autocompact.{service,path} pass systemd-analyze verify"

exit 0