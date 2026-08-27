#!/usr/bin/env node
// bulk-close-pr-landings.mjs — fleet-ops#1162 (audit finding 4).
//
// Housekeeping one-shot. Scans `Nishfleet/fleet2` (or `--repo`) for open
// `docs(pr-landing):` pull requests whose diff is disposition-only
// markdown (no real code changes), then closes them with a single ack
// comment per PR.
//
// Why this exists (issue body):
//   277 inert docs(pr-landing) PRs accumulated in Nishfleet/fleet2 since
//   2026-08-19 (188h+ old, allow_auto_merge=False, no auto-merge-arm.yml).
//   The PR list is unusable; new real work is buried. This is the
//   one-shot cleanup. Prevention is the sibling vacation Actions /
//   orphan-workflow check, not this script.
//
// What this does NOT do:
//   - Close PRs that are not in scope: the title prefix
//     `docs(pr-landing):` must match, and EVERY file in the PR must end
//     with `.md` (no real code diff). PRs that include `bin/`, `lib/`,
//     `tests/`, `systemd/`, `etc/`, etc. edits are kept untouched.
//   - Touch `auto-merge-arm.yml` or `allow_auto_merge`. That constraint
//     is already satisfied in fleet2 today (the .github directory does
//     not even exist on `main`), and this script does not write to the
//     base branch at all — it only mutates PR state.
//   - Trigger the mass-close-guard (`.github/scripts/mass-close-guard.mjs`).
//     The guard only fires on `issues: closed` events for agent-labeled
//     issues, not on PRs.
//
// Search quirk: `gh pr list --search 'docs(pr-landing)'` returns 0
// because `(` and `)` are GitHub search operators. This script uses the
// REST `/search/issues` endpoint with `q=repo:OWNER/REPO+is:pr+is:open`
// and filters in-process, which is the only way to enumerate them.
//
// Surface: gh CLI + GitHub REST API only. No paid services. Pure logic
// (`isDispositionOnly`, `matchAckTemplate`) is exported so the test
// suite can drive it without a live `gh`.
//
// USAGE
//   bulk-close-pr-landings.mjs                     # dry-run, default repo
//   bulk-close-pr-landings.mjs --apply             # actually close
//   bulk-close-pr-landings.mjs --repo OWNER/REPO   # operate on a different repo
//   bulk-close-pr-landings.mjs --limit 10          # cap the run for safety
//   bulk-close-pr-landings.mjs --json              # machine-readable output
//
// EXIT CODES
//   0   success (incl. nothing to do, or dry-run only)
//   2   missing prereq (gh, GH_TOKEN, repo arg)
//   3   partial failure (some closes failed; see stderr for which)
//   4   hard API failure (search / list failed)

import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const ISSUE_REF = "fleet-ops#1162";
const ACK_MARKER = `<!-- ${ISSUE_REF} -->`;
const TITLE_PREFIX = "docs(pr-landing):";
const DISPOSITION_GLOB = /^(?:PR-LANDING-DISPOSITION|FAILED-UNIT-DISPOSITION|PLAYBOOK-INCIDENTS)-.+\.md$/;

/**
 * Pure decision: is this PR a disposition-only housekeeping target?
 *
 * @param {string} title       The PR title, exact.
 * @param {Array<{path: string}>} files  The PR's changed files.
 * @returns {boolean}
 */
export function isDispositionOnly(title, files) {
  if (typeof title !== "string" || !title.startsWith(TITLE_PREFIX)) return false;
  if (!Array.isArray(files) || files.length === 0) return false;
  // Every changed file must be a markdown file. This is the "no real
  // code diff" guarantee the issue spec asks for.
  for (const f of files) {
    if (!f || typeof f.path !== "string") return false;
    if (!f.path.endsWith(".md")) return false;
  }
  return true;
}

/**
 * The one ack comment posted on every close. Plain text, audit-friendly,
 * references the issue so a future opener sees the rationale.
 *
 * Exported so the test can lock its exact wording.
 */
