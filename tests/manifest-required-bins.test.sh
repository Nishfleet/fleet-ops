#!/usr/bin/env bash
# tests/manifest-required-bins.test.sh
#
# fleet-ops#175 + #485: MANIFEST-declared binaries must stay in MANIFEST, and
# the installed heartbeat must fail loud when a required helper is missing.
# Silent `skip (not installed)` hid dead passes.
#
# Proves, offline:
#   1. The audit-named dests are still MANIFEST lines.
#   2. require_manifest_helper exists and is wired into every MANIFEST
#      heartbeat helper.
#   3. Missing helper + should_run_deploy=1 -> return 1 (fail loud).
#   4. Missing helper + should_run_deploy=0 -> return 2 (CI/worktree skip).
#   5. Executable helper -> return 0.
#   6. HELPER-MISSING is the loud tag; the production path no longer
#      skip-only any of these helpers.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
manifest="$repo_root/MANIFEST"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$manifest" ]] || fail "MANIFEST missing"
[[ -x "$tier1" ]] || fail "not executable: $tier1"

# --- 1. MANIFEST still declares the dests the audit found missing ----------
required=(
  "lib/guard_pi_packet.py /home/nish/.local/lib/pi-packet/guard_pi_packet.py"
  "bin/pi-packet-guard /home/nish/.local/bin/pi-packet-guard"
  "bin/blocked-reconcile /home/nish/.local/bin/blocked-reconcile"
  "bin/fleet-heartbeat-undersaturation /home/nish/.local/bin/fleet-heartbeat-undersaturation"
  "bin/oomd-drill /home/nish/.local/bin/oomd-drill"
  "bin/codex-orphan-reap /home/nish/.local/bin/codex-orphan-reap"
  "bin/claim-reconcile /home/nish/.local/bin/claim-reconcile"
  "bin/lifecycle-label-sweep /home/nish/.local/bin/lifecycle-label-sweep"
  "bin/fleet-heartbeat-low-water-mark /home/nish/.local/bin/fleet-heartbeat-low-water-mark"
  "bin/fleet-heartbeat-red-pr-repair /home/nish/.local/bin/fleet-heartbeat-red-pr-repair"
  "bin/ram-measure /home/nish/.local/bin/ram-measure"
  "bin/fleet-escalation-canary /home/nish/.local/bin/fleet-escalation-canary"
  "bin/fleet-entitled-wired-canary /home/nish/.local/bin/fleet-entitled-wired-canary"
  "bin/worker-app-canary /home/nish/.local/bin/worker-app-canary"
  "bin/fleet-credential-expiry-canary /home/nish/.local/bin/fleet-credential-expiry-canary"
  "lib/credential-expiry-canary.py /home/nish/.local/lib/pi-packet/credential-expiry-canary.py"
)
for entry in "${required[@]}"; do
  grep -Fxq "$entry" "$manifest" || fail "MANIFEST missing required dest: $entry"
done
ok "MANIFEST still declares the #175/#485 dests plus credential-expiry canary"

# --- 2. wiring: all MANIFEST heartbeat helpers use require_manifest_helper -
grep -q '^require_manifest_helper()' "$tier1" \
  || fail "tier1 must define require_manifest_helper"
grep -q 'HELPER-MISSING' "$tier1" \
  || fail "tier1 must emit HELPER-MISSING"
set +e
python3 - "$tier1" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
helpers = {
    "BLOCKED_BIN=": "blocked-reconcile",
    "UNDERSAT_BIN=": "undersaturation",
    "CLAIM_BIN=": "claim-reconcile",
    "LIFECYCLE_BIN=": "lifecycle-label-sweep",
    "LOW_WATER_BIN=": "low-water-mark",
    "AUDITOR_BIN=": "senior-auditor panel",
    "REDPR_BIN=": "red-pr-repair",
    "RAM_BIN=": "ram-measure",
    "CANARY_BIN=": "escalation-coverage canary",
    "ENTITLED_CANARY_BIN=": "entitled-vs-wired canary",
    "WORKER_APP_CANARY_BIN=": "worker-app identity canary",
    "CRED_EXPIRY_CANARY_BIN=": "credential-expiry canary",
}
rc = 0
for needle, label in helpers.items():
    start = text.find(needle)
    if start < 0:
        print(f"missing {label} block")
        rc = 1
        continue
    # Each block is well under 2000 chars; use 2000 to be safe.
    chunk = text[start : start + 2000]
    if "require_manifest_helper" not in chunk:
        print(f"{label} block must call require_manifest_helper")
        rc = 1
    if "HELPER-MISSING" not in chunk:
        print(f"{label} block must loud HELPER-MISSING")
        rc = 1
sys.exit(rc)
PY
wiring_rc=$?
set -e
[[ "$wiring_rc" -eq 0 ]] || fail "one or more heartbeat helpers do not call require_manifest_helper or loud HELPER-MISSING"
ok "all twelve MANIFEST heartbeat helpers call require_manifest_helper and loud HELPER-MISSING"

# --- 3-5. extract the real function and prove the three outcomes -----------
extract_fn() {
  local fn="$1"
  awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { in_fn=1 }
    in_fn { print }
    in_fn && /^\}/ { in_fn=0 }
  ' "$tier1"
}

scratch="$(mktemp -d -t manifest-required-bins.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

extract_fn require_manifest_helper >"$scratch/helper.sh"
grep -q 'require_manifest_helper' "$scratch/helper.sh" \
  || fail "could not extract require_manifest_helper"
# shellcheck disable=SC1091
source "$scratch/helper.sh"

present="$scratch/present-helper"
printf '#!/bin/sh\nexit 0\n' >"$present"
chmod +x "$present"
missing="$scratch/missing-helper"

should_run_deploy=1
require_manifest_helper "$present"
[[ $? -eq 0 ]] || fail "executable helper must return 0"

set +e
require_manifest_helper "$missing"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "missing helper + should_run_deploy=1 must return 1, got $rc"

should_run_deploy=0
set +e
require_manifest_helper "$missing"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "missing helper + should_run_deploy=0 must return 2, got $rc"
ok "require_manifest_helper: present=0, prod-missing=1, ci-missing=2"

echo "OK: MANIFEST dests locked and missing helpers fail loud (fleet-ops#175/#485)"
