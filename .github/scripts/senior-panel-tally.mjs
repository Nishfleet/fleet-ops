#!/usr/bin/env node
// Senior-panel conference tally (fleet-ops #223).
//
// Pure aggregation of the three senior auditors' verdicts into one
// conference result. The auditors (GLM-5.2 devin / GLM-5.3 free /
// deepseek-v4-pro straitly) each return APPROVE or REJECT with a reason;
// this function decides the conference outcome:
//
//   - APPROVE  : >= 2 of 3 APPROVE  -> check goes green; verdicts posted.
//   - REJECT   : >= 2 of 3 REJECT   -> check stays red; reject reasons posted.
//   - PENDING  : fewer than 3 verdicts returned (a seat could not convene)
//                -> fail-closed: never auto-green. The workflow files an
//                escalation (#221) and leaves the check not-green. A 1-1
//                split with a missing seat is also PENDING, not APPROVE —
//                the conference did not convene 2-of-3 either way.
//
// "Any REJECT with reasons -> check stays red" (issue §3) is the REJECT
// bucket: when the conference rejects, every rejector's reason is surfaced
// so the loop-to-green worker can address them. A lone REJECT among 2
// APPROVEs is noted but does not block — 2-of-3 admits.
//
// Pure function: verdicts in, result out. No network, no I/O. Unit-testable.
// Surface: local JSON in / JSON out. No paid services.

import { readFileSync } from "node:fs";

/**
 * @typedef {{
 *   seat: string,
 *   verdict: "APPROVE" | "REJECT",
 *   reason: string,
 *   round?: number,
 * }} Verdict
 *
 * @typedef {{
 *   result: "APPROVE" | "REJECT" | "PENDING",
 *   approves: number,
 *   rejects: number,
 *   missing: number,
 *   reasons: string[],
 *   note?: string,
 * }} TallyResult
 */

export const REQUIRED_SEATS = 3;
export const APPROVE_THRESHOLD = 2;

/**
 * Normalise a single verdict object. Tolerates missing fields by returning
 * null (a malformed verdict counts as a missing seat — fail-closed).
 *
 * @param {unknown} v
 * @returns {Verdict | null}
 */
export function normaliseVerdict(v) {
  if (!v || typeof v !== "object") return null;
  const seat = String(/** @type {any} */ (v).seat || "").trim();
  const verdict = String(/** @type {any} */ (v).verdict || "").trim().toUpperCase();
  const reason = String(/** @type {any} */ (v).reason || "").trim();
  if (!seat) return null;
  if (verdict !== "APPROVE" && verdict !== "REJECT") return null;
  return { seat, verdict, reason, round: /** @type {any} */ (v).round };
}

/**
 * @param {Verdict[]} verdicts
 * @returns {TallyResult}
 */
export function tallyConference(verdicts) {
  const clean = verdicts.map(normaliseVerdict).filter((v) => v !== null);
  const approves = clean.filter((v) => v.verdict === "APPROVE").length;
  const rejects = clean.filter((v) => v.verdict === "REJECT").length;
  const missing = REQUIRED_SEATS - clean.length;

  if (clean.length < REQUIRED_SEATS) {
    // Fail-closed: a seat that could not convene means the conference did
    // not reach 2-of-3 either way. Never auto-green on a partial panel.
    return {
      result: "PENDING",
      approves,
      rejects,
      missing,
      reasons: clean.map((v) => `${v.seat}: ${v.verdict} — ${v.reason}`),
      note: `conference incomplete: ${missing} seat(s) did not convene; fail-closed pending`,
    };
  }

  if (approves >= APPROVE_THRESHOLD) {
    const loneRejects = clean.filter((v) => v.verdict === "REJECT");
    return {
      result: "APPROVE",
      approves,
      rejects,
      missing: 0,
      reasons: clean.map((v) => `${v.seat}: ${v.verdict} — ${v.reason}`),
      note:
        loneRejects.length > 0
          ? `admitted 2-of-3; ${loneRejects.length} dissent noted but non-blocking`
          : "unanimous approve",
    };
  }

  // rejects >= 2 (since 3 verdicts, approves < 2)
  const rejectors = clean.filter((v) => v.verdict === "REJECT");
  return {
    result: "REJECT",
    approves,
    rejects,
    missing: 0,
    reasons: rejectors.map((v) => `${v.seat}: ${v.reason}`),
    note: `conference rejected ${rejects}-of-${REQUIRED_SEATS}; address the reasons above and re-push`,
  };
}

function usage() {
  return [
    "senior-panel-tally.mjs — tally three senior-auditor verdicts (#223).",
    "",
    "Reads a JSON array on stdin: [{ seat, verdict, reason }, ...] (<= 3).",
    "Prints { result, approves, rejects, missing, reasons, note }.",
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
    process.stderr.write(`senior-panel-tally: invalid JSON on stdin: ${e}\n`);
    return 2;
  }
  if (!Array.isArray(data)) {
    process.stderr.write("senior-panel-tally: stdin must be a JSON array of verdicts\n");
    return 2;
  }
  const result = tallyConference(data);
  process.stdout.write(JSON.stringify(result) + "\n");
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exit(main(process.argv.slice(2)));
}
