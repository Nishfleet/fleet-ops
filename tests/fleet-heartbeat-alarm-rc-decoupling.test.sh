#!/usr/bin/env bash
# tests/fleet-heartbeat-alarm-rc-decoupling.test.sh
#
# fleet-ops#1116: fleet-heartbeat.service lands in --state=failed every 15
# min because bin/fleet-heartbeat-tier1 propagates the alarm channel rc
# (=1) of six detectors to the unit. The detector already raised the
# alarm (LOUD [X] log + auto-file + observe-to-close drain); the unit
# failure is redundant. This test pins the alarm-vs-failure separation:
#
# Class lock (fleet-ops#366 — every fix ships its mechanism):
#   A. A tier-1 stub detector that exits 1 (alarm path) MUST NOT make
#      bin/fleet-heartbeat-tier1 exit 1. The loud log line IS the alarm;
#      tier 1 exits 0; the wrapper exits 0.
#   B. A tier-1 stub detector that exits 7 (crashed) MUST make tier 1
#      exit 7 — propagated rc; unit goes red (real fault, must surface).
#   C. The six detector integration points (deploy-check, red-pr-repair,
#      escalation-canary, decisions-ledger, failed-command-flagged,
#      unjustified-wait) MUST be enumerated by a regression test that
#      runs each stub and asserts the right tier-1 exit per stub. This
#      is the shape-lock.
#   D. The existing bin/fleet-heartbeat-rc-propagation.test.sh (tier 1 /
#      tier 2 stub shape) MUST stay green; this new test MUST be nested
#      under tests/seat-lib.test.sh (workers cannot add a ci.yml line).
#
# What this test does NOT touch (per the packet's anti-patterns):
#   - The LOUD [X] lines inside the detector integrations (the alarm is
#     correct and must stay loud).
#   - The detector scripts themselves (their exit-1-on-find contract is
#     documented and tested elsewhere).
#   - bin/fleet-heartbeat (the wrapper) — its `if "$TIER1"; then` branch
#     is correct, and the rc-propagation test for tier 1/2 stays.
#   - systemd drop-in to suppress OnFailure= on fleet-heartbeat.service
#     (that hides real crashes like a python import error).
#
# Nested under tests/seat-lib.test.sh because workers cannot add a
# .github/workflows/ci.yml line (standing rule, fleet-ops#1116 class lock
# point D).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$tier1" ]] || fail "tier1 not executable: $tier1"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch="$(mktemp -d -t hb-alarm-rc-decouple.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- stub script factory ----------------------------------------------------
# Every detector integration in tier1 consults an env var of the form
# FLEET_<NAME>_BIN and invokes the path it points at. We set every one
# of those env vars to a stub that exits whatever rc we need.
make_stub() {
    local rc="$1"
    local path="$scratch/stub-exit-$rc"
    printf '#!/usr/bin/sh\nexit %s\n' "$rc" >"$path"
    chmod +x "$path"
    printf '%s' "$path"
}

# --- canonical stub: every detector returns 0 (alarm-channel off) ------------
exit0="$(make_stub 0)"
exit1="$(make_stub 1)"
exit2="$(make_stub 2)"
exit7="$(make_stub 7)"

# The full env-var list (one per detector integration in tier1). Each
# detector has a $BIN path; we override them all so tier1's rc-propagation
# logic only sees the detector we are actually testing.
# NOTE: tier1 also gates on a "canary must be in MANIFEST" check
# (`require_manifest_helper`) for several canaries. We bypass that by
# pointing each at a stub in a scratch dir we control; the [ -x "$BIN" ]
# check passes for stubs, and `require_manifest_helper` only rejects when
# the path is empty or explicitly missing. We set FLEET_OPS_CHECKOUT to
# a non-existent dir so the deploy-check block (block 0) is skipped
# entirely (its `should_run_deploy` guard requires the invocation to
# match the installed heartbeat). That keeps the test focused on the
# six integration blocks we are decoupling.
declare -a DETECTOR_VARS=(
    FLEET_HEARTBEAT_REDPR
    FLEET_FINDINGS_QUEUED
    FLEET_DECISIONS_LEDGER_BIN
    FLEET_FAILED_COMMAND_BIN
    FLEET_UNJUSTIFIED_WAIT
    FLEET_ESCALATION_COMPLETION
    FLEET_ESCALATION_CANARY
    FLEET_ENTITLED_WIRED_CANARY
    FLEET_WORKER_APP_CANARY
    FLEET_OPENCODE_M3_CANARY
    FLEET_PAID_FLASH_CANARY
    FLEET_RAM_MEASURE_BIN
    FLEET_FREE_ROSTER_CANARY
    FLEET_PI_EXTENSIONS_CANARY
    FLEET_CLINE_GLM53_CANARY
    FLEET_REPO_VISIBILITY_CANARY
    FLEET_STRAITLY_CANARY
    FLEET_EXEC_REVIEW_CANARY
    FLEET_WORK_SUPPLY_CANARY
    FLEET_TAILSCALE_ACL_CANARY
    FLEET_VERIFY_HARNESS_CANARY
    FLEET_SEAT_LIVE_VALIDATE
    FLEET_CRED_EXPIRY_CANARY
)

