#!/usr/bin/node
// enqueue-green-prs.mjs — amendment 2 part (c): the weekly backstop sweep that
// arms the merge queue for any open, green, unqueued fleet PR. The primary
// path is event-driven (reusable-auto-enqueue.yml on pull_request/check_suite);
// this catches the case where the event path missed (transient API error,
// race with label add, fork-PR misclassification that turned out to be same-
// repo, etc.).
//
// Per-repo rule (matches reusable-auto-enqueue.yml):
//   - open, non-draft, non-fork PR
//   - no no-auto-merge label
//   - no [no-merge] in title
//   - all required checks green (or absent / not configured -> eligible)
//   - not already armed/queued (auto_merge_request_enabled)
//   - author in the fleet allowlist (default: nish3451, github-actions[bot],
//     app/dependabot, fleet-ops[bot] — covers worker-authored PRs)
//
// Queued repos use --auto --squash (which adds to the queue when merge_queue
// is configured, arms auto-merge otherwise). One path, both shapes.
//
// Hands-off + archived repos skipped entirely. The exception file
// `.fleet/standards-exceptions.yml` does NOT gate this sweep per-PR; the per-
// repo exception system covers settings drift, while this sweep follows the
// reusable-auto-enqueue.yml's own exclusion list (no-auto-merge, [no-merge],
// fork, draft) — these are the per-PR rules the standard enforces.
//
// Output (markdown summary) goes to stdout; --out-dir writes JSON. Drift
// report is appended to repo-standards-drift.json under `enqueueGreenPrs`.
//
// Failure modes (handled, not loud):
//   - PR with no required checks configured -> considered eligible (legacy
//     repos without a ruleset still get the arm; the cheap move is to queue).
//   - check run state "expected" (waiting on GitHub) -> NOT green, not queued.
//   - check run state "pending" -> NOT green.
//   - the arm itself fails (PR closed in flight, API rate-limit) -> logged as
//     skipped, surfaced in the report.

import { execFileSync } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";

import { isHandsOff } from "./repo-standards.lib.mjs";

const FLEET_AUTHORS_DEFAULT = "nish3451,github-actions[bot],app/dependabot,fleet-ops[bot]";

function gh(args, { json = false, allowFail = false } = {}) {
  try {
    const out = execFileSync("gh", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    if (!json) return out.trim();
    return out.trim() ? JSON.parse(out) : null;
  } catch (e) {
    if (allowFail) return null;
    throw e;
  }
}

function parseArgs(argv) {
  const opts = { orgs: [], format: "markdown", outDir: null, repo: null, dryRun: true };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dry-run") { opts.dryRun = true; }
    else if (a === "--apply") { opts.dryRun = false; }
    else if (a === "--org") { opts.orgs.push(argv[++i]); }
    else if (a === "--format") { opts.format = argv[++i]; }
    else if (a === "--out-dir") { opts.outDir = argv[++i]; }
    else if (a === "--repo") { opts.repo = argv[++i]; }
    else if (a === "--fleet-authors") { opts.fleetAuthors = argv[++i]; }
    else if (a === "-h" || a === "--help") {
      console.error("usage: enqueue-green-prs.mjs [--apply|--dry-run] [--repo OWNER/NAME] [--fleet-authors CSV] --org X --org Y --format json|markdown --out-dir DIR");
      process.exit(0);
    }
  }
  if (opts.orgs.length === 0) opts.orgs = ["Nishfleet", "nish3451"];
  if (!opts.fleetAuthors) opts.fleetAuthors = FLEET_AUTHORS_DEFAULT;
  return opts;
}

function listRepos(org) {
  const out = gh(["repo", "list", org, "--limit", "200", "--no-archived", "--json",
    "nameWithOwner,isFork",
    "-q", '.[] | select(.isFork|not) | {nameWithOwner}'],
    { allowFail: true });
  if (!out) return [];
  return out.split("\n").map((s) => s.trim()).filter(Boolean).map((line) => {
    try { return JSON.parse(line); } catch { return null; }
  }).filter(Boolean);
}

