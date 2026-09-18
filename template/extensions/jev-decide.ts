/**
 * jev-decide — Jev (typesafe-ai/jev) as a Pi tool, via the fleet's jev-eval helper.
 *
 * "Jev decides" (Nish 2026-09-17): every typed decision (yes/no, choice, score)
 * goes through Jev before acting. Jev is an EVALUATION model on the Vercel AI
 * Gateway — chat/completions returns 400 ModelTypeMismatch — so it can never be
 * a pi provider/seat. This tool is the in-session rail: it shells out to
 * `jev-eval` (fleet-ops bin/jev-eval.mjs, $1 cap, JSONL log, Jev-only credential
 * read from ~/.config/fleet-ops/seats/typesafe-jev.env by the helper itself).
 * The credential never enters this extension or the model context.
 *
 * Question shapes (jev-eval contract):
 *   boolean {type:"boolean", instructions}                  -> {probability}
 *   choice  {type:"choice",  criteria:{key:desc}, instructions} -> {choice, probabilities}
 *   score   {type:"score",   instructions}                  -> {score}
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { Type } from "typebox";

const JEV_EVAL = process.env.JEV_EVAL_BIN ?? join(homedir(), ".local", "bin", "jev-eval");

export default function (pi: ExtensionAPI) {
	console.log("EXTLOAD-OK extension=jev-decide mode=print-safe");
	pi.registerTool({
		name: "jev_decide",
		label: "Jev decide",
		description:
			"Ask Jev (typesafe-ai/jev) for probabilities on typed decisions before acting: boolean, choice or score questions over a state summary. Act on the probability, cite the ref. Never for prose or code.",
		parameters: Type.Object({
			state: Type.String({ description: "Plain-text state summary the questions are judged against (facts, numbers, dates)" }),
			questions: Type.Record(
				Type.String(),
				Type.Object({
					type: Type.Union([Type.Literal("boolean"), Type.Literal("choice"), Type.Literal("score")]),
					instructions: Type.String({ description: "The question, phrased for a yes/no, a pick, or a 0-1 score" }),
					criteria: Type.Optional(Type.Record(Type.String(), Type.String(), { description: "choice only: key -> description" })),
				}),
				{ description: "Question map keyed by a short id" },
			),
			site: Type.String({ description: "Decision site name, e.g. fleet-seats, intake-triage (goes to the JSONL log)" }),
			ref: Type.String({ description: "Real record this decision is about: issue/PR number, path, timestamp" }),
		}),
		async execute(_toolCallId, params) {
			if (!existsSync(JEV_EVAL)) {
				return { content: [{ type: "text", text: `jev-eval helper not installed at ${JEV_EVAL}` }], details: { error: "missing_helper" }, isError: true };
			}
			const input = JSON.stringify({ state: params.state, questions: params.questions });
			const proc = spawnSync(JEV_EVAL, ["--site", params.site, "--ref", params.ref], {
				input,
				encoding: "utf-8",
				timeout: 60_000,
				env: process.env,
			});
			const out = (proc.stdout ?? "").trim();
			const err = (proc.stderr ?? "").trim();
			if (proc.status !== 0 || !out) {
				// exit 3 = spend cap reached (jev-eval contract) — surface it loudly, never silently.
				return {
					content: [{ type: "text", text: `jev-eval exit ${proc.status ?? "signal"}: ${err || "no output"}` }],
					details: { exit: proc.status, stderr: err },
					isError: true,
				};
			}
			let parsed: unknown = out;
			try {
				parsed = JSON.parse(out);
			} catch {
				/* return raw text */
			}
			return { content: [{ type: "text", text: typeof parsed === "string" ? parsed : JSON.stringify(parsed, null, 2) }], details: { result: parsed } };
		},
	});
}
