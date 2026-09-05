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

# fleet-ops#3237: pi transport self-heal regression test. Proves the
# pi-transport-self-heal wrapper re-creates the bin symlink via npm rebuild,
# falls back to npm install@pinned, and only escalates when the package itself
# is broken. Hosted here so P14 runs it without a workflow-file edit.
bash "$here/pi-transport-self-heal.test.sh"

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

# fleet-ops#2757: canary effectiveness metric family + CanaryEffectivenessLow
# / CanarySilentTooLong. Hosted here so P14 runs it without a workflow-file
# edit.
bash "$here/canary-effectiveness.test.sh"

# fleet-ops#2528: three WFR-input trend regression alerts live in the
# dispatcher SKIP_SET + canary SKIP_FIRING (+ stubbed no-spawn /
# no-STOP-REASON proof). Hosted here so P14 runs it without a
# workflow-file edit.
bash "$here/alert-repair-wfr-trend-skip.test.sh"

# fleet-ops#2672: the WFR-input main_green slow-burn SLO lives in the
# dispatcher SKIP_SET + canary SKIP_FIRING so the 6h AMX repeat can no
# longer spawn a repair worker into a mechanism-impossible lagging
# integrator (the verify chain it created stalled at hop=verify and
# re-seated onto an empty-run benched seat). Hosted here so P14 runs it
# without a workflow-file edit.
bash "$here/alert-repair-slo-slowburn-skip.test.sh"

# fleet-ops#2694 (PR #2796 follow-up): the fleet_alert_outcome_24h
# phantom-vs-real split test landed on main without a ci.yml listing or a
# host, so P14 ran red on "1 test file(s) are neither in ci.yml, hosted by
# a listed test, live/destructive, nor a known orphan:
# alert-repair-outcome-metric.test.sh" for every push since 08:05Z (the
# named pin in tests/p14-test-listing-gate.test.sh is the class-prevention
# so a future drop of this host line fails by name). Hermetic test
# (no gh/prometheus/systemd) — runs fine in hosted CI. Hosted here so P14
# runs it without a workflow-file edit (the worker App cannot push
# .github/workflows/**).
bash "$here/alert-repair-outcome-metric.test.sh"

# fleet-ops#2768: one-shot dispatch-ledger fixture-row sweep. PR #2873
# landed the test without a ci.yml listing or a host, so P14 ran red on
# "1 test file(s) are neither in ci.yml, hosted by a listed test,
# live/destructive, nor a known orphan: dispatch-ledger-fixture-sweep.test.sh"
# (run 33662643290). Hosted here so P14 runs it without a workflow-file
# edit (the worker App cannot push .github/workflows/**). The named pin
# in tests/p14-test-listing-gate.test.sh is the class-prevention so a
# future drop of this host line fails by name.
# Hermetic (scratch ledger, no gh/prometheus/systemd).
bash "$here/dispatch-ledger-fixture-sweep.test.sh"

# fleet-ops#2902 (PR #2885 follow-up): the deploy-quality SLO test landed
# on main without a ci.yml listing or a host, so P14 ran red on "2 test
# file(s) are neither in ci.yml, hosted by a listed test, live/destructive,
# nor a known orphan: fleet-deploy-quality.test.sh
# fleet-issue-file-close-duplicates.test.sh" (reported in #2902). Hosted
# here so P14 runs it without a workflow-file edit (the worker App cannot
# push .github/workflows/**). The named pin in
# tests/p14-test-listing-gate.test.sh is the class-prevention so a future
# drop of this host line fails by name.
# Hermetic (pin fixtures, no gh/prometheus/systemd).
bash "$here/fleet-deploy-quality.test.sh"

# fleet-ops#2902 (PR #2900 follow-up): the close-duplicates drain test
# landed on main without a ci.yml listing or a host (same 2-orphan FAIL as
# fleet-deploy-quality above, reported in #2902). Hosted here so P14 runs
# it without a workflow-file edit (the worker App cannot push
# .github/workflows/**). The named pin in
# tests/p14-test-listing-gate.test.sh is the class-prevention so a future
# drop of this host line fails by name.
# Hermetic (fake gh, no gh/prometheus/systemd).
bash "$here/fleet-issue-file-close-duplicates.test.sh"

# fleet-ops#3161: regression test for the primary-signal floor + cross-repo
# canonical bug that closed 18 issues incl. two Nish-endorsed critical-path
# packets as score=1.00 dups of an unrelated 0509 CI issue. Hosted here
# (same shape as the #2902 host above) so P14 runs it without a workflow
# edit. The named pin in tests/p14-test-listing-gate.test.sh is the
# class-prevention so a future drop of this host line fails by name.
# Hermetic (fake gh, no network).
bash "$here/fleet-issue-file-close-duplicates-regression-3161.test.sh"

# fleet-ops#2902 (PR #2905 follow-up): the leaky-worktree containment
# detector landed on main without a ci.yml listing or a host — and P14 was
# already red on the two orphans above, so this leftover slipped in
# unmasked. Hosted here so P14 runs it without a workflow-file edit (the
# worker App cannot push .github/workflows/**). The named pin in
# tests/p14-test-listing-gate.test.sh is the class-prevention so a future
# drop of this host line fails by name.
# Hermetic self-test with fixture worktrees; live scan zeroes out (exit 0)
# when roots are absent, so it runs fine in hosted CI.
bash "$here/worktree-leaky-test-containment.test.sh"

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

# fleet-ops#3263 (PR #3304): devin/cursor provider extension + spawnSync
# timeout gate. Hosted here so P14 runs it without a workflow-file edit
# (workers cannot push .github/workflows/**).
bash "$here/provider-timeout.test.sh"
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

