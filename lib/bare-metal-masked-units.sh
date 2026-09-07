# shellcheck shell=bash
# bare-metal-masked-units.sh — verify hardware-absent system units are masked.
# Sourced by bin/fleet-bare-metal-rebuild. NOT executed directly.
#
# fleet-ops#2122: a permanently-unstartable hardware unit on a VPS (e.g.
# openipmi.service on a box with no IPMI BMC) re-enters failed state and pages
# SystemUnitFailed every alert cycle. The bare-metal manifest declares these
# units in .masked_units.units[]; apply_rebuild masks them at provision time
# and live_check verifies each is still masked so drift is caught. This helper
# counts how many are NOT masked, so the check is unit-testable without running
# the full live_check (which also touches apt, tailscale, SSH, user units).
#
# Depends on: $MANIFEST_JSON (path to bare-metal-rebuild-manifest.json),
#             $SYSTEMCTL (systemctl binary or test stub),
#             a `log` function that writes one line to stderr.
#
# Prints the count of unmasked units on stdout (0 = all masked). Logs each
# violation via `log`. Exits 0 regardless; the caller adds the count to its
# violation total.
count_unmasked_units() {
  local unit state count=0
  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    state="$("$SYSTEMCTL" is-enabled "$unit" 2>/dev/null || true)"
    if [[ "$state" != "masked" ]]; then
      log "check: masked_units unit not masked: $unit (state=${state:-unknown})"
      count=$((count + 1))
    fi
  done < <(jq -r '.masked_units.units[].name // empty' "$MANIFEST_JSON" 2>/dev/null || true)
  printf '%s\n' "$count"
}
