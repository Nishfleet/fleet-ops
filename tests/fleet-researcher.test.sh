#!/usr/bin/env bash
# tests/fleet-researcher.test.sh
#
# Proves the standing researcher role (fleet-ops#458) offline:
#   1. Delta contract: a concrete they/we/adopting+citations delta is
#      accepted; generic advice and missing citations are rejected.
#   2. Triggers: quality plateau, quality regression, domain staleness,
#      every Nth gap-closure cycle, failed cycle, seat-map change.
#   3. Dispatch starts fleet-researcher.service on a live trigger.
#   4. Active unit -> no start. Cadence-cut (zero adoption) -> no start.
#   5. Drill run: a valid delta is filed scout-candidate+research-delta.
#   6. Drill run: generic advice is logged, not filed; replay is skipped.
#   7. Heartbeat-tier1 wires block 20 and propagates a broken dispatch.
#   8. MANIFEST installs the role files.
#
# Live pi / systemctl start are the outermost edges and are stubbed.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/researcher-delta.py"
dispatch="$repo_root/bin/fleet-researcher-dispatch"
run="$repo_root/bin/fleet-researcher-run"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
unit="$repo_root/systemd/fleet-researcher.service"
prompt="$repo_root/prompts/researcher.md"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -x "$dispatch" ]] || fail "not executable: $dispatch"
[[ -x "$run" ]] || fail "not executable: $run"
[[ -f "$tier1" ]] || fail "missing $tier1"
[[ -f "$unit" ]] || fail "missing $unit"
[[ -f "$prompt" ]] || fail "missing $prompt"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"
bash -n "$dispatch" || fail "dispatch: bash -n"
bash -n "$run" || fail "run: bash -n"
python3 -m py_compile "$lib" || fail "researcher-delta.py failed py_compile"
ok "scripts compile"

scratch="$(mktemp -d -t fleet-researcher.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"
mkdir -p "$HOME"

# --- 1. contract -----------------------------------------------------------
good='{"deltas":[{"title":"Blameless postmortem packet","plane":"fleet-workflow","they":"SRE teams auto-draft a blameless timeline from tickets and pages, then humans own the judgment.","we":"fleet-ops files a failure-fix issue with a mechanism line but does not reconstruct the timeline.","adopting":"On FAILED cycle, assemble a timeline packet from journals and GitHub events and queue it as a research-delta.","citations":[{"url":"https://sre.google/sre-book/postmortem-culture/","note":"Google SRE blameless postmortems"}]}]}'
bad_generic='{"deltas":[{"they":"Top teams are excellent at reliability work.","we":"We should also be excellent at reliability work.","adopting":"Follow best practices.","citations":[{"url":"https://example.com"}]}]}'
bad_nocite='{"deltas":[{"they":"Shops run continuous adversarial testing against their own gates.","we":"We only run scheduled fixture drills in fleet-ops.","adopting":"Stand a red-team researcher whose findings auto-file as gap-audit issues.","citations":[]}]}'

printf '%s\n' "$good" >"$scratch/good.json"
printf '%s\n' "$bad_generic" >"$scratch/generic.json"
printf '%s\n' "$bad_nocite" >"$scratch/nocite.json"

v=$(python3 "$lib" validate --file "$scratch/good.json")
jq -e '.accepted | length == 1' <<<"$v" >/dev/null || fail "good delta should be accepted: $v"
jq -e '.rejected | length == 0' <<<"$v" >/dev/null || fail "good delta should have zero rejects: $v"

v=$(python3 "$lib" validate --file "$scratch/generic.json")
jq -e '(.accepted | length) == 0 and (.rejected | length) == 1' <<<"$v" >/dev/null \
  || fail "generic advice should be rejected: $v"

v=$(python3 "$lib" validate --file "$scratch/nocite.json")
jq -e '.accepted | length == 0' <<<"$v" >/dev/null || fail "missing citations should reject: $v"
ok "delta contract accepts concrete deltas and rejects generic/un-cited ones"

# --- 2. triggers -----------------------------------------------------------
python3 "$lib" init --state "$scratch/state.json" >/dev/null
python3 - "$scratch/state.json" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["domains"] = {
  "fleet-workflow": {"last_research_at": "2026-08-20T00:00:00Z"},
  "product-0509": {"last_research_at": "2026-08-20T00:00:00Z"},
}
json.dump(s, open(p, "w"), indent=2)
open(p, "a").write("\n")
PY

