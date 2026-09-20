/**
 * FLEET FORK of examples/extensions/permission-gate.ts (upstream pi 0.85.1).
 *
 * WHY A FORK: pi's settings.json exposes only `extensions` and `packages`
 * (docs/settings.md:286) — there is no per-extension config key, so the
 * pattern list can only be changed in the file. Three fleet rules plus the
 * worker-scoped toolchain ban are added to the stock three; nothing else
 * differs from upstream.
 *
 * WHY HERE AND NOT confirm-destructive.ts: that stock extension hooks
 * `session_before_switch`/`session_before_fork` only — session lifecycle, not
 * commands — and returns early when `!ctx.hasUI`. It can never gate a bash
 * call. This one can: stock already blocks by default with no UI, which is
 * every `pi --print` fleet seat.
 *
 * Replaces the fleet's 620-line spawn-guard-core.ts + its bash-spawn-hook
 * fork (deleted 2026-09-18). The process ceiling those carried is now
 * systemd's: fleet-work.slice TasksMax=8000 via the linked drop-in
 * systemd/fleet-work.slice.d/10-tasksmax.conf.
 *
 * 2026-09-21 (fleet-ops#4891): the `worker_toolchain_ban` rule is re-homed
 * here. The sweep commit dropped it as collateral with spawn-guard-core.ts
 * (its message never mentions it), but the AGENTS.md memory-budget rule it
 * enforces is still live — without this block a worker can still start a
 * 1-3 GB `tsc -b` / coverage run and be OOM-killed AFTER the damage. Worker
 * scope = the session cgroup is a fleet `<lane>-issue@` unit
 * (pi-issue@/devin-issue@/cursor-issue@); FLEET_WORKER_CONTEXT=1|0 overrides
 * for tests.
 *
 * NOT GUARDED, said plainly: the devin and cursor provider shims run the
 * vendor CLI with its own tools, so Pi never sees a bash call and no rule
 * here fires for those seats. That was true of spawn-guard-core too.
 */

import { readFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * fleet-ops#5902: the worker memory-budget rule (AGENTS.md, fleet-ops#4891)
 * — never `tsc -b`, `vitest --coverage`, `npm run typecheck` / `test:coverage`
 * inside a worker — was prose only until #5910. On 2026-09-12 pi-issue@0509-3014
 * ran `NODE_OPTIONS=--max-old-space-size=3072 npx tsc -b` (node RSS 1.77 GB)
 * and #4838 had already shown the box's RAM goes to these toolchains, not to
 * seat count. Ported verbatim from spawn-guard-core.ts.
 */
export const WORKER_TOOLCHAIN_RULE =
	/\b(?:(?:npx\s+)?tsc\s+(?:-b|--build)\b|vitest\b[^\n;|&]*--coverage\b|npm\s+(?:run\s+)?(?:typecheck|test:coverage)\b|npm\s+test\b[^\n;|&]*--coverage\b)/i;

export function isWorkerSession(env: NodeJS.ProcessEnv): boolean {
	if (env.FLEET_WORKER_CONTEXT === "1") return true;
	if (env.FLEET_WORKER_CONTEXT === "0") return false;
	try {
		return readFileSync("/proc/self/cgroup", "utf8").includes("-issue@");
	} catch {
		return false;
	}
}

/**
 * fleet-ops#5700 precision rule: the toolchain regex must be tested against
 * executable-position text only. A read-only command that merely MENTIONS a
 * banned invocation inside a quoted string or a heredoc body (`grep -rn
 * 'tsc -b'`, a PR body) is prose, not execution — the raw-text match produced
 * blocks on exactly the workers maintaining the rule. This returns the
 * command with heredoc bodies dropped and quoted spans replaced by NUL
 * separators. Ported verbatim from spawn-guard-core.ts.
 */
export function stripQuotedShellText(command: string): string {
	// 1. Drop heredoc bodies (everything up to the terminator line).
	const lines = command.split("\n");
	const kept: string[] = [];
	let terminator: string | null = null;
	for (const line of lines) {
		if (terminator !== null) {
			if (line.trim() === terminator) {
				terminator = null;
				kept.push("");
			}
			continue;
		}
		kept.push(line);
		const m = line.match(/<<(-?)\s*(['"`]?)([A-Za-z_][A-Za-z0-9_-]*)\2/);
		if (m) terminator = m[3];
	}
	const noHeredocs = kept.join("\n");
	// 2. Blank out quoted spans with NUL separators: the tokens inside a
	// quote can neither match nor splice together around the quote bounds.
	let out = "";
	let quote: string | null = null;
	for (const ch of noHeredocs) {
		if (quote === null) {
			if (ch === "'" || ch === '"') {
				quote = ch;
				out += "\x00";
			} else {
				out += ch;
			}
		} else if (ch === quote) {
			quote = null;
			out += "\x00";
		}
	}
	return out;
}

export function workerToolchainBlock(ctx: {
	command: string;
	env: NodeJS.ProcessEnv;
}): string | null {
	if (!isWorkerSession(ctx.env)) return null;
	const m = WORKER_TOOLCHAIN_RULE.exec(stripQuotedShellText(ctx.command));
	return m ? `worker_toolchain_ban cmd=${m[0].trim()}` : null;
}

const WORKER_TOOLCHAIN_GUIDANCE =
	"CI owns coverage and typecheck (AGENTS.md memory-budget rule, fleet-ops#4891/#5902). " +
	"Never run `tsc -b`, `vitest --coverage`, `npm run typecheck` or `npm run test:coverage` " +
	"inside a worker: each costs 1-3 GB and starves the whole fleet. Run the targeted, " +
	"coverage-free test for the files you touched and let the PR checks do the rest.";

export default function (pi: ExtensionAPI) {
	const dangerousPatterns = [
		/\brm\s+(-rf?|--recursive)/i,
		/\bsudo\b/i,
		/\b(chmod|chown)\b.*777/i,
		/\bgit\s+stash\b(?!\s+(?:list|show)\b)/i,
		/\bsystemctl\b[^\n;|&]*\brestart\b/i,
		/\bwrangler\b[^\n;|&]*\bdeploy\b/i,
	];

	process.stderr.write(
		"EXTLOAD-OK extension=permission-gate guard=tool_call rules=6 worker_toolchain_ban=armed\n",
	);

	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return undefined;

		const command = event.input.command as string;

		// Worker-scoped and unconditional: a worker never gets a UI prompt, and
		// the toolchain run must be stopped before it starts, not OOM-killed at
		// 1-3 GB. Guidance text tells the model what to run instead.
		const toolchainBlock = workerToolchainBlock({
			command,
			env: process.env,
		});
		if (toolchainBlock) {
			process.stderr.write(`SPAWN_BLOCKED reason=${toolchainBlock}\n`);
			return {
				block: true,
				reason: `SPAWN_BLOCKED reason=${toolchainBlock}. ${WORKER_TOOLCHAIN_GUIDANCE}`,
			};
		}

		if (!dangerousPatterns.some((p) => p.test(command))) return undefined;

		if (!ctx.hasUI) {
			return { block: true, reason: "Dangerous command blocked (no UI for confirmation)" };
		}

		const choice = await ctx.ui.select(`⚠️ Dangerous command:\n\n  ${command}\n\nAllow?`, ["Yes", "No"]);
		if (choice !== "Yes") return { block: true, reason: "Blocked by user" };

		return undefined;
	});
}
