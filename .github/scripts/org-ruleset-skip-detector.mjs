#!/usr/bin/env node
// Org repository-ruleset SKIP detector (fleet-ops central reusable set).
//
// Organization repository rulesets with repo-pattern `*` are the inbuilt
// GitHub gate that binds every current AND future repo at creation with zero
// opt-in — the preferred mechanism in the gap-closure decision (fleet-ops#185).
// Nishfleet is on the free org plan, so `GET /orgs/Nishfleet/rulesets` returns
// 403 "Upgrade to GitHub Team to enable this feature." That is a loud SKIP,
// never a silent pass: the central cycle discovers repos via the GitHub API
// instead, and paid Team is Nish's call (fleet-ops#219, blocked-on:
// nish-decision).
//
// This detector makes that constraint OBSERVED, not assumed. Each run it probes
// the org plan + rulesets endpoint, classifies the result, records a
// machine-readable SKIP, and the moment the constraint lifts (Nish pays for
// Team) it flags the change loudly and posts a `decision-resolved:` comment on
// #219 so the heartbeat blocked-reconciler detects it without a human.
//
// Org plan changes are external billing events with no fleet-visible webhook,
// so a periodic probe is the only detection. The existing daily
// ci-standards-audit workflow is the named schedule: it imports this module
// on every live run. This file is also runnable on its own.
//
// Surface: gh CLI + GitHub REST API only. No paid services.

import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_ORG = "Nishfleet";
const DEFAULT_DECISION_ISSUE_REPO = "Nishfleet/fleet-ops";
const DEFAULT_DECISION_ISSUE_NUMBER = 219;
const COMMENT_MARKER_PREFIX = "<!-- org-ruleset-skip-detector:";

// Free-plan orgs cannot create org rulesets. Any other plan name (team,
// enterprise, etc.) can. The plan name is the authoritative signal — it does
// not depend on the rulesets endpoint permission.
const FREE_PLAN = "free";

/**
 * GitHub App installation tokens cannot read org rulesets (403 "Resource
 * not accessible by integration"). A PAT or user `gh` auth can, and that is
 * the token the daily ci-standards-audit job uses (FLEET_SYNC_PAT). When the
 * App token is in GH_TOKEN (fleet workers), retry the org probes without it
 * so the SKIP is still observed on the VPS.
 *
 * @param {string} blob
 * @returns {boolean}
 */
export function isAppTokenOrgDenied(blob) {
  return /Resource not accessible by integration/i.test(String(blob ?? ""));
}

/**
 * @typedef {{
 *   status: "available" | "team-required" | "permission-denied" | "error",
 *   detail: string,
 *   plan: string | null,
 *   ruleset_count: number | null,
 * }} Classification
 */

/**
 * @typedef {{
 *   plan?: string | null,
 *   rulesets?: unknown[] | { status?: number, message?: string } | null,
 * }} Probe
 */

/**
 * Classify an org-ruleset probe into one of four states. Pure: no I/O, safe to
 * unit-test with fixtures.
 *
 * - `available`: the org is on a paid plan AND the rulesets endpoint returned
 *   an array. Org rulesets can bind every repo. This is the state-change that
 *   unblocks #219.
 * - `team-required`: the org is on the free plan, OR the rulesets endpoint
 *   returned the plan-limit 403 ("Upgrade to GitHub Team"). The steady SKIP.
 * - `permission-denied`: the rulesets endpoint returned a 403 that is a token
 *   permission failure ("Resource not accessible by integration"), not a plan
 *   limit. The probe cannot determine the state — a loud error, never a pass.
 * - `error`: any other failure (non-403 HTTP error, empty probe).
 *
 * The plan name wins: a `free` plan is `team-required` regardless of the
 * rulesets probe, because the plan is the ground truth for the feature gate.
 * A free plan can never classify as `available`, even if a fixture forges a
 * ruleset list. That is the silent-pass this detector exists to prevent.
 *
 * @param {Probe} probe
 * @returns {Classification}
 */
