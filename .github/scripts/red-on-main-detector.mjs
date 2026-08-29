#!/usr/bin/env node
// Red-on-main detector (fleet-ops central reusable set).
//
// Watches every workflow on main, not just an allowlisted set. A workflow
// whose first ever main run fails is a distinct, high-signal case: it was
// likely merged untested against main. Alert, do not auto-revert, until the
// workflow has a green baseline.
//
// Surface: gh CLI + GitHub REST API only. No paid services.

import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_LOOKBACK_MINUTES = 60;
const DEFAULT_PAGE_SIZE = 100;
const LABEL = "red-on-main";
const COMMENT_MARKER_PREFIX = "<!-- red-on-main-detector:";

// The detector workflow itself should not alert on its own failures.
// "Auto revert" is skipped too: its job is to revert a red commit or halt
// (exit 1 by design, filing a HALT issue) when a revert is unsafe. That red
// is an expected halt signal, not a workflow regression on main; flagging it
// spawns recurring noise (fleet-ops#155, #596, #1482). The halt issue itself
// is the loud surface.
const SKIP_WORKFLOWS = new Set([
  "Red on main detector",
  "red-on-main-detector",
  "Red on main watch",
  "red-on-main-watch",
  "Auto revert",
]);

/**
 * @typedef {{
 *   id: number,
 *   name: string,
 *   workflow_id: number,
 *   event: string | null,
 *   conclusion: string | null,
 *   head_branch: string | null,
 *   head_sha: string,
 *   created_at: string,
 *   html_url: string,
 *   pull_request_numbers?: number[],
 *   pull_requests?: Array<{ number: number }>,
 * }} WorkflowRun
 *
 * @typedef {{
 *   status: "first-ever" | "never-green" | "established-red",
 *   repository: string,
 *   workflow: string,
 *   workflow_id: number,
 *   run_id: number,
 *   run_url: string,
 *   head_branch: string | null,
 *   head_sha: string,
 *   short_sha: string,
 *   event: string | null,
 *   created_at: string,
 *   prior_run_count: number,
 *   has_green_baseline: boolean,
 * }} RedAlert
 */

/**
 * @param {string} command
 * @param {string[]} args
 * @param {{ timeoutMs?: number, input?: string }} [opts]
 * @returns {string}
 */
function execGh(command, args, opts = {}) {
  try {
    return execFileSync(command, args, {
      encoding: "utf8",
      env: process.env,
      maxBuffer: 64 * 1024 * 1024,
      timeout: opts.timeoutMs ?? 90_000,
      stdio: ["ignore", "pipe", "pipe"],
      input: opts.input,
    });
  } catch (error) {
    const failure = /** @type {{ message?: unknown, stderr?: unknown, stdout?: unknown }} */ (
      error
    );
    const detail = [failure.message, failure.stderr, failure.stdout]
      .map((part) => (part ? String(part) : ""))
      .filter((part) => part.trim().length > 0)
      .join(" | ");
    throw new Error(
      `red_on_main_exec_failed: ${command} ${args.join(" ")} :: ${detail.slice(0, 800)}`,
    );
  }
}

/**
 * @param {string} endpoint
 * @param {string} jq
 * @param {{ paginate?: boolean, timeoutMs?: number, query?: Record<string, string | number> }} [opts]
 * @returns {unknown}
 */
function ghApiJson(endpoint, jq, opts = {}) {
  const args = [
    "api",
    "--header",
    "Accept: application/vnd.github+json",
    "--header",
    "X-GitHub-Api-Version: 2022-11-28",
  ];
  if (opts.paginate) args.push("--paginate");
  let url = endpoint;
  if (opts.query) {
    const params = new URLSearchParams();
    for (const [k, v] of Object.entries(opts.query)) params.set(k, String(v));
    const qs = params.toString();
    if (qs) url += (endpoint.includes("?") ? "&" : "?") + qs;
  }
  args.push(url);
  if (jq) args.push("--jq", jq);
  const stdout = execGh("gh", args, { timeoutMs: opts.timeoutMs ?? 90_000 });
  if (!stdout.trim()) return null;
  if (opts.paginate) {
    const out = [];
    for (const line of stdout.split(/\r?\n/u)) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        out.push(JSON.parse(trimmed));
      } catch {
        // Skip stray warning text; well-formed run objects parse cleanly.
      }
    }
    return out;
  }
  return JSON.parse(stdout);
}

