#!/usr/bin/env node
// Repeat-deterministic failure detector (fleet-ops central reusable set).
//
// Top teams classify before retrying:
//   assertion failure -> stop, do not re-arm
//   infra / network / timeout -> retry with backoff
//
// The mechanical signal needs no knowledge of WHY a step failed, only that
// the SAME failure signature kept failing. The signature is
//   (repo, workflow, job, step, assertion)
// and the rule is: the same signature failed `threshold` (default 3) times
// within `window-hours` (default 6) -> emit loudly. Re-arm cannot fix an
// assertion failure; this alert says so.
//
// It catches both shapes that burned CI on 2026-08-25:
//   - "Deploy production" retried an identical hard wrangler error 6x
//     (11:09 -> 14:06).
//   - PR #994 re-entered the 0509 merge queue 6x (19:51 -> 22:21) failing
//     the same assertion every time.
// Neither was retryable. Both replay through this detector and fire.
//
// Alert channel: the same one the repo already uses for telemetry —
// GitHub `::error` annotations, the job summary, optional PR comments
// (--comment), and JSON output. No new channel is invented.
//
// Surface: gh CLI + GitHub REST API only. No paid services.

import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_LOOKBACK_HOURS = 6;
const DEFAULT_THRESHOLD = 3;
const DEFAULT_WINDOW_HOURS = 6;
const DEFAULT_PAGE_SIZE = 100;
const COMMENT_MARKER = "<!-- repeat-deterministic-detector -->";

// GitHub Actions log annotation prefix. Strip it so the assertion is the
// message, not the wrapper.
const ANNOTATION_PREFIX = /^##(?:error|warning|notice)\s+/u;
// Leading log timestamp tokens: "2026-08-25T11:09:00.123Z " or "11:09:00 ".
const LEADING_TS = /^(?:\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?\s+|\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+)/u;

/**
 * @typedef {{
 *   repo: string,
 *   workflow: string,
 *   job: string,
 *   step: string,
 *   assertion: string,
 *   run_id: number,
 *   run_url: string,
 *   job_id: number | null,
 *   job_url: string,
 *   created_at: string,
 *   event: string | null,
 *   head_branch: string | null,
 *   head_sha: string,
 *   pr: number | null,
 * }} Failure
 *
 * @typedef {{
 *   signature: string,
 *   repo: string,
 *   workflow: string,
 *   job: string,
 *   step: string,
 *   assertion: string,
 *   count: number,
 *   threshold: number,
 *   window_hours: number,
 *   first_at: string,
 *   last_at: string,
 *   runs: Array<{ run_id: number, run_url: string, created_at: string, pr: number | null }>,
 * }} Repeat
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
      `repeat_deterministic_exec_failed: ${command} ${args.join(" ")} :: ${detail.slice(0, 800)}`,
    );
  }
}

/**
 * @param {string} endpoint
 * @param {string} jq
 * @param {{ paginate?: boolean, timeoutMs?: number, query?: Record<string, string | number>, raw?: boolean }} [opts]
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
  if (jq && !opts.raw) args.push("--jq", jq);
  const stdout = execGh("gh", args, { timeoutMs: opts.timeoutMs ?? 90_000 });
  if (opts.raw) return stdout;
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
 * @param {{ pull_request_numbers?: number[], pull_requests?: Array<{ number: number }>, head_branch?: string | null }} run
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
 * Normalize a raw assertion line so the same error collapses across runs
 * even when the log prefix differs (timestamps, annotation wrappers).
 * Conservative: it does NOT scrub message text, so two genuinely different
 * errors stay separate.
 *
 * @param {string} raw
 * @returns {string}
 */
export function normalizeAssertion(raw) {
  if (raw === null || raw === undefined) return "";
  let s = String(raw);
  // The annotation wrapper and a leading log timestamp can appear in either
  // order (`##error <ts> msg` or `<ts> ##error msg`), so strip each twice.
  // Order matters: the timestamp precedes `##error` in raw logs.
  s = s.replace(LEADING_TS, "");
  s = s.replace(ANNOTATION_PREFIX, "");
  s = s.replace(LEADING_TS, "");
  s = s.replace(ANNOTATION_PREFIX, "");
  s = s.trim();
  // Collapse internal whitespace runs but keep the message content intact.
  s = s.replace(/\s+/gu, " ");
  return s.slice(0, 500);
}

/**
 * @param {Failure} f
 * @returns {string}
 */
export function signature(f) {
  return [f.repo, f.workflow, f.job, f.step, f.assertion].join("\u241F");
}

