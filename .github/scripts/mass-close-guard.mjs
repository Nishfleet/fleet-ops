#!/usr/bin/env node
// Mass-close guard (fleet-ops central reusable set).
//
// Blind spot (2026-08-25, real incident): an agent bulk-closed 20 open
// control-plane issues as NOT_PLANNED in 2 minutes, citing superseded
// config — including the coordination issue. Zero detection; a human
// happened to look. The reconciler converges UNIT state, not ISSUE state,
// so this class stays open.
//
// This is the deterministic, per-issue guard. On every `issues: closed`
// event it asks one question, no LLM, no rate window:
//
//   Was this issue closed as `not_planned` while labeled
//   `agent-ready`/`agent-in-progress`, with no linked merged PR?
//
// If yes -> comment, reopen, apply `triage-mass-close`. If a merged PR
// references the issue, the close was legitimate and the issue stays
// closed. The ">3 in 10 min" mass-close signature is the motivation, not
// a gate: a single not-planned close of an agent-labeled issue with no
// merged PR is already wrong (only Nish retires agent work as not-planned,
// and he does it with a reason, not in bulk), so the guard fires per
// issue. Keeping it per-issue also means it is trivially testable: close
// one dummy agent-ready issue as not-planned and watch it reopen.
//
// Surface: gh CLI + GitHub REST API only. No paid services.

import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const GUARD_LABEL = "triage-mass-close";
const PROTECTED_LABELS = new Set(["agent-ready", "agent-in-progress"]);
const NOT_PLANNED = "not_planned";
const COMMENT_MARKER = "<!-- mass-close-guard -->";

/**
 * The labels that protect an issue from a not-planned close.
 * Exported so the workflow's YAML `if` and the tests can stay in sync.
 */
export const PROTECTED_LABEL_NAMES = [...PROTECTED_LABELS];

/**
 * Pure decision: should this close be reverted by the guard?
 *
 * @param {string|null|undefined} stateReason  The issue's state_reason
 *   (`not_planned`, `completed`, `duplicate`, `outdated`, `reopened`, ...).
 * @param {string[]}              labels       Label names on the issue.
 * @param {Array<string|null|undefined>} linkedPrStates  States of PRs that
 *   cross-reference this issue (`MERGED`, `OPEN`, `CLOSED`, null/unknown).
 * @returns {boolean}
 */
export function shouldReopen(stateReason, labels, linkedPrStates) {
  if (stateReason !== NOT_PLANNED) return false;
  if (!Array.isArray(labels) || !labels.some((l) => PROTECTED_LABELS.has(l))) {
    return false;
  }
  if (Array.isArray(linkedPrStates) && linkedPrStates.some((s) => s === "MERGED")) {
    return false;
  }
  return true;
}

/**
 * Run `gh api` and return parsed JSON, throwing on failure.
 * @param {string[]} args
 * @returns {any}
 */
