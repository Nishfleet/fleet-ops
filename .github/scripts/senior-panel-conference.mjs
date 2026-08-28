#!/usr/bin/env node
// Senior-panel conference (fleet-ops #223).
//
// Convenes the three senior auditors on a `build:serious` PR, tallies their
// verdicts, and emits one conference result the check workflow turns into a
// green/red/pending status. This is the GitHub-side orchestrator of the
// conference; the auditor seats themselves run on the VPS (issue #223 §3,
// #185 mechanism order: GitHub-hosted > systemd+pi > agent-specific).
//
// Two dispatch modes:
//
//   --stub   (default when no live bridge is configured)
//     Deterministic verdicts with NO network. Driven by
//     SENIOR_PANEL_STUB_OUTCOME = approve | reject | pending so the tally,
//     verdict-posting, and fail-closed mechanics can be exercised in CI for
//     all three outcomes. The stub is the "stubbed conference" the issue's
//     stubbed acceptance names — it proves the mechanics, not the judgement.
//
//   --live   (when SENIOR_PANEL_BRIDGE_URL + SENIOR_PANEL_BRIDGE_TOKEN are set)
//     POSTs the context packet to a VPS bridge endpoint, which convenes the
//     real three-seat conference (GLM-5.2 devin / GLM-5.3 free / ds4-pro
//     straitly) via the #146 pi-audit@ machinery and returns the verdicts.
//     If the bridge is unreachable or returns fewer than 3 verdicts, the
//     conference is PENDING (fail-closed) and an escalation is signalled —
//     "seats walled -> pending + escalation" (#223 §3, #221).
//
//     The live bridge + the pi-audit@ template units are NOT in main yet
//     (#146 shipped a local dedupe stub, not the three-seat conference).
//     Until they land, --live fails closed by design: the check never
//     auto-greens a serious build. This is the correct, safe state.
//
// Context packet (deterministic data gathering, not prose — #146 §2):
//   the diff, the spec (closing) issue body, the latest CI check runs, and
//   the round-1 verdicts fed back into round 2 (confer, not just vote).
//
// Surface: local JSON in / JSON out. The only network is the optional live
// bridge, gated on secrets. No paid services from this script itself.

import { readFileSync } from "node:fs";
import { tallyConference, normaliseVerdict, REQUIRED_SEATS } from "./senior-panel-tally.mjs";
import {
  HAND_BUILT_PLUMBING_BAN,
  detectHandRolledPlumbing,
} from "./hand-rolled-plumbing.mjs";

export { HAND_BUILT_PLUMBING_BAN, detectHandRolledPlumbing };

/**
 * @typedef {import("./senior-panel-tally.mjs").Verdict} Verdict
 * @typedef {import("./senior-panel-tally.mjs").TallyResult} TallyResult
 *
 * @typedef {{
 *   repo: string,
 *   prNumber: number,
 *   prTitle: string,
 *   prBody: string,
 *   diff: string,
 *   changedFiles: string[],
 *   additions: number,
 *   deletions: number,
 *   closingIssueNumber: number | null,
 *   closingIssueBody: string,
 *   ciCheckRuns: { name: string, conclusion: string, url: string }[],
 *   triggers: string[],
 *   headSha: string,
 *   handBuiltPlumbingBan: string,
 *   plumbingFindings: import("./hand-rolled-plumbing.mjs").PlumbingFinding[],
 * }} ContextPacket
 *
 * @typedef {{
 *   result: "APPROVE" | "REJECT" | "PENDING",
 *   verdicts: (Verdict | null)[],
 *   tally: TallyResult,
 *   packet: ContextPacket,
 *   mode: "stub" | "live",
 *   escalated: boolean,
 *   commentBody: string,
 * }} ConferenceResult
 */

export const AUDITOR_SEATS = [
  { seat: "glm-5.2-devin", provider: "devin", model: "glm-5-2" },
  { seat: "glm-5.3-free", provider: "free-lane", model: "glm-5-3" },
  { seat: "ds4-pro-straitly", provider: "straitly", model: "deepseek-v4-pro" },
];

