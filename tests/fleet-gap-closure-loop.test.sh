#!/usr/bin/env bash
# tests/fleet-gap-closure-loop.test.sh
#
# fleet-ops#180 acceptance (stubbed, machinery-only):
#   cycle with findings -> no conference
#   clean cycle + green SLOs -> conference convened
#   2-of-3 DONE -> loop CONTINUES (unanimity required), dissent auto-filed
#   unanimous -> intensive loop closed, calendar floor intact, precedence=product
#   injected regression -> loop reopened, precedence=loop
# Plus: tally determinism, SLO placeholder for #153, intake yield/order,
# no hand-rolled poller, MANIFEST + unit shape, heartbeat trigger, weekly floor.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

loop="$repo_root/bin/fleet-gap-closure-loop"
tally="$repo_root/bin/fleet-gap-closure-tally"
slo="$repo_root/bin/fleet-gap-closure-slo"
conf="$repo_root/bin/fleet-gap-closure-conference"
drill="$repo_root/bin/fleet-gap-closure-drill"
audit_run="$repo_root/bin/fleet-gap-closure-auditor"
yield="$repo_root/bin/fleet-gap-closure-yield"
order="$repo_root/bin/fleet-gap-closure-order"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
manifest="$repo_root/MANIFEST"
weekly="$repo_root/systemd/fleet-blind-audit.timer"

for f in "$loop" "$tally" "$slo" "$conf" "$drill" "$audit_run" "$yield" "$order"; do
  [[ -x "$f" ]] || fail "not executable: $f"
  bash -n "$f" || fail "bash -n failed: $f"
done
command -v jq >/dev/null 2>&1 || fail "jq missing"

# ---------------------------------------------------------------------------
# Plumbing ban: no hand-rolled poller / retry / sleep-wait in the loop.
# `while [ i -lt n ]` over a known JSON array is enumeration, not a poller.
# ---------------------------------------------------------------------------
for f in "$loop" "$tally" "$slo" "$conf" "$drill" "$audit_run" "$yield" "$order"; do
  if grep -nE 'while[[:space:]]+:|[[:space:]]sleep[[:space:]]+[0-9]' "$f" >/dev/null; then
    fail "hand-rolled poller/sleep in $f: $(grep -nE 'while[[:space:]]+:|[[:space:]]sleep[[:space:]]+[0-9]' "$f")"
  fi
done
ok "no hand-rolled poller/sleep in gap-closure binaries"

# ---------------------------------------------------------------------------
# Shape: units, MANIFEST, weekly floor intact, heartbeat trigger
# ---------------------------------------------------------------------------
[[ -f "$repo_root/systemd/fleet-gap-closure-loop.service" ]] \
  || fail "missing systemd/fleet-gap-closure-loop.service"
[[ -f "$repo_root/systemd/fleet-gap-closure-conference.service" ]] \
  || fail "missing systemd/fleet-gap-closure-conference.service"
[[ -f "$repo_root/systemd/fleet-gap-closure-drill.service" ]] \
  || fail "missing systemd/fleet-gap-closure-drill.service"
[[ -f "$repo_root/systemd/fleet-gap-closure-auditor@.service" ]] \
  || fail "missing systemd/fleet-gap-closure-auditor@.service"
[[ -f "$repo_root/systemd/pi-audit@.service" ]] \
  || fail "missing systemd/pi-audit@.service (admission panel must stay)"
[[ -f "$repo_root/systemd/gap-closure-drill.slice" ]] \
  || fail "missing systemd/gap-closure-drill.slice"
[[ -f "$repo_root/systemd/gap-closure-drill-stub-fail.service" ]] \
  || fail "missing systemd/gap-closure-drill-stub-fail.service"
[[ -f "$repo_root/systemd/gap-closure-drill-stub-mask.timer" ]] \
  || fail "missing systemd/gap-closure-drill-stub-mask.timer"

grep -q "ExecStart=/bin/bash -c 'exec /home/nish/.local/bin/fleet-gap-closure-loop'" \
  "$repo_root/systemd/fleet-gap-closure-loop.service" \
  || fail "loop unit ExecStart must be /bin/bash -c exec (hosted systemd-analyze)"
grep -q '^Restart=no$' "$repo_root/systemd/fleet-gap-closure-loop.service" \
  || fail "loop unit must be Restart=no (heartbeat is the retry)"
if grep -q '^\[Install\]$' "$repo_root/systemd/fleet-gap-closure-loop.service"; then
  fail "loop unit must not have [Install] (heartbeat starts it)"
fi

grep -q '^Slice=gap-closure-drill.slice$' \
  "$repo_root/systemd/gap-closure-drill-stub-fail.service" \
  || fail "fail stub must sit in gap-closure-drill.slice"
if grep -qE '^OnFailure=' "$repo_root/systemd/gap-closure-drill-stub-fail.service"; then
  fail "fail stub must inherit global OnFailure= (must not reset it)"
fi

expected_manifest=(
  "bin/fleet-gap-closure-loop /home/nish/.local/bin/fleet-gap-closure-loop"
  "bin/fleet-gap-closure-conference /home/nish/.local/bin/fleet-gap-closure-conference"
  "bin/fleet-gap-closure-tally /home/nish/.local/bin/fleet-gap-closure-tally"
  "bin/fleet-gap-closure-drill /home/nish/.local/bin/fleet-gap-closure-drill"
  "bin/fleet-gap-closure-slo /home/nish/.local/bin/fleet-gap-closure-slo"
  "bin/fleet-gap-closure-auditor /home/nish/.local/bin/fleet-gap-closure-auditor"
  "bin/fleet-gap-closure-yield /home/nish/.local/bin/fleet-gap-closure-yield"
  "bin/fleet-gap-closure-order /home/nish/.local/bin/fleet-gap-closure-order"
  "systemd/fleet-gap-closure-loop.service /home/nish/.config/systemd/user/fleet-gap-closure-loop.service"
  "systemd/fleet-gap-closure-conference.service /home/nish/.config/systemd/user/fleet-gap-closure-conference.service"
  "systemd/fleet-gap-closure-drill.service /home/nish/.config/systemd/user/fleet-gap-closure-drill.service"
  "systemd/fleet-gap-closure-auditor@.service /home/nish/.config/systemd/user/fleet-gap-closure-auditor@.service"
  "systemd/gap-closure-drill.slice /home/nish/.config/systemd/user/gap-closure-drill.slice"
  "systemd/gap-closure-drill-stub-fail.service /home/nish/.config/systemd/user/gap-closure-drill-stub-fail.service"
  "systemd/gap-closure-drill-stub-mask.service /home/nish/.config/systemd/user/gap-closure-drill-stub-mask.service"
  "systemd/gap-closure-drill-stub-mask.timer /home/nish/.config/systemd/user/gap-closure-drill-stub-mask.timer"
  "prompts/gap-closure-conference.md /home/nish/.pi/agent/prompts/gap-closure-conference.md"
  "prompts/gap-closure-conference-round2.md /home/nish/.pi/agent/prompts/gap-closure-conference-round2.md"
  "prompts/gap-closure-research.md /home/nish/.pi/agent/prompts/gap-closure-research.md"
  "prompts/gap-closure-research-round2.md /home/nish/.pi/agent/prompts/gap-closure-research-round2.md"
)
for entry in "${expected_manifest[@]}"; do
  grep -Fxq "$entry" "$manifest" || fail "MANIFEST missing: $entry"
done
ok "MANIFEST + unit shape locked"

grep -F -- 'systemctl --user start fleet-gap-closure-loop.service' "$tier1" >/dev/null \
  || fail "tier1 must start fleet-gap-closure-loop.service each tick"
grep -F -- 'FLEET_GAP_LOOP_DISABLE' "$tier1" >/dev/null \
  || fail "tier1 must honour FLEET_GAP_LOOP_DISABLE"
# #157 calendar floor must remain unconditional. The floor is daily as of
# fleet-ops#378 (the weekly cadence was structurally defeated by a full
# gap-board); this lock is "the timer still fires on a calendar, with no
# Condition* that would skip it after intensive-loop DONE".
grep -E '^OnCalendar=' "$weekly" >/dev/null \
  || fail "blind-audit floor timer must keep an OnCalendar= line"
if grep -qE '^[[:space:]]*(Condition|ExecCondition)' "$weekly"; then
  fail "blind-audit floor must not gain a Condition* gate"
fi
ok "heartbeat trigger + calendar floor intact"

grep -F -- 'fleet-gap-closure-yield' "$repo_root/prompts/intake.md" >/dev/null \
  || fail "intake.md must call fleet-gap-closure-yield"
grep -F -- 'gap-audit' "$repo_root/prompts/intake.md" >/dev/null \
  || fail "intake.md must name gap-audit as an intake kind"
ok "intake prompt wired to precedence helpers"

# ---------------------------------------------------------------------------
# Tally: deterministic, unanimity required, research never terminates
# ---------------------------------------------------------------------------
r1='[{"auditor":"a","vote":"DONE"},{"auditor":"b","vote":"DONE"},{"auditor":"c","vote":"NOT-DONE"}]'
r2_split='[{"auditor":"a","vote":"DONE","reason":"ok"},{"auditor":"b","vote":"DONE","reason":"ok"},{"auditor":"c","vote":"NOT-DONE","reason":"drill rot"}]'
out="$("$tally" conf-1 termination "$r1" "$r2_split")"
[[ "$(printf '%s' "$out" | jq -r '.unanimous_done')" == "false" ]] \
  || fail "2-of-3 must not be unanimous: $out"
[[ "$(printf '%s' "$out" | jq -r '.dissenters | length')" == "1" ]] \
  || fail "2-of-3 must record one dissenter: $out"
[[ "$(printf '%s' "$out" | jq -r '.dissenters[0].auditor')" == "c" ]] \
  || fail "dissenter must be c: $out"

