/**
 * Fleet spawn guard — Pi migration step 3 (2026-08-23),
 * moved from a bash-tool override to `tool_call` on 2026-08-25.
 *
 * THE FINDING THAT MATTERS (2026-08-25, while verifying P10-B item 4)
 * ------------------------------------------------------------------
 * NOTHING IN THIS FILE PROTECTS A `devin` OR `cursor` SESSION. Those two
 * providers are CLI shims: `devin-provider/index.ts` (api `devin-cli`) and
 * `cursor-provider` (api `cursor-cli`) shell out to the vendor binary with
 * `--permission-mode dangerous`, and that binary runs its OWN agent with its
 * OWN tools. Pi never sees a bash call, so no spawnHook fires, no `tool_call`
 * fires, and `protected-paths.ts` / `permission-gate.ts` are equally blind.
 * Every rule in spawn-guard-core.ts — git stash, rm -rf under
 * $HOME/workspaces, credential-path writes, systemctl restarts, the process
 * ceiling, the depth-1 spec-gate guard, the 0509 wrangler-deploy block — is
 * bypassed for those seats, and `devin/glm-5-2` is the fleet's primary seat.
 *
 * Proven both ways on pi 0.84.2 with the same command in the same shape:
 *   * `--provider devin --model glm-5-2`: `git stash push -m probe2c` RAN,
 *     created a real stash entry, produced no SPAWN_BLOCKED line and no
 *     block-log row. `echo "HOOK=[$PI_SPAWN_HOOK]"` printed `HOOK=[]`.
 *   * `--provider ollama --model deepseek-v4-flash:0731`: the same command was
 *     BLOCKED, no stash created, SPAWN_BLOCKED logged with full argv.
 *
 * Closing that gap is not possible from inside a Pi extension; it needs a
 * guard below the agent (a PATH shim, or simply not leaving the credential
 * within reach — see P10-B item 5). Said plainly here so nobody reads
 * `EXTLOAD-OK` and concludes the fleet is guarded. That line proves the FILE
 * loaded, not that the seat in use routes through it, which is why it now
 * names the mechanism (`guard=tool_call`) rather than just claiming a guard.
 *
 * A CORRECTION, recorded on purpose
 * ---------------------------------
 * The first version of this header claimed the old `createBashTool` override
 * "never runs" on pi 0.84.2. That was WRONG, and it was wrong because every
 * probe behind it had been run against the devin CLI shim, where no Pi tool
 * runs at all. Retested against a native provider, the old override blocked
 * `git stash` correctly. Whoever reads this next: a guard tested on one
 * provider has been tested on one provider.
 *
 * WHY tool_call ANYWAY
 * --------------------
 * The move still stands on its own merits, for native-provider seats:
 *   * it is Pi's shipped, documented interception point
 *     (docs/extensions.md:766-791) and the one Pi's own example uses for
 *     exactly this job — blocking `rm -rf`;
 *   * it is what every other guard in this directory already uses
 *     (protected-paths.ts, permission-gate.ts), so there is now one mechanism
 *     to reason about instead of two;
 *   * `{ block: true, reason }` hands the model a structured, actionable
 *     refusal naming the sanctioned alternative, instead of a synthesized
 *     `exit 2` that reads as a bare failed command;
 *   * it stops this extension squatting the built-in "bash" tool name. That
 *     squat was not harmless: with the override in place, ANY other extension
 *     registering bash died with `Tool "bash" conflicts with …` and Pi
 *     refused to start.
 *
 * Rollback: restore bash-spawn-hook.ts.bak-20260825-toolcall (the override
 * version — functional on native providers, equally blind to devin/cursor).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
	evaluateBashToolCall,
	FLEET_SLICE_TASKS_MAX,
	FLEET_SPAWN_SOFT_CEILING,
} from "./spawn-guard-core.ts";

export { evaluateSpawnHook, evaluateBashToolCall } from "./spawn-guard-core.ts";

export default function (pi: ExtensionAPI) {
	process.stderr.write(
		`EXTLOAD-OK extension=bash-spawn-hook guard=tool_call depth_max=1 ceiling=${FLEET_SPAWN_SOFT_CEILING}/${FLEET_SLICE_TASKS_MAX} wrangler_deploy_guard=0509\n`,
	);

	pi.on("tool_call", async (event) => {
		if (event.toolName !== "bash") return;
		const command = (event.input as { command?: string })?.command;
		if (typeof command !== "string" || command.length === 0) return;

		const verdict = evaluateBashToolCall({
			command,
			cwd: process.cwd(),
			env: process.env,
		});
		if (!verdict) return;

		return { block: true, reason: verdict.reason };
	});
}