/**
 * @param {unknown} payload
 * @returns {WorkflowRun[]}
 */
function runsFromFixture(payload) {
  if (Array.isArray(payload)) return /** @type {WorkflowRun[]} */ (payload);
  if (payload && typeof payload === "object") {
    const obj = /** @type {{ runs?: unknown, run?: unknown, previous_runs?: unknown }} */ (payload);
    if (Array.isArray(obj.runs)) return /** @type {WorkflowRun[]} */ (obj.runs);
    if (obj.run && typeof obj.run === "object") {
      const run = /** @type {WorkflowRun} */ (obj.run);
      const previous = Array.isArray(obj.previous_runs) ? /** @type {WorkflowRun[]} */ (obj.previous_runs) : [];
      return [run, ...previous];
    }
  }
  throw new Error("red_on_main_fixture_invalid: expected {runs: [...]} or {run, previous_runs}");
}

/**
 * @param {unknown} value
 * @returns {string}
 */
function jqString(value) {
  return JSON.stringify(String(value ?? ""));
}

/**
 * @param {string | null | undefined} name
 * @returns {boolean}
 */
export function isSkippedWorkflow(name) {
  if (!name) return false;
  return SKIP_WORKFLOWS.has(name);
}

/**
 * Fetch recent failed workflow runs on the main branch.
 *
 * `status=failure` is required: `status=completed` on a busy repo fills the
 * page with green runs and the first-ever red run falls off the end.
 *
 * @param {string} repository
 * @param {Date} since
 * @returns {WorkflowRun[]}
 */
function fetchFailedMainRuns(repository, since) {
  const sinceIso = since.toISOString();
  const raw = ghApiJson(
    `repos/${repository}/actions/runs`,
    `.workflow_runs[]? | select(.created_at >= ${jqString(sinceIso)}) | ` +
      `{id: .id, name: .name, workflow_id: .workflow_id, event: .event, ` +
      `conclusion: .conclusion, head_branch: .head_branch, head_sha: .head_sha, ` +
      `created_at: .created_at, html_url: .html_url, ` +
      `pull_request_numbers: [.pull_requests[]?.number], pull_requests: .pull_requests}`,
    {
      paginate: true,
      query: {
        per_page: DEFAULT_PAGE_SIZE,
        branch: "main",
        status: "failure",
        created: `>=${sinceIso}`,
      },
      timeoutMs: 180_000,
    },
  );
  const runs = Array.isArray(raw) ? raw : [];
  return runs.filter(
    (r) =>
      r &&
      r.conclusion === "failure" &&
      r.head_branch === "main" &&
      !isSkippedWorkflow(r.name),
  );
}

/**
 * Fetch the up to `perPage` completed main runs of a workflow created before
 * the reference run. This is the local history used to classify the run.
 *
 * @param {string} repository
 * @param {WorkflowRun} run
 * @param {number} perPage
 * @returns {WorkflowRun[]}
 */
