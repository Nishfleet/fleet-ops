#!/usr/bin/env node
// CI failure -> senior-auditor escalation bridge (fleet-ops#221).
//
// The gap (Nish 2026-08-26): every VPS-plane failure escalates to the senior
// auditors via the global OnFailure= -> stop-escalation pipeline, but
// GitHub-plane failures — red CI checks, failed workflows, red required
// checks on PRs — have detectors (auto-revert, red-on-main-watch, #124
// redispatch) and NO route into the escalation matrix. A new failing check
// dies as a red X unless a human hand-writes the escalation: the
// instance-not-class anti-pattern.
//
// This detector is the mechanical bridge. For a target repo it:
//   1. Samples recent failed workflow runs (lookback, default 6h).
//   2. Builds a failure signature (repo, workflow, job, step, assertion,
//      event) per failing job — the same shape as the repeat-deterministic
//      detector (fleet-ops#21), so a signature is stable across re-runs.
//   3. EXCLUDES failures another detector already owns mechanically:
//        - auto-revert: a CI-workflow failure on main (push to main).
//          auto-revert opens the revert PR; its own loop guard halts loud
//          on a red revert. Re-escalating here would duplicate.
//        - #124 redispatch: a failure on a claim/issue-* branch (an open
//          fleet-worker PR). The heartbeat re-dispatches a repair worker
//          and fails loud into paging after its 2-attempt budget. Owned.
//   4. Keeps signatures that REPEAT or PERSIST past one re-run: count >=
//      threshold (default 2 — one original + one re-run still failing)
//      within window-hours (default 6). A single transient red does not
//      escalate; the same check red twice does.
//   5. For each qualifying signature, FILE one labeled escalation issue
//      (`escalate-senior`) in the escalation repo (default
//      Nishfleet/fleet-ops) carrying the failure context: run link, repo,
//      check name, last green, signature hash.
//
// Bounds (the issue's "one escalation per failure signature per 6h, hash
// like stop-escalation, dedupe against open issues"):
//   - The signature is hashed (sha256). The issue body carries an HTML
//     comment marker `<!-- escalate-sig: <hash> -->`.
//   - Before filing, the detector lists OPEN `escalate-senior` issues in
//     the escalation repo and skips any signature whose hash marker is
//     already on an open issue. The open issues ARE the dedup ledger — no
//     separate seen.txt to drift. Filing a second escalation for the same
//     signature while the first is still open is the failure mode; this
//     prevents it. Once the first is closed (verdict landed), a fresh
//     recurrence after the 6h lookback window files a new one.
//
// Intake routing of the `escalate-senior` label to the pi-audit@ senior
// panel (the same three seniors + context-packet discipline as fleet-ops#146)
// is a separate follow-up: #146's panel infrastructure was reverted and is
// not on main. This bridge PRODUCES the labeled issues; #146's panel
// CONSUMES them. They compose. See the follow-up issue filed by #221.
//
// GitHub Actions minutes: public repos only, free. The detector reads gh CLI
// + GitHub REST API only; no paid services. It runs as a reusable workflow
// (workflow_call) and as a scheduled sweep in fleet-ops that enumerates
// enrolled repos from config/intake-repos.json (the #185 central-auto-
// discovery form — a repo created tomorrow is covered on the next sweep
// with nobody touching anything).
//
// Surface: gh CLI + GitHub REST API only. No paid services.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const DEFAULT_LOOKBACK_HOURS = 6;
const DEFAULT_WINDOW_HOURS = 6;
const DEFAULT_THRESHOLD = 2; // "repeats or persists past one re-run"
const DEFAULT_PAGE_SIZE = 100;
const DEFAULT_LABEL = "escalate-senior";
const DEFAULT_ESCALATION_REPO = "Nishfleet/fleet-ops";
const SIG_MARKER_PREFIX = "<!-- escalate-sig:";