r2_all='[{"auditor":"a","vote":"DONE","reason":"ok"},{"auditor":"b","vote":"DONE","reason":"ok"},{"auditor":"c","vote":"DONE","reason":"ok"}]'
out="$("$tally" conf-2 termination "$r1" "$r2_all")"
[[ "$(printf '%s' "$out" | jq -r '.unanimous_done')" == "true" ]] \
  || fail "3-of-3 DONE must be unanimous: $out"

r2_empty='[]'
out="$("$tally" conf-empty termination "$r1" "$r2_empty")"
[[ "$(printf '%s' "$out" | jq -r '.unanimous_done')" == "false" ]] \
  || fail "empty round2 must NOT be unanimous (need exactly 3 DONE): $out"

r2_research='[{"auditor":"a","adopted":[{"title":"t1","body":"b1"}],"rejected":[{"title":"no","reason":"already have it"}]}]'
out="$("$tally" conf-r research '[]' "$r2_research")"
[[ "$(printf '%s' "$out" | jq -r '.unanimous_done')" == "false" ]] \
  || fail "research mode must never set unanimous_done: $out"
[[ "$(printf '%s' "$out" | jq -r '.adopted | length')" == "1" ]] \
  || fail "research tally must union adopted: $out"
ok "tally: unanimity, dissent, research never terminates"

# Isolate the SLO snapshot from the live quality-slo file so hosted CI and
# this VPS do not leak a FAIL verdict into the stubbed green-path tests.
export GAP_LOOP_QUALITY_JSON="$here/.no-quality-snapshot.json"

# ---------------------------------------------------------------------------
# Scratch env for the state machine
# ---------------------------------------------------------------------------
scratch="$(mktemp -d -t gap-loop.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

state_dir="$scratch/state"
mkdir -p "$state_dir" "$scratch/bin"
prec="$state_dir/precedence"
gaps_file="$scratch/gaps.json"
printf '[]\n' >"$gaps_file"
creates="$scratch/creates.log"
: >"$creates"

cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
if [ -n "${GAP_LOOP_FAKE_GH_RATE_LIMIT:-}" ]; then
    printf 'GraphQL: API rate limit already exceeded for user ID 257724087.\n' >&2
    exit 1
fi
case "$*" in
  *"issue list"*gap-audit*"--state open"*)
    jq 'length' "${GAPS_JSON}" 2>/dev/null || echo 0
    ;;
  *"issue list"*gap-audit*"--state closed"*)
    # fleet-ops#5400: fleet-gap-closure-slo counts auto-repair client-side from
    # issue labels now; emit the seeded [{labels:[...]}] array.
    if [ -n "${CLOSED_GAPS_JSON:-}" ] && [ -f "$CLOSED_GAPS_JSON" ]; then
      cat "$CLOSED_GAPS_JSON"
    else
      echo '[]'
    fi
    ;;
  *"issue list"*stop-the-line*)
    # fleet-ops#4522: frozen-line gate. STL_FROZEN=1 simulates an open
    # stop-the-line issue (production deploy red on consecutive commits).
    if [ "${STL_FROZEN:-0}" = "1" ]; then echo 1; else echo 0; fi
    ;;
  *"issue list"*)
    echo 0
    ;;
  *"issue create"*)
    printf 'create %s\n' "$*" >>"${CREATES_LOG}"
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    ;;
  *)
    echo "[]"
    ;;
esac
FAKE
chmod +x "$scratch/bin/gh"

# Fake systemctl: start records; is-active reads $scratch/unit-state/<unit>
mkdir -p "$scratch/unit-state"
cat >"$scratch/bin/systemctl" <<FAKE
#!/usr/bin/env bash
# Drop --user if present.
[[ "\${1:-}" == "--user" ]] && shift
cmd="\${1:-}"; shift || true
case "\$cmd" in
  start)
    for u in "\$@"; do
      printf 'start %s\n' "\$u" >>"$scratch/starts.log"
      printf 'inactive\n' >"$scratch/unit-state/\$u"
    done
    exit 0
    ;;
  is-active)
    u="\${1:-}"
    if [[ -f "$scratch/unit-state/\$u" ]]; then
      cat "$scratch/unit-state/\$u"
    else
      echo inactive
    fi
    exit 0
    ;;
  is-failed)
    echo inactive
    exit 1
    ;;
  cat|list-units|reset-failed)
    exit 0
    ;;
  *)
    echo "unexpected systemctl: \$cmd \$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$scratch/bin/systemctl"

export PATH="$scratch/bin:$PATH"
export GAPS_JSON="$gaps_file"
export CREATES_LOG="$creates"
export STL_FROZEN=0
export GAP_LOOP_STATE_DIR="$state_dir"
export GAP_LOOP_PRECEDENCE_FILE="$prec"
export GAP_LOOP_GH="$scratch/bin/gh"
export GAP_LOOP_SYSTEMCTL="$scratch/bin/systemctl"
export GAP_LOOP_DRY_RUN=1
export GAP_LOOP_FAKE_NOW="2026-08-26T16:00:00Z"
export GAP_LOOP_SLO_BIN="$slo"
export GAP_LOOP_DISABLE=0
export GAP_LOOP_REPO="Nishfleet/fleet-ops"
export GAP_LOOP_CONF_CLEAN_FLOOR=2

# fleet-ops#5021: bin/fleet-gap-closure-slo also folds the chain-e2e drill
# results in (CHAIN_E2E_STATE_DIR, default: LIVE /home/nish/workspaces/
# agent-state/chain-e2e). Pin it to a scratch dir holding no results file,
# exactly like GAP_LOOP_QUALITY_JSON above. Otherwise a red live drill leaks
# green=false into these stubbed green-path cycles, the clean-below-floor cycle
# takes the NOT-clean branch, and consecutive_clean stays 0 (reds
# ci-standards-audit on a machine whose last chain-e2e drill failed).
export CHAIN_E2E_STATE_DIR="$scratch/chain-e2e"
mkdir -p "$CHAIN_E2E_STATE_DIR"
# fleet-ops#5400: the SLO snapshot fails closed — every required input must be
# measured AND passing. Pin each required input to a measured stub value so
# the green-path cycles stay green deterministically; without these pins the
# live box's missing starvation/time-to-repair producers leak red into them.
printf '{"all_pass":true,"results":[{"name":"chain","pass":true}]}\n' \
  >"$CHAIN_E2E_STATE_DIR/chain-e2e-drill-results.json"
export GAP_LOOP_STARVATION_JSON="$scratch/starvation.json"
printf '{"starvation_minutes_24h":0}\n' >"$GAP_LOOP_STARVATION_JSON"
export GAP_LOOP_TTR_JSON="$scratch/time-to-repair.json"
printf '{"detector-rot":37}\n' >"$GAP_LOOP_TTR_JSON"
export CLOSED_GAPS_JSON="$scratch/closed-gaps.json"
printf '[{"labels":[]},{"labels":[]}]\n' >"$CLOSED_GAPS_JSON"

tick() { "$loop"; }

phase() { jq -r '.phase' "$state_dir/state.json"; }
cycle() { jq -r '.cycle' "$state_dir/state.json"; }
prec_val() { cat "$prec" 2>/dev/null || echo missing; }

# --- init + first audit dispatch -------------------------------------------
tick
[[ -f "$state_dir/state.json" ]] || fail "init must write state.json"
[[ "$(phase)" == "audit" ]] || fail "init phase must be audit, got $(phase)"
[[ "$(cycle)" == "1" ]] || fail "init cycle must be 1"
[[ "$(jq -r '.research_due' "$state_dir/state.json")" == "true" ]] || fail "cycle 1 research_due must be true"
[[ "$(prec_val)" == "loop" ]] || fail "init precedence must be loop, got $(prec_val)"
[[ "$(jq -r '.dispatched.audit' "$state_dir/state.json")" == "true" ]] \
  || fail "first tick must set dispatched.audit=true (boolean), got $(jq -c .dispatched "$state_dir/state.json")"
ok "init: cycle=1 phase=audit research_due precedence=loop"

# --- audit complete with findings, cycle 1 -> research (not conference) ----
printf '[{"number":11},{"number":12}]\n' >"$gaps_file"
tick
[[ "$(phase)" == "research" ]] || fail "cycle 1 after audit+findings must go research, got $(phase)"
[[ "$(jq -r '.cycle_findings' "$state_dir/state.json")" == "2" ]] \
  || fail "cycle_findings must be 2 (number), got $(jq -c .cycle_findings "$state_dir/state.json")"
ok "audit with findings on cycle 1 -> research (not conference)"

# --- research dispatch then complete -> fix --------------------------------
tick  # dispatch research
[[ "$(jq -r '.dispatched.research' "$state_dir/state.json")" == "true" ]] \
  || fail "research tick 1 must dispatch"
mode_file="$(find "$state_dir/conferences" -name mode | head -1)"
[[ -n "$mode_file" ]] || fail "research must write a conference mode file"
[[ "$(cat "$mode_file")" == "research" ]] || fail "mode must be research, got $(cat "$mode_file")"
tick  # complete research (dry-run, unit inactive)
[[ "$(phase)" == "fix" ]] || fail "research complete -> fix, got $(phase)"
[[ "$(jq -r '.research_due' "$state_dir/state.json")" == "false" ]] \
  || fail "research_due must flip false after research"
ok "research convenes then yields to fix"

# --- fix waits while board non-empty ---------------------------------------
tick
[[ "$(phase)" == "fix" ]] || fail "fix must wait while gaps open, got $(phase)"
ok "fix waits while gap-board has findings"

# --- drain -> drill --------------------------------------------------------
printf '[]\n' >"$gaps_file"
tick
[[ "$(phase)" == "drill" ]] || fail "drained board -> drill, got $(phase)"
ok "gap-board drained -> drill"

# --- drill dispatch then complete (seed results) ---------------------------
tick  # dispatch
# Seed a passing drill result as the drill unit would.
printf '{"all_pass":true,"results":[{"name":"unit-failure-escalation","pass":true}]}\n' \
  >"$state_dir/drill-results.json"