function fetchPreviousRuns(repository, run, perPage = DEFAULT_PAGE_SIZE) {
  const beforeIso = run.created_at;
  const workflowId = run.workflow_id;
  if (!workflowId) return [];
  // List-runs-for-a-repository has no workflow_id query. History has to
  // come from the per-workflow endpoint or every workflow's past is mixed.
  const raw = ghApiJson(
    `repos/${repository}/actions/workflows/${workflowId}/runs`,
    `[.workflow_runs[]? | select(.created_at < ${jqString(beforeIso)}) | ` +
      `{id: .id, name: .name, workflow_id: .workflow_id, event: .event, ` +
      `conclusion: .conclusion, head_branch: .head_branch, head_sha: .head_sha, ` +
      `created_at: .created_at, html_url: .html_url, ` +
      `pull_request_numbers: [.pull_requests[]?.number], pull_requests: .pull_requests}]`,
    {
      paginate: false,
      query: {
        per_page: perPage,
        branch: "main",
        status: "completed",
        created: `<${beforeIso}`,
      },
      timeoutMs: 60_000,
    },
  );
  const runs = Array.isArray(raw) ? raw : [];
  return runs.filter(
    (r) =>
      r &&
      r.id !== run.id &&
      r.created_at < beforeIso &&
      r.head_branch === "main",
  );
}

/**
 * @param {WorkflowRun} run
 * @param {WorkflowRun[]} previousRuns
 * @returns {RedAlert["status"]}
 */
export function classifyFailure(run, previousRuns) {
  const older = previousRuns.filter(
    (r) => r && r.id !== run.id && r.created_at < run.created_at,
  );
  if (older.length === 0) return "first-ever";
  const green = older.some((r) => r.conclusion === "success");
  if (green) return "established-red";
  return "never-green";
}

/**
 * @param {WorkflowRun} run
 * @param {WorkflowRun[]} previousRuns
 * @param {string} repository
 * @returns {RedAlert}
 */
export function buildAlert(run, previousRuns, repository) {
  const older = previousRuns.filter(
    (r) => r && r.id !== run.id && r.created_at < run.created_at,
  );
  const status = classifyFailure(run, previousRuns);
  return {
    status,
    repository,
    workflow: run.name,
    workflow_id: run.workflow_id,
    run_id: run.id,
    run_url: run.html_url,
    head_branch: run.head_branch,
    head_sha: run.head_sha,
    short_sha: typeof run.head_sha === "string" ? run.head_sha.slice(0, 7) : "",
    event: run.event,
    created_at: run.created_at,
    prior_run_count: older.length,
    has_green_baseline: status === "established-red",
  };
}

/**
 * @param {WorkflowRun[]} runs
 * @param {string} repository
 * @returns {RedAlert[]}
 */
export function buildAlerts(runs, repository) {
  const list = Array.isArray(runs) ? runs : [];
  const mainFailures = list.filter(
    (r) =>
      r &&
      r.conclusion === "failure" &&
      r.head_branch === "main" &&
      !isSkippedWorkflow(r.name),
  );
  mainFailures.sort((a, b) => (a.created_at < b.created_at ? -1 : 1));

  /** @type {RedAlert[]} */
  const alerts = [];
  for (const run of mainFailures) {
    const previous = list.filter(
      (r) =>
        r &&
        r.id !== run.id &&
        r.created_at < run.created_at &&
        (r.workflow_id === run.workflow_id || r.name === run.name) &&
        r.head_branch === "main",
    );
    alerts.push(buildAlert(run, previous, repository));
  }
  return alerts;
}

/**
 * One open issue per workflow per tick. Keep the newest run URL, but keep
 * the loudest status (first-ever beats never-green beats established-red)
 * so a brand-new workflow that fails twice in the lookback still says
 * "first ever".
 *
 * @param {RedAlert[]} alerts
 * @returns {RedAlert[]}
 */
export function collapseAlerts(alerts) {
  const rank = { "first-ever": 0, "never-green": 1, "established-red": 2 };
  /** @type {Map<string, RedAlert>} */
  const byWorkflow = new Map();
  for (const alert of alerts) {
    const key = `${alert.workflow_id}:${alert.workflow}`;
    const prev = byWorkflow.get(key);
    if (!prev) {
      byWorkflow.set(key, { ...alert });
      continue;
    }
    const merged = { ...prev };
    if ((rank[alert.status] ?? 9) < (rank[prev.status] ?? 9)) {
      merged.status = alert.status;
      merged.has_green_baseline = merged.status === "established-red";
    }
    if (alert.created_at > prev.created_at) {
      merged.run_id = alert.run_id;
      merged.run_url = alert.run_url;
      merged.head_sha = alert.head_sha;
      merged.short_sha = alert.short_sha;
      merged.created_at = alert.created_at;
      merged.event = alert.event;
    }
    merged.prior_run_count = Math.min(merged.prior_run_count, alert.prior_run_count);
    byWorkflow.set(key, merged);
  }
  return [...byWorkflow.values()];
}

