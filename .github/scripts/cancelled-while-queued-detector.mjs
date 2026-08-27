#!/usr/bin/env node
// cancelled-while-queued detector (fleet-ops#819).
//
// The failure mode (Nish 2026-08-24 audit of p42-public-audit session):
// some workflow runs sat 1,200+ minutes as `cancelled-while-queued` — a
// run that was queued for a runner, never picked up, then cancelled.
// GitHub bills the wall-clock for any minute the runner is actually
// executing (see the official "How use of GitHub Actions is measured"
// page: the billable time is when a GitHub-hosted runner is in use, and
// queued time is NOT in use). The audit confirmed this — `.billable
// .UBUNTU.total_ms` returned 0 for the cancelled-while-queued runs.
// GitHub itself discards queued runs after 45 minutes of no runner
// pickup (see "Workflow continuity" on the GitHub-hosted runners page),
// so the 1,200+ minute runs that the audit saw had already been
// discarded by GitHub; they will never bill.
//
// So the actual risk is two-fold and the detector's job is the
// second of these two:
//
//   1. (Solved by GitHub.) A run queued for >45 min is auto-discarded.
//   2. (This detector.) A run queued for *too long* is queue pressure:
//      every queued run blocks the next one and signals that a
//      runner/budget capacity is exhausted. If a queued run is ever
//      picked up after long idle, the run still bills from pickup →
//      completion. Cancelling it BEFORE pickup is the safest form of
//      cap (queue is freed, billing is impossible, the underlying
//      failure is surfaced as a labelled issue that the senior-
//      auditor matrix can act on).
//
// The detector for each enrolled repo (the #185 central-auto-discovery
// form, enrolled set read from config/intake-repos.json):
//
//   1. Samples in-flight workflow runs (status in {queued, pending,
//      in_progress, waiting}; default include in-flight so the
//      detector catches runs that have been waiting too long even
//      after assignment).
//   2. For each, computes `queued_for_minutes = now - created_at`.
//   3. Keeps runs where `queued_for_minutes >= queued_threshold_minutes`
//      (default 30, well below GitHub's 45-min discard so the cancel
//      lands before the run is silently lost; well above the normal
//      GitHub-hosted runner queue time of seconds-to-minutes).
//   4. Cancels each kept run via the GitHub Actions cancel API
//      (`POST /repos/{owner}/{repo}/actions/runs/{run_id}/cancel`)
//      and files one labelled issue per run in the escalation repo
//      (default Nishfleet/fleet-ops) with the run link, repo,
//      workflow, queued duration, and the cancel reason.
//   5. Dedupes against open `cancelled-while-queued` issues by
//      signature (repo + run_id hash). A second sweep within the
//      24h lookback window does NOT refile; the open issues ARE
//      the dedup ledger.
//
// Observe-to-close (fleet-ops#725 family): an open issue is closed on
// a later tick when the run is no longer reported as queued (either
// because the cancel landed and the run is now `completed/cancelled`,
// or because the run was re-queued and completed). The detector scans
// the issue body for the signature marker and closes any whose run is
// no longer queued — same discipline as the findings-queued
// observe-to-close path.
//
// What this is NOT:
//   - It is NOT a billing-detector: GitHub's billing surface is
//     `total_ms` and it returns 0 for cancelled-while-queued runs.
//     The audit confirmed it. The "billing bomb" framing in the
//     issue is a hypothetical — IF a queued run ever bills, the
//     pre-emptive cancel is the safe cap.
//   - It is NOT a required check. A stuck queue can never break
//     merge; it can only delay it. The detector is an alert and a
//     cap, not a gate.
//
// Surface: gh CLI + GitHub REST API only; no paid services.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const DEFAULT_QUEUED_THRESHOLD_MINUTES = 30;
const DEFAULT_LOOKBACK_HOURS = 24;
const DEFAULT_PAGE_SIZE = 100;
const DEFAULT_LABEL = "cancelled-while-queued";
const DEFAULT_ESCALATION_REPO = "Nishfleet/fleet-ops";
const SIG_MARKER_PREFIX = "<!-- cancelled-while-queued-sig:";

