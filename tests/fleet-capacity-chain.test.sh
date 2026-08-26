#!/usr/bin/env bash
# tests/fleet-capacity-chain.test.sh
#
# Proves the capacity chain (fleet-ops#418) offline with mocked gh + systemctl:
#
#   1. Entitled → wired: inventory seat with no seat-caps row → ENTITLED-UNWIRED
#      + auto-file; cap=0 without a dated reason → ENTITLED-CAP0; cap=0 with
#      YYYY-MM-DD reason → quiet.
#   2. Wired → probed: cap>0 lane, chain landed >N days ago, no receipt →
#      AIMD-STALE; hard-capped lane exempt; fresh receipt quiet.
#   3. Probed → saturated / verdicts:
#        ready>0 running==bound live_caps<=ram → SATURATED
#        ready>0 running==ram ram<live_caps → GOVERNOR-LIMITED
#        ready>0 walled lane that lowers the bound → LANE-LIMITED
#        ready==0 → WORK-LIMITED
#        ready>0 running<bound healthy lanes → UNKNOWN + UNDERSAT-CAPACITY
#   4. Chain drill --drill: entitled / probed / saturated / walled / supplied
#      hops pass (SATURATED within 2 ticks, LANE-LIMITED names fixture-lane,
#      WORK-LIMITED + scout start).
#   5. tier1 block 15 wiring + MANIFEST install path locked.
#
# The real `systemctl start pi-scout@` / `gh issue create` are the outermost
# edges; they are stubbed. The detectors this issue owns run through the
# real binary.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-capacity-chain"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t capchain.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

triage="$scratch/triage.md"
log_dir="$scratch/log"
mkdir -p "$log_dir"
: >"$triage"

intake="$scratch/intake.json"
cat >"$intake" <<'JSON'
{
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": []
}
JSON

caps="$scratch/seat-caps.json"
inv="$scratch/inventory.json"
probes="$scratch/probes"
filed="$scratch/filed"
ledger="$scratch/ledger"
mkdir -p "$probes" "$filed" "$ledger"

gh_fake="$scratch/gh"
creates="$scratch/gh-create.log"
: >"$creates"
ready_file="$scratch/ready"
printf '4\n' >"$ready_file"
cat >"$gh_fake" <<FAKE
#!/usr/bin/env bash
if [[ "\$*" == *"issue list"*"agent-ready"* ]]; then
  cat "$ready_file"
  exit 0
fi
if [[ "\$*" == *"issue create"* ]]; then
  printf '%s\n' "\$*" >>"$creates"
  echo "https://example.invalid/issues/1"
  exit 0
fi
exit 0
FAKE
chmod +x "$gh_fake"

sys_fake="$scratch/systemctl"
calls="$scratch/syscalls.log"
: >"$calls"
cat >"$sys_fake" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$calls"
cmd=""
for a in "\$@"; do
  case "\$a" in
    --user) continue ;;
    --state=*|--no-legend|--plain|--no-block) continue ;;
    *) cmd="\$a"; break ;;
  esac
done
case "\$cmd" in
  list-units) exit 0 ;;
  is-active) echo inactive; exit 0 ;;
  start) exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$sys_fake"

export SYSTEMCTL="$sys_fake"
export GH="$gh_fake"
export FLEET_INTAKE_REPOS_JSON="$intake"
export FLEET_HEARTBEAT_LOG_DIR="$log_dir"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export SEAT_CAPS_JSON="$caps"
export FLEET_ENTITLEMENT_INVENTORY="$inv"
export FLEET_CAPACITY_PROBE_DIR="$probes"
export FLEET_CAPACITY_LANDED="$scratch/landed"
export FLEET_CAPACITY_FILED_DIR="$filed"
export FLEET_CAPACITY_FILE_ISSUES=1
export FLEET_CAPACITY_AUTO_FILE_REPO="Nishfleet/fleet-ops"
export FLEET_CAPACITY_RAM_GB=8
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export FLEET_OPS_REPO="$repo_root"

