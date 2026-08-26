#!/usr/bin/env node
// CI standards conformance audit (fleet-ops central reusable set).
//
// Reads every non-archived repo from the GitHub API, resolves its real default
// branch, then audits every `.github/workflows/*.yml` file for the standing
// CI standard. Produces a gap matrix and, when asked, opens fix PRs for the
// one gap that is safe to fix mechanically: missing auto-revert.yml on repos
// that already have a green push-to-main CI workflow and required checks.
//
// Surface: gh CLI + GitHub REST API only. No paid services. YAML parsing is
// delegated to the PyYAML installation that the caller must provide.

import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_ACCOUNT = "Nishfleet";
const DEFAULT_FLEET_OPS_REPO = "Nishfleet/fleet-ops";
const AUTO_REVERT_FILENAME = ".github/workflows/auto-revert.yml";
const AUTO_REVERT_BRANCH = "ci-standards-audit/auto-revert";
const AUTO_REVERT_TARGET_WORKFLOW = "CI";

/**
 * @typedef {object} WorkflowCheck
 * @property {string} file
 * @property {string} name
 * @property {boolean} pr_triggered
 * @property {boolean} push_to_default
 * @property {boolean} timeout_minutes_ok
 * @property {string[]} timeout_minutes_missing_jobs
 * @property {boolean|null} concurrency_ok
 * @property {boolean|string} concurrency_cancel_in_progress
 * @property {boolean} dependency_caching_ok
 * @property {string[]} caching_actions
 * @property {boolean} trigger_level_path_filter_error
 * @property {string[]} trigger_level_path_filter_jobs
 * @property {string|null} note
 */

/**
 * @typedef {object} RepoReport
 * @property {string} repo
 * @property {string} default_branch
 * @property {boolean} is_private
 * @property {string} plan
 * @property {string[]} required_contexts
 * @property {WorkflowCheck[]} workflows
 * @property {{present: boolean, eligible: boolean, can_open_pr: boolean, reason: string|null, opened_pr: string|null}} auto_revert
 * @property {string[]} gap_summary
 */

/**
 * @param {string[]} args
 * @param {object} [opts]
 * @returns {string}
 */