export function classifyOrgRulesets(probe) {
  const plan = typeof probe?.plan === "string" && probe.plan.length > 0 ? probe.plan : null;
  const rulesets = probe?.rulesets;

  if (plan && plan.toLowerCase() === FREE_PLAN) {
    return {
      status: "team-required",
      detail: `Org plan is ${FREE_PLAN}. Org rulesets need GitHub Team to bind every repo with pattern *. SKIP, not a pass. Paid upgrade is Nish's call (fleet-ops#219).`,
      plan,
      ruleset_count: null,
    };
  }

  if (plan && plan.toLowerCase() !== FREE_PLAN) {
    if (Array.isArray(rulesets)) {
      return {
        status: "available",
        detail: `Org plan is ${plan}; ${rulesets.length} org ruleset(s) present. Org rulesets can bind every repo — #219 is resolved externally.`,
        plan,
        ruleset_count: rulesets.length,
      };
    }
    // Paid plan but the rulesets probe did not return a list. Still available
    // in principle; record the plan and note the probe shape.
    return {
      status: "available",
      detail: `Org plan is ${plan}; org rulesets are available on this plan (rulesets probe did not return a list).`,
      plan,
      ruleset_count: null,
    };
  }

  // No plan read — classify from the rulesets probe alone.
  if (Array.isArray(rulesets)) {
    return {
      status: "available",
      detail: `${rulesets.length} org ruleset(s) present. Org rulesets can bind every repo — #219 is resolved externally.`,
      plan: null,
      ruleset_count: rulesets.length,
    };
  }

  if (rulesets && typeof rulesets === "object") {
    const body = /** @type {{ status?: number, message?: string }} */ (rulesets);
    const message = String(body.message ?? "");
    const status = Number(body.status);
    if (status === 403 && /Upgrade to GitHub Team/i.test(message)) {
      return {
        status: "team-required",
        detail: `Org rulesets need GitHub Team. Nishfleet is on free. Paid upgrade is Nish's call (fleet-ops#219). SKIP, not a pass.`,
        plan: null,
        ruleset_count: null,
      };
    }
    if (status === 403 && /Resource not accessible|insufficient/i.test(message)) {
      return {
        status: "permission-denied",
        detail: `Rulesets probe returned 403 "${message}" — the token cannot read org rulesets. Cannot determine the plan gate. Fix the token scope (needs org read); do not treat as a pass.`,
        plan: null,
        ruleset_count: null,
      };
    }
    if (status && status >= 400) {
      return {
        status: "error",
        detail: `Rulesets probe returned HTTP ${status}: ${message || "(no message)"}`,
        plan: null,
        ruleset_count: null,
      };
    }
  }

  return {
    status: "error",
    detail: "Org-ruleset probe returned nothing usable (no plan, no rulesets).",
    plan: null,
    ruleset_count: null,
  };
}

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
      env: opts.env ?? process.env,
      maxBuffer: 64 * 1024 * 1024,
      timeout: opts.timeoutMs ?? 90_000,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (error) {
    const failure = /** @type {{ message?: unknown, stderr?: unknown, stdout?: unknown }} */ (error);
    const detail = [failure.message, failure.stderr, failure.stdout]
      .map((part) => (part ? String(part) : ""))
      .filter((part) => part.trim().length > 0)
      .join(" | ");
    throw new Error(
      `org_ruleset_probe_exec_failed: ${command} ${args.join(" ")} :: ${detail.slice(0, 800)}`,
    );
  }
}

/**
 * Drop GH_TOKEN so `gh` falls back to its stored user/PAT creds. Used only
 * after the App installation token is denied org-level reads.
 *
 * @returns {NodeJS.ProcessEnv}
 */
function envWithoutAppToken() {
  const env = { ...process.env };
  delete env.GH_TOKEN;
  delete env.GH_ENTERPRISE_TOKEN;
  return env;
}

/**
 * @param {string} org
 * @returns {string | null}
 */
/**
 * @param {string} out
 * @returns {string | null}
 */
