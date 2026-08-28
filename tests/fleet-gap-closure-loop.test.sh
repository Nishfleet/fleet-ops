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
case "$*" in
  *"issue list"*gap-audit*"--state open"*)
    jq 'length' "${GAPS_JSON}" 2>/dev/null || echo 0
    ;;
  *"issue list"*gap-audit*"--state closed"*)
    echo 0
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
export GAP_LOOP_STATE_DIR="$state_dir"
export GAP_LOOP_PRECEDENCE_FILE="$prec"
export GAP_LOOP_GH="$scratch/bin/gh"
export GAP_LOOP_SYSTEMCTL="$scratch/bin/systemctl"
export GAP_LOOP_DRY_RUN=1
export GAP_LOOP_FAKE_NOW="2026-08-26T16:00:00Z"
export GAP_LOOP_SLO_BIN="$slo"
export GAP_LOOP_DISABLE=0
export GAP_LOOP_REPO="Nishfleet/fleet-ops"

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
# Jump to measure of a clean cycle.
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
  "updated_at": "2026-08-26T16:00:00Z"
}
JSON
printf '{"all_pass":true,"results":[{"name":"x","pass":true}]}\n' >"$state_dir/drill-results.json"
printf '[]\n' >"$gaps_file"
tick
[[ "$(phase)" == "conference" ]] || fail "clean+green+drills must convene conference, got $(phase)"
ok "clean cycle + green SLOs -> conference convened"

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

echo "OK: fleet-ops#180 gap-closure loop acceptance (stubbed) pass"
