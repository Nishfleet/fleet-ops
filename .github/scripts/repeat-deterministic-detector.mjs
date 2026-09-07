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
// Repo-scoped blocking (--block). The detector can gate a PR's own repo:
//   - Blocking (exit 1) applies ONLY to signatures in the PR's OWN
//     repository (repeat.repo === the --own-repo / GITHUB_REPOSITORY context).
//     A same-repo repeat-deterministic loop is, by definition, a loop the PR
//     cannot safely re-arm past — that is the stop-the-line signal.
//   - Cross-repo signatures (e.g. a 0509 'Deploy production' cluster sampled
//     from a fleet-ops PR gate) are ADVISORY: reported via the PR comment and
//     the report, but never a failing check for the fleet-ops PR. The failing
//     repo's OWN detector instance files its tracking issue (fleet-issue-file)
//     where it holds write scope; the gate cannot write across a repo boundary.
//   - A cluster only blocks when its LAST failure falls inside the lookback
//     window anchored to `now` (nowMs - lookbackHours). The live fetcher
//     already bounds samples to created_at >= now-lookback, so this holds by
//     construction live; the explicit guard (--now) makes the anchor visible
//     and deterministic for fixture/regression runs.
//   - A signature whose FIX PR references its tracking issue
//     (`Fixes #N` / `Closes #N` / `Resolves #N` in the gated PR body) is
//     excluded from blocking that PR: a PR that fixes the loop must not be
//     blocked for the same signature.
//
// Blocking is opt-in via --block so the alert-only telemetry path stays
// unchanged (exit 0 with repeats reported).
//
// Surface: gh CLI + GitHub REST API only. No paid services.

import { execFileSync } from "node:child_process";
import { existsSync, appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const DEFAULT_LOOKBACK_HOURS = 6;
const DEFAULT_THRESHOLD = 3;
const DEFAULT_WINDOW_HOURS = 6;
const DEFAULT_TOP_SIGNATURES = 10;
const DEFAULT_PAGE_SIZE = 100;
const COMMENT_MARKER = "<!-- repeat-deterministic-detector -->";

// Resolved once: the fleet-issue-file dedupe wrapper (fleet-ops#1212). It is
// the "existing fleet-issue-file" the blocking/cross-repo contract names —
// filing-time dedupe against open issues, so one signature gets at most one
// tracking issue.
const DETECTOR_SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const FLEET_ISSUE_FILE = resolve(DETECTOR_SCRIPT_DIR, "../../bin/fleet-issue-file");

// GitHub Actions log annotation prefix. Real GitHub logs emit
// `##[error] <msg>` (with brackets), not the bracketless `##error <msg>`
// the docs use as shorthand. The detector must match BOTH forms — the
// issue fleet-ops#21 names the bracket form verbatim ("first ##[error]
// assertion line"), and the real 0509 ratchet failures only emit the
// bracket form from vitest assertions. A regex that misses one keeps the
// whole headline diagnostic invisible. The trailing whitespace is
// optional because GitHub itself sometimes omits it (e.g. timestamp lines
// emit `##[error]<msg>` with no separator).
const ANNOTATION_PREFIX = /^##\[?(?:error|warning|notice)\]?\s*/u;
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
 *   event: string,
 *   count: number,
 *   threshold: number,
 *   window_hours: number,
 *   first_at: string,
 *   last_at: string,
 *   runs: Array<{ run_id: number, run_url: string, created_at: string, pr: number | null }>,
 * }} Repeat
 *
 * @typedef {{
 *   signature: string,
 *   repo: string,
 *   workflow: string,
 *   job: string,
 *   step: string,
 *   assertion: string,
 *   event: string,
 *   count: number,
 *   first_at: string,
 *   last_at: string,
 *   runs: Array<{ run_id: number, run_url: string, created_at: string, pr: number | null }>,
 * }} FailureSignature
 *
 * @typedef {{
 *   event: string,
 *   total: number,
 *   failed: number,
 *   failure_rate: number,
 * }} EventSplitRow
 *
 * @typedef {{
 *   rows: EventSplitRow[],
 *   failed_total: number,
 *   total_runs: number,
 *   divergence_pp: number,
 *   primary: { pr: EventSplitRow, queue: EventSplitRow } | null,
 * }} EventSplit
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
  // order (`##[error] <ts> msg` or `<ts> ##[error] msg`), so strip each
  // twice. Order matters: the timestamp precedes `##[error]` in raw logs.
  // The wrapper regex accepts BOTH `##[error]` (real GitHub format) and
  // the bracketless `##error` shorthand — both show up across CI tooling.
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
 * The signature is the full tuple the issue names:
 *   (repo, workflow, job, step, assertion, triggering event)
 * Event is part of the key because a pull_request failure and a merge_group
 * failure of the same assertion are different contexts — the PR-vs-queue
 * split is the diagnosis, so collapsing them would hide it. Null/unknown
 * events coerce to "(unknown)" so a fixture without an event still groups
 * deterministically.
 *
 * @param {Failure} f
 * @returns {string}
 */
