#!/usr/bin/env node
// Org-wide gap-closure cycle (fleet-ops#185).
//
// One central run discovers every Nishfleet repo from the GitHub API,
// minus config/intake-repos.json excluded[]. A repo created tomorrow is
// in the next cycle with nobody touching enrolment.
//
// Stages: audit (file gap-audit issues in the TARGET repo) → sandboxed
// CI-level drills → DORA four keys → per-repo DONE/reopen.
//
// Org rulesets are the preferred inbuilt gate. Nishfleet is on the free
// plan, which 403s that API ("Upgrade to GitHub Team"). That probe is a
// loud SKIP, never a silent pass. Paid Team is Nish's call.
//
// Conference (three auditor seats + tally) stays on the VPS and reuses
// fleet-ops#180 unchanged. This script records conference: pending-180.
//
// Surface: gh CLI + GitHub REST API. No paid services. No per-repo copies
// of this loop. No systemd duplicate of this schedule.

import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_ORG = "Nishfleet";
const DEFAULT_WINDOW_DAYS = 7;
const DEFAULT_MAX_FINDINGS_PER_REPO = 5;
const GAP_AUDIT_LABEL = "gap-audit";
const STALE_BRANCH_DAYS = 14;
const OWNERLESS_PR_HOURS = 48;
const STUCK_RUN_HOURS = 2;
const CONTROL_PLANE = new Set(["fleet-ops", "siterep-public"]);

/**
 * @typedef {{ name: string, permanent?: boolean, reason?: string }} ExcludedEntry
 * @typedef {{
 *   name: string,
 *   full_name?: string,
 *   archived?: boolean,
 *   private?: boolean,
 *   default_branch?: string,
 *   created_at?: string,
 *   pushed_at?: string,
 *   workflows?: string[],
 *   has_auto_revert?: boolean,
 *   has_branch_protection?: boolean,
 *   main_runs?: Array<{
 *     id?: number,
 *     name?: string,
 *     conclusion?: string | null,
 *     status?: string,
 *     head_branch?: string | null,
 *     html_url?: string,
 *     created_at?: string,
 *     updated_at?: string,
 *   }>,
 *   open_prs?: Array<{
 *     number: number,
 *     title?: string,
 *     html_url?: string,
 *     draft?: boolean,
 *     updated_at?: string,
 *     assignees?: unknown[],
 *     labels?: Array<{ name?: string } | string>,
 *     user?: { type?: string, login?: string },
 *   }>,
 *   branches?: Array<{
 *     name: string,
 *     updated_at?: string,
 *     ahead?: number,
 *     open_pr?: boolean,
 *   }>,
 *   merged_prs?: Array<{
 *     number?: number,
 *     created_at?: string,
 *     merged_at?: string,
 *     auto_revert?: boolean,
 *   }>,
 *   deployments?: Array<{ created_at?: string, environment?: string, state?: string }>,
 *   open_gap_audit_titles?: string[],
 * }} RepoSnapshot
 * @typedef {{
 *   repo: string,
 *   kind: string,
 *   title: string,
 *   body: string,
 *   evidence: string,
 * }} Finding
 * @typedef {{
 *   branch: string,
 *   conclusion: string,
 *   subject: string,
 *   main_head: string,
 *   head_sha: string,
 * }} AutoRevertEvent
 */

/**
 * @param {string} command
 * @param {string[]} args
 * @param {{ timeoutMs?: number, input?: string, allowFail?: boolean }} [opts]
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
    const failure = /** @type {{ stdout?: unknown, stderr?: unknown, status?: number, message?: unknown }} */ (
      error
    );
    const stderr = String(failure.stderr ?? "");
    const stdout = String(failure.stdout ?? "");
    if (opts.allowFail) {
      return stdout;
    }
    const detail = [stderr, stdout, failure.message]
      .map((part) => (typeof part === "string" ? part.trim() : ""))
      .filter(Boolean)
      .join("\n");
    const err = new Error(detail || String(error));
    /** @type {Error & { status?: number, stdout?: string, stderr?: string }} */
    const wrapped = err;
    wrapped.status = failure.status;
    wrapped.stdout = stdout;
    wrapped.stderr = stderr;
    throw wrapped;
  }
}

/**
 * @param {unknown} intake
 * @returns {Set<string>}
 */