/**
 * Parse an ISO-8601 timestamp to epoch milliseconds. Returns NaN on failure.
 *
 * @param {string} ts
 * @returns {number}
 */
function epochMs(ts) {
  return Date.parse(ts);
}

/**
 * Detect repeat-deterministic failures. Groups by signature, sorts each
 * group by created_at, and fires when `threshold` failures land inside a
 * `window-hours` sliding window. The window is checked as: for sorted
 * timestamps, if ts[i+threshold-1] - ts[i] <= window for any i.
 *
 * @param {Failure[]} failures
 * @param {{ threshold?: number, windowHours?: number }} [opts]
 * @returns {Repeat[]}
 */
export function detectRepeatDeterministic(failures, opts = {}) {
  const threshold = opts.threshold ?? DEFAULT_THRESHOLD;
  const windowHours = opts.windowHours ?? DEFAULT_WINDOW_HOURS;
  const windowMs = windowHours * 60 * 60 * 1000;

  /** @type {Map<string, Failure[]>} */
  const groups = new Map();
  for (const f of failures) {
    if (!f || !f.created_at) continue;
    const key = signature(f);
    const list = groups.get(key) ?? [];
    list.push(f);
    groups.set(key, list);
  }

  /** @type {Repeat[]} */
  const repeats = [];
  for (const [, list] of groups) {
    if (list.length < threshold) continue;
    const sorted = list.slice().sort((a, b) => {
      const ai = epochMs(a.created_at);
      const bi = epochMs(b.created_at);
      if (ai === bi) return 0;
      return ai < bi ? -1 : 1;
    });
    let fired = false;
    for (let i = 0; i + threshold <= sorted.length; i++) {
      const start = epochMs(sorted[i].created_at);
      const end = epochMs(sorted[i + threshold - 1].created_at);
      if (Number.isFinite(start) && Number.isFinite(end) && end - start <= windowMs) {
        fired = true;
        break;
      }
    }
    if (!fired) continue;
    const head = sorted[0];
    const tail = sorted[sorted.length - 1];
    repeats.push({
      signature: signature(head),
      repo: head.repo,
      workflow: head.workflow,
      job: head.job,
      step: head.step,
      assertion: head.assertion,
      count: sorted.length,
      threshold,
      window_hours: windowHours,
      // Overall group span — the alert describes the whole loop, not just
      // the first in-window triple (the issue names loops by their full span).
      first_at: head.created_at,
      last_at: tail.created_at,
      runs: sorted.map((f) => ({
        run_id: f.run_id,
        run_url: f.run_url,
        created_at: f.created_at,
        pr: f.pr,
      })),
    });
  }
  repeats.sort(
    (a, b) =>
      (a.repo < b.repo ? -1 : a.repo > b.repo ? 1 : 0) ||
      (a.workflow < b.workflow ? -1 : a.workflow > b.workflow ? 1 : 0) ||
      a.job.localeCompare(b.job) ||
      a.step.localeCompare(b.step),
  );
  return repeats;
}

/**
 * @param {Repeat} repeat
 * @returns {string}
 */
export function renderAlert(repeat) {
  const plural = repeat.count === 1 ? "time" : "times";
  return (
    `Failure signature "${repeat.workflow} / ${repeat.job} / ${repeat.step}"` +
    ` failed ${repeat.count} ${plural} in ${repeat.window_hours}h` +
    ` (assertion: "${repeat.assertion || "<no message>"}").` +
    ` This is a repeat-deterministic failure — re-arm or re-queue will not help.` +
    ` Classify before retrying: assertion failure -> stop; infra/network/timeout -> retry with backoff.`
  );
}

/**
 * @param {{
 *   repository: string,
 *   generated_at: string,
 *   lookback_hours: number,
 *   threshold: number,
 *   window_hours: number,
 *   failures_sampled: number,
 *   repeats: Repeat[],
 * }} report
 * @returns {string}
 */
export function renderReport(report) {
  const lines = [];
  lines.push(`Repeat-deterministic failure detector — ${report.repository}`);
  lines.push(
    `Sampled ${report.failures_sampled} failures over ${report.lookback_hours}h` +
      ` (threshold ${report.threshold} within ${report.window_hours}h) at ${report.generated_at}`,
  );
  lines.push("");
  if (report.repeats.length === 0) {
    lines.push("Repeat-deterministic failures: none");
  } else {
    lines.push(`Repeat-deterministic failures: ${report.repeats.length}`);
    for (const repeat of report.repeats) {
      lines.push(`  - ${renderAlert(repeat)}`);
      lines.push(`      repo:      ${repeat.repo}`);
      lines.push(`      first:     ${repeat.first_at}`);
      lines.push(`      last:      ${repeat.last_at}`);
      lines.push(`      runs:      ${repeat.runs.map((r) => r.run_url).join(", ")}`);
    }
  }
  return lines.join("\n");
}

