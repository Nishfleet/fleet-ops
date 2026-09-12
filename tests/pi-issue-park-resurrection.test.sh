#!/usr/bin/env bash
# tests/pi-issue-park-resurrection.test.sh
#
# fleet-ops#5092: an issue parked with awaiting-runtime-gate never regains
# agent-ready via the failed-unit reaper, and a unit claimed BEFORE the park
# does not restart-loop after the park lands (pi-issue-run exits 0 on the
# parked label so Restart=on-failure never schedules a restart).
#
# 0509#2213 live chain (2026-09-10/11): claim 19:14:57Z -> park 20:00:39Z ->
# worker exit 1 (debug-playbook gate) -> Restart=on-failure ladder burns
# StartLimitBurst=3 -> OnFailure reaper re-adds agent-ready at 20:04:41Z,
# silently un-parking. Two assertions kill both links:
#   1. reaper fail-closed on the live label set (agent-ready NOT re-added)
#   2. pi-issue-run exits 0 on a parked issue (no failure -> no restart)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t pi-issue-park-resurrection.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export GH_TOKEN="${GH_TOKEN:-fake-test-token-aaaaaaaaaaaaaaaa}"

fake="$scratch/fake"
mkdir -p "$fake"

# --- fake systemctl: worker not live; records stop / reset-failed -----------
cat >"$fake/systemctl" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
while [[ $# -gt 0 ]]; do
  case "$1" in
    show)
      prop=""; shift
      while [[ $# -gt 0 ]]; do
        case "$1" in -p) prop="$2"; shift 2 ;; --value) shift ;; *) shift ;; esac
      done
      case "$prop" in ActiveState) echo inactive ;; MainPID) echo 0 ;; *) echo "" ;; esac
      exit 0 ;;
    stop|reset-failed)
      echo "$1" >>"${FAKE_SYSTEMCTL_LOG:?}"; exit 0 ;;
    *) exit 0 ;;
  esac
done
FAKE
chmod +x "$fake/systemctl"
systemctl_log="$scratch/systemctl.log"
: >"$systemctl_log"
export FAKE_SYSTEMCTL_LOG="$systemctl_log"

triage="$scratch/triage.md"
state_dir="$scratch/pstate"
issues_dir="$scratch/issues"
mkdir -p "$state_dir/attempts" "$issues_dir"
printf 'TARGET: repo Nishfleet/5092 issue 2213 unit test-unit\n' >"$issues_dir/5092-2213.in"
printf 'stub out\n' >"$issues_dir/5092-2213.out"
printf 'stub err\n' >"$issues_dir/5092-2213.err"

# ======================================================================
# Part 1 — reaper fail-closed (bin/pi-issue-failed-reap)
# ======================================================================
bin_pr="$repo_root/bin/pi-issue-failed-reap"
[[ -x "$bin_pr" ]] || fail "reaper is not executable: $bin_pr"

