/**
 * FLEET FORK of examples/extensions/permission-gate.ts (upstream pi 0.85.1).
 *
 * WHY A FORK: pi's settings.json exposes only `extensions` and `packages`
 * (docs/settings.md:286) — there is no per-extension config key, so the
 * pattern list can only be changed in the file. Three fleet rules are added
 * to the stock three; nothing else differs from upstream.
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
 * NOT GUARDED, said plainly: the devin and cursor provider shims run the
 * vendor CLI with its own tools, so Pi never sees a bash call and no rule
 * here fires for those seats. That was true of spawn-guard-core too.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	const dangerousPatterns = [
		/\brm\s+(-rf?|--recursive)/i,
		/\bsudo\b/i,
		/\b(chmod|chown)\b.*777/i,
		/\bgit\s+stash\b(?!\s+(?:list|show)\b)/i,
		/\bsystemctl\b[^\n;|&]*\brestart\b/i,
		/\bwrangler\b[^\n;|&]*\bdeploy\b/i,
	];

	process.stderr.write("EXTLOAD-OK extension=permission-gate guard=tool_call rules=6\n");

	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return undefined;

		const command = event.input.command as string;
		if (!dangerousPatterns.some((p) => p.test(command))) return undefined;

		if (!ctx.hasUI) {
			return { block: true, reason: "Dangerous command blocked (no UI for confirmation)" };
		}

		const choice = await ctx.ui.select(`⚠️ Dangerous command:\n\n  ${command}\n\nAllow?`, ["Yes", "No"]);
		if (choice !== "Yes") return { block: true, reason: "Blocked by user" };

		return undefined;
	});
}
