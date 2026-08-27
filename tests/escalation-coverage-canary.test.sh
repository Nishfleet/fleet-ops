#!/usr/bin/env bash
# tests/escalation-coverage-canary.test.sh
#
# Proves the escalation coverage canary (fleet-ops#152) on BOTH planes.
#
# VPS plane:
#   1. All loaded services/paths/timers covered -> exit 0, OK line, pending/EXCLUDED logged.
#   2. A service missing unit-escalation@<unit>.service -> exit 1, named.
#   2b. A path unit missing OnFailure -> exit 1, named (fleet-ops#618).
#   2c. A timer unit missing OnFailure -> exit 1, named (fleet-ops#618).
#   2d. Canary source must list --type=service,path,timer (class lock).
#   3. A bin script with an unwrapped `pi --print --provider` -> exit 1, named.
#   4. Excluded services (anti-recursion set) are skipped.
#   5. Marker files for #76 and #124 suppress the pending findings; #76 is
#      also suppressed by observing the real delivery wiring in the repo
#      (watchman lib + heartbeat/tier1 wiring + hc.env EnvironmentFile).
#
# GitHub plane:
#   6. auto-revert.yml + red-on-main-detector.yml present -> covered.
#   7. An intake repo missing from claim_repos -> exit 1, named.
#   8. An intake repo on the exclusion list -> skipped (not a violation).
#   9. fleet-repos.json missing -> PENDING (loud, not fail).
#  10. bridge marker or bridge files present -> OK; absent -> PENDING.
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
# Handles both `--user show` (VPS-plane blocks 1-9) and bare `show`
# (block 10 backup staleness, system-scope restic units — no --user).
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == "--user" ]] && shift
cmd="$1"; shift
case "$cmd" in
  list-units)
    type_filter=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --type=*) type_filter="${1#--type=}"; shift ;;
        --type) type_filter="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ -f "${LOADED_UNITS:-/dev/null}" ]]; then
      while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        if [[ -n "$type_filter" ]]; then
          matched=0
          IFS=',' read -ra types <<< "$type_filter"
          for t in "${types[@]}"; do
            [[ "$u" == *".$t" ]] && matched=1 && break
          done
          [[ "$matched" -eq 1 ]] || continue
        fi
        printf '%s loaded active running -\n' "$u"
      done < "${LOADED_UNITS:-/dev/null}"
    fi
    exit 0
    ;;
  show)
    unit="$1"; shift
    prop="${1#--property=}"; prop="${prop#--value}"
    # Block 10: system-scope restic units. State lives in BACKUP_STATE_DIR.
    if [[ -n "${BACKUP_STATE_DIR:-}" ]] && [[ -f "${BACKUP_STATE_DIR}/${unit}.${prop}" ]]; then
      cat "${BACKUP_STATE_DIR}/${unit}.${prop}"
      exit 0
    fi
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

# Block 10 (fleet-ops#388): backup-staleness state for the fake systemctl.
# Block 11 (fleet-ops#529): vault-conflict-resolver state uses the same dir.
backup_state="$scratch/backup_state"
mkdir -p "$backup_state"
export BACKUP_STATE_DIR="$backup_state"
export FLEET_RESTIC_BACKUP_TIMER="restic-r2-backup.timer"
export FLEET_RESTIC_BACKUP_SERVICE="restic-r2-backup.service"
export FLEET_RESTIC_STALENESS_HOURS=30
export FLEET_VAULT_CONFLICT_TIMER="vault-conflict-resolver.timer"
export FLEET_VAULT_CONFLICT_SERVICE="vault-conflict-resolver.service"
export FLEET_VAULT_CONFLICT_STALE_HOURS=1