export function excludedNames(intake) {
  const list = intake && typeof intake === "object" ? /** @type {{ excluded?: ExcludedEntry[] }} */ (intake).excluded : [];
  const names = new Set();
  for (const entry of Array.isArray(list) ? list : []) {
    if (entry && typeof entry.name === "string" && entry.name.trim()) {
      names.add(entry.name.trim());
    }
  }
  return names;
}

/**
 * @param {string} repoName
 * @param {Iterable<string>} [handsOff]
 * @returns {boolean}
 */
export function isHandsOff(repoName, handsOff = []) {
  const set = handsOff instanceof Set ? handsOff : new Set(handsOff);
  return set.has(repoName);
}

/**
 * Discover cycle targets. Auto-discovery: every non-archived org repo that
 * is not in excluded[]. Intake `repos` / `deferred` do not gate this loop.
 *
 * @param {{
 *   orgRepos: RepoSnapshot[],
 *   excluded: Iterable<string>,
 *   handsOff?: Iterable<string>,
 * }} input
 * @returns {{ targets: RepoSnapshot[], skipped: Array<{ name: string, reason: string }> }}
 */
export function discoverTargets(input) {
  const excluded = input.excluded instanceof Set ? input.excluded : new Set(input.excluded);
  const skipped = [];
  const targets = [];
  for (const repo of input.orgRepos) {
    const name = repo.name;
    if (!name) continue;
    if (repo.archived) {
      skipped.push({ name, reason: "archived" });
      continue;
    }
    if (excluded.has(name)) {
      skipped.push({ name, reason: "excluded" });
      continue;
    }
    if (isHandsOff(name, input.handsOff)) {
      skipped.push({ name, reason: "hands-off" });
      continue;
    }
    targets.push(repo);
  }
  targets.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return { targets, skipped };
}

/**
 * @param {{ status?: number, message?: string } | unknown[] | null | undefined} probe
 * @returns {{ status: "available" | "team-required" | "error", detail: string }}
 */
export function classifyOrgRulesets(probe) {
  if (Array.isArray(probe)) {
    return { status: "available", detail: `${probe.length} org ruleset(s)` };
  }
  if (probe && typeof probe === "object") {
    const body = /** @type {{ status?: number, message?: string }} */ (probe);
    const message = String(body.message ?? "");
    if (body.status === 403 && /Upgrade to GitHub Team/i.test(message)) {
      return {
        status: "team-required",
        detail: "Org rulesets need GitHub Team. Nishfleet is on free. Paid upgrade is Nish's call. SKIP, not a pass.",
      };
    }
    if (body.status && body.status >= 400) {
      return { status: "error", detail: message || `HTTP ${body.status}` };
    }
  }
  return { status: "error", detail: "org ruleset probe returned nothing" };
}

/**
 * Sandboxed auto-revert detector. Live deploys are never the drill target.
 *
 * @param {AutoRevertEvent} event
 * @returns {"SKIP_NOT_RED" | "SKIP_NOT_MAIN" | "HALT_REVERT_LOOP" | "HALT_FRESHNESS" | "OPEN_REVERT"}
 */
export function decideAutoRevert(event) {
  if (event.conclusion !== "failure") return "SKIP_NOT_RED";
  if (event.branch !== "main") return "SKIP_NOT_MAIN";
  const subject = event.subject ?? "";
  if (/^revert:/i.test(subject) || subject.startsWith("Revert")) return "HALT_REVERT_LOOP";
  if (event.main_head !== event.head_sha) return "HALT_FRESHNESS";
  return "OPEN_REVERT";
}

/**
 * @param {Array<{ event: AutoRevertEvent, expect: string }>} cases
 * @returns {{ passed: number, failed: Array<{ expect: string, got: string, event: AutoRevertEvent }> }}
 */
export function runAutoRevertDrill(cases) {
  const failed = [];
  let passed = 0;
  for (const row of cases) {
    const got = decideAutoRevert(row.event);
    if (got === row.expect) passed += 1;
    else failed.push({ expect: row.expect, got, event: row.event });
  }
  return { passed, failed };
}

/**
 * Stale-branch three-check: no open PR, last activity ≥ 14 days, unique
 * commits vs default (ahead > 0). All three must hold or it is not lost work.
 *
 * @param {{ name: string, updated_at?: string, ahead?: number, open_pr?: boolean }} branch
 * @param {{ now?: Date, defaultBranch?: string }} [opts]
 * @returns {boolean}
 */