run_tier1() {
    # $1 = detector under test (env var name without FLEET_ prefix
    # because the array already has it), $2 = stub path
    local target_var="$1"
    local target_stub="$2"
    # Start every detector at exit 0, then override the target with
    # $2. This isolates the assertion: only the target detector's rc
    # can possibly propagate.
    local -a env_args=()
    local v
    for v in "${DETECTOR_VARS[@]}"; do
        env_args+=("$v=$exit0")
    done
    env_args+=("$target_var=$target_stub")
    # Block 0 (deploy-check) is gated on $FLEET_OPS_CHECKOUT matching the
    # installed heartbeat. We do NOT set FLEET_OPS_CHECKOUT, so
    # should_run_deploy=0 and block 0 is skipped — that block's rc
    # propagation was already changed to -ge 2 in the same patch, but
    # covering it would require invoking tier1 from its installed path,
    # which the test cannot do safely. The shape-lock covers the other
    # five integration points; the deploy-check change is verified by
    # the all-cans-pass / alarm-stub / crash-stub scenarios below
    # through grep of the diff (see D below).
    env -i \
        PATH="/home/nish/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        HOME="$HOME" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
        "${env_args[@]}" \
        bash "$tier1" 2>&1
}

# --- A. alarm stub (rc=1) does NOT propagate -------------------------------
# For each of the six integration points, point the detector at the
# exit-1 stub and assert tier 1 still exits 0 (the loud log IS the alarm;
# unit stays green).
A_PASS=0
A_TOTAL=0
declare -a A_POINTS=(
    FLEET_HEARTBEAT_REDPR
    FLEET_DECISIONS_LEDGER_BIN
    FLEET_FAILED_COMMAND_BIN
    FLEET_UNJUSTIFIED_WAIT
    FLEET_ESCALATION_CANARY
)
for v in "${A_POINTS[@]}"; do
    A_TOTAL=$((A_TOTAL + 1))
    set +e
    out="$(run_tier1 "$v" "$exit1")"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        fail "A: $v alarm-stub (rc=1) made tier 1 exit $rc — alarm-vs-failure separation broken. output: $out"
    fi
    A_PASS=$((A_PASS + 1))
    printf '%s\n' "$out" | grep -qE "FAILED (rc=1)" \
        && fail "A: $v alarm-stub logged FAILED (rc=1) — loud log is the alarm; tier 1 must exit 0, not log FAILED. output: $out"
done
ok "A: alarm-stub (rc=1) on $A_PASS/$A_TOTAL integration points does NOT fail tier 1 (alarm-vs-failure separation)"

# --- B. crash stub (rc=7) DOES propagate ----------------------------------
# For the same six integration points, point the detector at the exit-7
# stub and assert tier 1 exits 7 (a real crash must surface).
B_PASS=0
B_TOTAL=0
for v in "${A_POINTS[@]}"; do
    B_TOTAL=$((B_TOTAL + 1))
    set +e
    out="$(run_tier1 "$v" "$exit7")"
    rc=$?
    set -e
    if [ "$rc" -ne 7 ]; then
        fail "B: $v crash-stub (rc=7) made tier 1 exit $rc — real crashes must surface. output: $out"
    fi
    B_PASS=$((B_PASS + 1))
done
ok "B: crash-stub (rc=7) on $B_PASS/$B_TOTAL integration points DOES fail tier 1 (rc=7 propagated)"

# --- C. all-cans-pass baseline (rc=0) stays green --------------------------
# When every detector exits 0, tier 1 exits 0. This is the regression
# baseline: nothing else changed.
set +e
out="$(run_tier1 FLEET_HEARTBEAT_REDPR "$exit0")"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    fail "C: all-cans-pass baseline failed: tier 1 exited $rc. output: $out"
fi
printf '%s\n' "$out" | grep -qE "tier 1 complete:" \
    || fail "C: all-cans-pass did not log 'tier 1 complete:' line. output: $out"
ok "C: all-cans-pass baseline: tier 1 exits 0, logs 'tier 1 complete:'"

# --- D. source gate: every detector's rc propagation uses -ge 2 ------------
# The class lock says the six integration points MUST only propagate rc
# when the helper CRASHED (rc >= 2). This is the shape-lock. We grep
# the source for the six -ge 2 lines and assert they are present, and
# we grep the rest of the file to ensure the OLD `-ne 0` shape is not
# reintroduced for those six vars.
declare -a D_VARS=(deploy_rc redpr_rc canary_rc decisions_ledger_rc failed_command_rc unjustified_rc)
D_PASS=0
D_TOTAL=0
for v in "${D_VARS[@]}"; do
    D_TOTAL=$((D_TOTAL + 1))
    # The -ge 2 line for $v must exist
    if ! grep -qE "if \\[ \"?\\\${?${v}:?-?0?\\}?:?0?\"? -ge 2 \\]; then" "$tier1"; then
        fail "D: $v does not have a -ge 2 rc-propagation guard. The alarm-vs-failure separation is missing for this detector."
    fi
    D_PASS=$((D_PASS + 1))
    # And the OLD `-ne 0` shape for $v must NOT exist (would mean we
    # added -ge 2 but forgot to remove -ne 0 — both fire and the unit
    # still fails on rc=1)
    if grep -nE "if \\[ \"?\\\${?${v}:?-?0?\\}?:?0?\"? -ne 0 \\]; then" "$tier1" | grep -q .; then
        fail "D: $v still has a -ne 0 rc-propagation guard — alarm-vs-failure separation is leaking. The shape-lock requires ONLY -ge 2 for these six."
    fi
done
ok "D: source gate: $D_PASS/$D_TOTAL detector rc-propagation guards are -ge 2 (no -ne 0 leak)"

# Nested CI host (workers cannot add a ci.yml line).
grep -Fq 'bash "$here/fleet-heartbeat-alarm-rc-decoupling.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "nested under seat-lib.test.sh"

echo "ALL OK"
