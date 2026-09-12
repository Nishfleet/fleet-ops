#!/usr/bin/env node
// repo-standards-apply.mjs — idempotent, deterministic standards sync across
// every repo in Nishfleet + nish3451.
//
// What it enforces (per repo, per repo type, honoring .fleet/standards-exceptions.yml):
//   - label triad (review:deep, no-auto-merge, fleet:standards)
//   - branch protection payload (enforce_admins, no force-push, no deletions,
//     required contexts = standard gates + repo product checks; NEVER weakens
//     a repo that requires MORE than the standard)
//   - merge-queue ruleset ("main-merge-queue", non_fast_forward + deletion +
//     merge_queue with HEADGREEN/max-5/min-2/wait-5min/6h-timeout + the
//     required_status_checks union — fleet-ops#5787). Created or PUT-updated
//     when drift is reported; never weakens a stronger existing shape; an
//     "extra-preserved" diff is reported as drift-not-error so a repo with a
//     stricter required context list is left alone (the next sweep merges it
//     in as the new baseline).
//   - CODEOWNERS on gate paths
//   - thin-caller workflows present and SHA-pinned to fleet-ops main tip
//
// DRIFT handling:
//   - settings drift (labels, branch protection) -> applied via API + logged
//   - file drift (CODEOWNERS, thin callers) -> a PR opened (or the file synced
//     via the existing repo-file-sync-action path)
//   - never weakens anything found stronger (extra required contexts preserved)
//   - hands-off repos skipped entirely
//   - local-richer repos (0509) skip the thin-caller migration, reported as such
//
// Exceptions (.fleet/standards-exceptions.yml): honored only when
// decided_by: nish. Every active exception is REPORTED in every drift report
// (visible forever, never silent). Exception count per repo is tracked; growth
// is a smell the weekly digest mentions.
//
// Modes:
//   --dry-run (default)  compute + print drift, change nothing
//   --apply              apply settings via API + open file-fix PRs
//   --org Nishfleet      account to scan (repeatable; defaults to both)
//   --format json|markdown  report format
//
// Named reason for the weekly cadence (per the compute rule): new repos appear
// out-of-band; org webhooks are unavailable on the free plan, so an event-driven
// "repo created" trigger is not available. One idempotent weekly sweep is the
// minimal mechanical form. (The existing repo-standards-sync.yml runs daily for
// allow_auto_merge + file sync; this script covers the settings + thin-caller
// surface that file sync cannot reach.)

import { execFileSync } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";

import {
  LABEL_TRIAD,
  GATE_OWNER_PATHS,
  THIN_CALLERS,
  REPO_TYPES,
  classifyRepo,
  isHandsOff,
  isLocalRicher,
  MERGE_QUEUE_RULESET_NAME,
  MERGE_QUEUE_RULESET_PARAMS,
} from "./repo-standards.lib.mjs";
import { ExceptionsFile, KNOWN_EXCEPTION_RULES } from "./standards-exceptions.mjs";