/**
 * @param {string} repository
 * @param {Date} since
 * @returns {Array<{ id: number, name: string, event: string | null, conclusion: string | null, head_branch: string | null, head_sha: string, created_at: string, html_url: string, pull_request_numbers: number[], pull_requests: Array<{ number: number }> }>}
 */
export function fetchFailedRuns(repository, since) {
  const sinceIso = since.toISOString();
  const raw = ghApiJson(
    `repos/${repository}/actions/runs`,
    `.workflow_runs[]? | select(.created_at >= "${sinceIso}") | ` +
      `{id: .id, name: .name, event: .event, conclusion: .conclusion, ` +
      `head_branch: .head_branch, head_sha: .head_sha, created_at: .created_at, ` +
      `html_url: .html_url, pull_request_numbers: [.pull_requests[]?.number], ` +
      `pull_requests: .pull_requests}`,
    {
      paginate: true,
      query: { per_page: DEFAULT_PAGE_SIZE, created: `>=${sinceIso}`, status: "failure" },
      timeoutMs: 180_000,
    },
  );
  const runs = Array.isArray(raw) ? raw : [];
  return runs.filter((r) => r && r.conclusion === "failure");
}

/**
 * @param {string} repository
 * @param {number} runId
 * @returns {Array<{ id: number, name: string, html_url: string, steps: Array<{ name: string, conclusion: string | null }> }>}
 */
export function fetchFailingJobs(repository, runId) {
  const jobs = /** @type {Array<{ id: number, name: string, html_url: string, conclusion: string | null, steps: Array<{ name: string, conclusion: string | null }> }> | null} */ (
    ghApiJson(
      `repos/${repository}/actions/runs/${runId}/jobs`,
      `.jobs // [] | map({id: .id, name: .name, html_url: .html_url, ` +
        `conclusion: .conclusion, steps: [.steps[]? | {name: .name, conclusion: .conclusion}]})`,
      { timeoutMs: 60_000 },
    )
  );
  if (!Array.isArray(jobs)) return [];
  return jobs.filter((j) => j && j.conclusion === "failure" && j.name);
}

/**
 * Extract the first error annotation from a job's logs. Returns "" when the
 * logs are unavailable (expired, 410) or contain no error line — the caller
 * falls back to the step name so same-step failures still collapse.
 *
 * @param {string} repository
 * @param {number} jobId
 * @returns {string}
 */