tick  # complete
[[ "$(phase)" == "measure" ]] || fail "drill complete -> measure, got $(phase)"
[[ "$(jq -r '.drills_pass' "$state_dir/state.json")" == "true" ]] \
  || fail "drills_pass must be true"
ok "drill complete -> measure"

# --- measure with findings=2: NOT clean, no conference, next cycle ---------
tick
[[ "$(phase)" == "audit" ]] || fail "findings>0 must NOT conference, got $(phase)"
[[ "$(cycle)" == "2" ]] || fail "not-clean must increment cycle, got $(cycle)"
[[ "$(jq -r '.consecutive_clean' "$state_dir/state.json")" == "0" ]] \
  || fail "not-clean consecutive_clean must be 0"
ok "cycle with findings -> no conference (re-audit cycle 2)"

# ---------------------------------------------------------------------------
# Clean cycle + green SLOs -> conference; 2-of-3 continues; unanimous closes
# ---------------------------------------------------------------------------
# fleet-ops#4524: a single clean cycle must NOT convene the termination
# conference when consecutive_clean is below the floor (default 2). It re-audits
# and keeps consecutive_clean, and must NOT mark last_verdict=FAIL on a clean
# cycle (it is clean, just too soon to convene).
cat >"$state_dir/state.json" <<'JSON'
{
  "cycle": 2,
  "phase": "measure",
  "cycle_findings": 0,
  "consecutive_clean": 0,
  "drills_pass": true,
  "drill_results": [],
  "slo_snapshot": {},
  "slos_green": null,
  "precedence": "loop",
  "research_due": false,
  "dispatched": {},
  "verdict_history": [],
  "last_verdict": "FAIL",
  "updated_at": "2026-08-26T16:00:00Z"
}
JSON
printf '{"all_pass":true,"results":[{"name":"x","pass":true}]}\n' >"$state_dir/drill-results.json"
printf '[]\n' >"$gaps_file"
tick
[[ "$(phase)" == "audit" ]] || fail "clean below floor must NOT convene conference, got $(phase)"
[[ "$(jq -r '.consecutive_clean' "$state_dir/state.json")" == "1" ]] \
  || fail "below-floor clean must keep consecutive_clean=1, got $(jq -c .consecutive_clean "$state_dir/state.json")"
[[ "$(jq -r '.last_verdict' "$state_dir/state.json")" == "FAIL" ]] \
  || fail "clean below floor must NOT rewrite last_verdict to FAIL, got $(jq -c .last_verdict "$state_dir/state.json")"
# fleet-ops#5021: the green verdict for this cycle must come from the pinned
# stub state only. fleet-ops#5400 pins a passing chain-e2e fixture in
# CHAIN_E2E_STATE_DIR (fail-closed SLO: a null rate is unmeasured, hence red),
# so the stored rate must read exactly 1 — our fixture, never a live leak.
[[ "$(jq -r '.slo_snapshot.snapshot.chain_e2e_drill_pass_rate' "$state_dir/state.json")" == "1" ]] \
  || fail "chain-e2e rate must be the pinned stub's 1, got $(jq -c '.slo_snapshot.snapshot.chain_e2e_drill_pass_rate' "$state_dir/state.json")"
ok "clean below floor -> re-audit, consecutive_clean kept, last_verdict untouched"

# A second consecutive clean cycle reaches the floor and convenes conference.
cat >"$state_dir/state.json" <<'JSON'
{
  "cycle": 3,
  "phase": "measure",
  "cycle_findings": 0,
  "consecutive_clean": 1,
  "drills_pass": true,
  "drill_results": [],
  "slo_snapshot": {},
  "slos_green": null,
  "precedence": "loop",
  "research_due": false,
  "dispatched": {},
  "verdict_history": [],
  "last_verdict": "FAIL",
  "updated_at": "2026-08-26T16:00:00Z"
}
JSON
printf '{"all_pass":true,"results":[{"name":"x","pass":true}]}\n' >"$state_dir/drill-results.json"
printf '[]\n' >"$gaps_file"
tick
[[ "$(phase)" == "conference" ]] || fail "clean at floor must convene conference, got $(phase)"
ok "clean cycle at floor -> conference convened"

# Dispatch conference (writes mode=termination).
tick
conf_id="$(jq -r '.dispatched.conf_id' "$state_dir/state.json")"
[[ -n "$conf_id" && "$conf_id" != "null" ]] || fail "conference must record conf_id"
[[ "$(cat "$state_dir/conferences/$conf_id/mode")" == "termination" ]] \
  || fail "termination mode file missing"
# 2-of-3 verdict.
mkdir -p "$state_dir/conferences/$conf_id"
"$tally" "$conf_id" termination \
  '[{"auditor":"glm-5-2","vote":"DONE"},{"auditor":"glm-5-3","vote":"DONE"},{"auditor":"ds4-pro","vote":"DONE"}]' \
  '[{"auditor":"glm-5-2","vote":"DONE","reason":"ok"},{"auditor":"glm-5-3","vote":"DONE","reason":"ok"},{"auditor":"ds4-pro","vote":"NOT-DONE","reason":"queue starvation"}]' \
  >"$state_dir/conferences/$conf_id/verdict.json"
: >"$creates"
tick
[[ "$(phase)" == "audit" ]] || fail "2-of-3 must CONTINUE the loop, got $(phase)"
[[ "$(prec_val)" == "loop" ]] || fail "2-of-3 must keep precedence=loop"
grep -q 'conference dissent' "$creates" || fail "2-of-3 must auto-file dissent, got: $(cat "$creates")"
ok "2-of-3 DONE -> loop continues, dissent filed"

# Unanimous DONE.
cat >"$state_dir/state.json" <<'JSON'
{
  "cycle": 3,
  "phase": "conference",
  "cycle_findings": 0,
  "consecutive_clean": 1,
  "drills_pass": true,
  "drill_results": [],
  "slo_snapshot": {"green": true},
  "slos_green": true,
  "precedence": "loop",
  "research_due": false,
  "dispatched": {"conference": true, "conf_id": "term-unanimous"},
  "verdict_history": [],
  "updated_at": "2026-08-26T16:00:00Z"
}
JSON
mkdir -p "$state_dir/conferences/term-unanimous"
printf 'termination\n' >"$state_dir/conferences/term-unanimous/mode"
"$tally" term-unanimous termination \
  '[{"auditor":"a","vote":"DONE"},{"auditor":"b","vote":"DONE"},{"auditor":"c","vote":"DONE"}]' \
  '[{"auditor":"a","vote":"DONE","reason":"ok"},{"auditor":"b","vote":"DONE","reason":"ok"},{"auditor":"c","vote":"DONE","reason":"ok"}]' \
  >"$state_dir/conferences/term-unanimous/verdict.json"
tick
[[ "$(phase)" == "done" ]] || fail "unanimous must close intensive loop, got $(phase)"
[[ "$(prec_val)" == "product" ]] || fail "unanimous must flip precedence=product, got $(prec_val)"
[[ "$(jq -r '.precedence' "$state_dir/state.json")" == "product" ]] \
  || fail "state.precedence must be product"
ok "unanimous DONE -> intensive loop closed, precedence=product"

# Injected regression reopens.
printf '[{"number":42}]\n' >"$gaps_file"
tick
[[ "$(phase)" == "audit" ]] || fail "regression must reopen, got $(phase)"
[[ "$(prec_val)" == "loop" ]] || fail "regression must flip precedence=loop, got $(prec_val)"
[[ "$(cycle)" == "4" ]] || fail "reopen must increment cycle, got $(cycle)"
ok "injected regression -> loop reopened, precedence=loop"

# ---------------------------------------------------------------------------
# GraphQL rate-limit guard: a transient API limit must not fail-loud.
# ---------------------------------------------------------------------------
cat >"$state_dir/state.json" <<'JSON'
{
  "cycle": 4,
  "phase": "fix",
  "cycle_findings": 2,
  "consecutive_clean": 0,
  "drills_pass": null,
  "drill_results": [],
  "slo_snapshot": {},
  "slos_green": null,
  "precedence": "loop",
  "research_due": false,
  "dispatched": {},
  "verdict_history": [],
  "last_verdict": "",
  "updated_at": "2026-08-26T16:00:00Z"
}
JSON
export GAP_LOOP_FAKE_GH_RATE_LIMIT=1
rl_out="$("$loop" 2>&1)"
export -n GAP_LOOP_FAKE_GH_RATE_LIMIT
[[ "$(phase)" == "fix" ]] || fail "rate-limit skip must keep phase=fix, got $(phase)"
[[ "$(cycle)" == "4" ]] || fail "rate-limit skip must not advance cycle, got $(cycle)"
printf '%s' "$rl_out" | grep -q "GraphQL rate limit exhausted" \
  || fail "rate-limit skip must log the guard, got: $rl_out"
ok "gap_board_count GraphQL rate-limit guard: exit 0, state unchanged, log"

# ---------------------------------------------------------------------------
# fleet-ops#4522: a stop-the-line freeze must defer the termination
# conference (never convene on a red/frozen pipeline), not file a dissent.
# ---------------------------------------------------------------------------
cat >"$state_dir/state.json" <<'JSON'
{
  "cycle": 7,
  "phase": "measure",
  "cycle_findings": 0,
  "consecutive_clean": 0,
  "drills_pass": true,
  "drill_results": [],
  "slo_snapshot": {},
  "slos_green": null,
  "precedence": "loop",
  "research_due": false,
  "dispatched": {},
  "verdict_history": [],
  "last_verdict": "",
  "updated_at": "2026-08-26T16:00:00Z"
}
JSON
printf '{"all_pass":true,"results":[{"name":"x","pass":true}]}\n' >"$state_dir/drill-results.json"
printf '[]\n' >"$gaps_file"
# Frozen line must defer, not convene.
export STL_FROZEN=1
"$loop"
[[ "$(phase)" == "audit" ]] \
  || fail "frozen line must defer conference and re-audit, got phase=$(phase)"
[[ "$(cycle)" == "8" ]] \
  || fail "frozen-line deferral must increment cycle, got cycle=$(cycle)"
