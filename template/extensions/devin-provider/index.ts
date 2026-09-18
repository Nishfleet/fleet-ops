/**
 * Devin Provider Extension
 *
 * Registers `devin` as a Pi provider. Routes through the Devin CLI:
 *   devin -p "<prompt>" --model <model> --respect-workspace-trust false
 *         --permission-mode smart --sandbox
 *
 * Credential: $DEVIN_API_KEY from ~/.config/fleet-ops/seats/devin.env
 * Models: the SWE-2 lane (config/seat-caps.json). A Devin message rate limit is waited out
 * and resumed in-session (rate-limit.ts), never a worker death.
 */

import {
	type Api,
	type AssistantMessage,
	type AssistantMessageEventStream,
	type Context,
	type Model,
	type SimpleStreamOptions,
	calculateCost,
	createAssistantMessageEventStream,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isDevinRateLimit, parseDevinResetSeconds, planDevinRetry } from "./rate-limit.ts";
import { loadSeatEnv, modelsFromModelsJson } from "./seat-env";

// =============================================================================
// Helpers — extract the user prompt from Pi's message context
// =============================================================================

function extractPrompt(context: Context): string {
	// Use the system prompt plus the last user message as the packet
	const parts: string[] = [];

	if (context.systemPrompt) {
		parts.push(context.systemPrompt);
	}

	for (const msg of context.messages) {
		if (msg.role === "user") {
			if (typeof msg.content === "string") {
				parts.push(msg.content);
			} else {
				for (const block of msg.content) {
					if (block.type === "text") {
						parts.push(block.text);
					}
				}
			}
		}
	}

	return parts.join("\n\n");
}

// =============================================================================
// Load env vars from the seats root (~/.config/fleet-ops/seats) so $DEVIN_API_KEY resolves
// =============================================================================

function loadFleetEnv(): void {
	loadSeatEnv("devin");
}

loadFleetEnv();

// =============================================================================
// Rate-limit resume: a minutes-scale Devin message limit is a pause, not a
// death. Bounds come from pi-issue-run's watchdog, exported as
// PI_HANG_TIMEOUT_S; every knob is env-overridable for tests.
// =============================================================================

function envInt(name: string, fallback: number): number {
	const raw = process.env[name];
	const n = raw === undefined || raw === "" ? NaN : Number(raw);
	return Number.isFinite(n) && n >= 0 ? n : fallback;
}

// spawnSync timeout: 2400000 ms = 40 min per attempt (2026-09-04: 30 min killed every
// heavy packet at 1801s; must stay >= 0.9 x PI_HANG_TIMEOUT_S — tests/provider-timeout.test.sh
// greps this literal). A resumed attempt gets the smaller of this and the remaining watchdog budget.
const ATTEMPT_TIMEOUT_MS_DEFAULT = 2400000;
const RATE_LIMIT_MAX_ATTEMPTS = envInt("PI_DEVIN_RATE_LIMIT_MAX_ATTEMPTS", 3);
const RATE_LIMIT_MIN_WAIT_S = envInt("PI_DEVIN_RATE_LIMIT_MIN_WAIT_S", 30);
const RATE_LIMIT_MAX_WAIT_S = envInt("PI_DEVIN_RATE_LIMIT_MAX_WAIT_S", 1200);
const RATE_LIMIT_MIN_RUN_S = envInt("PI_DEVIN_RATE_LIMIT_MIN_RUN_S", 600);
const WATCHDOG_S = envInt("PI_HANG_TIMEOUT_S", 2520);

const RESUME_NOTE =
	"RESUME NOTE: a previous attempt on this exact packet was interrupted by a Devin message rate limit " +
	"after doing some work. The working tree may already contain partial edits or commits: run `git status` " +
	"and `git log --oneline -5` first, keep what is correct, and continue from there. Do not redo finished steps.\n\n";

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
	return new Promise((resolve, reject) => {
		const t = setTimeout(resolve, ms);
		signal?.addEventListener(
			"abort",
			() => {
				clearTimeout(t);
				reject(new Error("aborted during rate-limit wait"));
			},
			{ once: true },
		);
	});
}

// =============================================================================
// Streaming Implementation — runs devin CLI, streams output back
// =============================================================================

