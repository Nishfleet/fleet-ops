#!/usr/bin/env node
// Stop-the-line detector (fleet-ops#1457).
//
// Trunk-based CD canon: trunk stays green; when the pipeline goes red,
// fixing it preempts new merges ("stop the line"). The auto-revert machinery
// (live on 6 repos as of 2026-08-26) already detects the HALT verdict —
// "infra fault across consecutive commits, HALT" — and writes a loud halt
// issue. What it does NOT do is freeze the merge queue: armed auto-merge
// kept landing green PRs onto a red pipeline, each triggering a doomed
// 12-minute deploy run, a failure email, and a red Auto revert run. Live
// count: ~20 PRs merged onto red overnight 2026-08-27→28
// (Nishfleet/0509#1347-1351 + Nishfleet/0509#1354).
//
// This detector is the mechanical stop-the-line. For a target repo it:
//
//   1. Samples recent completed workflow runs on main (lookback, default 90m).
//      90m is wider than a typical CI run but narrower than the alert surface
//      (red-on-main-watch at 20m) so a single missed tick still catches up.
//   2. Walks main's recent SHAs in order. For each SHA, finds the workflow
//      runs that ran for that push (head_sha matches). For each workflow,
//      keeps a 1-deep "last run was red?" memory.
//
//      A HALT is declared when the SAME workflow goes red on TWO consecutive
//      main SHAs. This is the exact condition the existing halt issue
//      already names; the regression is that the halt issue never stopped the
//      merges. The detector now ALSO freezes the line, by writing a
//      `stop-the-line` label on a single open issue in the repo. The
//      auto-merge-arm workflow checks for this label before arming — see
//      `.github/workflows/reusable-auto-merge-arm.yml`.
//
//      Auto-unfreeze on the next green run of THAT workflow: detector
//      closes the issue, the arm re-enables itself the next pull_request.
//      No human step. One notification per state transition (open / close).
//
//      The arm check is the mechanical safety net: even if a future detector
//      misses a red and forgets to open the issue, an open stop-the-line
//      issue (from any prior halt) still freezes the line until cleared.
//
//   3. PRs continue to run their full CI feedback. Only merging is frozen —
//      the auto-merge-arm refuses to arm while the issue is open (logs the
//      reason and waits for the PR to be merged by a human, or for the issue
//      to auto-close on the next green run).
//
//   4. The detector is idempotent on the open issue: it reuses the existing
//      one instead of opening duplicates (title-based dedup, mirroring the
//      fleet-ops#596 / auto-revert.sh halt path). On the green-runs-again
//      transition it closes that ONE issue and posts a one-line
//      "auto-unfrozen" comment so the alert path can fire a single
//      transition event, not one per merge (the issue's "One notification
//      on the state TRANSITION" requirement).
//
// Bounds (the issue's "respect the per-repo rollout list" + "alert paths
// terminate in dispatch, not in Nish's inbox"):
//   - GitHub App installation tokens have issues:write + actions:read
//     (nishfleet-worker App; fleet-ops#1253). They cannot call the
//     users API (`/user` 403, fleet-ops#1253) but `whoami` works. The
//     detector never probes `/user`; it uses only repo-scoped REST.
//   - The detector runs as a workflow_run trigger AND a scheduled sweep
//     (the same workflow_run + schedule shape as red-on-main-watch.yml).
//     Schedule covers missed workflow_run ticks (the App does not currently
//     fan out to many consumers) and rate-limit blips.
//   - The `stop-the-line` label is created on demand (best-effort; if the
//     token cannot create the label the issue still opens — the title
//     carries the same key for dedup).
//
// Drill (the issue's "replay a red-consecutive scenario in a sandbox repo or
// workflow test and prove freeze + auto-unfreeze"):
//   - tests/stop-the-line-detector.test.sh runs the detector against a
//     fixture that simulates red-red consecutive + a green follow-up run,
//     proves the open/close transitions, and asserts auto-merge-arm exits
//     early when the issue is open. It does NOT require network or a
//     sandbox repo; the pure functions + --from-json replay form makes it
//     runnable anywhere with Node + git + bash.
//
// Surface: gh CLI + GitHub REST API only. No paid services.

import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_LOOKBACK_MINUTES = 90;
const DEFAULT_PAGE_SIZE = 100;
const DEFAULT_LABEL = "stop-the-line";
const DEFAULT_BRANCH = "main";
const COMMENT_MARKER_PREFIX = "<!-- stop-the-line:";