[[ "$(jq -r '.consecutive_clean' "$state_dir/state.json")" == "0" ]] \
  || fail "frozen-line deferral must reset consecutive_clean"
export STL_FROZEN=0
ok "stop-the-line freeze defers the termination conference (no conference, no dissent)"

# ---------------------------------------------------------------------------
# SLO: #153 placeholder; drill pass rate gates green
# ---------------------------------------------------------------------------
export FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md"
: >"$scratch/triage.md"
snap="$(GAP_LOOP_DISABLE=1 "$slo")"
[[ "$(printf '%s' "$snap" | jq -r '.green')" == "true" ]] || fail "disabled SLO must be green"

printf '{"all_pass":true,"results":[{"name":"x","pass":true}]}\n' >"$state_dir/drill-results.json"
snap="$(GAP_LOOP_DISABLE=0 "$slo")"
[[ "$(printf '%s' "$snap" | jq -r '.snapshot.product_vs_control_plane_merge_ratio.source')" == "PLACEHOLDER:fleet-ops#153" ]] \
  || fail "SLO must declare #153 placeholder when no THROUGHPUT line, got: $snap"
[[ "$(printf '%s' "$snap" | jq -r '.green')" == "true" ]] || fail "drill all_pass must keep green"
[[ "$(printf '%s' "$snap" | jq -r '.snapshot.detector_drill_pass_rate')" == "1" ]] \
  || fail "drill pass rate must be 1, got $snap"

printf '[2026-08-26T16:00:00Z] [THROUGHPUT] merged_product_PRs=2 merged_control_plane_PRs=1 merged_fleet_worker_PRs=3 since=x\n' >"$scratch/triage.md"
snap="$(GAP_LOOP_DISABLE=0 "$slo")"
[[ "$(printf '%s' "$snap" | jq -r '.snapshot.product_vs_control_plane_merge_ratio.source')" == "fleet-ops#153" ]] \
  || fail "SLO must fill ratio from #153 THROUGHPUT line, got: $snap"
[[ "$(printf '%s' "$snap" | jq -r '.snapshot.product_vs_control_plane_merge_ratio.value.merged_product_PRs')" == "2" ]] \
  || fail "SLO must read product PR count from THROUGHPUT, got: $snap"

printf '{"all_pass":false,"results":[{"name":"x","pass":false}]}\n' >"$state_dir/drill-results.json"
snap="$(GAP_LOOP_DISABLE=0 "$slo")"
[[ "$(printf '%s' "$snap" | jq -r '.green')" == "false" ]] || fail "failed drill must make SLO not green"
printf '{"all_pass":true,"results":[{"name":"x","pass":true}]}\n' >"$state_dir/drill-results.json"
printf '{"cycle":{"verdict":"FAIL","regressions":["auto_revert_rate"]}}\n' >"$scratch/quality-fail.json"
snap="$(GAP_LOOP_DISABLE=0 GAP_LOOP_QUALITY_JSON="$scratch/quality-fail.json" "$slo")"
[[ "$(printf '%s' "$snap" | jq -r '.green')" == "false" ]] || fail "quality FAIL must make SLO not green, got: $snap"
ok "SLO snapshot: #153 placeholder, fills from THROUGHPUT, drill and quality gate green"

# ---------------------------------------------------------------------------
# fleet-ops#5400: the SLO snapshot fails closed — an unmeasured required input
# is budget-exhausted, never a pass, and unmeasured[] names it.
# ---------------------------------------------------------------------------
rm -f "$GAP_LOOP_STARVATION_JSON"
snap="$(GAP_LOOP_DISABLE=0 "$slo")"
[[ "$(printf '%s' "$snap" | jq -r '.green')" == "false" ]] \
  || fail "unmeasured queue_starvation_minutes must force green=false, got: $snap"
printf '%s' "$snap" | jq -e '.unmeasured | index("queue_starvation_minutes")' >/dev/null \
  || fail "unmeasured must name queue_starvation_minutes, got: $snap"
printf '{"starvation_minutes_24h":0}\n' >"$GAP_LOOP_STARVATION_JSON"

rm -f "$GAP_LOOP_TTR_JSON"
snap="$(GAP_LOOP_DISABLE=0 "$slo")"
[[ "$(printf '%s' "$snap" | jq -r '.green')" == "false" ]] \
  || fail "empty time_to_repair_per_class must force green=false, got: $snap"
printf '%s' "$snap" | jq -e '.unmeasured | index("time_to_repair_per_class")' >/dev/null \
  || fail "unmeasured must name time_to_repair_per_class, got: $snap"
printf '{"detector-rot":37}\n' >"$GAP_LOOP_TTR_JSON"

printf '[]\n' >"$CLOSED_GAPS_JSON"
snap="$(GAP_LOOP_DISABLE=0 "$slo")"
[[ "$(printf '%s' "$snap" | jq -r '.green')" == "false" ]] \
  || fail "no closed gap-audit issues -> pct_auto_repaired unmeasured -> red, got: $snap"
printf '%s' "$snap" | jq -e '.unmeasured | index("pct_auto_repaired")' >/dev/null \
  || fail "unmeasured must name pct_auto_repaired, got: $snap"
printf '[{"labels":[{"name":"agent-blocked"}]}]\n' >"$CLOSED_GAPS_JSON"
snap="$(GAP_LOOP_DISABLE=0 "$slo")"
[[ "$(printf '%s' "$snap" | jq -r '.green')" == "false" ]] \
  || fail "measured 0% auto-repair must not read green, got: $snap"
[[ "$(printf '%s' "$snap" | jq -r '.snapshot.pct_auto_repaired')" == "0" ]] \
  || fail "all-blocked closed board must compute pct_auto_repaired=0, got: $snap"

printf '[{"labels":[]},{"labels":[]}]\n' >"$CLOSED_GAPS_JSON"
snap="$(GAP_LOOP_DISABLE=0 "$slo")"
[[ "$(printf '%s' "$snap" | jq -r '.green')" == "true" ]] \
  || fail "fully measured passing inputs must yield green, got: $snap"
[[ "$(printf '%s' "$snap" | jq -r '.unmeasured | length')" == "0" ]] \
  || fail "measured inputs must leave unmeasured empty, got: $snap"
[[ "$(printf '%s' "$snap" | jq -r '.snapshot.pct_auto_repaired')" == "100" ]] \
  || fail "label-counted pct_auto_repaired must be 100, got: $snap"
ok "SLO fails closed: unmeasured required inputs and 0% auto-repair read red"

# ---------------------------------------------------------------------------
# Intake yield + order
# ---------------------------------------------------------------------------
export GAP_LOOP_PRECEDENCE_FILE="$prec"
printf 'loop\n' >"$prec"
# Fake gh: fleet-ops has one agent-ready gap-audit issue.
cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*fleet-ops*agent-ready*)
    printf '1\n'
    ;;
  *)
    printf '0\n'
    ;;
esac
FAKE
[[ "$("$yield" 0509)" == "yield" ]] || fail "0509 must yield while precedence=loop and fleet-ops has gap-audit ready"
[[ "$("$yield" fleet-ops)" == "proceed" ]] || fail "fleet-ops must proceed under loop precedence"
printf 'product\n' >"$prec"
[[ "$("$yield" 0509)" == "proceed" ]] || fail "0509 must proceed after DONE (precedence=product)"
ok "intake yield: loop outranks 0509 until DONE"

printf 'loop\n' >"$prec"
ordered="$(printf '%s' '[{"number":3,"labels":[{"name":"agent-ready"}]},{"number":1,"labels":[{"name":"agent-ready"},{"name":"gap-audit"}]},{"number":2,"labels":[{"name":"agent-ready"}]}]' | "$order")"
got="$(printf '%s\n' "$ordered" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
[[ "$got" == "1 2 3" ]] \
  || fail "loop order must put gap-audit first then by number, got: $got"
printf 'product\n' >"$prec"
ordered="$(printf '%s' '[{"number":3,"labels":[{"name":"agent-ready"}]},{"number":1,"labels":[{"name":"agent-ready"},{"name":"gap-audit"}]},{"number":2,"labels":[{"name":"agent-ready"}]}]' | "$order")"
[[ "$(printf '%s' "$ordered" | awk 'NR==1')" == "2" ]] \
  || fail "product order must put gap-audit last, first should be 2, got: $ordered"
ok "intake order: gap-audit first while loop, last after DONE"

# ---------------------------------------------------------------------------
# pi-audit-run + conference dry-run + drill dry-run (the deliverable run)
# ---------------------------------------------------------------------------
jobdir="$state_dir/pi-audit-jobs/dry-token"
mkdir -p "$jobdir" "$scratch/pkt"
printf '{"vote?":"n"}\n' >"$scratch/pkt/packet.md"  # packet existence only
jq -n -c --arg packet "$scratch/pkt/packet.md" --arg stdout "$scratch/pkt/out.json" \
  '{token:"dry-token",provider:"devin",model:"glm-5-2",packet:$packet,stdout:$stdout,mode:"termination",round:"1",auditor:"glm-5-2"}' \
  >"$jobdir/job.json"
PI_AUDIT_DRY_RUN=1 PI_AUDIT_INSTANCE=dry-token GAP_LOOP_STATE_DIR="$state_dir" \
  "$audit_run" dry-token
[[ "$(jq -r '.vote' "$scratch/pkt/out.json")" == "DONE" ]] \
  || fail "fleet-gap-closure-auditor dry-run must write DONE JSON, got $(cat "$scratch/pkt/out.json")"
ok "fleet-gap-closure-auditor dry-run writes a JSON verdict"

# ---------------------------------------------------------------------------
# fleet-ops#1593: seat preflight refuses dead or absent seats before launch.
# ---------------------------------------------------------------------------
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$state_dir/seats"
fake_pi="$scratch/bin/fake-pi"
cat >"$fake_pi" <<'FAKE'
#!/usr/bin/env bash
printf '{"vote":"DONE","reason":"ok"}\n'
FAKE
chmod +x "$fake_pi"