/**
 * Build the deterministic context packet from gathered PR data. Pure: no
 * network. The workflow gathers the pieces (gh api) and passes them in.
 *
 * @param {Partial<ContextPacket> & { repo: string; prNumber: number }} input
 * @returns {ContextPacket}
 */
export function buildContextPacket(input) {
  return {
    repo: input.repo,
    prNumber: input.prNumber,
    prTitle: String(input.prTitle || ""),
    prBody: String(input.prBody || ""),
    diff: String(input.diff || ""),
    changedFiles: Array.isArray(input.changedFiles) ? input.changedFiles : [],
    additions: Number(input.additions) || 0,
    deletions: Number(input.deletions) || 0,
    closingIssueNumber:
      input.closingIssueNumber === null || input.closingIssueNumber === undefined
        ? null
        : Number(input.closingIssueNumber),
    closingIssueBody: String(input.closingIssueBody || ""),
    ciCheckRuns: Array.isArray(input.ciCheckRuns) ? input.ciCheckRuns : [],
    triggers: Array.isArray(input.triggers) ? input.triggers : [],
    headSha: String(input.headSha || ""),
    handBuiltPlumbingBan: HAND_BUILT_PLUMBING_BAN,
    plumbingFindings: Array.isArray(input.plumbingFindings) ? input.plumbingFindings : [],
  };
}

/**
 * Round-2 conferencing: feed each auditor the other two's round-1 verdicts.
 * In stub mode this is a no-op pass-through (the stub verdicts are already
 * final). In live mode the bridge performs the second round server-side;
 * here we just attach the round-1 cross-view to the packet for the bridge.
 *
 * @param {Verdict[]} round1
 * @returns {Record<string, string[]>}
 */
export function crossView(round1) {
  const map = {};
  for (const v of round1) {
    if (!v) continue;
    map[v.seat] = round1
      .filter((o) => o && o.seat !== v.seat)
      .map((o) => `${o.seat}: ${o.verdict} — ${o.reason}`);
  }
  return map;
}

/**
 * Stub verdicts — deterministic, no network. The outcome is chosen by
 * SENIOR_PANEL_STUB_OUTCOME so CI can prove all three paths.
 *
 * @param {ContextPacket} packet
 * @param {string} outcome  "approve" | "reject" | "pending"
 * @returns {(Verdict | null)[]}
 */
export function stubVerdicts(packet, outcome) {
  const base = `stub conference on ${packet.repo}#${packet.prNumber} (triggers: ${packet.triggers.join(",") || "none"})`;
  if (outcome === "pending") {
    // One seat "walled" — fail-closed.
    return [
      { seat: AUDITOR_SEATS[0].seat, verdict: "APPROVE", reason: `${base}; stub approve` },
      null,
      { seat: AUDITOR_SEATS[2].seat, verdict: "REJECT", reason: `${base}; stub reject` },
    ];
  }
  if (outcome === "reject") {
    return [
      { seat: AUDITOR_SEATS[0].seat, verdict: "REJECT", reason: `${base}; stub reject r1` },
      { seat: AUDITOR_SEATS[1].seat, verdict: "REJECT", reason: `${base}; stub reject r2` },
      { seat: AUDITOR_SEATS[2].seat, verdict: "APPROVE", reason: `${base}; stub approve` },
    ];
  }
  // approve (default)
  return [
    { seat: AUDITOR_SEATS[0].seat, verdict: "APPROVE", reason: `${base}; stub approve` },
    { seat: AUDITOR_SEATS[1].seat, verdict: "APPROVE", reason: `${base}; stub approve` },
    { seat: AUDITOR_SEATS[2].seat, verdict: "REJECT", reason: `${base}; stub lone reject (non-blocking)` },
  ];
}