// Workflows auto-revert owns (it watches workflow_run on "CI", branches=main).
// A failure of one of these on main is auto-revert's domain.
const DEFAULT_AUTO_REVERT_WORKFLOWS = ["CI"];
const DEFAULT_MAIN_BRANCH = "main";
// #124's heartbeat re-dispatches repair onto open fleet-worker PRs whose
// heads are claim/issue-* branches.
const DEFAULT_CLAIM_BRANCH_PREFIX = "claim/";

// GitHub Actions log annotation prefix — same as the repeat-deterministic
// detector. Real logs emit `##[error] <msg>` (brackets); the bracketless
// `##error <msg>` is the docs shorthand. Match both so the assertion (and
// thus the signature) is stable across real runs.
const ANNOTATION_PREFIX = /^##\[?(?:error|warning|notice)\]?\s*/u;
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
 *   hash: string,
 *   repo: string,
 *   workflow: string,
 *   job: string,
 *   step: string,
 *   assertion: string,
 *   event: string | null,
 *   count: number,
 *   first_at: string,
 *   last_at: string,
 *   runs: Array<{ run_id: number, run_url: string, created_at: string, head_branch: string | null }>,
 *   last_green: { run_id: number, run_url: string, created_at: string } | null,
 *   excluded_owner: string | null,
 * }} Escalation
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
      `escalation_exec_failed: ${command} ${args.join(" ")} :: ${detail.slice(0, 800)}`,
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
        // Skip stray warning text; well-formed objects parse cleanly.
      }
    }
    return out;
  }
  return JSON.parse(stdout);
}

/**
 * Strip the annotation wrapper and a leading log timestamp (in either
 * order) and collapse whitespace, without touching the message text. Mirrors
 * repeat-deterministic-detector.normalizeAssertion so a signature is stable
 * whether the assertion came from a real log or a fixture.
 *
 * @param {string | null | undefined} raw
 * @returns {string}
 */
export function normalizeAssertion(raw) {
  if (!raw) return "";
  let s = String(raw).replace(/\r/gu, "");
  s = s.replace(ANNOTATION_PREFIX, "");
  s = s.replace(LEADING_TS, "");
  s = s.replace(ANNOTATION_PREFIX, "");
  return s.replace(/\s+/gu, " ").trim();
}

/**
 * Pull the PR number off a workflow run. Merge-queue runs encode it in
 * head_branch (`gh-readonly-queue/<base>/pr-<N>-<sha>`); pull_request runs
 * populate `pull_requests`.
 *
 * @param {{ pull_request_numbers?: number[], pull_requests?: Array<{ number: number }>, head_branch?: string | null }} run
 * @returns {number | null}
 */
export function extractPrNumber(run) {
  const fromField = Array.isArray(run.pull_request_numbers) ? run.pull_request_numbers : [];
  if (fromField.length > 0 && Number.isFinite(fromField[0])) return Number(fromField[0]);
  const fromEmbed = Array.isArray(run.pull_requests) ? run.pull_requests : [];
  if (fromEmbed.length > 0 && fromEmbed[0] && Number.isFinite(fromEmbed[0].number)) {
    return Number(fromEmbed[0].number);
  }
  const branch = typeof run.head_branch === "string" ? run.head_branch : "";
  const m = branch.match(/\/pr-(\d+)-/u);
  return m ? Number(m[1]) : null;
}

/**
 * The failure signature: (repo, workflow, job, step, assertion, event).
 * Stable across re-runs of the same failing check. The event is part of the
 * tuple so a pull_request failure and a merge_group failure of the same
 * assertion are SEPARATE escalations (they have different owners and fixes).
 *
 * @param {Failure} f
 * @returns {string}
 */
export function signature(f) {
  const event = f.event ?? "(unknown)";
  return [f.repo, f.workflow, f.job, f.step, f.assertion, event].join("\u241F");
}

/**
 * @param {string} sig
 * @returns {string}
 */
export function signatureHash(sig) {
  return createHash("sha256").update(sig).digest("hex");
}

/**
 * Does auto-revert own this failure? auto-revert watches workflow_run on the
 * CI workflow, branches=[main]. A CI-workflow failure on main (event=push,
 * head_branch=main) is its domain: it opens the revert PR and halts loud on
 * a red revert. Re-escalating here duplicates.
 *
 * @param {{ workflow: string, event: string | null, head_branch: string | null }} run
 * @param {{ autoRevertWorkflows?: string[], mainBranch?: string }} [opts]
 * @returns {boolean}
 */