export function signature(f) {
  return [f.repo, f.workflow, f.job, f.step, f.assertion, f.event ?? "(unknown)"].join("\u241F");
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
      event: head.event ?? "(unknown)",
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
 * Decide which repeat clusters BLOCK the pipeline (the exit-1 gate). A
 * cluster blocks ONLY when ALL of the following hold:
 *
 *   - SAME-REPO: repeat.repo === ownRepo, the repo the gated PR belongs to.
 *     Cross-repo clusters (e.g. a 0509 'Deploy production' loop sampled from
 *     a fleet-ops PR gate) are ADVISORY — reported, but never a failing
 *     check for the fleet-ops PR (the deadlock this fix removes).
 *   - IN-WINDOW: its LAST failure is inside the lookback window anchored to
 *     `now` (nowMs - lookbackHours). The live fetcher bounds samples to
 *     created_at >= now-lookback, so this holds by construction live; the
 *     explicit guard (--now) makes the anchor deterministic in tests.
 *   - NOT FIXED: the gated PR body does not reference the signature's
 *     tracking issue with a `Fixes`/`Closes`/`Resolves #N` trailer. A PR
 *     that fixes the filed issue must not block itself on that signature.
 *
 * When ownRepo is empty (no repo context) nothing blocks — an unscoped run
 * cannot know what is "own", so it stays alert-only.
 *
 * @param {Repeat[]} repeats
 * @param {{ ownRepo: string, nowMs: number, lookbackHours?: number, prBody?: string, signatureIssues?: Array<{ signature: string, number: number }> }} opts
 * @returns {Repeat[]}
 */
export function selectBlockingRepeats(repeats, opts = {}) {
  const ownRepo = opts.ownRepo ?? "";
  if (!ownRepo) return [];
  const nowMs = Number.isFinite(opts.nowMs) ? opts.nowMs : Date.now();
  const lookbackMs = (opts.lookbackHours ?? DEFAULT_LOOKBACK_HOURS) * 60 * 60 * 1000;
  const windowStart = nowMs - lookbackMs;
  const fixRe = /(?:fixes|closes|resolves)\s+#(\d+)/giu;
  const fixedIssues = new Set();
  const prBody = opts.prBody ?? "";
  for (const m of prBody.matchAll(fixRe)) fixedIssues.add(Number(m[1]));
  const issueForSig = new Map((opts.signatureIssues ?? []).map((si) => [si.signature, Number(si.number)]));
  return (repeats ?? []).filter((r) => {
    if (r.repo !== ownRepo) return false; // cross-repo: advisory, never a failing check
    const last = Date.parse(r.last_at);
    if (!Number.isFinite(last) || last < windowStart || last > nowMs) {
      return false; // not inside the now-anchored lookback (or in the future)
    }
    const issueNum = issueForSig.get(r.signature);
    if (issueNum !== undefined && fixedIssues.has(issueNum)) return false; // fix PR references its issue
    return true;
  });
}

/**
 * Best-effort open-issue lookup: map each repeat signature to the number of
 * the open tracking issue that carps it (matched by the detector marker +
 * the signature in the issue body). This is what lets a later FIX PR
 * reference the issue and un-block the same signature. Best-effort: a failed
 * lookup returns an empty map (no fix-exclusion possible), never a crash.
 *
 * @param {string} repo
 * @param {Repeat[]} repeats
 * @returns {Map<string, number>}
 */
export function fetchSignatureIssues(repo, repeats) {
  const found = new Map();
  try {
    const issues = /** @type {Array<{ number: number, body: string | null }> | null} */ (
      ghApiJson(
        `repos/${repo}/issues`,
        `.[] | {number: .number, body: .body}`,
        {
          query: { state: "open", per_page: DEFAULT_PAGE_SIZE },
          paginate: true,
          timeoutMs: 60_000,
        },
      )
    );
    if (!Array.isArray(issues)) return found;
    for (const it of issues) {
      if (!it || typeof it.body !== "string") continue;
      for (const r of repeats) {
        if (found.has(r.signature)) continue;
        if (it.body.includes(COMMENT_MARKER) && it.body.includes(r.signature)) {
          found.set(r.signature, Number(it.number));
        }
      }
    }
  } catch (error) {
    console.error(
      `tracking_issue_lookup_failed on ${repo}: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  return found;
}

/**
 * File (or dedupe to) ONE tracking issue for a repeat signature in its own
 * repo via the existing fleet-issue-file wrapper. Only invoked live for the
 * blockable (same-repo) repeats so the fix-PR-exclusion cycle has a real
 * issue to reference. Best-effort: a filing failure logs and continues — it
 * must never crash the gate.
 *
 * @param {string} repo
 * @param {Repeat} repeat
 * @returns {boolean}
 */
export function ensureTrackingIssue(repo, repeat) {
  const title = `repeat-deterministic (fleet-ops gate): ${repeat.workflow} / ${repeat.job} / ${repeat.step}`.slice(0, 200);
  const body = [
    COMMENT_MARKER,
    "",
    renderAlert(repeat),
    "",
    `Signature: \`${repeat.signature}\``,
    "",
    "Tracked by the repeat-deterministic PR gate. A PR fixing this signature " +
      "references this issue (`Fixes #N`) to un-block itself.",
  ].join("\n");
  try {
    if (existsSync(FLEET_ISSUE_FILE)) {
      execFileSync(
        FLEET_ISSUE_FILE,
        ["-R", repo, "--title", title, "--body", body],
        { encoding: "utf8", env: process.env, timeout: 60_000, stdio: ["ignore", "pipe", "pipe"] },
      );
    } else {
      execFileSync(
        "gh",
        ["issue", "create", "-R", repo, "--title", title, "--body", body],
        { encoding: "utf8", env: process.env, timeout: 60_000 },
      );
    }
    return true;
  } catch (error) {
    console.error(
      `tracking_issue_file_failed on ${repo}: ${error instanceof Error ? error.message : String(error)}`,
    );
    return false;
  }
}

/**
 * Summarize every failure signature in the sample — NOT only those that
 * crossed the repeat-deterministic threshold. The headline "21.8% CI
 * failure rate" is meaningless without decomposition: the same assertion
 * firing 6 times is one root cause, not six. This function is the
 * decomposition. It returns all signatures sorted by count desc (then
 * most-recent-first as a stable tiebreak), so the top-N view is the
 * diagnosis, not the totals.
 *
 * The signature is `(repo, workflow, job, step, assertion, event)` — the
 * tuple the issue names verbatim. Event is part of the key because a
 * pull_request failure and a merge_group failure of the same assertion are
 * DIFFERENT contexts; the PR-vs-queue split is the diagnosis, so
 * collapsing them would hide it.
 *
 * `limit` defaults to DEFAULT_TOP_SIGNATURES (10) and is clamped to >= 1.
 * Passing a large number returns every distinct signature.
 *
 * @param {Failure[]} failures
 * @param {{ limit?: number }} [opts]
 * @returns {FailureSignature[]}
 */
export function summarizeSignatures(failures, opts = {}) {
  const limit = Math.max(1, Math.floor(opts.limit ?? DEFAULT_TOP_SIGNATURES));
  /** @type {Map<string, Failure[]>} */
  const groups = new Map();
  for (const f of failures) {
    if (!f || !f.created_at) continue;
    const key = signature(f);
    const list = groups.get(key) ?? [];
    list.push(f);
    groups.set(key, list);
  }
  /** @type {FailureSignature[]} */
  const out = [];
  for (const [, list] of groups) {
    const sorted = list.slice().sort((a, b) => {
      const ai = epochMs(a.created_at);
      const bi = epochMs(b.created_at);
      if (ai === bi) return 0;
      return ai < bi ? -1 : 1;
    });
    const head = sorted[0];
    const tail = sorted[sorted.length - 1];
    out.push({
      signature: signature(head),
      repo: head.repo,
      workflow: head.workflow,
      job: head.job,
      step: head.step,
      assertion: head.assertion,
      event: head.event ?? "(unknown)",
      count: sorted.length,
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
  out.sort((a, b) => {
    if (a.count !== b.count) return b.count - a.count;
    // Tiebreak: most-recent failure wins — "what is on fire NOW" is more
    // diagnostic than "what fired first historically".
    const ai = epochMs(a.last_at);
    const bi = epochMs(b.last_at);
    if (ai !== bi) return ai < bi ? 1 : -1;
    return a.signature.localeCompare(b.signature);
  });
  return out.slice(0, limit);
}

/**
 * Bucket all runs (failed + total) by triggering event so the headline rate
 * decomposes into pull_request vs merge_group vs push vs ... The issue
 * names this number explicitly: "9.6% vs 21% — that gap is the diagnosis."
 * A headline rate with no decomposition cannot drive any action.
 *
 * Inputs:
 *   - failures: every failed run the detector knows about (already
 *     derived from `fetchFailedRuns`, so each failure has an event field).
 *   - totalRuns: the full set of runs in the same lookback window
 *     (any conclusion). When omitted (e.g. fixture mode), we fall back to
 *     counting failed runs only — the split still says what fraction of
 *     failures came from each event, which is a useful signal even without
 *     the true rate.
 *
 * Output rows are sorted by event name for deterministic output. The
 * `primary` field pairs pull_request and merge_group specifically so the
 * headline number is one-line greppable in the rendered report.
 *
 * `divergence_pp` is the merge_group rate minus the pull_request rate,
 * expressed in percentage points. A positive divergence says "queue runs
 * fail more often than PR runs" — the single most diagnostic number for
 * whether failures are semantic merge conflicts (queue-side gap) or flaky
 * tests (no gap, both events similar).
 *
 * @param {Failure[]} failures
 * @param {Array<{ event: string | null }>} [totalRuns]
 * @returns {EventSplit}
 */
export function summarizeEventSplit(failures, totalRuns) {
  /** @type {Map<string, number>} */
  const totalByEvent = new Map();
  if (Array.isArray(totalRuns)) {
    for (const r of totalRuns) {
      if (!r) continue;
      const ev = r.event ?? "(unknown)";
      totalByEvent.set(ev, (totalByEvent.get(ev) ?? 0) + 1);
    }
  }
  /** @type {Map<string, number>} */
  const failedByEvent = new Map();
  for (const f of failures) {
    if (!f) continue;
    const ev = f.event ?? "(unknown)";
    failedByEvent.set(ev, (failedByEvent.get(ev) ?? 0) + 1);
  }
  const allEvents = new Set([...totalByEvent.keys(), ...failedByEvent.keys()]);
  /** @type {EventSplitRow[]} */
  const rows = [];
  for (const event of allEvents) {
    const total = totalByEvent.get(event) ?? 0;
    const failed = failedByEvent.get(event) ?? 0;
    // When totalRuns is unknown (fixture mode, omitted) we still report the
    // failed count, and the rate field is `null` (NaN -> null at render time)
    // so the JSON does not lie about a percentage that was never measured.
    const rate = total > 0 ? failed / total : Number.NaN;
    rows.push({
      event,
      total,
      failed,
      failure_rate: Number.isFinite(rate) ? rate : 0,
    });
  }
  rows.sort((a, b) => (a.event < b.event ? -1 : a.event > b.event ? 1 : 0));
  const failedTotal = failures.length;
  const totalRunsCount = Array.isArray(totalRuns) ? totalRuns.length : 0;
  const pr = rows.find((r) => r.event === "pull_request") ?? null;
  const queue = rows.find((r) => r.event === "merge_group") ?? null;
  let divergence = Number.NaN;
  if (pr && queue && Number.isFinite(pr.failure_rate) && Number.isFinite(queue.failure_rate)) {
    divergence = (queue.failure_rate - pr.failure_rate) * 100;
  }
  return {
    rows,
    failed_total: failedTotal,
    total_runs: totalRunsCount,
    divergence_pp: Number.isFinite(divergence) ? divergence : 0,
    primary: pr && queue ? { pr, queue } : null,
  };
}

/**
 * @param {Repeat} repeat
 * @returns {string}
 */
export function renderAlert(repeat) {
  const plural = repeat.count === 1 ? "time" : "times";
  return (
    `Failure signature "${repeat.workflow} / ${repeat.job} / ${repeat.step}"` +
    ` (event=${repeat.event}) failed ${repeat.count} ${plural} in ${repeat.window_hours}h` +
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
 *   blocking?: Repeat[],
 *   top_signatures?: FailureSignature[],
 *   event_split?: EventSplit,
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
  lines.push("");
  if (Array.isArray(report.blocking)) {
    if (report.blocking.length === 0) {
      lines.push("Blocking repeats (same-repo, in-window, not fix-excluded): none — PR gate stays green");
    } else {
      lines.push(`Blocking repeats (PR GATE FAIL): ${report.blocking.length}`);
      for (const repeat of report.blocking) {
        lines.push(`  - ${renderAlert(repeat).replace(/\r?\n/gu, " ")}`);
      }
    }
  }
  lines.push("");
  lines.push(renderTopSignaturesSection(report.top_signatures ?? []));
  lines.push(renderEventSplitSection(report.event_split ?? null));
  return lines.join("\n");
}

/**
 * @param {FailureSignature[]} signatures
 * @returns {string}
 */
export function renderTopSignaturesSection(signatures) {
  const lines = [];
  if (signatures.length === 0) {
    lines.push("Top failure signatures: none (no failures sampled)");
    return lines.join("\n");
  }
  lines.push(`Top failure signatures: ${signatures.length} (count desc, most-recent first as tiebreak)`);
  for (let i = 0; i < signatures.length; i++) {
    const s = signatures[i];
    const tail = s.assertion ? ` :: ${s.assertion}` : "";
    lines.push(
      `  ${String(i + 1).padStart(2)}. [${s.event}] ${s.workflow} / ${s.job} / ${s.step} x${s.count}${tail}`,
    );
    lines.push(`        ${s.first_at} -> ${s.last_at} | ${s.runs.length} run url(s)`);
  }
  return lines.join("\n");
}

/**
 * @param {EventSplit | null} split
 * @returns {string}
 */
export function renderEventSplitSection(split) {
  if (!split || split.rows.length === 0) {
    return "Event split: none";
  }
  const lines = [];
  lines.push(
    `Event split: ${split.failed_total} failures across ${split.rows.length} event type(s)` +
      (split.total_runs > 0 ? ` (${split.total_runs} total runs sampled)` : " (true rate unavailable)"),
  );
  for (const row of split.rows) {
    const rate = split.total_runs > 0 ? ` (${(row.failure_rate * 100).toFixed(2)}%)` : "";
    lines.push(`  - ${row.event.padEnd(14)} failed=${String(row.failed).padStart(4)}${rate}`);
  }
  if (split.primary) {
    const { pr, queue } = split.primary;
    const prPct = split.total_runs > 0 ? ` (${(pr.failure_rate * 100).toFixed(2)}%)` : "";
    const queuePct = split.total_runs > 0 ? ` (${(queue.failure_rate * 100).toFixed(2)}%)` : "";
    const div = Number.isFinite(split.divergence_pp)
      ? `${split.divergence_pp >= 0 ? "+" : ""}${split.divergence_pp.toFixed(2)}pp`
      : "n/a";
    lines.push(
      `  pull_request${prPct} vs merge_group${queuePct} — divergence: ${div}` +
        ` (>0 means queue-side gap, the semantic-merge-conflict signature)`,
    );
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
 * Fetch every run in the lookback window regardless of conclusion — needed
 * to compute the true `pull_request` vs `merge_group` failure rate (the
 * issue's headline diagnostic). Pulls only `id, conclusion, event` per
 * page (no log fetches) so the call stays cheap.
 *
 * The same `created >= since` filter is applied as `fetchFailedRuns` so the
 * failure rate is computed over an identical window.
 *
 * @param {string} repository
 * @param {Date} since
 * @returns {Array<{ id: number, event: string | null, conclusion: string | null, created_at: string }>}
 */
export function fetchAllRuns(repository, since) {
  const sinceIso = since.toISOString();
  const raw = ghApiJson(
    `repos/${repository}/actions/runs`,
    `.workflow_runs[]? | select(.created_at >= "${sinceIso}") | ` +
      `{id: .id, event: .event, conclusion: .conclusion, created_at: .created_at}`,
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
      const m = line.match(/##\[?error\]?\s*(.*)/u);
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
 * @param {{ repeats: Repeat[], top_signatures?: FailureSignature[], event_split?: EventSplit }} report
 * @param {boolean} emitAnnotations
 */
export function emitGithubAnnotations(report, emitAnnotations) {
  if (!emitAnnotations) return;
  const blocking = new Set((report.blocking ?? []).map((r) => r.signature));
  for (const repeat of report.repeats) {
    const msg = renderAlert(repeat).replace(/\r?\n/gu, " ");
    // Same-repo blockable repeats are hard errors (they gate). Cross-repo
    // repeats, and non-blocking repeats, are advisory warnings.
    console.error(`::${blocking.has(repeat.signature) ? "error" : "warning"} title=REPEAT-DETERMINISTIC::${msg}`);
  }
  if (report.event_split?.primary) {
    const { pr, queue } = report.event_split.primary;
    const prPct = (pr.failure_rate * 100).toFixed(2);
    const queuePct = (queue.failure_rate * 100).toFixed(2);
    const div = report.event_split.divergence_pp.toFixed(2);
    console.error(
      `::notice title=CI EVENT RATE::pull_request=${prPct}% merge_group=${queuePct}% divergence=${div}pp`,
    );
  }
}

function printUsage() {
  console.log(`Usage: repeat-deterministic-detector.mjs [options]

Options:
  --repo <owner/name>       Target repository (default: env REPEAT_DETERMINISTIC_REPO)
  --lookback-hours <n>      Hours of recent failed runs to sample (default: ${DEFAULT_LOOKBACK_HOURS})
  --threshold <n>           Failures needed to fire (default: ${DEFAULT_THRESHOLD})
  --window-hours <n>        Sliding window in hours (default: ${DEFAULT_WINDOW_HOURS})
  --top-signatures <n>      How many top failure signatures to publish (default: ${DEFAULT_TOP_SIGNATURES})
  --from-json <path>        Replay stored failures (no GitHub). Fixture tests use this.
  --format <human|json>     Output format (default: human)
  --output-json <path>      Also write the report JSON to this file
  --comment                 Emit PR-comment breadcrumbs (off by default)
  --block                   Enable exit-1 PR gating on same-repo repeats
  --own-repo <owner/name>   The PR's own repo (default: env GITHUB_REPOSITORY)
  --pr-body <path>          File with the gated PR body (fix-PR exclusion)
  --now <iso>               "Now" anchor for the lookback window (tests)
  --no-enrich               Do not fetch job logs for assertion text
  --no-event-split          Skip fetching the full-run set for the event-rate split
  --help                    Show this message
`);
}

function parseArgs(argv) {
  const args = {
    repo: process.env.REPEAT_DETERMINISTIC_REPO ?? "",
    lookbackHours: DEFAULT_LOOKBACK_HOURS,
    threshold: DEFAULT_THRESHOLD,
    windowHours: DEFAULT_WINDOW_HOURS,
    topSignatures: DEFAULT_TOP_SIGNATURES,
    fromJson: "",
    format: "human",
    outputJson: "",
    comment: false,
    block: false,
    ownRepo: "",
    prBody: "",
    nowMs: Date.now(),
    enrich: true,
    eventSplit: true,
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
    } else if (arg === "--top-signatures") {
      args.topSignatures = Math.max(1, Number(argv[++i]) || DEFAULT_TOP_SIGNATURES);
    } else if (arg === "--from-json") {
      args.fromJson = argv[++i] ?? "";
    } else if (arg === "--format") {
      args.format = (argv[++i] ?? "human").toLowerCase();
    } else if (arg === "--output-json") {
      args.outputJson = argv[++i] ?? "";
    } else if (arg === "--comment") {
      args.comment = true;
    } else if (arg === "--block") {
      args.block = true;
    } else if (arg === "--own-repo") {
      args.ownRepo = argv[++i] ?? "";
    } else if (arg === "--pr-body") {
      args.prBody = argv[++i] ?? "";
    } else if (arg === "--now") {
      const parsed = Date.parse(argv[++i] ?? "");
      if (Number.isFinite(parsed)) args.nowMs = parsed;
    } else if (arg === "--no-enrich") {
      args.enrich = false;
    } else if (arg === "--no-event-split") {
      args.eventSplit = false;
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
 * @returns {{ failures: Failure[], totalRuns: Array<{ id: number, event: string | null, conclusion: string | null, created_at: string }> | null, signatureIssues: Array<{ signature: string, number: number }> }}
 */
function failuresFromFixture(payload) {
  /** @type {{ failures?: unknown, total_runs?: unknown, signature_issues?: unknown, repository?: unknown }} */
  const obj = Array.isArray(payload) || payload === null || typeof payload !== "object"
    ? /** @type {{ failures?: unknown }} */ ({})
    : /** @type {{ failures?: unknown, total_runs?: unknown, signature_issues?: unknown, repository?: unknown }} */ (payload);
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
  let totalRuns = null;
  if (Array.isArray(obj.total_runs)) {
    totalRuns = obj.total_runs
      .map((r) => {
        if (!r || typeof r !== "object") return null;
        const rec = /** @type {{ id?: unknown, event?: unknown, conclusion?: unknown, created_at?: unknown }} */ (r);
        const id = Number(rec.id);
        if (!Number.isFinite(id) || id <= 0) return null;
        return {
          id,
          event: typeof rec.event === "string" ? rec.event : null,
          conclusion: typeof rec.conclusion === "string" ? rec.conclusion : null,
          created_at: String(rec.created_at ?? ""),
        };
      })
      .filter((r) => r !== null);
  }
  const signatureIssues =
    Array.isArray(obj.signature_issues)
      ? obj.signature_issues
          .filter((si) => si && typeof si === "object")
          .map((si) => {
            const rec = /** @type {{ signature?: unknown, number?: unknown }} */ (si);
            return { signature: String(rec.signature ?? ""), number: Number(rec.number) };
          })
          .filter((si) => si.signature && Number.isFinite(si.number))
      : [];
  return { failures, totalRuns, signatureIssues };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const now = new Date();
  const nowMs = args.nowMs;
  let repository = args.repo;
  /** @type {Failure[]} */
  let failures;
  /** @type {Array<{ id: number, event: string | null, conclusion: string | null, created_at: string }> | null} */
  let totalRuns = null;
  /** @type {Array<{ signature: string, number: number }>} */
  let parsedSignatureIssues = [];
  // The gated PR's body, used only for the fix-PR exclusion (a PR that
  // `Fixes #<tracking>` its own signature must not block itself). Lenient:
  // a missing/unreadable file logs and treats the exclusion as empty.
  let prBodyText = "";
  if (args.prBody) {
    try {
      prBodyText = readFileSync(resolve(args.prBody), "utf8");
    } catch (error) {
      console.error(
        `could_not_read_pr_body ${args.prBody}: ${error instanceof Error ? error.message : String(error)} — treating as no fix-exclusion`,
      );
    }
  }

  if (args.fromJson) {
    const payload = JSON.parse(readFileSync(resolve(args.fromJson), "utf8"));
    if (!repository && payload && typeof payload === "object" && payload.repository) {
      repository = String(payload.repository);
    }
    if (!repository) repository = "fixture";
    const parsed = failuresFromFixture(payload);
    failures = parsed.failures;
    totalRuns = parsed.totalRuns;
    parsedSignatureIssues = parsed.signatureIssues ?? [];
  } else {
    const since = new Date(now.getTime() - args.lookbackHours * 60 * 60 * 1000);
    const runs = fetchFailedRuns(args.repo, since);
    if (args.eventSplit) {
      try {
        totalRuns = fetchAllRuns(args.repo, since);
      } catch (error) {
        // Event-split fetch is best-effort: a single failure here must not
        // suppress the repeat-deterministic signal the alert exists for.
        console.error(
          `event_split_fetch_failed on ${args.repo}: ${error instanceof Error ? error.message : String(error)}`,
        );
        totalRuns = null;
      }
    }
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
  // Top failure signatures: every distinct tuple ranked by count desc. The
  // headline rate cannot drive action without this decomposition. Limit is
  // configurable via --top-signatures; default 10.
  const topSignatures = summarizeSignatures(failures, { limit: args.topSignatures });
  // Repo-scoped PR gate: when --block is set, exit 1 iff a repeat is in the
  // PR's OWN repo, inside the now-anchored lookback, and not excluded by a
  // fix-PR reference. Cross-repo repeats stay advisory (never block).
  const blocking = [];
  if (args.block) {
    const ownRepo = args.ownRepo || process.env.GITHUB_REPOSITORY || "";
    if (!ownRepo) {
      console.error("--block requires --own-repo or GITHUB_REPOSITORY (the PR's own repo) to scope blocking");
      process.exit(2);
    }
    if (!args.fromJson) {
      // Live: ensure a tracking issue exists for each same-repo repeat so a
      // later fix PR can reference it (fleet-issue-file dedupes). Best-effort.
      for (const r of repeats) {
        if (r.repo === ownRepo) ensureTrackingIssue(ownRepo, r);
      }
    }
    const signatureIssues = args.fromJson
      ? parsedSignatureIssues
      : Array.from(fetchSignatureIssues(ownRepo, repeats).entries())
          .map(([signature, number]) => ({ signature, number }));
    blocking.push(
      ...selectBlockingRepeats(repeats, {
        ownRepo,
        nowMs,
        lookbackHours: args.lookbackHours,
        prBody: prBodyText,
        signatureIssues,
      }),
    );
  }
  // pull_request vs merge_group failure-rate split. The issue's headline
  // number is uninformative without it: a 12-point gap says "queue-side
  // failure" (semantic merge conflicts), while a small gap says "flaky".
  const eventSplit = summarizeEventSplit(failures, totalRuns ?? undefined);
  const report = {
    generated_at: now.toISOString(),
    repository,
    lookback_hours: args.lookbackHours,
    threshold: args.threshold,
    window_hours: args.windowHours,
    failures_sampled: failures.length,
    repeats,
    blocking: args.block ? blocking : undefined,
    top_signatures: topSignatures,
    event_split: eventSplit,
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
      `blocking=${blocking.length}`,
      `failures-sampled=${failures.length}`,
      `top-signatures=${topSignatures.length}`,
      `event-split=${eventSplit.primary ? "computed" : "missing"}`,
      `divergence-pp=${Number.isFinite(eventSplit.divergence_pp) ? eventSplit.divergence_pp.toFixed(2) : "n/a"}`,
    ];
    appendFileSync(process.env.GITHUB_OUTPUT, `${lines.join("\n")}\n`);
  }

  // The gate: exit 1 only when a same-repo, in-window, unexcluded repeat
  // was found. Cross-repo repeats never fail the PR's own check.
  if (blocking.length > 0) process.exitCode = 1;
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