/**
 * Live dispatch: POST the packet to the VPS bridge. Returns the parsed
 * verdicts, or nulls for any seat the bridge could not convene.
 *
 * The bridge contract (for #146's pi-audit@ machinery to implement):
 *   POST $SENIOR_PANEL_BRIDGE_URL
 *   Authorization: Bearer $SENIOR_PANEL_BRIDGE_TOKEN
 *   body: { packet, seats: AUDITOR_SEATS, crossView }
 *   200: { verdicts: [ { seat, verdict, reason } | null, ... ] }
 *   5xx / timeout / non-JSON: all seats null (fail-closed PENDING)
 *
 * @param {ContextPacket} packet
 * @param {Record<string, string[]>} xv
 * @param {{ fetch?: typeof fetch }} [io]
 * @returns {Promise<(Verdict | null)[]>}
 */
export async function liveDispatch(packet, xv, io) {
  const url = process.env.SENIOR_PANEL_BRIDGE_URL;
  const token = process.env.SENIOR_PANEL_BRIDGE_TOKEN;
  const fetchFn = io?.fetch ?? (typeof fetch !== "undefined" ? fetch : null);
  if (!url || !token) {
    return AUDITOR_SEATS.map(() => null);
  }
  if (!fetchFn) {
    // No fetch available (old Node) — fail closed.
    return AUDITOR_SEATS.map(() => null);
  }
  try {
    const res = await fetchFn(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ packet, seats: AUDITOR_SEATS, crossView: xv }),
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) return AUDITOR_SEATS.map(() => null);
    const data = await res.json();
    const verdicts = Array.isArray(data?.verdicts) ? data.verdicts : [];
    return AUDITOR_SEATS.map((_, i) => normaliseVerdict(verdicts[i]) ?? null);
  } catch {
    return AUDITOR_SEATS.map(() => null);
  }
}

/**
 * Render the PR comment body that posts the verdicts. The workflow publishes
 * this via `gh pr comment`. APPROVE and REJECT surface every verdict; PENDING
 * names the missing seats and the escalation.
 *
 * @param {ConferenceResult} r
 * @returns {string}
 */
export function renderComment(r) {
  const header = `### Senior-auditor conference — ${r.result}`;
  const shaMark = r.packet.headSha ? `<!-- senior-panel:${r.packet.headSha} -->` : "";
  const lines = [
    header,
    shaMark,
    "",
    `Mode: \`${r.mode}\` | PR triggers: \`${r.packet.triggers.join("`, `") || "none"}\``,
    "",
  ];
  if (r.packet.plumbingFindings && r.packet.plumbingFindings.length > 0) {
    lines.push(
      "**HARD REJECTION (not a judgment call)** — hand-rolled orchestration in the diff.",
      "",
    );
    for (const f of r.packet.plumbingFindings) {
      lines.push(`- \`${f.id}\` in \`${f.path}\` — replace with ${f.replacement} (${f.evidence})`);
    }
    lines.push("");
  }
  if (r.result === "PENDING") {
    lines.push(
      `The conference could not convene 2-of-3 (${r.tally.missing} seat(s) walled).`,
      `Fail-closed: this check stays **not-green** until the panel reconvenes.`,
      `Escalation filed per #221.`,
      "",
      `Seats heard:`,
    );
    for (const v of r.verdicts) {
      lines.push(v ? `- ${v.seat}: ${v.verdict} — ${v.reason}` : `- _seat unavailable_`);
    }
  } else {
    lines.push(`**${r.result}** — ${r.tally.approves} approve / ${r.tally.rejects} reject. ${r.tally.note}`, "");
    for (const v of r.verdicts) {
      if (!v) continue;
      lines.push(`- ${v.seat}: ${v.verdict} — ${v.reason}`);
    }
    if (r.result === "REJECT") {
      lines.push("", "Reasons to address before re-push:");
      for (const reason of r.tally.reasons) lines.push(`- ${reason}`);
    }
  }
  return lines.join("\n");
}

