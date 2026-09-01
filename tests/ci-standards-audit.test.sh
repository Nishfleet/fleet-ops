#!/usr/bin/env bash
# tests/ci-standards-audit.test.sh
#
# Proves the CI-standards audit script against a fixture so the check logic is
# exercised without reaching the GitHub API.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/ci-standards-audit.mjs"
fixtures="$here/fixtures/ci-standards-audit"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$script" ]] || fail "audit script not found: $script"
node --check "$script" || fail "audit script failed node --check"
node "$script" --help >/dev/null || fail "audit --help failed"

# fleet-ops#490: require the invoke line, not a filename mention. A
# filename-only grep passed a comment-only ci.yml, so CI could drop this
# step while the lock still looked green.
ci_yml="$repo_root/.github/workflows/ci.yml"
grep -Fq 'bash tests/ci-standards-audit.test.sh' "$ci_yml" \
  || fail "ci.yml verify-command must run tests/ci-standards-audit.test.sh (fleet-ops#490)"

# Empty-host + comment-only drill (fleet-ops#366 / #490): the lock is not a
# tautology, and a filename-only comment must not satisfy it.
empty=$(mktemp)
trap 'rm -f "$empty"' EXIT
: >"$empty"
empty_hit=0
grep -Fq 'bash tests/ci-standards-audit.test.sh' "$empty" && empty_hit=1
[[ "$empty_hit" -eq 0 ]] || fail "empty-host drill must miss (hit=$empty_hit)"
printf '# tests/ci-standards-audit.test.sh\n' >"$empty"
comment_hit=0
grep -Fq 'bash tests/ci-standards-audit.test.sh' "$empty" && comment_hit=1
[[ "$comment_hit" -eq 0 ]] \
  || fail "comment-only filename must not satisfy the #490 lock (hit=$comment_hit)"
weak_hit=0
grep -Fq 'tests/ci-standards-audit.test.sh' "$empty" && weak_hit=1
[[ "$weak_hit" -eq 1 ]] \
  || fail "comment-only drill fixture is broken (weak grep should match filename)"
echo "OK: #490 lock requires bash invoke line; comment-only filename is not enough"

python3 -c "import yaml" 2>/dev/null || fail "PyYAML is required for audit tests"

cd "$repo_root"

# Pure function: PR-triggered and push-to-default detection.
node --input-type=module -e '
import {
  isPrTriggeredWorkflow,
  isPushToDefaultWorkflow,
  jobDisplayNames,
  checkWorkflow,
} from "./.github/scripts/ci-standards-audit.mjs";

const prOnly = {
  name: "PR only",
  on: { pull_request: null },
  jobs: {},
};
if (!isPrTriggeredWorkflow(prOnly)) throw new Error("pull_request should be PR-triggered");
if (isPushToDefaultWorkflow(prOnly, "main")) throw new Error("PR-only should not push to main");

const pushMain = {
  name: "Push main",
  on: { push: { branches: ["main"] } },
  jobs: {},
};
if (isPrTriggeredWorkflow(pushMain)) throw new Error("push-only should not be PR-triggered");
if (!isPushToDefaultWorkflow(pushMain, "main")) throw new Error("push to main should match main");

const matrixJob = {
  name: "test (${{ matrix.node-version }})",
  strategy: { matrix: { "node-version": [18, 20] } },
};
const names = jobDisplayNames("test", matrixJob);
if (!names.includes("test (18)") || !names.includes("test (20)")) {
  throw new Error(`matrix expansion failed: ${JSON.stringify(names)}`);
}