/**
 * @param {RedAlert} alert
 * @returns {string}
 */
export function renderAlert(alert) {
  if (alert.status === "first-ever") {
    return (
      `Workflow "${alert.workflow}" failed on its first ever run on main.` +
      ` This likely means it was merged untested against main. Run: ${alert.run_url}`
    );
  }
  if (alert.status === "never-green") {
    return (
      `Workflow "${alert.workflow}" has failed on main` +
      ` and has never had a green baseline (prior runs: ${alert.prior_run_count}).` +
      ` Run: ${alert.run_url}`
    );
  }
  return (
    `Workflow "${alert.workflow}" went red on main after a previous green baseline.` +
    ` Run: ${alert.run_url}`
  );
}

/**
 * @param {{
 *   generated_at: string,
 *   repository: string,
 *   lookback_minutes: number,
 *   runs_sampled: number,
 *   alerts: RedAlert[],
 * }} report
 * @returns {string}
 */
export function renderReport(report) {
  const lines = [];
  lines.push(`Red-on-main detector — ${report.repository}`);
  lines.push(
    `Sampled ${report.runs_sampled} failed main runs over ${report.lookback_minutes}m` +
      ` at ${report.generated_at}`,
  );
  lines.push("");
  if (report.alerts.length === 0) {
    lines.push("Red-on-main alerts: none");
  } else {
    lines.push(`Red-on-main alerts: ${report.alerts.length}`);
    for (const alert of report.alerts) {
      lines.push(`  - ${renderAlert(alert)}`);
      lines.push(`      status:    ${alert.status}`);
      lines.push(`      commit:    ${alert.short_sha}`);
    }
  }
  return lines.join("\n");
}

/**
 * @param {{
 *   generated_at: string,
 *   repository: string,
 *   lookback_minutes: number,
 *   runs_sampled: number,
 *   alerts: RedAlert[],
 * }} report
 * @param {boolean} emit
 */
export function emitGithubAnnotations(report, emit) {
  if (!emit) return;
  for (const alert of report.alerts) {
    const msg = renderAlert(alert).replace(/\r?\n/gu, " ");
    console.error(`::warning title=RED-ON-MAIN::${msg}`);
  }
}

/**
 * @param {RedAlert} alert
 * @returns {string}
 */
export function issueTitle(alert) {
  return `red-on-main: ${alert.workflow} (${alert.status})`;
}

/**
 * @param {RedAlert} alert
 * @returns {string}
 */
export function issueBody(alert) {
  const marker = `${COMMENT_MARKER_PREFIX}workflow=${alert.workflow} -->`;
  const statusText =
    alert.status === "first-ever"
      ? "First ever main run failed"
      : alert.status === "never-green"
        ? "No green baseline yet"
        : "Established workflow went red on main";

  const explanation =
    alert.status === "first-ever"
      ? "This is the workflow's **first ever run on main**, and it failed. It was likely merged untested against main."
      : alert.status === "never-green"
        ? `This workflow has run on main before but has **never succeeded** (prior runs: ${alert.prior_run_count}). It has no green baseline.`
        : "This workflow has a previous green baseline; it went red on this run.";

  return [
    marker,
    "",
    `**${statusText}**`,
    "",
    `- Workflow: \`${alert.workflow}\``,
    `- Run: ${alert.run_url}`,
    `- Commit: \`${alert.short_sha}\` (${alert.head_sha})`,
    `- Branch: \`${alert.head_branch ?? "unknown"}\``,
    `- Trigger event: \`${alert.event ?? "unknown"}\``,
    `- Previous main runs: ${alert.prior_run_count}`,
    `- Green baseline: ${alert.has_green_baseline ? "yes" : "no"}`,
    "",
    explanation,
    "",
    "Do not auto-revert on this signal. Alerting is the correct response until the workflow has a green baseline.",
  ].join("\n");
}