export function ghJson(args) {
  const ghHost = process.env.GH_HOST || "";
  const ghArgs = ghHost ? ["api", "--hostname", ghHost, ...args] : ["api", ...args];
  const out = execFileSync("gh", ghArgs, {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  return JSON.parse(out);
}

/** Paginated timeline fetch via gh api --paginate. */
function fetchTimeline(repo, issue) {
  const raw = execFileSync(
    "gh",
    ["api", "--paginate", `repos/${repo}/issues/${issue}/timeline`],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  );
  // --paginate concatenates JSON arrays per page: `][` becomes the seam.
  // Re-stitch into one array.
  const stitched = raw.replace(/\]\s*\[/g, ",");
  return JSON.parse(stitched);
}

/** Collect PR numbers that cross-reference this issue from the timeline. */
export function linkedPrNumbersFromTimeline(timeline) {
  if (!Array.isArray(timeline)) return [];
  const nums = new Set();
  for (const ev of timeline) {
    if (!ev || ev.event !== "cross-referenced") continue;
    const src = ev.source && ev.source.issue;
    if (src && src.pull_request && typeof src.number === "number") {
      nums.add(src.number);
    }
  }
  return [...nums].sort((a, b) => a - b);
}

function prState(repo, pr) {
  try {
    const data = ghJson([`repos/${repo}/pulls/${pr}`, "--jq", "{state: .state, merged: .merged}"]);
    // .state is "open" | "closed"; .merged is boolean. Normalize to MERGED/CLOSED/OPEN.
    if (data && data.merged === true) return "MERGED";
    if (data && data.state === "closed") return "CLOSED";
    if (data && data.state === "open") return "OPEN";
    return null;
  } catch {
    return null;
  }
}

function ensureLabel(repo) {
  execFileSync(
    "gh",
    [
      "label",
      "create",
      GUARD_LABEL,
      "--repo",
      repo,
      "--color",
      "B60205",
      "--description",
      "Auto-reopened: closed as not-planned while agent-labeled with no merged linked PR",
      "--force",
    ],
    { encoding: "utf8", stdio: ["ignore", "ignore", "ignore"] },
  );
}

function commentBody(issue) {
  return [
    COMMENT_MARKER,
    "",
    "Reopened by the **mass-close guard**.",
    "",
    "This issue was closed as `not_planned` while labeled `agent-ready` /",
    "`agent-in-progress`, and no merged pull request references it. Only Nish",
    "retires agent work as not-planned, and a single actor closing many",
    "agent-labeled issues as not-planned in a short window is the mass-close",
    "signature (see fleet-ops#77).",
    "",
    "If this close was intentional, either link a merged PR that closes it, or",
    "remove the `agent-ready` / `agent-in-progress` label before re-closing.",
  ].join("\n");
}

/**
 * @param {{repo: string, issue: number, dryRun?: boolean, actor?: string}} opts
 * @returns {{reopened: boolean, reason: string, linkedPrs: number[], linkedPrStates: string[]}}
 */
export function guard(opts) {
  const { repo, issue, dryRun = false } = opts;
  const data = ghJson([`repos/${repo}/issues/${issue}`, "--jq", "{state_reason: .state_reason, labels: [.labels[].name]}"]);
  const stateReason = (data && data.state_reason) || null;
  const labels = Array.isArray(data && data.labels) ? data.labels : [];

  const timeline = fetchTimeline(repo, issue);
  const linkedPrs = linkedPrNumbersFromTimeline(timeline);
  const linkedPrStates = linkedPrs.map((pr) => prState(repo, pr));

  const reopen = shouldReopen(stateReason, labels, linkedPrStates);

  if (!reopen) {
    return { reopened: false, reason: `no guard action (state_reason=${stateReason})`, linkedPrs, linkedPrStates };
  }

  if (dryRun) {
    return { reopened: false, reason: "dry-run: would reopen", linkedPrs, linkedPrStates };
  }

  ensureLabel(repo);
  execFileSync("gh", ["issue", "edit", String(issue), "--repo", repo, "--add-label", GUARD_LABEL], {
    encoding: "utf8",
  });
  execFileSync("gh", ["issue", "comment", String(issue), "--repo", repo, "--body", commentBody(issue)], {
    encoding: "utf8",
  });
  execFileSync("gh", ["issue", "reopen", String(issue), "--repo", repo], { encoding: "utf8" });

  return { reopened: true, reason: "reopened", linkedPrs, linkedPrStates };
}

function parseArgs(argv) {
  const args = { dryRun: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--repo") args.repo = argv[++i];
    else if (a === "--issue") args.issue = Number(argv[++i]);
    else if (a === "--dry-run") args.dryRun = true;
    else if (a === "--help" || a === "-h") {
      console.error(
        "Usage: mass-close-guard.mjs --repo OWNER/REPO --issue N [--dry-run]\n" +
          "  Reopens an issue closed as not_planned while agent-labeled, unless a\n" +
          "  merged PR references it. Pure decision: shouldReopen(stateReason, labels, linkedPrStates).",
      );
      process.exit(0);
    } else {
      console.error(`unknown arg: ${a}`);
      process.exit(2);
    }
  }
  if (!args.repo || !args.issue) {
    console.error("missing --repo or --issue");
    process.exit(2);
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv);
  const result = guard({ repo: args.repo, issue: args.issue, dryRun: args.dryRun });
  console.log(JSON.stringify(result));
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