export function isAutoRevertHandled(run, opts = {}) {
  const workflows = new Set(opts.autoRevertWorkflows ?? DEFAULT_AUTO_REVERT_WORKFLOWS);
  const main = opts.mainBranch ?? DEFAULT_MAIN_BRANCH;
  return (
    workflows.has(run.workflow) &&
    run.event === "push" &&
    run.head_branch === main
  );
}

/**
 * Does #124's red-PR repair own this failure? The heartbeat re-dispatches a
 * repair worker onto any open fleet-worker PR whose head is a claim/issue-*
 * branch, and fails loud into paging after its 2-attempt budget. A failure
 * on a claim/* branch is its domain.
 *
 * @param {{ head_branch: string | null }} run
 * @param {{ claimBranchPrefix?: string }} [opts]
 * @returns {boolean}
 */
export function isRedPrRepairHandled(run, opts = {}) {
  const prefix = opts.claimBranchPrefix ?? DEFAULT_CLAIM_BRANCH_PREFIX;
  return typeof run.head_branch === "string" && run.head_branch.startsWith(prefix);
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
 * Group failures by signature, drop the ones auto-revert or #124 already
 * own, and keep signatures that repeat/persist at least `threshold` times
 * within `windowHours`. Returns one Escalation per qualifying signature,
 * most-recent first.
 *
 * @param {Failure[]} failures
 * @param {{ threshold?: number, windowHours?: number, autoRevertWorkflows?: string[], mainBranch?: string, claimBranchPrefix?: string, allRuns?: Array<{ id: number, name: string, event: string | null, conclusion: string | null, head_branch: string | null, created_at: string, html_url: string }> }} [opts]
 * @returns {Escalation[]}
 */
export function detectEscalations(failures, opts = {}) {
  const threshold = Math.max(1, opts.threshold ?? DEFAULT_THRESHOLD);
  const windowHours = Math.max(1, opts.windowHours ?? DEFAULT_WINDOW_HOURS);
  const windowMs = windowHours * 60 * 60 * 1000;
  const allRuns = Array.isArray(opts.allRuns) ? opts.allRuns : [];

  /** @type {Map<string, Failure[]>} */
  const groups = new Map();
  /** @type {Map<string, string | null>} */
  const excludedOwner = new Map();

  for (const f of failures) {
    const sig = signature(f);
    if (isAutoRevertHandled(f, opts)) {
      excludedOwner.set(sig, "auto-revert");
      continue;
    }
    if (isRedPrRepairHandled(f, opts)) {
      excludedOwner.set(sig, "#124-redispatch");
      continue;
    }
    if (!groups.has(sig)) groups.set(sig, []);
    groups.get(sig).push(f);
  }

  /** @type {Escalation[]} */
  const out = [];
  for (const [sig, group] of groups) {
    group.sort((a, b) => epochMs(a.created_at) - epochMs(b.created_at));
    // Sliding window: keep the signature if ANY window of windowHours
    // contains >= threshold failures. A cluster spread over >windowHours
    // with no dense sub-window stays quiet (the issue's 6h bound).
    let qualifies = false;
    if (group.length >= threshold) {
      for (let i = 0; i + threshold - 1 < group.length; i++) {
        const first = epochMs(group[i].created_at);
        const last = epochMs(group[i + threshold - 1].created_at);
        if (last - first <= windowMs) {
          qualifies = true;
          break;
        }
      }
    }
    if (!qualifies) continue;
    const first = group[0];
    const last = group[group.length - 1];
    const repo = first.repo;
    const lastGreen = findLastGreen(allRuns, first.workflow, epochMs(first.created_at));
    out.push({
      signature: sig,
      hash: signatureHash(sig),
      repo,
      workflow: first.workflow,
      job: first.job,
      step: first.step,
      assertion: first.assertion,
      event: first.event,
      count: group.length,
      first_at: first.created_at,
      last_at: last.created_at,
      runs: group.map((f) => ({
        run_id: f.run_id,
        run_url: f.run_url,
        created_at: f.created_at,
        head_branch: f.head_branch,
      })),
      last_green: lastGreen,
      excluded_owner: excludedOwner.get(sig) ?? null,
    });
  }
  out.sort((a, b) => epochMs(b.last_at) - epochMs(a.last_at));
  return out;
}

/**
 * Best-effort most-recent SUCCESSFUL run of `workflowName` before
 * `beforeMs`. Used to surface "last green" in the escalation context. Returns
 * null when there is no green baseline (the red-on-main-detector's
 * first-ever case) or when allRuns was not supplied.
 *
 * @param {Array<{ id: number, name: string, conclusion: string | null, created_at: string, html_url: string }>} allRuns
 * @param {string} workflowName
 * @param {number} beforeMs
 * @returns {{ run_id: number, run_url: string, created_at: string } | null}
 */
export function findLastGreen(allRuns, workflowName, beforeMs) {
  if (!Array.isArray(allRuns) || allRuns.length === 0) return null;
  let best = null;
  let bestMs = -Infinity;
  for (const r of allRuns) {
    if (!r || r.name !== workflowName || r.conclusion !== "success") continue;
    const ms = epochMs(r.created_at);
    if (ms >= beforeMs) continue;
    if (ms > bestMs) {
      bestMs = ms;
      best = { run_id: Number(r.id), run_url: String(r.html_url ?? ""), created_at: String(r.created_at ?? "") };
    }
  }
  return best;
}

/**
 * Does an open issue already carry this signature's hash marker? The open
 * issues ARE the dedup ledger — no separate seen.txt to drift.
 *
 * @param {Array<{ number: number, body: string | null }>} openIssues
 * @param {string} hash
 * @returns {boolean}
 */
export function isDuplicated(openIssues, hash) {
  if (!Array.isArray(openIssues) || openIssues.length === 0) return false;
  const marker = `${SIG_MARKER_PREFIX} ${hash} -->`;
  return openIssues.some(
    (i) => i && typeof i.body === "string" && i.body.includes(marker),
  );
}

/**
 * @param {Escalation} e
 * @returns {string}
 */
export function renderIssueTitle(e) {
  const jobPart = e.job || e.step || "(unknown job)";
  return `[escalate-senior] ${e.repo}: ${e.workflow}/${jobPart} failing repeatedly`;
}

/**
 * @param {Escalation} e
 * @returns {string}
 */
export function renderIssueBody(e) {
  const lines = [];
  lines.push("<!-- escalate-sig: " + e.hash + " -->");
  lines.push("");
  lines.push(
    "GitHub-plane failure escalation (fleet-ops#221). This check failed repeatedly and is NOT owned by auto-revert (main CI) or the #124 red-PR repair (claim/* worker PRs). Route to the senior-auditor panel per #146.",
  );
  lines.push("");
  lines.push("## Failure context");
  lines.push("- **Repo:** `" + e.repo + "`");
  lines.push("- **Workflow:** `" + e.workflow + "`");
  lines.push("- **Job / step:** `" + e.job + "` / `" + e.step + "`");
  lines.push("- **Assertion:** " + (e.assertion || "(no error annotation — see run logs)"));
  lines.push("- **Event:** `" + (e.event ?? "(unknown)") + "`");
  lines.push("- **Occurrences in window:** " + e.count + " (first " + e.first_at + ", last " + e.last_at + ")");
  lines.push("");
  lines.push("## Runs");
  for (const r of e.runs) {
    lines.push("- " + r.run_url + " (`" + (r.head_branch ?? "?") + "`, " + r.created_at + ")");
  }
  lines.push("");
  lines.push("## Last green");
  if (e.last_green) {
    lines.push("- " + e.last_green.run_url + " (" + e.last_green.created_at + ")");
  } else {
    lines.push("- _(no green baseline found in the lookback window — first-ever red for this workflow, treat as high-signal)_");
  }
  lines.push("");
  lines.push("## Verdict");
  lines.push("- [ ] agent-ready fix issue filed");
  lines.push("- [ ] justified dismissal (reason logged)");
  lines.push("");
  lines.push(
    "Signature hash: `" + e.hash + "`. One escalation per signature per 6h; deduped against open `escalate-senior` issues. Closing this issue releases the bound.",
  );
  return lines.join("\n");
}

/**
 * Read enrolled repos from a config/intake-repos.json payload. Returns
 * `Nishfleet/<name>` for each declared repo, excluding permanently-excluded
 * ones (fleet2, archived). The #185 central-auto-discovery form: a repo
 * enrolled tomorrow is swept on the next cycle with nobody touching anything.
 *
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
// Live GitHub fetchers. Mirrors repeat-deterministic-detector.mjs so the
// signature shape stays identical and the two detectors compose.
// ---------------------------------------------------------------------------

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
 * Fetch every run in the lookback window regardless of conclusion, for the
 * "last green" lookup. Cheap: only id/name/conclusion/head_branch/created_at
 * + html_url per page (no log fetches).
 *
 * @param {string} repository
 * @param {Date} since
 * @returns {Array<{ id: number, name: string, event: string | null, conclusion: string | null, head_branch: string | null, created_at: string, html_url: string }>}
 */
export function fetchAllRuns(repository, since) {
  const sinceIso = since.toISOString();
  const raw = ghApiJson(
    `repos/${repository}/actions/runs`,
    `.workflow_runs[]? | select(.created_at >= "${sinceIso}") | ` +
      `{id: .id, name: .name, event: .event, conclusion: .conclusion, ` +
      `head_branch: .head_branch, created_at: .created_at, html_url: .html_url}`,
    {
      paginate: true,
      query: { per_page: DEFAULT_PAGE_SIZE, created: `>=${sinceIso}` },
      timeoutMs: 180_000,
    },
  );
  return Array.isArray(raw) ? raw.filter((r) => r && r.id) : [];
}

/**
 * @param {string} repository
 * @param {number} runId
 * @returns {Array<{ id: number, name: string, html_url: string, conclusion: string | null, steps: Array<{ name: string, conclusion: string | null }> }>}
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
      const m = line.match(/##\[?error\]?\s*(.*)/u);
      if (m && m[1] && m[1].trim()) return normalizeAssertion(m[1]);
    }
    return "";
  } catch {
    return "";
  }
}

/**
 * Build Failure records from failed runs. Mirrors repeat-deterministic's
 * buildFailures: one Failure per failing (job, failing-step) pair, with the
 * assertion resolved from logs when `enrich` is true (falling back to the
 * step name so same-step failures still collapse).
 *
 * @param {string} repository
 * @param {ReturnType<typeof fetchFailedRuns>} runs
 * @param {{ enrich?: boolean, assertionResolver?: (repo: string, jobId: number) => string }} [opts]
 * @returns {Failure[]}
 */
export function buildFailures(repository, runs, opts = {}) {
  const enrich = opts.enrich !== false;
  /** @type {Failure[]} */
  const failures = [];
  for (const run of runs) {
    const pr = extractPrNumber(run);
    let jobs;
    try {
      jobs = fetchFailingJobs(repository, Number(run.id));
    } catch {
      continue;
    }
    for (const job of jobs) {
      const failingSteps = (job.steps || []).filter((s) => s && s.conclusion === "failure");
      const stepNames = failingSteps.length > 0 ? failingSteps.map((s) => s.name) : ["(run-level)"];
      for (const stepName of stepNames) {
        let assertion = "";
        if (enrich && job.id && opts.assertionResolver) {
          try {
            assertion = opts.assertionResolver(repository, Number(job.id));
          } catch {
            assertion = "";
          }
        } else if (enrich && job.id) {
          assertion = fetchJobAssertion(repository, Number(job.id));
        }
        if (!assertion) assertion = stepName;
        failures.push({
          repo: repository,
          workflow: String(run.name ?? ""),
          job: String(job.name ?? ""),
          step: String(stepName),
          assertion,
          run_id: Number(run.id),
          run_url: String(run.html_url ?? ""),
          job_id: job.id ?? null,
          job_url: String(job.html_url ?? ""),
          created_at: String(run.created_at ?? ""),
          event: run.event ?? null,
          head_branch: run.head_branch ?? null,
          head_sha: String(run.head_sha ?? ""),
          pr: Number.isFinite(pr) ? pr : null,
        });
      }
    }
  }
  return failures;
}

/**
 * List open `escalate-senior` issues in the escalation repo. The bodies are
 * the dedup ledger.
 *
 * @param {string} escalationRepo
 * @param {string} label
 * @returns {Array<{ number: number, body: string | null }>}
 */
export function fetchOpenEscalations(escalationRepo, label) {
  const raw = ghApiJson(
    `repos/${escalationRepo}/issues`,
    `.[]? | {number: .number, body: .body}`,
    {
      paginate: true,
      query: { per_page: DEFAULT_PAGE_SIZE, state: "open", labels: label },
      timeoutMs: 60_000,
    },
  );
  return Array.isArray(raw) ? raw.filter((i) => i && Number.isFinite(i.number)) : [];
}

/**
 * File one escalation issue. Returns the new issue number, or null on
 * failure (a single filing failure does not abort the whole sweep).
 *
 * @param {string} escalationRepo
 * @param {Escalation} e
 * @param {{ label?: string }} [opts]
 * @returns {number | null}
 */
export function fileEscalation(escalationRepo, e, opts = {}) {
  const label = opts.label ?? DEFAULT_LABEL;
  const title = renderIssueTitle(e);
  const body = renderIssueBody(e);
  try {
    const num = execGh("gh", [
      "issue", "create",
      "--repo", escalationRepo,
      "--title", title,
      "--body", body,
      "--label", label,
    ], { timeoutMs: 60_000 });
    const n = Number((num || "").trim().split("/").pop());
    return Number.isFinite(n) && n > 0 ? n : null;
  } catch (error) {
    console.error(
      `file_failed on ${escalationRepo} sig=${e.hash.slice(0, 12)}: ${error instanceof Error ? error.message : String(error)}`,
    );
    return null;
  }
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function printUsage() {
  process.stdout.write(
    [
      "Usage: ci-failure-escalation-detector.mjs [options]",
      "",
      "Bridge GitHub-plane CI failures into the senior-auditor escalation matrix.",
      "",
      "  --target-repo <owner/name>    One repo to scan (default: env ESCALATION_TARGET_REPO).",
      "  --targets-from <path>         Read enrolled repos from a config/intake-repos.json file.",
      "  --escalation-repo <owner/name> Repo to file escalate-senior issues in (default Nishfleet/fleet-ops).",
      "  --lookback-hours <n>          Sample window for failed runs (default 6).",
      "  --window-hours <n>            Repeat window per signature (default 6).",
      "  --threshold <n>               Occurrences to escalate (default 2: one + one re-run).",
      "  --label <name>                Escalation label (default escalate-senior).",
      "  --from-json <path>            Fixture mode: {failures, all_runs, open_issues, repository}; no gh calls.",
      "  --output-json <path>          Write the report JSON here.",
      "  --dry-run                     Detect + render only; do not file issues.",
      "  --help                        Show this message.",
      "",
    ].join("\n"),
  );
}

/**
 * @param {string[]} argv
 * @returns {{
 *   targetRepo: string, targetsFrom: string, escalationRepo: string,
 *   lookbackHours: number, windowHours: number, threshold: number,
 *   label: string, fromJson: string, outputJson: string, dryRun: boolean,
 * }}
 */
function parseArgs(argv) {
  const args = {
    targetRepo: process.env.ESCALATION_TARGET_REPO ?? "",
    targetsFrom: "",
    escalationRepo: process.env.ESCALATION_REPO ?? DEFAULT_ESCALATION_REPO,
    lookbackHours: DEFAULT_LOOKBACK_HOURS,
    windowHours: DEFAULT_WINDOW_HOURS,
    threshold: DEFAULT_THRESHOLD,
    label: DEFAULT_LABEL,
    fromJson: "",
    outputJson: "",
    dryRun: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else if (arg === "--target-repo") {
      args.targetRepo = argv[++i] ?? "";
    } else if (arg === "--targets-from") {
      args.targetsFrom = argv[++i] ?? "";
    } else if (arg === "--escalation-repo") {
      args.escalationRepo = argv[++i] ?? DEFAULT_ESCALATION_REPO;
    } else if (arg === "--lookback-hours") {
      args.lookbackHours = Number(argv[++i]) || DEFAULT_LOOKBACK_HOURS;
    } else if (arg === "--window-hours") {
      args.windowHours = Math.max(1, Number(argv[++i]) || DEFAULT_WINDOW_HOURS);
    } else if (arg === "--threshold") {
      args.threshold = Math.max(1, Number(argv[++i]) || DEFAULT_THRESHOLD);
    } else if (arg === "--label") {
      args.label = argv[++i] ?? DEFAULT_LABEL;
    } else if (arg === "--from-json") {
      args.fromJson = argv[++i] ?? "";
    } else if (arg === "--output-json") {
      args.outputJson = argv[++i] ?? "";
    } else if (arg === "--dry-run") {
      args.dryRun = true;
    }
  }
  if (!args.targetRepo && !args.targetsFrom && !args.fromJson) {
    console.error("Missing required --target-repo / --targets-from / --from-json");
    printUsage();
    process.exit(2);
  }
  return args;
}

/**
 * @param {unknown} payload
 * @returns {{ failures: Failure[], allRuns: Array<{ id: number, name: string, conclusion: string | null, created_at: string, html_url: string }>, openIssues: Array<{ number: number, body: string | null }>, repository: string }}
 */
function fixtureFromPayload(payload) {
  /** @type {{ failures?: unknown, all_runs?: unknown, open_issues?: unknown, repository?: unknown }} */
  const obj = payload && typeof payload === "object" ? /** @type {any} */ (payload) : {};
  const list = Array.isArray(obj.failures) ? obj.failures : [];
  const failures = list.map((f) => {
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
  const allRuns = Array.isArray(obj.all_runs)
    ? obj.all_runs
        .map((r) => r && typeof r === "object" ? {
            id: Number(r.id),
            name: String(r.name ?? ""),
            conclusion: typeof r.conclusion === "string" ? r.conclusion : null,
            created_at: String(r.created_at ?? ""),
            html_url: String(r.html_url ?? ""),
          } : null)
        .filter((r) => r && Number.isFinite(r.id))
    : [];
  const openIssues = Array.isArray(obj.open_issues)
    ? obj.open_issues
        .map((i) => i && typeof i === "object" ? { number: Number(i.number), body: i.body ?? null } : null)
        .filter((i) => i && Number.isFinite(i.number))
    : [];
  return {
    failures,
    allRuns,
    openIssues,
    repository: typeof obj.repository === "string" ? obj.repository : "fixture",
  };
}

/**
 * Process one target repo. Returns the escalations that were (or would be)
 * filed. In fixture mode, no gh calls are made and `filed` carries the
 * would-be issue titles/bodies instead of issue numbers.
 *
 * @param {{ targetRepo: string, failures: Failure[], allRuns: Array<{ id: number, name: string, conclusion: string | null, created_at: string, html_url: string }>, openIssues: Array<{ number: number, body: string | null }>, escalationRepo: string, threshold: number, windowHours: number, label: string, dryRun: boolean, fixture: boolean }} ctx
 * @returns {{ escalations: Escalation[], filed: Array<{ hash: string, number: number | null, title: string, deduped: boolean }> }}
 */
function processTarget(ctx) {
  const escalations = detectEscalations(ctx.failures, {
    threshold: ctx.threshold,
    windowHours: ctx.windowHours,
    allRuns: ctx.allRuns,
  });
  /** @type {Array<{ hash: string, number: number | null, title: string, deduped: boolean }>} */
  const filed = [];
  for (const e of escalations) {
    if (isDuplicated(ctx.openIssues, e.hash)) {
      filed.push({ hash: e.hash, number: null, title: renderIssueTitle(e), deduped: true });
      continue;
    }
    if (ctx.dryRun || ctx.fixture) {
      filed.push({ hash: e.hash, number: null, title: renderIssueTitle(e), deduped: false });
      continue;
    }
    const num = fileEscalation(ctx.escalationRepo, e, { label: ctx.label });
    filed.push({ hash: e.hash, number: num, title: renderIssueTitle(e), deduped: false });
  }
  return { escalations, filed };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const now = new Date();

  /** @type {Array<{ target: string, escalations: Escalation[], filed: Array<{ hash: string, number: number | null, title: string, deduped: boolean }> }>} */
  const perTarget = [];

  if (args.fromJson) {
    const payload = JSON.parse(readFileSync(resolve(args.fromJson), "utf8"));
    const fx = fixtureFromPayload(payload);
    const r = processTarget({
      targetRepo: fx.repository,
      failures: fx.failures,
      allRuns: fx.allRuns,
      openIssues: fx.openIssues,
      escalationRepo: args.escalationRepo,
      threshold: args.threshold,
      windowHours: args.windowHours,
      label: args.label,
      dryRun: args.dryRun,
      fixture: true,
    });
    perTarget.push({ target: fx.repository, ...r });
  } else {
    /** @type {string[]} */
    const targets = [];
    if (args.targetsFrom) {
      const enrolled = parseEnrolledRepos(readFileSync(resolve(args.targetsFrom), "utf8"));
      targets.push(...enrolled);
    }
    if (args.targetRepo) targets.push(args.targetRepo);
    // De-dup the target list while preserving order.
    const seen = new Set();
    const uniqTargets = targets.filter((t) => {
      if (seen.has(t)) return false;
      seen.add(t);
      return true;
    });
    if (uniqTargets.length === 0) {
      console.error("No target repos to scan (empty intake-repos.json and no --target-repo).");
      process.exit(2);
    }
    for (const target of uniqTargets) {
      const since = new Date(now.getTime() - args.lookbackHours * 60 * 60 * 1000);
      let runs;
      let allRuns = [];
      try {
        runs = fetchFailedRuns(target, since);
        allRuns = fetchAllRuns(target, since);
      } catch (error) {
        console.error(
          `fetch_failed on ${target}: ${error instanceof Error ? error.message : String(error)} — skipping`,
        );
        perTarget.push({ target, escalations: [], filed: [] });
        continue;
      }
      const failures = buildFailures(target, runs, { enrich: true });
      let openIssues = [];
      if (!args.dryRun) {
        try {
          openIssues = fetchOpenEscalations(args.escalationRepo, args.label);
        } catch (error) {
          console.error(
            `open_issues_fetch_failed on ${args.escalationRepo}: ${error instanceof Error ? error.message : String(error)} — proceeding without dedup (may duplicate; safe because filing is idempotent via the marker)`,
          );
        }
      }
      const r = processTarget({
        targetRepo: target,
        failures,
        allRuns,
        openIssues,
        escalationRepo: args.escalationRepo,
        threshold: args.threshold,
        windowHours: args.windowHours,
        label: args.label,
        dryRun: args.dryRun,
        fixture: false,
      });
      perTarget.push({ target, ...r });
    }
  }

  const report = {
    generated_at: now.toISOString(),
    escalation_repo: args.escalationRepo,
    lookback_hours: args.lookbackHours,
    window_hours: args.windowHours,
    threshold: args.threshold,
    label: args.label,
    dry_run: args.dryRun,
    targets: perTarget,
  };
  const json = JSON.stringify(report, null, 2);
  console.log(json);
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n## CI failure -> senior-auditor escalation bridge\n\n\`\`\`json\n${json}\n\`\`\`\n`);
  }
  if (args.outputJson) writeFileSync(resolve(args.outputJson), json);
}

const invokedDirectly = process.argv[1] && resolve(process.argv[1]) === resolve(new URL(import.meta.url).pathname);
if (invokedDirectly) {
  main().catch((error) => {
    console.error(`fatal: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  });
}