# fake gh: routes the reaper's REST calls; records mutating calls.
gh_log="$scratch/gh.log"
gh_edit_log="$scratch/gh.log.edit"
cat >"$fake/gh" <<FAKE
#!/usr/bin/env bash
echo "\$*" >>"$gh_log"
if [[ "\$1" == "api" ]]; then
  case "\$2" in
    */issues/2213) printf '%s' "\$PARK_STATE_JSON"; exit 0 ;;
    */pulls*) echo "[]"; exit 0 ;;
    */git/refs/heads/*)
      for a in "\$@"; do
        if [[ "\$a" == "DELETE" ]]; then echo "{}"; exit 0; fi
      done
      echo '{"ref":"refs/heads/claim/issue-2213"}'; exit 0 ;;
    *) echo "{}"; exit 0 ;;
  esac
fi
if [[ "\$1" == "issue" && "\$2" == "edit" ]]; then
  echo "\$*" >>"$gh_log.edit"
  echo "https://github.com/Nishfleet/5092/issues/2213#issuecomment-1"; exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "comment" ]]; then
  echo "https://github.com/Nishfleet/5092/issues/2213#issuecomment-1"; exit 0
fi
echo "unexpected gh call: \$*" >&2
exit 1
FAKE
chmod +x "$fake/gh"

# Parked issue: awaiting-runtime-gate still present, agent-in-progress stale.
export PARK_STATE_JSON='{"state":"open","labels":[{"name":"agent-in-progress"},{"name":"awaiting-runtime-gate"},{"name":"priority:normal"}]}'

set +e
SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_dir" PI_ISSUES_DIR="$issues_dir" \
    PATH="$fake:$PATH" \
    "$bin_pr" 5092-2213 2>"$scratch/reap.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "reaper should exit 0 on the parked path, got $rc (err=$(cat "$scratch/reap.err"))"

[[ -f "$gh_log" ]] || fail "reaper must call gh (log missing)"
grep -q -- '--remove-label agent-in-progress' "$gh_log" \
    || fail "reaper must clear agent-in-progress: $(cat "$gh_log")"
grep -q -- '--add-label agent-ready' "$gh_log" \
    && fail "reaper re-added agent-ready on a PARKED issue — resurrection hole back (fleet-ops#5092)"
grep -q -- '--add-label' "$gh_log" \
    && fail "reaper added some label on the parked path: $(cat "$gh_log")"
[[ "$(grep -c -- 'remove-label' "$gh_log")" -eq 1 ]] \
    || fail "expected exactly one label edit, got: $(cat "$gh_log")"
grep -q 'parked (awaiting-runtime-gate)' "$scratch/reap.err" \
    || fail "reaper must log the parked fail-closed reason: $(cat "$scratch/reap.err")"
ok "reaper fail-closed: agent-ready NOT re-added on a parked (awaiting-runtime-gate) issue"

# The unit must have been stopped and packets archived — the restart ladder
# must not fire a 208/STDIN restart on the stale .in packet after the reap.
grep -q '^stop$' "$systemctl_log" || fail "reaper must stop the unit to cancel the pending restart ladder"
[[ -f "$issues_dir/5092-2213.in" ]] && fail "the .in packet must be archived (stale packet = restart life support)"
ls "$issues_dir" | grep -q '^ARCHIVED-5092-2213.in' \
    || fail "archived .in packet missing: $(ls "$issues_dir")"
ok "reaper cancels the restart ladder and archives the parked unit's packets"

# --- control: unparked issue still gets agent-ready (recover path intact) ----
: >"$systemctl_log"
: >"$gh_log"
rm -f "$issues_dir"/ARCHIVED-*
printf 'packet\n' >"$issues_dir/5092-2213.in"
export PARK_STATE_JSON='{"state":"open","labels":[{"name":"agent-in-progress"}]}'
set +e
SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_dir" PI_ISSUES_DIR="$issues_dir" \
    PATH="$fake:$PATH" \
    "$bin_pr" 5092-2213 2>"$scratch/reap2.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "unparked control must behave as before (rc=$rc)"
grep -q -- '--add-label agent-ready' "$gh_log" \
    || fail "unparked control: agent-ready re-add must still exist (recover path regressed): $(cat "$gh_log")"
ok "unparked control: recover path intact (agent-ready re-added)"

# ======================================================================
# Part 2 — pi-issue-run exits 0 on a parked issue (claimed-before-park)
# ======================================================================
export HOME="$scratch/home"
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"

run_state="$scratch/run-state"
run_issues="$scratch/run-issues"
mkdir -p "$run_state/attempts" "$run_issues"
export PI_PACKET_STATE="$run_state"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
export PI_ISSUES_DIR="$run_issues"
export PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_MODELS_JSON="$scratch/models.json"

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": [],
  "providers": {
    "devin": {
      "cap": 4,
      "class": "subscription",
      "models": { "swe-1-7": 4 }
    }
  }
}
JSON
cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [
        { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

WORKER_TOKEN_BIN="$scratch/worker-token"
export WORKER_TOKEN_BIN
# worker-token stub: in production pi-issue-run mints AFTER the parked check,
# so the parked path must never reach this.
cat >"$WORKER_TOKEN_BIN" <<'STUB'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
STUB
chmod +x "$WORKER_TOKEN_BIN"
export WORKER_TOKEN_BIN

stub_bin="$scratch/stub"
mkdir -p "$stub_bin"

# gh stub: `gh api .../issues/<n>` returns $PARK_STATE_JSON (fail-open if absent).
cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
  for a in "$@"; do
    case "$a" in *"/issues/"*) printf '%s' "${PARK_STATE_JSON:-{\"labels\":\[\]}}"; exit 0 ;; esac
  done
fi
echo "unexpected gh call: $*" >&2
exit 1
STUB
chmod +x "$stub_bin/gh"

# pi stub that fails hard — the parked exit must happen BEFORE any seat/work.
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
echo "invoked" >>"${PI_STUB_LOG:?}"
exit 42
STUB
chmod +x "$stub_bin/pi"
export PI_BIN="$stub_bin/pi"
pi_stub_log="$scratch/pi-stub.log"
: >"$pi_stub_log"
export PI_STUB_LOG="$pi_stub_log"

cat >"$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/systemctl"

export PATH="$stub_bin:$repo_root/bin:/usr/local/bin:/usr/bin:/bin"

pkt="$run_issues/fleet-ops-5092.in"
cat >"$pkt" <<'EOF'
TARGET: repo Nishfleet/fleet-ops issue 5092 unit park-resurrection-test
EOF

# --- parked: exit 0, pi never invoked (exit 0 == no Restart=on-failure) -----
export PARK_STATE_JSON='{"labels":[{"name":"awaiting-runtime-gate"}]}'
rm -f "$run_issues/fleet-ops-5092.out" "$run_issues/fleet-ops-5092.err" "$run_state/attempts/pi-issue-fleet-ops-5092.tried-seats"
set +e
"$repo_root/bin/pi-issue-run" fleet-ops-5092 >"$scratch/run.out" 2>"$scratch/run.err"
pr_rc=$?
set -e
[[ "$pr_rc" -eq 0 ]] || fail "parked issue must exit 0 (rc=$pr_rc); err=$(cat "$scratch/run.err")"
grep -q 'parked with awaiting-runtime-gate' "$scratch/run.err" \
    || fail "must log the park no-op exit: $(cat "$scratch/run.err")"
grep -q 'invoked' "$PI_STUB_LOG" \
    && fail "the worker (pi) must NOT be spawned on a parked issue"
ok "pi-issue-run exits 0 on a parked issue — claimed-before-park does not restart-loop"

# --- unparked control: the run proceeds into the real worker path ------------
export PARK_STATE_JSON='{"labels":[{"name":"agent-in-progress"}]}'
rm -f "$run_issues/fleet-ops-5092.out" "$run_issues/fleet-ops-5092.err"
set +e
"$repo_root/bin/pi-issue-run" fleet-ops-5092 >"$scratch/run2.out" 2>"$scratch/run2.err"
un_rc=$?
set -e
[[ "$un_rc" -ne 0 ]] \
    || fail "unparked control must NOT exit 0 — the park check is stuck open (rc=$un_rc)"
grep -q 'parked with awaiting-runtime-gate' "$scratch/run2.err" \
    && fail "unparked issue must not take the park exit: $(cat "$scratch/run2.err")"
grep -q 'invoked' "$PI_STUB_LOG" \
    || fail "unparked control: the worker path must actually proceed (pi stub should run)"
ok "unparked control: run proceeds into the worker path (no park short-circuit)"

echo "OK: pi-issue park-resurrection (fleet-ops#5092)"
