/**
 * Pure spawn-guard logic — no Pi imports.
 *
 * Used by bash-spawn-hook.ts (Pi spawnHook) and by hermetic proof.
 * Pi auto-discovers every *.ts in this directory, so this file also
 * exports a no-op default.
 *
 * Rollback: rm this file; restore bash-spawn-hook.ts.bak-20260823-step3
 */

import { execSync } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";

export const FLEET_SPEC_MAX_DEPTH = 1;
/** systemd TasksMax on fleet-work.slice — hard silent kill. Must match systemd/fleet-work.slice.d/10-tasksmax.conf (fleet-ops#3280: 11 threads/pi). */
export const FLEET_SLICE_TASKS_MAX = 8000;
/** Hook fails loud before systemd's silent TasksMax kill. */
export const FLEET_SPAWN_SOFT_CEILING = 7500;

/** Break-glass override for local 0509 deploys (CI is the sanctioned path; Nish, 2026-08-25). */
export const BREAKGLASS_DEPLOY_0509 = "FLEET_BREAKGLASS_DEPLOY_0509";
/** Append-only log of every blocked spawn — closes the argv observability gap. */
export const SPAWN_BLOCK_LOG = "/home/nish/workspaces/agent-state/spawn-blocks.log";

export interface SpawnContext {
	command: string;
	cwd: string;
	env: NodeJS.ProcessEnv;
}

/**
 * Every ladder leg that can re-enter the spec gate.
 * Names match live binaries in ~/.local/bin.
 */
