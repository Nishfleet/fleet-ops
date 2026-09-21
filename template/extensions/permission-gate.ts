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

/**
 * fleet-ops#7381: 2026-09-17 ~14:00Z, pi-issue-fleet-ops-7072 opened its run
 * with an improvised token presence check whose echo payload was
 *   "token: ${GH_TOKEN:+set}${GH_TOKEN:-EMPTY}"
 * — the :- expansion printed the live nishfleet-worker App token into the
 * session transcript. The AGENTS.md invariant now prescribes `test -n`
 * with constant output; this is the mechanical half. It applies to every
 * seat, not just workers: a secret in a transcript is never fine.
 *
 * Position-aware like the toolchain rule (fleet-ops#5700) but with the dual
 * quote treatment, because quoting decides EXPANSION here, not prose-ness:
 * single-quoted spans and <<'T' heredoc bodies can never expand (blanked
 * for the expansion check); double-quoted spans and <<T bodies DO expand —
 * they are the leak shape, so they stay visible. Command position is read
 * on a surface where every quoted span is blank, so a commit message
 * carrying "...the $GH_TOKEN idiom..." stays prose while outputting a
 * "x: $GH_TOKEN" line blocks.
 *
 * Known limits, accepted: a payload hidden inside a single-quoted `sh -c
 * '...'` string is invisible to a line-level guard, and set -x tracing can
 * echo expansions from commands this rule otherwise allows. The AGENTS.md
 * invariant bans the whole class; this gate covers the direct idioms.
 */
const SECRET_NAMED_VAR =
	/\$\{?!?\s*(?:[A-Za-z_][A-Za-z0-9_]*(?:TOKEN|SECRET|PASS(?:WORD|WD)?|CREDENTIALS?|PRIVATE|_KEY)[A-Za-z0-9_]*|SK_[A-Z][A-Z0-9_]*)/;
const ENV_DUMP_SUBSHELL =
	/\$\(\s*(?:printenv\b|env\s*\)|set\s*\)|(?:declare|export|typeset)\s+-p\b)/;
const SUBSHELL_SECRET_PRINT = new RegExp(
	`\\$\\(\\s*(?:echo|printf|printenv)\\b[^)]*${SECRET_NAMED_VAR.source}`,
);
/**
 * fleet-ops#7448: the same 2026-09-17 pi-issue-fleet-ops-7440 run leaked live
 * token material a second way — the auth-status subcommand of gh, whose
 * env-var account line carries the token value (verified live 2026-09-21:
 * the JWT is printed with only a trailing mask), and the auth-token
 * subcommand, which prints the credential outright. This is the
 * auth-status-output half of #7448's prevention clause; the expansion half
 * is the #7381 rule above. Read on the quote-masked command surface, so a
 * commit message naming the subcommand stays prose.
 */
