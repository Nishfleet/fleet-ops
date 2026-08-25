#!/usr/bin/env node
// Merge-queue semantic-conflict detector (fleet-ops central reusable set).
//
// The mechanical signal needs no knowledge of a check's contents:
//   the same check, for the same PR, passed on pull_request (or
//   pull_request_target) and failed on merge_group.
//
// That is a semantic merge conflict: the PR is green in isolation and
// collides with the batch. Re-queueing cannot fix it.
//
// Surface: gh CLI + GitHub REST API only. No paid services.

import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_LOOKBACK_HOURS = 24;
const DEFAULT_PAGE_SIZE = 100;
const ISOLATION_EVENTS = new Set(["pull_request", "pull_request_target"]);
const BATCH_EVENT = "merge_group";
const FETCH_EVENTS = ["pull_request", "pull_request_target", "merge_group"];
const COMPLETED = new Set(["success", "failure"]);
const COMMENT_MARKER = "<!-- semantic-merge-conflict-detector -->";

/**
 * @typedef {{
 *   id: number,
 *   name: string,
 *   event: string,
 *   conclusion: string | null,
 *   head_branch: string | null,
 *   head_sha: string,
 *   created_at: string,
 *   html_url: string,
 *   pull_request_numbers?: number[],
 *   pull_requests?: Array<{ number: number }>,
 *   failed_jobs?: string[],
 * }} WorkflowRun
 *
 * @typedef {{
 *   pr: number,
 *   check: string,
 *   workflow: string,
 *   isolation_event: string,
 *   isolation_run_id: number,
 *   isolation_url: string,
 *   batch_run_id: number,
 *   batch_url: string,
 *   batch_failure_count: number,
 * }} SemanticConflict
 */

/**
 * @param {string} command
 * @param {string[]} args
 * @param {{ timeoutMs?: number }} [opts]
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
      `semantic_conflict_exec_failed: ${command} ${args.join(" ")} :: ${detail.slice(0, 800)}`,
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
 * Pull the PR number off a workflow run. Merge-queue runs do not populate
 * `pull_requests`; their head_branch is `gh-readonly-queue/<base>/pr-<N>-<sha>`.
 *
 * @param {WorkflowRun} run
 * @returns {number | null}
 */
