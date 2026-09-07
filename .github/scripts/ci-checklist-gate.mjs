#!/usr/bin/env node
// CI checklist gate — fail a PR with unchecked required body checkboxes.
//
// Required checklist items are:
//   - any item whose text begins with "required:" (case-insensitive, optional
//     markdown bold/italic), or
//   - any item inside a section whose heading is "Verification" (## or ###).
//
// Exit 0: all required boxes are checked, or no required boxes exist.
// Exit 1: one or more required boxes are unchecked.
// Surface: local text only; no network.
//
// Usage:
//   node .github/scripts/ci-checklist-gate.mjs --body-env PR_BODY
//   node .github/scripts/ci-checklist-gate.mjs --body-file pr-body.md
//   node .github/scripts/ci-checklist-gate.mjs --body "markdown"
//   node .github/scripts/ci-checklist-gate.mjs --body-env PR_BODY --format json

import { appendFileSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const CHECKBOX_RE = /^\s*[-*+]\s+\[([xX ])\]\s*(.*)$/;
const HEADING_RE = /^(#{1,6})\s+(.+)$/;
const VERIFICATION_RE = /^verification\s*:?\s*$/i;
const REQUIRED_PREFIX_RE = /^(?:\*\*?|__?)?required(?:\*\*?|__?)?\s*:\s*(.*)$/i;

/**
 * @param {string[]} argv
 */
function parseArgs(argv) {
  const args = {
    body: "",
    bodyFile: "",
    bodyEnv: "",
    format: "human",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    }
    if (arg === "--format" && i + 1 < argv.length) {
      args.format = argv[i + 1];
      i += 1;
      continue;
    }
    if (arg === "--body" && i + 1 < argv.length) {
      args.body = argv[i + 1];
      i += 1;
      continue;
    }
    if (arg === "--body-file" && i + 1 < argv.length) {
      args.bodyFile = argv[i + 1];
      i += 1;
      continue;
    }
    if (arg === "--body-env" && i + 1 < argv.length) {
      args.bodyEnv = argv[i + 1];
      i += 1;
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }
  if (args.format !== "human" && args.format !== "json") {
    throw new Error("--format must be human or json");
  }
  if (!args.body && !args.bodyFile && !args.bodyEnv) {
    throw new Error("provide --body, --body-file, or --body-env");
  }
  return args;
}

function printUsage() {
  console.log(`Usage: ci-checklist-gate.mjs [options]

Verify that all required checkboxes in a PR body are checked.

Options:
  --body <text>         Literal markdown body
  --body-file <path>    Read body from file
  --body-env <var>      Read body from environment variable
  --format <human|json> Output format (default: human)
  --help                Show this message
`);
}

/**
 * @param {{body: string, bodyFile: string, bodyEnv: string}} args
 */
function readBody(args) {
  if (args.body) return args.body;
  if (args.bodyFile) return readFileSync(args.bodyFile, "utf8");
  if (args.bodyEnv) {
    const val = process.env[args.bodyEnv];
    if (val === undefined) {
      throw new Error(`environment variable ${args.bodyEnv} is not set`);
    }
    return val;
  }
  return "";
}

/**
 * @param {string} rawText
 * @returns {string|null}
 */
function stripRequiredPrefix(rawText) {
  const m = rawText.match(REQUIRED_PREFIX_RE);
  if (!m) return null;
  let rest = m[1] || "";
  rest = rest.replace(/^(?:\*\*?|__?)\s*/, "");
  rest = rest.replace(/\s*(?:\*\*?|__?)$/, "");
  return rest.trim();
}

/**
 * @param {string} body
 * @returns {{line: number, raw: string, text: string, inVerification: boolean}[]}
 */
export function findUncheckedRequired(body) {
  const lines = body.split(/\r?\n/);
  /** @type {{level: number, name: string}[]} */
  const sections = [];
  /** @type {{line: number, raw: string, text: string, inVerification: boolean}[]} */
  const unchecked = [];

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const heading = line.match(HEADING_RE);
    if (heading) {
      const level = heading[1].length;
      const name = heading[2].trim();
      while (sections.length > 0 && sections[sections.length - 1].level >= level) {
        sections.pop();
      }
      sections.push({ level, name });
      continue;
    }

    const checkbox = line.match(CHECKBOX_RE);
    if (!checkbox) continue;

    const checked = checkbox[1].toLowerCase() === "x";
    const rawText = checkbox[2].trim();
    const inVerification = sections.some((s) => VERIFICATION_RE.test(s.name));
    const hasRequiredPrefix = stripRequiredPrefix(rawText) !== null;

    if (!checked && (inVerification || hasRequiredPrefix)) {
      const cleanText = stripRequiredPrefix(rawText) ?? rawText;
      unchecked.push({
        line: i + 1,
        raw: rawText,
        text: cleanText,
        inVerification,
      });
    }
  }

  return unchecked;
}

/**
 * @param {{line: number, raw: string, text: string, inVerification: boolean}[]} unchecked
 */
function buildReport(unchecked) {
  const human =
    unchecked.length === 0
      ? "CI checklist gate: all required checkboxes are checked."
      : [
          `CI checklist gate: ${unchecked.length} required checkbox${unchecked.length === 1 ? "" : "es"} unchecked.`,
          "",
          "Every required checkbox must be checked before merge.",
          "A checkbox is required when it is in a '## Verification' section or its text starts with 'required:'.",
          "",
          ...unchecked.map((u) => `  line ${u.line}: ${u.text}`),
        ].join("\n");

  const json = {
    status: unchecked.length === 0 ? "pass" : "fail",
    unchecked_required: unchecked.map((u) => ({
      line: u.line,
      text: u.text,
      in_verification: u.inVerification,
    })),
  };

  return { human, json };
}

/**
 * @param {{line: number, raw: string, text: string, inVerification: boolean}[]} unchecked
 */
function emitAnnotations(unchecked) {
  for (const u of unchecked) {
    const msg = `Required checkbox unchecked: ${u.text}`.replace(/\r?\n/gu, " ");
    console.error(`::error::${msg} (line ${u.line})`);
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const body = readBody(args);
  const unchecked = findUncheckedRequired(body);
  const report = buildReport(unchecked);

  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n${report.human}\n`);
  }
  if (process.env.GITHUB_ACTIONS) {
    emitAnnotations(unchecked);
  }

  console.log(args.format === "json" ? JSON.stringify(report.json, null, 2) : report.human);

  if (unchecked.length > 0) {
    process.exit(1);
  }
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
