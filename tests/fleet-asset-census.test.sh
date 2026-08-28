#!/usr/bin/env bash
# tests/fleet-asset-census.test.sh
#
# fleet-ops#1149: mechanical VPS asset census, guard mapping, and unguarded-asset
# auto-filing. Offline where possible; live calls are stubbed or use a scratch
# filesystem. No secrets are printed.
#
# Proves:
#   1. The canary binary + lib exist and are executable/parseable.
#   2. config/asset-guard-map.json is valid and in MANIFEST.
#   3. The new systemd unit is in the non-role prefix list.
#   4. In skip-live mode the canary still emits a valid JSON census.
#   5. Diff against the guard map produces a JSON report and Prometheus textfile.
#   6. A custom map missing a class reports unguarded assets.
#   7. Issue title/body render and carry the dedup signal.
#   8. Dry-run auto-file logs without calling gh.
#   9. Test-suite mapping detects a workflow reference.
#  10. Test-header-claim extraction finds a capability comment.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/pi-packet/asset-census.py"
bin="$repo_root/bin/fleet-asset-census"
map="$repo_root/config/asset-guard-map.json"
manifest="$repo_root/MANIFEST"
quality_gates="$repo_root/lib/role-quality-gates.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$map" ]] || fail "missing $map"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# --- 1. validate the committed guard map -----------------------------------
python3 "$lib" validate-map --map "$map" || fail "committed guard map is invalid"
ok "committed guard map is valid"

# --- 2. MANIFEST ships the new files ---------------------------------------
grep -q '^bin/fleet-asset-census' "$manifest" \
  || fail "MANIFEST must install bin/fleet-asset-census"
grep -q '^lib/pi-packet/asset-census.py' "$manifest" \
  || fail "MANIFEST must install lib/pi-packet/asset-census.py"
grep -q '^config/asset-guard-map.json' "$manifest" \
  || fail "MANIFEST must install config/asset-guard-map.json"
grep -q '^systemd/fleet-asset-census.service' "$manifest" \
  || fail "MANIFEST must install fleet-asset-census.service"
grep -q '^systemd/fleet-asset-census.timer' "$manifest" \
  || fail "MANIFEST must install fleet-asset-census.timer"
ok "MANIFEST ships the canary binary, lib, map, and systemd units"

# --- 3. role-quality-gates does not flag the new unit ----------------------
grep -q '"fleet-asset-census"' "$quality_gates" \
  || fail "lib/role-quality-gates.py must list fleet-asset-census as non-role"
ok "fleet-asset-census is in NON_ROLE_UNIT_PREFIXES"

# --- 4. census in skip-live mode emits valid JSON --------------------------
scratch="$(mktemp -d -t fleet-asset-census.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch"
export FLEET_ASSET_CENSUS_FLEET_OPS_REPO="$repo_root"
export FLEET_ASSET_CENSUS_REPO_ROOTS="$repo_root"
export FLEET_ASSET_CENSUS_SKIP_LIVE=1

set +e
out="$("$bin" census 2>/tmp/census.err)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "census must exit 0, got $rc (stderr=$(cat /tmp/census.err))"
echo "$out" | jq -e . >/dev/null || fail "census output is not valid JSON"
count=$(echo "$out" | jq '.asset_count')
[[ "$count" -gt 0 ]] || fail "census must find at least one asset"
ok "census is valid JSON and finds $count assets"

# --- 5. diff against the committed map -------------------------------------
metrics="$scratch/metrics.prom"
report="$scratch/diff.json"
set +e
out="$("$bin" diff --map "$map" --output-json "$report" --metrics "$metrics" 2>/tmp/diff.err)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "diff must exit 0 (all committed classes covered), got $rc (stderr=$(cat /tmp/diff.err))"
[[ -f "$report" ]] || fail "diff must write --output-json"
[[ -f "$metrics" ]] || fail "diff must write --metrics"
grep -q 'fleet_asset_census_total' "$metrics" \
  || fail "metrics must include fleet_asset_census_total"
grep -q 'fleet_asset_census_unguarded_total' "$metrics" \
  || fail "metrics must include fleet_asset_census_unguarded_total"
ok "diff exits 0 and writes JSON + Prometheus textfile"