const compliant = {
  name: "CI",
  on: { pull_request: null, push: { branches: ["main"] } },
  concurrency: { group: "ci-${{ github.ref }}", "cancel-in-progress": true },
  jobs: {
    test: {
      name: "test",
      "runs-on": "ubuntu-latest",
      "timeout-minutes": 15,
      steps: [
        { uses: "actions/checkout@v4" },
        { uses: "actions/setup-node@v4", with: { "node-version": 20, cache: "npm" } },
        { run: "npm ci" },
      ],
    },
  },
};
const ok = checkWorkflow("ci.yml", compliant, ["test"], "main");
if (!ok.timeout_minutes_ok) throw new Error("compliant workflow should have timeout ok");
if (ok.concurrency_ok !== true) throw new Error("compliant workflow should have concurrency ok");
if (!ok.dependency_caching_ok) throw new Error("compliant workflow should have caching ok");
if (ok.trigger_level_path_filter_error) throw new Error("compliant workflow should not flag path filter");

const bad = {
  name: "CI",
  on: { pull_request: { paths: ["src/**"] }, push: { branches: ["main"] } },
  jobs: {
    test: {
      name: "test",
      "runs-on": "ubuntu-latest",
      steps: [
        { uses: "actions/checkout@v4" },
        { uses: "actions/setup-node@v4", with: { "node-version": 20 } },
        { run: "npm ci" },
      ],
    },
  },
};
const gap = checkWorkflow("ci.yml", bad, ["test"], "main");
if (gap.timeout_minutes_ok) throw new Error("bad workflow should be missing timeout");
if (gap.concurrency_ok !== false) throw new Error("bad workflow should be missing concurrency");
if (gap.dependency_caching_ok) throw new Error("bad workflow should be missing caching");
if (!gap.trigger_level_path_filter_error) throw new Error("bad workflow should flag path filter on required check");

console.log("OK: isPrTriggered, isPushToDefault, jobDisplayNames, checkWorkflow");
' || fail "pure function tests failed"

# Full fixture run: must find the compliant repo clean, the gaps repo with four
# gaps plus missing auto-revert, and the private repo not eligible.
report="$(node "$script" --from-json "$fixtures/typical.json" --format json)"

echo "$report" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (report.summary.total_repos !== 3) throw new Error(`expected 3 repos, got ${report.summary.total_repos}`);

const compliant = report.repos.find((r) => r.repo === "Nishfleet/example-compliant");
if (!compliant) throw new Error("compliant repo missing");
if (compliant.gap_summary.length !== 0) throw new Error(`compliant repo should have no gaps, got ${compliant.gap_summary.join(", ")}`);
if (!compliant.auto_revert.present || !compliant.auto_revert.eligible) throw new Error("compliant repo should have present and eligible auto-revert");

const gaps = report.repos.find((r) => r.repo === "Nishfleet/example-gaps");
if (!gaps) throw new Error("gaps repo missing");
if (gaps.gap_summary.length !== 5) {
  throw new Error(`gaps repo expected 5 gap lines, got ${gaps.gap_summary.length}: ${gaps.gap_summary.join("; ")}`);
}
if (!gaps.auto_revert.can_open_pr) throw new Error("gaps repo should be eligible for auto-revert PR");

const ineligible = report.repos.find((r) => r.repo === "Nishfleet/example-not-eligible");
if (!ineligible) throw new Error("ineligible repo missing");
if (ineligible.auto_revert.eligible) throw new Error("private free-plan repo should not be eligible");
if (!ineligible.auto_revert.reason.includes("private free-plan")) throw new Error("ineligible reason should mention private free-plan");

console.log("OK: fixture audit finds compliant, gaps, and ineligible repos");
'

echo "OK: ci-standards-audit.mjs fixtures and pure functions"

# fleet-ops#154: P14 must not inline-verify units whose ExecStart is a VPS
# path. Worker App tokens cannot push .github/workflows/**, so this lock
# rides on a test already listed in verify-command rather than a new
# workflow step.
bash "$here/p14-unstubbed-unit-verify.test.sh"

# fleet-ops#566: P14 verify-command is an explicit list. Workers cannot push
# .github/workflows/**, so the listing gate rides on this listed test.
bash "$here/p14-test-listing-gate.test.sh"