export function extractPrNumber(run) {
  const fromField = Array.isArray(run.pull_request_numbers) ? run.pull_request_numbers : [];
  if (fromField.length > 0 && Number.isFinite(fromField[0])) return Number(fromField[0]);
  const fromEmbed = Array.isArray(run.pull_requests)
    ? run.pull_requests.map((pr) => pr && pr.number).filter((n) => Number.isFinite(n))
    : [];
  if (fromEmbed.length > 0) return Number(fromEmbed[0]);
  const branch = run.head_branch ?? "";
  const queue = branch.match(/gh-readonly-queue\/[^/]+\/pr-(\d+)-/u);
  if (queue) return Number(queue[1]);
  const pullRef = branch.match(/^refs\/pull\/(\d+)\//u);
  if (pullRef) return Number(pullRef[1]);
  return null;
}

/**
 * @param {WorkflowRun} run
 * @returns {WorkflowRun}
 */
export function normalizeRun(run) {
  const pr = extractPrNumber(run);
  return {
    ...run,
    pull_request_numbers: pr === null ? [] : [pr],
    failed_jobs: Array.isArray(run.failed_jobs)
      ? run.failed_jobs.filter((name) => typeof name === "string" && name.length > 0)
      : [],
  };
}

/**
 * @param {WorkflowRun[]} runs
 * @returns {Array<{ event: string, total: number, failed: number, rate_pct: number }>}
 */
export function eventFailureRates(runs) {
  const byEvent = new Map();
  for (const run of runs) {
    if (!COMPLETED.has(run.conclusion ?? "")) continue;
    const event = run.event ?? "unknown";
    const bucket = byEvent.get(event) ?? { total: 0, failed: 0 };
    bucket.total += 1;
    if (run.conclusion === "failure") bucket.failed += 1;
    byEvent.set(event, bucket);
  }
  const preferred = ["pull_request", "merge_group"];
  const events = [
    ...preferred.filter((e) => byEvent.has(e)),
    ...Array.from(byEvent.keys()).filter((e) => !preferred.includes(e)),
  ];
  return events.map((event) => {
    const b = byEvent.get(event) ?? { total: 0, failed: 0 };
    return {
      event,
      total: b.total,
      failed: b.failed,
      rate_pct: b.total > 0 ? Number(((b.failed / b.total) * 100).toFixed(1)) : 0,
    };
  });
}

/**
 * @param {ReturnType<typeof eventFailureRates>} rates
 * @returns {number | null}
 */
export function divergencePct(rates) {
  const pr = rates.find((r) => r.event === "pull_request");
  const mg = rates.find((r) => r.event === "merge_group");
  if (!pr || !mg) return null;
  return Number((mg.rate_pct - pr.rate_pct).toFixed(1));
}

/**
 * Same check, same PR: latest isolation run is green, and at least one
 * merge_group run is red. Stays quiet when the latest isolation run is red
 * (the PR is bad on its own — not a batch collision).
 *
 * @param {WorkflowRun[]} runs
 * @returns {SemanticConflict[]}
 */
export function detectSemanticConflicts(runs) {
  /** @type {Map<string, WorkflowRun[]>} */
  const groups = new Map();
  for (const raw of runs) {
    const run = normalizeRun(raw);
    if (!COMPLETED.has(run.conclusion ?? "")) continue;
    const pr = extractPrNumber(run);
    if (pr === null) continue;
    const key = `${pr}\u241F${run.name}`;
    const list = groups.get(key) ?? [];
    list.push(run);
    groups.set(key, list);
  }

  /** @type {SemanticConflict[]} */
  const conflicts = [];
  for (const [key, list] of groups) {
    const isolation = list
      .filter((r) => ISOLATION_EVENTS.has(r.event))
      .sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
    const batch = list.filter((r) => r.event === BATCH_EVENT);
    const latestIsolation = isolation[0];
    if (!latestIsolation || latestIsolation.conclusion !== "success") continue;
    const batchFailures = batch
      .filter((r) => r.conclusion === "failure")
      .sort((a, b) => (a.created_at < b.created_at ? 1 : -1));
    if (batchFailures.length === 0) continue;

    const [prStr, workflow] = key.split("\u241F");
    const latestBatchFail = batchFailures[0];
    const jobNames =
      latestBatchFail.failed_jobs && latestBatchFail.failed_jobs.length > 0
        ? latestBatchFail.failed_jobs
        : [workflow];
    for (const check of jobNames) {
      conflicts.push({
        pr: Number(prStr),
        check,
        workflow,
        isolation_event: latestIsolation.event,
        isolation_run_id: latestIsolation.id,
        isolation_url: latestIsolation.html_url,
        batch_run_id: latestBatchFail.id,
        batch_url: latestBatchFail.html_url,
        batch_failure_count: batchFailures.length,
      });
    }
  }
  conflicts.sort((a, b) => a.pr - b.pr || a.check.localeCompare(b.check));
  return conflicts;
}

/**
 * @param {SemanticConflict} conflict
 * @returns {string}
 */
export function renderAlert(conflict) {
  const times =
    conflict.batch_failure_count > 1 ? ` (${conflict.batch_failure_count} merge_group failures)` : "";
  return (
    `Check "${conflict.check}" on PR #${conflict.pr} is green in isolation` +
    ` (${conflict.isolation_event}) and conflicts with the batch` +
    ` (${BATCH_EVENT})${times}. Re-queueing will not help.`
  );
}

/**
 * @param {{
 *   repository: string,
 *   generated_at: string,
 *   runs_sampled: number,
 *   event_rates: ReturnType<typeof eventFailureRates>,
 *   divergence_pct: number | null,
 *   conflicts: SemanticConflict[],
 * }} report
 * @returns {string}
 */
export function renderReport(report) {
  const lines = [];
  lines.push(`Semantic merge-conflict detector — ${report.repository}`);
  lines.push(`Sampled ${report.runs_sampled} runs at ${report.generated_at}`);
  lines.push("");
  lines.push("Failure rate by trigger:");
  for (const ev of report.event_rates) {
    lines.push(
      `  ${ev.event.padEnd(22)} ${ev.failed}/${ev.total}  (${ev.rate_pct}%)`,
    );
  }
  if (report.divergence_pct === null) {
    lines.push("  divergence             n/a (need both pull_request and merge_group runs)");
  } else {
    const sign = report.divergence_pct > 0 ? "+" : "";
    lines.push(
      `  divergence             ${sign}${report.divergence_pct} pp  (merge_group minus pull_request)`,
    );
  }
  lines.push("");
  if (report.conflicts.length === 0) {
    lines.push("Semantic merge conflicts: none");
  } else {
    lines.push(`Semantic merge conflicts: ${report.conflicts.length}`);
    for (const conflict of report.conflicts) {
      lines.push(`  - ${renderAlert(conflict)}`);
      lines.push(`      isolation: ${conflict.isolation_url}`);
      lines.push(`      batch:     ${conflict.batch_url}`);
    }
  }
  return lines.join("\n");
}

/**
 * @param {string} repository
 * @param {Date} since
 * @returns {WorkflowRun[]}
 */
/**
 * @param {string} repository
 * @param {Date} since
 * @param {string} event
 * @returns {WorkflowRun[]}
 */
export function fetchRunsForEvent(repository, since, event) {
  const sinceIso = since.toISOString();
  const raw = ghApiJson(
    `repos/${repository}/actions/runs`,
    `.workflow_runs[]? | select(.created_at >= "${sinceIso}") | ` +
      `{id: .id, name: .name, event: .event, conclusion: .conclusion, ` +
      `head_branch: .head_branch, head_sha: .head_sha, created_at: .created_at, ` +
      `html_url: .html_url, pull_request_numbers: [.pull_requests[]?.number]}`,
    {
      paginate: true,
      query: { per_page: DEFAULT_PAGE_SIZE, created: `>=${sinceIso}`, event },
      timeoutMs: 180_000,
    },
  );
  const runs = Array.isArray(raw) ? raw : [];
  return runs.map(normalizeRun);
}

/**
 * Fetch isolation and merge_group runs as separate queries so a busy repo's
 * push/schedule/dynamic traffic cannot crowd the PR-vs-queue comparison out
 * of GitHub's page cap.
 *
 * @param {string} repository
 * @param {Date} since
 * @returns {WorkflowRun[]}
 */
export function fetchRecentRuns(repository, since) {
  const seen = new Set();
  const out = [];
  for (const event of FETCH_EVENTS) {
    for (const run of fetchRunsForEvent(repository, since, event)) {
      if (seen.has(run.id)) continue;
      seen.add(run.id);
      out.push(run);
    }
  }
  return out;
}

/**
 * @param {string} repository
 * @param {number} pr
 * @returns {string | null}
 */
export function fetchPrHeadSha(repository, pr) {
  const sha = ghApiJson(
    `repos/${repository}/pulls/${pr}`,
    `.head.sha`,
    { timeoutMs: 30_000 },
  );
  return typeof sha === "string" && sha.length > 0 ? sha : null;
}

/**
 * When a merge_group failure's matching pull_request run fell outside the
 * lookback (or the mixed-event page cap), pull isolation runs for that PR
 * head so "same PR head" can still be evaluated.
 *
 * @param {string} repository
 * @param {WorkflowRun[]} runs
 * @returns {WorkflowRun[]}
 */
export function fillMissingIsolationRuns(repository, runs) {
  const out = runs.slice();
  const seen = new Set(out.map((r) => r.id));
  /** @type {Set<number>} */
  const needed = new Set();
  for (const run of out) {
    if (run.event !== BATCH_EVENT || run.conclusion !== "failure") continue;
    const pr = extractPrNumber(run);
    if (pr === null) continue;
    const hasIsolation = out.some(
      (other) =>
        extractPrNumber(other) === pr &&
        other.name === run.name &&
        ISOLATION_EVENTS.has(other.event),
    );
    if (!hasIsolation) needed.add(pr);
  }
  for (const pr of needed) {
    let head;
    try {
      head = fetchPrHeadSha(repository, pr);
    } catch {
      continue;
    }
    if (!head) continue;
    const raw = ghApiJson(
      `repos/${repository}/actions/runs`,
      `[.workflow_runs[]? | {id: .id, name: .name, event: .event, conclusion: .conclusion, ` +
        `head_branch: .head_branch, head_sha: .head_sha, created_at: .created_at, ` +
        `html_url: .html_url, pull_request_numbers: [.pull_requests[]?.number]}]`,
      {
        query: { per_page: DEFAULT_PAGE_SIZE, head_sha: head, event: "pull_request" },
        timeoutMs: 60_000,
      },
    );
    const extra = Array.isArray(raw) ? raw : raw ? [raw] : [];
    for (const item of extra) {
      const run = normalizeRun(/** @type {WorkflowRun} */ (item));
      if (!run.pull_request_numbers.includes(pr)) {
        run.pull_request_numbers = [pr];
      }
      if (seen.has(run.id)) continue;
      seen.add(run.id);
      out.push(run);
    }
  }
  return out;
}

/**
 * @param {string} repository
 * @param {number} runId
 * @returns {string[]}
 */
export function fetchFailedJobNames(repository, runId) {
  const jobs = /** @type {Array<{ name: string, conclusion: string | null }> | null} */ (
    ghApiJson(
      `repos/${repository}/actions/runs/${runId}/jobs`,
      `.jobs // [] | map({name: .name, conclusion: .conclusion})`,
      { timeoutMs: 60_000 },
    )
  );
  if (!Array.isArray(jobs)) return [];
  return jobs.filter((j) => j && j.conclusion === "failure" && j.name).map((j) => j.name);
}

/**
 * Attach failed job names onto the merge_group runs that already look like
 * semantic conflicts, so the alert can name the check rather than the
 * workflow. Other failures are left alone — no extra API calls.
 *
 * @param {string} repository
 * @param {WorkflowRun[]} runs
 * @param {SemanticConflict[]} conflicts
 * @returns {WorkflowRun[]}
 */
export function enrichFailedJobs(repository, runs, conflicts) {
  const out = runs.map((r) => normalizeRun(r));
  const wanted = new Set(conflicts.map((c) => c.batch_run_id));
  for (const run of out) {
    if (!wanted.has(run.id)) continue;
    if (run.failed_jobs && run.failed_jobs.length > 0) continue;
    try {
      run.failed_jobs = fetchFailedJobNames(repository, run.id);
    } catch {
      run.failed_jobs = [];
    }
  }
  return out;
}

/**
 * @param {string} repository
 * @param {SemanticConflict} conflict
 */
export function commentOnPullRequest(repository, conflict) {
  const body = [
    COMMENT_MARKER,
    "",
    `**Semantic merge conflict** — do not re-queue.`,
    "",
    renderAlert(conflict),
    "",
    `- Isolation run: ${conflict.isolation_url}`,
    `- Batch run: ${conflict.batch_url}`,
  ].join("\n");
  const comments = /** @type {Array<{ id: number, body: string }> | null} */ (
    ghApiJson(
      `repos/${repository}/issues/${conflict.pr}/comments`,
      `.[] | {id: .id, body: .body}`,
      { paginate: true, timeoutMs: 60_000 },
    )
  );
  const existing = Array.isArray(comments)
    ? comments.find((c) => typeof c.body === "string" && c.body.includes(COMMENT_MARKER) && c.body.includes(`"${conflict.check}"`))
    : null;
  const payload = JSON.stringify({ body });
  if (existing) {
    execFileSync(
      "gh",
      ["api", "-X", "PATCH", `repos/${repository}/issues/comments/${existing.id}`, "--input", "-"],
      { encoding: "utf8", env: process.env, input: payload, timeout: 60_000 },
    );
    return "updated";
  }
  execFileSync(
    "gh",
    ["api", "-X", "POST", `repos/${repository}/issues/${conflict.pr}/comments`, "--input", "-"],
    { encoding: "utf8", env: process.env, input: payload, timeout: 60_000 },
  );
  return "created";
}

/**
 * @param {object} report
 * @param {boolean} emitAnnotations
 */
export function emitGithubAnnotations(report, emitAnnotations) {
  if (!emitAnnotations) return;
  for (const conflict of report.conflicts) {
    const msg = renderAlert(conflict).replace(/\r?\n/gu, " ");
    console.error(`::error title=Semantic merge conflict::${msg}`);
  }
}

function printUsage() {
  console.log(`Usage: semantic-conflict-detector.mjs [options]

Options:
  --repo <owner/name>       Target repository (default: env SEMANTIC_CONFLICT_REPO)
  --lookback-hours <n>      Lookback window in hours (default: ${DEFAULT_LOOKBACK_HOURS})
  --from-json <path>        Replay stored runs (no GitHub). Fixture tests use this.
  --format <human|json>     Output format (default: human)
  --output-json <path>      Also write the report JSON to this file
  --comment                 Comment on each conflicting PR (off by default)
  --no-enrich               Do not fetch failed job names
  --help                    Show this message
`);
}

function parseArgs(argv) {
  const args = {
    repo: process.env.SEMANTIC_CONFLICT_REPO ?? "",
    lookbackHours: DEFAULT_LOOKBACK_HOURS,
    fromJson: "",
    format: "human",
    outputJson: "",
    comment: false,
    enrich: true,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else if (arg === "--repo") {
      args.repo = argv[++i] ?? "";
    } else if (arg === "--lookback-hours") {
      args.lookbackHours = Number(argv[++i]) || DEFAULT_LOOKBACK_HOURS;
    } else if (arg === "--from-json") {
      args.fromJson = argv[++i] ?? "";
    } else if (arg === "--format") {
      args.format = (argv[++i] ?? "human").toLowerCase();
    } else if (arg === "--output-json") {
      args.outputJson = argv[++i] ?? "";
    } else if (arg === "--comment") {
      args.comment = true;
    } else if (arg === "--no-enrich") {
      args.enrich = false;
    } else if (arg && !arg.startsWith("-")) {
      args.repo = arg;
    }
  }
  if (!args.repo && !args.fromJson) {
    console.error("Missing required --repo / SEMANTIC_CONFLICT_REPO or --from-json");
    printUsage();
    process.exit(2);
  }
  return args;
}

/**
 * @param {unknown} payload
 * @returns {WorkflowRun[]}
 */
function runsFromFixture(payload) {
  if (Array.isArray(payload)) return payload.map(normalizeRun);
  if (payload && typeof payload === "object" && Array.isArray(/** @type {{runs?: unknown}} */ (payload).runs)) {
    return /** @type {{runs: WorkflowRun[]}} */ (payload).runs.map(normalizeRun);
  }
  throw new Error("semantic_conflict_fixture_invalid: expected {runs: [...]} or an array");
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const now = new Date();
  let repository = args.repo;
  /** @type {WorkflowRun[]} */
  let runs;

  if (args.fromJson) {
    const payload = JSON.parse(readFileSync(resolve(args.fromJson), "utf8"));
    if (!repository && payload && typeof payload === "object" && payload.repository) {
      repository = String(payload.repository);
    }
    if (!repository) repository = "fixture";
    runs = runsFromFixture(payload);
  } else {
    const since = new Date(now.getTime() - args.lookbackHours * 60 * 60 * 1000);
    runs = fetchRecentRuns(args.repo, since);
    runs = fillMissingIsolationRuns(args.repo, runs);
    if (args.enrich) {
      const firstPass = detectSemanticConflicts(runs);
      if (firstPass.length > 0) {
        runs = enrichFailedJobs(args.repo, runs, firstPass);
      }
    }
  }

  const event_rates = eventFailureRates(runs);
  const conflicts = detectSemanticConflicts(runs);
  const report = {
    generated_at: now.toISOString(),
    repository,
    runs_sampled: runs.length,
    event_rates,
    divergence_pct: divergencePct(event_rates),
    conflicts,
  };

  const json = JSON.stringify(report, null, 2);
  const human = renderReport(report);
  console.log(args.format === "json" ? json : human);

  emitGithubAnnotations(report, Boolean(process.env.GITHUB_ACTIONS));
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n${human}\n`);
  }
  if (args.outputJson) writeFileSync(resolve(args.outputJson), json);

  if (args.comment && !args.fromJson) {
    for (const conflict of conflicts) {
      try {
        const action = commentOnPullRequest(repository, conflict);
        console.error(`comment ${action} on ${repository}#${conflict.pr} (${conflict.check})`);
      } catch (error) {
        console.error(
          `comment_failed on ${repository}#${conflict.pr}: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
      }
    }
  }

  if (process.env.GITHUB_OUTPUT) {
    const lines = [
      `conflicts=${conflicts.length}`,
      `runs-sampled=${runs.length}`,
      `divergence-pct=${report.divergence_pct === null ? "" : report.divergence_pct}`,
    ];
    appendFileSync(process.env.GITHUB_OUTPUT, `${lines.join("\n")}\n`);
  }
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