# 1. dead straitly/ds4-pro (seat_dead=true, credentials_bad).
jobdir="$state_dir/pi-audit-jobs/dead-token"
mkdir -p "$jobdir"
cat >"$state_dir/seats/straitly__deepseek_deepseek-v4-pro.json" <<EOF
{"provider":"straitly","model":"deepseek/deepseek-v4-pro","health_class":"credentials_bad","seat_dead":true,"observed_at":"$NOW"}
EOF
jq -n -c --arg packet "$scratch/pkt/packet.md" --arg stdout "$scratch/pkt/dead.json" \
  '{token:"dead-token",provider:"straitly",model:"deepseek/deepseek-v4-pro",packet:$packet,stdout:$stdout,mode:"termination",round:"1",auditor:"ds4-pro"}' \
  >"$jobdir/job.json"
PI_AUDIT_INSTANCE=dead-token GAP_LOOP_STATE_DIR="$state_dir" \
  PI_SEAT_HEALTH_LEDGER_DIR="$state_dir/seats" PI_SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
  PI_AUDIT_PI_BIN=/bin/false "$audit_run" dead-token
[[ "$(jq -r '.vote' "$scratch/pkt/dead.json")" == "NOT-DONE" ]] \
  || fail "dead seat must be refused, got $(cat "$scratch/pkt/dead.json")"
[[ "$(jq -r '._seat_preflight' "$scratch/pkt/dead.json")" == "true" ]] \
  || fail "dead seat refusal must be flagged as preflight"
[[ "$(jq -r '.preflight_reason' "$scratch/pkt/dead.json")" == "seat_dead=true" ]] \
  || fail "dead seat refusal must carry the precise reason, got $(jq -r '.preflight_reason' "$scratch/pkt/dead.json")"
ok "fleet-gap-closure-auditor refuses dead seat"

# 2. absent zenmux/glm-5.3-free (no ledger, no global match).
jobdir="$state_dir/pi-audit-jobs/absent-token"
mkdir -p "$jobdir"
jq -n -c --arg packet "$scratch/pkt/packet.md" --arg stdout "$scratch/pkt/absent.json" \
  '{token:"absent-token",provider:"zenmux",model:"z-ai/glm-5.3-free",packet:$packet,stdout:$stdout,mode:"termination",round:"1",auditor:"glm-5-3"}' \
  >"$jobdir/job.json"
PI_AUDIT_INSTANCE=absent-token GAP_LOOP_STATE_DIR="$state_dir" \
  PI_SEAT_HEALTH_LEDGER_DIR="$state_dir/seats" PI_SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
  PI_AUDIT_PI_BIN=/bin/false "$audit_run" absent-token
[[ "$(jq -r '.vote' "$scratch/pkt/absent.json")" == "NOT-DONE" ]] \
  || fail "absent seat must be refused, got $(cat "$scratch/pkt/absent.json")"
[[ "$(jq -r '._seat_preflight' "$scratch/pkt/absent.json")" == "true" ]] \
  || fail "absent seat refusal must be flagged as preflight"
[[ "$(jq -r '.preflight_reason' "$scratch/pkt/absent.json")" == "no health data" ]] \
  || fail "absent seat refusal must carry the precise reason, got $(jq -r '.preflight_reason' "$scratch/pkt/absent.json")"
ok "fleet-gap-closure-auditor refuses absent seat"

# 3. healthy devin/glm-5-2 runs the fake pi and returns DONE.
jobdir="$state_dir/pi-audit-jobs/healthy-token"
mkdir -p "$jobdir"
cat >"$state_dir/seats/devin__glm-5-2.json" <<EOF
{"provider":"devin","model":"glm-5-2","health_class":"healthy","seat_dead":false,"observed_at":"$NOW"}
EOF
jq -n -c --arg packet "$scratch/pkt/packet.md" --arg stdout "$scratch/pkt/healthy.json" \
  '{token:"healthy-token",provider:"devin",model:"glm-5-2",packet:$packet,stdout:$stdout,mode:"termination",round:"1",auditor:"glm-5-2"}' \
  >"$jobdir/job.json"
PI_AUDIT_INSTANCE=healthy-token GAP_LOOP_STATE_DIR="$state_dir" \
  PI_SEAT_HEALTH_LEDGER_DIR="$state_dir/seats" PI_SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
  PI_AUDIT_PI_BIN="$fake_pi" "$audit_run" healthy-token
[[ "$(jq -r '.vote' "$scratch/pkt/healthy.json")" == "DONE" ]] \
  || fail "healthy seat must run and return DONE, got $(cat "$scratch/pkt/healthy.json")"
ok "fleet-gap-closure-auditor runs healthy seat"

# ---------------------------------------------------------------------------
# fleet-ops#5399: pi --print prepends narration to the verdict object, so a
# whole-file jq parse fails and the auditor's real vote was filed as the
# mechanical "pi output was not valid JSON" dissent (cycle-15). The wrapper
# must recover the embedded verdict before falling back.
# ---------------------------------------------------------------------------

# 4a. narration + embedded termination verdict -> recovered with its reason.
cat >"$scratch/bin/fake-pi-prose" <<'FAKE'
#!/usr/bin/env bash
printf 'Verifying live state on the load-bearing issues before casting my vote.{"vote":"NOT-DONE","reason":"real auditor reason"}\n'
FAKE
chmod +x "$scratch/bin/fake-pi-prose"
jobdir="$state_dir/pi-audit-jobs/prose-token"
mkdir -p "$jobdir"
jq -n -c --arg packet "$scratch/pkt/packet.md" --arg stdout "$scratch/pkt/prose.json" \
  '{token:"prose-token",provider:"devin",model:"glm-5-2",packet:$packet,stdout:$stdout,mode:"termination",round:"2",auditor:"glm-5-3"}' \
  >"$jobdir/job.json"
PI_AUDIT_INSTANCE=prose-token GAP_LOOP_STATE_DIR="$state_dir" \
  PI_SEAT_HEALTH_LEDGER_DIR="$state_dir/seats" PI_SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
  PI_AUDIT_PI_BIN="$scratch/bin/fake-pi-prose" "$audit_run" prose-token
[[ "$(jq -r '.vote' "$scratch/pkt/prose.json")" == "NOT-DONE" ]] \
  || fail "embedded verdict must be recovered, got $(cat "$scratch/pkt/prose.json")"
[[ "$(jq -r '.reason' "$scratch/pkt/prose.json")" == "real auditor reason" ]] \
  || fail "recovered verdict must keep the auditor's real reason, got $(cat "$scratch/pkt/prose.json")"
[[ "$(jq -r '._extracted' "$scratch/pkt/prose.json")" == "true" ]] \
  || fail "recovered verdict must be marked _extracted"
ok "fleet-gap-closure-auditor recovers a verdict embedded in narration"

# 4b. prose only, no JSON anywhere -> generic refusal still applies.
cat >"$scratch/bin/fake-pi-nojson" <<'FAKE'
#!/usr/bin/env bash
printf 'I could not reach a verdict.\n'
FAKE
chmod +x "$scratch/bin/fake-pi-nojson"
jobdir="$state_dir/pi-audit-jobs/nojson-token"
mkdir -p "$jobdir"
jq -n -c --arg packet "$scratch/pkt/packet.md" --arg stdout "$scratch/pkt/nojson.json" \
  '{token:"nojson-token",provider:"devin",model:"glm-5-2",packet:$packet,stdout:$stdout,mode:"termination",round:"1",auditor:"glm-5-2"}' \
  >"$jobdir/job.json"
PI_AUDIT_INSTANCE=nojson-token GAP_LOOP_STATE_DIR="$state_dir" \
  PI_SEAT_HEALTH_LEDGER_DIR="$state_dir/seats" PI_SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
  PI_AUDIT_PI_BIN="$scratch/bin/fake-pi-nojson" "$audit_run" nojson-token
[[ "$(jq -r '.reason' "$scratch/pkt/nojson.json")" == "pi output was not valid JSON" ]] \
  || fail "prose-only output must still file the generic refusal, got $(cat "$scratch/pkt/nojson.json")"
[[ "$(jq -r '.vote' "$scratch/pkt/nojson.json")" == "NOT-DONE" ]] \
  || fail "generic refusal must vote NOT-DONE, got $(cat "$scratch/pkt/nojson.json")"
[[ -n "$(jq -r '.raw // ""' "$scratch/pkt/nojson.json")" ]] \
  || fail "generic refusal must carry a non-empty raw excerpt for diagnostics, got $(cat "$scratch/pkt/nojson.json")"
ok "fleet-gap-closure-auditor keeps the generic refusal for prose-only output"

# 4b2. large prose output -> the refusal still files, and the diagnostic raw
# excerpt stays bounded (<= 2000 bytes) so a multi-KB narration dump never
# reaches the conference tally (fleet-ops#5398). Pins the bound so refactors
# of the excerpt capture cannot silently drop or unbound it.
cat >"$scratch/bin/fake-pi-bigprose" <<'FAKE'
#!/usr/bin/env bash
python3 -c "import sys; sys.stdout.write('Still deliberating, no verdict JSON in sight. ' * 1200)"
FAKE
chmod +x "$scratch/bin/fake-pi-bigprose"
jobdir="$state_dir/pi-audit-jobs/bigprose-token"
mkdir -p "$jobdir"
jq -n -c --arg packet "$scratch/pkt/packet.md" --arg stdout "$scratch/pkt/bigprose.json" \
  '{token:"bigprose-token",provider:"devin",model:"glm-5-2",packet:$packet,stdout:$stdout,mode:"termination",round:"1",auditor:"glm-5-2"}' \
  >"$jobdir/job.json"
PI_AUDIT_INSTANCE=bigprose-token GAP_LOOP_STATE_DIR="$state_dir" \
  PI_SEAT_HEALTH_LEDGER_DIR="$state_dir/seats" PI_SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
  PI_AUDIT_PI_BIN="$scratch/bin/fake-pi-bigprose" "$audit_run" bigprose-token