export function isStaleLostBranch(branch, opts = {}) {
  const now = opts.now ?? new Date();
  const defaultBranch = opts.defaultBranch ?? "main";
  if (!branch.name || branch.name === defaultBranch) return false;
  if (branch.open_pr) return false;
  const ahead = Number(branch.ahead ?? 0);
  if (!(ahead > 0)) return false;
  if (!branch.updated_at) return false;
  const ageMs = now.getTime() - Date.parse(branch.updated_at);
  if (!Number.isFinite(ageMs)) return false;
  return ageMs >= STALE_BRANCH_DAYS * 24 * 60 * 60 * 1000;
}

/**
 * @param {{ labels?: Array<{ name?: string } | string>, assignees?: unknown[], draft?: boolean, updated_at?: string }} pr
 * @param {{ now?: Date }} [opts]
 * @returns {boolean}
 */
export function isOwnerlessPr(pr, opts = {}) {
  if (pr.draft) return false;
  const assignees = Array.isArray(pr.assignees) ? pr.assignees : [];
  if (assignees.length > 0) return false;
  const labels = (pr.labels ?? []).map((label) =>
    typeof label === "string" ? label : String(label?.name ?? ""),
  );
  if (labels.includes("agent-in-progress") || labels.includes("agent-ready")) return false;
  if (!pr.updated_at) return false;
  const now = opts.now ?? new Date();
  const ageMs = now.getTime() - Date.parse(pr.updated_at);
  if (!Number.isFinite(ageMs)) return false;
  return ageMs >= OWNERLESS_PR_HOURS * 60 * 60 * 1000;
}

/**
 * @param {RepoSnapshot} repo
 * @param {{ now?: Date }} [opts]
 * @returns {Finding[]}
 */
export function auditRepo(repo, opts = {}) {
  const now = opts.now ?? new Date();
  const full = repo.full_name ?? `Nishfleet/${repo.name}`;
  /** @type {Finding[]} */
  const findings = [];
  const workflows = repo.workflows ?? [];
  const hasCi = workflows.some((name) => /ci/i.test(name) || name === "CI");
  const hasAutoRevert =
    repo.has_auto_revert === true || workflows.some((name) => /auto[- ]?revert/i.test(name));

  if (!hasCi) {
    findings.push({
      repo: full,
      kind: "ci-health",
      title: `gap-audit: ${repo.name} has no CI workflow`,
      body: "A newly discovered or drifted repo has no CI workflow. The org-wide cycle found it without enrolment.",
      evidence: `workflows=${JSON.stringify(workflows)}`,
    });
  }

  if (!hasAutoRevert) {
    findings.push({
      repo: full,
      kind: "deploy-gate",
      title: `gap-audit: ${repo.name} is missing auto-revert`,
      body: "Deploy-gate integrity: no Auto revert workflow. A red-on-main merge would not undo itself.",
      evidence: `workflows=${JSON.stringify(workflows)} has_auto_revert=${repo.has_auto_revert ?? false}`,
    });
  }

  if (repo.has_branch_protection === false) {
    findings.push({
      repo: full,
      kind: "deploy-gate",
      title: `gap-audit: ${repo.name} default branch is unprotected`,
      body: "No branch protection / repo ruleset on the default branch. Org rulesets cannot bind this free-plan org, so the central cycle flags the gap.",
      evidence: "has_branch_protection=false",
    });
  }

  const mainRuns = repo.main_runs ?? [];
  const latest = mainRuns.find(
    (run) => run.conclusion === "failure" || run.conclusion === "success",
  );
  if (latest && latest.conclusion === "failure") {
    findings.push({
      repo: full,
      kind: "ci-health",
      title: `gap-audit: ${repo.name} is red on main`,
      body: `Latest main run of ${latest.name ?? "a workflow"} failed.`,
      evidence: latest.html_url ?? `run ${latest.id ?? "?"}`,
    });
  }

  for (const run of mainRuns) {
    if (run.status !== "in_progress" && run.status !== "queued") continue;
    const stamp = run.updated_at ?? run.created_at;
    if (!stamp) continue;
    const ageMs = now.getTime() - Date.parse(stamp);
    if (ageMs >= STUCK_RUN_HOURS * 60 * 60 * 1000) {
      findings.push({
        repo: full,
        kind: "ci-health",
        title: `gap-audit: ${repo.name} has a stuck Actions run`,
        body: `${run.name ?? "workflow"} has been ${run.status} for more than ${STUCK_RUN_HOURS}h.`,
        evidence: run.html_url ?? `run ${run.id ?? "?"}`,
      });
    }
  }

  for (const pr of repo.open_prs ?? []) {
    if (!isOwnerlessPr(pr, { now })) continue;
    findings.push({
      repo: full,
      kind: "lost-work",
      title: `gap-audit: ${repo.name} has ownerless PR #${pr.number}`,
      body: `Open PR #${pr.number} has no assignee and no agent-ready/in-progress label.`,
      evidence: pr.html_url ?? `#${pr.number}`,
    });
  }

  for (const branch of repo.branches ?? []) {
    if (!isStaleLostBranch(branch, { now, defaultBranch: repo.default_branch ?? "main" })) {
      continue;
    }
    findings.push({
      repo: full,
      kind: "lost-work",
      title: `gap-audit: ${repo.name} stale branch ${branch.name} (three-check)`,
      body: `Branch ${branch.name} has no open PR, is ≥${STALE_BRANCH_DAYS} days idle, and is ahead of default. Unique commits would be lost.`,
      evidence: `ahead=${branch.ahead} updated_at=${branch.updated_at}`,
    });
  }

  return findings;
}

