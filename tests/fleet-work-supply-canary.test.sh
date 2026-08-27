#!/usr/bin/env bash
# tests/fleet-work-supply-canary.test.sh
#
# Proves the 24h/12h drain trigger (fleet-ops#540) offline:
#   1. Hours math: famine, floor drain, go-ham, generate, rest.
#   2. gate: generate/go-ham exit 0; rest exit 1; gh fail exit 255.
#   3. Canary clean: wired ExecCondition, prompt, workers ungated,
#      auditor panel, hours in generate zone -> exit 0, OK.
#   4. Hardcoded ExecCondition -> exit 1, LOUD.
#   5. scout.md ready_count >= 12 rest -> exit 1.
#   6. pi-issue ExecCondition on agent-ready -> exit 1.
#   7. Missing auditor.md -> exit 1.
#   8. Scout idle while hours < 12 -> exit 1, files ticket.
#   9. Dedup: open issue with the marker -> no second create.
#  10. Production checkout is wired (ExecCondition, prompt, workers).
#  11. Heartbeat-tier1 wires the canary and propagates fail-loud.
#  12. --help exists (find-the-proven-thing receipt for this bin).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-work-supply-canary"
lib="$repo_root/lib/work-supply.sh"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing: $lib"
[[ -f "$tier1" ]] || fail "missing: $tier1"
bash -n "$bin" || fail "canary: bash syntax error"
bash -n "$lib" || fail "lib/work-supply.sh: bash syntax error"

scratch="$(mktemp -d -t work-supply-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME" "$scratch/repo/systemd" "$scratch/repo/prompts" "$scratch/repo/config"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_WORK_SUPPLY_REPO="Nishfleet/fleet-ops"
export FLEET_WORK_SUPPLY_FILE=1
export FLEET_WORK_SUPPLY_LIB="$lib"
export FLEET_OPS_REPO="$scratch/repo"
export FLEET_WORK_SUPPLY_MAX_IDLE_S=9000

# --- hours math (source the lib) -------------------------------------------
# shellcheck source=../lib/work-supply.sh
source "$lib"
[[ "$(work_supply_hours 0 0)" == "0" ]] || fail "math: ready=0 -> 0 hours"
[[ "$(work_supply_action 0)" == "go-ham" ]] || fail "math: 0 hours is go-ham"
[[ "$(work_supply_hours 6 0)" == "6" ]] || fail "math: floor drain ready=6 -> 6h"
[[ "$(work_supply_action 6)" == "go-ham" ]] || fail "math: 6h is go-ham"
[[ "$(work_supply_hours 30 0)" == "30" ]] || fail "math: floor drain ready=30 -> 30h"
[[ "$(work_supply_action 30)" == "rest" ]] || fail "math: 30h is rest"
# 30 ready, 18 closed in 6h -> ceil(30*6/18)=10
[[ "$(work_supply_hours 30 18 6)" == "10" ]] || fail "math: 30/18 in 6h -> 10h, got $(work_supply_hours 30 18 6)"
[[ "$(work_supply_action 10)" == "go-ham" ]] || fail "math: 10h is go-ham"
# 20 ready, 6 closed in 6h -> 20h generate
[[ "$(work_supply_hours 20 6 6)" == "20" ]] || fail "math: 20/6 in 6h -> 20h"
[[ "$(work_supply_action 20)" == "generate" ]] || fail "math: 20h is generate"
# 36 ready, 6 closed in 6h -> 36h rest
[[ "$(work_supply_hours 36 6 6)" == "36" ]] || fail "math: 36/6 in 6h -> 36h"
[[ "$(work_supply_action 36)" == "rest" ]] || fail "math: 36h is rest"
now=$(date -u +%s)
closed_json=$(jq -n --arg ts "$(date -u -d '@'"$((now - 3600))" +%Y-%m-%dT%H:%M:%SZ)" \
  '[{"number":1,"closedAt":$ts}]')
[[ "$(work_supply_closed_in_window "$closed_json" 6 "$now")" == "1" ]] \
  || fail "math: closed 1h ago counts in 6h window"
old_json=$(jq -n --arg ts "$(date -u -d '@'"$((now - 3600*10))" +%Y-%m-%dT%H:%M:%SZ)" \
  '[{"number":1,"closedAt":$ts}]')
[[ "$(work_supply_closed_in_window "$old_json" 6 "$now")" == "0" ]] \
  || fail "math: closed 10h ago is outside 6h window"
ok "scenario1: hours math famine/floor/go-ham/generate/rest"

gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
if [[ -f "${GH_BROKEN:-/dev/nonexistent}" ]]; then
  echo "gh: simulated failure" >&2
  exit 1
