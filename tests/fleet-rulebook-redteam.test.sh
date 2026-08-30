#!/usr/bin/env bash
# tests/fleet-rulebook-redteam.test.sh
#
# Proves fleet-ops#527 (sr-gap-rules-audit) offline:
#   1. Sibling backups are written before filing; SKIP_BACKUP is a hard fail.
#   2. Drill files a fixture finding as gap-audit + agent-ready.
#   3. Timer is monthly + Persistent=true.
#   4. Cadence-overdue canary LOUDs on a stale/missing stamp.
#   5. Heading-growth bonus starts the unit; no-growth and active unit do not.
#   6. Matrix row is enforced; heartbeat §39 is wired; MANIFEST installs.
#   7. Nested CI host (this file is invoked from rule-enforcement.test.sh).
#
# Live pi / systemctl start of the real unit are the outermost edges
# and are stubbed. The drill path is the real run.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-rulebook-redteam"
lib="$repo_root/lib/rulebook-redteam-cadence.sh"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
unit="$repo_root/systemd/fleet-rulebook-redteam.service"
timer="$repo_root/systemd/fleet-rulebook-redteam.timer"
prompt="$repo_root/prompts/rulebook-redteam.md"
manifest="$repo_root/MANIFEST"
matrix="$repo_root/config/rule-enforcement.json"
fixture="$repo_root/tests/fixtures/rulebook-redteam-drill-finding.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$tier1" ]] || fail "missing $tier1"
[[ -f "$unit" ]] || fail "missing $unit"
[[ -f "$timer" ]] || fail "missing $timer"
[[ -f "$prompt" ]] || fail "missing $prompt"
[[ -f "$fixture" ]] || fail "missing $fixture"
command -v jq >/dev/null 2>&1 || fail "jq missing"
bash -n "$bin" || fail "runner: bash -n"
bash -n "$lib" || fail "cadence lib: bash -n"
ok "scripts compile"

scratch="$(mktemp -d -t fleet-rulebook-redteam.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"
mkdir -p "$HOME" "$scratch/rules" "$scratch/fakebin" "$scratch/state"

printf '## Alpha\n\nkeep\n' >"$scratch/rules/standing.md"
printf '## Local\n' >"$scratch/rules/AGENTS.md"

cat >"$scratch/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "${1:-}" in
  label) exit 0 ;;
  issue)
    case "${2:-}" in
      list) printf '[]\n' ;;
      create)
        echo "https://github.com/Nishfleet/fleet-ops/issues/5271"
        echo create >>"${GH_CREATED:-/dev/null}"
        printf 'CREATE %s\n' "$*" >>"${GH_CREATE_LOG:-/dev/null}"
        ;;
    esac
    ;;
  *) exit 0 ;;
esac
exit 0
FAKE
chmod +x "$scratch/fakebin/gh"

cat >"$scratch/fakebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CALLS:-/dev/null}"
case "$*" in
  *is-active*)
    if [[ -f "${ACTIVE_UNITS:-/dev/null}" ]] && grep -qx "${RULEBOOK_REDTEAM_UNIT:-fleet-rulebook-redteam.service}" "${ACTIVE_UNITS}"; then
      echo active
    else
      echo inactive
    fi
    ;;
  *start*)
    echo "start --no-block ${RULEBOOK_REDTEAM_UNIT:-fleet-rulebook-redteam.service}" >>"${CALLS:-/dev/null}"
    ;;
esac
exit 0
FAKE
chmod +x "$scratch/fakebin/systemctl"

export PATH="$scratch/fakebin:$PATH"
export GH="$scratch/fakebin/gh"
export SYSTEMCTL="$scratch/fakebin/systemctl"
export CALLS="$scratch/calls"
export GH_LOG="$scratch/gh.log"
export GH_CREATED="$scratch/created.txt"
export GH_CREATE_LOG="$scratch/gh-create.log"
export FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md"
: >"$CALLS"
: >"$GH_LOG"
: >"$GH_CREATED"
: >"$GH_CREATE_LOG"
: >"$FLEET_HEARTBEAT_TRIAGE"

plan="$scratch/plan.md"
printf 'last-heartbeat: 2026-08-27T00:00:00Z\n' >"$plan"