export function normalizePlanName(out) {
  const trimmed = String(out ?? "").trim();
  if (!trimmed || trimmed === "null") return null;
  return trimmed;
}

function fetchOrgPlan(org) {
  const args = [
    "api",
    "--header",
    "Accept: application/vnd.github+json",
    "--header",
    "X-GitHub-Api-Version: 2022-11-28",
    `/orgs/${org}`,
    "--jq",
    ".plan.name",
  ];
  let plan = null;
  try {
    plan = normalizePlanName(execGh("gh", args));
  } catch {
    plan = null;
  }
  if (plan) return plan;
  // App installation tokens omit org.plan. Retry with stored user/PAT creds.
  if (!process.env.GH_TOKEN) return null;
  try {
    return normalizePlanName(execGh("gh", args, { env: envWithoutAppToken() }));
  } catch {
    return null;
  }
}

/**
 * Probe the org rulesets endpoint. On success returns an array. On a 403 we
 * capture the GitHub error body so classifyOrgRulesets can tell plan-limit
 * from permission-denied.
 *
 * @param {string} org
 * @returns {unknown[] | { status: number, message: string } | null}
 */
/**
 * @param {unknown} error
 * @returns {{ status: number, message: string } | null}
 */
function rulesetErrorBody(error) {
  const blob = error instanceof Error ? error.message : String(error);
  const statusMatch = blob.match(/HTTP (\d{3})/);
  const status = statusMatch ? Number(statusMatch[1]) : 0;
  const messageMatch = blob.match(/\{"message":"([^"]*)"/);
  const message = messageMatch ? messageMatch[1] : "";
  if (status || message) {
    return { status: status || 403, message };
  }
  return null;
}

/**
 * @param {string} org
 * @param {{ env?: NodeJS.ProcessEnv, timeoutMs?: number }} [opts]
 * @returns {unknown[] | { status: number, message: string } | null}
 */
function fetchOrgRulesetsOnce(org, opts = {}) {
  try {
    const out = execGh(
      "gh",
      [
        "api",
        "--header",
        "Accept: application/vnd.github+json",
        "--header",
        "X-GitHub-Api-Version: 2022-11-28",
        `/orgs/${org}/rulesets`,
      ],
      { timeoutMs: opts.timeoutMs ?? 60_000, env: opts.env },
    );
    const trimmed = out.trim();
    if (!trimmed) return null;
    try {
      const parsed = JSON.parse(trimmed);
      if (Array.isArray(parsed)) return parsed;
      return parsed && typeof parsed === "object" ? parsed : null;
    } catch {
      return null;
    }
  } catch (error) {
    return rulesetErrorBody(error);
  }
}

function fetchOrgRulesets(org) {
  const first = fetchOrgRulesetsOnce(org);
  if (first && typeof first === "object" && !Array.isArray(first)) {
    const body = /** @type {{ status?: number, message?: string }} */ (first);
    if (isAppTokenOrgDenied(String(body.message ?? "")) && process.env.GH_TOKEN) {
      return fetchOrgRulesetsOnce(org, { env: envWithoutAppToken() });
    }
  }
  return first;
}

/**
 * Live GitHub probe. Used by this script's main() and by ci-standards-audit
 * on its daily live run. Tests never call this: they replay `--from-json`.
 *
 * @param {string} org
 * @returns {Probe}
 */
export function probeOrgRulesets(org) {
  return {
    plan: fetchOrgPlan(org),
    rulesets: fetchOrgRulesets(org),
  };
}

/**
 * @param {{ generated_at: string, org: string, classification: Classification }} report
 * @returns {string}
 */
