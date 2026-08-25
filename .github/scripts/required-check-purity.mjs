#!/usr/bin/env node
// Required-check purity lint (fleet-ops central reusable set).
//
// A required status check must be a pure function of the PR's own diff.
// Exact equality against a shared committed baseline
// (`counts[x] !== ceiling`) is a global lock: every PR serialises on one
// number and the merge queue thrashes. Budget-style `<=` / `>` is fine.
// Tightening a ceiling happens on main after merge, never in the PR.
//
// Advisory by default (warn, exit 0). Pass --enforce to fail.
// Surface: local files only. No paid services.

import { appendFileSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { extname, join, relative, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const SCAN_EXTS = new Set([".mjs", ".js", ".cjs", ".ts", ".tsx", ".py"]);
const SKIP_DIRS = new Set([
  ".git",
  "node_modules",
  "dist",
  "coverage",
  "vendor",
  ".fleet-ops-purity",
  ".fleet-ops-linter",
]);
const MAX_FILE_BYTES = 512 * 1024;

const SCRIPT_DIR = fileURLToPath(new URL(".", import.meta.url));
const OWN_FIXTURES = resolve(SCRIPT_DIR, "../../tests/fixtures/required-check-purity");

/** `counts[x] !== ceiling` / `counts[x] != ceiling` — the 0509 textbook form. */
const EXACT_EQ_COUNT = /\bcounts?\s*\[[^\]]+\]\s*(?:!==|!=)\s*ceiling\b/;
/** Same idea without a subscript: `count !== ceiling`. */
const EXACT_EQ_BARE = /\b(?:count|actual|got)\s*(?:!==|!=)\s*(?:ceiling|baseline)\b/;
/** The gate tells the PR to edit the shared number. Split so this file does not match itself. */
const UPDATE_IN_PR = new RegExp(`run --update in this${" "}PR`, "i");
const EDIT_SHARED_IN_PR = new RegExp(
  `(?:edit|update|change)\\s+(?:the\\s+)?shared\\s+baseline in (?:this|the)${" "}PR`,
  "i",
);

/**
 * @typedef {{
 *   file: string,
 *   line: number,
 *   kind: "exact-equality-baseline" | "pr-must-edit-shared-baseline",
 *   text: string,
 * }} Finding
 */

/**
 * @param {string} line
 * @returns {boolean}
 */
export function lineIsComment(line) {
  const trimmed = line.trim();
  return (
    trimmed.startsWith("//") ||
    trimmed.startsWith("#") ||
    trimmed.startsWith("*") ||
    trimmed.startsWith("/*") ||
    trimmed.startsWith("*/")
  );
}

/**
 * Classify one source line. Comments are ignored so a doc note about the
 * old shape cannot keep a fixed ratchet noisy.
 *
 * @param {string} line
 * @returns {Finding["kind"] | null}
 */
export function classifyLine(line) {
  if (lineIsComment(line)) return null;
  if (EXACT_EQ_COUNT.test(line) || EXACT_EQ_BARE.test(line)) {
    return "exact-equality-baseline";
  }
  if (UPDATE_IN_PR.test(line) || EDIT_SHARED_IN_PR.test(line)) {
    return "pr-must-edit-shared-baseline";
  }
  return null;
}

/**
 * @param {string} source
 * @param {string} filename
 * @returns {Finding[]}
 */
export function findingsInSource(source, filename = "input") {
  const findings = [];
  const lines = source.split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const kind = classifyLine(lines[i]);
    if (!kind) continue;
    findings.push({
      file: filename,
      line: i + 1,
      kind,
      text: lines[i].trim(),
    });
  }
  return findings;
}

/**
 * @param {string} dir
 * @param {(filePath: string) => void} visit
 */
function walk(dir, visit) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      walk(full, visit);
      continue;
    }
    if (!entry.isFile()) continue;
    if (!SCAN_EXTS.has(extname(entry.name))) continue;
    visit(full);
  }
}

/**
 * @param {string} root
 * @param {string} filePath
 * @returns {boolean}
 */
function skipOwnFixture(root, filePath) {
  const rootResolved = resolve(root);
  const fileResolved = resolve(filePath);
  if (!fileResolved.startsWith(OWN_FIXTURES)) return false;
  // Scanning the fixture dir itself is how tests prove the 0509 shapes.
  return !rootResolved.startsWith(OWN_FIXTURES);
}