const LADDER_LEG =
	/(?:^|[\s'"=])(?:\/home\/nish\/\.local\/bin\/)?(?:fleet-spec-author|implementation-worker-(?:deepseek(?:-auto|-opencode|-commandcode)?|minimax-m3|grok-(?:auto|cursor|super)|cursor-sub|devin-glm|free-pool|luna-max|pi|sol-xhigh))(?:\s|$)/;

const SPEC_AUTHOR =
	/(?:^|[\s'"=])(?:\/home\/nish\/\.local\/bin\/)?fleet-spec-author(?:\s|$)/;

const M3_LEG =
	/(?:^|[\s'"=])(?:\/home\/nish\/\.local\/bin\/)?implementation-worker-minimax-m3(?:\s|$)/;

const DANGEROUS_RULES: Array<{ id: string; pattern: RegExp }> = [
	// Allow read-only `git stash list` / `git stash show` (fleet-ops#754);
	// still block every mutating form (bare `git stash`, pop, apply, push,
	// drop, clear, branch, create, store). The standing rule is about not
	// popping another agent's stash; listing/showing does not touch it.
	{ id: "git_stash_forbidden", pattern: /\bgit\s+stash\b(?!\s+(?:list|show)\b)/i },
	// fleet-ops#5589 (rulebook redteam 2026-09-11): the AGENTS.md hard line
	// "Never `systemctl restart` a slice — it bounces every unit inside it"
	// had no mechanical guard that actually fired. The pre-#5589 rule
	// (systemctl_restart_slice) required `restart` to sit directly after
	// `systemctl`, so `systemctl --user restart user-1000.slice` — the exact
	// shape the finding names; user-1000.slice carries ~54 live timers/units —
	// slipped through, and `stop` was not covered at all.
	//
	// Blocks `systemctl [flags] restart|stop ... <target>.slice` for any
	// target EXCEPT the dated allowlist documented below. Mixed targets are
	// blocked conservatively: one non-allowlisted slice anywhere in the
	// argument span blocks the whole command. (try-restart / kill / freeze
	// remain out of scope — the issue's contract is restart|stop.)
	//
	// Dated allowlist escape (drasl et al): single-purpose slices whose
	// restart/stop cannot bounce unrelated units. Every entry is an
	// exception to the hard line and needs a date + reason. Entries for
	// slices that do not exist on a machine are inert.
	//   - drasl.slice — 2026-09-11, fleet-ops#5589 (drasl et al.)
	{
		id: "systemctl_slice_lifecycle",
		pattern:
			/\bsystemctl\s+(?:[^\s;|&]+\s+)*?\b(?:restart|stop)\s+(?=[^\n;|&]*(?<![\w.\/-])(?!drasl\.slice\b)[^\s;|&]*\.slice\b)/i,
	},
	// Same flags-gap fix: `systemctl --user restart fleet-heartbeat.service`
	// defeated the pre-#5589 shape the same way. Verb set extended to stop
	// for fleet units too (fleet-ops#5605): a worker stopping a fleet unit
	// is the same class of self-harm — it kills the dead-man and the
	// in-flight work with no escalation.
	{
		id: "systemctl_restart_fleet_unit",
		pattern:
			/\bsystemctl\s+(?:[^\s;|&]+\s+)*?\b(?:restart|stop)\s+[^\n;|&]*(?:fleet-|implementation-worker-)/i,
	},
	{
		id: "credential_path_write",
		pattern:
			/(?:>>?|tee\b)[^\n|;&]*(?:fleet2\/etc\/|\/\.env\b|auth\.json\b)/i,
	},
	{
		id: "rm_rf_home_or_workspaces",
		pattern:
			/\brm\s+(-[^\s]*f[^\s]*\s+|-rf\s+)[^\n;|&]*(?:\/home\/nish\b|workspaces\/)/i,
	},
	// fleet-ops#4896: alert-repair workers ran `find /home/nish -name '*.prom'`
	// and `grep -rln <metric> /home/nish/workspaces ...` to locate files the
	// packet could have named — two sweeps of a 282 GB home dir pushed load to
	// 20 on 8 vCPU while zero product workers were admitted. Block recursive
	// searches rooted at /, ~, /home/nish, /home/nish/workspaces or
	// /home/nish/.local; a search rooted at a repo checkout or a state dir
	// below those stays allowed.
	{
		id: "home_wide_filesystem_sweep",
		pattern: /\b(?:find|rg|grep\s+(?:-\S+\s+)*-[A-Za-z]*[rR]\S*)(?:\s+[^\n;|&]*?)?\s+(?:\/|~|\$HOME|\/home|\/home\/nish|\/home\/nish\/workspaces|\/home\/nish\/\.local)\/?(?=\s|$)/i,
	},
	// fleet-ops#3111: a worker session must never write root-owned files into
	// the pi transport paths. The 2026-09-03 clobber was a worker running
	// `sudo install -D -m 0755 /dev/null /home/nish/.local/bin/pi` while
	// stubbing binaries for a test — it replaced the pi symlink with a 0-byte
	// root-owned regular file and starved the fleet for 33h. sudoers is
	// `nish ALL NOPASSWD: all`, so any worker can write root anywhere; this
	// rule blocks the dangerous shape at the spawn boundary. Covers install /
	// cp / tee / mv / ln / redirect / dd writing into ~/.local/bin,
	// ~/.local/lib/node_modules, ~/.pi, or /etc/systemd, and any /dev/null
	// source into $HOME. Block reason names the target so the model knows
	// which path tripped it.
	{
		id: "sudo_write_protected_path",
		pattern:
			/\bsudo\b[^\n;|&]*(?:\b(?:install|cp|mv|ln|dd|tee)\b|>>?)[^\n;|&]*(?:\/home\/nish\/\.local\/bin\b|\/home\/nish\/\.local\/lib\/node_modules\b|\/home\/nish\/\.pi\b|\/etc\/systemd\b)/i,
	},
	{
		id: "sudo_devnull_into_home",
		pattern:
			/\bsudo\b[^\n;|&]*(?:\b(?:install|cp|mv|ln|dd)\b|>>?)[^\n;|&]*\/dev\/null[^\n;|&]*(?:\/home\/nish\b)/i,
	},
];

/**
 * Direct wrangler deploy / versions upload, or the 0509 npm deploy entry point.
 * `npm run deploy` → `node scripts/deploy-production.mjs` → `spawnSync(wrangler, …)`
 * uses spawnSync internally, so the hook never sees the nested wrangler call —
 * the entry points must be blocked directly. (Nish, 2026-08-25, P10-B item 4.)
 */
const WRANGLER_DEPLOY_0509 =
	/\b(?:wrangler\s+(?:deploy|versions\s+upload)|npm\s+run\s+deploy|node\s+scripts\/deploy-production\.mjs)\b/;

/**
 * fleet-ops#5902: the worker memory-budget rule (prompts/worker.md, fleet-ops#4891/#4893)
 * — never `tsc -b`, `vitest --coverage`, `npm run typecheck` / `test:coverage` inside a
 * worker — was prose only. On 2026-09-12 pi-issue@0509-3014 ran
 * `NODE_OPTIONS=--max-old-space-size=3072 npx tsc -b` (node RSS 1.77 GB) and #4838 had
 * already shown the box's RAM goes to these toolchains, not to seat count. This is the
 * mechanical guard. Worker context = the session's cgroup is a pi-issue@ unit;
 * FLEET_WORKER_CONTEXT=1|0 overrides for tests. Quoted mentions are stripped first so a
 * worker can still grep for or write about the banned commands.
 */
export const WORKER_TOOLCHAIN_RULE =
	/\b(?:(?:npx\s+)?tsc\s+(?:-b|--build)\b|vitest\b[^\n;|&]*--coverage\b|npm\s+(?:run\s+)?(?:typecheck|test:coverage)\b|npm\s+test\b[^\n;|&]*--coverage\b)/i;

export function isWorkerSession(env: NodeJS.ProcessEnv): boolean {
	if (env.FLEET_WORKER_CONTEXT === "1") return true;
	if (env.FLEET_WORKER_CONTEXT === "0") return false;
	try {
		return readFileSync("/proc/self/cgroup", "utf8").includes("pi-issue@");
	} catch {
		return false;
	}
}

export function workerToolchainBlock(ctx: SpawnContext): string | null {
	if (!isWorkerSession(ctx.env)) return null;
	const m = WORKER_TOOLCHAIN_RULE.exec(stripQuotedShellText(ctx.command));
	return m ? `worker_toolchain_ban cmd=${m[0].trim()}` : null;
}

/**
 * fleet-ops#5700: the raw WRANGLER_DEPLOY_0509 regex is tested against the
 * FULL command text, so read-only commands that merely MENTION a deploy
 * phrase inside a quoted string or a heredoc body were blocked — 98 blocks,
 * majority false positives (a worker cannot grep for wrangler, write a PR
 * body via `cat <<EOF`, or even file this issue without tripping the gate;
 * the scout that filed #5700 was SPAWN_BLOCKED three times while filing it).
 *
 * stripQuotedShellText returns the command with heredoc bodies dropped and
 * quoted spans replaced by NUL separators, so only executable-position text
 * remains. Quoted content is prose — grep patterns, PR bodies, issue text.
 * Defensive edge: `sh -c 'wrangler deploy'` hides the deploy inside a quote
 * while still EXECUTING it, so when a `sh|bash -c` wrapper appears in the
 * stripped text and the raw text matches, the guard falls back to blocking
 * (conservative — the gate's teeth are kept at the cost of over-matching a
 * rare `grep 'sh -c'` shape). See fleet-spawn-guard-stash-readonly.test.sh
 * for the same principle (read-only mention ≠ execution).
 */
export function stripQuotedShellText(command: string): string {
	// 1. Drop heredoc bodies (everything up to the terminator line). A
	// heredoc body is prose — PR bodies, issue filings — never executable.
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
		const m = line.match(/<<(-?)\s*(['\"`]?)([A-Za-z_][A-Za-z0-9_-]*)\2/);
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

/**
 * fleet-ops#5700 dry-run precision: a wrangler deploy/versions upload
 * invocation that carries --dry-run deploys NOTHING (it only bundles), and
 * it is the one legitimate local pre-push verification for a wrangler
 * change. It is exempt — but any OTHER deploy entry point appearing in a
 * command separator-sibling segment (`&&`, `;`, `|`, `\n`) still blocks:
 * `wrangler deploy --dry-run && npm run deploy` is a deploy.
 */
export function wranglerDeployExecutableEntry(
	command: string,
): string | null {
	const stripped = stripQuotedShellText(command);
	const segments = stripped.split(/&&|\|\||[;|\n]/);
	for (const seg of segments) {
		if (!WRANGLER_DEPLOY_0509.test(seg)) continue;
		const isWranglerDryRunOnly =
			/\bwrangler\s+(?:deploy|versions\s+upload)\b/.test(seg) &&
			/--dry-run/.test(seg) &&
			!/\bnpm\s+run\s+deploy\b|\bnode\s+scripts\/deploy-production\.mjs\b/.test(
				seg,
			);
		if (isWranglerDryRunOnly) continue;
		return seg.trim();
	}
	// `sh -c` conservative fallback: see stripQuotedShellText.
	if (
		/(?:^|[;&|("\s])(?:sudo\s+)?(?:sh|bash)\s+-c\b/.test(stripped) &&
		WRANGLER_DEPLOY_0509.test(command)
	) {
		return command;
	}
	return null;
}

function parseDepth(env: NodeJS.ProcessEnv): number {
	const raw = env.FLEET_SPEC_DEPTH ?? env.FLEET_SPAWN_DEPTH ?? "0";
	const depth = Number.parseInt(String(raw), 10);
	return Number.isFinite(depth) && depth >= 0 ? depth : 0;
}

function shellQuote(value: string): string {
	return `'${value.replace(/'/g, `'\\''`)}'`;
}

function ladderRoute(command: string): string {
	if (M3_LEG.test(command)) return "minimax-m3";
	if (SPEC_AUTHOR.test(command)) return "fleet-spec-author";
	if (/implementation-worker-deepseek-opencode/.test(command)) return "opencode";
	if (/implementation-worker-deepseek-commandcode/.test(command))
		return "commandcode";
	if (/implementation-worker-deepseek/.test(command)) return "deepseek-auto";
	if (/implementation-worker-grok-cursor/.test(command)) return "grok-cursor";
	if (/implementation-worker-grok-super/.test(command)) return "grok-super";
	if (/implementation-worker-grok-auto/.test(command)) return "grok-auto";
	if (/implementation-worker-cursor-sub/.test(command)) return "cursor-sub";
	if (/implementation-worker-devin-glm/.test(command)) return "devin-glm";
	if (/implementation-worker-free-pool/.test(command)) return "free-pool";
	if (/implementation-worker-pi/.test(command)) return "pi";
	return "ladder-leg";
}

/**
 * Identify the ladder leg we are ON, not the command we are about to spawn.
 * Inherited FLEET_SPAWN_LEG / parent cmd win so a child fleet-spec-author
 * on the M3 fallback is labelled route=minimax-m3, not fleet-spec-author.
 */
function currentLeg(command: string, env: NodeJS.ProcessEnv): string {
	const inherited = env.FLEET_SPAWN_LEG;
	if (inherited && inherited !== "ladder-leg") return inherited;
	if (M3_LEG.test(env.FLEET_SPAWN_PARENT_CMD ?? "")) return "minimax-m3";
	if (M3_LEG.test(command)) return "minimax-m3";
	return ladderRoute(command);
}

function logBlock(reason: string, ctx: SpawnContext): void {
	try {
		const ts = new Date().toISOString();
		const cmd = ctx.command.slice(0, 500).replace(/\n/g, "\\n");
		const cwd = ctx.cwd.replace(/\t/g, " ");
		appendFileSync(SPAWN_BLOCK_LOG, `${ts}\t${reason}\t${cwd}\t${cmd}\n`);
	} catch {
		// Logging must never break the guard.
	}
}

/**
 * Block local 0509 production deploys from worker sessions. CI is the only
 * sanctioned deploy path (Nish, 2026-08-25, P10-B item 4). Scoped to repos
 * whose path contains "0509" and have a wrangler config in cwd. Break-glass
 * via FLEET_BREAKGLASS_DEPLOY_0509=1 for the documented CI-down case.
 *
 * ctx.cwd is the Pi process cwd, NOT the shell's `cd` target — a command like
 * `cd /path/to/0509 && wrangler deploy` sets cwd inside the shell, so we must
 * check both the spawn cwd and the command string for 0509 path references.
 */
export function wranglerDeployBlock(ctx: SpawnContext): string | null {
	if (!wranglerDeployExecutableEntry(ctx.command)) return null;
	if (ctx.env[BREAKGLASS_DEPLOY_0509] === "1") return null;
	if (!/0509/.test(ctx.cwd) && !/0509/.test(ctx.command)) return null;
	return "wrangler_deploy_0509";
}

function blocked(ctx: SpawnContext, reason: string): SpawnContext {
	logBlock(reason, ctx);
	const line = `SPAWN_BLOCKED reason=${reason}`;
	process.stderr.write(`${line}\n`);
	return {
		command: `printf '%s\\n' ${shellQuote(line)} >&2; exit 2`,
		cwd: ctx.cwd,
		env: {
			...ctx.env,
			PI_SPAWN_HOOK: "1",
			FLEET_SPAWN_GUARD: "1",
			FLEET_SPAWN_BLOCK_REASON: reason,
		},
	};
}

function fleetTasksCurrent(): number | null {
	try {
		const out = execSync(
			"systemctl --user show fleet-work.slice -p TasksCurrent --value",
			{ encoding: "utf8", timeout: 2000 },
		).trim();
		const n = Number.parseInt(out, 10);
		return Number.isFinite(n) ? n : null;
	} catch {
		return null;
	}
}

function dangerousRule(command: string): string | null {
	for (const rule of DANGEROUS_RULES) {
		if (rule.pattern.test(command)) return rule.id;
	}
	return null;
}

export interface BlockVerdict {
	reason: string;
}

/**
 * The LIVE guard. Called from bash-spawn-hook.ts's `tool_call` handler, which
 * fires for Pi's BUILT-IN bash tool.
 *
 * `evaluateSpawnHook` below is kept for the hermetic proof and for anything
 * that still constructs its own bash tool. It works, but it is no longer the
 * live path. Both functions must carry the same rules: if you add a rule to
 * one, add it to both.
 *
 * NEITHER function protects a `devin` or `cursor` session. Those providers
 * shell out to a vendor CLI that runs its own agent with its own tools, so Pi
 * never sees the bash call and nothing here is consulted. Proven 2026-08-25 —
 * see the bash-spawn-hook.ts header. Never conclude a rule is enforced from
 * `EXTLOAD-OK` or from a hermetic test: prove it with a real `pi --print` run
 * ON THE SEAT THE FLEET ACTUALLY USES.
 *
 * Returns null to allow, or a verdict whose `reason` is handed to the model as
 * a structured block reason.
 */
export function evaluateBashToolCall(ctx: SpawnContext): BlockVerdict | null {
	const { command, env } = ctx;
	const depth = parseDepth(env);

	const danger = dangerousRule(command);
	if (danger) {
		logBlock(danger, ctx);
		process.stderr.write(`SPAWN_BLOCKED reason=${danger}\n`);
		return { reason: blockReasonText(danger) };
	}

	const toolchainBlock = workerToolchainBlock(ctx);

	if (toolchainBlock) {

		logBlock(toolchainBlock, ctx);

		process.stderr.write(`SPAWN_BLOCKED reason=${toolchainBlock}\n`);

		return { reason: blockReasonText(toolchainBlock) };

	}

	const wranglerBlock = wranglerDeployBlock(ctx);
	if (wranglerBlock) {
		logBlock(wranglerBlock, ctx);
		process.stderr.write(`SPAWN_BLOCKED reason=${wranglerBlock}\n`);
		return { reason: blockReasonText(wranglerBlock) };
	}

	const tasks = fleetTasksCurrent();
	if (tasks !== null && tasks >= FLEET_SPAWN_SOFT_CEILING) {
		const reason = `process_ceiling tasks=${tasks} soft=${FLEET_SPAWN_SOFT_CEILING} slice_max=${FLEET_SLICE_TASKS_MAX}`;
		logBlock(reason, ctx);
		process.stderr.write(`SPAWN_BLOCKED reason=${reason}\n`);
		return { reason: blockReasonText(reason) };
	}

	if (SPEC_AUTHOR.test(command) && depth >= FLEET_SPEC_MAX_DEPTH) {
		const route = currentLeg(command, env);
		const reason = `spec_gate_reentry depth=${depth} max=${FLEET_SPEC_MAX_DEPTH} route=${route}`;
		logBlock(reason, ctx);
		process.stderr.write(`SPAWN_BLOCKED reason=${reason}\n`);
		return { reason: blockReasonText(reason) };
	}

	return null;
}

/**
 * A refusal the model can act on. The old block path replaced the command with
 * `printf 'SPAWN_BLOCKED reason=x' >&2; exit 2`, which reaches the model as a
 * bare failed command with no guidance about what to do instead — the shape
 * that leaves a worker flailing.
 */
function blockReasonText(reason: string): string {
	const id = reason.split(" ")[0];
	const guidance: Record<string, string> = {
		git_stash_forbidden:
			"`git stash` is forbidden on this machine: checkouts are shared, so `git stash pop` grabs stash@{0}, which is very often another agent's work. Commit to a branch instead, or clone the repo fresh under /tmp and work there.",
		rm_rf_home_or_workspaces:
			"Recursive delete under /home/nish or workspaces/ is forbidden. Delete the exact paths you created, by name.",
		credential_path_write:
			"Writing to a credential path is forbidden. Never write secrets into repos, notes, or env files from a worker session.",
		systemctl_slice_lifecycle:
			"Restarting or stopping a systemd slice bounces every unit inside it (user-1000.slice alone carries ~54 live timers/units). Only the dated allowlist in spawn-guard-core.ts (drasl et al) is exempt. Restart or stop the individual unit instead: `systemctl --user restart <unit>.service`.",
		systemctl_restart_fleet_unit:
			"Restarting (or stopping) fleet units from inside a worker session is forbidden.",
		sudo_write_protected_path:
			"Writing root-owned files into the pi transport paths (~/.local/bin, ~/.local/lib/node_modules, ~/.pi, /etc/systemd) is forbidden from a worker session. The 2026-09-03 incident clobbered ~/.local/bin/pi this way and starved the fleet for 33h. If a test needs a stub binary, use a tmp PATH dir under /tmp, never the real ~/.local/bin.",
		sudo_devnull_into_home:
			"Using /dev/null as a source into /home/nish under sudo is forbidden — it creates a 0-byte file that clobbers a real binary (the 2026-09-03 pi clobber was exactly this). Stub binaries in a tmp PATH dir under /tmp instead.",
		worker_toolchain_ban:
			"CI owns coverage and typecheck (prompts/worker.md memory-budget rule, fleet-ops#4891/#5902). Never run `tsc -b`, `vitest --coverage`, `npm run typecheck` or `npm run test:coverage` inside a worker: each costs 1-3 GB and starves the whole fleet. Run the targeted, coverage-free test for the files you touched and let the PR checks do the rest.",
		wrangler_deploy_0509:
			"Local production deploys of 0509 are forbidden: the CI pipeline is the only sanctioned deploy path, and deploying from here skips every merge gate. Land the change through a PR. If CI is genuinely down, the documented break-glass is FLEET_BREAKGLASS_DEPLOY_0509=1, which is Nish's call, not yours.",
		process_ceiling:
			"The fleet process ceiling is reached. Do not spawn more work; finish and report what you have.",
		spec_gate_reentry:
			"Re-entering the spec gate from a gate-spawned session is forbidden (depth limit 1). Do the work in this session.",
	};
	const extra = guidance[id] ?? "This command is blocked by the fleet spawn guard.";
	return `SPAWN_BLOCKED reason=${reason}. ${extra}`;
}

export function evaluateSpawnHook(ctx: SpawnContext): SpawnContext {
	const { command, cwd, env } = ctx;
	const depth = parseDepth(env);

	const danger = dangerousRule(command);
	if (danger) return blocked(ctx, danger);

	const wranglerBlock = wranglerDeployBlock(ctx);
	if (wranglerBlock) return blocked(ctx, wranglerBlock);

	const tasks = fleetTasksCurrent();
	if (tasks !== null && tasks >= FLEET_SPAWN_SOFT_CEILING) {
		return blocked(
			ctx,
			`process_ceiling tasks=${tasks} soft=${FLEET_SPAWN_SOFT_CEILING} slice_max=${FLEET_SLICE_TASKS_MAX}`,
		);
	}

	// A gate-spawned descendant (any ladder leg) must not re-enter the spec author.
	// Already-specced packets are recognised by the launchers (SPEC_GATE_ALREADY_SPECCED),
	// not by disabling the gate. This hook only blocks the recursive SPAWN.
	if (SPEC_AUTHOR.test(command) && depth >= FLEET_SPEC_MAX_DEPTH) {
		const route = currentLeg(command, env);
		return blocked(
			ctx,
			`spec_gate_reentry depth=${depth} max=${FLEET_SPEC_MAX_DEPTH} route=${route}`,
		);
	}

	const nextEnv: NodeJS.ProcessEnv = {
		...env,
		PI_SPAWN_HOOK: "1",
		FLEET_SPAWN_GUARD: "1",
	};

	if (LADDER_LEG.test(command)) {
		const nextDepth = depth + 1;
		nextEnv.FLEET_SPEC_DEPTH = String(nextDepth);
		nextEnv.FLEET_SPAWN_DEPTH = String(nextDepth);
		nextEnv.FLEET_SPEC_GATE_CHILD = "1";
		nextEnv.FLEET_SPAWN_LEG = ladderRoute(command);
		nextEnv.FLEET_SPAWN_PARENT_CMD = command.slice(0, 240);
	}

	return {
		command: `source ~/.profile 2>/dev/null || true\n${command}`,
		cwd,
		env: nextEnv,
	};
}

/** Pi auto-discovers this file; it is not an extension. */
export default function (): void {}