# fleet-ops#2912: closeout-skipped recurrence suppression in unit-escalation-write —
# a recurring same-class unit trip (fleet-heartbeat's structural reds, 35 trips
# in ~2 days) must stop re-summoning a senior auditor once the same class has
# been closeout-skipped RECURRENCE_SUPPRESS_N times. Hosted here alongside its
# unit-escalation-write-* siblings so P14 runs it without a workflow-file edit
# (the worker App cannot push .github/workflows/**).
bash "$here/unit-escalation-write-recurrence-suppress.test.sh"

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

# fleet-ops#2666: 0B-stdout empty-run burst on healthy seats — the 2h
# burst signal the #902 24h waste-ratio gauge masks (2026-09-01 12:48Z-
# 14:11Z: empty_runs_last_2h 0 -> 6 on minimax/MiniMax-M3 + openrouter/
# deepseek-v4-flash-0731, both healthy seats). The 16-scenario offline
# suite proves the burst gate, cause classification, healthy-seat
# bucketing, dedup, and observe-to-close. Hosted here so P14 runs it
# without a workflow-file edit (the worker App cannot push
# .github/workflows/**).
bash "$here/fleet-empty-run-burst-canary.test.sh"
bash "$here/fleet-scout-leak-canary.test.sh"

# fleet-ops#2627: empty-run count must accumulate across healthy ledger
# clobbers (seat-health.ts resets ledger count=0 on every 200 OK, so the
# wrapper's mark_seat_empty_run must carry the count in the clobber-proof
# spawn-bench marker — fleet-ops#1512 — and engage the failure-ceiling
# park from the marker-carried count at EMPTY_RUN_FAILURE_CEILING). The
# live 18 empty runs in 2h on healthy-reporting seats (opencode/nemotron
# and openrouter/deepseek-v4-flash-0731) was the wrapper-side marker
# staying at count=1 every cycle. Hosted here so P14 runs it without a
# workflow-file edit (the worker App cannot push .github/workflows/**).
bash "$here/seat-empty-run-clobber-park.test.sh"

# fleet-ops#3046: the EMPTY_RUN_FAILURE_CEILING default was 10, but the
# 2h count-merge window reset the count before it reached 10, so the live
# nemotron-3-ultra-free loop (9 empty runs in 2h on fleet-ops-2778) never
# parked. The fix lowers the default to 3 so the park fires on the 3rd
# no-op in the SAME 2h window. This test asserts the production default
# (no env override) is exactly 3 and the park engages on the 3rd no-op.
# Hosted here so P14 runs it without a workflow-file edit.
bash "$here/seat-empty-run-ceiling-default.test.sh"

# fleet-ops#2759: intake prioritization effectiveness metric (precedence-band
# product-first hold -> product merge lift). Hosted here so P14 runs it
# without a workflow-file edit (the worker App cannot push
# .github/workflows/**). Hermetic test (no gh/prometheus/systemd) — runs
# fine in hosted CI.
bash "$here/intake-prioritization-effectiveness.test.sh"

# fleet-ops#2756: scout effectiveness metric (filed -> survive intake ->
# agent-ready -> merged_14d). Hosted here so P14 runs it without a
# workflow-file edit (the worker App cannot push .github/workflows/**).
# Hermetic test (no gh/prometheus/systemd) — runs fine in hosted CI.
bash "$here/scout-effectiveness.test.sh"

# fleet-ops#2755: product delivery SLO family (throughput / lead time /
# revert rate / merged_24h). Hosted here so P14 runs it without a
# workflow-file edit (the worker App cannot push .github/workflows/**).
# Hermetic test (no gh/prometheus/systemd) — runs fine in hosted CI.
bash "$here/fleet-product-slo.test.sh"

# fleet-ops#2920 (PR #2937 follow-up): the drift-canary metrics drop-in
# test landed on main without a ci.yml listing or a host, so P14 ran red
# on "1 test file(s) are neither in ci.yml, hosted by a listed test,
# live/destructive, nor a known orphan: fleet-ops-drift-metrics-dropin.test.sh"
# for every push since 20:53Z. Hosted here so P14 runs it without a
# workflow-file edit (the worker App cannot push .github/workflows/**).
# The named pin in tests/p14-test-listing-gate.test.sh is the
# class-prevention so a future drop of this host line fails by name.
# Hermetic (stub gh + systemctl, overlay workspaces root).
bash "$here/fleet-ops-drift-metrics-dropin.test.sh"

# fleet-ops#2934 (PR #2948 follow-up): the empty-run count-merge window
# test landed on main without a ci.yml listing or a host, so P14 ran red
# on "1 test file(s) are neither in ci.yml, hosted by a listed test,
# live/destructive, nor a known orphan: seat-empty-run-intermittent-count.test.sh"
# for every push since 21:04Z. Hosted here so P14 runs it without a
# workflow-file edit (the worker App cannot push .github/workflows/**).
# The named pin in tests/p14-test-listing-gate.test.sh is the
# class-prevention so a future drop of this host line fails by name.
# Hermetic (scratch ledger/state, no gh/prometheus/systemd).
bash "$here/seat-empty-run-intermittent-count.test.sh"

# fleet-ops#1520: curator journal-cap lock. The live dump (~40KB of
# dispositioned trust_denials.entries every 5 min) was fixed in
# memory-compound#9; this test is the fleet-ops class lock so a revert
# of journal_safe_status fails CI here. Hosted here so P14 runs it
# without a workflow-file edit (the worker App cannot push
# .github/workflows/**). Offline import of memoryctl plus a live layer
# that skips in hosted CI (no user journal / no vault health file).
bash "$here/curator-journal-cap.test.sh"