// Status check rollup for a PR: returns { green: bool, contexts: [{name, state}] }
// where "green" means every check has bucket=pass. A check that failed or is
// still pending means the PR is NOT green, so it stays unqueued — branch
// protection will hold the merge either way.
function prCheckRollup(repo, prNumber) {
  // gh pr checks returns: name, state (SUCCESS/FAILURE/PENDING/NEUTRAL/SKIPPED),
  // bucket (pass/fail/pending/skipping/canceling). bucket=pass is what blocks
  // merge from being green.
  const raw = gh(["pr", "checks", String(prNumber), "--repo", repo, "--json", "name,state,bucket,link"], { json: true, allowFail: true });
  if (!Array.isArray(raw)) return { green: false, contexts: [], error: "cannot read checks" };
  if (raw.length === 0) return { green: true, contexts: [], note: "no checks -> treated eligible (legacy repo or no required checks)" };
  const failing = raw.filter((c) => c.bucket === "fail");
  const pending = raw.filter((c) => c.bucket === "pending");
  return {
    green: failing.length === 0 && pending.length === 0,
    contexts: raw.map((c) => ({ name: c.name, bucket: c.bucket, state: c.state })),
  };
}

// Eligible PRs (open, non-draft, non-fork, no no-auto-merge, no [no-merge]) +
// check rollup for each.
function listOpenPrs(repo) {
  const raw = gh(["pr", "list", "--repo", repo, "--state", "open", "--json",
    "number,title,isDraft,headRefName,author,labels,autoMergeRequest,headRepositoryOwner"], { json: true, allowFail: true });
  if (!Array.isArray(raw)) return [];
  return raw;
}

function authorAllowed(author, fleetCsv) {
  const set = new Set(fleetCsv.split(",").map((s) => s.trim()).filter(Boolean));
  return set.has(author);
}

function isForkPr(repo, headRepoFullName) {
  return headRepoFullName !== repo;
}

function arm(repo, prNumber) {
  // --auto --squash works on both merge-queue and non-queue repos. On a queue
  // repo it adds the PR to the queue; on a non-queue repo it arms auto-merge.
  // Either way, branch protection is respected (merge waits for required
  // checks). We never bypass.
  return gh(["pr", "merge", String(prNumber), "--auto", "--squash", "--repo", repo], { allowFail: true });
}

function processRepo(repo, opts) {
  if (isHandsOff(repo)) {
    return { repo, status: "skipped", reason: "hands-off", armed: 0, alreadyQueued: 0, notGreen: 0, skipped: 0, enqueued: [] };
  }
  const settings = gh(["api", `repos/${repo}`], { json: true, allowFail: true });
  if (!settings || settings.archived) return { repo, status: "skipped", reason: "archived", armed: 0, alreadyQueued: 0, notGreen: 0, skipped: 0, enqueued: [] };
  const prs = listOpenPrs(repo);
  const out = { repo, status: "ok", armed: 0, alreadyQueued: 0, notGreen: 0, skipped: 0, enqueued: [], skippedList: [] };
  for (const pr of prs) {
    // Per-PR exclusions (match reusable-auto-enqueue.yml).
    if (pr.isDraft) { out.skipped += 1; out.skippedList.push({ pr: pr.number, reason: "draft" }); continue; }
    if (pr.title && pr.title.includes("[no-merge]")) { out.skipped += 1; out.skippedList.push({ pr: pr.number, reason: "[no-merge] title" }); continue; }
    const labelNames = (pr.labels || []).map((l) => l.name);
    if (labelNames.includes("no-auto-merge")) { out.skipped += 1; out.skippedList.push({ pr: pr.number, reason: "no-auto-merge label" }); continue; }
    if (!authorAllowed((pr.author && pr.author.login) || "", opts.fleetAuthors)) { out.skipped += 1; out.skippedList.push({ pr: pr.number, reason: "author not in fleet allowlist" }); continue; }
    // Fork check requires head repo, which the list call returns via
    // headRepositoryOwner... fetch PR details.
    const detail = gh(["pr", "view", String(pr.number), "--repo", repo, "--json", "headRepositoryOwner"], { json: true, allowFail: true });
    const headOwner = detail && detail.headRepositoryOwner && detail.headRepositoryOwner.login;
    if (headOwner && headOwner !== repo.split("/")[0]) { out.skipped += 1; out.skippedList.push({ pr: pr.number, reason: "fork PR" }); continue; }
    // Already armed/queued? (autoMergeRequest is null when not armed.)
    if (pr.autoMergeRequest) { out.alreadyQueued += 1; continue; }
    // Green?
    const rollup = prCheckRollup(repo, pr.number);
    if (!rollup.green) { out.notGreen += 1; out.skippedList.push({ pr: pr.number, reason: rollup.error || "checks not all green", contexts: rollup.contexts }); continue; }
    // Arm.
    if (opts.dryRun) {
      out.armed += 1;
      out.enqueued.push({ pr: pr.number, title: pr.title, dryRun: true });
    } else {
      const ok = arm(repo, pr.number);
      if (ok != null) {
        out.armed += 1;
        out.enqueued.push({ pr: pr.number, title: pr.title, dryRun: false });
      } else {
        out.skipped += 1;
        out.skippedList.push({ pr: pr.number, reason: "gh pr merge failed (transient)" });
      }
    }
  }
  return out;
}