# write_backup_fresh — green backup: timer active, fired 5h ago, service success.
write_backup_fresh() {
  local last
  last="$(date -u -d '5 hours ago' '+%a %Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -u '+%a %Y-%m-%d %H:%M:%S %Z')"
  printf 'active\n' >"$backup_state/${FLEET_RESTIC_BACKUP_TIMER}.ActiveState"
  printf '%s\n' "$last" >"$backup_state/${FLEET_RESTIC_BACKUP_TIMER}.LastTriggerUSec"
  printf 'success\n' >"$backup_state/${FLEET_RESTIC_BACKUP_SERVICE}.Result"
}

# write_backup_stale — timer active but last fired 48h ago (> 30h threshold).
write_backup_stale() {
  local last
  last="$(date -u -d '48 hours ago' '+%a %Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -u '+%a %Y-%m-%d %H:%M:%S %Z')"
  printf 'active\n' >"$backup_state/${FLEET_RESTIC_BACKUP_TIMER}.ActiveState"
  printf '%s\n' "$last" >"$backup_state/${FLEET_RESTIC_BACKUP_TIMER}.LastTriggerUSec"
  printf 'success\n' >"$backup_state/${FLEET_RESTIC_BACKUP_SERVICE}.Result"
}

# write_backup_failed — timer active + fresh, but last service Result=failed.
write_backup_failed() {
  write_backup_fresh
  printf 'failed\n' >"$backup_state/${FLEET_RESTIC_BACKUP_SERVICE}.Result"
}

# write_backup_inactive — timer not active.
write_backup_inactive() {
  printf 'inactive\n' >"$backup_state/${FLEET_RESTIC_BACKUP_TIMER}.ActiveState"
  printf '\n' >"$backup_state/${FLEET_RESTIC_BACKUP_TIMER}.LastTriggerUSec"
  printf 'success\n' >"$backup_state/${FLEET_RESTIC_BACKUP_SERVICE}.Result"
}

# write_vault_conflict_fresh — green handler: timer active, fired 2m ago.
write_vault_conflict_fresh() {
  local last
  last="$(date -u -d '2 minutes ago' '+%a %Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -u '+%a %Y-%m-%d %H:%M:%S %Z')"
  printf 'active\n' >"$backup_state/${FLEET_VAULT_CONFLICT_TIMER}.ActiveState"
  printf '%s\n' "$last" >"$backup_state/${FLEET_VAULT_CONFLICT_TIMER}.LastTriggerUSec"
  printf 'success\n' >"$backup_state/${FLEET_VAULT_CONFLICT_SERVICE}.Result"
  mkdir -p "$repo/lib"
  cp "$repo_root/lib/vault-conflict-resolver.py" "$repo/lib/vault-conflict-resolver.py"
}

write_vault_conflict_inactive() {
  printf 'inactive\n' >"$backup_state/${FLEET_VAULT_CONFLICT_TIMER}.ActiveState"
  printf '\n' >"$backup_state/${FLEET_VAULT_CONFLICT_TIMER}.LastTriggerUSec"
  printf 'success\n' >"$backup_state/${FLEET_VAULT_CONFLICT_SERVICE}.Result"
}

write_vault_conflict_failed() {
  write_vault_conflict_fresh
  printf 'failed\n' >"$backup_state/${FLEET_VAULT_CONFLICT_SERVICE}.Result"
}

# intake-repos.json + fleet-repos.json defaults (overridden per scenario).
intake_json="$repo/config/intake-repos.json"
redpr_json="$state/fleet-repos.json"
export FLEET_INTAKE_REPOS_JSON="$intake_json"
export FLEET_REDPR_REPOS_JSON="$redpr_json"

# fleet-ops#383: step 9 joins a fixture vault against a matching matrix so
# existing two-plane scenarios stay green. Auto-file stays off unless a
# drill turns it on with a fake gh.
export FLEET_STANDING_RULES="$scratch/standing-rules.md"
export FLEET_DECISIONS_LEDGER="$scratch/decisions-ledger.md"
export FLEET_RULE_ENFORCEMENT_JSON="$repo/config/rule-enforcement.json"
export FLEET_RULE_ENFORCEMENT_LIB="$repo_root/lib/rule-enforcement.py"
export FLEET_RULE_ENFORCEMENT_FILE_ISSUES=0
export FLEET_RULE_ENFORCEMENT_NOW="2026-08-26T12:00:00Z"

