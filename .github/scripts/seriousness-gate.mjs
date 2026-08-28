#!/usr/bin/env node
// Seriousness gate (fleet-ops #223) — the mechanical, opt-in-free labeler.
//
// A PR is `build:serious` when ANY of these triggers fire:
//   1. control-plane-paths — touches bin/, systemd/, lib/, config/, or
//      .github/workflows/.
//   2. diff-size — more than 300 changed lines (additions + deletions).
//   3. closes-keystone-or-gap-audit — closes an issue labeled `keystone`
//      or `gap-audit`.
//   4. claim-duration — the claim ran longer than 15 minutes, measured from
//      the worker's "claimed by <unit> at <ts>" comment on the closing issue
//      to the PR's created_at. (Nish, 2026-08-26: the threshold is > 15 min,
//      superseding the spec body's "1h".)
//
// Pure function of the PR's own metadata — no network, no GitHub token at
// classify time. The workflow gathers the inputs (gh api) and feeds them in;
// this script never reaches GitHub. That keeps it unit-testable and free of
// the exact-equality / shared-baseline anti-patterns the purity lint guards.
//
// Labeling semantics (issue #223 §1): the gate ADDS `build:serious` when a
// trigger fires. It does NOT remove a hand-added label — "hand-adding the
// label also works; `build:trivial` may be applied ONLY by the panel itself."
// Removal is the panel's job, never the gate's. The workflow decides add vs.
// leave-alone from `serious`; it never strips the label.
//
// Surface: local JSON in / JSON out. No paid services.

import { readFileSync } from "node:fs";

/**
 * @typedef {{
 *   changedFiles: string[],
 *   additions: number,
 *   deletions: number,
 *   closingIssueLabels: string[],
 *   claimDurationMinutes: number | null,
 * }} GateInput
 *
 * @typedef {{
 *   serious: boolean,
 *   triggers: string[],
 *   detail: Record<string, { fired: boolean, value: unknown }>,
 * }} GateResult
 */

/** Paths whose edit makes a build serious (control plane). */
const CONTROL_PLANE_PATHS = [
  "bin/",
  "systemd/",
  "lib/",
  "config/",
  ".github/workflows/",
];

/** Diff-size threshold in changed lines (additions + deletions). */
const DIFF_SIZE_THRESHOLD = 300;

/** Claim-duration threshold in minutes (> this is serious). */
const CLAIM_DURATION_THRESHOLD_MINUTES = 15;

/** Issue labels that mark a closing issue as serious. */
const SERIOUS_CLOSING_LABELS = new Set(["keystone", "gap-audit"]);

/**
 * @param {string[]} changedFiles
 * @returns {string[]}
 */
export function controlPlaneMatches(changedFiles) {
  const hits = [];
  for (const f of changedFiles) {
    for (const prefix of CONTROL_PLANE_PATHS) {
      if (f === prefix.slice(0, -1) || f.startsWith(prefix)) {
        hits.push(f);
        break;
      }
    }
  }
  return hits;
}

/**
 * @param {GateInput} input
 * @returns {GateResult}
 */
export function classifySeriousness(input) {
  const changedFiles = Array.isArray(input.changedFiles) ? input.changedFiles : [];
  const additions = Number(input.additions) || 0;
  const deletions = Number(input.deletions) || 0;
  const closingLabels = Array.isArray(input.closingIssueLabels)
    ? input.closingIssueLabels
    : [];
  const claimMinutes =
    input.claimDurationMinutes === null || input.claimDurationMinutes === undefined
      ? null
      : Number(input.claimDurationMinutes);

  const cpHits = controlPlaneMatches(changedFiles);
  const diffLines = additions + deletions;
  const seriousClosing = closingLabels
    .map((l) => String(l).toLowerCase())
    .filter((l) => SERIOUS_CLOSING_LABELS.has(l));

  const triggers = [];

  const cpFired = cpHits.length > 0;
  if (cpFired) triggers.push("control-plane-paths");

  const sizeFired = diffLines > DIFF_SIZE_THRESHOLD;
  if (sizeFired) triggers.push("diff-size");

  const closingFired = seriousClosing.length > 0;
  if (closingFired) triggers.push("closes-keystone-or-gap-audit");

  let claimFired = false;
  if (claimMinutes !== null && !Number.isNaN(claimMinutes)) {
    claimFired = claimMinutes > CLAIM_DURATION_THRESHOLD_MINUTES;
    if (claimFired) triggers.push("claim-duration");
  }

  return {
    serious: triggers.length > 0,
    triggers,
    detail: {
      "control-plane-paths": { fired: cpFired, value: cpHits },
      "diff-size": { fired: sizeFired, value: diffLines },
      "closes-keystone-or-gap-audit": { fired: closingFired, value: seriousClosing },
      "claim-duration": {
        fired: claimFired,
        value: claimMinutes === null ? null : Math.round(claimMinutes * 100) / 100,
      },
    },
  };
}

function usage() {
  return [
    "seriousness-gate.mjs — classify a PR's build seriousness (fleet-ops #223).",
    "",
    "Reads a JSON object on stdin:",
    '  { "changedFiles": [...], "additions": N, "deletions": N,',
    '    "closingIssueLabels": [...], "claimDurationMinutes": N|null }',
    "",
    "Prints a JSON result: { serious, triggers, detail }.",
    "",
    "Flags:",
    "  --help   show this help",
  ].join("\n");
}

function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    process.stdout.write(usage() + "\n");
    return 0;
  }
  const raw = readFileSync(0, "utf8");
  let data;
  try {
    data = JSON.parse(raw);
  } catch (e) {
    process.stderr.write(`seriousness-gate: invalid JSON on stdin: ${e}\n`);
    return 2;
  }
  const result = classifySeriousness(data);
  process.stdout.write(JSON.stringify(result) + "\n");
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exit(main(process.argv.slice(2)));
}