/**
 * Walk `root` and return every purity finding.
 *
 * @param {string} root
 * @returns {Finding[]}
 */
export function scanRoot(root) {
  const absRoot = resolve(root);
  /** @type {Finding[]} */
  const findings = [];
  walk(absRoot, (filePath) => {
    if (skipOwnFixture(absRoot, filePath)) return;
    let st;
    try {
      st = statSync(filePath);
    } catch {
      return;
    }
    if (st.size > MAX_FILE_BYTES) return;
    let source;
    try {
      source = readFileSync(filePath, "utf8");
    } catch {
      return;
    }
    const rel = relative(absRoot, filePath).split("\\").join("/");
    findings.push(...findingsInSource(source, rel));
  });
  findings.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line);
  return findings;
}

/**
 * @param {Finding["kind"]} kind
 * @returns {string}
 */
function kindLabel(kind) {
  if (kind === "exact-equality-baseline") {
    return "exact equality against a shared committed baseline";
  }
  return "required check tells the PR to edit a shared baseline";
}

/**
 * @param {Finding[]} findings
 * @returns {string}
 */
export function renderReport(findings) {
  if (findings.length === 0) {
    return "Required-check purity: clean.\n";
  }
  const lines = [
    `Required-check purity: ${findings.length} finding${findings.length === 1 ? "" : "s"}`,
    "",
    "A required status check must be a pure function of the PR's own diff.",
    "Fail only when a count exceeds its ceiling (`>` / `<=`). Tighten the",
    "shared baseline on main after merge, never inside the contributor PR.",
    "",
  ];
  for (const finding of findings) {
    lines.push(`${finding.file}:${finding.line}: ${kindLabel(finding.kind)}`);
    lines.push(`  ${finding.text}`);
    lines.push("");
  }
  return `${lines.join("\n")}\n`;
}

/**
 * @param {Finding[]} findings
 * @param {boolean} emit
 */
export function emitGithubAnnotations(findings, emit) {
  if (!emit) return;
  for (const finding of findings) {
    const msg = `${kindLabel(finding.kind)}: ${finding.text}`.replace(/\r?\n/gu, " ");
    console.error(
      `::warning file=${finding.file},line=${finding.line},title=Required-check purity::${msg}`,
    );
  }
}

function printUsage() {
  console.log(`Usage: required-check-purity.mjs [options]

Scan a repo for required-check impurity: exact equality against a shared
committed baseline, or a gate that fails unless the PR edits that file.

Options:
  --root <dir>           Directory to scan (default: cwd)
  --format <human|json>  Output format (default: human)
  --output-json <path>   Also write the report JSON to this file
  --advisory             Warn and exit 0 even with findings (default)
  --enforce              Exit 1 when findings exist
  --help                 Show this message
`);
}

/**
 * @param {string[]} argv
 */
export function parseArgs(argv) {
  const args = {
    root: process.cwd(),
    format: "human",
    outputJson: "",
    enforce: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    }
    if (arg === "--advisory") {
      args.enforce = false;
      continue;
    }
    if (arg === "--enforce") {
      args.enforce = true;
      continue;
    }
    const next = argv[i + 1];
    if (arg === "--root" && next) {
      args.root = next;
      i += 1;
      continue;
    }
    if (arg === "--format" && next) {
      args.format = next;
      i += 1;
      continue;
    }
    if (arg === "--output-json" && next) {
      args.outputJson = next;
      i += 1;
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }
  if (args.format !== "human" && args.format !== "json") {
    throw new Error(`--format must be human or json, got ${args.format}`);
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const findings = scanRoot(args.root);
  const report = {
    generated_at: new Date().toISOString(),
    root: resolve(args.root),
    advisory: !args.enforce,
    findings,
  };
  const json = JSON.stringify(report, null, 2);
  const human = renderReport(findings);
  console.log(args.format === "json" ? json : human);

  emitGithubAnnotations(findings, Boolean(process.env.GITHUB_ACTIONS));
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\n${human}\n`);
  }
  if (args.outputJson) writeFileSync(resolve(args.outputJson), json);
  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(
      process.env.GITHUB_OUTPUT,
      `findings=${findings.length}\nadvisory=${args.enforce ? "false" : "true"}\n`,
    );
  }

  if (args.enforce && findings.length > 0) process.exit(1);
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