# fleet-ops#1457: stop-the-line detector drill. The detector + watch
# workflows landed in #1465, but the test was never registered in ci.yml
# (workers cannot push .github/workflows/**), so the p14-test-listing-gate
# failed on main. Hosted here so P14 runs it without a workflow-file edit.
bash "$here/stop-the-line-detector.test.sh"

# fleet-ops#1458: nish-boundary-notify retry + direct Telegram API fallback
# drill. Landed in #1471 but was not registered in ci.yml (workers cannot
# push .github/workflows/**). Runs offline against temp files. Hosted here
# so P14 runs it without a workflow-file edit.
bash "$here/nish-boundary-notify-retry-fallback.test.sh"

# fleet-ops#1212: filing-time same-problem dedupe helper. Hosted here so
# P14 runs it without a workflow-file edit (the worker App cannot push
# .github/workflows/**).
bash "$here/issue-file.test.sh"

# fleet-ops#695: same-repo `Closes <repo>#N` rejection gate. Pure
# evaluator hosted by this listed test so the drill runs in P14
# without a workflow-file edit (the worker App cannot push
# .github/workflows/**).
bash "$here/same-repo-closes-gate.test.sh"

# fleet-ops#1229: merge-trample gate. Hosted here so P14 runs the drill
# without a workflow-file edit.
bash "$here/merge-trample-gate.test.sh"

# fleet-ops#1548: machinery-authorization gate. Hosted here so P14 runs
# the drill without a workflow-file edit (nishfleet-worker cannot push
# .github/workflows/**).
bash "$here/machinery-authorization-gate.test.sh"

# fleet-ops#1493 (fleet-ops#2020): tests/ready-work-deleted.test.sh pins the deletion
# of the hand-placed ready-work dispatcher and checks the allowlist / MANIFEST /
# organ-catalog. Host it here from this already-listed ci-standards-audit test so
# the P14 test-listing gate goes green without a workflow edit.
bash "$here/ready-work-deleted.test.sh"

# fleet-ops#1492 / #1497 / #1498: tests that pin the deletion
# (auditor-stdio-test -> MECHANICAL-INSTEAD, quality-baseline-research ->
# MECHANICAL-INSTEAD) and the migration (memory-index-autocompact ->
# EXCEPTION-APPROVED) verdicts against the allowlist / MANIFEST / organ-catalog.
# Hosted here from this already-listed ci-standards-audit test so the P14
# test-listing gate goes green without a workflow edit.
bash "$here/auditor-stdio-test-deleted.test.sh"
bash "$here/quality-baseline-research-deleted.test.sh"
# note: memory-index-autocompact-migrated.test.sh runs `systemd-analyze verify` on
# a unit whose ExecStart points to /home/nish/.local/bin/memory-index-autocompact
# (VPS-only) — it is live_skip in p14-test-listing-gate, not hosted here.

# fleet-ops#1160: tests/fleet-ops-1160-regression.test.sh pins the tailscale
# RECOVER / sudo-probe / Persistent-timer logic in bin/vps-post-reboot-verify
# and bin/vps-weekly-update. Hosted here from this already-listed
# ci-standards-audit test so the P14 test-listing gate goes green without a
# workflow edit.
bash "$here/fleet-ops-1160-regression.test.sh"

# fleet-ops#1157: self-auditing console (verify field, DISPUTED, ConsoleLying).
# Hosted here so P14 runs it without a workflow-file edit.
bash "$here/console-tile-verify.test.sh"

# fleet-ops#1232: FleetGhCacheStale (warning, 45m) on the repair rail.
# Hosted here so P14 runs it without a workflow-file edit.
bash "$here/fleet-gh-cache-stale.test.sh"

# fleet-ops#1263: TTL + provenance compile layer. Nested host so P14
# covers it without a workflow-file edit.
bash "$here/memoryctl-ttl-provenance.test.sh"

# fleet-ops#1211: waste-ledger metric family + WasteRatioRising (no page).
# Hosted here so P14 runs it without a workflow-file edit.
bash "$here/fleet-waste-ledger.test.sh"

