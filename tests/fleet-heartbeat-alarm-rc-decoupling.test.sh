#!/usr/bin/env bash
# tests/fleet-heartbeat-alarm-rc-decoupling.test.sh
#
# fleet-ops#1116: fleet-heartbeat.service lands in --state=failed every 15
# min because bin/fleet-heartbeat-tier1 propagates the alarm channel rc
# (=1) of seven detectors to the unit. The detector already raised the
# alarm (LOUD [X] log + auto-file + observe-to-close drain); the unit
# failure is redundant. This test pins the alarm-vs-failure separation:
#
# Class lock (fleet-ops#366 — every fix ships its mechanism):
#   A. A tier-1 stub detector that exits 1 (alarm path) MUST NOT make
#      bin/fleet-heartbeat-tier1 exit 1. The loud log line IS the alarm;
#      tier 1 exits 0; the wrapper exits 0.
#   B. A tier-1 stub detector that exits 7 (crashed) MUST make tier 1
#      exit 7 — propagated rc; unit goes red (real fault, must surface).
#   C. The seven detector integration points (deploy-check, red-pr-repair,
#      escalation-canary, decisions-ledger, failed-command-flagged,
#      unjustified-wait, findings-queued) MUST be enumerated by a regression
#      test that runs each stub and asserts the right tier-1 exit per stub.
#      This is the shape-lock.
#   D. The existing bin/fleet-heartbeat-rc-propagation.test.sh (tier 1 /
#      tier 2 stub shape) MUST stay green; this new test MUST be nested
#      under tests/seat-lib.test.sh (workers cannot add a ci.yml line).
#
# Test approach (no live tier1 invocation):
#
#   1. Source the actual propagation block of bin/fleet-heartbeat-tier1
#      (the section between the `tier 1 complete: ...` log line and
#      `exit 0`) into a small test harness.
#   2. Pre-set the rc variables to the scenario values (0/1/7).
#   3. Run the sourced block. The block's `exit "$rc"` propagates.
#
# Why this approach (not running live tier1):
#   Live tier1 takes ~30-60s per invocation because of blocks 2/3/3b/4/
#   4b/5/6/6b (queue pass, blocked-reconcile, audit panel, lifecycle
#   sweep) that hit live GitHub. 4 invocations × 30s = 2 min, plus
#   rate-limit backoff = >5 min, exceeding the CI verify-command
#   budget. Sourcing the propagation block directly tests the SHAPE
#   (the class lock) without coupling to live GitHub state. The
#   existing bin/fleet-heartbeat-rc-propagation.test.sh follows the
#   same pattern (sources the wrapper, not the live tier1) for the
#   same reason.
#
# Scenarios (per the packet's acceptance #3, 4 OK scenarios):
#   1. alarm-stub: every alarm detector returns rc=1. Tier 1 must
#      exit 0 — the alarm is the loud log, not the unit failure.
#   2. crash-stub: every alarm detector returns rc=7. Tier 1 must
#      exit 7 — a real crash must surface.
#   3. both-stubs: one alarm detector returns rc=7, one returns rc=1,
#      the rest at rc=0. Tier 1 must exit 7 — the crash wins, the
#      alarm is fine.
#   4. all-cans-pass: every detector returns rc=0. Tier 1 exits 0
#      (regression baseline).
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

# --- Step 1: extract the propagation block from tier1 ----------------------
# The propagation block lives between the `tier 1 complete: ...` log
# line and the final `exit 0`. We slice it out with awk so the test
# runs against the SAME bytes the live script runs against (no
# divergence between the harness and the production).
#
# Markers (the live tier1 has these as anchors):
#   START: the line `log "tier 1 complete:`
#   END:   the line `exit 0` (the final one — at the very end of the
#          script). The propagation block ends with `exit 0`.
#
# Implementation: from the start marker to end of file, extract every
# line starting with `if [ "${` or `if [ "$` (the rc-propagation
# guards) AND every `exit "$..._rc"` AND every `exit "${..._rc}"`.
# The block structure is a series of `if [ ... -ge 2 ]; then exit; fi`
# (after the patch), so extracting just these lines reproduces the
# propagation logic in isolation.
prop_block="$here/.tmp-prop-block-$$.sh"
trap 'rm -f "$prop_block"' EXIT INT TERM

