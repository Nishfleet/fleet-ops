#!/usr/bin/env bash
# tests/fleet-geo-aeo.test.sh
#
# Proves the GEO/AEO canary (fleet-ops#1245) offline:
#   1. Production policy + worker.md + scan -> exit 0, GEO-AEO-OK.
#   2. Missing policy -> exit 1.
#   3. parked tactic leaked into allowed_tactics -> exit 1.
#   4. Wrong brand_gate -> exit 1.
#   5. Wrong llms_txt -> exit 1.
#   6. Worker.md missing a locked needle -> exit 1.
#   7. Grant without granted_by=nish -> exit 1.
#   8. Surface without nish_preview_approved -> exit 1.
#   9. bin/ fixture with oauth.reddit.com -> exit 1.
#  10. Valid Nish grant + previewed surface -> exit 0.
#  11. Heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it.
#  12. Matrix row is enforced with mechanism+proof.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-geo-aeo-canary"
lib="$repo_root/lib/geo-aeo.py"
policy="$repo_root/config/geo-aeo-policy.json"
worker="$repo_root/prompts/worker.md"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
matrix="$repo_root/config/rule-enforcement.json"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$policy" ]] || fail "missing $policy"
[[ -f "$worker" ]] || fail "missing $worker"
[[ -f "$tier1" ]] || fail "missing $tier1"
[[ -f "$matrix" ]] || fail "missing $matrix"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch="$(mktemp -d -t geo-aeo-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"

base_policy() {
  cat >"$scratch/policy.json"
}

clean_policy() {
  base_policy <<'JSON'
{
  "allowed_tactics": ["measurement", "owned-content"],
  "parked_tactics": ["reddit-community", "digital-pr"],
  "brand_gate": "preview-then-autonomous",
  "llms_txt": "developer-docs-only",
  "measurement_issues": [1236],
  "owned_content_issues": [1237, 1238],
  "approved_surfaces": [],
  "grants": []
}
JSON
}

clean_worker() {
  cat >"$scratch/worker.md" <<'EOF'
Hard rules:
GEO/AEO: fleet executes measurement and owned-content tactics only.
Brand gate is preview-then-autonomous.
PARKED: Reddit/community and digital-PR.
llms.txt: skip except developer docs.
EOF
}

run_canary() {
  FLEET_GEO_AEO_POLICY="${1:-$scratch/policy.json}" \
  FLEET_GEO_AEO_WORKER="${2:-$scratch/worker.md}" \
  FLEET_GEO_AEO_SCAN_ROOT="${3:-$scratch/scan}" \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
  "$bin" 2>&1
}

mkdir -p "$scratch/scan/bin" "$scratch/scan/systemd"
clean_policy
clean_worker
echo '# empty' >"$scratch/scan/bin/ok.sh"

# --- 1. production ----------------------------------------------------------
: >"$triage"
set +e
prod_out=$(
  FLEET_GEO_AEO_POLICY="$policy" \
  FLEET_GEO_AEO_WORKER="$worker" \
  FLEET_GEO_AEO_SCAN_ROOT="$repo_root" \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
  "$bin" 2>&1
)
prod_rc=$?
set -e
[[ "$prod_rc" == "0" ]] || fail "scenario1: production must be clean, got rc=$prod_rc ($prod_out)"
grep -q 'GEO-AEO-OK' <<<"$prod_out" || fail "scenario1: production must log OK ($prod_out)"
ok "scenario1: production policy+worker+scan is clean"

# --- 2. missing policy ------------------------------------------------------
: >"$triage"
set +e
out=$(run_canary "$scratch/missing.json" "$scratch/worker.md" "$scratch/scan")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario2: missing policy must exit 1, got $rc ($out)"
grep -q 'GEO-AEO-REJECT' <<<"$out" || fail "scenario2: must REJECT ($out)"
ok "scenario2: missing policy is fail-loud"

# --- 3. parked tactic in allowed_tactics ------------------------------------
clean_policy
jq '.allowed_tactics += ["reddit-community"]' "$scratch/policy.json" >"$scratch/p3.json"
set +e
out=$(run_canary "$scratch/p3.json")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario3: leaked parked tactic must exit 1, got $rc ($out)"
grep -q 'allowed_tactics' <<<"$out" || fail "scenario3: must name allowed_tactics ($out)"
ok "scenario3: parked tactic cannot join allowed_tactics"

# --- 4. wrong brand_gate ----------------------------------------------------
clean_policy
jq '.brand_gate = "autonomous-from-day-one"' "$scratch/policy.json" >"$scratch/p4.json"
set +e
out=$(run_canary "$scratch/p4.json")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario4: wrong brand_gate must exit 1, got $rc ($out)"
grep -q 'brand_gate' <<<"$out" || fail "scenario4: must name brand_gate ($out)"
ok "scenario4: brand_gate is locked to preview-then-autonomous"

# --- 5. wrong llms_txt ------------------------------------------------------
clean_policy
jq '.llms_txt = "everywhere"' "$scratch/policy.json" >"$scratch/p5.json"
set +e
out=$(run_canary "$scratch/p5.json")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario5: wrong llms_txt must exit 1, got $rc ($out)"
grep -q 'llms_txt' <<<"$out" || fail "scenario5: must name llms_txt ($out)"
ok "scenario5: llms_txt is locked to developer-docs-only"