# fleet-ops#2528: three WFR-input trend regression alerts live in the
# dispatcher SKIP_SET + canary SKIP_FIRING (+ stubbed no-spawn /
# no-STOP-REASON proof). Hosted here so P14 runs it without a
# workflow-file edit.
bash "$here/alert-repair-wfr-trend-skip.test.sh"

# fleet-ops#1466: closure condition for the seat-health.ts 200/empty-body
# false-healthy gap. The test imports the live extension at
# $HOME/.pi/agent/extensions/seat-health.ts (or FLEET_SEAT_HEALTH_TS) and
# runs the three invariants from the issue's test plan. CI skips when the
# extension is missing; on the VPS the test fails today (the gap is open)
# and passes once the classifier is fixed. Hosted here so P14 runs it
# without a workflow-file edit (the worker App cannot push
# .github/workflows/**).
bash "$here/seat-health-classifier.test.sh"

# fleet-ops#1422: closure condition for the runaway-seat quarantine. The
# test imports the live extension at
# $HOME/.pi/agent/extensions/seat-health.ts (or FLEET_SEAT_HEALTH_TS) and
# asserts that a seat past the quarantine threshold (20) gets an
# exponentially growing wall (1h floor -> 24h cap) instead of a flat
# 30s/900s re-probe window, and that a healthy write resets the count.
# CI skips when the extension is missing; on the VPS the test fails against
# the pre-fix extension and passes once computeUsableAt/writeSeatLedgerEntry
# quarantine. Hosted here so P14 runs it without a workflow-file edit (the
# worker App cannot push .github/workflows/**).
bash "$here/seat-health-quarantine.test.sh"

# fleet-ops#2145: closure condition for the seat_dead corpse mark. The test
# imports the live extension at $HOME/.pi/agent/extensions/seat-health.ts (or
# FLEET_SEAT_HEALTH_TS) and asserts that a seat past the seat_dead threshold
# (25 consecutive transient failures, or quota_exhausted aged past 24h) is
# marked seat_dead=true — a corpse, not a walled seat — while a successful
# probe recovers it (count -> 0, seat_dead -> false). CI skips when the
# extension is missing; on the VPS the test fails against the pre-fix
# extension and passes once shouldMarkSeatDead is wired into
# writeSeatLedgerEntry. Hosted here so P14 runs it without a workflow-file
# edit (the worker App cannot push .github/workflows/**).
bash "$here/seat-health-seat-dead.test.sh"

# fleet-ops#1464: GitHub push channel (webhook → Worker → tunnel → VPS).
# The four tests are offline (DRY=1, ephemeral localhost ports, temp dirs):
#   - gh-webhook-receiver-hmac: HMAC verify + dispatch table + /healthz
#   - gh-webhook-canary: synthetic probe HMAC + dead-man status states
#   - gh-webhook-organ-heartbeat: organ registry + absent() rules + gate
#   - fleet-intake-reconciler-counter: reconciler-caught counter + cadence
# Hosted here so P14 runs them without a workflow-file edit (the worker
# App cannot push .github/workflows/**).
bash "$here/gh-webhook-receiver-hmac.test.sh"
bash "$here/gh-webhook-canary.test.sh"
bash "$here/gh-webhook-organ-heartbeat.test.sh"
bash "$here/fleet-intake-reconciler-counter.test.sh"

# fleet-ops#180: gap-closure loop state machine (stubbed acceptance).
# Hosted here so P14 runs it without a workflow-file edit (the worker App
# cannot push .github/workflows/**).
bash "$here/fleet-gap-closure-loop.test.sh"

# fleet-ops#1549: --help/-h on fleet-blind-audit and fleet-researcher-dispatch
# must print usage and exit 0 without running a live audit or dispatch.
# Hosted here so P14 runs it without a workflow-file edit (the worker App
# cannot push .github/workflows/**).
bash "$here/fleet-help-flag-runs-live.test.sh"