/**
 * @param {Finding[]} findings
 * @param {string[]} openTitles
 * @returns {Finding[]}
 */
export function dedupeFindings(findings, openTitles) {
  const titles = new Set((openTitles ?? []).map((title) => title.trim().toLowerCase()));
  return findings.filter((finding) => !titles.has(finding.title.trim().toLowerCase()));
}

/**
 * DORA four keys from merged PRs + deployments in the window.
 * Change-fail rate uses auto-revert merges as failed changes.
 *
 * @param {{
 *   merged_prs?: Array<{ created_at?: string, merged_at?: string, auto_revert?: boolean }>,
 *   deployments?: Array<{ created_at?: string, state?: string }>,
 *   windowDays?: number,
 *   now?: Date,
 * }} input
 */
export function computeDora(input) {
  const now = input.now ?? new Date();
  const windowDays = input.windowDays ?? DEFAULT_WINDOW_DAYS;
  const since = now.getTime() - windowDays * 24 * 60 * 60 * 1000;
  const merged = (input.merged_prs ?? []).filter((pr) => {
    const stamp = Date.parse(pr.merged_at ?? "");
    return Number.isFinite(stamp) && stamp >= since;
  });
  const deploys = (input.deployments ?? []).filter((dep) => {
    const stamp = Date.parse(dep.created_at ?? "");
    return Number.isFinite(stamp) && stamp >= since && (dep.state === "success" || !dep.state);
  });
  const failed = merged.filter((pr) => pr.auto_revert);
  const leadTimesHours = merged
    .map((pr) => {
      const created = Date.parse(pr.created_at ?? "");
      const mergedAt = Date.parse(pr.merged_at ?? "");
      if (!Number.isFinite(created) || !Number.isFinite(mergedAt) || mergedAt < created) {
        return null;
      }
      return (mergedAt - created) / (60 * 60 * 1000);
    })
    .filter((value) => value !== null);
  const restoreHours = failed
    .map((pr) => {
      const created = Date.parse(pr.created_at ?? "");
      const mergedAt = Date.parse(pr.merged_at ?? "");
      if (!Number.isFinite(created) || !Number.isFinite(mergedAt) || mergedAt < created) {
        return null;
      }
      return (mergedAt - created) / (60 * 60 * 1000);
    })
    .filter((value) => value !== null);

  const avg = (values) =>
    values.length === 0 ? null : values.reduce((sum, value) => sum + value, 0) / values.length;

  return {
    window_days: windowDays,
    deploy_frequency_per_day: deploys.length / windowDays,
    deploys: deploys.length,
    changes: merged.length,
    lead_time_hours: avg(leadTimesHours),
    change_fail_rate: merged.length === 0 ? null : failed.length / merged.length,
    time_to_restore_hours: avg(restoreHours),
  };
}

/**
 * @param {{ prev?: string, findingsFiled: number, drillsPassed: boolean }} input
 * @returns {"looping" | "candidate-done" | "done" | "reopened"}
 */
export function nextLoopState(input) {
  const prev = input.prev ?? "looping";
  const clean = input.findingsFiled === 0 && input.drillsPassed;
  if (prev === "done") {
    return clean ? "done" : "reopened";
  }
  if (clean) return "candidate-done";
  return "looping";
}

