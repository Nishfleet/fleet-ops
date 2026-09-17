#!/usr/bin/env node
// jev-eval — shared Jev helper (fleet-ops#7371, helper half). Ported from the operator
// workstation's proven helper on 2026-09-17.
//
//   stdin  JSON {state, questions, site?, ref?}   ->   stdout JSON {answers, usage, ms, site, ref, state_sha256}
//
// Jev = typesafe-ai/jev via the Vercel AI Gateway, evaluation model: choice / boolean / score
// questions with probabilities. Jev never writes code or prose. This helper is Jev-ONLY:
// any other model id exits 2. The key is read from the seats env file named in #7371
// (VERCEL_AI_GATEWAY_JEV_KEY) and exported ONLY into this process — never printed, never
// a global env var, never a router route.
//
// Every call appends one JSONL line
//   {ts, site, ref, state_sha256, answers, probabilities, usage, ms, synthetic?, dry_run?}
// to ~/.local/state/pi-packet/jev/<site>.jsonl (mode 600) and adds its cost to
// ~/.local/state/pi-packet/jev/spend.json; exit 3 once the spend cap is reached.
//
// Flags: --site <name>   --ref <real record: issue/PR number, message id, file path, timestamp>
//        --synthetic     (row is an invented sample, not real traffic: excluded from tallies)
//        --dry-run       (validate + log shape, no network, no key; logged as synthetic)
//        --cap-usd <n>   (default 1)
//
// Question shapes: boolean {type, instructions} -> {probability}
//                  choice  {type, criteria: {key: description}, instructions} -> {choice, probabilities}
//                  score   {type, instructions} -> {score, probabilities?}
//
// Runtime: node >= 22.7 (ESM auto-detect) and ai@7.0.105, resolved from $JEV_EVAL_LIB, then
// ~/.local/lib/jev-eval, then <this file>/../lib/jev-eval. One-time install (no repo lockfile change):
//   npm i --prefix ~/.local/lib/jev-eval --ignore-scripts --no-audit --no-fund ai@7.0.105
// (the fleet host ships node without npm: copy ~/.local/lib/jev-eval/{package.json,node_modules} from a
//  machine that has npm — ai@7 is pure JS, no native modules — as was done on 2026-09-17.)
// Dry-run and the test suite need neither the package nor the key.
import { createRequire } from "node:module";
import { readFileSync, appendFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HOME = homedir();
const KEY_FILE = join(HOME, ".config/fleet-ops/seats/typesafe-jev.env");
const STATE_DIR = join(HOME, ".local/state/pi-packet/jev");
const SPEND = join(STATE_DIR, "spend.json");
const MODEL = "typesafe-ai/jev";
const USD_PER_INPUT_TOKEN = 0.042 / 1e6; // #7371: $0.042/MTok in, $0 out
const LIB_CANDIDATES = [process.env.JEV_EVAL_LIB, join(HOME, ".local/lib/jev-eval"), join(dirname(fileURLToPath(import.meta.url)), "..", "lib", "jev-eval")].filter(Boolean);

const argv = process.argv.slice(2);
const flag = (name, dflt) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : dflt; };
const dryRun = argv.includes("--dry-run");
const synthetic = argv.includes("--synthetic");
const capUsd = Number(flag("--cap-usd", "1"));
const siteFlag = flag("--site", null);
const refFlag = flag("--ref", null);

function die(code, msg) { process.stderr.write(`jev-eval: ${msg}\n`); process.exit(code); }

function readKey() {
  if (!existsSync(KEY_FILE)) die(2, `key file missing: ${KEY_FILE}`);
  const m = readFileSync(KEY_FILE, "utf8").match(/^VERCEL_AI_GATEWAY_JEV_KEY=(.+)$/m);
  if (!m || !m[1].trim()) die(2, "VERCEL_AI_GATEWAY_JEV_KEY not set in key file");
  return m[1].trim();
}

function loadSdk() {
  for (const lib of LIB_CANDIDATES) {
    const pkg = join(lib, "package.json");
    if (!existsSync(join(lib, "node_modules", "ai", "package.json"))) continue;
    if (!existsSync(pkg)) writeFileSync(pkg, '{"name":"jev-eval-lib","private":true}\n');
    return createRequire(pkg)("ai");
  }
  die(2, `ai@7 not installed; run: npm i --prefix ${LIB_CANDIDATES[0]} --ignore-scripts --no-audit --no-fund ai@7.0.105`);
}

function readSpend() { try { return JSON.parse(readFileSync(SPEND, "utf8")); } catch { return { usd: 0, calls: 0, inputTokens: 0 }; } }

let input;
try { input = JSON.parse(readFileSync(0, "utf8")); } catch { die(2, "stdin must be JSON {state, questions, site?, ref?}"); }
if (!input || typeof input !== "object") die(2, "stdin must be a JSON object");
if (input.model && input.model !== MODEL) die(2, `refusing model ${input.model}: this helper is Jev-only`);
if (input.state === undefined || !input.questions || typeof input.questions !== "object" || !Object.keys(input.questions).length) die(2, "need {state, questions}");
const site = String(siteFlag || input.site || "unknown").replace(/[^A-Za-z0-9._-]/g, "_");
const ref = refFlag || input.ref || null;
const stateStr = typeof input.state === "string" ? input.state : JSON.stringify(input.state);
const stateSha = createHash("sha256").update(stateStr).digest("hex");

mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
const spend = readSpend();
if (spend.usd >= capUsd) die(3, `spend cap reached: $${spend.usd.toFixed(4)} >= $${capUsd} (${SPEND})`);

let answers, usage, ms;
if (dryRun) {
  answers = Object.fromEntries(Object.keys(input.questions).map((k) => [k, { type: input.questions[k].type, dryRun: true }]));
  usage = { inputTokens: 0, outputTokens: 0, totalTokens: 0 }; ms = 0;
} else {
  const { experimental_evaluate } = loadSdk();
  process.env.AI_GATEWAY_API_KEY = readKey(); // this process only
  const t = Date.now();
  let r;
  try { r = await experimental_evaluate({ model: MODEL, state: input.state, questions: input.questions }); }
  catch (e) { die(1, `gateway error: ${String((e && e.message) || e).slice(0, 300)}`); }
  ms = Date.now() - t; answers = r.answers; usage = r.usage || {};
}
const probabilities = Object.fromEntries(Object.entries(answers).map(([k, v]) => [k, v.probability ?? v.probabilities ?? v.score ?? null]));
const line = { ts: new Date().toISOString(), site, ref, state_sha256: stateSha, answers, probabilities, usage, ms };
if (dryRun) line.dry_run = true;
if (synthetic || dryRun) line.synthetic = true;
const LOG = join(STATE_DIR, `${site}.jsonl`);
appendFileSync(LOG, JSON.stringify(line) + "\n", { mode: 0o600 });
const usd = (usage.inputTokens || 0) * USD_PER_INPUT_TOKEN;
writeFileSync(SPEND, JSON.stringify({ usd: spend.usd + usd, calls: spend.calls + 1, inputTokens: spend.inputTokens + (usage.inputTokens || 0), updated: line.ts }) + "\n", { mode: 0o600 });
process.stdout.write(JSON.stringify({ answers, usage, ms, site, ref, state_sha256: stateSha }) + "\n");