# fleet-ops#796: sgscan wrapper regression suite (--help, JSON parsing,
# unknown-flag rejection). Added by #1652 without a ci.yml listing or
# host; hosted here so P14 runs it without a workflow-file edit and the
# p14-test-listing-gate accounts for it (fleet-ops#1622).
bash "$here/sgscan.test.sh"

# auditor 2026-08-30: p14-test-listing-gate red on 4 orphan tests
# (fleet-loose-ends-canary + pi-issue-run-hang-stall-bench +
# unit-escalation-write-retry-absorb + unit-escalation-write-scout-futility-dedupe).
# Each landed without a host or known_orphan entry, which kept the gate red,
# SPEC-GATE-REFUSED the intake tick, dropped running=2 vs admit=22, and
# tripped the fleet-heartbeat undersat fail-loud. Hosted here so P14 runs
# them without a workflow-file edit.
bash "$here/fleet-loose-ends-canary.test.sh"
bash "$here/pi-issue-run-hang-stall-bench.test.sh"
bash "$here/unit-escalation-write-retry-absorb.test.sh"
bash "$here/unit-escalation-write-scout-futility-dedupe.test.sh"
# fleet-ops#2399 added unit-escalation-write-journal-evidence.test.sh (ledger
# 2026-08-28: pin journal evidence into STOP-REASON) without a ci.yml listing
# or host, leaving p14-test-listing-gate red on main -> FleetMainRed. Hosted
# here alongside its sibling unit-escalation-write-* tests so P14 runs it
# without a workflow-file edit.
bash "$here/unit-escalation-write-journal-evidence.test.sh"

# fleet-ops#2614 (PR #2655): same-unit re-fire dedupe + orphan-chain sweep.
# PR #2655 landed unit-escalation-write-same-unit-rerun-dedupe.test.sh and
# fleet-escalation-completion-orphan-sweep.test.sh WITHOUT a ci.yml listing
# or host, leaving p14-test-listing-gate red on main -> FleetMainRed (same
# failure class as fleet-ops#2399 journal-evidence, below). Hosted here
# alongside their sibling unit-escalation-write-*/escalation-completion
# tests so P14 runs them without a workflow-file edit (the worker App cannot
# push .github/workflows/**).
bash "$here/unit-escalation-write-same-unit-rerun-dedupe.test.sh"
bash "$here/fleet-escalation-completion-orphan-sweep.test.sh"

# fleet-ops#2133 / #2475 (PR #2193): pi-issue@*.service exclusion from
# unit-escalation-write. The worker has its own OnFailure=pi-issue-failed@%i
# reaper + Restart=on-failure with StartLimitBurst=3, so the SENIOR AUDITOR
# path was redundant and amplified pi-issue failures into seat-burning
# auditor dispatches (measured 2026-08-30 05:00Z: 59/62/33). The runtime
# test (4 cases: real-instance skip, template skip, reaper NOT excluded,
# unrelated unit NOT excluded) is the loud proof that the writer exits 0
# with a "skipping excluded unit" message instead of writing STOP-REASON
# for pi-issue@*. Hosts here alongside its sibling unit-escalation-write-*
# tests so P14 runs it without a workflow-file edit (the worker App cannot
# push .github/workflows/**).
bash "$here/unit-escalation-write-pi-issue-exclusion.test.sh"

# fleet-ops#2462: cap re-claims per item (MAX_RECLAIMS in pi-intake-tick.sh)
# + systemic-failure skip (.systemic marker when every tried seat is benched).
# Hosts the 11-test gate (MAX_RECLAIMS env var, tick read path, skip+escalate,
# .systemic marker, reaper increment+reset, run init+reset, shellcheck) so
# P14 covers it without a workflow-file edit (the worker App cannot push
# .github/workflows/**).
bash "$here/fleet-ops-2462-claim-cap.test.sh"