printf '%s\n' '{"verdict":"PASS","primary":{"x":1},"prior_primary":{"x":1}}' >"$scratch/plateau.json"
printf '%s\n' '{"verdict":"FAIL","primary":{"x":0},"prior_primary":{"x":1}}' >"$scratch/regress.json"
printf '%s\n' '{"cycle":5,"last_verdict":"NOT-DONE"}' >"$scratch/nth.json"
printf '%s\n' '{"cycle":2,"last_verdict":"FAIL"}' >"$scratch/failed.json"
printf '%s\n' '{"cycle":4,"last_verdict":"DONE"}' >"$scratch/quiet-gap.json"

t=$(python3 "$lib" triggers --state "$scratch/state.json" --quality "$scratch/plateau.json" --now "2026-08-21T00:00:00Z")
printf '%s' "$t" | jq -e '.triggers | index("quality-plateau")' >/dev/null || fail "plateau trigger missing: $t"

t=$(python3 "$lib" triggers --state "$scratch/state.json" --quality "$scratch/regress.json" --now "2026-08-21T00:00:00Z")
printf '%s' "$t" | jq -e '.triggers | index("quality-regression")' >/dev/null || fail "regression trigger missing: $t"

t=$(python3 "$lib" triggers --state "$scratch/state.json" --gap "$scratch/nth.json" --now "2026-08-21T00:00:00Z")
printf '%s' "$t" | jq -e '.triggers | index("nth-gap-cycle")' >/dev/null || fail "nth-cycle trigger missing: $t"

t=$(python3 "$lib" triggers --state "$scratch/state.json" --gap "$scratch/failed.json" --now "2026-08-21T00:00:00Z")
printf '%s' "$t" | jq -e '.triggers | index("failed-cycle")' >/dev/null || fail "failed-cycle trigger missing: $t"

t=$(python3 "$lib" triggers --state "$scratch/state.json" --gap "$scratch/quiet-gap.json" --now "2026-08-21T00:00:00Z")
printf '%s' "$t" | jq -e '.triggers == []' >/dev/null || fail "quiet gap+fresh domains should have no triggers: $t"

python3 - "$scratch/state.json" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["last_seat_map_hash"] = "aaa"
json.dump(s, open(p, "w"), indent=2)
open(p, "a").write("\n")
PY
t=$(python3 "$lib" triggers --state "$scratch/state.json" --seat-hash bbb --now "2026-08-21T00:00:00Z")
printf '%s' "$t" | jq -e '.triggers | index("seat-map-release")' >/dev/null || fail "seat-map trigger missing: $t"

t=$(python3 "$lib" triggers --state "$scratch/state.json" --now "2026-09-19T00:00:00Z" --stale-days 28)
printf '%s' "$t" | jq -e '.triggers | index("domain-stale:fleet-workflow")' >/dev/null \
  || fail "domain-stale trigger missing: $t"
ok "triggers: plateau, regression, nth cycle, failed cycle, seat-map, domain-stale"

# --- 3/4. dispatch with fake systemctl -------------------------------------
calls="$scratch/calls.log"
: >"$calls"
sys_fake="$scratch/systemctl"
cat >"$sys_fake" <<'FAKE'
#!/usr/bin/env bash
: "${CALLS:=/tmp/calls.log}"
printf '%s\n' "$*" >>"$CALLS"
if [[ "${1:-}" == "--user" && "${2:-}" == "is-active" ]]; then
  unit="${3:-}"
  if [[ -f "${ACTIVE_UNITS:-/dev/null}" ]] && grep -qxF "$unit" "${ACTIVE_UNITS:-/dev/null}"; then
    echo active
  else
    echo inactive
  fi
  exit 0
fi
if [[ "${1:-}" == "--user" && "${2:-}" == "start" ]]; then
  exit "${START_RC:-0}"
fi
echo "unexpected systemctl: $*" >&2
exit 1
FAKE
chmod +x "$sys_fake"

gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"label view"*) exit 1 ;;
  *"label create"*) exit 0 ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/9001"
    exit 0
    ;;
  *"issue view"*)
    echo '{"labels":[]}'
    exit 0
    ;;
  *)
    echo "unexpected gh: $*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$gh_fake"

auditor_fake="$scratch/auditor"
cat >"$auditor_fake" <<'FAKE'
#!/usr/bin/env bash
echo "auditor-nudge" >>"${AUDITOR_LOG:-/dev/null}"
exit 0
FAKE
chmod +x "$auditor_fake"

