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

grep -F 'tests/ci-standards-audit.test.sh' "$repo_root/.github/workflows/ci.yml" >/dev/null \
  || fail "ci.yml verify-command must run tests/ci-standards-audit.test.sh"

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
