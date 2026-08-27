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
