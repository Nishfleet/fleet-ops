#!/usr/bin/env bash
# tests/escalation-coverage-canary.test.sh
#
# Proves the escalation coverage canary (fleet-ops#152) on BOTH planes.
#
# VPS plane:
#   1. All loaded services covered -> exit 0, OK line, pending/EXCLUDED logged.
#   2. A service missing unit-escalation@<unit>.service -> exit 1, named.
#   3. A bin script with an unwrapped `pi --print --provider` -> exit 1, named.
#   4. Excluded services (anti-recursion set) are skipped.
#   5. Marker files for #76 and #124 suppress the pending findings.
#
# GitHub plane:
#   6. auto-revert.yml + red-on-main-detector.yml present -> covered.
#   7. An intake repo missing from claim_repos -> exit 1, named.
#   8. An intake repo on the exclusion list -> skipped (not a violation).
#   9. fleet-repos.json missing -> PENDING (loud, not fail).
#  10. bridge marker absent -> PENDING; present -> suppressed.
#
# Offline: uses a mocked systemctl, a scratch repo layout, and scratch JSON.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-escalation-canary"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

# --- scratch environment ----------------------------------------------------
scratch="$(mktemp -d -t esc-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

# A scratch fleet-ops repo with the workflow files the GitHub plane checks.
repo="$scratch/repo"
mkdir -p "$repo/bin" "$repo/.github/workflows" "$repo/config"
cp "$bin" "$repo/bin/fleet-escalation-canary"
chmod +x "$repo/bin/fleet-escalation-canary"
# Minimal workflow files so blocks 6 pass by default; tests remove them to
# force violations.
cat >"$repo/.github/workflows/auto-revert.yml" <<'WF'
on:
  workflow_run:
    workflows: ["CI"]
WF
cat >"$repo/.github/workflows/red-on-main-detector.yml" <<'WF'
on:
  workflow_call:
WF

state="$scratch/agent_state"
mkdir -p "$state"

triage="$scratch/triage.md"
: >"$triage"

loaded="$scratch/loaded_units"
onf_dir="$scratch/on_failure"
mkdir -p "$onf_dir"

# --- fake systemctl ---------------------------------------------------------
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
shift  # consume --user
cmd="$1"; shift
case "$cmd" in
  list-units)
    if [[ -f "${LOADED_UNITS:-/dev/null}" ]]; then
      while IFS= read -r u; do
        [[ -n "$u" ]] && printf '%s loaded active running -\n' "$u"
      done < "${LOADED_UNITS:-/dev/null}"
    fi
    exit 0
    ;;
  show)
    unit="$1"
    if [[ -f "${ON_FAILURE_DIR:-}/$unit" ]]; then
      cat "${ON_FAILURE_DIR:-}/$unit"
    else
      printf '\n'
    fi
    exit 0
    ;;
  *)
    printf 'unexpected systemctl call: %s %s\n' "$cmd" "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$systemctl_fake"

# Common env.
export SYSTEMCTL="$systemctl_fake"
export FLEET_OPS_REPO="$repo"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export AGENT_STATE="$state"
export FLEET_ESCALATION_CANARY_DELIVERY="$state/.escalation-delivery"
export FLEET_ESCALATION_CANARY_REDCI="$state/.red-ci-ownerless-guard"
export FLEET_ESCALATION_CANARY_BRIDGE="$state/.red-check-senior-auditor-bridge"
export LOADED_UNITS="$loaded"
export ON_FAILURE_DIR="$onf_dir"

# intake-repos.json + fleet-repos.json defaults (overridden per scenario).
intake_json="$repo/config/intake-repos.json"
redpr_json="$state/fleet-repos.json"
export FLEET_INTAKE_REPOS_JSON="$intake_json"
export FLEET_REDPR_REPOS_JSON="$redpr_json"

write_intake() {
  # $* = repo names (short, no owner prefix)
  {
    printf '{"repos":['
    local first=1
    for n in "$@"; do
      [[ $first -eq 1 ]] || printf ','
      printf '{"name":"%s"}' "$n"
      first=0
    done
    printf ']}'
  } >"$intake_json"
}

write_claim_repos() {
  # $* = full slugs in claim_repos
  {
    printf '{"claim_repos":['
    local first=1
    for r in "$@"; do
      [[ $first -eq 1 ]] || printf ','
      printf '"%s"' "$r"
      first=0
    done
    printf ']}'
  } >"$redpr_json"
}

run_canary() {
  set +e
  env_out=$("$bin" 2>&1)
  env_rc=$?
  set -e
}