python3 - "$tier1" "$prop_block" <<'PY'
"""Extract the rc-propagation block from bin/fleet-heartbeat-tier1.

We capture the final `tier 1 complete: ...` log line as the start
anchor, then everything from that line to EOF. The result is the
propagation block: the rc-propagation guards, the final `exit 0`,
and the per-detector rc log line. Sourcing this block with pre-set
rc variables runs ONLY the propagation logic.
"""
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
text = src.read_text(encoding="utf-8").splitlines(keepends=True)

# Find the start anchor: a line that begins with `log "tier 1 complete:`
start = None
for i, line in enumerate(text):
    if line.lstrip().startswith('log "tier 1 complete:'):
        start = i
        break
if start is None:
    print(f"could not find 'tier 1 complete:' anchor in {src}", file=sys.stderr)
    sys.exit(1)

# Everything from the start anchor to EOF is the propagation block.
propagation = "".join(text[start:])

# Pre-declare all rc vars to 0 so the sourced block has consistent
# defaults if the caller forgot to set any of them. The block
# references each as `${X_rc:-0}` so the caller's env wins.
#
# Why we do NOT pre-declare here: a script-level `X=0` assignment would
# SHADOW the env var that the caller passes (`env deploy_rc=7 bash
# block.sh` sets deploy_rc=7 in the script's environment, but a
# script-local `deploy_rc=0` line overrides it). The block uses
# `${X_rc:-0}` for every propagation guard it needs to read, and
# `[ "$X_rc" -ne 0 ]` (no `:-0`) for the helpers whose contract is
# "always set by the script" — with `set -u` off, the latter expand
# to empty + integer-compare-error, which `if` treats as false. That
# is exactly the shape we want to test (the propagation chain).
#
# Note: we deliberately do NOT enable `set -u` here. The propagation
# block's `tier 1 complete: ...` log line references non-rc counters
# (queued, released, seen, ...) that live in the upper tiers of the
# script. Pre-declaring every counter would be brittle (the log line
# changes as new canaries land) and adds no class-lock value. Dropping
# `-u` lets bash expand unset names to empty strings, which is exactly
# what we want for a propagation-shape test.
prefix = """#!/usr/bin/env bash
# Extracted propagation block from bin/fleet-heartbeat-tier1.
# Caller-supplied env vars (deploy_rc=7 etc.) drive the propagation.
set -eo pipefail
# Pass log() through to stdout so the scenario 4 baseline can assert
# that the `tier 1 complete: ...` line is reached (i.e., the propagation
# block made it past every rc guard without early-exiting).
log() { printf '%s\n' "$*"; }
# Default the three rc vars that the production script reads WITHOUT a
# ${X_rc:-0} default. The `:="${var:=0}"` form leaves any caller-supplied
# env value intact (it only assigns when the var is unset/empty), so the
# harness can still drive scenarios by exporting deploy_rc=7 etc.
: "${undersat_rc:=0}"
: "${low_water_rc:=0}"
: "${entitled_canary_rc:=0}"
"""

# Append the propagation block itself.
dst.write_text(prefix + propagation, encoding="utf-8")
PY

[[ -s "$prop_block" ]] || fail "failed to extract propagation block from $tier1"

# --- Step 2: source the propagation block in each scenario ----------------
# We `bash` the extracted block (not `source`) so each scenario is
# isolated and the exit code is captured by the wrapper.

run_scenario() {
    # $1 = scenario name
    # $@ = NAME=VALUE env-var assignments to override the rc defaults
    local name="$1"
    shift
    local extra_env=("$@")
    # Note: `$rc` and `$out` are intentionally NOT local. The caller
    # reads them after run_scenario returns to assert the propagated
    # exit. `set -u` would catch an unbound read; we keep `set -u` on
    # in the outer test, so the caller is required to set `rc=0` (or
    # some sentinel) before the first scenario runs.
    set +e
    out="$(env -i PATH="/usr/bin:/bin" "${extra_env[@]}" bash "$prop_block" 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$out" | tail -5 >&2
    printf 'scenario %s: rc=%s\n' "$name" "$rc"
}

# Note on why each scenario goes through run_scenario: the propagation
# block is expected to exit non-zero in scenarios 2 and 3 (rc=7 crash
# propagation). With the outer `set -e`, a direct `out="$(...)"` capture
# would propagate that exit code and terminate the test harness before
# the assertion runs. run_scenario wraps the capture with `set +e` /
# `set -e` so the harness survives the propagation's expected crash and
# the assertion sees the real rc.

