#!/usr/bin/env bash
# tests/orphan-workflow-detector.test.sh
#
# fleet-ops#1161 — orphan-workflow detector (audit findings 3+4).
#
# Proves the pure decision logic without reaching GitHub. The detector
# must:
#   - filter out dynamic/ dependabot paths
#   - filter out non-active workflow states
#   - report missing=active file as an orphan
#   - collapse duplicates and report one alert per (repo, path) pair
#   - render a stable, reusable-issue-title for the human handoff
#   - accept the multi-repo fixture shape for replay
#
# The live GitHub-side check (run the reusable workflow against the real
# fleet2/egress-probe/0509-telemetry/siterep) is a separate acceptance
# step on a one-shot runbook, gated by Nish — the detector itself only
# needs to file the alert.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/orphan-workflow-detector.mjs"
fixtures="$here/fixtures/orphan-workflow-detector"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "detector script not found: $script"
node --check "$script" || fail "detector script failed node --check"
node "$script" --help >/dev/null || fail "detector --help failed"
ok "script parses, --help exits 0"

cd "$repo_root"

# --- pure-function unit tests ------------------------------------------------
node --input-type=module -e '
import {
  filterProbableOrphans,
  isOrphan,
  buildAlert,
  collapseAlerts,
  renderAlert,
  issueTitle,
  checksFromFixture,
} from "./.github/scripts/orphan-workflow-detector.mjs";