run_drill() {
  RULEBOOK_DRILL=1 \
  RULEBOOK_DRILL_FINDINGS="$fixture" \
  RULEBOOK_STATE_DIR="$scratch/state" \
  RULEBOOK_PLAN_FILE="$plan" \
  RULEBOOK_STANDING_RULES="$scratch/rules/standing.md" \
  RULEBOOK_RULE_FILES="$scratch/rules/standing.md
$scratch/rules/AGENTS.md" \
  RULEBOOK_FAKE_NOW="2026-08-27T04:15:00Z" \
  RULEBOOK_SKIP_BACKUP="${RULEBOOK_SKIP_BACKUP:-0}" \
    "$bin"
}

# --- 1. backup gate --------------------------------------------------------
RULEBOOK_SKIP_BACKUP=1
set +e
skip_out=$(run_drill 2>&1)
skip_rc=$?
set -e
unset RULEBOOK_SKIP_BACKUP
[[ "$skip_rc" == "2" ]] || fail "SKIP_BACKUP must exit 2, got $skip_rc ($skip_out)"
grep -q 'no sibling backups' <<<"$skip_out" \
  || fail "SKIP_BACKUP must name the backup gate: $skip_out"
if grep -q create "$GH_CREATED"; then
  fail "SKIP_BACKUP must not file: $(cat "$GH_CREATED")"
fi
ok "backup gate: SKIP_BACKUP=1 refuses to file (exit 2)"

# --- 2. drill: backups + filing -------------------------------------------
: >"$GH_CREATED"
: >"$GH_CREATE_LOG"
rm -rf "$scratch/state"
mkdir -p "$scratch/state"
set +e
drill_out=$(run_drill 2>&1)
drill_rc=$?
set -e
[[ "$drill_rc" == "0" ]] || fail "drill should exit 0, got $drill_rc ($drill_out)"
[[ -f "$scratch/rules/standing.md.bak-rulebook-redteam-20260827" ]] \
  || fail "missing sibling backup of standing.md"
[[ -f "$scratch/rules/AGENTS.md.bak-rulebook-redteam-20260827" ]] \
  || fail "missing sibling backup of AGENTS.md"
grep -q create "$GH_CREATED" || fail "drill must file: $(cat "$GH_LOG")"
grep -E 'CREATE .*--label gap-audit' "$GH_CREATE_LOG" >/dev/null \
  || fail "filed issue must carry gap-audit: $(cat "$GH_CREATE_LOG")"
grep -E 'CREATE .*--label agent-ready' "$GH_CREATE_LOG" >/dev/null \
  || fail "filed issue must carry agent-ready (fleet-ops#402): $(cat "$GH_CREATE_LOG")"
grep -E 'CREATE .*--body-file ' "$GH_CREATE_LOG" >/dev/null \
  || fail "gh issue create must use --body-file: $(cat "$GH_CREATE_LOG")"
grep -qE '^last-rulebook-redteam-run:' "$plan" \
  || fail "plan missing last-rulebook-redteam-run stamp"
[[ -f "$scratch/state/last-heading-count" ]] \
  || fail "runner must store last-heading-count"
ok "drill: sibling backups, gap-audit+agent-ready file, stamp"

# --- 3. timer shape --------------------------------------------------------
grep -qE '^OnCalendar=\*-\*-\*01 04:15:00$' "$timer" \
  || grep -qE '^OnCalendar=\*-\*-01 04:15:00$' "$timer" \
  || fail "timer must be OnCalendar=*-*-01 04:15:00 (monthly floor), got $(grep OnCalendar "$timer")"
grep -q '^Persistent=true$' "$timer" || fail "timer must be Persistent=true"
grep -q '^WantedBy=timers.target$' "$timer" || fail "timer WantedBy=timers.target"
grep -q 'Type=oneshot' "$unit" || fail "unit must be oneshot"
grep -q 'Restart=no' "$unit" || fail "unit must be Restart=no"
grep -q "ExecStart=/bin/bash -c 'exec /home/nish/.local/bin/fleet-rulebook-redteam'" "$unit" \
  || fail "unit ExecStart must wrap the bin in bash -c (CI systemd-analyze stubs)"
ok "timer monthly + Persistent; unit oneshot Restart=no"

if command -v systemd-analyze >/dev/null 2>&1; then
  if ! systemd-analyze verify --man=no "$unit"; then
    fail "systemd-analyze verify failed for fleet-rulebook-redteam.service"
  fi
  if ! systemd-analyze verify --man=no "$timer"; then
    fail "systemd-analyze verify failed for fleet-rulebook-redteam.timer"
  fi
  ok "systemd-analyze verify accepts the unit and timer"
fi

# --- 4. cadence canary -----------------------------------------------------
# shellcheck source=../lib/rulebook-redteam-cadence.sh
source "$lib"