// Workflows the detector never treats as halt signals — these are
// observers/detectors on top of CI, not the CI signals themselves. A red
// detector run is an alert, not a pipeline failure. Matches the dedup set
// in auto-revert.sh: the verifier flow runs with --no-auto-merge (no
// required CI), so a red detector does not chain into halt.
const SKIP_WORKFLOWS = new Set([
  "Auto revert",
  "Auto-merge arm",
  "CI failure escalation bridge",
  "Red on main detector",
  "Red on main watch",
  "Stop-the-line detector",
  "Stop-the-line watch",
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
 * }} WorkflowRun
 *
 * @typedef {{
 *   action: "open" | "comment" | "close" | "noop",
 *   repository: string,
 *   workflow: string,
 *   reason: string,
 *   red_runs: Array<{run_id: number, run_url: string, head_sha: string, created_at: string}>,
 *   unfreeze_run: {run_id: number, run_url: string, head_sha: string, created_at: string} | null,
 *   open_issue_number: number | null,
 * }} Decision
 *
 * @typedef {{
 *   generated_at: string,
 *   repository: string,
 *   branch: string,
 *   lookback_minutes: number,
 *   runs_sampled: number,
 *   decision: Decision,
 * }} Report
 */

// ---------- pure helpers (no I/O) ----------------------------------------

/**
 * @param {string | null | undefined} name
 * @returns {boolean}
 */
export function isSkippedWorkflow(name) {
  if (!name) return false;
  return SKIP_WORKFLOWS.has(name);
}

/**
 * @param {WorkflowRun[]} runs
 * @returns {boolean}
 */
export function isMainBranchRun(runs, branch = DEFAULT_BRANCH) {
  if (!Array.isArray(runs)) return false;
  return runs.some((r) => r && r.head_branch === branch);
}

/**
 * Walk consecutive SHAs on the branch and decide whether the SAME workflow
 * went red on two consecutive SHAs (the HALT trigger). Pure, no I/O, safe
 * to unit-test with fixtures.
 *
 * A run is considered "the run for SHA N" only when head_sha exactly matches.
 * The runs input is the flat list returned by
 * `/repos/{repo}/actions/runs?branch=main&status=completed&per_page=N`. It
 * may be empty, in which case the verdict is "no halt".
 *
 * The state machine is per-workflow: track the last conclusion seen on the
 * previous SHA. If THIS SHA's only-conclusion for the workflow is red, the
 * workflow is "currently halted". The moment a green follows, the workflow
 * is "previously halted" and the freeze has lifted. The unfreeze path is
 * the green run that lifted the freeze.
 *
 * Concretely:
 *   - `halt=true` iff at least one workflow is "currently halted" (last
 *     two SHAs both red, with no green in between).
 *   - `unfreeze_candidate` is the most-recent green run for a workflow that
 *     WAS halted at some point in the lookback; the actuator closes the
 *     open issue when this is set AND an existing stop-the-line issue is
 *     open.
 *   - `halted_runs` names the runs that triggered the current halt (used in
 *     the freeze-issue body so the on-call has links without replaying
 *     run history).
 *
 * @param {WorkflowRun[]} runs
 * @param {{ branch?: string }} [opts]
 * @returns {{
 *   halt: boolean,
 *   halted_workflow: string | null,
 *   halted_runs: WorkflowRun[],
 *   last_run_for_halted: WorkflowRun | null,
 *   unfreeze_candidate: WorkflowRun | null,
 * }}
 */
