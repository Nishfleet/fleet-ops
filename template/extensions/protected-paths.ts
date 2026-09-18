/**
 * FLEET FORK of examples/extensions/protected-paths.ts (upstream pi 0.85.1).
 *
 * WHY A FORK: the path list is a literal in the stock file and pi's
 * settings.json has no per-extension config key (docs/settings.md:286), so
 * the fleet credential paths can only be added here. The hook body is
 * upstream's, unchanged.
 *
 * LIMIT, said plainly: stock guards the `write` and `edit` tools only. A
 * credential written through `bash` (`cat > .../seats/x.env`) is NOT caught
 * here — the bash path is permission-gate.ts. The deleted spawn-guard-core.ts
 * covered both; this covers the tool path, and the real control on the bash
 * path is that fleet seats run non-interactive, where permission-gate blocks
 * by default.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	const protectedPaths = [
		".env",
		".git/",
		"node_modules/",
		"/.config/fleet-ops/seats",
		"/etc/restic",
		"/.pi/agent/auth.json",
		".pem",
	];

	process.stderr.write("EXTLOAD-OK extension=protected-paths tools=write,edit\n");

	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "write" && event.toolName !== "edit") {
			return undefined;
		}

		const path = event.input.path as string;
		const isProtected = protectedPaths.some((p) => path.includes(p));

		if (isProtected) {
			if (ctx.hasUI) {
				ctx.ui.notify(`Blocked write to protected path: ${path}`, "warning");
			}
			return { block: true, reason: `Path "${path}" is protected` };
		}

		return undefined;
	});
}