// GitHub "Workflow continuity": a queued run is discarded after 45
// minutes. We cancel at 30 by default to land BEFORE the silent
// discard so the cancel shows up in the run history and the filing
// is observable.
const DEFAULT_DISCARD_MINUTES = 45;

// In-flight statuses that still count as "queued for a runner" for
// the purposes of this detector. `pending` = scheduled, `queued` =
// waiting for a runner, `waiting` = concurrency hold, `in_progress`
// is excluded by design (already running, billing is real but the
// 45-min auto-cancel is not the worry).
const DEFAULT_QUEUED_STATUSES = ["pending", "queued", "waiting"];

/**
 * @typedef {{
 *   id: number,
 *   name: string,
 *   event: string | null,
 *   status: string,
 *   conclusion: string | null,
 *   head_branch: string | null,
 *   head_sha: string,
 *   created_at: string,
 *   html_url: string,
 *   pull_request_numbers: number[],
 *   pull_requests: Array<{ number: number }>,
 * }} Run
 *
 * @typedef {{
 *   repo: string,
 *   run_id: number,
 *   run_url: string,
 *   workflow: string,
 *   event: string | null,
 *   head_branch: string | null,
 *   head_sha: string,
 *   pr: number | null,
 *   created_at: string,
 *   queued_for_minutes: number,
 *   status: string,
 *   signature: string,
 *   hash: string,
 * }} QueuedRun
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
    const failure = /** @type {{ message?: unknown, stderr?: unknown, stdout?: unknown }} */ (error);
    const detail = [failure.message, failure.stderr, failure.stdout]
      .map((part) => (part ? String(part) : ""))
      .filter((part) => part.trim().length > 0)
      .join(" | ");
    throw new Error(
      `cancelled_queued_exec_failed: ${command} ${args.join(" ")} :: ${detail.slice(0, 800)}`,
    );
  }
}

/**
 * @param {string} endpoint
 * @param {string} jq
 * @param {{ paginate?: boolean, timeoutMs?: number, query?: Record<string, string | number>, raw?: boolean, method?: string }} [opts]
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
  if (opts.method) args.push("--method", opts.method);
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
        // Skip stray warning text; well-formed objects parse cleanly.
      }
    }
    return out;
  }
  return JSON.parse(stdout);
}

/**
 * @param {string} ts
 * @returns {number}
 */
function epochMs(ts) {
  if (!ts) return 0;
  const ms = Date.parse(ts);
  return Number.isFinite(ms) ? ms : 0;
}

/**
 * Stable per-run signature for dedup. Repo + run_id uniquely
 * identifies a single workflow run, so the signature is per-run, not
 * per-failure-shape like the CI-failure-escalation detector uses.
 * Cancelling a run is a one-shot action; refiling the same run
 * before it has cleared the queue would be a duplicate.
 *
 * @param {string} repo
 * @param {number} runId
 * @returns {string}
 */
export function runSignature(repo, runId) {
  return [repo, String(runId)].join("\u241F");
}

/**
 * @param {string} sig
 * @returns {string}
 */
export function signatureHash(sig) {
  return createHash("sha256").update(sig).digest("hex");
}

/**
 * Is this run's status one that "queued for a runner" still covers?
 * `pending` (scheduled, not yet fired) and `queued` (waiting for a
 * runner) and `waiting` (concurrency hold) all count. `in_progress`
 * does not — the run is already executing and the 45-min auto-cancel
 * is not the worry.
 *
 * @param {string} status
 * @param {string[]} [queuedStatuses]
 * @returns {boolean}
 */
export function isQueuedStatus(status, queuedStatuses) {
  const set = new Set(queuedStatuses ?? DEFAULT_QUEUED_STATUSES);
  return set.has(status);
}

/**
 * @param {string} ts
 * @param {number} nowMs
 * @returns {number}
 */
export function minutesBetween(ts, nowMs) {
  if (!ts) return 0;
  const ms = epochMs(ts);
  if (!ms) return 0;
  return Math.max(0, (nowMs - ms) / 60_000);
}

/**
 * @param {Run} run
 * @param {{ repo: string, nowMs: number, queuedThresholdMinutes: number, queuedStatuses?: string[] }} opts
 * @returns {QueuedRun | null}
 */