write_covered_vault() {
  cat >"$FLEET_STANDING_RULES" <<'EOF'
# fixture standing rules
## Covered fixture rule (Nish, 2026-08-26)
A rule the matrix already covers.
EOF
  cat >"$FLEET_DECISIONS_LEDGER" <<'EOF'
# fixture ledger
## Ledger
### Product / fleet
- 2026-08-26 | covered ledger rule | a decision the matrix already covers
EOF
  mkdir -p "$repo/config"
  cat >"$FLEET_RULE_ENFORCEMENT_JSON" <<'EOF'
{
  "queued_stale_days": 7,
  "auto_file_cap_per_tick": 5,
  "rules": [
    {
      "id": "sr-covered-fixture",
      "source": "global-standing-rules.md: Covered fixture rule (Nish, 2026-08-26)",
      "mechanism": "test gate",
      "proof": "tests/escalation-coverage-canary.test.sh",
      "status": "enforced"
    },
    {
      "id": "led-covered-fixture",
      "source": "decisions-ledger.md: 2026-08-26 | covered ledger rule",
      "mechanism": "test gate",
      "proof": "tests/escalation-coverage-canary.test.sh",
      "status": "enforced"
    }
  ]
}
EOF
}

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
  rm -f "$repo/.github/workflows/ci-failure-escalation.yml" "$repo/.github/scripts/ci-failure-escalation-detector.mjs"
  rm -rf "${repo:?}/lib" "${repo:?}/systemd"
  write_covered_vault
  # Block 10 default: green backup so existing two-plane scenarios stay green.
  write_backup_fresh
  # Block 11 default: green vault-conflict handler + fixture resolver.
  write_vault_conflict_fresh
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

# Wire the #76 terminal delivery paths in the scratch repo so the canary's
# block 3 sees real wiring (not just a marker). Mirrors the live fleet-ops
# layout: lib/heartbeat-watchman.sh + bin/fleet-heartbeat + tier1 + service.
wire_delivery() {
  mkdir -p "$repo/lib" "$repo/systemd"
  cat >"$repo/lib/heartbeat-watchman.sh" <<'SH'
#!/usr/bin/env bash
heartbeat_ping_deadman() { :; }
heartbeat_page_units() { :; }
heartbeat_seat_health_check() { :; }
SH
  cat >"$repo/bin/fleet-heartbeat" <<'SH'
#!/usr/bin/env bash
source "$0.watchman"
heartbeat_ping_deadman
SH
  chmod +x "$repo/bin/fleet-heartbeat"
  cat >"$repo/bin/fleet-heartbeat-tier1" <<'SH'
#!/usr/bin/env bash
heartbeat_page_units
heartbeat_seat_health_check
SH
  chmod +x "$repo/bin/fleet-heartbeat-tier1"
  cat >"$repo/systemd/fleet-heartbeat.service" <<'SVC'
[Service]
EnvironmentFile=-/home/nish/.config/fleet-heartbeat/hc.env
SVC
}