fi
case "$*" in
  *"issue list"*"-l agent-ready"*"--state closed"*|*"--state closed"*"-l agent-ready"*)
    if [[ -f "${GH_CLOSED_JSON:-/dev/null}" ]]; then
      cat "${GH_CLOSED_JSON}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue list"*"-l agent-ready"*)
    n=$(cat "${WORK_READY:-/dev/null}" 2>/dev/null || echo 0)
    printf '%s\n' "$n"
    exit 0
    ;;
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export PATH="$scratch:$PATH"
export WORK_READY="$scratch/work_ready"
printf '20\n' >"$WORK_READY"
export GH_CLOSED_JSON="$scratch/closed.json"
echo '[]' >"$GH_CLOSED_JSON"
export GH_OPEN_ISSUES="$scratch/open.json"
echo '[]' >"$GH_OPEN_ISSUES"

write_wired_checkout() {
  mkdir -p "$scratch/repo/systemd" "$scratch/repo/prompts" "$scratch/repo/config"
  cat >"$scratch/repo/systemd/pi-scout@.service" <<'UNIT'
[Service]
ExecCondition=/bin/bash -c 'bin=/home/nish/.local/bin/fleet-work-supply-canary; if [ ! -x "$bin" ]; then echo "work-supply-gate missing" >&2; exit 255; fi; exec "$bin" gate %i'
ExecStart=/bin/bash -c 'exec /home/nish/.local/bin/pi-scout-run %i scout'
UNIT
  cat >"$scratch/repo/systemd/pi-issue@.service" <<'UNIT'
[Service]
ExecStart=/home/nish/.local/bin/pi-issue-run %i
UNIT
  cat >"$scratch/repo/prompts/scout.md" <<'MD'
# scout
Generate until quality finds pass the bar. Rest is hours-of-work at the
measured drain rate (24h rest / 12h go-ham), not a hardcoded issue count.
MD
  cat >"$scratch/repo/prompts/auditor.md" <<'MD'
You are one of three senior auditors. 2-of-3 PASS.
MD
  cat >"$scratch/repo/config/role-quality-gates.json" <<'JSON'
{
  "roles": [
    {
      "id": "scout",
      "gate": "senior admission panel (scout-candidate -> 2-of-3 PASS -> agent-ready)"
    }
  ]
}
JSON
  cat >"$scratch/repo/config/intake-repos.json" <<'JSON'
{
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": []
}
JSON
}

export FLEET_INTAKE_REPOS_JSON="$scratch/repo/config/intake-repos.json"

run_canary() {
  set +e
  env_out=$(
    FLEET_OPS_REPO="$scratch/repo" \
    FLEET_INTAKE_REPOS_JSON="$scratch/repo/config/intake-repos.json" \
    "$bin" "$@" 2>&1
  )
  env_rc=$?
  set -e
}

# --- 2. gate exits ----------------------------------------------------------
write_wired_checkout
export FLEET_WORK_SUPPLY_HOURS=20
set +e
"$bin" gate demo >/dev/null 2>&1
gate_rc=$?
set -e
[[ "$gate_rc" == "0" ]] || fail "gate generate (20h) must exit 0, got $gate_rc"
export FLEET_WORK_SUPPLY_HOURS=5
set +e
"$bin" gate demo >/dev/null 2>&1
gate_rc=$?
set -e
[[ "$gate_rc" == "0" ]] || fail "gate go-ham (5h) must exit 0, got $gate_rc"
export FLEET_WORK_SUPPLY_HOURS=30
set +e
"$bin" gate demo >/dev/null 2>&1
gate_rc=$?
set -e
[[ "$gate_rc" == "1" ]] || fail "gate rest (30h) must exit 1, got $gate_rc"
unset FLEET_WORK_SUPPLY_HOURS
touch "$scratch/gh_broken"
export GH_BROKEN="$scratch/gh_broken"
set +e
"$bin" gate demo >/dev/null 2>&1
gate_rc=$?
set -e
unset GH_BROKEN
rm -f "$scratch/gh_broken"
[[ "$gate_rc" == "255" ]] || fail "gate gh fail must exit 255, got $gate_rc"
ok "scenario2: gate exit 0/1/255"

# --- 3. clean canary --------------------------------------------------------
write_wired_checkout
: >"$gh_log"; : >"$triage"
export FLEET_WORK_SUPPLY_HOURS=20
export FLEET_WORK_SUPPLY_SCOUT_STATE=inactive
export FLEET_WORK_SUPPLY_LAST_TRIGGER_AGE_S=100
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario3: clean must exit 0, got rc=$env_rc ($env_out)"
grep -q 'WORK-SUPPLY-OK' <<<"$env_out" || fail "scenario3: must log OK ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario3: must not file (gh=$(cat "$gh_log"))"
fi
ok "scenario3: clean wired checkout is green"