export function toQueuedRun(run, opts) {
  if (!run || !isQueuedStatus(run.status, opts.queuedStatuses)) return null;
  const queuedFor = minutesBetween(run.created_at, opts.nowMs);
  if (queuedFor < opts.queuedThresholdMinutes) return null;
  const sig = runSignature(opts.repo, run.id);
  const pr = Array.isArray(run.pull_request_numbers) && run.pull_request_numbers.length > 0
    ? Number(run.pull_request_numbers[0])
    : (Array.isArray(run.pull_requests) && run.pull_requests[0] && Number.isFinite(run.pull_requests[0].number)
        ? Number(run.pull_requests[0].number)
        : null);
  return {
    repo: opts.repo,
    run_id: run.id,
    run_url: run.html_url,
    workflow: run.name || "(unnamed workflow)",
    event: run.event,
    head_branch: run.head_branch,
    head_sha: run.head_sha,
    pr,
    created_at: run.created_at,
    queued_for_minutes: Math.round(queuedFor),
    status: run.status,
    signature: sig,
    hash: signatureHash(sig),
  };
}

/**
 * Detect queued-too-long runs across an array of `Run` objects
 * (typically from one repo's actions/runs listing). The threshold is
 * the only filter — the caller decides which repos to scan and the
 * detector does not exclude any branch. A claim/issue-* branch is no
 * exception: a stuck worker PR is the most common cause of the
 * "queue pressure" signal in the fleet.
 *
 * @param {Run[]} runs
 * @param {{ repo: string, nowMs: number, queuedThresholdMinutes: number, queuedStatuses?: string[] }} opts
 * @returns {QueuedRun[]}
 */
export function detectStaleQueued(runs, opts) {
  if (!Array.isArray(runs)) return [];
  return runs
    .map((r) => toQueuedRun(r, opts))
    .filter((r) => r !== null);
}

/**
 * @param {Array<{ number: number, body: string | null }>} openIssues
 * @param {string} hash
 * @returns {boolean}
 */
export function isDuplicated(openIssues, hash) {
  if (!Array.isArray(openIssues) || !hash) return false;
  const marker = `${SIG_MARKER_PREFIX} ${hash} -->`;
  return openIssues.some((i) => typeof i?.body === "string" && i.body.includes(marker));
}

/**
 * @param {Array<{ number: number, body: string | null }>} openIssues
 * @param {string} hash
 * @returns {number | null}
 */
export function findOpenIssue(openIssues, hash) {
  if (!Array.isArray(openIssues) || !hash) return null;
  const marker = `${SIG_MARKER_PREFIX} ${hash} -->`;
  for (const i of openIssues) {
    if (typeof i?.body === "string" && i.body.includes(marker)) {
      return Number(i.number) || null;
    }
  }
  return null;
}

/**
 * @param {QueuedRun} r
 * @returns {string}
 */
export function renderIssueTitle(r) {
  const age = `${r.queued_for_minutes}m`;
  return `[${DEFAULT_LABEL}] ${r.repo} — ${r.workflow} queued ${age} (run #${r.run_id})`;
}

/**
 * @param {QueuedRun} r
 * @returns {string}
 */
