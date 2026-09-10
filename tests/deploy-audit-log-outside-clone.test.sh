#!/usr/bin/env bash
# fleet-ops#3758 regression: fleet-deploy-check must never default the
# deploy audit log INSIDE the deploy clone it watches. Doing so makes the
# clone permanently untracked-dirty, so DEPLOY-CHECK-DIRTY-CLONE fires on
# every 2-min tick and a REAL worker edit of the deploy clone is lost in
# the noise — the read-only gate cries wolf about its own log file.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/fleet-deploy-check"
fails=0

if grep -qE 'FLEET_OPS_DEPLOY_AUDIT_LOG=.*fleet-ops-deploy/logs' "$BIN"; then
    echo "FAIL: fleet-deploy-check defaults FLEET_OPS_DEPLOY_AUDIT_LOG inside the deploy clone"
    fails=1
fi
if ! grep -qE 'FLEET_OPS_DEPLOY_AUDIT_LOG=.*\.local/state' "$BIN"; then
    echo "FAIL: fleet-deploy-check audit-log default is not under ~/.local/state"
    fails=1
fi
# The deploy clone path must not appear as a write target anywhere in the checker.
if grep -nE '>[>]?[[:space:]]*"?\$?\{?[A-Za-z_]*\}?/?.*fleet-ops-deploy/logs' "$BIN"; then
    echo "FAIL: fleet-deploy-check writes into the deploy clone"
    fails=1
fi

if [[ "$fails" -eq 0 ]]; then echo "PASS: deploy audit log stays outside the deploy clone"; fi
exit "$fails"