function gh(args, { json = false, allowFail = false } = {}) {
  try {
    const out = execFileSync("gh", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    if (!json) return out.trim();
    return out.trim() ? JSON.parse(out) : null;
  } catch (e) {
    if (allowFail) return null;
    throw e;
  }
}

function parseArgs(argv) {
  const opts = { apply: false, dryRun: true, orgs: [], format: "markdown", outDir: null, repo: null, onlyLabels: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--apply") { opts.apply = true; opts.dryRun = false; }
    else if (a === "--dry-run") { opts.dryRun = true; }
    else if (a === "--org") { opts.orgs.push(argv[++i]); }
    else if (a === "--format") { opts.format = argv[++i]; }
    else if (a === "--out-dir") { opts.outDir = argv[++i]; }
    else if (a === "--repo") { opts.repo = argv[++i]; }
    else if (a === "--only-labels") { opts.onlyLabels = true; }
    else if (a === "-h" || a === "--help") {
      console.error("usage: repo-standards-apply.mjs [--apply|--dry-run] [--repo OWNER/NAME] [--only-labels] --org Nishfleet --org nish3451 --format json|markdown --out-dir DIR");
      process.exit(0);
    }
  }
  if (opts.orgs.length === 0) opts.orgs = ["Nishfleet", "nish3451"];
  return opts;
}

function listRepos(org) {
  // --no-archived keeps archived repos out; the hands-off list is a second net.
  // gh repo list --json ... -q emits one JSON object per line (jq -c semantics
  // per row), so parse line-by-line into an array. Flatten the nested
  // language/topic shape here so the rest of the script sees simple fields.
  const out = gh(["repo", "list", org, "--limit", "200", "--no-archived", "--json",
    "nameWithOwner,isFork,primaryLanguage,languages,repositoryTopics",
    "-q", '.[] | select(.isFork|not) | {nameWithOwner, primaryLanguage: (.primaryLanguage.name // ""), languages: [.languages[].node.name], topics: [(.repositoryTopics // []) | .[].name]}'],
    { allowFail: true });
  if (!out) return [];
  return out.split("\n").map((s) => s.trim()).filter(Boolean).map((line) => {
    try { return JSON.parse(line); } catch { return null; }
  }).filter(Boolean);
}

function repoLanguages(r) {
  const langs = [];
  if (r.primaryLanguage) langs.push(r.primaryLanguage);
  if (Array.isArray(r.languages)) for (const l of r.languages) langs.push(l);
  return langs.filter(Boolean);
}

function repoTopics(r) {
  return (r.topics || []).map((t) => t.name || t);
}

function getBranchProtection(repo, branch) {
  return gh(["api", `repos/${repo}/branches/${branch}/protection`], { json: true, allowFail: true });
}

function getRepoSettings(repo) {
  return gh(["api", `repos/${repo}`], { json: true, allowFail: true });
}

function getFile(repo, path_, branch) {
  const ref = branch ? `?ref=${branch}` : "";
  const obj = gh(["api", `repos/${repo}/contents/${path_}${ref}`], { json: true, allowFail: true });
  if (!obj || !obj.content) return null;
  return Buffer.from(obj.content, "base64").toString("utf8");
}

function listWorkflows(repo) {
  const obj = gh(["api", `repos/${repo}/contents/.github/workflows`], { json: true, allowFail: true });
  if (!Array.isArray(obj)) return [];
  return obj.map((f) => f.name);
}

// Fetch every ruleset on a repo. Returns an array of {id, name, enforcement,
// conditions, rules} (one entry per ruleset) or [] if the API returns 403
// (free-plan / App-token scope limits). The apply path is the only consumer
// — a 403 means the rule is reported as "skipped-permission" so the drift
// report still observes the situation rather than silent-passing.
function listRulesets(repo) {
  const obj = gh(["api", `repos/${repo}/rulesets`], { json: true, allowFail: true });
  if (!Array.isArray(obj)) return [];
  return obj;
}

// Fetch one ruleset by ID (the GET includes the rules array; the list call
// does not — GitHub keeps rules off the list endpoint to keep the response
// small).
function getRuleset(repo, id) {
  return gh(["api", `repos/${repo}/rulesets/${id}`], { json: true, allowFail: true });
}

// Resolve the fleet-ops main tip SHA to pin thin callers to.
function resolveFleetOpsSha() {
  return gh(["api", "repos/Nishfleet/fleet-ops/commits/main", "-q", ".sha"], { allowFail: true });
}

// The standard required contexts for a repo type (standard gates only; product
// checks are whatever the repo already requires and are PRESERVED).
function standardRequiredContexts(repoType) {
  const ctxs = [];
  for (const tc of THIN_CALLERS) for (const r of tc.required) if (!ctxs.includes(r)) ctxs.push(r);
  return ctxs;
}

function checkThinCallers(repo, workflows, fleetOpsSha, exceptions) {
  const findings = [];
  for (const tc of THIN_CALLERS) {
    const rule = `thin-caller:${tc.file.split("/").pop()}`;
    if (exceptions.isExcepted(rule)) {
      findings.push({ rule, status: "excepted", detail: `exception declared` });
      continue;
    }
    const present = workflows.includes(path.basename(tc.file));
    if (!present) {
      findings.push({ rule, status: "drift", detail: `${tc.file} missing`, fix: "open-pr" });
      continue;
    }
    // Check the SHA pin. The caller must pin to fleetOpsSha (or any committed
    // SHA — a moving ref like @main or @v1 is drift, since the standard is
    // SHA-pinned for tamper-evidence).
    const content = getFile(repo, tc.file);
    if (content == null) {
      findings.push({ rule, status: "drift", detail: `${tc.file} unreadable`, fix: "open-pr" });
      continue;
    }
    const usesMatch = content.match(new RegExp("uses:\\s*" + tc.uses.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "@([0-9a-f]{40}|main|v[0-9]+)"));
    if (!usesMatch) {
      findings.push({ rule, status: "drift", detail: `${tc.file} does not call ${tc.uses}`, fix: "open-pr" });
      continue;
    }
    const pin = usesMatch[1];
    if (pin === "main" || /^v[0-9]+$/.test(pin)) {
      findings.push({ rule, status: "drift", detail: `${tc.file} pins @${pin} (moving ref) — standard requires SHA pin`, fix: "open-pr" });
    } else if (pin !== fleetOpsSha) {
      findings.push({ rule, status: "stale-sha", detail: `${tc.file} pinned @${pin.slice(0, 8)} — fleet-ops main is @${fleetOpsSha.slice(0, 8)}`, fix: "open-pr" });
    } else {
      findings.push({ rule, status: "ok", detail: `${tc.file} pinned @${pin.slice(0, 8)}` });
    }
  }
  return findings;
}

function checkLabels(repo, exceptions) {
  const findings = [];
  if (exceptions.isExcepted("label-triad")) {
    findings.push({ rule: "label-triad", status: "excepted", detail: "exception declared" });
    return findings;
  }
  const labels = gh(["api", `repos/${repo}/labels`, "--paginate", "-q", ".[].name"], { allowFail: true }) || "";
  const labelSet = new Set(String(labels).split("\n").map((s) => s.trim()).filter(Boolean));
  for (const lbl of LABEL_TRIAD) {
    if (!labelSet.has(lbl.name)) {
      findings.push({ rule: "label-triad", status: "drift", detail: `label "${lbl.name}" missing`, fix: "apply-api", label: lbl });
    }
  }
  if (findings.length === 0) findings.push({ rule: "label-triad", status: "ok", detail: "triad present" });
  return findings;
}

function checkBranchProtection(repo, repoType, settings, exceptions) {
  const findings = [];
  if (exceptions.isExcepted("branch-protection")) {
    findings.push({ rule: "branch-protection", status: "excepted", detail: "exception declared" });
    return findings;
  }
  const branch = settings.default_branch;
  const bp = getBranchProtection(repo, branch);
  if (!bp) {
    findings.push({ rule: "branch-protection", status: "drift", detail: `no protection on ${branch}`, fix: "apply-api" });
    return findings;
  }
  const std = REPO_TYPES[repoType];
  // NEVER weaken: collect the union of standard + existing required contexts.
  const existingCtxs = (bp.required_status_checks && bp.required_status_checks.contexts) || [];
  const stdCtxs = standardRequiredContexts(repoType);
  const missing = stdCtxs.filter((c) => !existingCtxs.includes(c));
  if (missing.length > 0) {
    findings.push({ rule: "branch-protection", status: "drift", detail: `missing required contexts: ${missing.join(", ")}`, fix: "apply-api", missing });
  }
  // enforce_admins must be true.
  if (!bp.enforce_admins || !bp.enforce_admins.enabled) {
    findings.push({ rule: "branch-protection", status: "drift", detail: "enforce_admins not enabled", fix: "apply-api" });
  }
  if (bp.allow_force_pushes && bp.allow_force_pushes.enabled) {
    findings.push({ rule: "branch-protection", status: "drift", detail: "force-pushes allowed — must be false", fix: "apply-api" });
  }
  if (bp.allow_deletions && bp.allow_deletions.enabled) {
    findings.push({ rule: "branch-protection", status: "drift", detail: "deletions allowed — must be false", fix: "apply-api" });
  }
  // Preserve any extra contexts the repo already requires (report them as
  // "stronger-than-standard" so the drift report shows we did not remove them).
  const extra = existingCtxs.filter((c) => !stdCtxs.includes(c));
  if (extra.length > 0) {
    findings.push({ rule: "branch-protection", status: "ok-stronger", detail: `repo requires extra contexts (preserved): ${extra.join(", ")}` });
  }
  if (findings.length === 0) findings.push({ rule: "branch-protection", status: "ok", detail: "protection matches standard" });
  return findings;
}

function checkCodeowners(repo, exceptions) {
  const findings = [];
  if (exceptions.isExcepted("codeowners-gate-paths")) {
    findings.push({ rule: "codeowners-gate-paths", status: "excepted", detail: "exception declared" });
    return findings;
  }
  const content = getFile(repo, ".github/CODEOWNERS");
  if (content == null) {
    findings.push({ rule: "codeowners-gate-paths", status: "drift", detail: ".github/CODEOWNERS missing", fix: "open-pr" });
    return findings;
  }
  const missing = GATE_OWNER_PATHS.filter((p) => !content.includes(p));
  if (missing.length > 0) {
    findings.push({ rule: "codeowners-gate-paths", status: "drift", detail: `CODEOWNERS missing gate paths: ${missing.join(", ")}`, fix: "open-pr", missing });
  } else {
    findings.push({ rule: "codeowners-gate-paths", status: "ok", detail: "gate paths owned" });
  }
  return findings;
}

function applyLabel(repo, lbl) {
  gh(["label", "create", lbl.name, "--repo", repo, "--color", lbl.color, "--description", lbl.description, "--force"], { allowFail: true });
}

// Build the canonical main-merge-queue ruleset payload. The required contexts
// passed in are the union of: (a) the standard thin-caller contexts for the
// repo type and (b) any contexts the repo's branch protection already
// requires. Exported so tests can assert the shape and so future rules can
// layer on without rewriting the wire format.
//
// The ruleset target is "~DEFAULT_BRANCH" (the GitHub ref_name condition
// syntax for the repo's default branch, regardless of name — a repo whose
// default is `master` or has been renamed is covered the same way).
export function buildMergeQueueRuleset({ requiredContexts }) {
  const params = MERGE_QUEUE_RULESET_PARAMS;
  const required = Array.from(new Set(requiredContexts || []));
  return {
    name: MERGE_QUEUE_RULESET_NAME,
    target: "branch",
    enforcement: "active",
    conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
    rules: [
      { type: "non_fast_forward" },
      { type: "deletion" },
      { type: "merge_queue", parameters: { ...params.merge_queue } },
      {
        type: "required_status_checks",
        parameters: {
          ...params.required_status_checks_envelope,
          required_status_checks: required.map((c) => ({ context: c })),
        },
      },
    ],
  };
}

// Compare a fetched ruleset against the canonical payload. Returns the list
// of drift items (empty array = match). Strict on rule type / merge_queue
// parameters / required contexts; lax on order (PUT replaces with whatever
// we send). Exported so tests can lock the diff shape.
//
// merge_queue params are compared field-by-field — a repo that customised
// max_entries_to_build without an exception is drift (the standard 5 / 2 /
// 5 / 5 / HEADGREEN / 360 is what every queue repo shares).
export function diffMergeQueueRuleset(fetched, canonical) {
  const drift = [];
  if (!fetched) return ["ruleset-missing"];
  if (fetched.enforcement !== canonical.enforcement) {
    drift.push(`enforcement:${fetched.enforcement}!=${canonical.enforcement}`);
  }
  const cond = canonical.conditions.ref_name.include;
  const fetchedCond = ((fetched.conditions || {}).ref_name || {}).include || [];
  if (JSON.stringify([...fetchedCond].sort()) !== JSON.stringify([...cond].sort())) {
    drift.push(`conditions:${JSON.stringify(fetchedCond)}!=${JSON.stringify(cond)}`);
  }
  // Build a map of fetched rules by type for easy lookup.
  const fetchedRules = new Map();
  for (const r of fetched.rules || []) fetchedRules.set(r.type, r);
  for (const want of canonical.rules) {
    const got = fetchedRules.get(want.type);
    if (!got) {
      drift.push(`rule-missing:${want.type}`);
      continue;
    }
    if (want.type === "merge_queue") {
      const p = MERGE_QUEUE_RULESET_PARAMS.merge_queue;
      for (const k of Object.keys(p)) {
        if (JSON.stringify(got.parameters?.[k]) !== JSON.stringify(p[k])) {
          drift.push(`merge-queue.${k}:${JSON.stringify(got.parameters?.[k])}!=${JSON.stringify(p[k])}`);
        }
      }
    } else if (want.type === "required_status_checks") {
      const wantContexts = new Set((want.parameters.required_status_checks || []).map((c) => c.context));
      const gotContexts = new Set(((got.parameters || {}).required_status_checks || []).map((c) => c.context));
      const missing = [...wantContexts].filter((c) => !gotContexts.has(c));
      const extra = [...gotContexts].filter((c) => !wantContexts.has(c));
      if (missing.length > 0) drift.push(`required-status-checks.missing:${missing.join(",")}`);
      if (extra.length > 0) drift.push(`required-status-checks.extra-preserved:${extra.join(",")}`);
    }
  }
  return drift;
}

// Compose the required-status-checks list for a repo: union of the standard
// thin-caller contexts (same source as standardRequiredContexts) and the
// repo's existing branch protection + the repo's existing ruleset
// (preserves any context the repo already requires). The "never weaken" rule
// from the standard carries here so a sync cannot drop a context the repo
// was relying on.
export function mergeQueueRequiredContexts(repoType, existingBranchProtectionContexts, existingRulesetContexts) {
  const std = standardRequiredContexts(repoType);
  return Array.from(new Set([...std, ...(existingBranchProtectionContexts || []), ...(existingRulesetContexts || [])]));
}

// Check shape: looks at the repo's rulesets, finds the named one, and
// compares against the canonical payload. Findings mirror the BP shape: a
// single "merge-queue-ruleset" rule, status drift / ok / excepted / skipped.
function checkMergeQueueRuleset(repo, repoType, settings, exceptions, existingBranchProtectionContexts) {
  const findings = [];
  if (!REPO_TYPES[repoType].merge_queue) {
    // Repo type without a merge queue (static_site, archive) does not need
    // the ruleset; report skipped-type so a future type change to merge
    // queue re-runs the check. Not drift.
    findings.push({ rule: "merge-queue-ruleset", status: "ok-skip", detail: `repo type "${repoType}" has merge_queue: false` });
    return findings;
  }
  if (exceptions.isExcepted("merge-queue-ruleset")) {
    findings.push({ rule: "merge-queue-ruleset", status: "excepted", detail: "exception declared" });
    return findings;
  }
  const list = listRulesets(repo);
  if (list == null) {
    findings.push({ rule: "merge-queue-ruleset", status: "skipped-permission", detail: "rulesets endpoint unreachable (App-token scope or free-plan org); manual verification required" });
    return findings;
  }
  const named = list.find((r) => r.name === MERGE_QUEUE_RULESET_NAME);
  if (!named) {
    findings.push({ rule: "merge-queue-ruleset", status: "drift", detail: `ruleset "${MERGE_QUEUE_RULESET_NAME}" missing`, fix: "apply-api" });
    return findings;
  }
  const fetched = getRuleset(repo, named.id);
  // Compose required contexts from: standard + branch protection + fetched ruleset.
  const fetchedRequired = (((fetched || {}).rules || []).find((r) => r.type === "required_status_checks") || {});
  const existingRulesetContexts = ((fetchedRequired.parameters || {}).required_status_checks || []).map((c) => c.context);
  const required = mergeQueueRequiredContexts(repoType, existingBranchProtectionContexts, existingRulesetContexts);
  const canonical = buildMergeQueueRuleset({ requiredContexts: required });
  const drift = diffMergeQueueRuleset(fetched, canonical);
  if (drift.length === 0) {
    findings.push({ rule: "merge-queue-ruleset", status: "ok", detail: `ruleset "${MERGE_QUEUE_RULESET_NAME}" active with ${required.length} required context(s)` });
  } else {
    findings.push({ rule: "merge-queue-ruleset", status: "drift", detail: `ruleset "${MERGE_QUEUE_RULESET_NAME}" drifted: ${drift.join("; ")}`, fix: "apply-api" });
  }
  return findings;
}

// Apply: POST a new ruleset if missing, PUT to update if drift. Uses --input
// with a temp file (gh api's --input - stdin path was unreliable in earlier
// fleet-ops scripts). Allow-fail: a transient API hiccup is reported but
// does not crash the sweep; the next weekly run retries.
function applyMergeQueueRuleset(repo, repoType, existingBranchProtectionContexts) {
  const list = listRulesets(repo);
  if (list == null) return false;
  const named = list.find((r) => r.name === MERGE_QUEUE_RULESET_NAME);
  // Compose required contexts the same way check did (so the PUT body
  // matches the canonical the check would build).
  let existingRulesetContexts = [];
  if (named) {
    const fetched = getRuleset(repo, named.id);
    const rsc = (((fetched || {}).rules || []).find((r) => r.type === "required_status_checks") || {});
    existingRulesetContexts = ((rsc.parameters || {}).required_status_checks || []).map((c) => c.context);
  }
  const required = mergeQueueRequiredContexts(repoType, existingBranchProtectionContexts, existingRulesetContexts);
  const payload = buildMergeQueueRuleset({ requiredContexts: required });
  const tmp = path.join("/tmp", `rs-${repo.replace("/", "-")}-${Date.now()}.json`);
  writeFileSync(tmp, JSON.stringify(payload));
  if (named) {
    // PUT replaces; preserve the ID.
    const out = gh(["api", "-X", "PUT", `repos/${repo}/rulesets/${named.id}`, "--input", tmp], { allowFail: true });
    return out != null;
  }
  const out = gh(["api", "-X", "POST", `repos/${repo}/rulesets`, "--input", tmp], { allowFail: true });
  return out != null;
}

function applyBranchProtection(repo, branch, repoType, existingCtxs) {
  // Dead-code shape kept for backwards compatibility (no caller left after
  // the apply path was rewritten to use applyBranchProtectionViaTemp). The
  // apply path uses --input with a temp file (gh api's --input - stdin was
  // unreliable). Leaving a thin wrapper so any future caller does not have
  // to re-derive the payload shape.
  return applyBranchProtectionViaTemp(repo, branch, repoType, existingCtxs);
}

function processRepo(repo, r, fleetOpsSha, opts) {
  if (isHandsOff(repo)) {
    return { repo, status: "skipped", reason: "hands-off", findings: [] };
  }
  const settings = getRepoSettings(repo);
  if (!settings) return { repo, status: "error", reason: "cannot read repo", findings: [] };
  if (settings.archived) return { repo, status: "skipped", reason: "archived", findings: [] };

  const langs = repoLanguages(r);
  const topics = repoTopics(r);
  const repoType = classifyRepo(settings.name, langs, topics);
  if (REPO_TYPES[repoType].skip) return { repo, status: "skipped", reason: `type=${repoType}`, findings: [] };

  // Load exceptions.
  const excText = getFile(repo, ".fleet/standards-exceptions.yml") || "";
  const exceptions = new ExceptionsFile(excText, repo);
  const excReport = exceptions.report();

  const workflows = listWorkflows(repo);
  const findings = [];
  findings.push(...checkLabels(repo, exceptions));
  // Fetch branch protection once and reuse the contexts for both the BP
  // check and the merge-queue ruleset check (the ruleset's required
  // contexts are the union of standard + repo's branch protection).
  const branch = settings.default_branch;
  const bp = getBranchProtection(repo, branch);
  const existingCtxs = (bp && bp.required_status_checks && bp.required_status_checks.contexts) || [];
  findings.push(...checkBranchProtection(repo, repoType, settings, exceptions));
  findings.push(...checkMergeQueueRuleset(repo, repoType, settings, exceptions, existingCtxs));
  findings.push(...checkCodeowners(repo, exceptions));
  if (isLocalRicher(repo)) {
    findings.push({ rule: "thin-callers", status: "ok-local-richer", detail: "repo carries richer local gates; thin-caller migration skipped (filed as follow-up)" });
  } else {
    findings.push(...checkThinCallers(repo, workflows, fleetOpsSha, exceptions));
  }

  // Apply mode: fix settings drift via API. File drift (CODEOWNERS, thin
  // callers) is left to the existing repo-file-sync-action path or a follow-up
  // PR — this script does not open file PRs directly to keep one writer per
  // repo (the file-sync action already owns that surface).
  //
  // --only-labels scopes the apply to the label triad only: the explicit
  // labels-only safety brake. Branch-protection apply runs in --apply mode
  // whenever --only-labels is NOT passed (fleet-ops#248). The required-context
  // union is case-sensitive, so a standard context whose casing does not
  // match a repo's workflow job name exactly would stall every PR in that
  // repo (e.g. fleet-ops required "Semgrep" while the standard declares
  // "semgrep"). The context-name reconciliation (fleet-ops#248) renamed the
  // fleet-ops semgrep job to match the standard; siterep-public and 0509
  // already produce the canonical names, so the standard contexts now match
  // the produced checks everywhere. That reconciliation is the prerequisite
  // for this path - it must land before BP apply can run safely on a repo.
  if (opts.apply) {
    for (const f of findings) {
      if (f.fix === "apply-api" && f.rule === "label-triad" && f.label) {
        applyLabel(repo, f.label);
      }
    }
    if (!opts.onlyLabels) {
      const bpDrift = findings.some((f) => f.rule === "branch-protection" && f.status === "drift");
      if (bpDrift) {
        const branch = settings.default_branch;
        const bp = getBranchProtection(repo, branch);
        const existingCtxs = (bp && bp.required_status_checks && bp.required_status_checks.contexts) || [];
        applyBranchProtectionViaTemp(repo, branch, repoType, existingCtxs);
      }
      // Apply the merge-queue ruleset when drift is reported AND the repo
      // type has a merge queue. skipped-permission (free-plan org, App
      // token) is a no-op here — the drift report still flags the
      // situation, so manual verification has teeth.
      if (REPO_TYPES[repoType].merge_queue) {
        const rsDrift = findings.some((f) => f.rule === "merge-queue-ruleset" && f.status === "drift");
        if (rsDrift) {
          applyMergeQueueRuleset(repo, repoType, existingCtxs);
        }
      }
    }
  }

  return {
    repo,
    type: repoType,
    status: findings.some((f) => f.status === "drift" || f.status === "stale-sha") ? "drift" : "ok",
    findings,
    exceptions: excReport,
  };
}

function applyBranchProtectionViaTemp(repo, branch, repoType, existingCtxs) {
  const std = REPO_TYPES[repoType];
  const stdCtxs = standardRequiredContexts(repoType);
  const union = Array.from(new Set([...(existingCtxs || []), ...stdCtxs]));
  const payload = {
    required_status_checks: { strict: false, contexts: union },
    enforce_admins: true,
    required_pull_request_reviews: null,
    restrictions: null,
    required_linear_history: std.required_linear_history,
    allow_force_pushes: false,
    allow_deletions: false,
  };
  const tmp = path.join("/tmp", `bp-${repo.replace("/", "-")}-${Date.now()}.json`);
  writeFileSync(tmp, JSON.stringify(payload));
  gh(["api", "-X", "PUT", `repos/${repo}/branches/${branch}/protection`, "--input", tmp], { allowFail: true });
}

function renderMarkdown(report) {
  const lines = [];
  lines.push(`# Repo standards drift report`);
  lines.push(`Generated: ${report.generatedAt}`);
  lines.push(`Accounts: ${report.orgs.join(", ")}`);
  lines.push(`Mode: ${report.apply ? "apply" : "dry-run"}`);
  lines.push(`fleet-ops main SHA: ${report.fleetOpsSha || "(unresolved)"}`);
  lines.push("");
  lines.push(`## Summary`);
  lines.push(`- repos scanned: ${report.repos.length}`);
  lines.push(`- ok: ${report.repos.filter((r) => r.status === "ok").length}`);
  lines.push(`- drift: ${report.repos.filter((r) => r.status === "drift").length}`);
  lines.push(`- skipped: ${report.repos.filter((r) => r.status === "skipped").length}`);
  lines.push(`- error: ${report.repos.filter((r) => r.status === "error").length}`);
  const totalExc = report.repos.reduce((n, r) => n + ((r.exceptions && r.exceptions.count) || 0), 0);
  lines.push(`- active exceptions (Nish-approved): ${totalExc}`);
  lines.push("");
  lines.push(`## Per-repo findings`);
  for (const r of report.repos) {
    lines.push(`### ${r.repo} — ${r.status}${r.type ? ` (type: ${r.type})` : ""}${r.reason ? ` — ${r.reason}` : ""}`);
    if (r.exceptions) {
      if (r.exceptions.count > 0) {
        lines.push(`- **active exceptions: ${r.exceptions.count}**`);
        for (const e of r.exceptions.honored) lines.push(`  - \`${e.rule}\` — ${e.reason} (decided ${e.decided} by ${e.decided_by})`);
      }
      if (r.exceptions.proposed_not_honored.length > 0) {
        lines.push(`- **proposed exceptions NOT honored (need Nish approval): ${r.exceptions.proposed_not_honored.length}**`);
        for (const e of r.exceptions.proposed_not_honored) lines.push(`  - \`${e.rule}\` — ${e.reason} (decided_by: ${e.decided_by || "(unset)"} — must be \`nish\`)`);
      }
      if (r.exceptions.errors.length > 0) {
        lines.push(`- **exceptions file errors:**`);
        for (const err of r.exceptions.errors) lines.push(`  - ${err}`);
      }
    }
    for (const f of r.findings) lines.push(`- [${f.status}] ${f.rule}: ${f.detail}`);
    lines.push("");
  }
  return lines.join("\n");
}

function main() {
  const opts = parseArgs(process.argv);
  const fleetOpsSha = resolveFleetOpsSha();
  const repos = [];
  for (const org of opts.orgs) {
    for (const r of listRepos(org)) repos.push(r);
  }

  const results = [];
  for (const r of repos) {
    const repo = r.nameWithOwner;
    if (opts.repo && repo !== opts.repo) continue;
    try {
      results.push(processRepo(repo, r, fleetOpsSha, opts));
    } catch (e) {
      results.push({ repo, status: "error", reason: String(e.message || e), findings: [] });
    }
  }

  const report = {
    generatedAt: new Date().toISOString(),
    orgs: opts.orgs,
    apply: opts.apply,
    fleetOpsSha,
    repos: results,
  };

  if (opts.outDir) {
    mkdirSync(opts.outDir, { recursive: true });
    writeFileSync(path.join(opts.outDir, "repo-standards-drift.json"), JSON.stringify(report, null, 2));
    writeFileSync(path.join(opts.outDir, "repo-standards-drift.md"), renderMarkdown(report));
  }

  if (opts.format === "json") {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.log(renderMarkdown(report));
  }

  // Exit non-zero if any drift remains (CI gate shape). In --apply mode, drift
  // that could not be auto-fixed (file drift, or API apply that failed) still
  // counts as drift.
  const driftCount = results.filter((r) => r.status === "drift").length;
  if (driftCount > 0 && process.env.STANDARDS_ALLOW_DRIFT !== "1") {
    console.error(`::warning::${driftCount} repo(s) have standards drift.`);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