# ============================================================================
# Scenario 1: VPS plane all covered, GitHub plane all covered, markers absent
# ============================================================================
reset_state
cover "good-worker.service"
cover "good-watcher.path"
cover "good-tick.timer"
exclude "unit-escalation@foo.service"
exclude "stop-escalation.service"
exclude "stop-escalation.path"
exclude "ready-work.service"
exclude "escalation-daily-sweep.service"
exclude "escalation-daily-sweep.timer"
exclude "resilience-drill-stub-restart.service"
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
# Scenario 1b (regression, 2026-08-27): the #455 resilience drill's throwaway
# stub must be in the anti-recursion exclusion set. The drill DELIBERATELY
# SIGKILLs the stub to prove Restart=always; that intentional kill marks the
# unit Result=signal and fires the global OnFailure=unit-escalation@%n.service
# drop-in, which used to summon a false SENIOR AUDITOR. The exclusion means
# the canary treats a loaded stub as EXCLUDED, not as a missing-escalation
# VIOLATION. A REAL drill failure still escalates via the drill unit itself.
# ============================================================================
reset_state
cover "good-worker.service"
exclude "resilience-drill-stub-restart.service"
sanctioned_wrapper "pi-issue-run"
write_intake "0509"
write_claim_repos "Nishfleet/0509"

run_canary

[[ "$env_rc" == 0 ]] || fail "scenario1b: must exit 0, got $env_rc ($env_out)"
grep -q 'ESCALATION-CANARY-EXCLUDED' "$triage" || fail "scenario1b: triage missing EXCLUDED"
! grep -q 'ESCALATION-CANARY-VIOLATION' "$triage" || fail "scenario1b: stub must not be a VIOLATION"
ok "scenario1b: resilience-drill-stub-restart.service is excluded (false-summons regression, fleet-ops#455)"

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
# Scenario 2b (fleet-ops#618): a loaded .path unit missing OnFailure is a
# VIOLATION. This is the class that missed fleet-seat-recovery.path
# (unit-start-limit-hit, empty OnFailure) because block 1 used
# --type=service only. If the canary regresses to service-only, this
# fixture path unit is filtered out and the test fails.
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
printf '%s\n' "naked.path" >>"$loaded"
: >"$onf_dir/naked.path"
sanctioned_wrapper "pi-issue-run"
write_intake "0509"
write_claim_repos "Nishfleet/0509"

run_canary

[[ "$env_rc" == 1 ]] || fail "scenario2b: must exit 1, got $env_rc ($env_out)"
grep -q 'ESCALATION-CANARY-VIOLATION' "$triage" || fail "scenario2b: triage missing VIOLATION"
grep -q 'unit=naked.path' "$triage" || fail "scenario2b: triage must name naked.path"
! grep -q 'ESCALATION-CANARY-OK' "$triage" || fail "scenario2b: triage must not contain OK"
ok "scenario2b: missing-escalation path unit named and canary exits 1 (fleet-ops#618)"

# ============================================================================
# Scenario 2c (fleet-ops#618): a loaded .timer unit missing OnFailure is a
# VIOLATION. Same class as 2b for timers.
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
printf '%s\n' "naked.timer" >>"$loaded"
: >"$onf_dir/naked.timer"
sanctioned_wrapper "pi-issue-run"
write_intake "0509"
write_claim_repos "Nishfleet/0509"

run_canary

[[ "$env_rc" == 1 ]] || fail "scenario2c: must exit 1, got $env_rc ($env_out)"
grep -q 'ESCALATION-CANARY-VIOLATION' "$triage" || fail "scenario2c: triage missing VIOLATION"
grep -q 'unit=naked.timer' "$triage" || fail "scenario2c: triage must name naked.timer"
! grep -q 'ESCALATION-CANARY-OK' "$triage" || fail "scenario2c: triage must not contain OK"
ok "scenario2c: missing-escalation timer unit named and canary exits 1 (fleet-ops#618)"

# ============================================================================
# Scenario 2d (fleet-ops#618): source lock. A future edit that lists only
# --type=service (or greps only .service$) reopens the hole. The canary
# must request service,path,timer in one list-units call.
# ============================================================================
canary_src="$repo_root/bin/fleet-escalation-canary"
grep -F -- '--type=service,path,timer' "$canary_src" >/dev/null \
  || fail "scenario2d: canary must list-units --type=service,path,timer (fleet-ops#618)"