export function renderReport(report) {
  const c = report.classification;
  const lines = [
    `Org-ruleset SKIP detector — ${report.org}`,
    `Generated at: ${report.generated_at}`,
    "",
    `status:         ${c.status}`,
    `plan:           ${c.plan ?? "(unread)"}`,
    `ruleset_count:  ${c.ruleset_count ?? "(n/a)"}`,
    "",
    c.detail,
    "",
  ];
  if (c.status === "team-required") {
    lines.push("This is the steady SKIP. The central cycle discovers repos via the GitHub API instead.");
  } else if (c.status === "available") {
    lines.push("STATE CHANGE: org rulesets are now available. #219's blocker is resolved externally — lift per-repo gates to org level.");
  } else {
    lines.push("Cannot determine the org-ruleset gate. This is a loud finding, not a pass.");
  }
  return lines.join("\n");
}

/**
 * @param {{ classification: Classification }} report
 * @param {boolean} emit
 */
export function emitGithubAnnotations(report, emit) {
  if (!emit) return;
  const c = report.classification;
  const msg = c.detail.replace(/\r?\n/gu, " ");
  if (c.status === "team-required") {
    console.error(`::notice title=ORG-RULESETS-SKIP::${msg}`);
  } else if (c.status === "available") {
    console.error(`::warning title=ORG-RULESETS-AVAILABLE::${msg}`);
  } else {
    console.error(`::error title=ORG-RULESETS-PROBE-FAILED::${msg}`);
  }
}

/**
 * The comment body to post on the decision issue (#219) when org rulesets
 * become available. Contains a `decision-resolved:` line so the heartbeat
 * blocked-reconciler detects it deterministically.
 *
 * @param {{ generated_at: string, org: string, classification: Classification }} report
 * @returns {string}
 */
export function decisionResolvedComment(report) {
  const c = report.classification;
  const marker = `${COMMENT_MARKER_PREFIX}available -->`;
  const planLabel = c.plan ?? "(unread)";
  const countLabel = c.ruleset_count ?? "(not enumerated)";
  return [
    marker,
    "",
    `Org-ruleset SKIP detector observed org rulesets are now available on \`${report.org}\` at ${report.generated_at}.`,
    "",
    `Plan: \`${planLabel}\`. Rulesets: ${countLabel}.`,
    "",
    "The free-plan constraint that blocked this issue is lifted. Org rulesets with repo-pattern `*` can now bind every current and future repo at creation — lift per-repo branch protection / required checks / required workflows to the org level (fleet-ops#185 mechanism #1).",
    "",
    "decision-resolved: org rulesets now available on a paid plan",
  ].join("\n");
}

/**
 * @param {string} repo
 * @param {number} issueNumber
 * @returns {boolean}
 */
function hasDecisionResolvedComment(repo, issueNumber) {
  const marker = COMMENT_MARKER_PREFIX;
  try {
    const stdout = execGh(
      "gh",
      [
        "issue",
        "view",
        String(issueNumber),
        "--repo",
        repo,
        "--comments",
        "--json",
        "comments",
        "--jq",
        ".comments[].body",
      ],
      { timeoutMs: 60_000 },
    );
    return stdout.includes(marker);
  } catch {
    // If we cannot read the issue, assume not posted and attempt the write —
    // a duplicate comment is harmless and self-dedupes on the marker.
    return false;
  }
}

/**
 * @param {string} repo
 * @param {number} issueNumber
 * @param {string} body
 */