write_base_caps() {
  cat >"$caps" <<'JSON'
{
  "ram_gb_per_worker": 1,
  "providers": {
    "healthy-a": { "cap": 2, "class": "free" },
    "healthy-b": { "cap": 2, "class": "free" },
    "walled-x": { "cap": 2, "class": "free" },
    "hardone": { "cap": 4, "class": "subscription", "_hard_cap": "Nish 2026-08-26: never probe above" },
    "zeroed": { "cap": 0, "class": "free", "cap_zero_reason": "no working credential 2026-08-26" }
  }
}
JSON
}

write_base_inv() {
  cat >"$inv" <<'JSON'
{
  "seats": [
    { "id": "healthy-a", "class": "free" },
    { "id": "healthy-b", "class": "free" },
    { "id": "walled-x", "class": "free" },
    { "id": "hardone", "class": "prepaid-quota" },
    { "id": "zeroed", "class": "free" }
  ]
}
JSON
}

reset_state() {
  write_base_caps
  write_base_inv
  rm -rf "$probes" "$filed"
  mkdir -p "$probes" "$filed"
  : >"$triage"
  : >"$creates"
  : >"$calls"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$scratch/landed"
  unset FLEET_CAPACITY_WALLED
  unset FLEET_CAPACITY_PROBE_MAX_AGE_DAYS
  export FLEET_ENTITLEMENT_INVENTORY="$inv"
  export FLEET_CAPACITY_RUNNING=4
  printf '4\n' >"$ready_file"
}

# ============================================================================
# 1. Entitled → wired
# ============================================================================
reset_state
jq '.seats += [{"id":"ghost","class":"free"}]' "$inv" >"$scratch/inv2.json"
export FLEET_ENTITLEMENT_INVENTORY="$scratch/inv2.json"
"$bin" --observe >/dev/null 2>"$scratch/obs1.err" || true
grep -q 'ENTITLED-UNWIRED' "$triage" \
  || fail "missing seat must LOUD ENTITLED-UNWIRED; triage=$(cat "$triage")"
grep -q 'entitled-unwired: ghost' "$creates" \
  || fail "missing seat must auto-file; creates=$(cat "$creates")"
ok "entitled: missing seat → ENTITLED-UNWIRED + auto-file"

reset_state
# cap=0 without a date
cat >"$caps" <<'JSON'
{
  "ram_gb_per_worker": 1,
  "providers": {
    "healthy-a": { "cap": 2, "class": "free" },
    "zeroed": { "cap": 0, "class": "free" }
  }
}
JSON
cat >"$inv" <<'JSON'
{
  "seats": [
    { "id": "healthy-a", "class": "free" },
    { "id": "zeroed", "class": "free" }
  ]
}
JSON
export FLEET_ENTITLEMENT_INVENTORY="$inv"
date -u +%Y-%m-%dT%H:%M:%SZ >"$scratch/landed"
"$bin" --observe >/dev/null 2>"$scratch/obs2.err" || true
grep -q 'ENTITLED-CAP0' "$triage" \
  || fail "cap=0 without date must LOUD ENTITLED-CAP0; triage=$(cat "$triage")"
ok "entitled: cap=0 no date → ENTITLED-CAP0"

reset_state
export FLEET_ENTITLEMENT_INVENTORY="$inv"
# zeroed has a dated reason in write_base_caps; should be quiet on that seat
"$bin" --observe >/dev/null 2>"$scratch/obs3.err" || true
if grep -q 'ENTITLED-CAP0.*zeroed' "$triage"; then
  fail "dated cap=0 reason must be quiet, triage=$(cat "$triage")"
fi
ok "entitled: cap=0 with dated reason is quiet"

# ============================================================================
# 2. Wired → probed
# ============================================================================
reset_state
date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ >"$scratch/landed"
export FLEET_CAPACITY_PROBE_MAX_AGE_DAYS=0
"$bin" --observe >/dev/null 2>"$scratch/obs4.err" || true
grep -q 'AIMD-STALE' "$triage" \
  || fail "stale AIMD must LOUD; triage=$(cat "$triage")"