loud_count() {
    local n
    n="$(grep -c 'RULEBOOK-REDTEAM-CADENCE-OVERDUE' "$FLEET_HEARTBEAT_TRIAGE" 2>/dev/null || true)"
    [ -n "$n" ] || n=0
    printf '%s\n' "$n"
}
write_stamp() {
    local stamp="$1" state="${2:-completed, filed=1}"
    printf 'last-heartbeat: 2026-08-27T00:00:00Z\n' >"$plan"
    printf 'last-rulebook-redteam-run: %s (%s)\n' "$stamp" "$state" >>"$plan"
}

export PLAN_FILE="$plan"
unset RULEBOOK_CADENCE_DISABLE || true
unset RULEBOOK_CADENCE_MAX_AGE_S || true

: >"$FLEET_HEARTBEAT_TRIAGE"
fresh_stamp="$(date -u -d "@$(( $(date +%s) - 5*86400 ))" +%Y-%m-%dT%H:%M:%SZ)"
write_stamp "$fresh_stamp"
heartbeat_rulebook_redteam_cadence_canary
[[ "$rulebook_canary_status" == "ok" ]] || fail "fresh stamp must be ok, got $rulebook_canary_status"
[[ "$(loud_count)" == "0" ]] || fail "fresh stamp must not LOUD"
ok "cadence: fresh stamp -> ok"

: >"$FLEET_HEARTBEAT_TRIAGE"
stale_stamp="$(date -u -d "@$(( $(date +%s) - 40*86400 ))" +%Y-%m-%dT%H:%M:%SZ)"
write_stamp "$stale_stamp"
heartbeat_rulebook_redteam_cadence_canary
[[ "$rulebook_canary_status" == "overdue" ]] || fail "stale stamp must be overdue, got $rulebook_canary_status"
[[ "$(loud_count)" -ge 1 ]] || fail "stale stamp must LOUD"
ok "cadence: 40d stamp -> overdue + LOUD"

: >"$FLEET_HEARTBEAT_TRIAGE"
printf 'last-heartbeat: 2026-08-27T00:00:00Z\n' >"$plan"
heartbeat_rulebook_redteam_cadence_canary
[[ "$rulebook_canary_status" == "never-ran" ]] || fail "blank plan must be never-ran, got $rulebook_canary_status"
ok "cadence: missing stamp -> never-ran"

# --- 5. heading-growth bonus ----------------------------------------------
export RULEBOOK_STANDING_RULES="$scratch/rules/standing.md"
export RULEBOOK_STATE_DIR="$scratch/bonus-state"
export RULEBOOK_REDTEAM_UNIT="fleet-rulebook-redteam.service"
mkdir -p "$RULEBOOK_STATE_DIR"
printf '0\n' >"$RULEBOOK_STATE_DIR/last-heading-count"
: >"$CALLS"
heartbeat_rulebook_redteam_heading_bonus
[[ "$rulebook_heading_bonus" == "started" ]] || fail "heading growth must start, got $rulebook_heading_bonus"
grep -q 'start --no-block fleet-rulebook-redteam.service' "$CALLS" \
  || fail "heading growth must start the unit: $(cat "$CALLS")"
ok "heading bonus: growth starts the unit"

printf '99\n' >"$RULEBOOK_STATE_DIR/last-heading-count"
: >"$CALLS"
heartbeat_rulebook_redteam_heading_bonus
[[ "$rulebook_heading_bonus" == "no-growth" ]] || fail "no growth must skip, got $rulebook_heading_bonus"
! grep -q 'start --no-block' "$CALLS" || fail "no growth must not start"
ok "heading bonus: no growth is a no-op"

printf '0\n' >"$RULEBOOK_STATE_DIR/last-heading-count"
printf '%s\n' 'fleet-rulebook-redteam.service' >"$scratch/active"
export ACTIVE_UNITS="$scratch/active"
: >"$CALLS"
heartbeat_rulebook_redteam_heading_bonus
[[ "$rulebook_heading_bonus" == "already-running" ]] || fail "active unit must no-op, got $rulebook_heading_bonus"
ok "heading bonus: active unit is a no-op"
unset ACTIVE_UNITS

# --- 6. matrix, heartbeat, MANIFEST, sanctioned runner ---------------------
jq -e '.rules[] | select(.id == "sr-gap-rules-audit" and .status == "enforced")' \
  "$matrix" >/dev/null \
  || fail "sr-gap-rules-audit must be status=enforced in the matrix"