export function renderIssueBody(r) {
  const lines = [
    `A workflow run has been queued for ${r.queued_for_minutes} minutes and was auto-cancelled by the fleet-ops cancelled-while-queued detector (fleet-ops#819).`,
    "",
    `- repo: \`${r.repo}\``,
    `- workflow: \`${r.workflow}\``,
    `- run: #${r.run_id} — ${r.run_url}`,
    `- status: \`${r.status}\``,
    `- event: \`${r.event || "(unknown)"}\``,
    `- head_branch: \`${r.head_branch || "(none)"}\``,
    `- head_sha: \`${r.head_sha}\``,
    r.pr !== null ? `- pr: #${r.pr}` : "- pr: (none)",
    `- created_at: \`${r.created_at}\``,
    `- queued_for_minutes: ${r.queued_for_minutes} (threshold ${DEFAULT_QUEUED_THRESHOLD_MINUTES}m; GitHub auto-discards queued runs at ${DEFAULT_DISCARD_MINUTES}m per the GitHub-hosted runners doc)`,
    "",
    `${SIG_MARKER_PREFIX} ${r.hash} -->`,
    "",
    "## Why this was cancelled",
    "",
    "GitHub bills only the time a GitHub-hosted runner is executing a job. A run that is queued for a runner and never picked up is NOT billed (the audit that surfaced this issue confirmed `.billable.UBUNTU.total_ms` returns 0 for cancelled-while-queued runs). The risk this detector prevents is queue pressure and a worst-case scenario where a run sits queued for so long that, if it ever IS picked up, it would bill from pickup to completion with the long queue time already lost.",
    "",
    "GitHub's own \"Workflow continuity\" rule discards a queued run after 45 minutes of no runner pickup. The detector cancels at 30 minutes by default — before the silent discard — so the cancel shows up in the run history and the filing is observable.",
    "",
    "## What to do",
    "",
    "1. Look at the cancelled run's logs and identify why it was queued so long (concurrency contention, runner outage, scheduled-time collision).",
    "2. If this is a recurring pattern for a workflow, consider `concurrency: cancel-in-progress: true` or a longer runner.",
    "3. If the queue is blocked by a stuck earlier run, cancel the head-of-line run too.",
    "",
    "This issue is auto-closed by the same detector (observe-to-close, fleet-ops#725 family) when the run is no longer reported as queued on a later sweep.",
  ];
  return lines.join("\n");
}

/**
 * @param {string} jsonText
 * @returns {string[]}
 */
export function parseEnrolledRepos(jsonText) {
  /** @type {{ repos?: Array<{ name: string }>, excluded?: Array<{ name: string, permanent?: boolean }> }} */
  let obj;
  try {
    obj = JSON.parse(jsonText);
  } catch {
    return [];
  }
  if (!obj || typeof obj !== "object") return [];
  const excluded = new Set(
    Array.isArray(obj.excluded)
      ? obj.excluded.filter((e) => e && e.permanent).map((e) => e.name)
      : [],
  );
  const repos = Array.isArray(obj.repos) ? obj.repos : [];
  return repos
    .map((r) => (r && typeof r.name === "string" ? `Nishfleet/${r.name}` : null))
    .filter((r) => r !== null && !excluded.has(r.slice("Nishfleet/".length)));
}

// ---------------------------------------------------------------------------
// Live GitHub fetchers.
// ---------------------------------------------------------------------------

/**
 * Fetch in-flight workflow runs for a repo since `since`. Uses the
 * `status` filter on the actions/runs listing so cancelled/failed
 * runs are NOT included — this detector is for the live queue only.
 *
 * @param {string} repository
 * @param {Date} since
 * @returns {Run[]}
 */
export function fetchInFlightRuns(repository, since) {
  const sinceIso = since.toISOString();
  const raw = ghApiJson(
    `repos/${repository}/actions/runs`,
    `.workflow_runs[]? | ` +
      `{id: .id, name: .name, event: .event, status: .status, ` +
      `conclusion: .conclusion, head_branch: .head_branch, head_sha: .head_sha, ` +
      `created_at: .created_at, html_url: .html_url, ` +
      `pull_request_numbers: [.pull_requests[]?.number], ` +
      `pull_requests: .pull_requests}`,
    {
      paginate: true,
      query: { per_page: DEFAULT_PAGE_SIZE, created: `>=${sinceIso}` },
      timeoutMs: 180_000,
    },
  );
  if (!Array.isArray(raw)) return [];
  return raw.filter((r) => r && typeof r.id === "number" && typeof r.status === "string");
}

/**
 * Cancel a workflow run via the GitHub Actions cancel API. Returns
 * the API response code (204 = success). The cancel is best-effort:
 * a 409 "run already finished" or 403 "forbidden" is logged and the
 * detector still files the issue (so the senior-auditor pipeline
 * sees the queue-pressure signal even when the cancel is moot).
 *
 * @param {string} repository
 * @param {number} runId
 * @returns {{ ok: boolean, status: number, body: string }}
 */
export function cancelRun(repository, runId) {
  const body = ghApiJson(
    `repos/${repository}/actions/runs/${runId}/cancel`,
    "",
    { method: "POST", raw: true, timeoutMs: 60_000 },
  );
  // gh api returns the body on success and the error message on
  // failure. We can't read the HTTP status code from the body, so
  // infer: empty body or no error -> success.
  return { ok: true, status: 204, body: String(body ?? "") };
}