# hardone must be exempt
if grep -q 'AIMD-STALE.*hardone' "$triage"; then
  fail "hard-capped lane must be probe-exempt; triage=$(cat "$triage")"
fi
ok "probed: stale uncapped lane → AIMD-STALE; hard cap exempt"

reset_state
jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{provider:"healthy-a", probed_at:$t, signal:"held"}' >"$probes/healthy-a.json"
jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{provider:"healthy-b", probed_at:$t, signal:"held"}' >"$probes/healthy-b.json"
jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{provider:"walled-x", probed_at:$t, signal:"held"}' >"$probes/walled-x.json"
date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ >"$scratch/landed"
export FLEET_CAPACITY_PROBE_MAX_AGE_DAYS=0
"$bin" --observe >/dev/null 2>"$scratch/obs5.err" || true
if grep -q 'AIMD-STALE.*healthy-a' "$triage"; then
  fail "fresh receipt must keep healthy-a quiet; triage=$(cat "$triage")"
fi
ok "probed: fresh receipt is quiet"

# ============================================================================
# 3. Verdicts (reformulated undersat)
# ============================================================================
reset_state
# live_caps = 2+2+2+4 = 10, ram_envelope = 8, bound = 8
# running=8, ready=4 → GOVERNOR-LIMITED (ram < live)
export FLEET_CAPACITY_RUNNING=8
printf '4\n' >"$ready_file"
"$bin" --observe >/dev/null 2>"$scratch/obs6.err" || true
grep -q 'verdict=GOVERNOR-LIMITED' "$triage" \
  || fail "running at ram envelope below live caps → GOVERNOR-LIMITED; triage=$(cat "$triage")"
ok "verdict: GOVERNOR-LIMITED when RAM is the ceiling"

reset_state
# Drop ram-heavy extra: only healthy-a+b cap 2+2=4, ram=8, bound=4, running=4
cat >"$caps" <<'JSON'
{
  "ram_gb_per_worker": 1,
  "providers": {
    "healthy-a": { "cap": 2, "class": "free" },
    "healthy-b": { "cap": 2, "class": "free" }
  }
}
JSON
cat >"$inv" <<'JSON'
{
  "seats": [
    { "id": "healthy-a", "class": "free" },
    { "id": "healthy-b", "class": "free" }
  ]
}
JSON
export FLEET_CAPACITY_RUNNING=4
printf '4\n' >"$ready_file"
: >"$triage"
"$bin" --observe >/dev/null 2>"$scratch/obs7.err" || true
grep -q 'verdict=SATURATED' "$triage" \
  || fail "running at live-cap bound → SATURATED; triage=$(cat "$triage")"
ok "verdict: SATURATED at the live-cap bound"

reset_state
# RAM envelope 8 > live caps 6, so walling walled-x (cap 2) actually drops
# the bound 6 → 4. With the default map, hardone's cap 4 plus RAM=8 keeps
# the bound pinned at the governor after a 2-cap wall.
cat >"$caps" <<'JSON'
{
  "ram_gb_per_worker": 1,
  "providers": {
    "healthy-a": { "cap": 2, "class": "free" },
    "healthy-b": { "cap": 2, "class": "free" },
    "walled-x": { "cap": 2, "class": "free" }
  }
}
JSON
cat >"$inv" <<'JSON'
{
  "seats": [
    { "id": "healthy-a", "class": "free" },
    { "id": "healthy-b", "class": "free" },
    { "id": "walled-x", "class": "free" }
  ]
}
JSON
export FLEET_CAPACITY_WALLED="walled-x"
export FLEET_CAPACITY_RUNNING=4
printf '4\n' >"$ready_file"
"$bin" --observe >/dev/null 2>"$scratch/obs8.err" || true
grep -q 'verdict=LANE-LIMITED' "$triage" \
  || fail "walled lane that lowers bound → LANE-LIMITED; triage=$(cat "$triage")"