grep -F 'heartbeat_rulebook_redteam_cadence_canary' "$tier1" >/dev/null \
  || fail "tier1 §39 must call heartbeat_rulebook_redteam_cadence_canary"
grep -F 'heartbeat_rulebook_redteam_heading_bonus' "$tier1" >/dev/null \
  || fail "tier1 §39 must call heartbeat_rulebook_redteam_heading_bonus"
grep -F 'rulebook-redteam-cadence.sh' "$tier1" >/dev/null \
  || fail "tier1 §39 must source lib/rulebook-redteam-cadence.sh"
grep -Fq 'bin/fleet-rulebook-redteam /home/nish/.local/bin/fleet-rulebook-redteam' "$manifest" \
  || fail "MANIFEST missing runner"
grep -Fq 'lib/rulebook-redteam-cadence.sh /home/nish/.local/lib/pi-packet/rulebook-redteam-cadence.sh' "$manifest" \
  || fail "MANIFEST missing cadence lib"
grep -Fq 'prompts/rulebook-redteam.md /home/nish/.pi/agent/prompts/rulebook-redteam.md' "$manifest" \
  || fail "MANIFEST missing prompt"
grep -Fq 'systemd/fleet-rulebook-redteam.service /home/nish/.config/systemd/user/fleet-rulebook-redteam.service' "$manifest" \
  || fail "MANIFEST missing service"
grep -Fq 'systemd/fleet-rulebook-redteam.timer /home/nish/.config/systemd/user/fleet-rulebook-redteam.timer' "$manifest" \
  || fail "MANIFEST missing timer"
grep -F 'fleet-rulebook-redteam' "$repo_root/bin/fleet-escalation-canary" >/dev/null \
  || fail "fleet-rulebook-redteam must be on SANCTIONED_PI_RUNNERS"
grep -Fq 'bash "$here/fleet-rulebook-redteam.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "matrix enforced, §39 wired, MANIFEST, SANCTIONED_PI_RUNNERS, nested CI host"

# --- 7. packet assembly survives a missing LAST rule file -----------------
# Regression: the rule_files_list pipeline runs under `set -o pipefail`, so a
# failing `[ -f ]` on the final entry used to kill the run right after seat
# selection. The drill path skips packet assembly, so only a non-drill run
# catches it. Missing rule files are a reported SKIP, never a failure.
cat >"$scratch/fakebin/pi" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$scratch/fakebin/pi"
cat >"$scratch/seat-lib.sh" <<'FAKE'
pick_seat() { printf 'devin swe-1-7\n'; }
FAKE
rm -rf "$scratch/state-packet"
set +e
packet_out=$(RULEBOOK_DRY_RUN=1 \
  RULEBOOK_STATE_DIR="$scratch/state-packet" \
  RULEBOOK_PLAN_FILE="$plan" \
  RULEBOOK_STANDING_RULES="$scratch/rules/standing.md" \
  RULEBOOK_RULE_FILES="$scratch/rules/standing.md
$scratch/rules/does-not-exist.md" \
  RULEBOOK_SEAT_LIB="$scratch/seat-lib.sh" \
  RULEBOOK_PI_BIN="$scratch/fakebin/pi" \
  RULEBOOK_FAKE_NOW="2026-08-27T04:15:00Z" \
  "$bin" 2>&1)
packet_rc=$?
set -e
[[ "$packet_rc" == "0" ]] \
  || fail "missing last rule file must not fail the run (rc=$packet_rc): $packet_out"
grep -q 'skip missing rule file' <<<"$packet_out" \
  || fail "a missing rule file must be reported as a SKIP: $packet_out"
packet="$scratch/state-packet"
pkt_file=$(find "$packet" -name packet.md -print | sort | head -1)
[[ -n "$pkt_file" ]] || fail "packet.md was never assembled under $packet"
grep -q '## Run context' "$pkt_file" \
  || fail "packet must end with the volatile Run context block: $pkt_file"
if grep -qF '{{' "$pkt_file"; then
  fail "packet must not carry unsubstituted placeholders: $pkt_file"
fi
static_first=$(grep -n '^## Run context$' "$pkt_file" | tail -1 | cut -d: -f1)
[[ -n "$static_first" ]] || fail "packet has no '## Run context' heading: $pkt_file"
total=$(wc -l <"$pkt_file")
[[ "$static_first" -gt $((total * 7 / 10)) ]] \
  || fail "Run context must sit in the last 30% (line $static_first of $total)"
ok "packet assembly: missing last rule file is a SKIP, run context is last"

ok "fleet-ops#527 rulebook red-team: backups, drill, timer, cadence, heading bonus"
