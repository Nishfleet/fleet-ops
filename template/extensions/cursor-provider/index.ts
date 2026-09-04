/**
 * Cursor Provider Extension
 *
 * Registers `cursor` as a Pi provider. Routes through the Cursor CLI:
 *   cursor-agent --print --api-key "$CURSOR_API_KEY" --model <model>
 *                --force --trust --workspace <workspace> -- <prompt>
 *
 * Credential: $CURSOR_API_KEY from ~/fleet2/etc/cursor.env
 * Models (NON-NEGOTIABLE LOCK, Nish 2026-08-22):
 *   composer-2.5         — Cursor Composer 2.5
 *   cursor-grok-4.6-high — Cursor Grok 4.6 High
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
import { existsSync, readFileSync } from "node:fs";
import { writeSeatHealthFromCliSpawn, writeSeatHealthFromCliTimeout } from "../seat-health.ts";

// =============================================================================
// Helpers
function extractPrompt(context: Context): string {
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
// Cursor API key — env loading
// =============================================================================

function loadFleetEnv(): void {
	const envFile = "/home/nish/fleet2/etc/cursor.env";
	if (existsSync(envFile)) {
		const content = readFileSync(envFile, "utf-8");
		for (const line of content.split("\n")) {
			const trimmed = line.trim();
			if (!trimmed || trimmed.startsWith("#")) continue;
			const eqIdx = trimmed.indexOf("=");
			if (eqIdx > 0) {
				const key = trimmed.slice(0, eqIdx);
				const val = trimmed.slice(eqIdx + 1);
				if (!process.env[key]) {
					process.env[key] = val;
				}
			}
		}
	}
}

loadFleetEnv();

// =============================================================================
// Streaming Implementation — runs cursor-agent CLI, streams output back
// =============================================================================

// =============================================================================
// NISH TWO-MODEL LOCK (2026-08-22, NON-NEGOTIABLE) — runtime enforcement.
// The model catalog below is only a listing; Pi will happily pass any
// --model string straight through to cursor-agent. The launcher
// implementation-worker-cursor-sub enforces this at runtime, so this
// extension must too, or an unlocked model draws the prepaid Ultra seat.
// =============================================================================

const CURSOR_MODEL_LOCK = ["composer-2.5", "cursor-grok-4.6-high"] as const;

function assertLockedModel(id: string): void {
	if (!(CURSOR_MODEL_LOCK as readonly string[]).includes(id)) {
		throw new Error(
			`Model "${id}" is not permitted on the Cursor seat. Nish two-model lock ` +
			`(2026-08-22, non-negotiable) allows only: ${CURSOR_MODEL_LOCK.join(", ")}.`,
		);
	}
}

function streamCursor(
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
			assertLockedModel(model.id);
			const prompt = extractPrompt(context);
			const cursorBin = "/home/nish/.local/bin/cursor-agent";
			const apiKey = process.env.CURSOR_API_KEY;

			if (!existsSync(cursorBin)) {
				throw new Error(`Cursor binary not found at ${cursorBin}`);
			}

			if (!apiKey) {
				throw new Error(
					"CURSOR_API_KEY is not set. Source ~/fleet2/etc/cursor.env or set it in your environment.",
				);
			}

			// Build the command — same flags as implementation-worker-cursor-sub
			// cursor-agent --print --model <model> --force --trust
			//   --workspace <workspace> -- <prompt>
			const workspace = process.cwd();

			// Push start event
			stream.push({ type: "start", partial: output });

			// Run cursor-agent and capture output
			// Use spawnSync (not execSync) to avoid shell parsing of the prompt
			const child = spawnSync(cursorBin, ["--print", "--api-key", apiKey, "--model", model.id, "--force", "--trust", "--workspace", workspace, "--", prompt], {
				cwd: workspace,
				timeout: 2400000, // 40 min (2026-09-04 fleet-ops#3263: 30 min killed heavy packets at 1801s — same class as the devin-provider fix; pi hang watchdog is 2520s, provider must stay under it)
				maxBuffer: 10 * 1024 * 1024, // 10MB
			});

			if (child.error) {
				// ETIMEDOUT means the cursor-agent CLI itself hung — distinct from
				// quota exhaustion. Record as cli_timeout (short backoff), NOT a
				// long rate-limit window. See seat-health.ts.
				if ((child.error as NodeJS.ErrnoException).code === "ETIMEDOUT") {
					writeSeatHealthFromCliTimeout(model.provider, model.id);
				}
				throw child.error;
			}

			if (child.status !== 0 && child.status !== null) {
				const stderr = child.stderr?.toString() || "";
				const stdout = child.stdout?.toString() || "";
				writeSeatHealthFromCliSpawn(
					model.provider,
					model.id,
					`${stderr}\n${stdout}`,
					child.status,
				);
				throw new Error(`Cursor exited with code ${child.status}: ${stderr.slice(0, 1000)}`);
			}

			const stdout = child.stdout?.toString() || "";
			writeSeatHealthFromCliSpawn(model.provider, model.id, stdout, 0);

			// Push text content
			output.content.push({ type: "text", text: "" });
			stream.push({ type: "text_start", contentIndex: 0, partial: output });

			const textBlock = output.content[0] as { type: "text"; text: string };
			textBlock.text = stdout;
			stream.push({ type: "text_delta", contentIndex: 0, delta: stdout, partial: output });

			stream.push({ type: "text_end", contentIndex: 0, content: stdout, partial: output });

			// Calculate cost (mark as free/zero since Cursor Ultra covers it)
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
	pi.registerProvider("cursor", {
		name: "Cursor",
		baseUrl: "https://api2.cursor.sh",
		apiKey: "$CURSOR_API_KEY",
		api: "cursor-cli",
		models: [
			{
				id: "composer-2.5",
				name: "Composer 2.5",
				reasoning: true,
				input: ["text", "image"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 128000,
				maxTokens: 64000,
			},
			{
				id: "cursor-grok-4.6-high",
				name: "Cursor Grok 4.6 High",
				reasoning: true,
				input: ["text", "image"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 500000,
				maxTokens: 500000,
			},
		],
		// Delegate all streaming to the custom impl — not a standard API
		streamSimple: streamCursor,
	});
}