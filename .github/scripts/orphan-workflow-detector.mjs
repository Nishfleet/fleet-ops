#!/usr/bin/env node
// orphan-workflow-detector.mjs — fleet-ops#1161 (audit findings 3+4).
//
// The defect this exists to close: a workflow registration in the
// `actions/workflows` index can outlive the file at
// `.github/workflows/<path>`. GitHub keeps the registration active and
// still bills private-repo minutes for any schedule/push/workflow_dispatch
// trigger that fires. There is no UI signal for the class. The 2026-08-27
// audit found three such orphans (auto-merge-arm.yml on fleet2,
// egress-probe, 0509-telemetry), each burning the free-org quota over
// 2000 min/month.
//
// What this does:
//   For each target private repo, list registered workflows. For each
//   ACTIVE one (state=active), confirm the file at the declared path
//   actually exists via the contents API. If 404, file an alert issue
//   (one per repo, reused if open) describing the orphan and the
//   run/registration IDs needed to disable or delete it.
//
// What this does NOT do:
//   - Modify any repo's Actions settings. The freeze
//     (`PUT actions/permissions enabled=false`, `DELETE /actions/workflows/{id}`)
//     is irreversible, scopes GHA minutes, and requires the nishfleet
//     account (the worker App token has no Actions scope). It belongs in
//     a one-shot runbook, gated by Nish, not in a PR.
//   - Filter by content of the file. A workflow file can be valid YAML
//     and still orphan (e.g. the file was renamed in a PR and the old
//     registration was never disabled). The class is "registered but
//     404 on contents API" — nothing more.
//   - Alert on dependabot dynamic workflows. They are managed by
//     GitHub and not subject to the orphan class. Paths under
//     `.github/workflows/dynamic/` are skipped.
//
// Surface: gh CLI + GitHub REST API only. No paid services. Pure logic
// (isOrphan, parseWorkflowList, buildAlert, renderAlert, collapseAlerts)
// is exported so the test suite can drive it without a live `gh`.
//
// USAGE
//   orphan-workflow-detector.mjs --repo <owner/name>   # one repo
//   orphan-workflow-detector.mjs --repos-from <json>  # list from a file
//   orphan-workflow-detector.mjs --from-json <json>   # replay stored data
//   orphan-workflow-detector.mjs --no-issue            # report only
//   orphan-workflow-detector.mjs --format json|human   # output format
//   orphan-workflow-detector.mjs --output-json <path>  # also write JSON
//   orphan-workflow-detector.mjs --help

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const LABEL = "orphan-workflow";
const COMMENT_MARKER_PREFIX = "<!-- orphan-workflow-detector:";

// `dynamic/...` workflows are managed by GitHub (Dependabot, etc.) and
// are never subject to the orphan class — they live outside the
// .github/workflows/ tree on disk.
const DYNAMIC_PATH_PREFIX = "dynamic/";

/**
 * @typedef {{
 *   id: number,
 *   name: string,
 *   path: string,
 *   state: string,
 * }} RegisteredWorkflow
 */

/**
 * @typedef {{
 *   repository: string,
 *   workflow_id: number,
 *   workflow_name: string,
 *   path: string,
 *   state: string,
 *   actions_enabled: boolean | null,
 *   html_url: string,
 * }} OrphanAlert
 */

/**
 * Run `gh api` and return parsed JSON, throwing on failure.
 * @param {string[]} args
 * @returns {any}
 */
function ghJson(args) {
  const out = execFileSync(
    "gh",
    ["api", ...args],
    { encoding: "utf8", maxBuffer: 16 * 1024 * 1024, timeout: 60_000 },
  );
  if (!out.trim()) return null;
  return JSON.parse(out);
}

/**
 * Probe a contents URL and return true iff the file exists.
 * A 404 is the orphan class. A 403 (lost access) is treated as
 * "unknown" and skipped — we never false-positive on permissions.
 *
 * @param {string} repository
 * @param {string} path
 * @returns {Promise<"exists"|"missing"|"unknown">}
 */
async function fileExists(repository, path) {
  try {
    const data = ghJson([
      `repos/${repository}/contents/${path}`,
      "--jq",
      ".name",
    ]);
    if (data && typeof data === "string") return "exists";
    return "missing";
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    if (msg.includes("Not Found") || msg.includes(" 404")) return "missing";
    // Permission/visibility drift. Don't false-positive; the human
    // already has better signals (org audit log).
    return "unknown";
  }
}