[[ "$(jq -r '.vote' "$scratch/pkt/bigprose.json")" == "NOT-DONE" ]] \
  || fail "large prose output must still file a NOT-DONE refusal, got $(cat "$scratch/pkt/bigprose.json")"
[[ "$(jq -r '.reason' "$scratch/pkt/bigprose.json")" == "pi output was not valid JSON" ]] \
  || fail "large prose refusal must keep the cycle-15 reason, got $(cat "$scratch/pkt/bigprose.json")"
[[ "$(jq -r '.raw // "" | utf8bytelength' "$scratch/pkt/bigprose.json")" -le 2000 ]] \
  || fail "raw excerpt must stay bounded at 2000 bytes, got $(jq -r '.raw | utf8bytelength' "$scratch/pkt/bigprose.json")"
[[ -n "$(jq -r '.raw // ""' "$scratch/pkt/bigprose.json")" ]] \
  || fail "large prose refusal must carry a non-empty raw excerpt, got $(cat "$scratch/pkt/bigprose.json")"
ok "fleet-gap-closure-auditor bounds the refusal raw excerpt (<= 2000 bytes)"

# 4b3. pi exits 0 with empty output -> the refusal still files (the tally
# must keep moving) and raw may legitimately be empty (fleet-ops#5398).
cat >"$scratch/bin/fake-pi-empty" <<'FAKE'
#!/usr/bin/env bash
FAKE
chmod +x "$scratch/bin/fake-pi-empty"
jobdir="$state_dir/pi-audit-jobs/empty-token"
mkdir -p "$jobdir"
jq -n -c --arg packet "$scratch/pkt/packet.md" --arg stdout "$scratch/pkt/empty.json" \
  '{token:"empty-token",provider:"devin",model:"glm-5-2",packet:$packet,stdout:$stdout,mode:"termination",round:"1",auditor:"glm-5-2"}' \
  >"$jobdir/job.json"
PI_AUDIT_INSTANCE=empty-token GAP_LOOP_STATE_DIR="$state_dir" \
  PI_SEAT_HEALTH_LEDGER_DIR="$state_dir/seats" PI_SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
  PI_AUDIT_PI_BIN="$scratch/bin/fake-pi-empty" "$audit_run" empty-token
[[ "$(jq -r '.vote' "$scratch/pkt/empty.json")" == "NOT-DONE" ]] \
  || fail "empty output must still file a NOT-DONE refusal, got $(cat "$scratch/pkt/empty.json")"
[[ "$(jq -r '.reason' "$scratch/pkt/empty.json")" == "pi output was not valid JSON" ]] \
  || fail "empty output refusal must keep the cycle-15 reason, got $(cat "$scratch/pkt/empty.json")"
ok "fleet-gap-closure-auditor files the refusal even for empty pi output"

# 4c. research-mode jobs recover the adopted/deltas shape, not a vote object.
cat >"$scratch/bin/fake-pi-research" <<'FAKE'
#!/usr/bin/env bash
printf 'Converging.{"adopted":[{"title":"t","body":"b"}],"rejected":[]}\n'
FAKE
chmod +x "$scratch/bin/fake-pi-research"
jobdir="$state_dir/pi-audit-jobs/research-token"
mkdir -p "$jobdir"
jq -n -c --arg packet "$scratch/pkt/packet.md" --arg stdout "$scratch/pkt/research.json" \
  '{token:"research-token",provider:"devin",model:"glm-5-2",packet:$packet,stdout:$stdout,mode:"research",round:"2",auditor:"glm-5-2"}' \
  >"$jobdir/job.json"
PI_AUDIT_INSTANCE=research-token GAP_LOOP_STATE_DIR="$state_dir" \
  PI_SEAT_HEALTH_LEDGER_DIR="$state_dir/seats" PI_SEAT_HEALTH_FILE="$scratch/pi-seat-health.json" \
  PI_AUDIT_PI_BIN="$scratch/bin/fake-pi-research" "$audit_run" research-token
[[ "$(jq -r '.adopted[0].title' "$scratch/pkt/research.json")" == "t" ]] \
  || fail "research verdict must be recovered, got $(cat "$scratch/pkt/research.json")"
ok "fleet-gap-closure-auditor recovers a research verdict embedded in narration"

# Drill dry-run writes all_pass results (the deliverable).
GAP_LOOP_DRY_RUN=1 GAP_LOOP_STATE_DIR="$state_dir" "$drill"
[[ "$(jq -r '.all_pass' "$state_dir/drill-results.json")" == "true" ]] \
  || fail "drill dry-run must all_pass, got $(cat "$state_dir/drill-results.json")"
[[ "$(jq -r '.results | length' "$state_dir/drill-results.json")" -ge 3 ]] \
  || fail "drill must record the three detector proofs"
ok "drill dry-run writes all_pass results"

# Conference dry-run: needs prompts + conf dir + auditors.
conf_id="test-conf"
mkdir -p "$state_dir/conferences/$conf_id"
printf 'termination\n' >"$state_dir/conferences/$conf_id/mode"
printf '{"cycle":1}\n' >"$state_dir/state.json"
GAP_LOOP_CONF_ID="$conf_id" GAP_LOOP_DRY_RUN=1 GAP_LOOP_STATE_DIR="$state_dir" \
  GAP_LOOP_TALLY_BIN="$tally" GAP_LOOP_GH="$scratch/bin/gh" \
  GAP_LOOP_SYSTEMCTL="$scratch/bin/systemctl" \
  GAP_LOOP_AUDITORS='[{"id":"a","provider":"devin","model":"m"},{"id":"b","provider":"devin","model":"m"},{"id":"c","provider":"devin","model":"m"}]' \
  "$conf"
[[ -f "$state_dir/conferences/$conf_id/verdict.json" ]] \
  || fail "conference must write verdict.json"
[[ "$(jq -r '.unanimous_done' "$state_dir/conferences/$conf_id/verdict.json")" == "true" ]] \
  || fail "termination dry-run (3 DONE stubs) must be unanimous, got $(cat "$state_dir/conferences/$conf_id/verdict.json")"
ok "conference dry-run tallies unanimous DONE from three stubs"

# ---------------------------------------------------------------------------
# fleet-ops#4210: the glm-5-3 auditor must resolve to a LIVE wired free-GLM
# seat (seatlib health ledger), not the hardcoded unwired
# zenmux/z-ai/glm-5.3-free slug that made every termination conference file a
# mechanical gap-audit dissent.
# ---------------------------------------------------------------------------
res_seat_state="$state_dir/resolve-seats"
res_caps="$state_dir/resolve-caps"
mkdir -p "$res_seat_state" "$res_caps" "$res_caps/pp"
cat >"$res_caps/seat-caps.json" <<'CAPS'
{"providers":{"cline":{"cap":2,"class":"prepaid-quota","models":{"z-ai/glm-5.3-flash":{"cap":1,"class":"free"}}},"devin":{"cap":2,"class":"prepaid-quota","models":{"glm-5-2":{"cap":1}}}},"senior_seats_in_order":[]}
CAPS
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"$res_seat_state/cline__z-ai_glm-5.3-flash.json" <<EOF
{"provider":"cline","model":"z-ai/glm-5.3-flash","health_class":"healthy","seat_dead":false,"observed_at":"$NOW","source":"test"}
EOF
# Scenario A: cline/z-ai/glm-5.3-flash wired + healthy -> glm-5-3 lands there.
res_conf="resolve-conf"
mkdir -p "$state_dir/conferences/$res_conf"
printf 'termination\n' >"$state_dir/conferences/$res_conf/mode"
printf '{"cycle":1}\n' >"$state_dir/state.json"
GAP_LOOP_CONF_ID="$res_conf" GAP_LOOP_DRY_RUN=1 GAP_LOOP_STATE_DIR="$state_dir" \
  GAP_LOOP_TALLY_BIN="$tally" GAP_LOOP_GH="$scratch/bin/gh" \
  GAP_LOOP_SYSTEMCTL="$scratch/bin/systemctl" \
  PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh" \
  SEAT_CAPS_JSON="$res_caps/seat-caps.json" \
  PI_MODELS_JSON="$res_caps/models.json" \
  PI_SEAT_HEALTH_LEDGER_DIR="$res_seat_state" \
  PI_SEAT_HEALTH_FILE="$res_caps/global-seat-health.json" \
  PI_PACKET_STATE="$res_caps/pp" SEAT_LOG_FILE="$res_caps/pp/watch.log" \
  "$conf"
[[ -f "$state_dir/conferences/$res_conf/verdict.json" ]] \
  || fail "resolve conference must complete in dry-run"
gj="$state_dir/pi-audit-jobs/${res_conf}-r1-glm-5-3/job.json"
[[ -f "$gj" ]] || fail "conference must write a glm-5-3 job: $gj"
[[ "$(jq -r '.provider' "$gj")" == "cline" && "$(jq -r '.model' "$gj")" == "z-ai/glm-5.3-flash" ]] \
  || fail "glm-5-3 must resolve to the live wired free seat, got $(jq -c '{provider,model}' "$gj")"
ok "glm-5-3 resolves to live wired free-GLM seat (cline/z-ai/glm-5.3-flash)"

# Scenario B: the wired free seat is dead and no other free seat exists ->
# glm-5-3 keeps the ladder slug so the preflight refusal (and dissent) still
# surfaces the wall.
cat >"$res_seat_state/cline__z-ai_glm-5.3-flash.json" <<EOF
{"provider":"cline","model":"z-ai/glm-5.3-flash","health_class":"healthy","seat_dead":true,"observed_at":"$NOW","source":"test"}
EOF
res_conf2="resolve-conf-b"
mkdir -p "$state_dir/conferences/$res_conf2"
printf 'termination\n' >"$state_dir/conferences/$res_conf2/mode"
printf '{"cycle":1}\n' >"$state_dir/state.json"
GAP_LOOP_CONF_ID="$res_conf2" GAP_LOOP_DRY_RUN=1 GAP_LOOP_STATE_DIR="$state_dir" \
  GAP_LOOP_TALLY_BIN="$tally" GAP_LOOP_GH="$scratch/bin/gh" \
  GAP_LOOP_SYSTEMCTL="$scratch/bin/systemctl" \
  PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh" \
  SEAT_CAPS_JSON="$res_caps/seat-caps.json" \
  PI_MODELS_JSON="$res_caps/models.json" \
  PI_SEAT_HEALTH_LEDGER_DIR="$res_seat_state" \
  PI_SEAT_HEALTH_FILE="$res_caps/global-seat-health.json" \
  PI_PACKET_STATE="$res_caps/pp" SEAT_LOG_FILE="$res_caps/pp/watch.log" \
  "$conf"