export function classifyHalt(runs, opts = {}) {
  const branch = opts.branch ?? DEFAULT_BRANCH;
  const list = Array.isArray(runs) ? runs.slice() : [];
  if (list.length === 0) {
    return {
      halt: false,
      halted_workflow: null,
      halted_runs: [],
      last_run_for_halted: null,
      unfreeze_candidate: null,
    };
  }
  // Sort by created_at ascending so the walk follows SHAs over time.
  list.sort((a, b) => (a.created_at < b.created_at ? -1 : 1));

  /** @type {Map<string, WorkflowRun>} */
  const lastRunByWorkflow = new Map();
  /** @type {Map<string, WorkflowRun>} */
  const redOnPrevShaByWorkflow = new Map();
  /** @type {Set<string>} */
  const currentlyHalted = new Set();
  /** @type {Set<string>} */
  const everHalted = new Set();
  /** @type {Map<string, WorkflowRun[]>} */
  const haltedRunsByWorkflow = new Map();
  /** @type {Map<string, WorkflowRun>} */
  const unfreezeByWorkflow = new Map();

  let i = 0;
  while (i < list.length) {
    const sha = list[i].head_sha;
    /** @type {Map<string, {red: boolean, green: boolean, last: WorkflowRun}>} */
    const byWorkflow = new Map();
    while (i < list.length && list[i].head_sha === sha) {
      const run = list[i];
      if (run.head_branch && run.head_branch !== branch) {
        i += 1;
        continue;
      }
      if (isSkippedWorkflow(run.name)) {
        i += 1;
        continue;
      }
      const bucket = byWorkflow.get(run.name) ?? { red: false, green: false, last: run };
      if (run.conclusion === "failure") bucket.red = true;
      if (run.conclusion === "success") bucket.green = true;
      if (run.created_at > bucket.last.created_at) bucket.last = run;
      byWorkflow.set(run.name, bucket);
      i += 1;
    }

    for (const [name, b] of byWorkflow) {
      // Mixed red+green on the same SHA: the green outcome wins for THIS
      // SHA (the push produced at least one green run, the pipeline is
      // working — re-running clears it). Red means "the workflow went
      // red for this push and did NOT recover" (no other runs succeeded
      // for the same SHA). The two are disjoint in byWorkflow when a
      // single run is recorded for this SHA+workflow; we accept the mixed
      // case as green because GitHub records both successful and failed
      // runs and one green per push is enough.
      const outcomeFailed = b.red && !b.green;
      const outcomeCleared = b.green;
      const prevRed = redOnPrevShaByWorkflow.get(name) ?? null;

      if (outcomeFailed) {
        // Two consecutive red SHAs -> the halt trigger fires for this
        // workflow. Push both runs into the halted history so the issue
        // body has the urls without a follow-up run-history query.
        if (prevRed) {
          currentlyHalted.add(name);
          everHalted.add(name);
          const history = haltedRunsByWorkflow.get(name) ?? [];
          // Defensive dedupe; a workflow can halt across overlapping
          // SHA ranges when runs are re-queued for the same SHA.
          if (!history.some((r) => r.id === prevRed.id)) history.push(prevRed);
          if (!history.some((r) => r.id === b.last.id)) history.push(b.last);
          haltedRunsByWorkflow.set(name, history);
        }
        redOnPrevShaByWorkflow.set(name, b.last);
        lastRunByWorkflow.set(name, b.last);
      } else if (outcomeCleared) {
        // A green cleared any halt for this workflow. The green is the
        // unfreeze candidate if the workflow had ever been halted.
        if (currentlyHalted.has(name) || everHalted.has(name)) {
          unfreezeByWorkflow.set(name, b.last);
        }
        currentlyHalted.delete(name);
        redOnPrevShaByWorkflow.delete(name);
        lastRunByWorkflow.set(name, b.last);
      }
    }
  }

  if (currentlyHalted.size === 0 && unfreezeByWorkflow.size === 0) {
    return {
      halt: false,
      halted_workflow: null,
      halted_runs: [],
      last_run_for_halted: null,
      unfreeze_candidate: null,
    };
  }

  // Two paths:
  //   1. currentlyHalted is non-empty -> halt=true; pick the most-recent
  //      currently-halted workflow as the headline.
  //   2. currentlyHalted is empty AND unfreezeByWorkflow is non-empty ->
  //      halt=false with an unfreeze candidate; the actuator closes the
  //      existing stop-the-line issue.
  if (currentlyHalted.size > 0) {
    let chosenName = null;
    let chosenTail = null;
    for (const name of currentlyHalted) {
      const tail = lastRunByWorkflow.get(name) ?? null;
      if (!chosenName) {
        chosenName = name;
        chosenTail = tail;
        continue;
      }
      if (tail && chosenTail && tail.created_at > chosenTail.created_at) {
        chosenName = name;
        chosenTail = tail;
      } else if (tail && chosenTail && tail.created_at === chosenTail.created_at && name < chosenName) {
        chosenName = name;
        chosenTail = tail;
      }
    }
    return {
      halt: true,
      halted_workflow: chosenName,
      halted_runs: haltedRunsByWorkflow.get(chosenName) ?? [],
      last_run_for_halted: chosenTail,
      unfreeze_candidate: null,
    };
  }

  // No currently-halted workflow, but at least one was halted + unfrozen.
  // Pick the most-recent unfreeze candidate.
  let chosenUnfreeze = null;
  for (const run of unfreezeByWorkflow.values()) {
    if (!chosenUnfreeze || run.created_at > chosenUnfreeze.created_at) {
      chosenUnfreeze = run;
    }
  }
  return {
    halt: false,
    halted_workflow: chosenUnfreeze ? chosenUnfreeze.name : null,
    halted_runs: [],
    last_run_for_halted: null,
    unfreeze_candidate: chosenUnfreeze,
  };
}