/**
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
        "--repo",
        repository,
        "--color",
        "B60205",
        "--description",
        "A workflow is red on main",
        "--force",
      ],
      { encoding: "utf8", env: process.env, stdio: ["ignore", "pipe", "pipe"], timeout: 30_000 },
    );
  } catch {
    // The label may already exist or the token may not have label permission.
    // The issue search still uses the title as a fallback.
  }
}

/**
 * @param {string} repository
 * @param {string} workflow
 * @returns {number | null}
 */
function findExistingIssue(repository, workflow) {
  const marker = `${COMMENT_MARKER_PREFIX}workflow=${workflow}`;
  try {
    const stdout = execFileSync(
      "gh",
      [
        "issue",
        "list",
        "--repo",
        repository,
        "--state",
        "open",
        "--label",
        LABEL,
        "--limit",
        "100",
        "--json",
        "number,body",
        "--jq",
        ".[]",
      ],
      { encoding: "utf8", env: process.env, maxBuffer: 64 * 1024 * 1024, timeout: 60_000 },
    );
    for (const line of stdout.split(/\r?\n/u)) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const issue = JSON.parse(trimmed);
        if (
          typeof issue.body === "string" &&
          issue.body.includes(marker) &&
          Number.isFinite(issue.number)
        ) {
          return Number(issue.number);
        }
      } catch {
        // Ignore stray lines.
      }
    }
  } catch {
    // List may fail (no label, no issues, no permission). Fall through.
  }
  return null;
}

/**
 * @param {string} repository
 * @param {RedAlert} alert
 */
function ensureIssue(repository, alert) {
  ensureLabel(repository);
  const existing = findExistingIssue(repository, alert.workflow);
  const title = issueTitle(alert);
  const body = issueBody(alert);

  if (existing) {
    // Reuse the open issue. Do not comment on every 15-minute sweep — the
    // open issue is the alert until a human closes it.
    console.error(`reused ${repository}#${existing} for red-on-main: ${alert.workflow}`);
    return;
  }

  const payload = JSON.stringify({ title, body, labels: [LABEL] });
  try {
    const stdout = execFileSync(
      "gh",
      ["api", "-X", "POST", `repos/${repository}/issues`, "--input", "-"],
      { encoding: "utf8", env: process.env, input: payload, timeout: 60_000 },
    );
    const created = JSON.parse(stdout);
    console.error(`created ${repository}#${created.number} for red-on-main: ${alert.workflow}`);
  } catch (error) {
    try {
      const unlabeled = JSON.stringify({ title, body });
      const stdout = execFileSync(
        "gh",
        ["api", "-X", "POST", `repos/${repository}/issues`, "--input", "-"],
        { encoding: "utf8", env: process.env, input: unlabeled, timeout: 60_000 },
      );
      const created = JSON.parse(stdout);
      console.error(
        `created ${repository}#${created.number} for red-on-main: ${alert.workflow} (without label)`,
      );
    } catch (fallbackError) {
      console.error(
        `issue_create_failed on ${repository}: ${
          error instanceof Error ? error.message : String(error)
        } :: fallback ${
          fallbackError instanceof Error ? fallbackError.message : String(fallbackError)
        }`,
      );
    }
  }
}

/**
 * @param {string} repository
 * @param {RedAlert[]} alerts
 */