/**
 * Filter raw workflow list to the ones we should probe.
 * Skips dynamic/ paths (dependabot, etc.) — they are managed by
 * GitHub and the contents API will not see them.
 *
 * @param {RegisteredWorkflow[]} workflows
 * @returns {RegisteredWorkflow[]}
 */
export function filterProbableOrphans(workflows) {
  if (!Array.isArray(workflows)) return [];
  return workflows.filter(
    (w) =>
      w &&
      typeof w.id === "number" &&
      typeof w.path === "string" &&
      typeof w.name === "string" &&
      w.path.startsWith(".github/workflows/") &&
      !w.path.includes("/" + DYNAMIC_PATH_PREFIX) &&
      !w.path.endsWith("/" + DYNAMIC_PATH_PREFIX) &&
      w.state === "active",
  );
}

/**
 * Pure decision: does a registered workflow constitute an orphan?
 * The file existence result is the only input; everything else is
 * carried through to the alert.
 *
 * @param {RegisteredWorkflow} workflow
 * @param {"exists"|"missing"|"unknown"} fileState
 * @returns {boolean}
 */
export function isOrphan(workflow, fileState) {
  if (!workflow) return false;
  if (workflow.state !== "active") return false;
  if (!workflow.path || !workflow.path.startsWith(".github/workflows/")) {
    return false;
  }
  return fileState === "missing";
}

/**
 * Read the orphan-classification input from JSON.
 * Two shapes accepted:
 *   { repository, workflows: [...], file_checks: {path: "exists"|"missing"|"unknown"} }
 *   [ { repository, workflow, file_state }, ... ]
 *
 * @param {unknown} payload
 * @returns {Array<{ repository: string, workflow: RegisteredWorkflow, file_state: "exists"|"missing"|"unknown" }>}
 */
export function checksFromFixture(payload) {
  if (!payload) return [];
  if (Array.isArray(payload)) {
    return payload
      .map((row) => {
        if (!row || typeof row !== "object") return null;
        const r = /** @type {Record<string, unknown>} */ (row);
        if (
          typeof r.repository !== "string" ||
          !r.workflow ||
          typeof r.workflow !== "object" ||
          typeof r.file_state !== "string"
        ) {
          return null;
        }
        return {
          repository: r.repository,
          workflow: /** @type {RegisteredWorkflow} */ (r.workflow),
          file_state: /** @type {"exists"|"missing"|"unknown"} */ (r.file_state),
        };
      })
      .filter((x) => x !== null);
  }
  if (typeof payload === "object") {
    const obj = /** @type {Record<string, unknown>} */ (payload);
    if (typeof obj.repository !== "string") return [];
    const workflows = Array.isArray(obj.workflows) ? obj.workflows : [];
    const fileChecks =
      obj.file_checks && typeof obj.file_checks === "object"
        ? /** @type {Record<string, string>} */ (obj.file_checks)
        : {};
    return workflows
      .map((w) => {
        if (!w || typeof w !== "object") return null;
        const wf = /** @type {RegisteredWorkflow} */ (w);
        if (!wf.path) return null;
        const state = fileChecks[wf.path];
        if (state !== "exists" && state !== "missing" && state !== "unknown") {
          return null;
        }
        return { repository: /** @type {string} */ (obj.repository), workflow: wf, file_state: state };
      })
      .filter((x) => x !== null);
  }
  return [];
}

/**
 * Build the alert object for a single orphan.
 *
 * @param {string} repository
 * @param {RegisteredWorkflow} workflow
 * @param {boolean | null} actionsEnabled
 * @returns {OrphanAlert}
 */
export function buildAlert(repository, workflow, actionsEnabled) {
  return {
    repository,
    workflow_id: workflow.id,
    workflow_name: workflow.name,
    path: workflow.path,
    state: workflow.state,
    actions_enabled: actionsEnabled,
    html_url: `https://github.com/${repository}/actions/workflows/${workflow.path.split("/").pop()}`,
  };
}

/**
 * One alert per (repo, path) pair. The detector fires per orphan; if
 * the same path shows up across two registered workflows (e.g. an old
 * ID after a re-registration), keep the lowest workflow_id.
 *
 * @param {OrphanAlert[]} alerts
 * @returns {OrphanAlert[]}
 */