/**
 * @param {{halted_workflow: string | null, halted_runs: WorkflowRun[]}} verdict
 * @returns {string}
 */
export function renderHaltReason(verdict) {
  if (!verdict.halted_workflow) return "";
  const wf = verdict.halted_workflow;
  const runs = verdict.halted_runs || [];
  if (runs.length === 0) return wf;
  const lines = runs
    .filter((r, idx, arr) => arr.findIndex((x) => x.id === r.id) === idx)
    .map((r) => {
      const shortSha = typeof r.head_sha === "string" ? r.head_sha.slice(0, 7) : "";
      return `  - \`${shortSha}\` ${r.conclusion} — ${r.html_url}`;
    });
  return `${wf}\n${lines.join("\n")}`;
}

/**
 * @param {Decision} decision
 * @returns {string}
 */
export function issueTitle(decision) {
  if (decision.action === "open") {
    return `stop-the-line: ${decision.repository} frozen — ${decision.workflow} red on consecutive commits`;
  }
  if (decision.action === "close") {
    return `stop-the-line: ${decision.repository} unfrozen — ${decision.workflow} green again`;
  }
  return `stop-the-line: ${decision.repository} ${decision.action}`;
}

/**
 * @param {Decision} decision
 * @returns {string}
 */
export function issueBody(decision) {
  const lines = [`${COMMENT_MARKER_PREFIX}workflow=${decision.workflow} -->`];
  lines.push("");
  if (decision.action === "open") {
    lines.push(
      `Repository is **frozen**. Auto-merge arming is paused until the next green run of the halted workflow.`,
    );
    lines.push("");
    lines.push(`- Halted workflow: \`${decision.workflow}\``);
    if (decision.red_runs.length > 0) {
      lines.push("- Consecutive red runs on main:");
      for (const r of decision.red_runs) {
        const shortSha = typeof r.head_sha === "string" ? r.head_sha.slice(0, 7) : "";
        lines.push(`  - \`${shortSha}\` — ${r.run_url}`);
      }
    }
    lines.push("- Freeze automatically clears on the next green run of this workflow (no human step).");
    lines.push("- CI on PRs continues — feedback is unchanged. Only merging is frozen.");
  } else if (decision.action === "close") {
    lines.push(
      `Repository is **unfrozen**. The halted workflow went green again; auto-merge arming has resumed.`,
    );
    lines.push("");
    lines.push(`- Unfreeze workflow: \`${decision.workflow}\``);
    if (decision.unfreeze_run) {
      const shortSha = typeof decision.unfreeze_run.head_sha === "string"
        ? decision.unfreeze_run.head_sha.slice(0, 7)
        : "";
      lines.push(`- Green run: ${decision.unfreeze_run.run_url} (\`${shortSha}\`)`);
    }
  } else {
    lines.push(decision.reason);
  }
  lines.push("");
  lines.push("_This issue is owned by the stop-the-line detector (fleet-ops#1457). It opens on HALT, closes on the next green run, and is the single source of truth for arming auto-merge._");
  return lines.join("\n");
}

// ---------- GitHub I/O (used only when not in --from-json mode) -----------

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
      `stop_the_line_exec_failed: ${command} ${args.join(" ")} :: ${detail.slice(0, 800)}`,
    );
  }
}

/**
 * @param {string} endpoint
 * @param {string} jq
 * @param {{ paginate?: boolean, query?: Record<string, string | number>, timeoutMs?: number }} [opts]
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
        // Skip stray warning text.
      }
    }
    return out;
  }
  return JSON.parse(stdout);
}

/**
 * @param {string} repository
 * @param {number} lookbackMinutes
 * @returns {WorkflowRun[]}
 */