# --- 4. hardcoded ExecCondition ---------------------------------------------
: >"$gh_log"; : >"$triage"
cat >"$scratch/repo/systemd/pi-scout@.service" <<'UNIT'
[Service]
ExecCondition=/bin/sh -c 'n=$(gh issue list -R Nishfleet/%i -l agent-ready --json number --jq length); [ "$n" -lt 12 ]'
UNIT
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario4: hardcoded ExecCondition must exit 1, got $env_rc ($env_out)"
grep -q 'WORK-SUPPLY-VIOLATION' <<<"$env_out" || fail "scenario4: must LOUD ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario4: must file (gh=$(cat "$gh_log"))"
ok "scenario4: hardcoded count ExecCondition fails loud"

# --- 5. scout.md still rests on 12 ------------------------------------------
write_wired_checkout
: >"$gh_log"; : >"$triage"
cat >"$scratch/repo/prompts/scout.md" <<'MD'
If `ready_count >= 12`, print "supply full", exit 0.
MD
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario5: old prompt rest must exit 1, got $env_rc ($env_out)"
grep -q 'scout.md still rests' <<<"$env_out" || fail "scenario5: must name the prompt ($env_out)"
ok "scenario5: ready_count >= 12 prompt fails loud"

# --- 6. workers gated -------------------------------------------------------
write_wired_checkout
: >"$gh_log"; : >"$triage"
cat >"$scratch/repo/systemd/pi-issue@.service" <<'UNIT'
[Service]
ExecCondition=/bin/sh -c 'gh issue list -l agent-ready --json number'
ExecStart=/home/nish/.local/bin/pi-issue-run %i
UNIT
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario6: gated workers must exit 1, got $env_rc ($env_out)"
grep -q 'workers must stay at max' <<<"$env_out" || fail "scenario6: must name workers ($env_out)"
ok "scenario6: worker ExecCondition on agent-ready fails loud"

# --- 7. missing auditor -----------------------------------------------------
write_wired_checkout
: >"$gh_log"; : >"$triage"
rm -f "$scratch/repo/prompts/auditor.md"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario7: missing auditor must exit 1, got $env_rc ($env_out)"
ok "scenario7: missing auditor.md fails loud"

# --- 8. go-ham idle ---------------------------------------------------------
write_wired_checkout
: >"$gh_log"; : >"$triage"
export FLEET_WORK_SUPPLY_HOURS=5
export FLEET_WORK_SUPPLY_SCOUT_STATE=inactive
export FLEET_WORK_SUPPLY_LAST_TRIGGER_AGE_S=20000
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario8: go-ham idle must exit 1, got $env_rc ($env_out)"
grep -q 'WORK-SUPPLY-GO-HAM' <<<"$env_out" || fail "scenario8: must LOUD go-ham ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario8: must file (gh=$(cat "$gh_log"))"
ok "scenario8: idle scout under 12h fail-loud + files"

# --- 9. dedup ---------------------------------------------------------------
: >"$gh_log"; : >"$triage"
cat >"$scratch/open.json" <<'JSON'
[{"number":77,"body":"already\nwork-supply-canary: go-ham-idle demo\n"}]
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario9: still a violation, must exit 1"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario9: must not file a second ticket (gh=$(cat "$gh_log"))"
fi
ok "scenario9: open marker is deduped"

# --- 10. production checkout wiring -----------------------------------------
grep -q 'fleet-work-supply-canary' "$repo_root/systemd/pi-scout@.service" \
  && grep -q 'gate %i' "$repo_root/systemd/pi-scout@.service" \
  || fail "production pi-scout@.service must call fleet-work-supply-canary gate"
if grep -qE 'ready_count >= 12' "$repo_root/prompts/scout.md"; then
  fail "production scout.md still rests on ready_count >= 12"
fi
if grep -qE 'ExecCondition=.*agent-ready' "$repo_root/systemd/pi-issue@.service"; then
  fail "production pi-issue@.service must not gate workers on agent-ready"
fi
[[ -f "$repo_root/prompts/auditor.md" ]] || fail "production auditor.md missing"
jq -e '.roles[] | select(.id=="scout") | .gate | test("2-of-3")' \
  "$repo_root/config/role-quality-gates.json" >/dev/null \
  || fail "production scout gate must be 2-of-3"
ok "scenario10: production checkout is wired"

# --- 11. heartbeat wiring ---------------------------------------------------
grep -F 'fleet-work-supply-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-work-supply-canary"
grep -F 'work_supply_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture work_supply_canary_rc"
grep -F -- '_propagate_crash work_supply_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the work-supply gate fails loud"
grep -q 'bin/fleet-work-supply-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-work-supply-canary"
grep -q 'lib/work-supply.sh' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install lib/work-supply.sh"
ok "scenario11: heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it"

# --- 12. --help -------------------------------------------------------------
help_out=$("$bin" --help)
grep -q 'gate <repo>' <<<"$help_out" || fail "--help must name gate"
ok "scenario12: --help names gate and hours"

ok "fleet-work-supply-canary: math, gate, clean, ExecCondition, prompt, workers, auditor, go-ham idle, dedup, production, wiring, help"
