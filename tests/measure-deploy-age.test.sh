#!/usr/bin/env bash
# tests/measure-deploy-age.test.sh
#
# fleet-ops#5514 (0509#2975 item 4): the judges' measure.sh carries the 0509
# deploy-production freshness line from the 0509 repo's deploy-age detector
# (scripts/deploy-age.mjs), verbatim:
#   deploy: last_success_age_h=<n> merges_since=<m> last_failure=<reason>
# and a LOUD line fires when merges_since>0 AND last_success_age_h>=6 —
# the two-days-of-red-deploys blind spot. Missing detector is UNAVAILABLE,
# never a fabricated green.
#
# Hermetic: FLEET_DEPLOY_AGE_SCRIPT points at fake detectors, MEASURE_REPOS=""
# keeps gh out of the loop, FLEET_SESSIONS_DIR is empty.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
measure="$here/measure.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$measure" ]] || fail "measure.sh not found"
command -v node >/dev/null 2>&1 || fail "node required"

scratch="$(mktemp -d -t measure-deploy.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
FLEET_SESSIONS_DIR="$scratch/empty-sessions" MEASURE_REPOS=""

mkdir -p "$scratch/empty-sessions" "$scratch/dets"
cat >"$scratch/dets/stale.mjs" <<'EOF'
console.log("deploy: last_success_age_h=30 merges_since=4 last_failure=some-reason");
EOF
cat >"$scratch/dets/fresh.mjs" <<'EOF'
console.log("deploy: last_success_age_h=1 merges_since=0 last_failure=none");
EOF

# newline continuity matters: FLEET_SESSIONS_DIR must be set per run below.

run_deploy_lines() {
    ( export FLEET_SESSIONS_DIR="$scratch/empty-sessions"
      export MEASURE_REPOS=""
      export FLEET_DEPLOY_AGE_SCRIPT="$1"
      bash "$measure" 2>/dev/null || true ) | grep -E '^(deploy:|LOUD deploy-stale:)'
}

# 1. absent detector -> UNAVAILABLE line, no fabricated green, no LOUD
out=$(run_deploy_lines "$scratch/dets/no-such-file.mjs")
echo "$out" | grep -q '^deploy: UNAVAILABLE:detector-not-installed$' || fail "missing detector line: $out"
echo "$out" | grep -q 'LOUD' && fail "LOUD fired on missing detector"
ok "1. missing detector -> UNAVAILABLE"

# 2. healthy detector -> the line verbatim, no LOUD
out=$(run_deploy_lines "$scratch/dets/fresh.mjs")
echo "$out" | grep -Fq 'deploy: last_success_age_h=1 merges_since=0 last_failure=none' || fail "healthy line not verbatim: $out"
echo "$out" | grep -q 'LOUD' && fail "LOUD fired on healthy state"
ok "2. fresh line verbatim, no LOUD"

# 3. simulated stale ledger (30h old, 4 merges since) -> LOUD fires
out=$(run_deploy_lines "$scratch/dets/stale.mjs")
echo "$out" | grep -Fq 'deploy: last_success_age_h=30 merges_since=4 last_failure=some-reason' || fail "stale line not verbatim: $out"
echo "$out" | grep -Eq '^LOUD deploy-stale: last success 30h old with 4 merges since' || fail "LOUD missing on stale: $out"
ok "3. stale ledger -> LOUD line"

# 4. a crashing detector folds to UNAVAILABLE:detector-failed, never a
#    partial line (the detector's own contract is exit 0; a non-zero here is
#    engine drift, so the label differs from a missing detector)
printf 'process.stdout.write("garbage\\n"); process.exit(1);' >"$scratch/dets/crash.mjs"
out=$(run_deploy_lines "$scratch/dets/crash.mjs")
echo "$out" | grep -q '^deploy: UNAVAILABLE:detector-failed$' || fail "crash not flagged: $out"
ok "4. crashing detector -> UNAVAILABLE:detector-failed"

# 5. a chatty detector: only the first deploy: line is printed verbatim,
#    banner/junk lines never reach the judge feed
printf 'console.log("banner noise");\nconsole.log("deploy: last_success_age_h=9 merges_since=2 last_failure=none");\nconsole.log("deploy: last_success_age_h=1 merges_since=0 last_failure=none");\n' >"$scratch/dets/chatty.mjs"
out=$(run_deploy_lines "$scratch/dets/chatty.mjs")
[ "$(echo "$out" | grep -c '^deploy: ')" = "1" ] || fail "chatty detector leaked lines: $out"
echo "$out" | grep -Fq 'deploy: last_success_age_h=9 merges_since=2 last_failure=none' || fail "chatty: wrong line kept: $out"
echo "$out" | grep -Eq '^LOUD deploy-stale: last success 9h old with 2 merges since' || fail "LOUD missing on chatty-stale: $out"
ok "5. chatty detector -> first deploy: line only"

exit 0
