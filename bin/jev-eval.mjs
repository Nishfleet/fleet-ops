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
//        --second-opinion (state must contain item and context; returns both framings)
//        JEV_SECOND_OPINION=0 disables the second call at this caller for rollback.
//        Disagreement is advisory; agreement never authorizes reserved-class action.
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
const SECOND_OPINION_THRESHOLD = 0.5; // #7429: boolean answers disagree when their probabilities fall on opposite sides
const LIB_CANDIDATES = [process.env.JEV_EVAL_LIB, join(HOME, ".local/lib/jev-eval"), join(dirname(fileURLToPath(import.meta.url)), "..", "lib", "jev-eval")].filter(Boolean);

const argv = process.argv.slice(2);
const flag = (name, dflt) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : dflt; };
const dryRun = argv.includes("--dry-run");
const synthetic = argv.includes("--synthetic");
const capUsd = Number(flag("--cap-usd", "1"));
const siteFlag = flag("--site", null);
const refFlag = flag("--ref", null);

const secondOpinion = argv.includes("--second-opinion") && process.env.JEV_SECOND_OPINION !== "0";

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
if (secondOpinion) {
  if (typeof input.state !== "object" || input.state === null) die(2, "--second-opinion needs an object state with item and context fields");
  if (!("item" in input.state) || !("context" in input.state)) die(2, "--second-opinion needs an object state with item and context fields");
}
const site = String(siteFlag || input.site || "unknown").replace(/[^A-Za-z0-9._-]/g, "_");
const ref = refFlag || input.ref || null;
const stateStr = typeof input.state === "string" ? input.state : JSON.stringify(input.state);
const stateSha = createHash("sha256").update(stateStr).digest("hex");

mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
const LOG = join(STATE_DIR, `${site}.jsonl`);
function logRow(row) {
  if (dryRun) row.dry_run = true;
  if (synthetic || dryRun) row.synthetic = true;
  appendFileSync(LOG, JSON.stringify(row) + "\n", { mode: 0o600 });
}
const evaluateOnce = async (state, framing) => {
  const spend = readSpend();
  if (spend.usd >= capUsd) die(3, `spend cap reached: $${spend.usd.toFixed(4)} >= $${capUsd} (${SPEND})`);
  let answers, usage, ms;
  if (dryRun) {
    answers = Object.fromEntries(Object.entries(input.questions).map(([k, q]) => [k, { type: q.type, dryRun: true }]));
    usage = { inputTokens: 0, outputTokens: 0, totalTokens: 0 }; ms = 0;
  } else {
    const { experimental_evaluate } = loadSdk();
    process.env.AI_GATEWAY_API_KEY = readKey(); // this process only
    const t = Date.now();
    let r;
    try { r = await experimental_evaluate({ model: MODEL, state, questions: input.questions }); }
    catch (e) { die(1, `gateway error: ${String((e && e.message) || e).slice(0, 300)}`); }
    answers = r.answers; usage = r.usage || {}; ms = Date.now() - t;
  }
  const hash = createHash("sha256").update(typeof state === "string" ? state : JSON.stringify(state)).digest("hex");
  const result = { answers, usage, ms, site, ref, state_sha256: hash };
  const ts = new Date().toISOString();
  const probabilities = Object.fromEntries(Object.entries(answers).map(([k, v]) => [k, v?.probability ?? v?.probabilities ?? v?.score ?? null]));
  logRow({ ts, ...result, probabilities, ...(framing ? { framing } : {}) });
  const tokens = usage.inputTokens || 0;
  writeFileSync(SPEND, JSON.stringify({ usd: spend.usd + tokens * USD_PER_INPUT_TOKEN, calls: spend.calls + 1, inputTokens: spend.inputTokens + tokens, updated: ts }) + "\n", { mode: 0o600 });
  return result;
};

function disagree(a, b) {
  let unknown = false;
  for (const [key, question] of Object.entries(input.questions)) {
    const va = a[key] ?? {}, vb = b[key] ?? {};
    let left, right;
    if (question.type === "boolean") {
      const valid = p => Number.isFinite(p) && p >= 0 && p <= 1 && p !== SECOND_OPINION_THRESHOLD;
      if (valid(va.probability) && valid(vb.probability)) {
        left = va.probability > SECOND_OPINION_THRESHOLD;
        right = vb.probability > SECOND_OPINION_THRESHOLD;
      }
    } else if (question.type === "choice") {
      if (Object.hasOwn(question.criteria || {}, va.choice) && Object.hasOwn(question.criteria || {}, vb.choice)) {
        left = va.choice; right = vb.choice;
      }
    } else if (question.type === "score") {
      if (Number.isFinite(va.score) && Number.isFinite(vb.score)) {
        left = va.score; right = vb.score;
      }
    }
    if (left === undefined || right === undefined) unknown = true;
    else if (left !== right) return true;
  }
  return unknown ? null : false;
}

let result;
if (secondOpinion) {
  const { item, context, ...rest } = input.state;
  // Explicit text preserves presentation order through SDK object serialization.
  const a = await evaluateOnce(JSON.stringify({ item, context, ...rest }), "item-first");
  const b = await evaluateOnce(JSON.stringify({ context, item, ...rest }), "context-first");
  const second_opinion = { a, b, disagreement: dryRun ? null : disagree(a.answers, b.answers) };
  const usage = Object.fromEntries(["inputTokens", "outputTokens", "totalTokens"].map(k => [k, (a.usage[k] || 0) + (b.usage[k] || 0)]));
  result = { answers: a.answers, usage, ms: a.ms + b.ms, site, ref, state_sha256: stateSha, second_opinion };
  // Summary is not another model call. Call rows above own usage and spend.
  logRow({ ts: new Date().toISOString(), kind: "second-opinion-summary", site, ref, state_sha256: stateSha, second_opinion });
} else {
  result = await evaluateOnce(input.state);
}
process.stdout.write(JSON.stringify(result) + "\n");
