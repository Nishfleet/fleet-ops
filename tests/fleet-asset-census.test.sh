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
# Organ heartbeat (fleet-ops#1010 standing pattern, fleet-ops#1149 item 4):
# the diff must write a fresh timestamp so absent() can fire when the weekly
# timer stops running.
grep -q 'fleet_asset_census_last_run_seconds' "$metrics" \
  || fail "metrics must include fleet_asset_census_last_run_seconds heartbeat"
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

# --- 11. organ registration + absent() rule (fleet-ops#1010, #1149 item 4) --
organs="$repo_root/config/fleet-organs.json"
rules="$repo_root/config/fleet_rules.yml"
grep -q '"name": "asset-census"' "$organs" \
  || fail "fleet-organs.json must register the asset-census organ"
grep -q 'fleet_asset_census_last_run_seconds' "$organs" \
  || fail "fleet-organs.json must name the heartbeat metric"
grep -q 'FleetAssetCensusAbsent' "$organs" \
  || fail "fleet-organs.json must name the absent alert"
grep -q 'alert: FleetAssetCensusAbsent' "$rules" \
  || fail "fleet_rules.yml must define the FleetAssetCensusAbsent alert"
grep -q 'absent(fleet_asset_census_last_run_seconds)' "$rules" \
  || fail "fleet_rules.yml must use absent() on the census heartbeat metric"
# The verify drill is the standing proof that registry <-> rules agree.
bin/fleet-organ-heartbeat-check verify --registry "$organs" --rules "$rules" >/tmp/organ-verify.out 2>&1 \
  || fail "organ-heartbeat verify drill failed: $(cat /tmp/organ-verify.out)"
grep -q 'organ asset-census -> FleetAssetCensusAbsent' /tmp/organ-verify.out \
  || fail "verify drill must list the asset-census organ"
ok "asset-census organ registered with matching absent() rule"

# --- 12. scalability: SECRET_KEY_RE must not backtrack, prune must skip -----
# Regression pin for the 2026-08-28 inner-loop fix: a wrapped .*(...).* regex
# hung the census for 60+ seconds on 13k config files, and an unpruned
# ~/.pi/agent/git crawled 24k vendored files. A large fake config tree with
# long non-matching lines must finish well under the cap.
# The census scans ~/.config, ~/.local/state, ~/.pi/agent — place the fixture
# under ~/.config so it is actually walked.
mkdir -p "$scratch/.config"
python3 - "$scratch/.config" <<'PY'
import sys, os
root = sys.argv[1]
# 50 files × 400 lines × 200 chars of non-matching noise. The old wrapped
# .*(...).* regex still took 15+ seconds on this shape; a correct regex
# finishes in well under a second.
for i in range(50):
    with open(os.path.join(root, f"f{i}.conf"), "w") as f:
        for _ in range(400):
            f.write("x" * 200 + " no marker here just noise\n")
# A vendored subtree that must be pruned, not descended into.
vend = os.path.join(root, "git")
os.makedirs(vend, exist_ok=True)
for i in range(500):
    with open(os.path.join(vend, f"v{i}.json"), "w") as f:
        f.write('{"no":"secret"}\n')
PY
export FLEET_ASSET_CENSUS_SKIP_LIVE=1
export HOME="$scratch"
start=$(date +%s)
out="$("$bin" census 2>/tmp/big.err)"
rc=$?
elapsed=$(( $(date +%s) - start ))
[[ "$rc" -eq 0 ]] || fail "big-config census failed (rc=$rc): $(cat /tmp/big.err)"
echo "$out" | jq -e . >/dev/null || fail "big-config census output not JSON"
# 30s is a generous ceiling; the bug took 60s+. A future wrapped-regex
# regression or a missing prune will blow past it.
[[ "$elapsed" -lt 30 ]] || fail "census took ${elapsed}s on a large config tree (must be <30s; regex/prune regression)"
# The pruned git/ subtree must not contribute assets.
pruned=$(echo "$out" | jq '[.assets[] | select(.id | contains(".config/git/"))] | length')
[[ "$pruned" -eq 0 ]] || fail "pruned git/ subtree leaked $pruned assets into the census"
ok "scalability: large config tree scanned in ${elapsed}s, vendored subtree pruned"

echo "OK: fleet-asset-census (fleet-ops#1149)"