gj2="$state_dir/pi-audit-jobs/${res_conf2}-r1-glm-5-3/job.json"
[[ -f "$gj2" ]] || fail "conference must write a glm-5-3 job: $gj2"
[[ "$(jq -r '.provider' "$gj2")" == "zenmux" && "$(jq -r '.model' "$gj2")" == "z-ai/glm-5.3-free" ]] \
  || fail "glm-5-3 must keep the ladder slug when nothing is usable, got $(jq -c '{provider,model}' "$gj2")"
ok "glm-5-3 keeps ladder slug when no free seat is usable (preflight surfaces wall)"

# Scenario C: ladder + every free seat unusable, but a capable seat is live ->
# glm-5-3 falls back to the first usable capable seat (pi-audit-run
# resolve_free_role shape), so the loop can converge while free lanes are all
# benched.
cat >"$res_caps/seat-caps.json" <<'CAPS'
{"providers":{"cline":{"cap":2,"class":"prepaid-quota","models":{"z-ai/glm-5.3-flash":{"cap":1,"class":"free"}}},"cursor":{"cap":2,"class":"capable","models":{"cursor-grok-4.6-high":{"cap":1,"class":"capable"}}},"devin":{"cap":2,"class":"prepaid-quota","models":{"glm-5-2":{"cap":1}}}},"senior_seats_in_order":[]}
CAPS
cat >"$res_caps/models.json" <<'MODELS'
{"providers":{"cursor":{"models":[{"id":"cursor-grok-4.6-high","reasoning":true}]}}}
MODELS
cat >"$res_seat_state/cursor__cursor-grok-4.6-high.json" <<EOF
{"provider":"cursor","model":"cursor-grok-4.6-high","health_class":"healthy","seat_dead":false,"observed_at":"$NOW","source":"test"}
EOF
res_conf3="resolve-conf-c"
mkdir -p "$state_dir/conferences/$res_conf3"
printf 'termination\n' >"$state_dir/conferences/$res_conf3/mode"
printf '{"cycle":1}\n' >"$state_dir/state.json"
GAP_LOOP_CONF_ID="$res_conf3" GAP_LOOP_DRY_RUN=1 GAP_LOOP_STATE_DIR="$state_dir" \
  GAP_LOOP_TALLY_BIN="$tally" GAP_LOOP_GH="$scratch/bin/gh" \
  GAP_LOOP_SYSTEMCTL="$scratch/bin/systemctl" \
  PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh" \
  SEAT_CAPS_JSON="$res_caps/seat-caps.json" \
  PI_MODELS_JSON="$res_caps/models.json" \
  PI_SEAT_HEALTH_LEDGER_DIR="$res_seat_state" \
  PI_SEAT_HEALTH_FILE="$res_caps/global-seat-health.json" \
  PI_PACKET_STATE="$res_caps/pp" SEAT_LOG_FILE="$res_caps/pp/watch.log" \
  "$conf"
gj3="$state_dir/pi-audit-jobs/${res_conf3}-r1-glm-5-3/job.json"
[[ -f "$gj3" ]] || fail "conference must write a glm-5-3 job: $gj3"
[[ "$(jq -r '.provider' "$gj3")" == "cursor" && "$(jq -r '.model' "$gj3")" == "cursor-grok-4.6-high" ]] \
  || fail "glm-5-3 must fall back to a usable capable seat, got $(jq -c '{provider,model}' "$gj3")"
ok "glm-5-3 falls back to usable capable seat when no free seat is live"

# ---------------------------------------------------------------------------
# fleet-ops#4523: a wired free-class seat with NO health ledger (an unwired
# or never-probed slug sitting in enumerate_seats) must NOT throw "hc:
# unbound variable" under `set -u` and abort resolve_free_glm_conf_seat.
# Before the fix, production's full models.json made the resolver scan past a
# no-ledger free seat first, crash the whole command-substitution subshell,
# and fall back to the unwired zenmux/z-ai/glm-5.3-free ladder slug -> a
# preflight refusal -> a blind-seat dissent every conference. The resolver
# must skip the no-ledger seat and still fall through to a usable capable
# seat.
cap5="$state_dir/resolve-caps-d"
mkdir -p "$cap5"
cat >"$cap5/seat-caps.json" <<'CAPS'
{"providers":{
  "cline":{"cap":2,"class":"prepaid-quota","models":{"z-ai/glm-5.3-flash":{"cap":1,"class":"free"}}},
  "zenmux":{"cap":2,"class":"prepaid-quota","models":{"z-ai/glm-4.7-flash-free":{"cap":1,"class":"free"}}},
  "cursor":{"cap":2,"class":"capable","models":{"cursor-grok-4.6-high":{"cap":1,"class":"capable"}}}
},"senior_seats_in_order":[]}
CAPS
cat >"$cap5/models.json" <<'MODELS'
{"providers":{"zenmux":{"models":[{"id":"z-ai/glm-4.7-flash-free","reasoning":false}]},"cursor":{"models":[{"id":"cursor-grok-4.6-high","reasoning":true}]}}}
MODELS
# cline free-GLM ladder seat dead -> step 1 empty. cursor capable seat live.
# NO ledger for zenmux/z-ai/glm-4.7-flash-free -> the resolver must skip it
# (non-match), not crash, and land on cursor.
cat >"$res_seat_state/cline__z-ai_glm-5.3-flash.json" <<EOF
{"provider":"cline","model":"z-ai/glm-5.3-flash","health_class":"healthy","seat_dead":true,"observed_at":"$NOW","source":"test"}
EOF
cat >"$res_seat_state/cursor__cursor-grok-4.6-high.json" <<EOF
{"provider":"cursor","model":"cursor-grok-4.6-high","health_class":"healthy","seat_dead":false,"observed_at":"$NOW","source":"test"}
EOF
res_conf4="resolve-conf-d"
mkdir -p "$state_dir/conferences/$res_conf4"
printf 'termination\n' >"$state_dir/conferences/$res_conf4/mode"
printf '{"cycle":1}\n' >"$state_dir/state.json"
GAP_LOOP_CONF_ID="$res_conf4" GAP_LOOP_DRY_RUN=1 GAP_LOOP_STATE_DIR="$state_dir" \
  GAP_LOOP_TALLY_BIN="$tally" GAP_LOOP_GH="$scratch/bin/gh" \
  GAP_LOOP_SYSTEMCTL="$scratch/bin/systemctl" \
  PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh" \
  SEAT_CAPS_JSON="$cap5/seat-caps.json" \
  PI_MODELS_JSON="$cap5/models.json" \
  PI_SEAT_HEALTH_LEDGER_DIR="$res_seat_state" \
  PI_SEAT_HEALTH_FILE="$cap5/global-seat-health.json" \
  PI_PACKET_STATE="$cap5/pp" SEAT_LOG_FILE="$cap5/pp/watch.log" \
  "$conf"
gj4="$state_dir/pi-audit-jobs/${res_conf4}-r1-glm-5-3/job.json"
[[ -f "$gj4" ]] || fail "conference must write a glm-5-3 job: $gj4"
[[ "$(jq -r '.provider' "$gj4")" == "cursor" && "$(jq -r '.model' "$gj4")" == "cursor-grok-4.6-high" ]] \
  || fail "glm-5-3 must skip the no-ledger free seat and fall back to the usable capable seat, got $(jq -c '{provider,model}' "$gj4")"
ok "glm-5-3 skips a no-ledger free seat without crashing (set -u / fleet-ops#4523)"

# ---------------------------------------------------------------------------
# fleet-ops#4209: the glm-5-2 auditor must resolve to a LIVE wired seat, not
# the hardcoded devin/glm-5-2 that the auditor preflight refused when the
# devin lane was quota-benched (cycle-4 termination conference
# 2026-09-07T10:49:54Z: devin/glm-5-2 benched until 2026-09-08T09:01:04Z — a
# no-show dissent, not an auditor judgment). Resolves through a devin ladder
# (glm-5-2 then swe-1-7) and falls back to any usable capable seat, keeping
# the ladder slug only when nothing anywhere is usable so a genuine wall
# still surfaces as a preflight refusal.
# ---------------------------------------------------------------------------
res_seat_state2="$state_dir/resolve-seats-2"
res_caps2="$state_dir/resolve-caps-2"
mkdir -p "$res_seat_state2" "$res_caps2" "$res_caps2/pp"
cat >"$res_caps2/seat-caps.json" <<'CAPS'
{"providers":{"devin":{"cap":2,"class":"prepaid-quota","models":{"glm-5-2":{"cap":1},"swe-1-7":{"cap":1}}}},"senior_seats_in_order":[]}
CAPS
cat >"$res_caps2/models.json" <<'MODELS'
{"providers":{"devin":{"models":[{"id":"glm-5-2"},{"id":"swe-1-7"}]}}}
MODELS
NOW2="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FUTURE2="$(date -u -d '+2 days' +%Y-%m-%dT%H:%M:%SZ)"