/**
 * Run the full conference. Pure of global state except env vars (for stub
 * outcome + live bridge). The workflow calls this; tests call it with
 * injected env/io.
 *
 * @param {Partial<ContextPacket> & { repo: string; prNumber: number }} packetInput
 * @param {{ mode?: "stub" | "live"; outcome?: string; env?: Record<string,string>; io?: { fetch?: typeof fetch } }} [opts]
 * @returns {Promise<ConferenceResult>}
 */
export async function runConference(packetInput, opts = {}) {
  const env = opts.env ?? process.env;
  const mode =
    opts.mode ??
    (env.SENIOR_PANEL_BRIDGE_URL && env.SENIOR_PANEL_BRIDGE_TOKEN ? "live" : "stub");
  const outcome = (opts.outcome ?? env.SENIOR_PANEL_STUB_OUTCOME ?? "approve")
    .toLowerCase()
    .trim();

  const packet = buildContextPacket(packetInput);
  packet.plumbingFindings = detectHandRolledPlumbing(packet.diff);

  let verdicts;
  let escalated = false;
  if (packet.plumbingFindings.length > 0) {
    // Mechanical REJECT — Nish 2026-08-26: not a judgment call.
    const why = packet.plumbingFindings
      .map((f) => `${f.id} in ${f.path} — replace with ${f.replacement}`)
      .join("; ");
    verdicts = AUDITOR_SEATS.map((s) => ({
      seat: s.seat,
      verdict: "REJECT",
      reason: `HARD REJECTION (not a judgment call): ${why}`,
    }));
  } else if (mode === "live") {
    const round1 = await liveDispatch(packet, {}, opts.io);
    // Round 2: re-dispatch with the cross-view. The bridge performs the
    // confer; we feed it round-1 so auditors see each other's verdicts.
    const xv = crossView(round1.filter((v) => v !== null));
    verdicts = await liveDispatch(packet, xv, opts.io);
    if (verdicts.filter((v) => v !== null).length < REQUIRED_SEATS) {
      escalated = true;
    }
  } else {
    verdicts = stubVerdicts(packet, outcome);
    if (outcome === "pending") escalated = true;
  }

  const tally = tallyConference(verdicts);
  if (tally.result === "PENDING") escalated = true;

  const result = {
    result: tally.result,
    verdicts,
    tally,
    packet,
    mode,
    escalated,
    commentBody: "",
  };
  result.commentBody = renderComment(result);
  return result;
}

function usage() {
  return [
    "senior-panel-conference.mjs — convene the senior-auditor conference (#223).",
    "",
    "Reads a context-packet JSON on stdin and prints the conference result.",
    "Packet: { repo, prNumber, prTitle, prBody, diff, changedFiles,",
    "  additions, deletions, closingIssueNumber, closingIssueBody,",
    "  ciCheckRuns, triggers, headSha }",
    "",
    "Flags:",
    "  --stub          force stub mode (deterministic, no network)",
    "  --live          force live bridge mode (fail-closed if unconfigured)",
    "  --outcome X     stub outcome: approve | reject | pending",
    "  --help          show this help",
    "",
    "Env (live mode): SENIOR_PANEL_BRIDGE_URL, SENIOR_PANEL_BRIDGE_TOKEN",
    "Env (stub mode): SENIOR_PANEL_STUB_OUTCOME=approve|reject|pending",
  ].join("\n");
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    process.stdout.write(usage() + "\n");
    return 0;
  }
  let mode;
  let outcome;
  for (const a of argv) {
    if (a === "--stub") mode = "stub";
    else if (a === "--live") mode = "live";
    else if (a.startsWith("--outcome=")) outcome = a.slice("--outcome=".length);
  }
  const raw = readFileSync(0, "utf8");
  let data;
  try {
    data = JSON.parse(raw);
  } catch (e) {
    process.stderr.write(`senior-panel-conference: invalid JSON on stdin: ${e}\n`);
    return 2;
  }
  const result = await runConference(data, { mode, outcome });
  process.stdout.write(JSON.stringify(result) + "\n");
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exit(await main(process.argv.slice(2)));
}