const GH_AUTH_PRINT = /^\s*(?:[^\s;|&]+\s+)*auth\s+(status|token)\b/;
const CMD_SEGMENT = /[^;|&\n(){}`<>]+/g;
const SEGMENT_FIRST_WORD =
	/^\s*(?:(?:[A-Za-z_][A-Za-z0-9_]*=\S*|!|time|command|builtin|exec|nice|nohup|env|xargs|do|then|else|elif|timeout\s+\S+|stdbuf\s+\S+)\s+)*([A-Za-z_][A-Za-z0-9_./-]*)/;
const DUMP_REST = /^[\s\x00]*$|^[\s\x00]*-p\b/;
const TRACE_FLAG = /^[\s\x00]*(?:-[a-zA-Z]*[xv][a-zA-Z]*|-o\s+xtrace)\b/;
// `env` whose operands are only flags and NAME=val assignments has no
// command to run, so it PRINTS the environment (fleet-ops#7381 covers the
// whole dump class, not just bare `env`). -u/--unset/-C/-S take an operand.
// env sits in SEGMENT_FIRST_WORD's prefix class, so `env FOO=x -0`
// mis-resolves FOO as the first word — check for env in command position
// (after keyword prefixes only) before the segment scan resolves a word.
const ENV_ARG_FLAG = /^-(u|C|S)$|^--(unset|chdir|split-string)/;
const ENV_LEAD =
	/^\s*(?:(?:!|time|command|builtin|exec|nice|nohup|xargs|do|then|else|elif|timeout\s+\S+|stdbuf\s+\S+)\s+)*env\b([\s\S]*)$/;
function envDumpOperands(rest: string): boolean {
	const toks = rest.trim().split(/\s+/).filter(Boolean);
	let i = 0;
	while (i < toks.length) {
		if (ENV_ARG_FLAG.test(toks[i])) i += 2;
		else if (toks[i].startsWith("-") || /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[i]))
			i += 1;
		else break;
	}
	return i === toks.length;
}

/**
 * Position-preserving quote/comment mask. Single-quoted spans always mask
 * (cannot expand); double-quoted spans mask only for the command surface.
 * `#` starts a comment at word boundary and masks to end of line in both —
 * a comment neither runs nor expands.
 */
function maskQuotedSpans(text: string, maskDouble: boolean): string {
	let out = "";
	let q: string | null = null;
	let inComment = false;
	for (let i = 0; i < text.length; i++) {
		const ch = text[i];
		if (inComment) {
			if (ch === "\n") inComment = false;
			out += ch === "\n" ? ch : "\x00";
			continue;
		}
		if (q !== null) {
			if (ch === q) q = null;
			out += "\x00";
			continue;
		}
		if (ch === "'" || (maskDouble && ch === '"')) {
			q = ch;
			out += "\x00";
			continue;
		}
		if (ch === "#" && (i === 0 || /[\s;|&(){}`]/.test(text[i - 1]))) {
			inComment = true;
			out += "\x00";
			continue;
		}
		out += ch;
	}
	return out;
}

export function secretPrintBlock(command: string): string | null {
	// Pass 1: heredoc bodies. cmd masks every body (data, not commands); exp
	// masks only <<'T'-quoted bodies. A secret expansion inside an unquoted
	// body lands wherever the heredoc goes — a real leak, flagged directly.
	const cmdLines: string[] = [];
	const expLines: string[] = [];
	let term: string | null = null;
	let termQuoted = false;
	let heredocLeak = false;
	for (const line of command.split("\n")) {
		if (term !== null) {
			if (line.trim() === term) {
				term = null;
				cmdLines.push("");
				expLines.push("");
				continue;
			}
			cmdLines.push("");
			expLines.push(termQuoted ? "" : line);
			if (!termQuoted && SECRET_NAMED_VAR.test(line)) heredocLeak = true;
			continue;
		}
		const m = line.match(/<<(-?)\s*(['"`]?)([A-Za-z_][A-Za-z0-9_-]*)\2/);
		if (m) {
			term = m[3];
			termQuoted = m[2] !== "";
		}
		cmdLines.push(maskQuotedSpans(line, true));
		expLines.push(maskQuotedSpans(line, false));
	}
	const cmd = cmdLines.join("\n");
	const exp = expLines.join("\n");

	if (heredocLeak) return "secret_print heredoc-expands-secret";
	if (ENV_DUMP_SUBSHELL.test(exp)) return "secret_print env-dump-subshell";
	if (SUBSHELL_SECRET_PRINT.test(exp)) return "secret_print subshell-echo";

	// Pass 2: per segment on the command surface, an output/dump command in
	// first-word position decides whether the expansion surface is checked.
	for (const seg of cmd.matchAll(CMD_SEGMENT)) {
		const text = seg[0];
		const envM = text.match(ENV_LEAD);
		if (envM && envDumpOperands(envM[1])) return "secret_print cmd=env-dump";
		const fw = text.match(SEGMENT_FIRST_WORD);
		if (!fw) continue;
		const word = fw[1];
		if (word === "echo" || word === "printf") {
			if (SECRET_NAMED_VAR.test(exp.slice(seg.index, seg.index + text.length)))
				return `secret_print cmd=${word}`;
			continue;
		}
		if (word === "printenv") return "secret_print cmd=printenv";
		if (word === "gh" || word.endsWith("/gh")) {
			const auth = text.slice(fw[0].length).match(GH_AUTH_PRINT);
			if (auth) return `secret_print cmd=gh-auth-${auth[1]}`;
		}
		if (
			word === "env" ||
			word === "set" ||
			word === "export" ||
			word === "declare" ||
			word === "typeset"
		) {
			const rest = text.slice(fw[0].length);
			if (DUMP_REST.test(rest)) return `secret_print cmd=${word}-dump`;
			if (
				word === "set" &&
				TRACE_FLAG.test(rest) &&
				SECRET_NAMED_VAR.test(exp)
			)
				return "secret_print cmd=set-trace";
			if (word === "env" && envDumpOperands(rest))
				return "secret_print cmd=env-dump";
		}
	}
	return null;
}

const SECRET_PRINT_GUIDANCE =
	"A secret-named variable must never reach a printed/logged line: `${VAR:-...}`/`${VAR:+...}` " +
	"expansions, printenv, bare env/set/export/declare and set -x all put the VALUE in the transcript " +
	"(fleet-ops#7381). The GH_TOKEN presence check is `test -n \"$GH_TOKEN\"` — constant output only. " +
	"Never run gh's auth-status or auth-token subcommand either: both print the token " +
	"into the transcript (fleet-ops#7448).";

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
		"EXTLOAD-OK extension=permission-gate guard=tool_call rules=6 worker_toolchain_ban=armed secret_print=armed\n",
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

		// fleet-ops#7381: secret-print block, every seat (no worker-scope
		// check — a token in a transcript is never fine). Unattended seats get
		// the hard block; interactive seats get the same confirm flow as the
		// dangerous list.
		const secretBlock = secretPrintBlock(command);
		if (secretBlock) {
			if (!ctx.hasUI) {
				process.stderr.write(`SPAWN_BLOCKED reason=${secretBlock}\n`);
				return {
					block: true,
					reason: `SPAWN_BLOCKED reason=${secretBlock}. ${SECRET_PRINT_GUIDANCE}`,
				};
			}
			const choice = await ctx.ui.select(
				`⚠️ Command prints a secret-named variable:\n\n  ${command}\n\nAllow?`,
				["Yes", "No"],
			);
			if (choice !== "Yes") return { block: true, reason: "Blocked by user" };
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