/**
 * @param {ReturnType<typeof computeDora>[]} perRepo
 * @param {string[]} productRepos
 * @param {string[]} controlRepos
 */
export function productVsControlRatio(doraByRepo) {
  let productChanges = 0;
  let controlChanges = 0;
  let productRepos = 0;
  let controlRepos = 0;
  for (const [name, dora] of Object.entries(doraByRepo)) {
    const changes = Number(dora?.changes ?? 0);
    if (CONTROL_PLANE.has(name)) {
      controlRepos += 1;
      controlChanges += changes;
    } else {
      productRepos += 1;
      productChanges += changes;
    }
  }
  return {
    product_repos: productRepos,
    control_plane_repos: controlRepos,
    product_changes: productChanges,
    control_plane_changes: controlChanges,
    product_vs_control_plane: controlChanges === 0 ? null : productChanges / controlChanges,
  };
}

/**
 * @param {{
 *   org: string,
 *   generated_at: string,
 *   org_rulesets: ReturnType<typeof classifyOrgRulesets>,
 *   discovered: string[],
 *   skipped: Array<{ name: string, reason: string }>,
 *   findings: Finding[],
 *   filed: Array<{ repo: string, title: string, url?: string }>,
 *   drills: { passed: number, failed: unknown[] },
 *   dora: Record<string, unknown>,
 *   loop: Record<string, string>,
 *   conference: string,
 * }} report
 */
export function renderReport(report) {
  const lines = [
    `Gap-closure cycle — ${report.org}`,
    `generated_at: ${report.generated_at}`,
    `org_rulesets: ${report.org_rulesets.status} (${report.org_rulesets.detail})`,
    `discovered: ${report.discovered.join(", ") || "(none)"}`,
    `skipped: ${report.skipped.map((row) => `${row.name}:${row.reason}`).join(", ") || "(none)"}`,
    `private_api_only: ${report.private_api_only?.join(", ") || "(none)"}`,
    `findings: ${report.findings.length}`,
    `filed: ${report.filed.length}`,
    `drills_passed: ${report.drills.passed} failed: ${report.drills.failed.length}`,
    `conference: ${report.conference}`,
    "",
  ];
  for (const finding of report.findings) {
    lines.push(`- [${finding.kind}] ${finding.title}`);
  }
  return lines.join("\n");
}

const DEFAULT_DRILL_CASES = [
  {
    event: {
      branch: "main",
      conclusion: "failure",
      subject: "feat: add widget",
      main_head: "abc",
      head_sha: "abc",
    },
    expect: "OPEN_REVERT",
  },
  {
    event: {
      branch: "drill/gap-closure-canary",
      conclusion: "failure",
      subject: "feat: add widget",
      main_head: "abc",
      head_sha: "def",
    },
    expect: "SKIP_NOT_MAIN",
  },
  {
    event: {
      branch: "main",
      conclusion: "failure",
      subject: "revert: auto-restore green main",
      main_head: "abc",
      head_sha: "abc",
    },
    expect: "HALT_REVERT_LOOP",
  },
  {
    event: {
      branch: "main",
      conclusion: "failure",
      subject: "feat: add widget",
      main_head: "fff",
      head_sha: "abc",
    },
    expect: "HALT_FRESHNESS",
  },
];

/**
 * @param {unknown} payload
 * @param {{ now?: Date, maxFindings?: number }} [opts]
 */