# --- scenario 1: alarm-stub (rc=1) on every alarm detector -> exits 0 ------
run_scenario 1 \
    deploy_rc=1 redpr_rc=1 canary_rc=1 \
    decisions_ledger_rc=1 failed_command_rc=1 unjustified_rc=1 findings_queued_rc=1
if [ "$rc" -ne 0 ]; then
    fail "scenario 1: alarm-stub (rc=1) on every alarm detector made propagation exit $rc — alarm-vs-failure separation broken. output: $out"
fi
ok "scenario 1: alarm-stub (rc=1) on alarm detectors -> propagation exits 0 (alarm-vs-failure separation)"

# --- scenario 2: crash-stub (rc=7) on every alarm detector -> exits 7 ------
run_scenario 2 \
    deploy_rc=7 redpr_rc=7 canary_rc=7 \
    decisions_ledger_rc=7 failed_command_rc=7 unjustified_rc=7 findings_queued_rc=7
if [ "$rc" -ne 7 ]; then
    fail "scenario 2: crash-stub (rc=7) on every alarm detector made propagation exit $rc — real crashes must surface. output: $out"
fi
ok "scenario 2: crash-stub (rc=7) on alarm detectors -> propagation exits 7 (real crash surfaces)"

# --- scenario 3: both-stubs (one alarm detector rc=7, one rc=1) -> exits 7 -
# redpr at rc=7 (crash), decisions_ledger at rc=1 (alarm), the rest at
# rc=0. The first rc=7 encountered in the propagation chain (deploy is
# 0, so we skip to redpr=7) triggers the exit. Tier 1's chain order:
#   deploy (rc=0) -> blocked (rc=0) -> ... -> redpr (rc=7) -> exit 7.
run_scenario 3 redpr_rc=7 decisions_ledger_rc=1
if [ "$rc" -ne 7 ]; then
    fail "scenario 3: mixed (redpr=7 + decisions_ledger=1) made propagation exit $rc — crash must win over alarm. output: $out"
fi
ok "scenario 3: both-stubs (alarm=1 + crash=7) -> propagation exits 7 (crash wins)"

# --- scenario 4: all-cans-pass (rc=0) -> exits 0 (regression) --------------
run_scenario 4
if [ "$rc" -ne 0 ]; then
    fail "scenario 4: all-cans-pass baseline failed: propagation exited $rc. output: $out"
fi
printf '%s\n' "$out" | grep -qE "tier 1 complete:" \
    || fail "scenario 4: all-cans-pass did not log 'tier 1 complete:' line. output: $out"
ok "scenario 4: all-cans-pass baseline: propagation exits 0, logs 'tier 1 complete:'"

# --- source gate (D): the seven rc-propagation guards MUST be -ge 2 ----------
# The class lock says the seven integration points MUST only propagate rc
# when the helper CRASHED (rc >= 2). This is the shape-lock. We grep
# the source for the seven -ge 2 lines and assert they are present, and
# we grep the rest of the file to ensure the OLD `-ne 0` shape is not
# reintroduced for those seven vars.
declare -a D_VARS=(deploy_rc redpr_rc canary_rc decisions_ledger_rc failed_command_rc unjustified_rc findings_queued_rc)
D_PASS=0
D_TOTAL=0
for v in "${D_VARS[@]}"; do
    D_TOTAL=$((D_TOTAL + 1))
    # The -ge 2 line for $v must exist
    if ! grep -qE "if \\[ \"?\\\${?${v}:?-?0?\\}?:?0?\"? -ge 2 \\]; then" "$tier1"; then
        fail "source gate: $v does not have a -ge 2 rc-propagation guard. The alarm-vs-failure separation is missing for this detector."
    fi
    D_PASS=$((D_PASS + 1))
    # And the OLD `-ne 0` shape for $v must NOT exist (would mean we
    # added -ge 2 but forgot to remove -ne 0 — both fire and the unit
    # still fails on rc=1)
    if grep -nE "if \\[ \"?\\\${?${v}:?-?0?\\}?:?0?\"? -ne 0 \\]; then" "$tier1" | grep -q .; then
        fail "source gate: $v still has a -ne 0 rc-propagation guard — alarm-vs-failure separation is leaking. The shape-lock requires ONLY -ge 2 for these seven."
    fi
done
ok "source gate: $D_PASS/$D_TOTAL detector rc-propagation guards are -ge 2 (no -ne 0 leak)"

# Nested CI host (workers cannot add a ci.yml line).
grep -Fq 'bash "$here/fleet-heartbeat-alarm-rc-decoupling.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "nested under seat-lib.test.sh"

echo "ALL OK"
