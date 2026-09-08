/**
 * Cursor Cloud Agents Provider Extension
 *
 * Registers `cursor-cloud` as a Pi provider. This is a REMOTE-AGENT seat:
 * it does not run a local CLI. Instead it POSTs the packet to Cursor's
 * Cloud Agents API (`https://api.cursor.com/v1/agents`), which spins up a
 * cloud agent against a connected GitHub repo+branch, and polls until the
 * run finishes. The finished run carries `git.branches[].prUrl` — the PR the
 * agent opened on Nish's behalf — which we print to stdout so the fleet's
 * remote-agent empty-run detector (`has_session_pr_url` in pi-issue-run)
 * judges the session a success by PR URL, not local tool count.
 *
 * Credential: the same User API key as the IDE seat — `$CURSOR_API_KEY` from
 * ~/fleet2/etc/cursor.env. The ENDPOINT is what differs (api.cursor.com for
 * Cloud Agents vs api2.cursor.sh for the IDE). Do NOT create a separate
 * cursor-api.env (orchestrator, 2026-09-08).
 *
 * Model: `grok-4.6` only, non-fast. Nish's "never ever use the fast models"
 * rule (memory cursor-pools-and-no-fast-models) bans every `-fast` variant;
 * the Cloud Agents model catalog has no `-fast` slug, and the grok-4.6
 * model's `fast` parameter must stay `false` (default).
 *
 * Repo: the Cloud Agents API can only launch against repos already connected
 * to Cursor's GitHub app (`GET /v1/repositories`). Among Nishfleet repos the
 * only currently-accessible cloud-repo is `Nishfleet/0509`; it is used as
 * the launch target. If a repo is not in that list the API returns a
 * `validation_error` and we fail the session.
 *
 * Spend: the docs price (Grok 4.6 $2/$0.5/$6 per M token) lives in
 * config/pi-models.json so `calculateCost` and the fleet seat-spend export
 * are correct; per-run real spend is read from `GET /v1/agents/{id}/usage`
 * (`runs[].cost.chargedCents`) and reported on the assistant message so the
 * `prepaid-usage` meter sees real dollars, not a guess.
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
import { existsSync, readFileSync } from "node:fs";
import { writeSeatHealthFromHttp } from "../seat-health.ts";

const BASE_URL = "https://api.cursor.com/v1";
// The only Cloud Agents repo currently accessible to Cursor (GET /v1/repositories).
// Launching against anything else returns `validation_error: failed to verify
// branch existence` because the repo is simply not connected to Cursor's GH app.
const REPO_URL = "https://github.com/Nishfleet/0509";
const STARTING_REF = "main";
const MODEL_ID = "grok-4.6"; // non-fast; Nish bans -fast (memory, 2026-09-07)
const POLL_INTERVAL_MS = 5000;
const MAX_POLLS = 600; // 50 min ceiling, under the pi hang watchdog (2520 s)

// =============================================================================
// Env loading — $CURSOR_API_KEY from ~/fleet2/etc/cursor.env (same key as IDE)
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
// Prompt extraction + HTTP helpers
// =============================================================================

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

function authBearer(apiKey: string): string {
	return `Basic ${Buffer.from(`${apiKey}:`).toString("base64")}`;
}

async function apiGet(apiKey: string, url: string): Promise<{ status: number; json: any }> {
	const resp = await fetch(url, {
		headers: { Authorization: authBearer(apiKey) },
	});
	let json: any = {};
	try {
		json = await resp.json();
	} catch {
		/* non-JSON body */
	}
	return { status: resp.status, json };
}

async function apiPost(
	apiKey: string,
	url: string,
	body: unknown,
): Promise<{ status: number; json: any }> {
	const resp = await fetch(url, {
		method: "POST",
		headers: {
			Authorization: authBearer(apiKey),
			"Content-Type": "application/json",
		},
		body: JSON.stringify(body),
	});
	let json: any = {};
	try {
		json = await resp.json();
	} catch {
		/* non-JSON body */
	}
	return { status: resp.status, json };
}

// =============================================================================
// Streaming Implementation — launch a cloud agent, poll, return result + PR
// =============================================================================

