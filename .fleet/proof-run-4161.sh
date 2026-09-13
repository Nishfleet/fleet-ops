#!/usr/bin/env bash
# CI-shape proof of .github/workflows/fleet-drain-backstop.yml (fleet-ops#4161).
# Runs the workflow's exact step, but with a FRESH HOME so the /home/runner
# state-dir class is exercised, not just the nish-host class.
set -u
cd "$(dirname "$0")/.." || exit 2
export HOME=/tmp/ci-home-4161
rm -rf "$HOME"; mkdir -p "$HOME"
export GITHUB_ACTIONS=true
export FLEET_MERGED_PR_CLOSE_OK=1 FLEET_CLOSE_DUPLICATES_OK=1
export MERGED_PR_CLOSE_INTAKE_JSON="$PWD/config/intake-repos.json"
export MERGED_PR_CLOSE_SUMMARY="$PWD/.fleet/merged-pr-close.json"
export MERGED_PR_CLOSE_TRIAGE="$PWD/.fleet/FLEET-HEARTBEAT-TRIAGE.md"
export FLEET_CLOSE_DUPLICATES_REVIEW_LOG="$PWD/.fleet/close-duplicates.review.log"
export DEAD_PR_STATE_DIR="$PWD/.fleet/dead-pr-state"
export ATTEMPTS_DIR="$PWD/.fleet/attempts"

mkdir -p .fleet/attempts .fleet/dead-pr-state
touch .fleet/FLEET-HEARTBEAT-TRIAGE.md

rc_total=0
echo "=== dead-pr-detector start $(date -u +%H:%M:%SZ)"
if bin/fleet-dead-pr-detector; then echo "DETECTOR: exit 0"; else rc=$?; echo "DETECTOR: exit $rc"; rc_total=1; fi
echo "=== fleet-merged-pr-close start $(date -u +%H:%M:%SZ)"
if bin/fleet-merged-pr-close; then echo "MERGED-PR-CLOSE: exit 0"; else rc=$?; echo "MERGED-PR-CLOSE: exit $rc"; rc_total=1; fi
echo "=== close-duplicates start $(date -u +%H:%M:%SZ)"
if out="$(bin/fleet-issue-file close-duplicates 2>&1)"; then
  echo "$out" | tail -12; echo "CLOSE-DUP: exit 0"
else
  rc=$?; echo "$out" | tail -12; echo "CLOSE-DUP: exit $rc"; rc_total=1
fi
echo "=== artifacts $(date -u +%H:%M:%SZ)"
ls -la .fleet/merged-pr-close.json .fleet/FLEET-HEARTBEAT-TRIAGE.md .fleet/close-duplicates.review.log 2>&1
echo "=== fresh-HOME residue (proves the /home/runner class):"
find /tmp/ci-home-4161 -type f | head -8
echo "PROOF_RUN_RC=$rc_total"
exit $rc_total
