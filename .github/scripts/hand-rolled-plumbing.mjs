#!/usr/bin/env node
// Mechanical hard-reject for hand-rolled orchestration (fleet-ops #223).
//
// Nish, 2026-08-26, ledgered 'hand-built plumbing BAN': this is NOT a
// judgment call for the panel. Presence of the pattern = REJECT, with the
// replacement primitive named. Pure-logic tested scripts (parse, compute,
// compose) are fine; anything that schedules, retries, or supervises by
// hand is not.
//
// Pure function of a unified diff. No network. The conference calls this
// before any auditor seat; a hit short-circuits to REJECT.

import { readFileSync } from "node:fs";

/** Ledger line — must appear verbatim on every conference context packet. */
export const HAND_BUILT_PLUMBING_BAN =
  "HARD REJECTION CRITERION (Nish, 2026-08-26, ledgered 'hand-built plumbing BAN'): the conference AUTOMATICALLY REJECTS any diff containing hand-rolled orchestration — bespoke retry/backoff loops, sleep-poll loops, cooldown timers, queue/dispatch daemons, or watchdog scripts — where a systemd primitive (Restart=, StartLimit*, OnFailure=, timers, path units), a GitHub-inbuilt gate, or a Pi stock extension provides the behavior. This is not a judgment call for the panel: presence of the pattern = REJECT with the replacement primitive named. The auditor context packet must include this ledger line verbatim. Pure-logic tested scripts (parse, compute, compose) are fine; anything that schedules, retries, or supervises by hand is not.";

/**
 * @typedef {{
 *   id: "sleep-poll" | "retry-backoff" | "cooldown" | "watchdog" | "dispatch-daemon",
 *   path: string,
 *   replacement: string,
 *   evidence: string,
 * }} PlumbingFinding
 */

/**
 * @param {string} path
 * @returns {boolean}
 */
export function skipPath(path) {
  if (!path) return true;
  if (path.startsWith("tests/") || path.startsWith("docs/") || path.startsWith("reports/")) {
    return true;
  }
  if (path.endsWith(".md")) return true;
  if (path.endsWith("hand-rolled-plumbing.mjs")) return true;
  return false;
}

/**
 * Drop line comments so a doc note about the ban cannot trip the detector.
 *
 * @param {string} line
 * @param {string} path
 * @returns {string}
 */
export function stripComment(line, path) {
  if (
    path.endsWith(".sh") ||
    path.endsWith(".bash") ||
    path.endsWith(".yml") ||
    path.endsWith(".yaml")
  ) {
    return line.replace(/#.*$/, "");
  }
  if (path.endsWith(".mjs") || path.endsWith(".js") || path.endsWith(".ts")) {
    return line.replace(/\/\/.*$/, "");
  }
  return line;
}

/**
 * Collect added lines per file from a unified diff.
 *
 * @param {string} diff
 * @returns {{ path: string, added: string[] }[]}
 */
export function addedByFile(diff) {
  const files = [];
  let path = "";
  let added = [];
  const flush = () => {
    if (path) files.push({ path, added });
  };
  for (const line of String(diff || "").split(/\r?\n/)) {
    if (line.startsWith("+++ b/")) {
      flush();
      path = line.slice("+++ b/".length);
      added = [];
      continue;
    }
    if (line.startsWith("+++ /dev/null")) {
      flush();
      path = "";
      added = [];
      continue;
    }
    if (path && line.startsWith("+") && !line.startsWith("+++")) {
      added.push(line.slice(1));
    }
  }
  flush();
  return files;
}

/**
 * @param {string} path
 * @param {string} code
 * @returns {PlumbingFinding[]}
 */
export function findingsInAddedCode(path, code) {
  const findings = [];
  const hasLoop = /\b(while|until)\b/.test(code);
  const hasSleep = /\bsleep\b/.test(code);
  const hasBackoff = /\b(backoff|retry_count|RETRY_COUNT)\b/.test(code);
  const hasCooldown = /\bcooldown\b/.test(code);
  const hasWhileTrue = /\bwhile\s+true\b/.test(code);

  if (hasLoop && hasSleep) {
    findings.push({
      id: "sleep-poll",
      path,
      replacement: "a systemd timer, path unit, or OnFailure=",
      evidence: "loop + sleep in added lines",
    });
  }
  if (hasBackoff && hasSleep) {
    findings.push({
      id: "retry-backoff",
      path,
      replacement: "Restart= + RestartSec= + StartLimitBurst=",
      evidence: "backoff/retry + sleep in added lines",
    });
  }
  if (hasCooldown && hasSleep) {
    findings.push({
      id: "cooldown",
      path,
      replacement: "RestartSec= or a systemd timer",
      evidence: "cooldown + sleep in added lines",
    });
  }
  if (/watchdog/i.test(path) && (hasSleep || hasLoop)) {
    findings.push({
      id: "watchdog",
      path,
      replacement: "systemd WatchdogSec= / TimeoutStartSec=",
      evidence: "watchdog script with a poll loop",
    });
  }
  if (path.startsWith("bin/") && hasWhileTrue) {
    findings.push({
      id: "dispatch-daemon",
      path,
      replacement: "a systemd timer + pi-systemd-run",
      evidence: "while true in bin/",
    });
  }
  return findings;
}

/**
 * Scan a unified diff. Returns findings (empty = clean).
 *
 * @param {string} diff
 * @returns {PlumbingFinding[]}
 */
export function detectHandRolledPlumbing(diff) {
  const out = [];
  for (const file of addedByFile(diff)) {
    if (skipPath(file.path)) continue;
    const code = file.added.map((l) => stripComment(l, file.path)).join("\n");
    out.push(...findingsInAddedCode(file.path, code));
  }
  return out;
}

function usage() {
  return [
    "hand-rolled-plumbing.mjs — mechanical detect of banned orchestration (#223).",
    "",
    "Reads a unified diff on stdin. Prints a JSON array of findings.",
    "Empty array = clean. Non-empty = conference REJECT.",
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
  const findings = detectHandRolledPlumbing(raw);
  process.stdout.write(JSON.stringify(findings) + "\n");
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exit(main(process.argv.slice(2)));
}