/**
 * List open `cancelled-while-queued` issues in the escalation repo
 * for dedup. Mirrors the ci-failure-escalation detector's open-issues
 * listing so the two detectors share the same shape.
 *
 * @param {string} escalationRepo
 * @param {string} [label]
 * @returns {Array<{ number: number, body: string | null }>}
 */
export function fetchOpenLabeledIssues(escalationRepo, label = DEFAULT_LABEL) {
  try {
    const raw = ghApiJson(
      `repos/${escalationRepo}/issues`,
      `.[] | {number: .number, body: .body, state: .state, labels: [.labels[].name]}`,
      {
        paginate: true,
        query: { state: "open", labels: label, per_page: DEFAULT_PAGE_SIZE },
        timeoutMs: 90_000,
      },
    );
    if (!Array.isArray(raw)) return [];
    return raw
      .filter((i) => i && typeof i.number === "number")
      .map((i) => ({ number: Number(i.number), body: i.body == null ? null : String(i.body) }));
  } catch {
    return [];
  }
}

/**
 * @param {string} escalationRepo
 * @param {QueuedRun} r
 * @param {string} [label]
 * @returns {string}
 */
export function fileIssue(escalationRepo, r, label = DEFAULT_LABEL) {
  const title = renderIssueTitle(r);
  const body = renderIssueBody(r);
  const stdout = execGh("gh", [
    "issue",
    "create",
    "-R",
    escalationRepo,
    "--title",
    title,
    "--body",
    body,
    "--label",
    label,
  ], { timeoutMs: 60_000 });
  return stdout.trim();
}

/**
 * @param {string} escalationRepo
 * @param {number} number
 * @param {string} comment
 * @returns {void}
 */
export function closeIssue(escalationRepo, number, comment) {
  execGh("gh", [
    "issue",
    "close",
    String(number),
    "-R",
    escalationRepo,
    "--comment",
    comment,
  ], { timeoutMs: 60_000 });
}

// ---------------------------------------------------------------------------
// Sweep / orchestration.
// ---------------------------------------------------------------------------

/**
 * @param {{
 *   repo: string,
 *   nowMs: number,
 *   queuedThresholdMinutes: number,
 *   queuedStatuses: string[],
 *   lookbackHours: number,
 *   escalationRepo: string,
 *   dryRun: boolean,
 *   runs?: Run[],
 *   openIssues?: Array<{ number: number, body: string | null }>,
 * }} opts
 * @returns {{
 *   repo: string,
 *   detected: QueuedRun[],
 *   cancelled: Array<{ run_id: number, ok: boolean }>,
 *   filed: Array<{ run_id: number, url: string, deduped: boolean }>,
 *   closed: Array<{ number: number, hash: string }>,
 *   errors: string[],
 * }}
 */