export SYSTEMCTL="$sys_fake"
export GH="$gh_fake"
export CALLS="$calls"
export GH_LOG="$scratch/gh.log"
export AUDITOR_LOG="$scratch/auditor.log"
export RESEARCHER_LIB="$lib"
export RESEARCHER_REFRESH_LABELS=0
export RESEARCHER_MIN_INTERVAL_S=0
export FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md"
: >"$FLEET_HEARTBEAT_TRIAGE"

run_dispatch() {
  local dir="$1"
  mkdir -p "$dir"
  RESEARCHER_STATE_DIR="$dir" \
  RESEARCHER_QUALITY_JSON="${2:-}" \
  RESEARCHER_GAP_JSON="${3:-}" \
  RESEARCHER_FAKE_NOW="2026-08-21T00:00:00Z" \
  RESEARCHER_UNIT="fleet-researcher.service" \
    "$dispatch"
}

: >"$calls"
fresh="$scratch/fresh-state"
run_dispatch "$fresh" || fail "dispatch on stale domains should exit 0"
grep -q 'start --no-block fleet-researcher.service' "$calls" \
  || fail "stale domains should start the unit: $(cat "$calls")"
ok "dispatch: domain staleness starts fleet-researcher.service"

: >"$calls"
printf '%s\n' 'fleet-researcher.service' >"$scratch/active"
ACTIVE_UNITS="$scratch/active" run_dispatch "$fresh" || fail "active-unit dispatch should exit 0"
! grep -q 'start --no-block' "$calls" || fail "active unit must not start again: $(cat "$calls")"
ok "dispatch: active unit is a no-op"

mkdir -p "$scratch/quiet"
python3 "$lib" init --state "$scratch/quiet/state.json" >/dev/null
python3 - "$scratch/quiet/state.json" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["domains"] = {
  "fleet-workflow": {"last_research_at": "2026-08-21T00:00:00Z"},
  "product-0509": {"last_research_at": "2026-08-21T00:00:00Z"},
}
s["last_dispatch_at"] = "2026-08-21T00:00:00Z"
json.dump(s, open(p, "w"), indent=2)
open(p, "a").write("\n")
PY
: >"$calls"
unset ACTIVE_UNITS || true
run_dispatch "$scratch/quiet" || fail "quiet dispatch should exit 0"
! grep -q 'start --no-block' "$calls" || fail "quiet state must not start: $(cat "$calls")"
ok "dispatch: no trigger -> no start"

mkdir -p "$scratch/plat"
cp "$scratch/quiet/state.json" "$scratch/plat/state.json"
python3 - "$scratch/plat/state.json" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["last_dispatch_at"] = ""
json.dump(s, open(p, "w"), indent=2)
open(p, "a").write("\n")
PY
: >"$calls"
run_dispatch "$scratch/plat" "$scratch/plateau.json" || fail "plateau dispatch should exit 0"
grep -q 'start --no-block fleet-researcher.service' "$calls" \
  || fail "plateau should start the unit: $(cat "$calls")"
ok "dispatch: quality plateau starts the unit"

mkdir -p "$scratch/cut"
python3 "$lib" init --state "$scratch/cut/state.json" >/dev/null
python3 - "$scratch/cut/state.json" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["deltas"] = [{"fingerprint": "d%d" % i, "status": "discarded"} for i in range(8)]
s["domains"] = {
  "fleet-workflow": {"last_research_at": ""},
  "product-0509": {"last_research_at": ""},
}
json.dump(s, open(p, "w"), indent=2)
open(p, "a").write("\n")
PY
: >"$calls"
: >"$FLEET_HEARTBEAT_TRIAGE"
run_dispatch "$scratch/cut" || fail "cadence-cut dispatch should exit 0"
! grep -q 'start --no-block' "$calls" || fail "cadence-cut must not start: $(cat "$calls")"
grep -q 'RESEARCHER-CADENCE-CUT' "$FLEET_HEARTBEAT_TRIAGE" \
  || fail "cadence-cut must LOUD: $(cat "$FLEET_HEARTBEAT_TRIAGE")"
ok "dispatch: zero-adoption rate cuts cadence"