export function runCycleFromPayload(payload, opts = {}) {
  const now = opts.now ?? new Date();
  const maxFindings = opts.maxFindings ?? DEFAULT_MAX_FINDINGS_PER_REPO;
  const body = /** @type {{
    org?: string,
    org_rulesets?: unknown,
    intake?: unknown,
    hands_off?: string[],
    repos?: RepoSnapshot[],
    prev_loop?: Record<string, string>,
    drill_cases?: Array<{ event: AutoRevertEvent, expect: string }>,
    now?: string,
  }} */ (payload);

  const cycleNow = body.now ? new Date(body.now) : now;
  const excluded = excludedNames(body.intake);
  const discovery = discoverTargets({
    orgRepos: body.repos ?? [],
    excluded,
    handsOff: body.hands_off ?? [],
  });
  const orgRulesets = classifyOrgRulesets(body.org_rulesets);
  const drillCases = body.drill_cases ?? DEFAULT_DRILL_CASES;
  const drills = runAutoRevertDrill(drillCases);

  /** @type {Finding[]} */
  const findings = [];
  /** @type {Record<string, string>} */
  const loop = {};
  /** @type {Record<string, ReturnType<typeof computeDora>>} */
  const doraByRepo = {};
  for (const repo of discovery.targets) {
    const raw = auditRepo(repo, { now: cycleNow });
    const fresh = dedupeFindings(raw, repo.open_gap_audit_titles ?? []).slice(0, maxFindings);
    findings.push(...fresh);
    const dora = computeDora({
      merged_prs: repo.merged_prs,
      deployments: repo.deployments,
      now: cycleNow,
    });
    doraByRepo[repo.name] = dora;
    const prev = body.prev_loop?.[repo.name];
    loop[repo.name] = nextLoopState({
      prev,
      findingsFiled: fresh.length,
      drillsPassed: drills.failed.length === 0,
    });
  }

  const ratio = productVsControlRatio(doraByRepo);

  const report = {
    org: body.org ?? DEFAULT_ORG,
    generated_at: cycleNow.toISOString(),
    org_rulesets: orgRulesets,
    discovered: discovery.targets.map((repo) => repo.name),
    skipped: discovery.skipped,
    private_api_only: discovery.targets.filter((repo) => repo.private).map((repo) => repo.name),
    findings,
    filed: /** @type {Array<{ repo: string, title: string, url?: string }>} */ ([]),
    drills,
    dora: {
      by_repo: doraByRepo,
      ...ratio,
    },
    loop,
    conference: "pending-180",
  };
  return report;
}

function printUsage() {
  console.log(`Usage:
  node .github/scripts/gap-closure-cycle.mjs --from-json FILE [--format json|human] [--output-json FILE]
  node .github/scripts/gap-closure-cycle.mjs --org Nishfleet --intake config/intake-repos.json [--dry-run]

Org-wide gap-closure cycle. Discovers repos from the GitHub API minus excluded[].
--from-json never reaches GitHub. --dry-run computes findings and does not file issues.`);
}

/**
 * @param {string[]} argv
 */
export function parseArgs(argv) {
  const args = {
    org: process.env.GAP_CLOSURE_ORG ?? DEFAULT_ORG,
    intake: process.env.GAP_CLOSURE_INTAKE ?? "",
    fromJson: "",
    format: "human",
    outputJson: "",
    dryRun: false,
    maxFindings: DEFAULT_MAX_FINDINGS_PER_REPO,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else if (arg === "--org") {
      args.org = argv[++i] ?? args.org;
    } else if (arg === "--intake") {
      args.intake = argv[++i] ?? "";
    } else if (arg === "--from-json") {
      args.fromJson = argv[++i] ?? "";
    } else if (arg === "--format") {
      args.format = (argv[++i] ?? "human").toLowerCase();
    } else if (arg === "--output-json") {
      args.outputJson = argv[++i] ?? "";
    } else if (arg === "--dry-run") {
      args.dryRun = true;
    } else if (arg === "--max-findings") {
      args.maxFindings = Math.max(1, Number(argv[++i]) || DEFAULT_MAX_FINDINGS_PER_REPO);
    }
  }
  if (!args.fromJson && !args.intake && !args.org) {
    console.error("Missing --from-json or --org");
    printUsage();
    process.exit(2);
  }
  return args;
}

/**
 * @param {string} org
 * @returns {RepoSnapshot[]}
 */
function fetchOrgRepos(org) {
  const raw = execGh("gh", [
    "api",
    "--paginate",
    `orgs/${org}/repos?per_page=100&type=all`,
  ]);
  /** @type {Array<Record<string, unknown>>} */
  const list = JSON.parse(raw);
  return list.map((row) => ({
    name: String(row.name ?? ""),
    full_name: String(row.full_name ?? `${org}/${row.name}`),
    archived: Boolean(row.archived),
    private: Boolean(row.private),
    default_branch: String(row.default_branch ?? "main"),
    created_at: typeof row.created_at === "string" ? row.created_at : undefined,
    pushed_at: typeof row.pushed_at === "string" ? row.pushed_at : undefined,
  }));
}

/**
 * @param {string} org
 * @returns {{ status?: number, message?: string } | unknown[]}
 */