function streamDevin(
	model: Model<Api>,
	context: Context,
	options?: SimpleStreamOptions,
): AssistantMessageEventStream {
	const stream = createAssistantMessageEventStream();

	(async () => {
		const output: AssistantMessage = {
			role: "assistant",
			content: [],
			api: model.api,
			provider: model.provider,
			model: model.id,
			usage: {
				input: 0,
				output: 0,
				cacheRead: 0,
				cacheWrite: 0,
				totalTokens: 0,
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
			},
			stopReason: "pending",
			timestamp: Date.now(),
		};

		try {
			const prompt = extractPrompt(context);
			const devinBin = "/home/nish/.local/bin/devin";

			if (!existsSync(devinBin)) {
				throw new Error(`Devin binary not found at ${devinBin}`);
			}

			// Ensure the Devin API key is in the environment
			const env = {
				...process.env,
				DEVIN_API_KEY: process.env.DEVIN_API_KEY ?? "",
			};
			if (!env.DEVIN_API_KEY) {
				throw new Error(
					"DEVIN_API_KEY is not set. Source ~/.config/fleet-ops/seats/devin.env or set it in your environment.",
				);
			}

			// Push start event
			stream.push({ type: "start", partial: output });

			// Write the prompt to a temp file.  Passing the full packet as a
			// single argv string to `devin -p` can exceed MAX_ARG_STRLEN and
			// cause spawnSync to fail with E2BIG (Argument list too long).
			const tmpDir = mkdtempSync(join(tmpdir(), "pi-devin-"));
			const promptFile = join(tmpDir, "prompt.md");
			const args = [
				"--print",
				"--prompt-file", promptFile,
				"--model", model.id,
				"--respect-workspace-trust", "false",
				// 2026-09-09 (Fable): `--sandbox` forces Devin's "autonomous" permission mode, which since
				// 2026-09-08 rejects every file write non-interactively ("rejected a tool call that requires
				// confirmation"), so 100% of runs ended empty at the first edit. Probe: no sandbox +
				// dangerous writes and runs (DONE-D); sandbox with any mode does not. Other seats run
				// unsandboxed on this VPS already (standing write autonomy, Nish 2026-08-05).
				"--permission-mode", "dangerous",
			];

			let child;
			let attemptTimeoutMs = ATTEMPT_TIMEOUT_MS_DEFAULT;
			try {
				for (let attempt = 1; ; attempt++) {
					writeFileSync(promptFile, attempt === 1 ? prompt : RESUME_NOTE + prompt, "utf-8");

					// Run devin synchronously and capture output
					child = spawnSync(devinBin, args, {
						env,
						cwd: process.cwd(),
						timeout: attemptTimeoutMs,
						maxBuffer: 10 * 1024 * 1024, // 10MB
					});

					if (child.error) {
						// ETIMEDOUT means the devin CLI itself hung — today this correlated
						// with 6-8 concurrent pi workers, not with the seat being out of
						// quota. Record it as a DISTINCT mode so the ledger does not treat
						// it as rate-limit/quota exhaustion (long window) — short backoff.
						if ((child.error as NodeJS.ErrnoException).code === "ETIMEDOUT") {
							// seat-health.ts deleted 2026-09-18 (glue sweep): LiteLLM/Prometheus own seat state.
							// writeSeatHealthFromCliTimeout(model.provider, model.id);
						}
						throw child.error;
					}

					if (child.status === 0 || child.status === null) break;

					const stderr = child.stderr?.toString() || "";
					const stdoutSoFar = child.stdout?.toString() || "";
					const failureText = `${stderr}\n${stdoutSoFar}`;
					// The ledger still learns about the wall (other workers skip the seat
					// for its reset); a successful resume rewrites the record healthy.
					// seat-health.ts deleted 2026-09-18 (glue sweep): LiteLLM/Prometheus own seat state.
					// writeSeatHealthFromCliSpawn(model.provider, model.id, failureText, child.status);

					if (isDevinRateLimit(failureText)) {
						const resetS = parseDevinResetSeconds(failureText);
						const plan = planDevinRetry({
							attempt,
							maxAttempts: RATE_LIMIT_MAX_ATTEMPTS,
							elapsedS: process.uptime(),
							watchdogS: WATCHDOG_S,
							resetS,
							minWaitS: RATE_LIMIT_MIN_WAIT_S,
							maxWaitS: RATE_LIMIT_MAX_WAIT_S,
							minRunS: RATE_LIMIT_MIN_RUN_S,
							attemptTimeoutMsDefault: ATTEMPT_TIMEOUT_MS_DEFAULT,
						});
						if (plan.retry) {
							console.error(
								`devin-provider: rate limit on ${model.id} (attempt ${attempt}/${RATE_LIMIT_MAX_ATTEMPTS}) — ` +
									`waiting ${plan.waitS}s then resuming in-session (${plan.reason})`,
							);
							await sleep(plan.waitS * 1000, options?.signal);
							attemptTimeoutMs = plan.attemptTimeoutMs;
							continue;
						}
						console.error(`devin-provider: rate limit on ${model.id} — not resuming: ${plan.reason}`);
					}
					throw new Error(`Devin exited with code ${child.status}: ${stderr.slice(0, 1000)}`);
				}
			} finally {
				rmSync(tmpDir, { recursive: true, force: true });
			}

			const stdout = child.stdout?.toString() || "";
			// seat-health.ts deleted 2026-09-18 (glue sweep): LiteLLM/Prometheus own seat state.
			// writeSeatHealthFromCliSpawn(model.provider, model.id, stdout, 0);

			// Push text content
			output.content.push({ type: "text", text: "" });
			stream.push({ type: "text_start", contentIndex: 0, partial: output });

			const textBlock = output.content[0] as { type: "text"; text: string };
			textBlock.text = stdout;
			stream.push({ type: "text_delta", contentIndex: 0, delta: stdout, partial: output });

			stream.push({ type: "text_end", contentIndex: 0, content: stdout, partial: output });

			// Calculate cost (mark as free/zero since Devin Pro covers it)
			output.stopReason = "stop";
			calculateCost(model, output.usage);

			stream.push({ type: "done", reason: "stop", message: output });
			stream.end();
		} catch (error) {
			output.stopReason = options?.signal?.aborted ? "aborted" : "error";
			output.errorMessage = error instanceof Error ? error.message : JSON.stringify(error);
			stream.push({ type: "error", reason: output.stopReason, error: output });
			stream.end();
		}
	})();

	return stream;
}

// =============================================================================
// Extension Entry Point
// =============================================================================

export default function (pi: ExtensionAPI) {
	pi.registerProvider("devin", {
		name: "Devin",
		baseUrl: "https://api.devin.ai",
		apiKey: "$DEVIN_API_KEY",
		api: "devin-cli",
		models: modelsFromModelsJson("devin", { reasoning: true, input: ["text", "image"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }),
		// Delegate all streaming to the custom impl — not a standard API
		streamSimple: streamDevin,
	});
}