function fetchRecentMainRuns(repository, lookbackMinutes) {
  const since = new Date(Date.now() - lookbackMinutes * 60_000);
  const sinceIso = since.toISOString();
  const raw = ghApiJson(
    `repos/${repository}/actions/runs`,
    `.workflow_runs[]? | select(.created_at >= "${sinceIso}") | ` +
      `{id: .id, name: .name, workflow_id: .workflow_id, event: .event, ` +
      `conclusion: .conclusion, head_branch: .head_branch, head_sha: .head_sha, ` +
      `created_at: .created_at, html_url: .html_url}`,
    {
      paginate: true,
      query: {
        per_page: DEFAULT_PAGE_SIZE,
        branch: DEFAULT_BRANCH,
        status: "completed",
        created: `>=${sinceIso}`,
      },
      timeoutMs: 180_000,
    },
  );
  const runs = Array.isArray(raw) ? raw : [];
  return runs.filter(
    (r) =>
      r &&
      typeof r.id === "number" &&
      typeof r.head_sha === "string" &&
      r.head_branch === DEFAULT_BRANCH &&
      !isSkippedWorkflow(r.name),
  );
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
        DEFAULT_LABEL,
        "--repo",
        repository,
        "--color",
        "B60205",
        "--description",
        "Stop-the-line: merging is frozen until the next green run of a halted workflow",
        "--force",
      ],
      { encoding: "utf8", env: process.env, stdio: ["ignore", "pipe", "pipe"], timeout: 30_000 },
    );
  } catch {
    // Label may already exist or token cannot manage labels; the issue
    // search below falls back to title-based dedup.
  }
}

/**
 * Find the existing open stop-the-line issue (if any) for this repo.
 *
 * Dedup has to handle the production fact that labels do not always stick
 * on issue-creation under app installation tokens (`gh issue create --label`
 * returns 0 but the label never lands on the issue). Same lesson as
 * `auto-revert.sh halt()`, fleet-ops#596. The title is constant
 * (`stop-the-line: <repo> frozen — <workflow>`), so title-matching catches
 * what label-matching misses.
 *
 * @param {string} repository
 * @returns {number | null}
 */
function findExistingIssue(repository) {
  try {
    const itemsRaw = execFileSync(
      "gh",
      [
        "issue",
        "list",
        "--repo",
        repository,
        "--state",
        "open",
        "--limit",
        "100",
        "--json",
        "number,title",
        "--jq",
        ".[]",
      ],
      { encoding: "utf8", env: process.env, maxBuffer: 64 * 1024 * 1024, timeout: 60_000 },
    );
    for (const line of itemsRaw.split(/\r?\n/u)) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const issue = JSON.parse(trimmed);
        if (
          typeof issue.title === "string" &&
          issue.title.includes("stop-the-line: ") &&
          issue.title.includes("frozen") &&
          Number.isFinite(issue.number)
        ) {
          return Number(issue.number);
        }
      } catch {
        // Skip stray lines.
      }
    }
  } catch {
    // List may fail (no permissions / no issues yet). Fall through.
  }
  return null;
}

/**
 * @param {string} repository
 * @param {string} title
 * @param {string} body
 * @returns {Promise<{number: number} | null>}
 */
