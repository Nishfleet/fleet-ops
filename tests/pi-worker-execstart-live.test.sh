#!/usr/bin/env bash
# tests/pi-worker-execstart-live.test.sh
#
# fleet-ops#1155 live drill: spawn an odd-named user service whose ExecStart
# command line contains the literal "pi --print", and assert the seat-lib
# counters see it. This is the acceptance test for the class fix: worker
# counts must match by ExecStart content, not unit-name patterns.
#
# Live / destructive: creates and removes a transient systemd user unit.
# Not safe for hosted CI, so it is listed as a live-skip in
# tests/p14-test-listing-gate.test.sh.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"

# --- unique, clearly-test-only unit name -----------------------------------
unit="odd-pi-1155-$(date -u +%s).service"
# Strip trailing .service for systemd-run; it appends it.
unit_base="${unit%.service}"

scratch="$(mktemp -d -t pi-worker-execstart-live.XXXXXX)"
trap 'rm -rf "$scratch"; systemctl --user stop "odd-pi-1155-*.service" 2>/dev/null || true' EXIT INT TERM

# Fake pi binary: sleeps long enough for us to probe, but ignores all args.
# The important thing is the *command line* contains "pi --print".
pi_fake="$scratch/pi-1155-fake"
cat >"$pi_fake" <<'FAKE'
#!/usr/bin/env bash
sleep 5
FAKE
chmod +x "$pi_fake"

# --- spawn the odd-named unit --------------------------------------------
# Use a transient user service with a non-"pi-*" name. ExecStart is the
# fake binary followed by the literal arguments "pi --print --provider ...",
# exactly like an ad-hoc `pi-systemd-run --unit <name> -- ...` invocation.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
systemd-run --user --unit "$unit_base" --collect --no-block \
  "$pi_fake" pi --print --provider devin --model glm-5-2 || fail "systemd-run failed"

# Wait for the unit to reach active/activating (up to 5s).
for _ in {1..25}; do
    state=$(systemctl --user is-active "$unit" 2>/dev/null || echo inactive)
    [[ "$state" == "active" || "$state" == "activating" ]] && break
    sleep 0.2
done
state=$(systemctl --user is-active "$unit" 2>/dev/null || echo inactive)
[[ "$state" == "active" || "$state" == "activating" ]] \
  || fail "unit $unit never became active/activating (state=$state)"

# --- source seat-lib with live systemd probing enabled ---------------------
# Use a scratch seat-caps/models so pick_seat helpers do not fail.
export PI_PACKET_STATE="$scratch/pi-packet"
export ACTIVE_SEATS_DIR="$PI_PACKET_STATE/active-seats"
mkdir -p "$ACTIVE_SEATS_DIR"
export HOME="$scratch/home"
mkdir -p "$HOME"

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "org_reserve": 2,
  "free_providers_in_order": [],
  "prepaid_providers_in_order": ["devin"],
  "providers": {
    "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 3, "swe-1-7": 4 } }
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

cat >"$scratch/models.json" <<'JSON'
{ "providers": { "devin": { "models": [ { "id": "glm-5-2" } ] } } }
JSON
export PI_MODELS_JSON="$scratch/models.json"

# Probe live systemd.
export PI_SEAT_LIB_CHECK_SYSTEMD=1
# shellcheck source=../lib/seat-lib.sh
source "$lib"

# --- assert every counter sees the odd-named unit --------------------------
listed=$(_seat_list_unit)
printf '%s\n' "$listed" | grep -qxF "$unit" \
  || fail "_seat_list_unit must see $unit, got: $listed"
ok "_seat_list_unit sees odd-named $unit"

listed_org=$(_seat_list_org_unit)
printf '%s\n' "$listed_org" | grep -qxF "$unit" \
  || fail "_seat_list_org_unit must see $unit, got: $listed_org"
ok "_seat_list_org_unit sees odd-named $unit"

org=$(count_active_org)
[[ "$org" -ge 1 ]] || fail "count_active_org must be >= 1, got $org"
ok "count_active_org counts the odd-named unit ($org)"

total=$(count_active_total)
[[ "$total" -ge 1 ]] || fail "count_active_total must be >= 1, got $total"
ok "count_active_total counts the odd-named unit ($total)"

per_prov=$(count_active_on_provider devin)
[[ "$per_prov" -ge 1 ]] || fail "count_active_on_provider devin must be >= 1, got $per_prov"
ok "count_active_on_provider devin counts the odd-named unit ($per_prov)"

per_seat=$(count_active_on_seat devin glm-5-2)
[[ "$per_seat" -ge 1 ]] || fail "count_active_on_seat devin/glm-5-2 must be >= 1, got $per_seat"
ok "count_active_on_seat devin/glm-5-2 counts the odd-named unit ($per_seat)"

# count_active_issue should not double-count an org/repair odd-named unit.
issue=$(count_active_issue)
[[ "$issue" == "0" ]] || fail "count_active_issue must be 0 for an org odd-named unit, got $issue"
ok "count_active_issue stays 0 for the org odd-named unit"

echo "ALL OK: odd-named pi --print unit is visible to every seat-lib counter"
