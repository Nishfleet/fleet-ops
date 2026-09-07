/**
 * Provider-shim spawn guard (fleet-ops#3126, P10-bypass closure).
 *
 * The devin and cursor providers are CLI shims: they shell out to a vendor
 * binary (`devin`, `cursor-agent`) with `--permission-mode dangerous`, and
 * that binary runs its OWN agent with its OWN tools. Pi never sees a bash
 * call from inside the vendor session, so the Pi-side guards
 * (bash-spawn-hook.ts -> spawn-guard-core.ts, protected-paths.ts,
 * permission-gate.ts) are all blind on those seats. Proven 2026-08-25:
 * `git stash push` RAN on the devin seat with no SPAWN_BLOCKED line and no
 * block-log row.
 *
 * This module closes that gap at the only point the shim controls: the
 * prompt handed to the vendor binary. Before execing the vendor CLI, the
 * provider shim calls `assertPromptSafe(prompt)`, which scans the prompt for
 * the dangerous shapes the fleet guard refuses and throws a loud, actionable
 * error if any is present. The vendor agent never starts, so the dangerous
 * operation never runs.
 *
 * The rules mirror spawn-guard-core.ts (git stash, rm -rf under
 * $HOME/workspaces, credential-path writes, systemctl restarts, the 0509
 * wrangler-deploy block). Keep the two in step: if you add a rule to one,
 * add it to both.
 *
 * This is a helper module, not a standalone extension. It is imported by the
 * provider shims and auto-discovered by Pi as a no-op default export (same
 * pattern as spawn-guard-core.ts). Rollback: rm this file and revert the
 * provider shims to their pre-guard form.
 */

import { appendFileSync } from "node:fs";

/** Append-only log of every blocked spawn — same target as spawn-guard-core.ts. */
export const SPAWN_BLOCK_LOG = "/home/nish/workspaces/agent-state/spawn-blocks.log";

/**
 * Dangerous shapes the provider shims refuse before execing the vendor
 * binary. Mirrors the DANGEROUS_RULES + WRANGLER_DEPLOY_0509 policy in
 * spawn-guard-core.ts. Each entry carries the same id so the block log and
 * the model-facing reason stay consistent across the Pi-side and shim-side
 * guards.
 */
const PROVIDER_DANGEROUS_RULES: Array<{ id: string; pattern: RegExp }> = [
	// git stash (mutating forms). Read-only list/show are allowed (fleet-ops#754).
	{ id: "git_stash_forbidden", pattern: /\bgit\s+stash\b(?!\s+(?:list|show)\b)/i },
	{
		id: "systemctl_restart_slice",
		pattern: /\bsystemctl\s+restart\s+[^\n;|&]*\.slice\b/i,
	},
	{
		id: "systemctl_restart_fleet_unit",
		pattern:
			/\bsystemctl\s+restart\s+[^\n;|&]*(?:fleet-|implementation-worker-)/i,
	},
	{
		id: "credential_path_write",
		pattern:
			/(?:>>?|tee\b)[^\n;|&]*(?:fleet2\/etc\/|\/\.env\b|auth\.json\b)/i,
	},
	{
		id: "rm_rf_home_or_workspaces",
		pattern:
			/\brm\s+(-[^\s]*f[^\s]*\s+|-rf\s+)[^\n;|&]*(?:\/home\/nish\b|workspaces\/)/i,
	},
	// Direct wrangler deploy / versions upload, or the 0509 npm deploy entry
	// point (Nish, 2026-08-25, P10-B item 4).
	{
		id: "wrangler_deploy_0509",
		pattern:
			/\b(?:wrangler\s+(?:deploy|versions\s+upload)|npm\s+run\s+deploy|node\s+scripts\/deploy-production\.mjs)\b/,
	},
];

function logBlock(reason: string, prompt: string): void {
	try {
		const ts = new Date().toISOString();
		const snippet = prompt.slice(0, 500).replace(/\n/g, "\\n");
		appendFileSync(
			SPAWN_BLOCK_LOG,
			`${ts}\tprovider_shim_${reason}\t${process.cwd()}\t${snippet}\n`,
		);
	} catch {
		// Logging must never break the guard.
	}
}

function blockReasonText(id: string): string {
	const guidance: Record<string, string> = {
		git_stash_forbidden:
			"`git stash` is forbidden on this machine: checkouts are shared, so `git stash pop` grabs stash@{0}, which is very often another agent's work. Commit to a branch instead, or clone the repo fresh under /tmp and work there.",
		rm_rf_home_or_workspaces:
			"Recursive delete under /home/nish or workspaces/ is forbidden. Delete the exact paths you created, by name.",
		credential_path_write:
			"Writing to a credential path is forbidden. Never write secrets into repos, notes, or env files from a worker session.",
		systemctl_restart_slice:
			"Restarting a systemd slice is forbidden: it kills every unrelated agent sharing it.",
		systemctl_restart_fleet_unit:
			"Restarting fleet units from inside a worker session is forbidden.",
		wrangler_deploy_0509:
			"Local production deploys of 0509 are forbidden: the CI pipeline is the only sanctioned deploy path, and deploying from here skips every merge gate. Land the change through a PR.",
	};
	const extra = guidance[id] ?? "This operation is blocked by the fleet spawn guard.";
	return `SPAWN_BLOCKED reason=${id}. ${extra}`;
}

/**
 * Scan a prompt for dangerous operations. Returns the rule id that tripped,
 * or null if the prompt is safe.
 */
export function detectDangerousPrompt(prompt: string): string | null {
	for (const rule of PROVIDER_DANGEROUS_RULES) {
		if (rule.pattern.test(prompt)) return rule.id;
	}
	return null;
}

/**
 * Refuse to launch a vendor binary whose prompt requests a dangerous
 * operation. Throws a loud, actionable error naming the blocked shape and the
 * sanctioned alternative. Called by the devin and cursor provider shims
 * BEFORE they exec the vendor CLI.
 */
export function assertPromptSafe(prompt: string): void {
	const id = detectDangerousPrompt(prompt);
	if (!id) return;
	logBlock(id, prompt);
	process.stderr.write(`SPAWN_BLOCKED reason=${id}\n`);
	throw new Error(blockReasonText(id));
}

/** Pi auto-discovers this file; it is not an extension. */
export default function (): void {}