if grep -n -- '--type=service' "$canary_src" | grep -v -- 'service,path,timer' >/dev/null; then
  fail "scenario2d: canary still has a service-only --type= list-units (fleet-ops#618)"
fi
grep -E "grep '\\\\.service\\\$'" "$canary_src" >/dev/null \
  && fail "scenario2d: canary still filters loaded units to .service only (fleet-ops#618)" || true
ok "scenario2d: canary source enumerates service, path, and timer (fleet-ops#618 class lock)"

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

# ============================================================================
# Scenario 9: bridge files present without marker -> canary sees it as wired
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
sanctioned_wrapper "pi-issue-run"
write_intake "0509"
write_claim_repos "Nishfleet/0509"
: >"$FLEET_ESCALATION_CANARY_DELIVERY"
: >"$FLEET_ESCALATION_CANARY_REDCI"
mkdir -p "$repo/.github/scripts"
: >"$repo/.github/workflows/ci-failure-escalation.yml"
: >"$repo/.github/scripts/ci-failure-escalation-detector.mjs"

run_canary

[[ "$env_rc" == 0 ]] || fail "scenario9: must exit 0, got $env_rc ($env_out)"
! grep -q 'senior-auditor bridge not wired' "$triage" || fail "scenario9: bridge files must suppress PENDING without marker"
grep -q 'pending=0' "$triage" || fail "scenario9: OK line must show pending=0"
ok "scenario9: bridge files present -> wired without marker"

# ============================================================================
# Scenario 10: #76 delivery wired in the repo (no marker) -> PENDING suppressed
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
sanctioned_wrapper "pi-issue-run"
wire_delivery
write_intake "0509"
write_claim_repos "Nishfleet/0509"
: >"$FLEET_ESCALATION_CANARY_REDCI"
mkdir -p "$repo/.github/scripts"
: >"$repo/.github/workflows/ci-failure-escalation.yml"
: >"$repo/.github/scripts/ci-failure-escalation-detector.mjs"

run_canary

[[ "$env_rc" == 0 ]] || fail "scenario10: must exit 0, got $env_rc ($env_out)"
! grep -q 'terminal delivery not wired (#76)' "$triage" || fail "scenario10: #76 PENDING must be suppressed by real wiring"
grep -q 'delivery wired' <<<"$env_out" || fail "scenario10: canary must log the delivery-wired observation"
grep -q 'pending=0' "$triage" || fail "scenario10: OK line must show pending=0 (all paths wired)"
ok "scenario10: #76 delivery wiring observed -> PENDING suppressed without marker"

# ============================================================================
# Scenario 11: #76 delivery wiring incomplete (no hc.env EnvironmentFile) -> PENDING
# ============================================================================
reset_state
cover "good-worker.service"
exclude "unit-escalation@foo.service"
sanctioned_wrapper "pi-issue-run"
wire_delivery
# Remove the hc.env EnvironmentFile line so the dead-man config is unwired.
cat >"$repo/systemd/fleet-heartbeat.service" <<'SVC'
[Service]
ExecStart=/bin/true
SVC
write_intake "0509"
write_claim_repos "Nishfleet/0509"
: >"$FLEET_ESCALATION_CANARY_REDCI"
: >"$FLEET_ESCALATION_CANARY_BRIDGE"

run_canary

[[ "$env_rc" == 0 ]] || fail "scenario11: must exit 0 (PENDING not fail), got $env_rc ($env_out)"
grep -q 'terminal delivery not wired (#76)' "$triage" || fail "scenario11: triage must name #76 delivery as PENDING"
! grep -q 'ESCALATION-CANARY-VIOLATION' "$triage" || fail "scenario11: incomplete wiring must be PENDING not VIOLATION"
ok "scenario11: #76 wiring incomplete -> PENDING naming the delivery gap"