grep -q 'walled=walled-x' "$triage" \
  || fail "LANE-LIMITED must name the walled lane; triage=$(cat "$triage")"
ok "verdict: LANE-LIMITED names the walled lane"

reset_state
printf '0\n' >"$ready_file"
export FLEET_CAPACITY_RUNNING=0
"$bin" --observe >/dev/null 2>"$scratch/obs9.err" || true
grep -q 'verdict=WORK-LIMITED' "$triage" \
  || fail "ready=0 → WORK-LIMITED; triage=$(cat "$triage")"
ok "verdict: WORK-LIMITED when ready work is gone"

reset_state
export FLEET_CAPACITY_RUNNING=1
printf '8\n' >"$ready_file"
"$bin" --observe >/dev/null 2>"$scratch/obs10.err" || true
grep -q 'verdict=UNKNOWN' "$triage" \
  || fail "ready work + running below bound + healthy lanes → UNKNOWN; triage=$(cat "$triage")"
grep -q 'UNDERSAT-CAPACITY' "$triage" \
  || fail "reformulated undersat must LOUD UNDERSAT-CAPACITY; triage=$(cat "$triage")"
ok "verdict: UNKNOWN + UNDERSAT-CAPACITY below the bound with work"

# ============================================================================
# 4. Chain drill
# ============================================================================
reset_state
export FLEET_CAPACITY_DRILL_DIR="$scratch/drill"
: >"$triage"
if ! "$bin" --drill >/dev/null 2>"$scratch/drill.err"; then
  fail "drill must exit 0; err=$(cat "$scratch/drill.err") triage=$(cat "$triage")"
fi
grep -q 'CAPACITY-DRILL-OK' "$triage" \
  || fail "drill must LOUD CAPACITY-DRILL-OK; triage=$(cat "$triage") err=$(cat "$scratch/drill.err")"
grep -q 'ENTITLED-UNWIRED' "$triage" \
  || fail "drill entitled hop must scream missing seat"
grep -q 'AIMD-STALE' "$triage" \
  || fail "drill probed hop must scream stale AIMD"
grep -q 'pi-scout@drill.service' "$scratch/drill/systemctl-calls.log" \
  || fail "drill supplied hop must start pi-scout@drill.service"
ok "drill: all five hops pass (SATURATED / LANE-LIMITED / WORK-LIMITED+scout)"

# ============================================================================
# 5. Wiring locks (block 16 after #387 took block 15)
# ============================================================================
grep -q 'fleet-capacity-chain' "$tier1" \
  || fail "fleet-heartbeat-tier1 must invoke fleet-capacity-chain"
grep -q 'FLEET_CAPACITY_CHAIN' "$tier1" \
  || fail "tier1 must honour FLEET_CAPACITY_CHAIN override"
grep -q 'capacity_rc' "$tier1" \
  || fail "tier1 must track capacity_rc"
grep -q -- '--drill' "$tier1" \
  || fail "tier1 must run the chain drill every tick"
ok "tier1 block 16 wiring locked"

grep -q 'bin/fleet-capacity-chain /home/nish/.local/bin/fleet-capacity-chain' "$manifest" \
  || fail "MANIFEST must install fleet-capacity-chain"
ok "MANIFEST install paths locked"

# Production inventory is entitled-seats.json (fleet-ops#387/#425).
prod_inv="$repo_root/config/entitled-seats.json"
if [[ ! -f "$prod_inv" ]]; then
  fail "entitled-seats.json missing (needed after rebase onto origin/main)"
fi
jq '.' "$prod_inv" >/dev/null || fail "entitled-seats.json is not valid JSON"
need='cline commandcode cursor devin grok hetzner minimax ollama opencode openrouter orcarouter zenmux'
for id in $need; do
  jq -e --arg id "$id" '.seats[] | select(.id==$id)' "$prod_inv" >/dev/null \
    || fail "inventory missing entitled seat $id"
done
ok "production entitled-seats.json is the chain's inventory"

echo "OK: fleet-capacity-chain: entitled, probed, saturated, supplied, drilled"