# --- 5/6. drill run --------------------------------------------------------
export RESEARCHER_DRILL=1
export RESEARCHER_AUDITOR_BIN="$auditor_fake"
export RESEARCHER_DRY_RUN=0
mkdir -p "$scratch/run1"
export RESEARCHER_STATE_DIR="$scratch/run1"
export RESEARCHER_DRILL_DELTAS="$scratch/good.json"
export RESEARCHER_FAKE_NOW="2026-08-21T12:00:00Z"
: >"$scratch/gh.log"
: >"$scratch/auditor.log"
"$run" || fail "drill run with a good delta should exit 0"
grep -q 'issue create' "$scratch/gh.log" || fail "valid delta must be filed: $(cat "$scratch/gh.log")"
grep -q 'scout-candidate' "$scratch/gh.log" || fail "filed issue must carry scout-candidate"
grep -q 'research-delta' "$scratch/gh.log" || fail "filed issue must carry research-delta"
grep -q 'auditor-nudge' "$scratch/auditor.log" || fail "filing must nudge the admission panel"
jq -e '(.deltas | length) == 1 and .deltas[0].status == "filed"' "$scratch/run1/state.json" >/dev/null \
  || fail "state should record the filed delta: $(cat "$scratch/run1/state.json")"
ok "run: valid delta files scout-candidate+research-delta and nudges admission"

mkdir -p "$scratch/run2"
export RESEARCHER_STATE_DIR="$scratch/run2"
export RESEARCHER_DRILL_DELTAS="$scratch/generic.json"
: >"$scratch/gh.log"
"$run" || fail "generic drill should exit 0"
! grep -q 'issue create' "$scratch/gh.log" || fail "generic advice must not file: $(cat "$scratch/gh.log")"
jq -e '(.rejected | length) >= 1' "$scratch/run2/state.json" >/dev/null \
  || fail "generic advice must be logged as rejected"
ok "run: generic advice is rejected and not filed"

export RESEARCHER_STATE_DIR="$scratch/run1"
export RESEARCHER_DRILL_DELTAS="$scratch/good.json"
: >"$scratch/gh.log"
"$run" || fail "replay drill should exit 0"
! grep -q 'issue create' "$scratch/gh.log" || fail "replay must not re-file: $(cat "$scratch/gh.log")"
ok "run: rejected/filed fingerprints are not re-litigated"

# --- 7. heartbeat wiring ---------------------------------------------------
grep -F '20. researcher dispatch starting' "$tier1" >/dev/null \
  || fail "tier1 must log researcher dispatch as block 20"
grep -F 'researcher_dispatch_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture researcher_dispatch_rc"
grep -F -- 'exit "$researcher_dispatch_rc"' "$tier1" >/dev/null \
  || fail "tier1 must propagate a broken researcher dispatch"
grep -F 'fleet-researcher-dispatch' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-researcher-dispatch"
ok "heartbeat-tier1 wires block 20 and propagates a broken dispatch"

# --- 8. MANIFEST + unit shape ---------------------------------------------
grep -Fq 'bin/fleet-researcher-dispatch /home/nish/.local/bin/fleet-researcher-dispatch' "$manifest" \
  || fail "MANIFEST missing dispatch"
grep -Fq 'bin/fleet-researcher-run /home/nish/.local/bin/fleet-researcher-run' "$manifest" \
  || fail "MANIFEST missing run"
grep -Fq 'lib/researcher-delta.py /home/nish/.local/lib/pi-packet/researcher-delta.py' "$manifest" \
  || fail "MANIFEST missing lib"
grep -Fq 'prompts/researcher.md /home/nish/.pi/agent/prompts/researcher.md' "$manifest" \
  || fail "MANIFEST missing prompt"
grep -Fq 'systemd/fleet-researcher.service /home/nish/.config/systemd/user/fleet-researcher.service' "$manifest" \
  || fail "MANIFEST missing unit"
grep -q 'Restart=no' "$unit" || fail "unit must be Restart=no"
grep -q 'Type=oneshot' "$unit" || fail "unit must be oneshot"
ok "MANIFEST and unit shape (oneshot, Restart=no)"

if command -v systemd-analyze >/dev/null 2>&1; then
  if ! systemd-analyze verify --man=no "$unit"; then
    fail "systemd-analyze verify failed for fleet-researcher.service"
  fi
  ok "systemd-analyze verify accepts fleet-researcher.service"
fi

grep -F 'fleet-researcher-run' "$repo_root/bin/fleet-escalation-canary" >/dev/null \
  || fail "fleet-researcher-run must be on SANCTIONED_PI_RUNNERS"
ok "SANCTIONED_PI_RUNNERS includes fleet-researcher-run"

ok "fleet-ops#458 researcher role: contract, triggers, dispatch, drills, heartbeat wiring"
