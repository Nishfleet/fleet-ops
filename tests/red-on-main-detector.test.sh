#!/usr/bin/env bash
# tests/red-on-main-detector.test.sh
#
# Proves the red-on-main detector classifies a failing main run without
# reaching GitHub. The fixture form is a single run + previous_runs so each
# classification has a clear unit case.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/red-on-main-detector.mjs"
fixtures="$here/fixtures/red-on-main-detector"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$script" ]] || fail "detector script not found: $script"
node --check "$script" || fail "detector script failed node --check"
node "$script" --help >/dev/null || fail "detector --help failed"

cd "$repo_root"

# --- pure-function unit tests ------------------------------------------------
node --input-type=module -e '
import {
  classifyFailure,
  buildAlert,
  collapseAlerts,
  isSkippedWorkflow,
  renderAlert,
} from "./.github/scripts/red-on-main-detector.mjs";

const run = { id: 10, created_at: "2026-08-25T17:00:00Z", conclusion: "failure" };
const success = { id: 1, created_at: "2026-08-25T16:00:00Z", conclusion: "success" };
const failure = { id: 2, created_at: "2026-08-25T16:00:00Z", conclusion: "failure" };

if (classifyFailure(run, []) !== "first-ever") throw new Error("no previous runs must be first-ever");
if (classifyFailure(run, [failure]) !== "never-green") throw new Error("only previous failures must be never-green");
if (classifyFailure(run, [success, failure]) !== "established-red") throw new Error("any previous success must be established-red");

const alert = buildAlert(
  { ...run, name: "CI", workflow_id: 5, head_branch: "main", head_sha: "abc123def456", html_url: "https://example.com/run/10" },
  [],
  "Nishfleet/0509"
);
if (alert.status !== "first-ever") throw new Error("buildAlert must be first-ever");
if (alert.workflow !== "CI") throw new Error("buildAlert must name workflow");
if (!alert.short_sha) throw new Error("buildAlert must set short_sha");
if (alert.prior_run_count !== 0) throw new Error("buildAlert prior_run_count must be 0");

const rendered = renderAlert(alert);
if (!rendered.includes("first ever")) throw new Error("renderAlert first-ever must say first ever");
if (!rendered.includes("https://example.com/run/10")) throw new Error("renderAlert must include run url");

if (isSkippedWorkflow("Red on main detector") !== true) throw new Error("detector workflow must be skipped");
if (isSkippedWorkflow("CI") !== false) throw new Error("CI must not be skipped");

const collapsed = collapseAlerts([
  { ...alert, workflow_id: 5, status: "first-ever", created_at: "2026-08-25T17:00:00Z", run_id: 10, prior_run_count: 0 },
  { ...alert, workflow_id: 5, status: "never-green", created_at: "2026-08-25T17:15:00Z", run_id: 11, run_url: "https://example.com/run/11", prior_run_count: 1 },
]);
if (collapsed.length !== 1) throw new Error("collapseAlerts must keep one alert per workflow");
if (collapsed[0].status !== "first-ever") throw new Error("collapseAlerts must keep first-ever over never-green");
if (collapsed[0].run_id !== 11) throw new Error("collapseAlerts must point at the newest run");

console.log("OK: classifyFailure, buildAlert, renderAlert, skip, collapse");
' || fail "pure function tests failed"

# --- replay: first ever main run fails ---------------------------------------
first_json="$(node "$script" --from-json "$fixtures/first-ever.json" --format json)"
echo "$first_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.alerts) || report.alerts.length !== 1) {
  throw new Error(`first-ever fixture must fire one alert, got ${JSON.stringify(report.alerts)}`);
}
const a = report.alerts[0];
if (a.status !== "first-ever") throw new Error(`expected status first-ever, got ${a.status}`);
if (a.workflow !== "ratchet-auto-tighten") throw new Error(`expected workflow ratchet-auto-tighten, got ${a.workflow}`);
if (a.prior_run_count !== 0) throw new Error(`expected 0 previous runs, got ${a.prior_run_count}`);
if (a.has_green_baseline) throw new Error("first-ever must have no green baseline");
console.log("OK: first-ever fixture fires");
'

# --- replay: never-green workflow fails --------------------------------------
never_json="$(node "$script" --from-json "$fixtures/never-green.json" --format json)"
echo "$never_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.alerts) || report.alerts.length !== 1) {
  throw new Error(`never-green fixture must fire one alert, got ${JSON.stringify(report.alerts)}`);
}
const a = report.alerts[0];
if (a.status !== "never-green") throw new Error(`expected status never-green, got ${a.status}`);
if (a.prior_run_count !== 1) throw new Error(`expected 1 previous run, got ${a.prior_run_count}`);
if (a.has_green_baseline) throw new Error("never-green must have no green baseline");
console.log("OK: never-green fixture fires");
'

# --- replay: established workflow goes red -----------------------------------
established_json="$(node "$script" --from-json "$fixtures/established-red.json" --format json)"
echo "$established_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.alerts) || report.alerts.length !== 1) {
  throw new Error(`established-red fixture must fire one alert, got ${JSON.stringify(report.alerts)}`);
}
const a = report.alerts[0];
if (a.status !== "established-red") throw new Error(`expected status established-red, got ${a.status}`);
if (a.prior_run_count !== 1) throw new Error(`expected 1 previous run, got ${a.prior_run_count}`);
if (!a.has_green_baseline) throw new Error("established-red must have green baseline");
console.log("OK: established-red fixture fires");
'

# --- replay: quiet fixture (success) stays silent ----------------------------
quiet_json="$(node "$script" --from-json "$fixtures/quiet.json" --format json)"
echo "$quiet_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.alerts) || report.alerts.length !== 0) {
  throw new Error(`quiet fixture must stay silent, got ${JSON.stringify(report.alerts)}`);
}
console.log("OK: quiet fixture stays silent");
'

# --- human report copy -------------------------------------------------------
human="$(node "$script" --from-json "$fixtures/first-ever.json" --format human)"
echo "$human" | grep -q "Red-on-main detector" || fail "human report must have a title"
echo "$human" | grep -q "first ever" || fail "human report first-ever must say first ever"
echo "$human" | grep -q "ratchet-auto-tighten" || fail "human report must name the workflow"
echo "$human" | grep -qi "red-on-main" || fail "human report must mention red-on-main"

# --- issue title and body ----------------------------------------------------
body="$(node --input-type=module -e '
import { issueTitle, issueBody } from "./.github/scripts/red-on-main-detector.mjs";
const a = {
  status: "first-ever", workflow: "ratchet-auto-tighten", run_url: "https://example.com/run/10",
  short_sha: "abc1234", head_sha: "abc1234567890", head_branch: "main", event: "push",
  prior_run_count: 0, has_green_baseline: false,
};
console.log(JSON.stringify({ title: issueTitle(a), body: issueBody(a) }));
')"
echo "$body" | jq -e '.title == "red-on-main: ratchet-auto-tighten (first-ever)"' >/dev/null || fail "issue title mismatch"
echo "$body" | jq -e '.body | contains("first ever run on main")' >/dev/null || fail "issue body must say first ever run on main"
echo "$body" | jq -e '.body | contains("Do not auto-revert")' >/dev/null || fail "issue body must say Do not auto-revert"
echo "$body" | jq -e '.body | contains("red-on-main-detector:")' >/dev/null || fail "issue body must contain detector marker"

echo "OK: red-on-main-detector.mjs fixtures and copy"