function streamCursorCloud(
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
			const apiKey = process.env.CURSOR_API_KEY ?? "";

			if (!apiKey) {
				throw new Error(
					"CURSOR_API_KEY is not set. Source ~/fleet2/etc/cursor.env (same key as the IDE seat).",
				);
			}

			stream.push({ type: "start", partial: output });

			// 1. Launch the cloud agent against the connected repo.
			const launch = await apiPost(apiKey, `${BASE_URL}/agents`, {
				prompt: { text: prompt },
				model: { id: MODEL_ID },
				repos: [{ url: REPO_URL, startingRef: STARTING_REF }],
				autoCreatePR: true,
				mode: "agent",
			});

			if (launch.status !== 201 && launch.status !== 200) {
				writeSeatHealthFromHttp(model.provider, model.id, launch.status, {});
				const msg =
					launch.json?.error?.message ||
					launch.json?.message ||
					`HTTP ${launch.status}`;
				throw new Error(`Cursor Cloud launch failed (${launch.status}): ${msg}`);
			}

			const agentId: string | undefined =
				launch.json?.agent?.id ?? launch.json?.id;
			const runId: string | undefined =
				launch.json?.run?.id ?? launch.json?.latestRunId;
			if (!agentId || !runId) {
				throw new Error(
					`Cursor Cloud launch returned no agent/run id: ${JSON.stringify(launch.json).slice(0, 500)}`,
				);
			}

			// 2. Poll the run to completion.
			let run: any = launch.json?.run ?? {};
			let statusStr: string = run?.status ?? "RUNNING";
			let attempts = 0;
			while (statusStr !== "FINISHED" && attempts < MAX_POLLS) {
				attempts++;
				if (options?.signal?.aborted) {
					output.stopReason = "aborted";
					stream.push({ type: "error", reason: "aborted", error: output });
					stream.end();
					return;
				}
				await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
				const poll = await apiGet(
					apiKey,
					`${BASE_URL}/agents/${agentId}/runs/${runId}`,
				);
				if (poll.status !== 200) {
					writeSeatHealthFromHttp(model.provider, model.id, poll.status, {});
					throw new Error(
						`Cursor Cloud poll failed (${poll.status}): ${poll.json?.error?.message ?? ""}`,
					);
				}
				run = poll.json;
				statusStr = run?.status ?? "RUNNING";

				if (statusStr === "ERROR" || statusStr === "CANCELLED" || statusStr === "EXPIRED") {
					// Task failure, not a seat fault: the launch+run worked, so the seat
					// itself is healthy. Recording a 200 keeps it available for the next
					// packet — a bad packet must not bench a working seat.
					writeSeatHealthFromHttp(model.provider, model.id, 200, {});
					throw new Error(
						`Cursor Cloud run ${statusStr}: ${run?.error?.message ?? run?.result ?? ""}`,
					);
				}
			}

			if (statusStr !== "FINISHED") {
				throw new Error(`Cursor Cloud run timed out after ${MAX_POLLS} polls`);
			}

			// 3. The run finished. Read its result and any PR the agent opened.
			const result: string = run?.result ?? "";
			const prUrl: string =
				run?.git?.branches?.[0]?.prUrl ??
				run?.git?.branches?.[0]?.pullRequestUrl ??
				"";

			// 4. Read per-run real spend from the usage endpoint.
			let chargedCents = 0;
			let totalTokens = 0;
			let inputTokens = 0;
			let outputTokens = 0;
			const usage = await apiGet(apiKey, `${BASE_URL}/agents/${agentId}/usage`);
			if (usage.status === 200 && usage.json) {
				const thisRun = (usage.json.runs ?? []).find((r: any) => r.id === runId);
				chargedCents = Number(thisRun?.cost?.chargedCents ?? 0) || 0;
				inputTokens = Number(thisRun?.usage?.inputTokens ?? 0) || 0;
				outputTokens = Number(thisRun?.usage?.outputTokens ?? 0) || 0;
				totalTokens =
					Number(thisRun?.usage?.totalTokens ?? 0) ||
					inputTokens + outputTokens;
			}

			// 5. Emit the finished message. Attach the PR URL to stdout so the
			//    fleet remote-agent empty-run detector sees a real success, and
			//    report the real charged spend for the prepaid-usage meter.
			output.content.push({ type: "text", text: "" });
			stream.push({ type: "text_start", contentIndex: 0, partial: output });

			const lines: string[] = [];
			if (prUrl) lines.push(prUrl);
			if (result) {
				// Cap the echoed result so a huge final reply doesn't blow the
				// 10 MB maxBuffer / stdout capture.
				lines.push(result.slice(0, 4000));
			}
			const stdout = lines.join("\n\n");

			const textBlock = output.content[0] as { type: "text"; text: string };
			textBlock.text = stdout;
			stream.push({ type: "text_delta", contentIndex: 0, delta: stdout, partial: output });

			// Real per-run dollar cost straight from Cursor's usage ledger.
			output.usage = {
				input: inputTokens,
				output: outputTokens,
				cacheRead: 0,
				cacheWrite: 0,
				totalTokens: totalTokens || inputTokens + outputTokens,
				cost: {
					input: 0,
					output: 0,
					cacheRead: 0,
					cacheWrite: 0,
					total: chargedCents / 100,
				},
			};
			output.stopReason = "stop";
			calculateCost(model, output.usage);
			stream.push({ type: "text_end", contentIndex: 0, content: stdout, partial: output });
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
	pi.registerProvider("cursor-cloud", {
		name: "Cursor Cloud",
		baseUrl: BASE_URL,
		apiKey: "$CURSOR_API_KEY",
		api: "cursor-cloud",
		models: [
			{
				id: MODEL_ID,
				name: "Cursor Grok 4.6 (Cloud Agent)",
				reasoning: true,
				input: ["text", "image"],
				cost: { input: 2, output: 6, cacheRead: 0.5, cacheWrite: 0 },
				contextWindow: 500000,
				maxTokens: 131072,
			},
		],
		// Delegate all streaming to the custom remote-agent impl.
		streamSimple: streamCursorCloud,
	});
}
