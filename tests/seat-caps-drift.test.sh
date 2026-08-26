#!/usr/bin/env bash
# tests/seat-caps-drift.test.sh
#
# Locks fleet-ops#156 finding 10: every provider in models.json appears
# in seat-caps.json (cap 0 is an explicit decision; absent is drift).
#
# The detector lives in lib/heartbeat-watchman.sh (jq, keys only — no new
# binary). CI has no live models.json (secrets, not in this repo), so this
# test uses SECRET-FREE fixtures:
#   1. clean: every models.json provider has a seat-caps.json entry -> rc 0
#   2. drift: a models.json provider absent from seat-caps.json -> rc 1,
#      missing provider named in triage
#   3. cap 0 is NOT drift
#   4. missing files skip (rc 0) so CI/scratch does not fail the tick
#   5. a models.json with ONLY provider keys (no apiKey) still works
#   6. live: if ~/.pi/agent/models.json exists, it must match repo
#      config/seat-caps.json (VPS proof; skipped on hosted CI)
#   7. tier1 block 15 is wired to the watchman function

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/heartbeat-watchman.sh"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
chmod +x "$lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-caps-drift.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md"
export FLEET_SEAT_HEALTH="$scratch/seat.json"
export FLEET_SEAT_LEDGER_DIR="$scratch/seats"
: >"$FLEET_HEARTBEAT_TRIAGE"
mkdir -p "$FLEET_SEAT_LEDGER_DIR"

run_wm() { "$lib" "$@"; }

# Secret-free models.json (NO apiKey/baseUrl/headers).
cat >"$scratch/models-clean.json" <<'JSON'
{
  "providers": {
    "devin": { "models": [ { "id": "glm-5-2" } ] },
    "ollama": { "models": [ { "id": "deepseek-v4-flash:0731" } ] },
    "straitly": { "models": [ { "id": "deepseek/deepseek-v4-pro" } ] }
  }
}
JSON

cat >"$scratch/caps-clean.json" <<'JSON'
{
  "providers": {
    "devin":     { "cap": 4, "class": "subscription" },
    "ollama":    { "cap": 2, "class": "free" },
    "straitly":  { "cap": 0, "class": "metered" }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models-clean.json"
export SEAT_CAPS_JSON="$scratch/caps-clean.json"
: >"$FLEET_HEARTBEAT_TRIAGE"
set +e
out="$(run_wm seat-caps-drift 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "clean case must exit 0, got $rc: $out"
grep -q "SEAT-CAPS-DRIFT" "$FLEET_HEARTBEAT_TRIAGE" \
  && fail "clean case must not loud-report: $(cat "$FLEET_HEARTBEAT_TRIAGE")"
ok "clean: all providers present (straitly cap 0 counts) -> rc 0"

# 3. cap 0 is NOT drift — proven above.
ok "cap 0 is an explicit decision, not drift"

# 2. drift: drop straitly from caps
cat >"$scratch/caps-drift.json" <<'JSON'
{
  "providers": {
    "devin":  { "cap": 4, "class": "subscription" },
    "ollama": { "cap": 2, "class": "free" }
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/caps-drift.json"
: >"$FLEET_HEARTBEAT_TRIAGE"
set +e
out="$(run_wm seat-caps-drift 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "drift case must exit 1, got $rc: $out"
grep -q "straitly" "$FLEET_HEARTBEAT_TRIAGE" \
  || fail "drift case must name straitly in triage: $(cat "$FLEET_HEARTBEAT_TRIAGE")"
grep -q "SEAT-CAPS-DRIFT" "$FLEET_HEARTBEAT_TRIAGE" \
  || fail "drift case must loud-report SEAT-CAPS-DRIFT"
ok "drift: absent provider named, rc 1"

# 4. missing models.json -> skip rc 0
export PI_MODELS_JSON="$scratch/nope.json"
export SEAT_CAPS_JSON="$scratch/caps-clean.json"
: >"$FLEET_HEARTBEAT_TRIAGE"
set +e
out="$(run_wm seat-caps-drift 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "missing models.json must skip rc 0, got $rc: $out"
ok "missing models.json -> skip rc 0"

# 5. keys-only models.json (no secrets) against clean caps
cat >"$scratch/models-keysonly.json" <<'JSON'
{ "providers": { "devin": {}, "ollama": {}, "straitly": {} } }
JSON
export PI_MODELS_JSON="$scratch/models-keysonly.json"
export SEAT_CAPS_JSON="$scratch/caps-clean.json"
set +e
out="$(run_wm seat-caps-drift 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "keysonly models.json must exit 0, got $rc: $out"
ok "detector reads only provider keys — secret-free models.json works"

# 6. live VPS check: real models.json vs THIS PR's repo cap-map.
# Hosted CI has no models.json so this is skipped there. Never prints
# secret fields (watchman reads .providers|keys only).
live_models="${HOME}/.pi/agent/models.json"
if [[ -f "$live_models" ]]; then
  export PI_MODELS_JSON="$live_models"
  export SEAT_CAPS_JSON="$repo_root/config/seat-caps.json"
  : >"$FLEET_HEARTBEAT_TRIAGE"
  set +e
  out="$(run_wm seat-caps-drift 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || fail "live models.json drifting vs repo seat-caps.json (rc=$rc): $out triage=$(cat "$FLEET_HEARTBEAT_TRIAGE")"
  ok "live models.json vs repo seat-caps.json is clean"
else
  ok "skip live models.json check (absent — CI runner)"
fi

# 7. repo seat-caps.json has a providers object; straitly is explicit cap 0
jq -e '.providers | keys | length > 0' "$repo_root/config/seat-caps.json" >/dev/null \
  || fail "repo config/seat-caps.json must have a non-empty providers object"
jq -e '.providers.straitly.cap == 0' "$repo_root/config/seat-caps.json" >/dev/null \
  || fail "repo config/seat-caps.json must list straitly at cap 0 (explicit decision)"
ok "repo seat-caps.json lists straitly at cap 0"

# 8. tier1 wiring lock (worker App cannot push .github/workflows/**)
grep -q 'heartbeat_seat_caps_drift_check' "$tier1" \
  || fail "tier1 must call heartbeat_seat_caps_drift_check"
grep -q 'seat_caps_drift_rc' "$tier1" \
  || fail "tier1 must fail-loud on seat-caps drift via seat_caps_drift_rc"
ok "tier1 block 15 wired to watchman seat-caps-drift"

echo
echo "seat-caps-drift detector locked (fleet-ops#156 finding 10)"