function probeOrgRulesetsLive(org) {
  try {
    const raw = execGh("gh", ["api", `orgs/${org}/rulesets`]);
    return JSON.parse(raw);
  } catch (error) {
    const wrapped = /** @type {{ status?: number, stderr?: string, stdout?: string, message?: string }} */ (
      error
    );
    const text = `${wrapped.stdout ?? ""}\n${wrapped.stderr ?? ""}\n${wrapped.message ?? ""}`;
    try {
      const parsed = JSON.parse((wrapped.stdout || "").trim() || "{}");
      if (parsed && typeof parsed === "object" && Object.keys(parsed).length > 0) {
        return {
          status: Number(parsed.status ?? wrapped.status ?? 403),
          message: String(parsed.message ?? text),
        };
      }
    } catch {
      // fall through
    }
    if (/Upgrade to GitHub Team/i.test(text)) {
      return { status: 403, message: "Upgrade to GitHub Team to enable this feature." };
    }
    return { status: wrapped.status ?? 403, message: text };
  }
}

/**
 * @param {string} fullName
 * @param {string} defaultBranch
 * @param {Date} now
 * @returns {Partial<RepoSnapshot>}
 */
function fetchRepoDetails(fullName, defaultBranch, now) {
  const workflowsRaw = execGh("gh", [
    "api",
    "--paginate",
    `repos/${fullName}/actions/workflows?per_page=100`,
  ]);
  const workflowsJson = JSON.parse(workflowsRaw);
  const workflows = (workflowsJson.workflows ?? [])
    .filter((row) => row.state === "active")
    .map((row) => String(row.name ?? ""));

  let hasBranchProtection = false;
  try {
    execGh("gh", ["api", `repos/${fullName}/branches/${defaultBranch}/protection`]);
    hasBranchProtection = true;
  } catch {
    hasBranchProtection = false;
  }

  const runsRaw = execGh("gh", [
    "api",
    `repos/${fullName}/actions/runs?branch=${encodeURIComponent(defaultBranch)}&per_page=20`,
  ]);
  const runsJson = JSON.parse(runsRaw);
  const mainRuns = (runsJson.workflow_runs ?? []).map((run) => ({
    id: run.id,
    name: run.name,
    conclusion: run.conclusion,
    status: run.status,
    head_branch: run.head_branch,
    html_url: run.html_url,
    created_at: run.created_at,
    updated_at: run.updated_at,
  }));

  const prsRaw = execGh("gh", [
    "pr",
    "list",
    "-R",
    fullName,
    "--state",
    "open",
    "--limit",
    "50",
    "--json",
    "number,title,url,isDraft,updatedAt,assignees,labels,author",
  ]);
  const openPrs = JSON.parse(prsRaw).map((pr) => ({
    number: pr.number,
    title: pr.title,
    html_url: pr.url,
    draft: Boolean(pr.isDraft),
    updated_at: pr.updatedAt,
    assignees: pr.assignees ?? [],
    labels: pr.labels ?? [],
    user: pr.author,
  }));

  const since = new Date(now.getTime() - DEFAULT_WINDOW_DAYS * 24 * 60 * 60 * 1000).toISOString();
  const mergedRaw = execGh("gh", [
    "pr",
    "list",
    "-R",
    fullName,
    "--state",
    "merged",
    "--limit",
    "50",
    "--search",
    `merged:>=${since.slice(0, 10)}`,
    "--json",
    "number,title,createdAt,mergedAt",
  ]);
  const mergedPrs = JSON.parse(mergedRaw).map((pr) => ({
    number: pr.number,
    created_at: pr.createdAt,
    merged_at: pr.mergedAt,
    auto_revert: /^revert:/i.test(String(pr.title ?? "")),
  }));

  let branches = [];
  try {
    const branchRaw = execGh("gh", [
      "api",
      "--paginate",
      `repos/${fullName}/branches?per_page=100`,
    ]);
    const branchList = JSON.parse(branchRaw);
    const openPrJson = execGh("gh", [
      "pr",
      "list",
      "-R",
      fullName,
      "--state",
      "open",
      "--limit",
      "50",
      "--json",
      "headRefName",
    ]);
    const openBranchNames = new Set(JSON.parse(openPrJson).map((pr) => pr.headRefName));
    // Live runs do not compute ahead-of-default (that needs a clone).
    // ahead=0 keeps the three-check from firing without evidence.
    branches = branchList.slice(0, 40).map((branch) => ({
      name: String(branch.name ?? ""),
      updated_at: undefined,
      ahead: 0,
      open_pr: openBranchNames.has(branch.name),
    }));
  } catch {
    branches = [];
  }

  let openTitles = [];
  try {
    const issuesRaw = execGh("gh", [
      "issue",
      "list",
      "-R",
      fullName,
      "--state",
      "open",
      "--label",
      GAP_AUDIT_LABEL,
      "--limit",
      "50",
      "--json",
      "title",
    ]);
    openTitles = JSON.parse(issuesRaw).map((issue) => String(issue.title ?? ""));
  } catch {
    openTitles = [];
  }

  return {
    workflows,
    has_auto_revert: workflows.some((name) => /auto[- ]?revert/i.test(name)),
    has_branch_protection: hasBranchProtection,
    main_runs: mainRuns,
    open_prs: openPrs,
    branches,
    merged_prs: mergedPrs,
    deployments: mergedPrs.map((pr) => ({
      created_at: pr.merged_at,
      state: "success",
    })),
    open_gap_audit_titles: openTitles,
  };
}