export function fetchJobAssertion(repository, jobId) {
  try {
    const logs = /** @type {string} */ (
      ghApiJson(`repos/${repository}/actions/jobs/${jobId}/logs`, "", {
        raw: true,
        timeoutMs: 60_000,
      })
    );
    if (!logs) return "";
    for (const line of logs.split(/\r?\n/u)) {
      const m = line.match(/##error\s+(.*)/u);
      if (m && m[1] && m[1].trim()) return normalizeAssertion(m[1]);
    }
    return "";
  } catch {
    return "";
  }
}

/**
 * Build Failure records from failed runs. When `enrich` is false (or
 * assertions are not yet known), `assertion` is left empty so the caller can
 * group by (repo, workflow, job, step) first and only fetch logs for
 * candidate repeats. When `enrich` is true, the assertion is resolved per
 * failing job (from logs, falling back to the step name).
 *
 * @param {string} repository
 * @param {ReturnType<typeof fetchFailedRuns>} runs
 * @param {{ enrich?: boolean, assertionResolver?: (repo: string, jobId: number) => string }} [opts]
 * @returns {Failure[]}
 */
export function buildFailures(repository, runs, opts = {}) {
  const enrich = opts.enrich ?? false;
  const resolve = opts.assertionResolver ?? fetchJobAssertion;
  /** @type {Failure[]} */
  const out = [];
  for (const run of runs) {
    const pr = extractPrNumber(run);
    let jobs;
    try {
      jobs = fetchFailingJobs(repository, run.id);
    } catch {
      jobs = [];
    }
    if (jobs.length === 0) {
      // Job-level failure with no failing step listed: one record keyed on
      // the workflow itself so it is still observable.
      out.push({
        repo: repository,
        workflow: run.name,
        job: "(job)",
        step: "(run)",
        assertion: enrich ? "(no failing job listed)" : "",
        run_id: run.id,
        run_url: run.html_url,
        job_id: null,
        job_url: run.html_url,
        created_at: run.created_at,
        event: run.event,
        head_branch: run.head_branch,
        head_sha: run.head_sha,
        pr,
      });
      continue;
    }
    for (const job of jobs) {
      const failingSteps = (job.steps ?? []).filter((s) => s.conclusion === "failure");
      if (failingSteps.length === 0) {
        out.push({
          repo: repository,
          workflow: run.name,
          job: job.name,
          step: "(job)",
          assertion: enrich ? "(no failing step listed)" : "",
          run_id: run.id,
          run_url: run.html_url,
          job_id: job.id,
          job_url: job.html_url,
          created_at: run.created_at,
          event: run.event,
          head_branch: run.head_branch,
          head_sha: run.head_sha,
          pr,
        });
        continue;
      }
      for (const step of failingSteps) {
        let assertion = "";
        if (enrich) {
          const fromLogs = job.id ? resolve(repository, job.id) : "";
          assertion = fromLogs || step.name;
        }
        out.push({
          repo: repository,
          workflow: run.name,
          job: job.name,
          step: step.name,
          assertion,
          run_id: run.id,
          run_url: run.html_url,
          job_id: job.id,
          job_url: job.html_url,
          created_at: run.created_at,
          event: run.event,
          head_branch: run.head_branch,
          head_sha: run.head_sha,
          pr,
        });
      }
    }
  }
  return out;
}

/**
 * Two-pass enrichment: detect on (workflow, job, step) with empty assertions,
 * fetch logs only for runs that are already candidate repeats, then re-detect
 * on the full signature. Bounds log fetches to candidates.
 *
 * @param {string} repository
 * @param {Failure[]} failures
 * @param {{ threshold: number, windowHours: number, assertionResolver?: (repo: string, jobId: number) => string }} opts
 * @returns {Failure[]}
 */
export function enrichCandidateAssertions(repository, failures, opts) {
  const candidates = new Set(
    detectRepeatDeterministic(failures, {
      threshold: opts.threshold,
      windowHours: opts.windowHours,
    }).flatMap((r) => r.runs.map((rr) => rr.run_id)),
  );
  if (candidates.size === 0) return failures;
  const resolve = opts.assertionResolver ?? fetchJobAssertion;
  return failures.map((f) => {
    if (f.assertion || !candidates.has(f.run_id) || f.job_id === null) return f;
    const fromLogs = resolve(repository, f.job_id);
    return { ...f, assertion: fromLogs || f.step };
  });
}

/**
 * Comment on the PR attached to the most recent run that has one, so nobody
 * re-arms or re-queues a repeat-deterministic loop. Idempotent: one marker
 * comment per (PR, signature), updated in place. When no run carries a PR
 * (e.g. a push-triggered deploy loop), the body is logged to stderr so the
 * workflow run still carries the breadcrumb.
 *
 * @param {string} repository
 * @param {Repeat} repeat
 * @returns {"created" | "updated" | "logged" | "skipped"}
 */
export function commentOnPullRequest(repository, repeat) {
  const withPr = repeat.runs.filter((r) => Number.isFinite(r.pr));
  const body = [
    COMMENT_MARKER,
    "",
    `**Repeat-deterministic failure** — do not re-arm.`,
    "",
    renderAlert(repeat),
    "",
    `Runs: ${repeat.runs.map((r) => r.run_url).join(", ")}`,
  ].join("\n");
  if (withPr.length === 0) {
    console.error(body);
    return "logged";
  }
  const pr = Number(withPr[withPr.length - 1].pr);
  const comments = /** @type {Array<{ id: number, body: string }> | null} */ (
    ghApiJson(
      `repos/${repository}/issues/${pr}/comments`,
      `.[] | {id: .id, body: .body}`,
      { paginate: true, timeoutMs: 60_000 },
    )
  );
  const existing = Array.isArray(comments)
    ? comments.find(
        (c) =>
          typeof c.body === "string" &&
          c.body.includes(COMMENT_MARKER) &&
          c.body.includes(repeat.signature),
      )
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
    ["api", "-X", "POST", `repos/${repository}/issues/${pr}/comments`, "--input", "-"],
    { encoding: "utf8", env: process.env, input: payload, timeout: 60_000 },
  );
  return "created";
}

/**
 * @param {{ repeats: Repeat[] }} report
 * @param {boolean} emitAnnotations
 */
export function emitGithubAnnotations(report, emitAnnotations) {
  if (!emitAnnotations) return;
  for (const repeat of report.repeats) {
    const msg = renderAlert(repeat).replace(/\r?\n/gu, " ");
    console.error(`::error title=REPEAT-DETERMINISTIC::${msg}`);
  }
}