# Scenario A: devin/glm-5-2 wired + healthy -> glm-5-2 lands there (the
# common case is unchanged).
cat >"$res_seat_state2/devin__glm-5-2.json" <<EOF
{"provider":"devin","model":"glm-5-2","health_class":"healthy","seat_dead":false,"observed_at":"$NOW2","source":"test"}
EOF
res_conf4="resolve-conf-2a"
mkdir -p "$state_dir/conferences/$res_conf4"
printf 'termination\n' >"$state_dir/conferences/$res_conf4/mode"
printf '{"cycle":1}\n' >"$state_dir/state.json"
GAP_LOOP_CONF_ID="$res_conf4" GAP_LOOP_DRY_RUN=1 GAP_LOOP_STATE_DIR="$state_dir" \
  GAP_LOOP_TALLY_BIN="$tally" GAP_LOOP_GH="$scratch/bin/gh" \
  GAP_LOOP_SYSTEMCTL="$scratch/bin/systemctl" \
  PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh" \
  SEAT_CAPS_JSON="$res_caps2/seat-caps.json" \
  PI_MODELS_JSON="$res_caps2/models.json" \
  PI_SEAT_HEALTH_LEDGER_DIR="$res_seat_state2" \
  PI_SEAT_HEALTH_FILE="$res_caps2/global-seat-health.json" \
  PI_PACKET_STATE="$res_caps2/pp" SEAT_LOG_FILE="$res_caps2/pp/watch.log" \
  "$conf"
[[ -f "$state_dir/conferences/$res_conf4/verdict.json" ]] \
  || fail "resolve conference must complete in dry-run"
gj4="$state_dir/pi-audit-jobs/${res_conf4}-r1-glm-5-2/job.json"
[[ -f "$gj4" ]] || fail "conference must write a glm-5-2 job: $gj4"
[[ "$(jq -r '.provider' "$gj4")" == "devin" && "$(jq -r '.model' "$gj4")" == "glm-5-2" ]] \
  || fail "glm-5-2 must keep the live devin/glm-5-2 seat when healthy, got $(jq -c '{provider,model}' "$gj4")"
ok "glm-5-2 resolves to live devin/glm-5-2 when healthy (common case unchanged)"

# Scenario B: devin/glm-5-2 quota-benched (the cycle-4 wall) but
# devin/swe-1-7 wired + healthy -> glm-5-2 lands on the other devin seat.
cat >"$res_seat_state2/devin__glm-5-2.json" <<EOF
{"provider":"devin","model":"glm-5-2","health_class":"quota_bench","seat_dead":false,"observed_at":"$NOW2","bench_until":"$FUTURE2","source":"test"}
EOF
cat >"$res_seat_state2/devin__swe-1-7.json" <<EOF
{"provider":"devin","model":"swe-1-7","health_class":"healthy","seat_dead":false,"observed_at":"$NOW2","source":"test"}
EOF
res_conf5="resolve-conf-2b"
mkdir -p "$state_dir/conferences/$res_conf5"
printf 'termination\n' >"$state_dir/conferences/$res_conf5/mode"
printf '{"cycle":1}\n' >"$state_dir/state.json"
GAP_LOOP_CONF_ID="$res_conf5" GAP_LOOP_DRY_RUN=1 GAP_LOOP_STATE_DIR="$state_dir" \
  GAP_LOOP_TALLY_BIN="$tally" GAP_LOOP_GH="$scratch/bin/gh" \
  GAP_LOOP_SYSTEMCTL="$scratch/bin/systemctl" \
  PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh" \
  SEAT_CAPS_JSON="$res_caps2/seat-caps.json" \
  PI_MODELS_JSON="$res_caps2/models.json" \
  PI_SEAT_HEALTH_LEDGER_DIR="$res_seat_state2" \
  PI_SEAT_HEALTH_FILE="$res_caps2/global-seat-health.json" \
  PI_PACKET_STATE="$res_caps2/pp" SEAT_LOG_FILE="$res_caps2/pp/watch.log" \
  "$conf"
gj5="$state_dir/pi-audit-jobs/${res_conf5}-r1-glm-5-2/job.json"
[[ -f "$gj5" ]] || fail "conference must write a glm-5-2 job: $gj5"
[[ "$(jq -r '.provider' "$gj5")" == "devin" && "$(jq -r '.model' "$gj5")" == "swe-1-7" ]] \
  || fail "glm-5-2 must fall over to the live devin/swe-1-7 when glm-5-2 is benched, got $(jq -c '{provider,model}' "$gj5")"
ok "glm-5-2 falls over to live devin/swe-1-7 when glm-5-2 is quota-benched"

# Scenario C: the whole devin ladder unusable, but a capable seat is live ->
# glm-5-2 falls back to the first usable capable seat (pi-audit-run
# resolve_free_role shape), so the loop can converge while the devin lane is
# down.
cat >"$res_caps2/seat-caps.json" <<'CAPS'
{"providers":{"cursor":{"cap":2,"class":"capable","models":{"cursor-grok-4.6-high":{"cap":1,"class":"capable"}}},"devin":{"cap":2,"class":"prepaid-quota","models":{"glm-5-2":{"cap":1},"swe-1-7":{"cap":1}}}},"senior_seats_in_order":[]}
CAPS
cat >"$res_caps2/models.json" <<'MODELS'
{"providers":{"cursor":{"models":[{"id":"cursor-grok-4.6-high","reasoning":true}]},"devin":{"models":[{"id":"glm-5-2"},{"id":"swe-1-7"}]}}}
MODELS
cat >"$res_seat_state2/devin__glm-5-2.json" <<EOF
{"provider":"devin","model":"glm-5-2","health_class":"healthy","seat_dead":true,"observed_at":"$NOW2","source":"test"}
EOF
cat >"$res_seat_state2/devin__swe-1-7.json" <<EOF
{"provider":"devin","model":"swe-1-7","health_class":"healthy","seat_dead":true,"observed_at":"$NOW2","source":"test"}
EOF
cat >"$res_seat_state2/cursor__cursor-grok-4.6-high.json" <<EOF
{"provider":"cursor","model":"cursor-grok-4.6-high","health_class":"healthy","seat_dead":false,"observed_at":"$NOW2","source":"test"}
EOF
res_conf6="resolve-conf-2c"
mkdir -p "$state_dir/conferences/$res_conf6"
printf 'termination\n' >"$state_dir/conferences/$res_conf6/mode"
printf '{"cycle":1}\n' >"$state_dir/state.json"
GAP_LOOP_CONF_ID="$res_conf6" GAP_LOOP_DRY_RUN=1 GAP_LOOP_STATE_DIR="$state_dir" \
  GAP_LOOP_TALLY_BIN="$tally" GAP_LOOP_GH="$scratch/bin/gh" \
  GAP_LOOP_SYSTEMCTL="$scratch/bin/systemctl" \
  PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh" \
  SEAT_CAPS_JSON="$res_caps2/seat-caps.json" \
  PI_MODELS_JSON="$res_caps2/models.json" \
  PI_SEAT_HEALTH_LEDGER_DIR="$res_seat_state2" \
  PI_SEAT_HEALTH_FILE="$res_caps2/global-seat-health.json" \
  PI_PACKET_STATE="$res_caps2/pp" SEAT_LOG_FILE="$res_caps2/pp/watch.log" \
  "$conf"
gj6="$state_dir/pi-audit-jobs/${res_conf6}-r1-glm-5-2/job.json"
[[ -f "$gj6" ]] || fail "conference must write a glm-5-2 job: $gj6"
[[ "$(jq -r '.provider' "$gj6")" == "cursor" && "$(jq -r '.model' "$gj6")" == "cursor-grok-4.6-high" ]] \
  || fail "glm-5-2 must fall back to a usable capable seat when the devin ladder is down, got $(jq -c '{provider,model}' "$gj6")"
ok "glm-5-2 falls back to usable capable seat when the devin ladder is down"

# Scenario D: devin ladder down and no other seat usable -> glm-5-2 keeps
# the ladder slug devin/glm-5-2 so the auditor preflight refusal (and the
# dissent) still surface the wall honestly.
cat >"$res_seat_state2/cursor__cursor-grok-4.6-high.json" <<EOF
{"provider":"cursor","model":"cursor-grok-4.6-high","health_class":"healthy","seat_dead":true,"observed_at":"$NOW2","source":"test"}
EOF
res_conf7="resolve-conf-2d"
mkdir -p "$state_dir/conferences/$res_conf7"
printf 'termination\n' >"$state_dir/conferences/$res_conf7/mode"
printf '{"cycle":1}\n' >"$state_dir/state.json"
GAP_LOOP_CONF_ID="$res_conf7" GAP_LOOP_DRY_RUN=1 GAP_LOOP_STATE_DIR="$state_dir" \
  GAP_LOOP_TALLY_BIN="$tally" GAP_LOOP_GH="$scratch/bin/gh" \
  GAP_LOOP_SYSTEMCTL="$scratch/bin/systemctl" \
  PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh" \
  SEAT_CAPS_JSON="$res_caps2/seat-caps.json" \
  PI_MODELS_JSON="$res_caps2/models.json" \
  PI_SEAT_HEALTH_LEDGER_DIR="$res_seat_state2" \
  PI_SEAT_HEALTH_FILE="$res_caps2/global-seat-health.json" \
  PI_PACKET_STATE="$res_caps2/pp" SEAT_LOG_FILE="$res_caps2/pp/watch.log" \
  "$conf" 2>"$res_caps2/conf-d.log"
gj7="$state_dir/pi-audit-jobs/${res_conf7}-r1-glm-5-2/job.json"
[[ -f "$gj7" ]] || fail "conference must write a glm-5-2 job: $gj7"
[[ "$(jq -r '.provider' "$gj7")" == "devin" && "$(jq -r '.model' "$gj7")" == "glm-5-2" ]] \
  || fail "glm-5-2 must keep the ladder slug when nothing is usable, got $(jq -c '{provider,model}' "$gj7")"
grep -q "no usable devin seat" "$res_caps2/conf-d.log" \
  || fail "conference must log the ladder-slug fallback, got: $(cat "$res_caps2/conf-d.log")"
ok "glm-5-2 keeps ladder slug when no seat is usable (preflight surfaces wall)"

echo "OK: fleet-ops#180 gap-closure loop acceptance (stubbed) pass"