# --- 6. worker.md missing needle --------------------------------------------
printf 'no geo rules here\n' >"$scratch/worker-empty.md"
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/worker-empty.md")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario6: missing worker needles must exit 1, got $rc ($out)"
grep -q 'worker.md missing' <<<"$out" || fail "scenario6: must name worker.md ($out)"
ok "scenario6: worker.md must keep the GEO/AEO needles"

# --- 7. grant without Nish --------------------------------------------------
clean_policy
jq '.grants = [{"tactic":"reddit-community","granted_by":"fleet","granted_on":"2026-08-27"}]' \
  "$scratch/policy.json" >"$scratch/p7.json"
set +e
out=$(run_canary "$scratch/p7.json")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario7: non-Nish grant must exit 1, got $rc ($out)"
grep -q 'granted_by' <<<"$out" || fail "scenario7: must name granted_by ($out)"
ok "scenario7: grants require granted_by=nish"

# --- 8. surface without preview ---------------------------------------------
clean_policy
jq '.approved_surfaces = [{"name":"0509-stats","nish_preview_approved":false,"approved_on":"2026-08-27"}]' \
  "$scratch/policy.json" >"$scratch/p8.json"
set +e
out=$(run_canary "$scratch/p8.json")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario8: unpreviewed surface must exit 1, got $rc ($out)"
grep -q 'nish_preview_approved' <<<"$out" || fail "scenario8: must name nish_preview_approved ($out)"
ok "scenario8: public surfaces need Nish preview"

# --- 9. reddit API in bin/ --------------------------------------------------
clean_policy
clean_worker
printf 'curl https://oauth.reddit.com/api/submit\n' >"$scratch/scan/bin/post-reddit.sh"
set +e
out=$(run_canary)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario9: reddit API in bin/ must exit 1, got $rc ($out)"
grep -q 'oauth.reddit.com' <<<"$out" || fail "scenario9: must name oauth.reddit.com ($out)"
ok "scenario9: Reddit API posting machinery is fail-loud"
rm -f "$scratch/scan/bin/post-reddit.sh"

# --- 10. valid Nish grant + previewed surface -------------------------------
clean_policy
jq '.grants = [{"tactic":"digital-pr","granted_by":"nish","granted_on":"2026-08-27"}]
    | .approved_surfaces = [{"name":"0509-stats","nish_preview_approved":true,"approved_on":"2026-08-27"}]' \
  "$scratch/policy.json" >"$scratch/p10.json"
set +e
out=$(run_canary "$scratch/p10.json")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario10: valid grant+surface must exit 0, got $rc ($out)"
grep -q 'GEO-AEO-OK' <<<"$out" || fail "scenario10: must log OK ($out)"
ok "scenario10: Nish-dated grant and previewed surface pass"

# --- 11. heartbeat + MANIFEST -----------------------------------------------
grep -F 'fleet-geo-aeo-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-geo-aeo-canary"
grep -F 'geo_aeo_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture geo_aeo_canary_rc"
grep -F -- 'exit "$geo_aeo_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the GEO/AEO gate fails loud"
grep -F 'require_manifest_helper "$GEO_AEO_CANARY_BIN"' "$tier1" >/dev/null \
  || fail "tier1 GEO/AEO block must call require_manifest_helper"
grep -F 'HELPER-MISSING' "$tier1" >/dev/null \
  || fail "tier1 must emit HELPER-MISSING"
grep -Fxq 'bin/fleet-geo-aeo-canary /home/nish/.local/bin/fleet-geo-aeo-canary' "$manifest" \
  || fail "MANIFEST must install bin/fleet-geo-aeo-canary"
grep -Fxq 'lib/geo-aeo.py /home/nish/.local/lib/pi-packet/geo-aeo.py' "$manifest" \
  || fail "MANIFEST must install lib/geo-aeo.py"
grep -Fxq 'config/geo-aeo-policy.json /home/nish/.local/state/pi-packet/geo-aeo-policy.json' "$manifest" \
  || fail "MANIFEST must install config/geo-aeo-policy.json"
ok "scenario11: heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it"

# --- 12. matrix row ---------------------------------------------------------
jq -e '.rules[] | select(.id == "led-2026-08-27-geo-aeo-fleet-executes-measurement-owned-content-" and .status == "enforced")' \
  "$matrix" >/dev/null \
  || fail "matrix row must be status=enforced"
mech=$(jq -r '.rules[] | select(.id == "led-2026-08-27-geo-aeo-fleet-executes-measurement-owned-content-") | .mechanism' "$matrix")
printf '%s\n' "$mech" | grep -q 'fleet-geo-aeo-canary' \
  || fail "mechanism must name fleet-geo-aeo-canary (got: $mech)"
printf '%s\n' "$mech" | grep -q 'preview-then-autonomous' \
  || fail "mechanism must lock preview-then-autonomous (got: $mech)"
proof=$(jq -r '.rules[] | select(.id == "led-2026-08-27-geo-aeo-fleet-executes-measurement-owned-content-") | .proof' "$matrix")
printf '%s\n' "$proof" | grep -q 'bin/fleet-geo-aeo-canary' \
  || fail "proof must name the canary (got: $proof)"
printf '%s\n' "$proof" | grep -q 'tests/fleet-geo-aeo.test.sh' \
  || fail "proof must name this test (got: $proof)"
ok "scenario12: matrix row is enforced with mechanism+proof"

ok "geo-aeo: production clean, policy locks, worker needles, grants, surfaces, reddit deny-scan, heartbeat, matrix"