export function collapseAlerts(alerts) {
  const map = new Map();
  for (const a of alerts) {
    const key = `${a.repository}::${a.path}`;
    const existing = map.get(key);
    if (!existing || a.workflow_id < existing.workflow_id) {
      map.set(key, a);
    }
  }
  return [...map.values()].sort((x, y) => {
    if (x.repository !== y.repository) return x.repository.localeCompare(y.repository);
    return x.path.localeCompare(y.path);
  });
}

/**
 * Render an alert as a stable markdown string for the issue body.
 *
 * @param {OrphanAlert} alert
 * @returns {string}
 */
export function renderAlert(alert) {
  const enabled =
    alert.actions_enabled === true
      ? "enabled (billing risk)"
      : alert.actions_enabled === false
      ? "disabled"
      : "unknown";
  return [
    `- repo: \`${alert.repository}\``,
    `- workflow: \`${alert.workflow_name}\` (id ${alert.workflow_id})`,
    `- path: \`${alert.path}\``,
    `- registration state: \`${alert.state}\``,
    `- Actions for repository: ${enabled}`,
    `- url: ${alert.html_url}`,
  ].join("\n");
}

/**
 * Issue title for an alert. Stable so re-runs find and update the
 * existing open issue.
 *
 * @param {OrphanAlert} alert
 * @returns {string}
 */
export function issueTitle(alert) {
  return `[orphan-workflow] ${alert.repository}: ${alert.path}`;
}

/**
 * Issue body for an alert.
 *
 * @param {OrphanAlert} alert
 * @returns {string}
 */
export function issueBody(alert) {
  return [
    "An active workflow registration exists in the Actions index but the",
    "declared file is missing from the default branch. GitHub continues",
    "to bill private-repo minutes for any schedule/push/workflow_dispatch",
    "trigger that fires. This alert is auto-filed by",
    "`.github/scripts/orphan-workflow-detector.mjs` (fleet-ops#1161).",
    "",
    "## Orphan",
    "",
    renderAlert(alert),
    "",
    "## Why this matters",
    "",
    "- Each failed run on the orphan bills the org's GitHub-hosted minutes.",
    "- A free-plan org past quota bills the card on file. AGENTS.md forbids",
    "  unattended card charges; this issue is the human handoff for the",
    "  freeze step.",
    "",
    "## Recommended remediation (runbook, manual)",
    "",
    "Pick exactly one (mutations are irreversible; coordinate with Nish):",
    "",
    "1. Disable Actions for the repo (cheapest, bluntest):",
    "   `gh api -X PUT repos/" + alert.repository + "/actions/permissions`",
    "   with body `{\"enabled\": false}`. The registration stays; the",
    "   billing stops.",
    "2. Delete the orphan registration (surgical):",
    "   `gh api -X DELETE repos/" + alert.repository + "/actions/workflows/" + alert.workflow_id + "`",
    "   Requires Admin perms; the nishfleet-worker App token does not have it.",
    "3. Restore the file (if the file was lost, not the workflow): push",
    "   the YAML back to the default branch at the declared path. The",
    "   registration auto-recovers on first run.",
    "",
    "## Detection mechanism (prevention)",
    "",
    "This issue is filed by the orphan-workflow detector at",
    "`.github/scripts/orphan-workflow-detector.mjs` (reusable workflow",
    "`.github/workflows/orphan-workflow-detector.yml`). The detector",
    "scans every ACTIVE registration in `actions/workflows` and probes",
    "the contents API for the declared path. A 404 is the orphan class.",
    "Keep this issue open until the orphan is resolved; the detector",
    "will reuse the open issue on re-runs (no comment spam).",
    "",
    COMMENT_MARKER_PREFIX + " " + alert.repository + " " + alert.workflow_id + " -->",
  ].join("\n");
}

/**
 * Find the open issue (if any) carrying the same orphan marker.
 *
 * @param {string} repository
 * @param {number} workflowId
 * @returns {number | null}
 */
function findExistingIssue(repository, workflowId) {
  const marker = `${COMMENT_MARKER_PREFIX} ${repository} ${workflowId} -->`;
  try {
    const raw = execFileSync(
      "gh",
      [
        "issue",
        "list",
        "-R",
        repository,
        "--state",
        "open",
        "--label",
        LABEL,
        "--limit",
        "100",
        "--json",
        "number,body",
      ],
      { encoding: "utf8", timeout: 60_000 },
    );
    const items = JSON.parse(raw);
    if (!Array.isArray(items)) return null;
    for (const item of items) {
      if (item && typeof item.body === "string" && item.body.includes(marker)) {
        return typeof item.number === "number" ? item.number : null;
      }
    }
  } catch {
    // Fall through: list may fail (no label yet, no permission).
  }
  return null;
}