export function ackCommentBody() {
  return [
    ACK_MARKER,
    "",
    `Housekeeping close (${ISSUE_REF}, audit finding 4, 2026-08-27).`,
    "",
    "This PR's diff is disposition-only markdown (`PR-LANDING-DISPOSITION-*.md` /",
    "`FAILED-UNIT-DISPOSITION-*.md`); there is no real code change to land.",
    "These PRs accumulated in `Nishfleet/fleet2` since 2026-08-19",
    "(188h+ old, `allow_auto_merge=False`, no `auto-merge-arm.yml` on `main`,",
    "so they will never auto-merge in 10 days). The PR list has been",
    "unusable and new real work is buried.",
    "",
    "This is one-shot housekeeping, not a product decision. Reopen if the",
    "work should be re-attempted. The sibling vacation Actions /",
    "orphan-workflow issue covers prevention; this run is the cleanup.",
  ].join("\n");
}

function ghJson(args) {
  return JSON.parse(
    execFileSync("gh", ["api", ...args], {
      encoding: "utf8",
      maxBuffer: 16 * 1024 * 1024,
    }),
  );
}

/**
 * Build the search URL with query params. `gh api` does not expose a
 * GET-query-string builder for path endpoints, so we compose the URL
 * ourselves and pass it as the path.
 */
function searchUrl(q, page) {
  const params = new URLSearchParams({ q, per_page: "100" });
  if (page) params.set("page", String(page));
  return `search/issues?${params.toString()}`;
}