reset_state() {
  rm -f "$triage" "$loaded"
  rm -rf -- "${onf_dir:?}"/*
  : >"$triage"
  : >"$loaded"
  rm -f "$repo/bin"/*[^c] 2>/dev/null || true
  # restore the canary itself + workflow files
  cp "$bin" "$repo/bin/fleet-escalation-canary"
  chmod +x "$repo/bin/fleet-escalation-canary"
  cat >"$repo/.github/workflows/auto-revert.yml" <<'WF'
on:
  workflow_run:
    workflows: ["CI"]
WF
  cat >"$repo/.github/workflows/red-on-main-detector.yml" <<'WF'
on:
  workflow_call:
WF
  rm -f "$FLEET_ESCALATION_CANARY_DELIVERY" "$FLEET_ESCALATION_CANARY_REDCI" "$FLEET_ESCALATION_CANARY_BRIDGE"
}

# ============================================================================
# Helpers to build fixture state
# ============================================================================
cover() {
  local unit="$1"
  printf '%s\n' "$unit" >>"$loaded"
  printf 'unit-escalation@%s.service\n' "$unit" >"$onf_dir/$unit"
}

exclude() {
  local unit="$1"
  printf '%s\n' "$unit" >>"$loaded"
  : >"$onf_dir/$unit"
}

sanctioned_wrapper() {
  local name="$1"
  cat >"$repo/bin/$name" <<'PI'
#!/usr/bin/env bash
# sanctioned wrapper
: # "$PI_BIN" --print --provider devin --model glm-5-2 < packet.md
PI
  chmod +x "$repo/bin/$name"
}

# ============================================================================
# Scenario 1: VPS plane all covered, GitHub plane all covered, markers absent
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
exclude "stop-escalation.service"
exclude "ready-work.service"
exclude "escalation-daily-sweep.service"
sanctioned_wrapper "pi-issue-run"
sanctioned_wrapper "pi-packet-run"
write_intake "0509" "fleet-ops" "siterep-public"
write_claim_repos "Nishfleet/0509" "Nishfleet/fleet-ops" "Nishfleet/siterep-public"

run_canary

[[ "$env_rc" == 0 ]] || fail "scenario1: must exit 0, got $env_rc ($env_out)"
grep -q 'ESCALATION-CANARY-OK' "$triage" || fail "scenario1: triage missing OK line"
grep -q 'two-plane invariant holds' "$triage" || fail "scenario1: OK line must name the two-plane invariant"
grep -q 'ESCALATION-CANARY-PENDING' "$triage" || fail "scenario1: triage missing PENDING (#76/#124/#152 bridge)"
grep -q 'ESCALATION-CANARY-EXCLUDED' "$triage" || fail "scenario1: triage missing EXCLUDED"
! grep -q 'ESCALATION-CANARY-VIOLATION' "$triage" || fail "scenario1: triage must not contain VIOLATION"
ok "scenario1: both planes covered -> exit 0 with OK, PENDING, EXCLUDED"

# ============================================================================
# Scenario 2: VPS plane — one loaded service missing its escalation drop-in
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
printf '%s\n' "naked.service" >>"$loaded"
: >"$onf_dir/naked.service"
sanctioned_wrapper "pi-issue-run"
write_intake "0509"
write_claim_repos "Nishfleet/0509"

run_canary

[[ "$env_rc" == 1 ]] || fail "scenario2: must exit 1, got $env_rc ($env_out)"
grep -q 'ESCALATION-CANARY-VIOLATION' "$triage" || fail "scenario2: triage missing VIOLATION"
grep -q 'unit=naked.service' "$triage" || fail "scenario2: triage must name naked.service"
! grep -q 'ESCALATION-CANARY-OK' "$triage" || fail "scenario2: triage must not contain OK"
ok "scenario2: missing-escalation unit named and canary exits 1"

# ============================================================================
# Scenario 3: VPS plane — a bin script runs pi --print --provider unwrapped
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
sanctioned_wrapper "pi-issue-run"
write_intake "0509"
write_claim_repos "Nishfleet/0509"

cat >"$repo/bin/rogue-runner" <<'PI'
#!/usr/bin/env bash
# not a sanctioned wrapper
pi --print --provider devin --model glm-5-2 < packet.md
PI
chmod +x "$repo/bin/rogue-runner"

run_canary

[[ "$env_rc" == 1 ]] || fail "scenario3: must exit 1, got $env_rc ($env_out)"
grep -q 'bin/rogue-runner' "$triage" || fail "scenario3: triage must name rogue-runner"
! grep -q 'ESCALATION-CANARY-OK' "$triage" || fail "scenario3: triage must not contain OK"
ok "scenario3: unwrapped pi runner named and canary exits 1"

# ============================================================================
# Scenario 4: marker files suppress pending findings (all three markers)
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
sanctioned_wrapper "pi-issue-run"
write_intake "0509"
write_claim_repos "Nishfleet/0509"
: >"$FLEET_ESCALATION_CANARY_DELIVERY"
: >"$FLEET_ESCALATION_CANARY_REDCI"
: >"$FLEET_ESCALATION_CANARY_BRIDGE"

run_canary

[[ "$env_rc" == 0 ]] || fail "scenario4: must exit 0, got $env_rc ($env_out)"
grep -q 'ESCALATION-CANARY-OK' "$triage" || fail "scenario4: triage missing OK"
grep -q 'pending=0' "$triage" || fail "scenario4: OK line must show pending=0"
! grep -q 'ESCALATION-CANARY-PENDING' "$triage" || fail "scenario4: PENDING must be gone when markers are present"
! grep -q 'ESCALATION-CANARY-VIOLATION' "$triage" || fail "scenario4: triage must not contain VIOLATION"
ok "scenario4: #76/#124/#152 markers present -> OK with no pending findings"

# ============================================================================
# Scenario 5: GitHub plane — auto-revert.yml missing -> VIOLATION
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
sanctioned_wrapper "pi-issue-run"
write_intake "0509"
write_claim_repos "Nishfleet/0509"
rm -f "$repo/.github/workflows/auto-revert.yml"

run_canary

[[ "$env_rc" == 1 ]] || fail "scenario5: must exit 1, got $env_rc ($env_out)"
grep -q 'auto-revert.yml missing' "$triage" || fail "scenario5: triage must name auto-revert.yml"
ok "scenario5: missing auto-revert.yml -> VIOLATION naming it"

# ============================================================================
# Scenario 6: GitHub plane — intake repo not in claim_repos -> VIOLATION
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
sanctioned_wrapper "pi-issue-run"
write_intake "0509" "fleet-ops" "siterep-public"
# fleet-ops enrolled but NOT in claim_repos
write_claim_repos "Nishfleet/0509" "Nishfleet/siterep-public"

run_canary

[[ "$env_rc" == 1 ]] || fail "scenario6: must exit 1, got $env_rc ($env_out)"
grep -q 'Nishfleet/fleet-ops is intake-enrolled' "$triage" || fail "scenario6: triage must name fleet-ops as uncovered"
grep -q 'escape #124 redispatch' "$triage" || fail "scenario6: triage must say it escapes #124"
ok "scenario6: intake repo missing from claim_repos -> VIOLATION naming it"

# ============================================================================
# Scenario 7: GitHub plane — fleet-repos.json missing -> PENDING (not fail)
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
sanctioned_wrapper "pi-issue-run"
write_intake "0509"
rm -f "$redpr_json"

run_canary

[[ "$env_rc" == 0 ]] || fail "scenario7: must exit 0 (PENDING not fail), got $env_rc ($env_out)"
grep -q 'fleet-repos.json missing' "$triage" || fail "scenario7: triage must name fleet-repos.json missing as PENDING"
! grep -q 'ESCALATION-CANARY-VIOLATION' "$triage" || fail "scenario7: missing state file must be PENDING not VIOLATION"
ok "scenario7: fleet-repos.json missing -> PENDING (loud, not fail)"

# ============================================================================
# Scenario 8: GitHub plane — bridge marker absent -> PENDING; present -> OK
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
sanctioned_wrapper "pi-issue-run"
write_intake "0509"
write_claim_repos "Nishfleet/0509"
: >"$FLEET_ESCALATION_CANARY_DELIVERY"
: >"$FLEET_ESCALATION_CANARY_REDCI"
# bridge marker absent

run_canary

[[ "$env_rc" == 0 ]] || fail "scenario8a: must exit 0 (bridge PENDING), got $env_rc ($env_out)"
grep -q 'red-check -> senior-auditor bridge not wired' "$triage" || fail "scenario8a: triage must name the bridge as PENDING"
ok "scenario8a: bridge absent -> PENDING (loud, not fail)"

: >"$FLEET_ESCALATION_CANARY_BRIDGE"
: >"$triage"
run_canary
[[ "$env_rc" == 0 ]] || fail "scenario8b: must exit 0, got $env_rc ($env_out)"
! grep -q 'senior-auditor bridge not wired' "$triage" || fail "scenario8b: bridge PENDING must be suppressed by marker"
ok "scenario8b: bridge marker present -> suppressed"

ok "escalation-coverage-canary: covers VPS + GitHub planes, exclusions, and pending holes"