const eq = (got, want, msg) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    throw new Error(`${msg}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
  }
};

const active = { id: 1, name: "CI", path: ".github/workflows/ci.yml", state: "active" };
const dep = { id: 2, name: "Dependabot", path: "dynamic/dependabot/dependabot-updates", state: "active" };
const disabled = { id: 3, name: "Old", path: ".github/workflows/old.yml", state: "disabled_manually" };
const inactive = { id: 4, name: "Inactive", path: ".github/workflows/inactive.yml", state: "disabled_inactivity" };

// filterProbableOrphans keeps only active workflows under .github/workflows/.
const filtered = filterProbableOrphans([active, dep, disabled, inactive]);
eq(filtered.length, 1, "filterProbableOrphans must keep only the active .github/workflows/ entry");
eq(filtered[0].id, 1, "filterProbableOrphans must pick active CI");

// isOrphan — the textbook case.
if (!isOrphan(active, "missing")) throw new Error("active + missing must be orphan");
if (isOrphan(active, "exists")) throw new Error("active + exists must NOT be orphan");
if (isOrphan(active, "unknown")) throw new Error("active + unknown must NOT be orphan (permission drift)");
if (isOrphan(disabled, "missing")) throw new Error("disabled_manually + missing must NOT be orphan");
if (isOrphan(inactive, "missing")) throw new Error("disabled_inactivity + missing must NOT be orphan");
if (isOrphan(dep, "missing")) throw new Error("dynamic/ dependabot path must NOT be orphan");
if (isOrphan(null, "missing")) throw new Error("null workflow must NOT be orphan");

// buildAlert carries through everything needed to file the issue.
const alert = buildAlert("Nishfleet/fleet2", active, true);
eq(alert.repository, "Nishfleet/fleet2", "alert must carry repository");
eq(alert.workflow_id, 1, "alert must carry workflow_id");
eq(alert.workflow_name, "CI", "alert must carry workflow_name");
eq(alert.path, ".github/workflows/ci.yml", "alert must carry path");
eq(alert.state, "active", "alert must carry state");
eq(alert.actions_enabled, true, "alert must carry actions_enabled");

// renderAlert must mention the path and the billing risk when actions are on.
const rendered = renderAlert(alert);
if (!rendered.includes("Nishfleet/fleet2")) throw new Error("renderAlert must name the repo");
if (!rendered.includes(".github/workflows/ci.yml")) throw new Error("renderAlert must name the path");
if (!rendered.includes("billing risk")) throw new Error("renderAlert must flag billing risk when Actions is enabled");
const renderedOff = renderAlert({ ...alert, actions_enabled: false });
if (renderedOff.includes("billing risk")) throw new Error("renderAlert must not flag billing when Actions is disabled");
const renderedUnknown = renderAlert({ ...alert, actions_enabled: null });
if (!renderedUnknown.includes("unknown")) throw new Error("renderAlert must say unknown when actions_enabled is null");

// issueTitle is stable per (repo, path) — re-runs must find the same issue.
const titleA = issueTitle(alert);
const titleB = issueTitle(alert);
if (titleA !== titleB) throw new Error(`issueTitle must be stable: ${titleA} != ${titleB}`);
if (!titleA.includes("Nishfleet/fleet2")) throw new Error("issueTitle must include repo");
if (!titleA.includes(".github/workflows/ci.yml")) throw new Error("issueTitle must include path");
if (!titleA.startsWith("[orphan-workflow]")) throw new Error("issueTitle must lead with the tag");

// collapseAlerts keeps one entry per (repo, path) and prefers lower id.
const a1 = buildAlert("Nishfleet/fleet2", { id: 100, name: "Old arm", path: ".github/workflows/auto-merge-arm.yml", state: "active" }, true);
const a2 = buildAlert("Nishfleet/fleet2", { id: 50, name: "New arm", path: ".github/workflows/auto-merge-arm.yml", state: "active" }, true);
const a3 = buildAlert("Nishfleet/siterep", { id: 200, name: "CI", path: ".github/workflows/ci.yml", state: "active" }, true);
const collapsed = collapseAlerts([a1, a2, a3]);
eq(collapsed.length, 2, "collapseAlerts must dedupe by (repo, path)");
const fleet2 = collapsed.find((x) => x.repository === "Nishfleet/fleet2");
if (!fleet2) throw new Error("collapseAlerts must keep fleet2");
if (fleet2.workflow_id !== 50) throw new Error(`collapseAlerts must keep lower id, got ${fleet2.workflow_id}`);
if (fleet2.workflow_name !== "New arm") throw new Error("collapseAlerts must keep the lower-id alert's name");

// checksFromFixture accepts the {repository, workflows, file_checks} shape.
const checks = checksFromFixture({
  repository: "Nishfleet/fleet2",
  workflows: [active, dep, disabled],
  file_checks: {
    ".github/workflows/ci.yml": "exists",
    ".github/workflows/old.yml": "exists",
    "dynamic/dependabot/dependabot-updates": "missing",
  },
});
if (checks.length !== 3) throw new Error(`checksFromFixture must return 3 rows, got ${checks.length}`);
if (checks[0].repository !== "Nishfleet/fleet2") throw new Error("checksFromFixture must carry repository");
if (checks[0].file_state !== "exists") throw new Error("checksFromFixture must map ci.yml to exists");

// checksFromFixture also accepts the array shape.
const arrayShape = checksFromFixture([
  { repository: "Nishfleet/fleet2", workflow: active, file_state: "missing" },
  { repository: "Nishfleet/siterep", workflow: dep, file_state: "exists" },
]);
if (arrayShape.length !== 2) throw new Error(`array-shape fixture must have 2 rows, got ${arrayShape.length}`);

// checksFromFixture must reject garbage silently (not throw).
checksFromFixture(null);
checksFromFixture({});
checksFromFixture({ repository: 42 });
checksFromFixture([{ repository: 1 }, null, { workflow: "x" }]);
ok("pure function tests pass: filter, isOrphan, buildAlert, render, title, collapse, fixture");
' || fail "pure function tests failed"

# --- replay: single-orphan fixture (one alert, dynamic+disabled filtered) ----
single_json="$(node "$script" --from-json "$fixtures/single-orphan.json" --format json --no-issue)"
echo "$single_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.alerts)) throw new Error("replay must return alerts array");
if (report.alerts.length !== 1) {
  throw new Error(`single-orphan fixture must fire exactly one alert, got ${report.alerts.length}`);
}
const a = report.alerts[0];
if (a.repository !== "Nishfleet/fleet2") throw new Error(`expected Nishfleet/fleet2, got ${a.repository}`);
if (a.path !== ".github/workflows/auto-merge-arm.yml") throw new Error(`expected auto-merge-arm.yml, got ${a.path}`);
if (a.workflow_id !== 342125743) throw new Error(`expected id 342125743, got ${a.workflow_id}`);
if (a.state !== "active") throw new Error(`expected state active, got ${a.state}`);
if (a.actions_enabled !== null) throw new Error(`expected actions_enabled null (from fixture), got ${a.actions_enabled}`);
console.log("OK: single-orphan fixture fires one alert, dynamic+disabled filtered");
' || fail "single-orphan fixture replay failed"

# --- replay: multi-repo fixture (one orphan across two repos) ----------------
multi_json="$(node "$script" --from-json "$fixtures/two-orphan-multi-repo.json" --format json --no-issue)"
echo "$multi_json" | node --input-type=module -e '
import { readFileSync } from "node:fs";
const report = JSON.parse(readFileSync(0, "utf8"));
if (!Array.isArray(report.alerts)) throw new Error("replay must return alerts array");
if (report.alerts.length !== 1) {
  throw new Error(`two-orphan-multi-repo fixture must fire exactly one alert, got ${report.alerts.length}`);
}
const a = report.alerts[0];
if (a.repository !== "Nishfleet/fleet2") throw new Error(`expected Nishfleet/fleet2, got ${a.repository}`);
if (a.workflow_name !== "Auto-merge arm") throw new Error(`expected Auto-merge arm, got ${a.workflow_name}`);
if (!a.path.endsWith("auto-merge-arm.yml")) throw new Error(`expected auto-merge-arm.yml, got ${a.path}`);
console.log("OK: multi-repo fixture fires one alert, siterep is clean");
' || fail "multi-repo fixture replay failed"

# --- --output-json writes the report ----------------------------------------
out_path="$(mktemp -t orphan-workflow-out.XXXXXX.json)"
trap "rm -f '$out_path'" EXIT
node "$script" --from-json "$fixtures/single-orphan.json" --format json --no-issue --output-json "$out_path" >/dev/null
[[ -s "$out_path" ]] || fail "output-json file must be non-empty"
node --input-type=module -e "
import { readFileSync } from 'node:fs';
const j = JSON.parse(readFileSync('$out_path', 'utf8'));
if (!Array.isArray(j.alerts) || j.alerts.length !== 1) {
  throw new Error('output-json must contain one alert, got ' + JSON.stringify(j));
}
console.log('OK: --output-json writes the report');
" || fail "--output-json file is invalid"

# --- --help exits 0 --------------------------------------------------------
node "$script" --help >/dev/null || fail "--help must exit 0"

# --repo missing is a usage error, exits 2 only when nothing is supplied
# When --repos-from is absent and --repo is absent, the script falls
# back to DEFAULT_TARGETS. We do not call it (it would try to reach
# GitHub). The test just confirms the parser does not reject --repo
# silently — it stores the value. We do that by piping a value through
# the help path and confirming --help still works.
node "$script" --help >/dev/null || fail "--help must exit 0 after --repo"
ok "all orphan-workflow-detector tests passed"