function ghText(args) {
  return execFileSync("gh", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
}

/**
 * REST search to enumerate open `docs(pr-landing):` PRs in the repo.
 * `gh pr list --search 'docs(pr-landing)'` returns 0 (paren-operator
 * quirk), so this is the only enumeration path that works.
 */
function searchOpenPrLandings(repo) {
  // Note: parens in the search token are not actually operators for
  // this token (GitHub only treats a few reserved chars like `()` in
  // specific contexts), but the substring match is the only safe way
  // to enumerate. We narrow to the exact title prefix in-process.
  const q = `repo:${repo} is:pr is:open ${TITLE_PREFIX} in:title`;
  const out = ghJson([searchUrl(q)]);
  if (!Array.isArray(out.items)) {
    throw new Error(`search returned no items array: ${JSON.stringify(out).slice(0, 200)}`);
  }
  // The search matched on the substring `docs(pr-landing)`; narrow to the
  // exact title prefix to drop lookalikes (e.g. `docs(quarantine): ...
  // PR-LANDING ...`).
  return out.items
    .filter((it) => it && typeof it.title === "string" && it.title.startsWith(TITLE_PREFIX))
    .map((it) => ({
      number: it.number,
      title: it.title,
      url: it.html_url,
      nodeId: it.node_id,
    }));
}

function prFiles(repo, number) {
  // --paginate handles per_page; passing `-f per_page=...` would switch
  // the method to POST. See `.github/scripts/mass-close-guard.mjs` for
  // the same pattern.
  const raw = ghJson([`repos/${repo}/pulls/${number}/files`, "--paginate"]);
  // GitHub returns `filename`; normalise to `path` so `isDispositionOnly`
  // and the tests speak one vocabulary.
  if (!Array.isArray(raw)) return raw;
  return raw.map((f) => (f && typeof f === "object" ? { path: f.filename, ...f } : f));
}

function prState(repo, number) {
  const data = ghJson([
    `repos/${repo}/pulls/${number}`,
    "--jq",
    "{state: .state, merged: .merged}",
  ]);
  if (data && data.merged === true) return "MERGED";
  if (data && data.state === "closed") return "CLOSED";
  if (data && data.state === "open") return "OPEN";
  return null;
}

function closePr(repo, number, comment) {
  // `gh pr close -c "..."` posts the comment as the closing comment and
  // closes in one step. Do not delete the branch — many of these PRs are
  // on long-lived branches and the spec says "no main-branch change"
  // (close is PR state, not branch).
  ghText([
    "pr",
    "close",
    String(number),
    "--repo",
    repo,
    "-c",
    comment,
  ]);
}

/**
 * Plan a run: enumerate, classify, return actions.
 *
 * @param {{repo: string, limit?: number, apply?: boolean}} opts
 * @returns {{
 *   scanned: number,
 *   disposition_only: number,
 *   kept: number,
 *   already_closed: number,
 *   actions: Array<{number: number, title: string, decision: 'close'|'keep'|'already-closed', reason: string}>,
 *   errors: Array<{number: number, phase: string, message: string}>,
 * }}
 */
export function plan(opts) {
  const { repo, limit = Infinity, apply = false } = opts;
  const prs = searchOpenPrLandings(repo);
  const actions = [];
  const errors = [];
  let dispositionOnly = 0;
  let kept = 0;
  let alreadyClosed = 0;

  for (const pr of prs) {
    let files;
    try {
      files = prFiles(repo, pr.number);
    } catch (e) {
      errors.push({ number: pr.number, phase: "list-files", message: e.message || String(e) });
      actions.push({ number: pr.number, title: pr.title, decision: "keep", reason: "list-files failed; not closing" });
      continue;
    }
    if (!isDispositionOnly(pr.title, files)) {
      kept += 1;
      actions.push({
        number: pr.number,
        title: pr.title,
        decision: "keep",
        reason: "has non-md file(s) — not disposition-only",
      });
      continue;
    }
    // Defensive: a PR can race between search and files fetch and be
    // closed. Skip gracefully instead of failing.
    try {
      const st = prState(repo, pr.number);
      if (st !== "OPEN") {
        alreadyClosed += 1;
        actions.push({ number: pr.number, title: pr.title, decision: "already-closed", reason: `state=${st}` });
        continue;
      }
    } catch (e) {
      errors.push({ number: pr.number, phase: "state", message: e.message || String(e) });
      continue;
    }

    dispositionOnly += 1;
    if (actions.filter((a) => a.decision === "close").length >= limit) {
      actions.push({ number: pr.number, title: pr.title, decision: "keep", reason: "limit reached; not closing" });
      continue;
    }

    if (apply) {
      try {
        closePr(repo, pr.number, ackCommentBody());
        actions.push({ number: pr.number, title: pr.title, decision: "close", reason: "closed" });
      } catch (e) {
        errors.push({ number: pr.number, phase: "close", message: e.message || String(e) });
        actions.push({ number: pr.number, title: pr.title, decision: "keep", reason: `close failed: ${e.message || e}` });
      }
    } else {
      actions.push({ number: pr.number, title: pr.title, decision: "close", reason: "dry-run" });
    }
  }

  return {
    scanned: prs.length,
    disposition_only: dispositionOnly,
    kept,
    already_closed: alreadyClosed,
    actions,
    errors,
  };
}

function parseArgs(argv) {
  const args = { dryRun: true, repo: "Nishfleet/fleet2", limit: Infinity, json: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--apply") args.dryRun = false;
    else if (a === "--dry-run") args.dryRun = true;
    else if (a === "--repo") args.repo = argv[++i];
    else if (a === "--limit") args.limit = Number(argv[++i]);
    else if (a === "--json") args.json = true;
    else if (a === "--help" || a === "-h") {
      console.error(
        "Usage: bulk-close-pr-landings.mjs [--apply] [--repo OWNER/REPO] [--limit N] [--json]\n" +
          "  Housekeeping close of disposition-only `docs(pr-landing):` PRs (fleet-ops#1162).\n" +
          "  Default: dry-run on Nishfleet/fleet2. --apply to actually close.\n" +
          "  --limit caps the number of closes for a safety-step run.",
      );
      process.exit(0);
    } else {
      console.error(`unknown arg: ${a}`);
      process.exit(2);
    }
  }
  if (!args.repo) {
    console.error("missing --repo");
    process.exit(2);
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv);
  let result;
  try {
    result = plan({ repo: args.repo, limit: args.limit, apply: !args.dryRun });
  } catch (e) {
    console.error(`hard failure: ${e.message || e}`);
    process.exit(4);
  }

  if (args.json) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.log(
      `scanned=${result.scanned} disposition_only=${result.disposition_only} kept=${result.kept} ` +
        `already_closed=${result.already_closed} errors=${result.errors.length} mode=${
          args.dryRun ? "dry-run" : "apply"
        }`,
    );
    for (const a of result.actions) {
      console.log(`  ${a.decision.padEnd(15)} #${a.number}  ${a.title.slice(0, 80)}  (${a.reason})`);
    }
    if (result.errors.length) {
      for (const e of result.errors) {
        console.error(`  ERR #${e.number} (${e.phase}): ${e.message}`);
      }
    }
  }

  if (result.errors.length) process.exit(3);
  process.exit(0);
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