# --- 6. unguarded-asset detection with a custom map ------------------------
custom_map="$scratch/missing-class.json"
cat >"$custom_map" <<'EOF'
{
  "version": 1,
  "auto_file_cap_per_tick": 3,
  "issue_repo": "Nishfleet/fleet-ops",
  "classes": {},
  "assets": []
}
EOF
set +e
out="$("$bin" diff --map "$custom_map" --output-json "$scratch/diff-missing.json" --dry-run 2>/tmp/diff-missing.err)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "diff with an empty map must exit 1, got $rc"
unguarded=$(jq '.unguarded_count' "$scratch/diff-missing.json")
[[ "$unguarded" -gt 0 ]] || fail "empty map must produce unguarded assets"
ok "empty map produces unguarded assets (count=$unguarded)"

# --- 7. issue title/body render -------------------------------------------
title="$(python3 "$lib" issue-title --json '{"id":"test:foo","class":"test","name":"foo"}')"
[[ "$title" == "unguarded asset: foo" ]] || fail "issue-title wrong: $title"
body="$(python3 "$lib" issue-body --json '{"id":"test:foo","class":"test","name":"foo","source":"test"}')"
grep -q 'signal: asset-census/test:foo' <<<"$body" \
  || fail "issue-body must carry the signal marker"
ok "issue title/body carry the dedup signal"

# --- 8. dry-run auto-file does not call gh ---------------------------------
set +e
out="$(FLEET_ASSET_CENSUS_DRY_RUN=1 FLEET_ASSET_CENSUS_FILE_ISSUES=1 "$bin" diff --map "$custom_map" --file-issues 2>&1)"
rc=$?
set -e
# Exit 1 is expected because the map is empty.
[[ "$rc" -eq 1 ]] || fail "dry-run diff with file-issues must exit 1, got $rc"
grep -q 'dry-run would file' <<<"$out" \
  || fail "dry-run must log 'would file'"
ok "dry-run auto-file reports without calling gh"

# --- 9. test suite guarded_by from workflow --------------------------------
# The committed map covers test-suite; the diff above should have found at
# least one test-suite asset. Spot-check the repo root workflow reference.
workflows_test="$scratch/workflows-ref.test.sh"
cat >"$workflows_test" <<'EOF'
#!/bin/sh
# exercises the workflows-ref fixture
EOF
chmod +x "$workflows_test"
mini_repo="$scratch/mini-repo"
mkdir -p "$mini_repo/.github/workflows"
cp "$workflows_test" "$mini_repo/workflows-ref.test.sh"
cat >"$mini_repo/.github/workflows/ci.yml" <<'EOF'
name: CI
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/workflows-ref.test.sh
EOF
set +e
out="$(FLEET_ASSET_CENSUS_REPO_ROOTS="$mini_repo" "$bin" census 2>/tmp/mini.err)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "mini-repo census failed (rc=$rc): $(cat /tmp/mini.err)"
res="$scratch/mini-census.json"
echo "$out" >"$res"
# A workflow ref by filename should be detected.
guarded=$(jq '[.assets[] | select(.class == "test-suite" and (.details.guarded_by | length) > 0)] | length' "$res")
[[ "$guarded" -gt 0 ]] || fail "workflow reference must guard a test suite (guarded=$guarded)"
ok "test-suite mapping detects a workflow reference"

# --- 10. test-header claim extraction --------------------------------------
mkdir -p "$mini_repo/tests"
cat >"$mini_repo/tests/claim.test.sh" <<'EOF'
#!/bin/sh
# This suite does NOT exercise sign-in with 2FA.
# It exercises password reset.
EOF
chmod +x "$mini_repo/tests/claim.test.sh"
set +e
out="$(FLEET_ASSET_CENSUS_REPO_ROOTS="$mini_repo" "$bin" census 2>/tmp/claim.err)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "claim census failed (rc=$rc): $(cat /tmp/claim.err)"
echo "$out" >"$scratch/claim-census.json"
claims=$(jq '[.assets[] | select(.class == "test-header-claim")] | length' "$scratch/claim-census.json")
[[ "$claims" -ge 2 ]] || fail "must extract at least 2 test-header claims, got $claims"
ok "test-header claim extraction finds capability comments"

echo "OK: fleet-asset-census (fleet-ops#1149)"