/**
 * Ensure the detector label exists. Idempotent.
 *
 * @param {string} repository
 */
function ensureLabel(repository) {
  try {
    execFileSync(
      "gh",
      [
        "label",
        "create",
        LABEL,
        "-R",
        repository,
        "--color",
        "D93F0B",
        "--description",
        "Active workflow registration whose file is missing on the default branch (auto-filed by orphan-workflow-detector).",
        "--force",
      ],
      { encoding: "utf8", timeout: 30_000 },
    );
  } catch {
    // Label may already exist or be managed by a higher-level sync; not
    // fatal — the issue-create path retries without the label.
  }
}

/**
 * File (or reuse) an issue for an orphan alert.
 *
 * @param {OrphanAlert} alert
 * @param {{ noIssue?: boolean }} [opts]
 */
function emitIssue(alert, opts = {}) {
  if (opts.noIssue) {
    console.error(`would file ${alert.repository}#? for orphan ${alert.path}`);
    return;
  }
  ensureLabel(alert.repository);
  const existing = findExistingIssue(alert.repository, alert.workflow_id);
  if (existing) {
    console.error(
      `reused ${alert.repository}#${existing} for orphan ${alert.path}`,
    );
    return;
  }
  const payload = JSON.stringify({
    title: issueTitle(alert),
    body: issueBody(alert),
    labels: [LABEL],
  });
  try {
    const stdout = execFileSync(
      "gh",
      ["api", "-X", "POST", `repos/${alert.repository}/issues`, "--input", "-"],
      { encoding: "utf8", input: payload, timeout: 60_000 },
    );
    const created = JSON.parse(stdout);
    console.error(
      `created ${alert.repository}#${created.number} for orphan ${alert.path}`,
    );
  } catch (labelError) {
    // Retry without label (label may be protected / org-locked).
    try {
      const unlabeled = JSON.stringify({
        title: issueTitle(alert),
        body: issueBody(alert),
      });
      const stdout = execFileSync(
        "gh",
        ["api", "-X", "POST", `repos/${alert.repository}/issues`, "--input", "-"],
        { encoding: "utf8", input: unlabeled, timeout: 60_000 },
      );
      const created = JSON.parse(stdout);
      console.error(
        `created ${alert.repository}#${created.number} for orphan ${alert.path} (without label)`,
      );
    } catch (fallbackError) {
      console.error(
        `issue_create_failed on ${alert.repository} (workflow ${alert.workflow_id}): ` +
          `${labelError instanceof Error ? labelError.message : String(labelError)} :: ` +
          `fallback ${
            fallbackError instanceof Error ? fallbackError.message : String(fallbackError)
          }`,
      );
    }
  }
}

/**
 * Fetch registered workflows for a repo.
 *
 * @param {string} repository
 * @returns {RegisteredWorkflow[]}
 */
function fetchWorkflows(repository) {
  const raw = ghJson([
    `repos/${repository}/actions/workflows`,
    "--jq",
    ".workflows",
  ]);
  if (!Array.isArray(raw)) return [];
  return raw
    .map((w) => {
      if (!w || typeof w !== "object") return null;
      const wf = /** @type {Record<string, unknown>} */ (w);
      if (
        typeof wf.id !== "number" ||
        typeof wf.name !== "string" ||
        typeof wf.path !== "string" ||
        typeof wf.state !== "string"
      ) {
        return null;
      }
      return /** @type {RegisteredWorkflow} */ (wf);
    })
    .filter((w) => w !== null);
}

/**
 * Probe whether Actions is enabled for a repo (best-effort).
 *
 * @param {string} repository
 * @returns {Promise<boolean | null>}
 */
async function fetchActionsEnabled(repository) {
  try {
    const raw = ghJson([
      `repos/${repository}/actions/permissions`,
      "--jq",
      ".enabled",
    ]);
    if (raw === true) return true;
    if (raw === false) return false;
    return null;
  } catch {
    return null;
  }
}