async function createIssue(repository, title, body) {
  ensureLabel(repository);
  const payload = JSON.stringify({ title, body, labels: [DEFAULT_LABEL] });
  try {
    const stdout = execFileSync(
      "gh",
      ["api", "-X", "POST", `repos/${repository}/issues`, "--input", "-"],
      { encoding: "utf8", env: process.env, input: payload, timeout: 60_000 },
    );
    const created = JSON.parse(stdout);
    if (Number.isFinite(created.number)) {
      return { number: created.number };
    }
  } catch {
    // Fall through to unlabeled retry below.
  }
  // Fallback: retry without label, mirroring the red-on-main-detector.
  try {
    const unlabeled = JSON.stringify({ title, body });
    const stdout = execFileSync(
      "gh",
      ["api", "-X", "POST", `repos/${repository}/issues`, "--input", "-"],
      { encoding: "utf8", env: process.env, input: unlabeled, timeout: 60_000 },
    );
    const created = JSON.parse(stdout);
    if (Number.isFinite(created.number)) {
      return { number: created.number };
    }
  } catch (error) {
    console.error(
      `issue_create_failed on ${repository}: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
  }
  return null;
}

/**
 * @param {string} repository
 * @param {number} issueNumber
 * @param {string} body
 */
function commentIssue(repository, issueNumber, body) {
  try {
    execFileSync(
      "gh",
      [
        "api",
        "-X",
        "POST",
        `repos/${repository}/issues/${issueNumber}/comments`,
        "-f",
        `body=${body}`,
      ],
      { encoding: "utf8", env: process.env, timeout: 60_000 },
    );
  } catch (error) {
    console.error(
      `comment_failed on ${repository}#${issueNumber}: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
  }
}

/**
 * @param {string} repository
 * @param {number} issueNumber
 */
function closeIssue(repository, issueNumber) {
  try {
    execFileSync(
      "gh",
      [
        "api",
        "-X",
        "PATCH",
        `repos/${repository}/issues/${issueNumber}`,
        "-f",
        "state=closed",
      ],
      { encoding: "utf8", env: process.env, timeout: 60_000 },
    );
  } catch (error) {
    console.error(
      `issue_close_failed on ${repository}#${issueNumber}: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
  }
}

/**
 * Build the Decision object that drives the actuator.
 *
 * @param {{
 *   verdict: ReturnType<typeof classifyHalt>,
 *   repository: string,
 *   existingIssueNumber: number | null,
 * }} ctx
 * @returns {Decision}
 */
export function buildDecision(ctx) {
  const { verdict, repository, existingIssueNumber } = ctx;
  if (!verdict.halt) {
    if (existingIssueNumber && verdict.unfreeze_candidate) {
      // Halt cleared: close + comment the transition.
      const ur = verdict.unfreeze_candidate;
      return {
        action: "close",
        repository,
        workflow: verdict.halted_workflow ?? "(unknown)",
        reason: "halt cleared",
        red_runs: [],
        unfreeze_run: {
          run_id: ur.id,
          run_url: ur.html_url,
          head_sha: ur.head_sha,
          created_at: ur.created_at,
        },
        open_issue_number: existingIssueNumber,
      };
    }
    return {
      action: "noop",
      repository,
      workflow: "",
      reason: "no consecutive-failure halt detected",
      red_runs: [],
      unfreeze_run: null,
      open_issue_number: null,
    };
  }
  const red_runs = (verdict.halted_runs || []).map((r) => ({
    run_id: r.id,
    run_url: r.html_url,
    head_sha: r.head_sha,
    created_at: r.created_at,
  }));
  return {
    action: existingIssueNumber ? "comment" : "open",
    repository,
    workflow: verdict.halted_workflow ?? "(unknown)",
    reason: "consecutive-commit HALT",
    red_runs,
    unfreeze_run: null,
    open_issue_number: existingIssueNumber,
  };
}

/**
 * @param {Decision} decision
 * @returns {Promise<Decision>}
 */
export async function applyDecision(decision) {
  if (decision.action === "noop") return decision;
  if (decision.action === "open") {
    const created = await createIssue(decision.repository, issueTitle(decision), issueBody(decision));
    if (created) {
      return { ...decision, open_issue_number: created.number };
    }
    return { ...decision, action: "noop", reason: "create failed (token)" };
  }
  if (decision.action === "comment" && decision.open_issue_number) {
    commentIssue(decision.repository, decision.open_issue_number, issueBody(decision));
    return decision;
  }
  if (decision.action === "close" && decision.open_issue_number) {
    commentIssue(decision.repository, decision.open_issue_number, issueBody(decision));
    closeIssue(decision.repository, decision.open_issue_number);
    return decision;
  }
  return decision;
}

// ---------- CLI -----------------------------------------------------------

function printUsage() {
  console.log(`Usage: stop-the-line-detector.mjs [options]

Detects the HALT verdict for a single repo: same workflow failed on
consecutive commits on main. When the verdict holds, opens (or reuses) a
single \`stop-the-line\` labeled issue that causes the auto-merge-arm
workflow to skip arming. Auto-clears on the next green run of the
halted workflow.

Options:
  --repo <owner/name>            Target repository (default: env STOP_THE_LINE_REPO)
  --lookback-minutes <n>         Minutes of recent main runs to sample (default: ${DEFAULT_LOOKBACK_MINUTES})
  --from-json <path>             Replay stored runs (no GitHub). Test fixtures use this.
  --format <human|json>          Output format (default: human)
  --output-json <path>           Write the JSON report to this path
  --no-issue                     Skip opening/closing/commenting on issues
  --help, -h                     Show this message
`);
}

function parseArgs(argv) {
  const args = {
    repo: process.env.STOP_THE_LINE_REPO ?? "",
    lookbackMinutes: Number(process.env.STOP_THE_LINE_LOOKBACK_MINUTES) || DEFAULT_LOOKBACK_MINUTES,
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
    console.error("Missing required --repo / STOP_THE_LINE_REPO or --from-json");
    printUsage();
    process.exit(2);
  }
  return args;
}

/**
 * @param {{ generated_at: string, repository: string, branch: string, lookback_minutes: number, runs_sampled: number, decision: Decision }} report
 * @returns {string}
 */
export function renderReport(report) {
  const lines = [];
  lines.push(`Stop-the-line detector — ${report.repository}`);
  lines.push(
    `Sampled ${report.runs_sampled} main run(s) over ${report.lookback_minutes}m at ${report.generated_at}`,
  );
  lines.push("");
  const d = report.decision;
  if (d.action === "noop") {
    lines.push(`Decision: noop (${d.reason})`);
  } else if (d.action === "open") {
    lines.push(`Decision: OPEN stop-the-line issue (${d.workflow} red on consecutive commits)`);
    if (d.red_runs.length > 0) {
      lines.push("  - red runs:");
      for (const r of d.red_runs) {
        const short = typeof r.head_sha === "string" ? r.head_sha.slice(0, 7) : "";
        lines.push(`      - \`${short}\` ${r.run_url}`);
      }
    }
  } else if (d.action === "close") {
    lines.push(`Decision: CLOSE stop-the-line issue (${d.workflow} green again)`);
    if (d.unfreeze_run) {
      const short = typeof d.unfreeze_run.head_sha === "string"
        ? d.unfreeze_run.head_sha.slice(0, 7)
        : "";
      lines.push(`  - green run: ${d.unfreeze_run.run_url} (\`${short}\`)`);
    }
  } else {
    lines.push(`Decision: ${d.action} (${d.reason})`);
  }
  return lines.join("\n");
}

/**
 * @param {{ decision: Decision }} report
 * @param {boolean} emit
 */
export function emitGithubAnnotations(report, emit) {
  if (!emit) return;
  const d = report.decision;
  if (d.action === "open") {
    console.error(
      `::error title=STOP-THE-LINE::${d.workflow} red on consecutive commits; auto-merge arming paused`,
    );
  } else if (d.action === "close") {
    console.error(
      `::notice title=STOP-THE-LINE-CLEAR::${d.workflow} green again; auto-merge arming resumed`,
    );
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const now = new Date();

  /** @type {Decision} */
  let decision;
  let repository = args.repo;
  let runsSampled = 0;

  if (args.fromJson) {
    const payload = JSON.parse(readFileSync(resolve(args.fromJson), "utf8"));
    if (payload && typeof payload === "object") {
      if (typeof payload.repository === "string" && payload.repository.length > 0) {
        repository = payload.repository;
      }
      const branch = typeof payload.branch === "string" ? payload.branch : DEFAULT_BRANCH;
      const runs = Array.isArray(payload.runs) ? payload.runs : [];
      runsSampled = runs.length;
      const verdict = classifyHalt(runs, { branch });
      const issueNumber =
        typeof payload.existing_issue_number === "number" ? payload.existing_issue_number : null;
      decision = buildDecision({
        verdict,
        repository,
        existingIssueNumber: issueNumber,
      });
    } else {
      throw new Error(`fixture must be an object: ${args.fromJson}`);
    }
  } else {
    const runs = fetchRecentMainRuns(repository, args.lookbackMinutes);
    runsSampled = runs.length;
    const verdict = classifyHalt(runs);
    const existing = findExistingIssue(repository);
    decision = buildDecision({
      verdict,
      repository,
      existingIssueNumber: existing,
    });
  }

  if (!args.fromJson && !args.noIssue) {
    decision = await applyDecision(decision);
  }

  const report = {
    generated_at: now.toISOString(),
    repository,
    branch: DEFAULT_BRANCH,
    lookback_minutes: args.lookbackMinutes,
    runs_sampled: runsSampled,
    decision,
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
    appendFileSync(
      process.env.GITHUB_OUTPUT,
      `action=${decision.action}\nworkflow=${decision.workflow}\n`,
    );
  }
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