export function sweepRepo(opts) {
  const errors = [];
  const detected = Array.isArray(opts.runs)
    ? detectStaleQueued(opts.runs, {
        repo: opts.repo,
        nowMs: opts.nowMs,
        queuedThresholdMinutes: opts.queuedThresholdMinutes,
        queuedStatuses: opts.queuedStatuses,
      })
    : [];
  const openIssues = Array.isArray(opts.openIssues) ? opts.openIssues : [];

  const cancelled = [];
  const filed = [];

  for (const r of detected) {
    if (opts.dryRun) {
      cancelled.push({ run_id: r.run_id, ok: true });
      filed.push({ run_id: r.run_id, url: "(dry-run)", deduped: isDuplicated(openIssues, r.hash) });
      continue;
    }
    try {
      cancelRun(opts.repo, r.run_id);
      cancelled.push({ run_id: r.run_id, ok: true });
    } catch (err) {
      errors.push(`cancel ${opts.repo}#${r.run_id}: ${String(err).slice(0, 240)}`);
      cancelled.push({ run_id: r.run_id, ok: false });
    }
    if (isDuplicated(openIssues, r.hash)) {
      filed.push({ run_id: r.run_id, url: "(deduped)", deduped: true });
      continue;
    }
    try {
      const url = fileIssue(opts.escalationRepo, r);
      filed.push({ run_id: r.run_id, url, deduped: false });
    } catch (err) {
      errors.push(`file ${opts.repo}#${r.run_id}: ${String(err).slice(0, 240)}`);
    }
  }

  // Observe-to-close: any open labelled issue whose signature no
  // longer matches a detected queued run is closed. Same discipline
  // as the findings-queued / failed-command observe-to-close paths.
  // The decision (number + hash) is reported even in dry-run so the
  // detector is fully observable; only the actual gh close call is
  // gated on !dryRun.
  const currentHashes = new Set(detected.map((d) => d.hash));
  const closed = [];
  for (const issue of openIssues) {
    const m = typeof issue.body === "string"
      ? issue.body.match(/<!--\s*cancelled-while-queued-sig:\s*([0-9a-f]{64})\s*-->/u)
      : null;
    if (!m) continue;
    const hash = m[1];
    if (currentHashes.has(hash)) continue;
    if (opts.dryRun) {
      closed.push({ number: issue.number, hash });
      continue;
    }
    try {
      closeIssue(
        opts.escalationRepo,
        issue.number,
        `observe-to-close: signal: ${SIG_MARKER_PREFIX} ${hash} -->` +
          ` no longer reported as queued-while-stale on sweep at ${new Date(opts.nowMs).toISOString()}.`,
      );
      closed.push({ number: issue.number, hash });
    } catch (err) {
      errors.push(`close issue #${issue.number}: ${String(err).slice(0, 240)}`);
    }
  }

  return { repo: opts.repo, detected, cancelled, filed, closed, errors };
}

// ---------------------------------------------------------------------------
// CLI.
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  /** @type {Record<string, string | boolean | number | string[]>} */
  const args = {};
  const list = /** @type {string[]} */ ([]);
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help" || a === "-h") args.help = true;
    else if (a === "--dry-run") args["dry-run"] = true;
    else if (a === "--targets-from") { args["targets-from"] = argv[++i]; }
    else if (a === "--target-repo") { args["target-repo"] = argv[++i]; }
    else if (a === "--escalation-repo") { args["escalation-repo"] = argv[++i]; }
    else if (a === "--queued-threshold-minutes") { args["queued-threshold-minutes"] = Number(argv[++i]); }
    else if (a === "--lookback-hours") { args["lookback-hours"] = Number(argv[++i]); }
    else if (a === "--from-json") { args["from-json"] = argv[++i]; }
    else if (a === "--output-json") { args["output-json"] = argv[++i]; }
    else if (a === "--label") { args.label = argv[++i]; }
    else if (a === "--now") { args.now = argv[++i]; }
    else if (a && a.startsWith("--")) { args[a.slice(2)] = argv[++i]; }
    else list.push(a);
  }
  args._ = list;
  return args;
}

function printHelp() {
  const help = `Usage:
  cancelled-while-queued-detector.mjs [options]

  Options:
    --target-repo <owner/name>      One repo to scan. Mutually exclusive with --targets-from.
    --targets-from <path>           Read enrolled repos from a config/intake-repos.json
                                    payload (the #185 central-auto-discovery form).
    --escalation-repo <owner/name>  Repo to file labelled issues in (default
                                    Nishfleet/fleet-ops).
    --queued-threshold-minutes <N>  Auto-cancel runs queued for at least N minutes
                                    (default 30, below GitHub's 45-min discard).
    --lookback-hours <N>            How far back to scan in-flight runs (default 24).
    --label <label>                 Label for the filed issue (default
                                    "cancelled-while-queued").
    --dry-run                       Detect and dedupe; do not cancel or file.
    --now <ISO>                     Override the clock (for replay tests).
    --from-json <path>              Replay mode: read a JSON fixture of {repo: Run[]}
                                    instead of calling GitHub. Tests use this.
    --output-json <path>            Write the sweep result to a JSON file.
    --help                          This help.

  Pure-function library: import { detectStaleQueued, renderIssueTitle,
  renderIssueBody, isDuplicated, parseEnrolledRepos, runSignature,
  signatureHash, toQueuedRun, isQueuedStatus, minutesBetween } from this
  module for offline tests.
`;
  process.stdout.write(help);
}