function execGh(args, opts = {}) {
  try {
    return execFileSync("gh", args, {
      encoding: "utf8",
      env: { ...process.env, GH_TOKEN: process.env.FLEET_SYNC_PAT || process.env.GH_TOKEN || "" },
      maxBuffer: 64 * 1024 * 1024,
      timeout: opts.timeoutMs ?? 90_000,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (error) {
    const detail = [error.message, error.stderr, error.stdout]
      .map((part) => (part ? String(part) : ""))
      .filter((part) => part.trim().length > 0)
      .join(" | ");
    throw new Error(`ci_standards_audit_exec_failed: gh ${args.join(" ")} :: ${detail.slice(0, 800)}`);
  }
}

/**
 * @param {string[]} args
 * @param {string} [input]
 * @returns {string}
 */
function execProgram(args, input) {
  try {
    return execFileSync(args[0], args.slice(1), {
      encoding: "utf8",
      input,
      timeout: 30_000,
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch (error) {
    const detail = [error.message, error.stderr, error.stdout]
      .map((part) => (part ? String(part) : ""))
      .filter((part) => part.trim().length > 0)
      .join(" | ");
    throw new Error(`ci_standards_audit_exec_failed: ${args.join(" ")} :: ${detail.slice(0, 800)}`);
  }
}

/**
 * @param {string} source
 * @returns {unknown}
 */
export function parseYaml(source) {
  const python = "import yaml, json, sys; print(json.dumps(yaml.safe_load(sys.stdin), default=str))";
  const out = execProgram(["python3", "-c", python], source);
  return JSON.parse(out);
}

/**
 * @param {string} account
 * @returns {Array<{nameWithOwner: string, isArchived: boolean, isPrivate: boolean, defaultBranchRef: {name: string}}>}
 */
export function listActiveRepos(account) {
  const out = execGh([
    "repo", "list", account,
    "--no-archived",
    "--limit", "1000",
    "--json", "nameWithOwner,isArchived,isPrivate,defaultBranchRef",
  ]);
  return JSON.parse(out);
}

/**
 * @param {string} repo
 * @param {string} defaultBranch
 * @returns {string[]}
 */
export function listWorkflowFiles(repo, defaultBranch) {
  try {
    const out = execGh([
      "api", `repos/${repo}/contents/.github/workflows?ref=${defaultBranch}`,
      "--jq", '.[] | select(.type == "file") | .name',
    ]);
    return out.split(/\r?\n/).filter((line) => line.trim().length > 0);
  } catch {
    return [];
  }
}

/**
 * @param {string} repo
 * @param {string} defaultBranch
 * @param {string} filename
 * @returns {string}
 */
export function fetchWorkflowContent(repo, defaultBranch, filename) {
  const out = execGh([
    "api",
    `repos/${repo}/contents/.github/workflows/${encodeURIComponent(filename)}?ref=${defaultBranch}`,
    "--jq", ".content",
  ]);
  return Buffer.from(out.trim(), "base64").toString("utf8");
}

/**
 * @param {string} repo
 * @param {string} branch
 * @returns {string[]|null}
 */
export function fetchRequiredContexts(repo, branch) {
  try {
    const out = execGh([
      "api",
      `repos/${repo}/branches/${encodeURIComponent(branch)}/protection/required_status_checks`,
      "--jq", ".contexts",
    ]);
    return JSON.parse(out);
  } catch {
    return null;
  }
}

/**
 * @param {string} repo
 * @returns {string}
 */
export function fetchPlanName(repo) {
  try {
    return execGh(["api", `repos/${repo}`, "--jq", ".plan.name"]).trim() || "free";
  } catch {
    return "free";
  }
}

/**
 * @param {string} repo
 * @param {string} branch
 * @returns {string|null}
 */
export function fetchLatestCiPushConclusion(repo, branch) {
  try {
    const out = execGh([
      "run", "list", "-R", repo,
      "--branch", branch,
      "--event", "push",
      "--workflow", AUTO_REVERT_TARGET_WORKFLOW,
      "--limit", "1",
      "--json", "conclusion",
    ]);
    const runs = JSON.parse(out);
    return runs[0]?.conclusion ?? null;
  } catch {
    return null;
  }
}

/**
 * @param {unknown} on
 * @returns {boolean}
 */
function eventPayload(workflow) {
  // GitHub Actions uses the key `on:` which YAML 1.1 parses as the boolean true.
  // PyYAML serialises that to the JSON string "true", so we look for the event
  // payload under several possible keys and never trust a raw `workflow.on`.
  for (const key of ["on", "true", "True", "TRUE"]) {
    if (key in workflow) return workflow[key];
  }
  return undefined;
}

/**
 * @param {Record<string, unknown>} workflow
 * @returns {boolean}
 */
export function isPrTriggeredWorkflow(workflow) {
  const on = eventPayload(workflow);
  if (on === "pull_request" || on === "pull_request_target") return true;
  if (Array.isArray(on)) return on.some((e) => e === "pull_request" || e === "pull_request_target");
  if (on && typeof on === "object") {
    return "pull_request" in on || "pull_request_target" in on;
  }
  return false;
}

/**
 * @param {Record<string, unknown>} workflow
 * @param {string} defaultBranch
 * @returns {boolean}
 */
export function isPushToDefaultWorkflow(workflow, defaultBranch) {
  const on = eventPayload(workflow);
  if (on === "push") return true;
  if (Array.isArray(on)) return on.includes("push");
  if (on && typeof on === "object") {
    const push = /** @type {Record<string, unknown>} */ (on).push;
    if (push === null || push === undefined) return false;
    if (typeof push === "string") return true;
    if (Array.isArray(push)) return true;
    if (typeof push === "object" && push !== null) {
      const branches = /** @type {Record<string, unknown>} */ (push).branches;
      if (branches === undefined) return true;
      if (Array.isArray(branches)) return branches.includes(defaultBranch);
      if (typeof branches === "string") return branches === defaultBranch;
    }
  }
  return false;
}

/**
 * @param {unknown} on
 * @returns {boolean}
 */
export function isPrTriggered(on) {
  if (on === "pull_request" || on === "pull_request_target") return true;
  if (Array.isArray(on)) return on.some((e) => e === "pull_request" || e === "pull_request_target");
  if (on && typeof on === "object") {
    return "pull_request" in on || "pull_request_target" in on;
  }
  return false;
}

/**
 * @param {unknown} on
 * @param {string} defaultBranch
 * @returns {boolean}
 */
export function isPushToDefault(on, defaultBranch) {
  if (on === "push") return true;
  if (Array.isArray(on)) return on.includes("push");
  if (on && typeof on === "object") {
    const push = /** @type {Record<string, unknown>} */ (on).push;
    if (push === null || push === undefined) return false;
    if (typeof push === "string") return true;
    if (Array.isArray(push)) return true;
    if (typeof push === "object" && push !== null) {
      const branches = /** @type {Record<string, unknown>} */ (push).branches;
      if (branches === undefined) return true;
      if (Array.isArray(branches)) return branches.includes(defaultBranch);
      if (typeof branches === "string") return branches === defaultBranch;
    }
  }
  return false;
}

/**
 * Expand `${{ matrix.<dim> }}` in a job display name.
 *
 * GitHub allows a few whitespace spellings. split/join is used instead of
 * `new RegExp(...)` so the dimension name never becomes a regular expression
 * (semgrep javascript.lang.security.audit.detect-non-literal-regexp).
 *
 * @param {string} rawName
 * @param {string} dimName
 * @param {string} value
 * @returns {string}
 */
function expandMatrixToken(rawName, dimName, value) {
  const token = `matrix.${dimName}`;
  const variants = [
    `\${{ ${token} }}`,
    `\${{${token}}}`,
    `\${{ ${token}}}`,
    `\${{${token} }}`,
  ];
  let out = rawName;
  for (const variant of variants) {
    out = out.split(variant).join(value);
  }
  return out;
}

/**
 * @param {string} key
 * @param {unknown} job
 * @returns {string[]}
 */
export function jobDisplayNames(key, job) {
  const jobObj = /** @type {Record<string, unknown>} */ (job);
  const rawName = typeof jobObj.name === "string" ? jobObj.name : key;

  const matrix = /** @type {Record<string, unknown>|undefined} */ (
    typeof jobObj.strategy === "object" && jobObj.strategy !== null
      ? /** @type {Record<string, unknown>} */ (jobObj.strategy).matrix
      : undefined
  );

  if (!matrix || typeof matrix !== "object" || !rawName.includes("${{ matrix.")) {
    return [rawName, key];
  }

  // Expand ${{ matrix.<dim> }} for up to one or two dimensions. This covers the
  // common "test (20)" form produced by a node-version matrix.
  const dims = Object.entries(/** @type {Record<string, unknown>} */ (matrix)).filter(
    ([k]) => !["include", "exclude"].includes(k),
  );
  const firstDim = dims[0];
  if (!firstDim) return [rawName, key];

  const [dimName, values] = firstDim;
  if (!Array.isArray(values) || values.length === 0) {
    return [expandMatrixToken(rawName, dimName, "*"), key];
  }

  const secondDim = dims[1];
  if (secondDim) {
    const [dim2Name, values2] = secondDim;
    if (Array.isArray(values2) && values2.length > 0) {
      const out = [];
      for (const v of values) {
        for (const v2 of values2) {
          out.push(expandMatrixToken(expandMatrixToken(rawName, dimName, String(v)), dim2Name, String(v2)));
        }
      }
      return out;
    }
  }

  return values.map((v) => expandMatrixToken(rawName, dimName, String(v)));
}

/**
 * @param {string} file
 * @param {Record<string, unknown>} workflow
 * @param {string[]} requiredContexts
 * @param {string} defaultBranch
 * @returns {WorkflowCheck}
 */
export function checkWorkflow(file, workflow, requiredContexts, defaultBranch) {
  const name = typeof workflow.name === "string" ? workflow.name : file;
  const prTriggered = isPrTriggeredWorkflow(workflow);
  const pushToDefault = isPushToDefaultWorkflow(workflow, defaultBranch);

  const jobs = workflow.jobs && typeof workflow.jobs === "object" ? workflow.jobs : {};

  /** @type {string[]} */
  const timeoutMissingJobs = [];
  /** @type {string[]} */
  const allJobNames = [];

  for (const [key, job] of Object.entries(jobs)) {
    const jobObj = /** @type {Record<string, unknown>} */ (job);
    const names = jobDisplayNames(key, job);
    allJobNames.push(...names);
    if (typeof jobObj["timeout-minutes"] !== "number") {
      timeoutMissingJobs.push(names[0]);
    }
  }

  let concurrencyOk = null;
  let concurrencyCancel = false;
  if (prTriggered) {
    const concurrency = workflow.concurrency;
    if (concurrency !== undefined) {
      if (typeof concurrency === "object" && concurrency !== null) {
        const cancel = /** @type {Record<string, unknown>} */ (concurrency)["cancel-in-progress"];
        concurrencyCancel = String(cancel).toLowerCase() === "true" || cancel === true;
        concurrencyOk = concurrencyCancel;
      } else if (typeof concurrency === "string") {
        concurrencyOk = false;
        concurrencyCancel = false;
      }
    } else {
      concurrencyOk = false;
      concurrencyCancel = false;
    }
  }

  const cacheResult = detectCaching(workflow);

  const pathFilter = detectTriggerLevelPathFilter(workflow, requiredContexts, allJobNames);

  return {
    file,
    name,
    pr_triggered: prTriggered,
    push_to_default: pushToDefault,
    timeout_minutes_ok: timeoutMissingJobs.length === 0,
    timeout_minutes_missing_jobs: timeoutMissingJobs,
    concurrency_ok: concurrencyOk,
    concurrency_cancel_in_progress: concurrencyCancel,
    dependency_caching_ok: cacheResult.ok,
    caching_actions: cacheResult.actions,
    trigger_level_path_filter_error: pathFilter.error,
    trigger_level_path_filter_jobs: pathFilter.jobs,
    note: null,
  };
}

const DEPENDENCY_INSTALL_RE = /\b(npm\s+ci|npm\s+install|yarn\s+install|pnpm\s+install|pip\s+install|pip3\s+install|bundle\s+install|go\s+mod\s+download|cargo\s+build|mvn\s+install|gradle\s+build)\b/;

/**
 * @param {Record<string, unknown>} workflow
 * @returns {{ok: boolean, applicable: boolean, actions: string[]}}
 */
function detectCaching(workflow) {
  const jobs = workflow.jobs && typeof workflow.jobs === "object" ? workflow.jobs : {};
  const actions = [];
  let installs = 0;

  for (const [key, job] of Object.entries(jobs)) {
    const jobObj = /** @type {Record<string, unknown>} */ (job);
    const steps = jobObj.steps;
    if (!Array.isArray(steps)) continue;
    for (const step of steps) {
      const stepObj = /** @type {Record<string, unknown>} */ (step);
      const uses = typeof stepObj.uses === "string" ? stepObj.uses : "";
      const with_ = stepObj.with && typeof stepObj.with === "object" ? stepObj.with : {};

      const run = typeof stepObj.run === "string" ? stepObj.run : "";
      if (DEPENDENCY_INSTALL_RE.test(run)) installs += 1;

      if (uses.startsWith("actions/cache") || uses.startsWith("actions/cache/")) {
        actions.push(`${uses} (${key})`);
      } else if (
        (uses.startsWith("actions/setup-node") ||
          uses.startsWith("actions/setup-python") ||
          uses.startsWith("actions/setup-go") ||
          uses.startsWith("actions/setup-bun") ||
          uses.startsWith("actions/setup-java") ||
          uses.startsWith("oven-sh/setup-bun")) &&
        "cache" in with_
      ) {
        actions.push(`${uses} cache (${key})`);
      }
    }
  }

  const applicable = installs > 0;
  return { ok: !applicable || actions.length > 0, applicable, actions };
}

/**
 * @param {Record<string, unknown>} workflow
 * @param {string[]} requiredContexts
 * @param {string[]} allJobNames
 * @returns {{error: boolean, jobs: string[]}}
 */
function detectTriggerLevelPathFilter(workflow, requiredContexts, allJobNames) {
  const on = eventPayload(workflow);
  if (!on || typeof on !== "object" || !isPrTriggered(on)) return { error: false, jobs: [] };

  const onObj = /** @type {Record<string, unknown>} */ (on);
  const pr = onObj.pull_request;
  const prt = onObj.pull_request_target;

  for (const trigger of [pr, prt]) {
    if (trigger && typeof trigger === "object") {
      const obj = /** @type {Record<string, unknown>} */ (trigger);
      if (Array.isArray(obj.paths) || Array.isArray(obj["paths-ignore"])) {
        const matched = allJobNames.filter((n) => requiredContexts.includes(n));
        return { error: matched.length > 0, jobs: matched };
      }
    }
  }

  return { error: false, jobs: [] };
}

/**
 * @param {string} repo
 * @param {string} defaultBranch
 * @param {Record<string, {parsed: unknown, source: string}>} workflows
 * @param {string[]} requiredContexts
 * @param {string|null} latestCiConclusion
 * @param {boolean} isPrivate
 * @param {string} plan
 * @returns {RepoReport["auto_revert"]}
 */
export function evaluateAutoRevert(repo, defaultBranch, workflows, requiredContexts, latestCiConclusion, isPrivate, plan) {
  const present = "auto-revert.yml" in workflows;

  const reasons = [];

  if (isPrivate && plan === "free") {
    reasons.push("private free-plan repo cannot set required checks");
  }
  if (requiredContexts.length === 0) {
    reasons.push("no required status checks on default branch");
  }

  const ciWorkflow = findCiWorkflow(workflows, defaultBranch);
  if (!ciWorkflow) {
    reasons.push(`no push-to-main workflow named "${AUTO_REVERT_TARGET_WORKFLOW}"`);
  } else if (!latestCiConclusion) {
    reasons.push(`no recent "${AUTO_REVERT_TARGET_WORKFLOW}" push run on ${defaultBranch} to verify green`);
  } else if (latestCiConclusion !== "success") {
    reasons.push(`latest "${AUTO_REVERT_TARGET_WORKFLOW}" push run on ${defaultBranch} is ${latestCiConclusion}; make green first`);
  }

  const eligible = reasons.length === 0;
  const canOpenPr = eligible && !present;

  return {
    present,
    eligible,
    can_open_pr: canOpenPr,
    reason: reasons.length > 0 ? reasons.join("; ") : null,
    opened_pr: null,
  };
}

/**
 * @param {Record<string, {parsed: unknown, source: string}>} workflows
 * @returns {{name: string, parsed: Record<string, unknown>}|null}
 */
function findCiWorkflow(workflows, defaultBranch) {
  for (const [file, data] of Object.entries(workflows)) {
    const parsed = /** @type {Record<string, unknown>} */ (data.parsed);
    if (typeof parsed.name === "string" && parsed.name === AUTO_REVERT_TARGET_WORKFLOW) {
      if (isPushToDefaultWorkflow(parsed, defaultBranch)) {
        return { name: file, parsed };
      }
    }
  }
  return null;
}

/**
 * @param {RepoReport[]} reports
 * @returns {object}
 */
export function buildSummary(reports) {
  let totalGaps = 0;
  let autoRevertMissingEligible = 0;
  let autoRevertPrsOpened = 0;

  for (const r of reports) {
    for (const w of r.workflows) {
      if (!w.timeout_minutes_ok) totalGaps += 1;
      if (w.concurrency_ok === false) totalGaps += 1;
      if (!w.dependency_caching_ok) totalGaps += 1;
      if (w.trigger_level_path_filter_error) totalGaps += 1;
    }
    if (r.auto_revert.can_open_pr) autoRevertMissingEligible += 1;
    if (r.auto_revert.opened_pr) autoRevertPrsOpened += 1;
  }

  return {
    total_repos: reports.length,
    total_workflow_gaps: totalGaps,
    auto_revert_missing_eligible: autoRevertMissingEligible,
    auto_revert_prs_opened: autoRevertPrsOpened,
  };
}

/**
 * @param {RepoReport[]} reports
 * @returns {string}
 */
export function renderMarkdown(reports, summary) {
  const lines = [
    "# CI standards gap matrix",
    "",
    `Generated at: ${new Date().toISOString()}`,
    "",
    "## Summary",
    "",
    `- Repos audited: ${summary.total_repos}`,
    `- Workflow standard gaps: ${summary.total_workflow_gaps}`,
    `- Repos eligible for auto-revert but missing it: ${summary.auto_revert_missing_eligible}`,
    `- Auto-revert fix PRs opened this run: ${summary.auto_revert_prs_opened}`,
    "",
    "## Per-repo matrix",
    "",
    "| Repo | Workflow | Timeout | Concurrency | Caching | Path filter on required | Auto-revert |",
    "|---|---|---|---|---|---|---|",
  ];

  for (const r of reports) {
    const ar = r.auto_revert;
    const arText = ar.present
      ? "present"
      : ar.can_open_pr
        ? (ar.opened_pr ? `missing (PR opened: ${ar.opened_pr})` : "missing (eligible for PR)")
        : `missing (${ar.reason ?? "not eligible"})`;

    if (r.workflows.length === 0) {
      lines.push(`| ${r.repo} | (no workflows) | - | - | - | - | ${arText} |`);
      continue;
    }

    for (const w of r.workflows) {
      const timeout = w.timeout_minutes_ok ? "ok" : `missing: ${w.timeout_minutes_missing_jobs.join(", ")}`;
      const concurrency = w.concurrency_ok === null ? "n/a" : w.concurrency_ok ? "ok" : "missing/false";
      const caching = w.dependency_caching_ok ? "ok" : "missing";
      const path = w.trigger_level_path_filter_error
        ? `error: ${w.trigger_level_path_filter_jobs.join(", ")}`
        : w.pr_triggered
          ? "ok"
          : "n/a";
      const wfLink = `[${w.file}](https://github.com/${r.repo}/blob/${r.default_branch}/.github/workflows/${encodeURIComponent(w.file)})`;
      lines.push(`| ${r.repo} | ${wfLink} | ${timeout} | ${concurrency} | ${caching} | ${path} | ${arText} |`);
    }
  }

  lines.push("");
  lines.push("## Gaps that need a recorded reason or a fix PR");
  lines.push("");

  let found = false;
  for (const r of reports) {
    for (const w of r.workflows) {
      const bits = [];
      if (!w.timeout_minutes_ok) bits.push(`timeout on ${w.timeout_minutes_missing_jobs.join(", ")}`);
      if (w.concurrency_ok === false) bits.push("concurrency cancel-in-progress missing");
      if (!w.dependency_caching_ok) bits.push("dependency caching missing");
      if (w.trigger_level_path_filter_error) bits.push(`trigger-level path filter on required check ${w.trigger_level_path_filter_jobs.join(", ")}`);
      if (bits.length > 0) {
        lines.push(`- ${r.repo} / ${w.file}: ${bits.join("; ")}`);
        found = true;
      }
    }
    if (r.auto_revert.can_open_pr) {
      if (r.auto_revert.opened_pr) {
        lines.push(`- ${r.repo}: opened auto-revert fix PR ${r.auto_revert.opened_pr}`);
      } else {
        lines.push(`- ${r.repo}: missing auto-revert.yml (eligible, but PR not opened this run)`);
      }
      found = true;
    }
  }
  if (!found) lines.push("None.");

  return lines.join("\n");
}

/**
 * @param {string} repo
 * @param {string} defaultBranch
 * @param {string} canonicalContent
 * @returns {string|null} PR URL
 */
function openAutoRevertPr(repo, defaultBranch, canonicalContent) {
  // Idempotent: skip if the branch already exists.
  try {
    execGh(["api", `repos/${repo}/git/ref/heads/${AUTO_REVERT_BRANCH}`], { timeoutMs: 30_000 });
    console.error(`skip ${repo}: branch ${AUTO_REVERT_BRANCH} already exists`);
    return null;
  } catch {
    // expected: branch does not exist
  }

  const defaultRef = execGh([
    "api", `repos/${repo}/git/ref/heads/${encodeURIComponent(defaultBranch)}`,
    "--jq", ".object.sha",
  ]).trim();

  execGh([
    "api", "-X", "POST", `repos/${repo}/git/refs`,
    "-f", `ref=refs/heads/${AUTO_REVERT_BRANCH}`,
    "-f", `sha=${defaultRef}`,
  ]);

  let content = canonicalContent;
  if (defaultBranch !== "main") {
    content = content.replace(/branches:\s*\[\s*main\s*\]/, `branches: [${defaultBranch}]`);
  }

  const b64 = Buffer.from(content, "utf8").toString("base64");
  const message = "ci: add auto-revert.yml";

  execGh([
    "api", "-X", "PUT", `repos/${repo}/contents/${AUTO_REVERT_FILENAME}`,
    "-f", `message=${message}`,
    "-f", `content=${b64}`,
    "-f", `branch=${AUTO_REVERT_BRANCH}`,
  ]);

  const body = [
    "Add the canonical auto-revert workflow from Nishfleet/fleet-ops.",
    "",
    `It watches the \`${AUTO_REVERT_TARGET_WORKFLOW}\` workflow on pushes to \`${defaultBranch}\` and opens a revert PR if that CI goes red.`,
    "",
    "The repo's latest push-to-main `CI` run is green, so it is safe to enable.",
    "",
    "Opened by the CI-standards audit. Closes the auto-revert gap.",
  ].join("\n");

  const prOut = execGh([
    "api", "-X", "POST", `repos/${repo}/pulls`,
    "-f", "title=ci: add auto-revert.yml",
    "-f", `body=${body}`,
    "-f", `head=${AUTO_REVERT_BRANCH}`,
    "-f", `base=${defaultBranch}`,
  ]);

  const pr = JSON.parse(prOut);

  try {
    execGh(["pr", "merge", "--auto", "--squash", "--repo", repo, String(pr.number)]);
  } catch {
    // Arming auto-merge is best-effort. `gh pr merge --auto` is idempotent,
    // so this is safe even if the target repo's auto-merge-arm.yml already
    // armed the PR.
  }

  return pr.html_url;
}

/**
 * @param {string} fleetOpsRepo
 * @param {string} ref
 * @returns {string}
 */
function fetchCanonicalAutoRevert(fleetOpsRepo, ref) {
  const out = execGh([
    "api",
    `repos/${fleetOpsRepo}/contents/.github/workflows/auto-revert.yml?ref=${ref}`,
    "--jq", ".content",
  ]);
  return Buffer.from(out.trim(), "base64").toString("utf8");
}

/**
 * @param {string} account
 * @param {object} opts
 * @returns {RepoReport[]}
 */
export function auditAccount(account, opts = {}) {
  const repos = listActiveRepos(account);
  /** @type {RepoReport[]} */
  const reports = [];

  for (const repoInfo of repos) {
    const repo = repoInfo.nameWithOwner;
    const defaultBranch = repoInfo.defaultBranchRef?.name ?? "main";
    const isPrivate = repoInfo.isPrivate;

    if (repo === "Nishfleet/fleet2") {
      continue; // standing rule: never touch fleet2
    }

    const plan = fetchPlanName(repo);
    const requiredContexts = fetchRequiredContexts(repo, defaultBranch) ?? [];
    const workflowFiles = listWorkflowFiles(repo, defaultBranch);

    /** @type {Record<string, {parsed: unknown, source: string}>} */
    const workflows = {};
    for (const file of workflowFiles) {
      if (!file.endsWith(".yml") && !file.endsWith(".yaml")) continue;
      try {
        const source = fetchWorkflowContent(repo, defaultBranch, file);
        const parsed = parseYaml(source);
        workflows[file] = { parsed, source };
      } catch (error) {
        console.error(`parse_failed ${repo}/${file}: ${error instanceof Error ? error.message : String(error)}`);
      }
    }

    const latestCiConclusion = fetchLatestCiPushConclusion(repo, defaultBranch);

    /** @type {WorkflowCheck[]} */
    const workflowChecks = [];
    for (const [file, data] of Object.entries(workflows)) {
      const parsed = /** @type {Record<string, unknown>} */ (data.parsed);
      workflowChecks.push(checkWorkflow(file, parsed, requiredContexts, defaultBranch));
    }

    const autoRevert = evaluateAutoRevert(repo, defaultBranch, workflows, requiredContexts, latestCiConclusion, isPrivate, plan);

    const gapSummary = [];
    for (const w of workflowChecks) {
      if (!w.timeout_minutes_ok) gapSummary.push(`${w.file}: missing timeout-minutes on ${w.timeout_minutes_missing_jobs.join(", ")}`);
      if (w.concurrency_ok === false) gapSummary.push(`${w.file}: missing concurrency cancel-in-progress for PR trigger`);
      if (!w.dependency_caching_ok) gapSummary.push(`${w.file}: missing dependency caching`);
      if (w.trigger_level_path_filter_error) gapSummary.push(`${w.file}: trigger-level path filter on required check ${w.trigger_level_path_filter_jobs.join(", ")}`);
    }
    if (autoRevert.can_open_pr) gapSummary.push("missing auto-revert.yml");

    reports.push({
      repo,
      default_branch: defaultBranch,
      is_private: isPrivate,
      plan,
      required_contexts: requiredContexts,
      workflows: workflowChecks,
      auto_revert: autoRevert,
      gap_summary: gapSummary,
    });
  }

  if (opts.openPrs && opts.canonicalContent) {
    for (const r of reports) {
      if (r.auto_revert.can_open_pr && !r.auto_revert.present) {
        try {
          const url = openAutoRevertPr(r.repo, r.default_branch, opts.canonicalContent);
          if (url) {
            r.auto_revert.opened_pr = url;
            r.gap_summary = r.gap_summary.filter((s) => s !== "missing auto-revert.yml");
          }
        } catch (error) {
          console.error(`open_pr_failed ${r.repo}: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
    }
  }

  return reports;
}

/**
 * @param {unknown} fixture
 * @param {object} [opts]
 * @returns {RepoReport[]}
 */
export function auditFromFixture(fixture, opts = {}) {
  const fixtureObj = /** @type {Record<string, unknown>} */ (fixture);
  /** @type {RepoReport[]} */
  const reports = [];

  const repos = Array.isArray(fixtureObj.repos) ? fixtureObj.repos : [];
  for (const raw of repos) {
    const repoInfo = /** @type {Record<string, unknown>} */ (raw);
    const repo = String(repoInfo.nameWithOwner);
    const defaultBranch = /** @type {string} */ (repoInfo.default_branch ?? "main");
    const isPrivate = Boolean(repoInfo.is_private);
    const plan = String(repoInfo.plan ?? "free");
    const requiredContexts = Array.isArray(repoInfo.required_contexts) ? repoInfo.required_contexts.map(String) : [];
    const latestCiConclusion = repoInfo.latest_ci_conclusion ? String(repoInfo.latest_ci_conclusion) : null;

    /** @type {Record<string, {parsed: unknown, source: string}>} */
    const workflows = {};
    const wfObj = repoInfo.workflows && typeof repoInfo.workflows === "object" ? repoInfo.workflows : {};
    for (const [file, data] of Object.entries(/** @type {Record<string, unknown>} */ (wfObj))) {
      const src = typeof data === "string" ? data : String(/** @type {Record<string, unknown>} */ (data).content ?? "");
      try {
        workflows[file] = { parsed: parseYaml(src), source: src };
      } catch {
        workflows[file] = { parsed: {}, source: src };
      }
    }

    const workflowChecks = [];
    for (const [file, data] of Object.entries(workflows)) {
      workflowChecks.push(checkWorkflow(file, /** @type {Record<string, unknown>} */ (data.parsed), requiredContexts, defaultBranch));
    }

    const autoRevert = evaluateAutoRevert(repo, defaultBranch, workflows, requiredContexts, latestCiConclusion, isPrivate, plan);

    const gapSummary = [];
    for (const w of workflowChecks) {
      if (!w.timeout_minutes_ok) gapSummary.push(`${w.file}: missing timeout-minutes on ${w.timeout_minutes_missing_jobs.join(", ")}`);
      if (w.concurrency_ok === false) gapSummary.push(`${w.file}: missing concurrency cancel-in-progress for PR trigger`);
      if (!w.dependency_caching_ok) gapSummary.push(`${w.file}: missing dependency caching`);
      if (w.trigger_level_path_filter_error) gapSummary.push(`${w.file}: trigger-level path filter on required check ${w.trigger_level_path_filter_jobs.join(", ")}`);
    }
    if (autoRevert.can_open_pr) gapSummary.push("missing auto-revert.yml");

    if (opts.openPrs && opts.canonicalContent && autoRevert.can_open_pr && !autoRevert.present) {
      // Fixture mode does not reach GitHub; record that a PR would be opened.
      autoRevert.opened_pr = "https://example.test/fixture-pr";
      gapSummary.splice(gapSummary.indexOf("missing auto-revert.yml"), 1);
    }

    reports.push({
      repo,
      default_branch: defaultBranch,
      is_private: isPrivate,
      plan,
      required_contexts: requiredContexts,
      workflows: workflowChecks,
      auto_revert: autoRevert,
      gap_summary: gapSummary,
    });
  }

  return reports;
}

function printUsage() {
  console.log(`Usage: node ci-standards-audit.mjs [options]

Options:
  --account <name>         GitHub account/owner to audit (default: ${DEFAULT_ACCOUNT})
  --from-json <path>       Replay from a fixture JSON instead of GitHub
  --open-prs               Open fix PRs for missing auto-revert.yml where eligible
  --canonical-ref <ref>    Fleet-ops ref to take the canonical auto-revert.yml from
  --fleet-ops-repo <repo>  Source of the canonical auto-revert.yml (default: ${DEFAULT_FLEET_OPS_REPO})
  --output-json <path>     Write the gap matrix as JSON
  --output-markdown <path> Write the gap matrix as Markdown
  --format <json|human>    Print format to stdout (default: human)
  --help                   Show this message
`);
}

function parseArgs(argv) {
  /** @type {Record<string, string | boolean>} */
  const args = {
    account: DEFAULT_ACCOUNT,
    fromJson: "",
    openPrs: false,
    canonicalRef: "main",
    fleetOpsRepo: DEFAULT_FLEET_OPS_REPO,
    outputJson: "",
    outputMarkdown: "",
    format: "human",
    help: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--account":
        args.account = argv[++i] ?? args.account;
        break;
      case "--from-json":
        args.fromJson = argv[++i] ?? "";
        break;
      case "--open-prs":
        args.openPrs = true;
        break;
      case "--canonical-ref":
        args.canonicalRef = argv[++i] ?? "main";
        break;
      case "--fleet-ops-repo":
        args.fleetOpsRepo = argv[++i] ?? DEFAULT_FLEET_OPS_REPO;
        break;
      case "--output-json":
        args.outputJson = argv[++i] ?? "";
        break;
      case "--output-markdown":
        args.outputMarkdown = argv[++i] ?? "";
        break;
      case "--format":
        args.format = argv[++i] ?? "human";
        break;
      case "--help":
        args.help = true;
        break;
      default:
        if (arg.startsWith("-")) throw new Error(`unknown argument: ${arg}`);
    }
  }

  if (args.fromJson && args.openPrs) {
    console.error("warning: --open-prs is ignored when using --from-json");
    args.openPrs = false;
  }

  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) {
    printUsage();
    return;
  }

  // Ensure PyYAML is available before spending API calls.
  try {
    parseYaml("key: value");
  } catch (error) {
    console.error("PyYAML is required. Install it with: python3 -m pip install pyyaml");
    throw error;
  }

  /** @type {RepoReport[]} */
  let reports;

  if (args.fromJson) {
    const payload = JSON.parse(readFileSync(resolve(args.fromJson), "utf8"));
    reports = auditFromFixture(payload, { openPrs: args.openPrs });
  } else {
    let canonicalContent = "";
    if (args.openPrs) {
      canonicalContent = fetchCanonicalAutoRevert(String(args.fleetOpsRepo), String(args.canonicalRef));
    }
    reports = auditAccount(String(args.account), { openPrs: args.openPrs, canonicalContent });
  }

  const summary = buildSummary(reports);
  const fullReport = {
    generated_at: new Date().toISOString(),
    account: args.fromJson ? (/** @type {any} */ (JSON.parse(readFileSync(resolve(args.fromJson), "utf8"))).account ?? DEFAULT_ACCOUNT) : args.account,
    summary,
    repos: reports,
  };

  const json = JSON.stringify(fullReport, null, 2);
  const markdown = renderMarkdown(reports, summary);

  if (args.outputJson) writeFileSync(resolve(args.outputJson), json);
  if (args.outputMarkdown) writeFileSync(resolve(args.outputMarkdown), markdown);

  const human = markdown;
  console.log(args.format === "json" ? json : human);

  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n${markdown}\n`);
  }

  if (process.env.GITHUB_OUTPUT) {
    const lines = [
      `total-repos=${summary.total_repos}`,
      `total-workflow-gaps=${summary.total_workflow_gaps}`,
      `auto-revert-missing-eligible=${summary.auto_revert_missing_eligible}`,
      `auto-revert-prs-opened=${summary.auto_revert_prs_opened}`,
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