# ============================================================================
# Scenario 12: live bin/ wrappers that invoke pi --print must be sanctioned
# ============================================================================
# Catches the #351 omission: pi-intake-repair-run was wired to a unit and
# MANIFEST but never added to SANCTIONED_PI_RUNNERS, so every heartbeat tick
# failed the canary (auditor summon 2026-08-26T16:18Z). fleet-ops#393 is the
# named follow-up: pin that wrapper AND the unit->wrapper class so a sibling
# cannot drop off the list without failing this test.
canary_src="$repo_root/bin/fleet-escalation-canary"
pi_print_re='^[^#]*(\bpi\b|"\$PI(_BIN)?")[[:space:]]+--print'

mapfile -t sanctioned_runners < <(
  awk '
    /^SANCTIONED_PI_RUNNERS=\(/ { inarr=1; next }
    inarr && /^\)/ { exit }
    inarr {
      gsub(/^[ \t]+/, "")
      gsub(/[ \t]+$/, "")
      if ($0 ~ /^#/ || $0 == "") next
      print $0
    }
  ' "$canary_src"
)
[[ ${#sanctioned_runners[@]} -gt 0 ]] || fail "scenario12: SANCTIONED_PI_RUNNERS array is empty"

in_sanctioned() {
  local want="$1" r
  for r in "${sanctioned_runners[@]}"; do
    [[ "$r" == "$want" ]] && return 0
  done
  return 1
}

in_sanctioned "pi-intake-repair-run" \
  || fail "scenario12: pi-intake-repair-run must stay on SANCTIONED_PI_RUNNERS (fleet-ops#393)"

mapfile -t live_pi_runners < <(
  grep -R -l --exclude='fleet-escalation-canary' \
    -E "$pi_print_re" \
    "$repo_root/bin" 2>/dev/null || true
)
[[ ${#live_pi_runners[@]} -gt 0 ]] || fail "scenario12: expected live pi wrappers under bin/"
for f in "${live_pi_runners[@]}"; do
  name=$(basename "$f")
  in_sanctioned "$name" \
    || fail "scenario12: bin/$name invokes pi --print but is missing from SANCTIONED_PI_RUNNERS"
done

# Unit side of the same class: a systemd ExecStart that points at a bin
# wrapper which invokes pi --print must have that wrapper on the list.
# This is the #351 / #393 shape (unit wired, wrapper live, list missed).
while IFS= read -r -d '' unit; do
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == ExecStart=* ]] || continue
    if [[ "$line" =~ /home/nish/.local/bin/([A-Za-z0-9._-]+) ]]; then
      wrapper="${BASH_REMATCH[1]}"
      [[ "$wrapper" == "pi" ]] && continue
      bin_path="$repo_root/bin/$wrapper"
      [[ -f "$bin_path" ]] || continue
      grep -qE "$pi_print_re" "$bin_path" || continue
      in_sanctioned "$wrapper" \
        || fail "scenario12: $(basename "$unit") ExecStart=$wrapper invokes pi --print but is missing from SANCTIONED_PI_RUNNERS"
    fi
  done < "$unit"
done < <(find "$repo_root/systemd" -name '*.service' -print0)

ok "scenario12: every live bin/ pi --print wrapper is on SANCTIONED_PI_RUNNERS"

ok "escalation-coverage-canary: covers VPS + GitHub planes, exclusions, and pending holes"

# ============================================================================
# Scenario 12 (fleet-ops#388): backup stale -> VIOLATION naming staleness
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
write_backup_stale

run_canary

[[ "$env_rc" == 1 ]] || fail "scenario12: must exit 1 (stale backup), got $env_rc ($env_out)"
grep -q 'backup staleness' "$triage" || fail "scenario12: triage must name backup staleness"
grep -q 'older than 30h threshold' "$triage" || fail "scenario12: triage must name the 30h threshold"
! grep -q 'ESCALATION-CANARY-OK' "$triage" || fail "scenario12: stale backup must not yield OK"
ok "scenario12: stale backup -> VIOLATION naming staleness + threshold"

# ============================================================================
# Scenario 13 (fleet-ops#388): backup service failed -> VIOLATION
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
write_backup_failed

run_canary

[[ "$env_rc" == 1 ]] || fail "scenario13: must exit 1 (failed backup), got $env_rc ($env_out)"
grep -q 'last Result=failed' "$triage" || fail "scenario13: triage must name the failed backup result"
ok "scenario13: failed backup service -> VIOLATION naming Result"

# ============================================================================
# Scenario 14 (fleet-ops#388): backup timer inactive -> VIOLATION
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
write_backup_inactive

run_canary

[[ "$env_rc" == 1 ]] || fail "scenario14: must exit 1 (inactive timer), got $env_rc ($env_out)"
grep -q 'not active' "$triage" || fail "scenario14: triage must name the inactive timer"
ok "scenario14: inactive backup timer -> VIOLATION"

# ============================================================================
# Scenario 15 (fleet-ops#388): fresh backup -> no staleness violation
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
write_backup_fresh

run_canary

[[ "$env_rc" == 0 ]] || fail "scenario15: must exit 0 (fresh backup), got $env_rc ($env_out)"
grep -q 'ESCALATION-CANARY-OK' "$triage" || fail "scenario15: triage missing OK"
! grep -q 'backup staleness' "$triage" || fail "scenario15: fresh backup must not raise staleness"
ok "scenario15: fresh backup -> OK with no staleness violation"

# ============================================================================
# Scenario 16 (fleet-ops#388): skip flag suppresses block 10
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
write_backup_stale
export FLEET_ESCALATION_CANARY_SKIP_BACKUP=1

run_canary

unset FLEET_ESCALATION_CANARY_SKIP_BACKUP
[[ "$env_rc" == 0 ]] || fail "scenario16: must exit 0 (skip flag), got $env_rc ($env_out)"
grep -q 'SKIP (FLEET_ESCALATION_CANARY_SKIP_BACKUP=1)' <<<"$env_out" || fail "scenario16: canary must log the SKIP"
! grep -q 'backup staleness' "$triage" || fail "scenario16: skip flag must suppress staleness"
ok "scenario16: skip flag suppresses block 10"

ok "escalation-coverage-canary: block 10 backup staleness (fleet-ops#388) covered"

# ============================================================================
# Scenario 17 (fleet-ops#529): vault-conflict timer inactive -> VIOLATION
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
write_vault_conflict_inactive

run_canary

[[ "$env_rc" == 1 ]] || fail "scenario17: must exit 1 (inactive vault-conflict timer), got $env_rc ($env_out)"
grep -q 'vault-conflict' "$triage" || fail "scenario17: triage must name vault-conflict"
grep -q 'not active' "$triage" || fail "scenario17: triage must name the inactive timer"
ok "scenario17: inactive vault-conflict timer -> VIOLATION"

# ============================================================================
# Scenario 18 (fleet-ops#529): vault-conflict service failed -> VIOLATION
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
write_vault_conflict_failed

run_canary

[[ "$env_rc" == 1 ]] || fail "scenario18: must exit 1 (failed resolver), got $env_rc ($env_out)"
grep -q 'last Result=failed' "$triage" || fail "scenario18: triage must name the failed resolver result"
ok "scenario18: failed vault-conflict service -> VIOLATION naming Result"

# ============================================================================
# Scenario 19 (fleet-ops#529): resolver missing -> VIOLATION
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
rm -f "$repo/lib/vault-conflict-resolver.py"

run_canary

[[ "$env_rc" == 1 ]] || fail "scenario19: must exit 1 (missing resolver), got $env_rc ($env_out)"
grep -q 'resolver missing' "$triage" || fail "scenario19: triage must name the missing resolver"
ok "scenario19: missing resolver -> VIOLATION (2026-08-23 wipe class)"

# ============================================================================
# Scenario 20 (fleet-ops#529): skip flag suppresses block 11
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
write_vault_conflict_inactive
export FLEET_ESCALATION_CANARY_SKIP_VAULT_CONFLICT=1

run_canary

unset FLEET_ESCALATION_CANARY_SKIP_VAULT_CONFLICT
[[ "$env_rc" == 0 ]] || fail "scenario20: must exit 0 (skip flag), got $env_rc ($env_out)"
grep -q 'SKIP (FLEET_ESCALATION_CANARY_SKIP_VAULT_CONFLICT=1)' <<<"$env_out" || fail "scenario20: canary must log the SKIP"
! grep -q 'vault-conflict:' "$triage" || fail "scenario20: skip flag must suppress vault-conflict"
ok "scenario20: skip flag suppresses block 11"

# ============================================================================
# Scenario 21 (fleet-ops#529): fresh handler + fixture clear -> no violation
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

[[ "$env_rc" == 0 ]] || fail "scenario21: must exit 0 (fresh handler), got $env_rc ($env_out)"
grep -q 'fixture \*.sync-conflict-\* cleared' <<<"$env_out" \
  || grep -q 'fixture *.sync-conflict-* cleared' <<<"$env_out" \
  || fail "scenario21: canary must log fixture cleared (out=$env_out)"
! grep -q 'vault-conflict:' "$triage" || fail "scenario21: fresh handler must not raise vault-conflict"
ok "scenario21: fixture *.sync-conflict-* cleared -> OK"

ok "escalation-coverage-canary: block 11 vault-conflict (fleet-ops#529) covered"

# fleet-ops#387: entitled-vs-wired is a sibling heartbeat canary. Invoked from
# this CI-listed file so hosted runners run it without a workflow edit
# (worker tokens cannot push .github/workflows/**).
bash "$here/entitled-wired-canary.test.sh"

# fleet-ops#388: restore drill. Invoked from this CI-listed file so hosted
# runners run it without a workflow edit (worker tokens cannot push
# .github/workflows/**).
bash "$here/fleet-restore-drill.test.sh"

# fleet-ops#455: four-plane resilience drill. Invoked from this CI-listed
# file so hosted runners run it without a workflow edit (worker tokens
# cannot push .github/workflows/**).
bash "$here/fleet-resilience-drill.test.sh"

# fleet-ops#480: escalation completion enforcer. Invoked from this CI-listed
# file so hosted runners run it without a workflow edit (worker tokens cannot
# push .github/workflows/**).
bash "$here/fleet-escalation-completion.test.sh"

# fleet-ops#536: proven-only Pi extension allowlist. Invoked from this
# CI-listed file so hosted runners run it without a workflow edit
# (worker tokens cannot push .github/workflows/**).
bash "$here/fleet-pi-extensions-canary.test.sh"

# fleet-ops#634: free-model roster canary. Invoked from this CI-listed file
# so hosted runners run it without a workflow edit (worker tokens cannot
# push .github/workflows/**). PR #624 (fleet-ops#518) shipped the canary and
# the offline test but did not wire it into the CI list; this source line
# is the same shape as the sibling canaries above.
bash "$here/fleet-free-roster-canary.test.sh"

# fleet-ops#917: SuperGrok live-validate canary. Invoked from this CI-listed
# file so hosted runners run it without a workflow edit (worker tokens cannot
# push .github/workflows/**).
bash "$here/fleet-seat-live-validate.test.sh"

# fleet-ops#938: vacation-window credential expiry canary. Invoked from this
# CI-listed file so hosted runners run it without a workflow edit
# (worker tokens cannot push .github/workflows/**).
bash "$here/credential-expiry-canary.test.sh"

# fleet-ops#1166: sanctioned VPS Cloudflare token liveness canary. Invoked
# from this CI-listed file so hosted runners run it without a workflow edit
# (worker tokens cannot push .github/workflows/**).
bash "$here/cf-token-canary.test.sh"