function renderMarkdown(reports) {
  const lines = [];
  lines.push(`# Enqueue-green-PRs sweep (amendment 2 part c)`);
  lines.push(`Generated: ${new Date().toISOString()}`);
  lines.push(`Mode: ${reports.dryRun ? "dry-run" : "apply"}`);
  lines.push(`Fleet author allowlist: ${reports.fleetAuthors}`);
  lines.push(`Repos scanned: ${reports.repos.length}`);
  const totals = reports.repos.reduce((a, r) => ({
    armed: a.armed + (r.armed || 0),
    alreadyQueued: a.alreadyQueued + (r.alreadyQueued || 0),
    notGreen: a.notGreen + (r.notGreen || 0),
    skipped: a.skipped + (r.skipped || 0),
  }), { armed: 0, alreadyQueued: 0, notGreen: 0, skipped: 0 });
  lines.push(`Totals: armed=${totals.armed} already-queued=${totals.alreadyQueued} not-green=${totals.notGreen} skipped=${totals.skipped}`);
  lines.push("");
  for (const r of reports.repos) {
    if (r.status === "skipped") { lines.push(`### ${r.repo} — SKIPPED (${r.reason})`); continue; }
    if ((r.armed || 0) === 0 && (r.skipped || 0) === 0) { continue; } // quiet when nothing to do
    lines.push(`### ${r.repo}`);
    lines.push(`- armed: ${r.armed}`);
    lines.push(`- already queued: ${r.alreadyQueued}`);
    lines.push(`- not green (kept open): ${r.notGreen}`);
    lines.push(`- skipped (per-PR rule): ${r.skipped}`);
    for (const e of r.enqueued) lines.push(`  - ARMED #${e.pr}: ${e.title}${e.dryRun ? " (dry-run)" : ""}`);
    for (const s of r.skippedList.slice(0, 5)) lines.push(`  - SKIP #${s.pr}: ${s.reason}`);
    if (r.skippedList.length > 5) lines.push(`  - ... and ${r.skippedList.length - 5} more`);
    lines.push("");
  }
  return lines.join("\n");
}

function main() {
  const opts = parseArgs(process.argv);
  const repos = [];
  for (const org of opts.orgs) for (const r of listRepos(org)) repos.push(r);
  const results = [];
  for (const r of repos) {
    const repo = r.nameWithOwner;
    if (opts.repo && repo !== opts.repo) continue;
    try { results.push(processRepo(repo, opts)); }
    catch (e) { results.push({ repo, status: "error", reason: String(e.message || e), armed: 0, alreadyQueued: 0, notGreen: 0, skipped: 0, enqueued: [], skippedList: [] }); }
  }
  const report = { generatedAt: new Date().toISOString(), dryRun: opts.dryRun, fleetAuthors: opts.fleetAuthors, repos: results };
  if (opts.outDir) {
    mkdirSync(opts.outDir, { recursive: true });
    writeFileSync(path.join(opts.outDir, "enqueue-green-prs.json"), JSON.stringify(report, null, 2));
    writeFileSync(path.join(opts.outDir, "enqueue-green-prs.md"), renderMarkdown(report));
  }
  if (opts.format === "json") console.log(JSON.stringify(report, null, 2));
  else console.log(renderMarkdown(report));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}