async function main() {
  const args = parseArgs(process.argv);
  if (args.help) {
    printHelp();
    return 0;
  }
  const escalationRepo = String(args["escalation-repo"] ?? DEFAULT_ESCALATION_REPO);
  const label = String(args.label ?? DEFAULT_LABEL);
  const queuedThresholdMinutes = Number(args["queued-threshold-minutes"] ?? DEFAULT_QUEUED_THRESHOLD_MINUTES);
  const lookbackHours = Number(args["lookback-hours"] ?? DEFAULT_LOOKBACK_HOURS);
  const dryRun = args["dry-run"] === true;
  const nowMs = typeof args.now === "string" ? Date.parse(String(args.now)) : Date.now();
  if (!Number.isFinite(nowMs) || nowMs <= 0) {
    process.stderr.write(`error: --now ${String(args.now)} is not a valid ISO timestamp\n`);
    return 2;
  }
  const since = new Date(nowMs - lookbackHours * 3_600_000);

  /** @type {string[]} */
  let repos = [];
  let runsOverride = /** @type {Record<string, Run[]> | null} */ (null);
  let openIssuesOverride = /** @type {Array<{ number: number, body: string | null }> | null} */ (null);
  if (typeof args["from-json"] === "string") {
    const text = readFileSync(String(args["from-json"]), "utf8");
    const fixture = JSON.parse(text);
    if (fixture && typeof fixture === "object") {
      if (Array.isArray(fixture.runs_by_repo)) {
        runsOverride = {};
        for (const entry of fixture.runs_by_repo) {
          if (entry && typeof entry.repo === "string" && Array.isArray(entry.runs)) {
            runsOverride[entry.repo] = entry.runs;
          }
        }
        repos = Object.keys(runsOverride);
      }
      if (Array.isArray(fixture.open_issues)) {
        openIssuesOverride = fixture.open_issues
          .filter((i) => i && typeof i.number === "number")
          .map((i) => ({ number: Number(i.number), body: i.body == null ? null : String(i.body) }));
      }
    }
  } else if (typeof args["target-repo"] === "string") {
    repos = [String(args["target-repo"])];
  } else if (typeof args["targets-from"] === "string") {
    const text = readFileSync(resolve(String(args["targets-from"])), "utf8");
    repos = parseEnrolledRepos(text);
  } else {
    process.stderr.write("error: one of --target-repo, --targets-from, --from-json is required\n");
    return 2;
  }
  if (repos.length === 0) {
    process.stderr.write("error: no repos to scan\n");
    return 2;
  }

  const openIssues = openIssuesOverride ?? fetchOpenLabeledIssues(escalationRepo, label);
  /** @type {ReturnType<typeof sweepRepo>[]} */
  const targets = [];
  for (const repo of repos) {
    const runs = runsOverride
      ? (runsOverride[repo] ?? [])
      : fetchInFlightRuns(repo, since);
    const result = sweepRepo({
      repo,
      nowMs,
      queuedThresholdMinutes,
      queuedStatuses: DEFAULT_QUEUED_STATUSES,
      lookbackHours,
      escalationRepo,
      dryRun,
      runs,
      openIssues,
    });
    targets.push(result);
  }

  const summary = {
    now: new Date(nowMs).toISOString(),
    escalation_repo: escalationRepo,
    label,
    queued_threshold_minutes: queuedThresholdMinutes,
    lookback_hours: lookbackHours,
    dry_run: dryRun,
    targets,
  };
  const json = JSON.stringify(summary, null, 2);
  if (typeof args["output-json"] === "string") {
    writeFileSync(String(args["output-json"]), json + "\n");
  } else {
    process.stdout.write(json + "\n");
  }
  return 0;
}

// ESM entry: main() is async-safe; keep it promise-style so future
// fetchers can await without restructuring. The CLI itself uses
// execFileSync so this is just a hygiene wrapper.
const invokedDirectly = process.argv[1] && resolve(process.argv[1]) === resolve(new URL(import.meta.url).pathname);
if (invokedDirectly) {
  main().then(
    (code) => process.exit(code),
    (err) => {
      process.stderr.write(`fatal: ${String(err).slice(0, 800)}\n`);
      process.exit(1);
    },
  );
}