/**
 * Run a single repo end-to-end.
 *
 * @param {string} repository
 * @param {{ noIssue?: boolean }} [opts]
 * @returns {Promise<OrphanAlert[]>}
 */
async function scanRepository(repository, opts = {}) {
  const workflows = filterProbableOrphans(fetchWorkflows(repository));
  if (workflows.length === 0) return [];
  const actionsEnabled = await fetchActionsEnabled(repository);
  /** @type {OrphanAlert[]} */
  const alerts = [];
  for (const wf of workflows) {
    const state = await fileExists(repository, wf.path);
    if (isOrphan(wf, state)) {
      const alert = buildAlert(repository, wf, actionsEnabled);
      alerts.push(alert);
      emitIssue(alert, opts);
    }
  }
  return alerts;
}

/**
 * Default target set: the private repos that the 2026-08-27 audit
 * flagged. The detector also accepts `--repos-from <file>` so the
 * reusable workflow can hand it a JSON list of additional private
 * repos to scan.
 */
const DEFAULT_TARGETS = [
  "Nishfleet/fleet2",
  "Nishfleet/egress-probe",
  "Nishfleet/0509-telemetry",
  "Nishfleet/siterep",
];

function printUsage() {
  console.log(`Usage: orphan-workflow-detector.mjs [options]

Options:
  --repo <owner/name>       Scan a single repository
  --repos-from <path>       JSON file with a "repositories" array of owner/name
  --from-json <path>        Replay stored checks (no GitHub)
  --format <human|json>     Output format (default: human)
  --output-json <path>      Also write the report JSON to this file
  --no-issue                Skip opening or commenting on issues
  --help                    Show this message
`);
}

function parseArgs(argv) {
  const args = {
    repo: "",
    reposFrom: "",
    fromJson: "",
    format: "human",
    outputJson: "",
    noIssue: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else if (arg === "--repo") {
      args.repo = argv[++i] ?? "";
    } else if (arg === "--repos-from") {
      args.reposFrom = argv[++i] ?? "";
    } else if (arg === "--from-json") {
      args.fromJson = argv[++i] ?? "";
    } else if (arg === "--format") {
      args.format = (argv[++i] ?? "human").toLowerCase();
    } else if (arg === "--output-json") {
      args.outputJson = argv[++i] ?? "";
    } else if (arg === "--no-issue") {
      args.noIssue = true;
    } else if (arg && !arg.startsWith("-")) {
      args.repo = arg;
    }
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  /** @type {string[]} */
  let repositories = [];
  let presetAlerts = null;
  if (args.fromJson) {
    const payload = JSON.parse(readFileSync(resolve(args.fromJson), "utf8"));
    const checks = checksFromFixture(payload);
    presetAlerts = [];
    for (const c of checks) {
      if (isOrphan(c.workflow, c.file_state)) {
        presetAlerts.push(buildAlert(c.repository, c.workflow, null));
      }
    }
  } else if (args.repo) {
    repositories = [args.repo];
  } else if (args.reposFrom) {
    const payload = JSON.parse(readFileSync(resolve(args.reposFrom), "utf8"));
    if (payload && Array.isArray(payload.repositories)) {
      repositories = payload.repositories
        .map((r) => (typeof r === "string" ? r : null))
        .filter((r) => r !== null);
    }
  } else {
    repositories = [...DEFAULT_TARGETS];
  }
  /** @type {OrphanAlert[]} */
  let alerts = [];
  if (presetAlerts) {
    alerts = presetAlerts;
    if (!args.noIssue) {
      for (const a of alerts) emitIssue(a, { noIssue: args.noIssue });
    }
  } else {
    for (const repository of repositories) {
      try {
        const repoAlerts = await scanRepository(repository, { noIssue: args.noIssue });
        alerts = alerts.concat(repoAlerts);
      } catch (error) {
        console.error(
          `scan_failed on ${repository}: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
      }
    }
  }
  alerts = collapseAlerts(alerts);
  if (args.format === "json") {
    const report = { alerts, scanned_repositories: repositories };
    const json = JSON.stringify(report, null, 2);
    console.log(json);
    if (args.outputJson) {
      writeFileSync(resolve(args.outputJson), json + "\n", "utf8");
    }
  } else {
    console.log(`orphan-workflow-detector: ${alerts.length} orphan(s) found`);
    for (const a of alerts) {
      console.log("");
      console.log(renderAlert(a));
    }
  }
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