function printUsage() {
  console.log(`Usage: repeat-deterministic-detector.mjs [options]

Options:
  --repo <owner/name>       Target repository (default: env REPEAT_DETERMINISTIC_REPO)
  --lookback-hours <n>      Hours of recent failed runs to sample (default: ${DEFAULT_LOOKBACK_HOURS})
  --threshold <n>           Failures needed to fire (default: ${DEFAULT_THRESHOLD})
  --window-hours <n>        Sliding window in hours (default: ${DEFAULT_WINDOW_HOURS})
  --from-json <path>        Replay stored failures (no GitHub). Fixture tests use this.
  --format <human|json>     Output format (default: human)
  --output-json <path>      Also write the report JSON to this file
  --comment                 Emit PR-comment breadcrumbs (off by default)
  --no-enrich               Do not fetch job logs for assertion text
  --help                    Show this message
`);
}

function parseArgs(argv) {
  const args = {
    repo: process.env.REPEAT_DETERMINISTIC_REPO ?? "",
    lookbackHours: DEFAULT_LOOKBACK_HOURS,
    threshold: DEFAULT_THRESHOLD,
    windowHours: DEFAULT_WINDOW_HOURS,
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
    } else if (arg === "--threshold") {
      args.threshold = Math.max(1, Number(argv[++i]) || DEFAULT_THRESHOLD);
    } else if (arg === "--window-hours") {
      args.windowHours = Math.max(1, Number(argv[++i]) || DEFAULT_WINDOW_HOURS);
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
    console.error("Missing required --repo / REPEAT_DETERMINISTIC_REPO or --from-json");
    printUsage();
    process.exit(2);
  }
  return args;
}

/**
 * @param {unknown} payload
 * @returns {Failure[]}
 */
function failuresFromFixture(payload) {
  const list = Array.isArray(payload)
    ? payload
    : payload && typeof payload === "object" && Array.isArray(/** @type {{ failures?: unknown }} */ (payload).failures)
      ? /** @type {{ failures: Failure[] }} */ (payload).failures
      : [];
  return list.map((f) => {
    const pr =
      typeof f.pr === "number"
        ? f.pr
        : extractPrNumber({ head_branch: f.head_branch, pull_request_numbers: f.pull_request_numbers, pull_requests: f.pull_requests });
    return {
      repo: String(f.repo ?? ""),
      workflow: String(f.workflow ?? ""),
      job: String(f.job ?? ""),
      step: String(f.step ?? ""),
      assertion: normalizeAssertion(f.assertion ?? ""),
      run_id: Number(f.run_id ?? 0),
      run_url: String(f.run_url ?? ""),
      job_id: f.job_id === undefined ? null : Number(f.job_id),
      job_url: String(f.job_url ?? ""),
      created_at: String(f.created_at ?? ""),
      event: f.event ?? null,
      head_branch: f.head_branch ?? null,
      head_sha: String(f.head_sha ?? ""),
      pr: Number.isFinite(pr) ? pr : null,
    };
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const now = new Date();
  let repository = args.repo;
  /** @type {Failure[]} */
  let failures;

  if (args.fromJson) {
    const payload = JSON.parse(readFileSync(resolve(args.fromJson), "utf8"));
    if (!repository && payload && typeof payload === "object" && payload.repository) {
      repository = String(payload.repository);
    }
    if (!repository) repository = "fixture";
    failures = failuresFromFixture(payload);
  } else {
    const since = new Date(now.getTime() - args.lookbackHours * 60 * 60 * 1000);
    const runs = fetchFailedRuns(args.repo, since);
    failures = buildFailures(args.repo, runs, { enrich: false });
    if (args.enrich) {
      failures = enrichCandidateAssertions(args.repo, failures, {
        threshold: args.threshold,
        windowHours: args.windowHours,
      });
    }
  }

  const repeats = detectRepeatDeterministic(failures, {
    threshold: args.threshold,
    windowHours: args.windowHours,
  });
  const report = {
    generated_at: now.toISOString(),
    repository,
    lookback_hours: args.lookbackHours,
    threshold: args.threshold,
    window_hours: args.windowHours,
    failures_sampled: failures.length,
    repeats,
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
    for (const repeat of repeats) {
      try {
        commentOnPullRequest(repository, repeat);
      } catch (error) {
        console.error(
          `comment_failed on ${repository}: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }
  }

  if (process.env.GITHUB_OUTPUT) {
    const lines = [
      `repeats=${repeats.length}`,
      `failures-sampled=${failures.length}`,
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