function postDecisionResolved(repo, issueNumber, body) {
  try {
    execGh(
      "gh",
      ["issue", "comment", String(issueNumber), "--repo", repo, "--body", body],
      { timeoutMs: 60_000 },
    );
    console.error(`posted decision-resolved comment on ${repo}#${issueNumber}`);
  } catch (error) {
    // A failed comment is a loud finding but not a crash — the state change is
    // still recorded in the report and annotations.
    console.error(`could not post decision-resolved comment on ${repo}#${issueNumber}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

/**
 * Observe-to-close: when the classification is `available`, post a
 * `decision-resolved:` comment on the decision issue so blocked-reconcile
 * can lift #219 without a human. Idempotent on the HTML marker.
 *
 * @param {{ repo: string, issueNumber: number, report: { generated_at: string, org: string, classification: Classification } }} opts
 * @returns {{ posted: boolean, reason: string }}
 */
export function maybePostDecisionResolved(opts) {
  if (opts.report.classification.status !== "available") {
    return { posted: false, reason: "not-available" };
  }
  if (hasDecisionResolvedComment(opts.repo, opts.issueNumber)) {
    console.error(`decision-resolved comment already present on ${opts.repo}#${opts.issueNumber}; not re-posting`);
    return { posted: false, reason: "already-posted" };
  }
  postDecisionResolved(opts.repo, opts.issueNumber, decisionResolvedComment(opts.report));
  return { posted: true, reason: "posted" };
}

function printUsage() {
  console.error(`Usage: org-ruleset-skip-detector.mjs [options]

Probes whether org-wide repository rulesets are available on the org, records
the SKIP deterministically, and flags the moment the free-plan constraint lifts.

Options:
  --org <name>              Org to probe (default: Nishfleet / ORG_RULESET_ORG)
  --decision-repo <repo>    Issue repo for the decision tracker (default: Nishfleet/fleet-ops)
  --decision-issue <n>      Issue number to comment on when available (default: 219)
  --from-json <file>        Replay a fixture { org, plan, rulesets } offline
  --format <human|json>     Output format (default: human)
  --output-json <file>      Write the JSON report to a file
  --no-issue                Do not post a comment on the decision issue
  --help, -h                Show this message
`);
}

/**
 * @param {string[]} argv
 * @returns {{ org: string, decisionRepo: string, decisionIssue: number, fromJson: string, format: string, outputJson: string, noIssue: boolean }}
 */
function parseArgs(argv) {
  const args = {
    org: process.env.ORG_RULESET_ORG ?? DEFAULT_ORG,
    decisionRepo: process.env.ORG_RULESET_DECISION_REPO ?? DEFAULT_DECISION_ISSUE_REPO,
    decisionIssue: Number(process.env.ORG_RULESET_DECISION_ISSUE) || DEFAULT_DECISION_ISSUE_NUMBER,
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
    } else if (arg === "--org") {
      args.org = argv[++i] ?? args.org;
    } else if (arg === "--decision-repo") {
      args.decisionRepo = argv[++i] ?? args.decisionRepo;
    } else if (arg === "--decision-issue") {
      args.decisionIssue = Number(argv[++i]) || args.decisionIssue;
    } else if (arg === "--from-json") {
      args.fromJson = argv[++i] ?? "";
    } else if (arg === "--format") {
      args.format = (argv[++i] ?? "human").toLowerCase();
    } else if (arg === "--output-json") {
      args.outputJson = argv[++i] ?? "";
    } else if (arg === "--no-issue") {
      args.noIssue = true;
    }
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const now = new Date();

  /** @type {Probe} */
  let probe;
  let org = args.org;

  if (args.fromJson) {
    const payload = JSON.parse(readFileSync(resolve(args.fromJson), "utf8"));
    if (payload && typeof payload === "object") {
      if (typeof payload.org === "string" && payload.org.length > 0) org = payload.org;
      probe = {
        plan: typeof payload.plan === "string" ? payload.plan : null,
        rulesets: payload.rulesets ?? null,
      };
    } else {
      throw new Error(`fixture must be an object: ${args.fromJson}`);
    }
  } else {
    probe = probeOrgRulesets(org);
  }

  const classification = classifyOrgRulesets(probe);
  const report = {
    generated_at: now.toISOString(),
    org,
    classification,
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
      `status=${classification.status}\norg=${org}\n`,
    );
  }

  if (!args.fromJson && !args.noIssue) {
    maybePostDecisionResolved({
      repo: args.decisionRepo,
      issueNumber: args.decisionIssue,
      report,
    });
  }

  // Steady SKIP and the available state change are both exit 0 (green run).
  // permission-denied / error mean the probe itself is broken — a loud,
  // nonzero failure so the scheduled audit goes red and gets fixed.
  if (classification.status === "permission-denied" || classification.status === "error") {
    process.exit(1);
  }
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