/**
 * @param {string} fullName
 * @param {Finding} finding
 * @returns {string}
 */
function fileFinding(fullName, finding) {
  execGh(
    "gh",
    [
      "label",
      "create",
      GAP_AUDIT_LABEL,
      "--repo",
      fullName,
      "--color",
      "BFD4F2",
      "--description",
      "Filed by the org-wide gap-closure cycle",
      "--force",
    ],
    { allowFail: true },
  );
  return execGh("gh", [
    "issue",
    "create",
    "-R",
    fullName,
    "--title",
    finding.title,
    "--body",
    `${finding.body}\n\nEvidence: ${finding.evidence}\n\nFiled by the central gap-closure cycle in Nishfleet/fleet-ops (fleet-ops#185). Label: ${GAP_AUDIT_LABEL}.`,
    "--label",
    GAP_AUDIT_LABEL,
  ]).trim();
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  /** @type {ReturnType<typeof runCycleFromPayload>} */
  let report;

  if (args.fromJson) {
    const payload = JSON.parse(readFileSync(resolve(args.fromJson), "utf8"));
    report = runCycleFromPayload(payload, { maxFindings: args.maxFindings });
  } else {
    const intakePath = args.intake
      ? resolve(args.intake)
      : resolve("config/intake-repos.json");
    if (!existsSync(intakePath)) {
      throw new Error(`intake file not found: ${intakePath}`);
    }
    const intake = JSON.parse(readFileSync(intakePath, "utf8"));
    const now = new Date();
    const orgRepos = fetchOrgRepos(args.org);
    const details = [];
    for (const repo of orgRepos) {
      if (repo.archived) {
        details.push(repo);
        continue;
      }
      try {
        const extra = fetchRepoDetails(repo.full_name ?? `${args.org}/${repo.name}`, repo.default_branch ?? "main", now);
        details.push({ ...repo, ...extra });
      } catch (error) {
        console.error(`WARN: skip details for ${repo.name}: ${error instanceof Error ? error.message : String(error)}`);
        details.push(repo);
      }
    }
    const orgRulesets = probeOrgRulesetsLive(args.org);
    report = runCycleFromPayload(
      {
        org: args.org,
        org_rulesets: orgRulesets,
        intake,
        repos: details,
        now: now.toISOString(),
      },
      { now, maxFindings: args.maxFindings },
    );

    if (!args.dryRun) {
      for (const finding of report.findings) {
        try {
          const url = fileFinding(finding.repo, finding);
          report.filed.push({ repo: finding.repo, title: finding.title, url });
        } catch (error) {
          console.error(
            `WARN: could not file ${finding.title} on ${finding.repo}: ${error instanceof Error ? error.message : String(error)}`,
          );
        }
      }
    }
  }

  const json = JSON.stringify(report, null, 2);
  const human = renderReport(report);
  console.log(args.format === "json" ? json : human);
  if (args.outputJson) writeFileSync(resolve(args.outputJson), json);
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n${human}\n`);
  }

  if (report.drills.failed.length > 0) {
    console.error("FAIL: sandboxed auto-revert drill did not pass");
    process.exit(1);
  }
  if (report.discovered.length === 0) {
    console.error("FAIL: discovered zero repos (auth dead or org empty)");
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