function emitIssues(repository, alerts) {
  for (const alert of alerts) {
    try {
      ensureIssue(repository, alert);
    } catch (error) {
      console.error(
        `ensure_issue_failed for ${alert.workflow}: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }
}

function printUsage() {
  console.log(`Usage: red-on-main-detector.mjs [options]

Options:
  --repo <owner/name>       Target repository (default: env RED_ON_MAIN_REPO)
  --lookback-minutes <n>    Minutes of recent failed main runs to sample (default: ${DEFAULT_LOOKBACK_MINUTES})
  --from-json <path>        Replay stored runs (no GitHub). Fixture tests use this.
  --format <human|json>     Output format (default: human)
  --output-json <path>      Also write the report JSON to this file
  --no-issue                Skip opening or commenting on issues
  --help                    Show this message
`);
}

function parseArgs(argv) {
  const args = {
    repo: process.env.RED_ON_MAIN_REPO ?? "",
    lookbackMinutes: Number(process.env.RED_ON_MAIN_LOOKBACK_MINUTES) || DEFAULT_LOOKBACK_MINUTES,
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
    } else if (arg === "--lookback-minutes") {
      args.lookbackMinutes = Math.max(1, Number(argv[++i]) || DEFAULT_LOOKBACK_MINUTES);
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
  if (!args.repo && !args.fromJson) {
    console.error("Missing required --repo / RED_ON_MAIN_REPO or --from-json");
    printUsage();
    process.exit(2);
  }
  return args;
}



async function main() {
  const args = parseArgs(process.argv.slice(2));
  const now = new Date();

  /** @type {RedAlert[]} */
  let alerts;
  let repository = args.repo;
  let runsSampled = 0;

  if (args.fromJson) {
    const payload = JSON.parse(readFileSync(resolve(args.fromJson), "utf8"));
    if (!repository && payload && typeof payload === "object" && payload.repository) {
      repository = String(payload.repository);
    }
    if (!repository) repository = "fixture";
    if (payload && typeof payload === "object" && payload.run) {
      const run = /** @type {WorkflowRun} */ (payload.run);
      const previous = Array.isArray(payload.previous_runs)
        ? /** @type {WorkflowRun[]} */ (payload.previous_runs)
        : [];
      runsSampled = 1 + previous.length;
      alerts =
        run.conclusion === "failure" &&
        run.head_branch === "main" &&
        !isSkippedWorkflow(run.name)
          ? [buildAlert(run, previous, repository)]
          : [];
    } else {
      const runs = runsFromFixture(payload);
      runsSampled = runs.length;
      alerts = collapseAlerts(buildAlerts(runs, repository));
    }
  } else {
    const since = new Date(now.getTime() - args.lookbackMinutes * 60 * 1000);
    const failedRuns = fetchFailedMainRuns(repository, since);
    runsSampled = failedRuns.length;

    /** @type {RedAlert[]} */
    const built = [];
    for (const run of failedRuns) {
      if (isSkippedWorkflow(run.name)) continue;
      const previous = fetchPreviousRuns(repository, run);
      built.push(buildAlert(run, previous, repository));
    }
    built.sort((a, b) => (a.created_at < b.created_at ? -1 : 1));
    alerts = collapseAlerts(built);
  }

  const report = {
    generated_at: now.toISOString(),
    repository,
    lookback_minutes: args.lookbackMinutes,
    runs_sampled: runsSampled,
    alerts,
  };

  const json = JSON.stringify(report, null, 2);
  const human = renderReport(report);
  console.log(args.format === "json" ? json : human);

  emitGithubAnnotations(report, Boolean(process.env.GITHUB_ACTIONS));
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n${human}\n`);
  }
  if (args.outputJson) writeFileSync(resolve(args.outputJson), json);

  if (process.env.GITHUB_OUTPUT) {
    const lines = [
      `alerts=${alerts.length}`,
      `runs-sampled=${runsSampled}`,
    ];
    appendFileSync(process.env.GITHUB_OUTPUT, `${lines.join("\n")}\n`);
  }

  if (!args.fromJson && !args.noIssue) {
    // ensureIssue searches for an existing open issue per workflow and creates
    // or comments. Multiple failures for the same workflow in one run will
    // update the same issue.
    emitIssues(repository, alerts);
  }
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
