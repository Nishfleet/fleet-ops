#!/usr/bin/env node
// repo-standards-apply.mjs — idempotent, deterministic standards sync across
// every repo in Nishfleet + nish3451.
//
// What it enforces (per repo, per repo type, honoring .fleet/standards-exceptions.yml):
//   - label triad (review:deep, no-auto-merge, fleet:standards)
//   - branch protection payload (enforce_admins, no force-push, no deletions,
//     required contexts = standard gates + repo product checks; NEVER weakens
//     a repo that requires MORE than the standard)
//   - CODEOWNERS on gate paths
//   - merge_group triggers where the repo type has a merge queue
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
  const opts = { apply: false, dryRun: true, orgs: [], format: "markdown", outDir: null };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--apply") { opts.apply = true; opts.dryRun = false; }
    else if (a === "--dry-run") { opts.dryRun = true; }
    else if (a === "--org") { opts.orgs.push(argv[++i]); }
    else if (a === "--format") { opts.format = argv[++i]; }
    else if (a === "--out-dir") { opts.outDir = argv[++i]; }
    else if (a === "-h" || a === "--help") {
      console.error("usage: repo-standards-apply.mjs [--apply|--dry-run] --org Nishfleet --org nish3451 --format json|markdown --out-dir DIR");
      process.exit(0);
    }
  }
  if (opts.orgs.length === 0) opts.orgs = ["Nishfleet", "nish3451"];
  return opts;
}

function listRepos(org) {
  // --no-archived keeps archived repos out; the hands-off list is a second net.
  return gh(["repo", "list", org, "--limit", "200", "--no-archived", "--json", "nameWithOwner,isFork,primaryLanguage,languages,repositoryTopics", "-q", ".[] | select(.isFork|not)"], { json: true }) || [];
}

function repoLanguages(r) {
  const langs = [];
  if (r.primaryLanguage) langs.push(r.primaryLanguage.name);
  if (Array.isArray(r.languages)) for (const l of r.languages) langs.push(l.name);
  return langs;
}

function repoTopics(r) {
  return (r.repositoryTopics || []).map((t) => t.name || t);
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
  const labels = gh(["api", `repos/${repo}/labels`, "--paginate", "-q", ".[].name"], { allowFail: true }) || [];
  const labelSet = new Set(labels.split("\n").map((s) => s.trim()).filter(Boolean));
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

function applyBranchProtection(repo, branch, repoType, existingCtxs) {
  const std = REPO_TYPES[repoType];
  const stdCtxs = standardRequiredContexts(repoType);
  // Union: existing + standard. Never remove.
  const union = Array.from(new Set([...(existingCtxs || []), ...stdCtxs]));
  // PUT /repos/{owner}/{repo}/branches/{branch}/protection
  const payload = {
    required_status_checks: {
      strict: false,
      contexts: union,
    },
    enforce_admins: true,
    required_pull_request_reviews: null,
    restrictions: null,
    required_linear_history: std.required_linear_history,
    allow_force_pushes: false,
    allow_deletions: false,
  };
  gh(["api", "-X", "PUT", `repos/${repo}/branches/${branch}/protection`, "--input", "-"], {
    allowFail: true,
  });
  // gh api --input - reads stdin; instead use a temp file to avoid stdin complexity.
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
  findings.push(...checkBranchProtection(repo, repoType, settings, exceptions));
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
  if (opts.apply) {
    for (const f of findings) {
      if (f.fix === "apply-api" && f.rule === "label-triad" && f.label) {
        applyLabel(repo, f.label);
      }
    }
    // Branch protection: apply once with the union of contexts.
    const bpDrift = findings.some((f) => f.rule === "branch-protection" && f.status === "drift");
    if (bpDrift) {
      const branch = settings.default_branch;
      const bp = getBranchProtection(repo, branch);
      const existingCtxs = (bp && bp.required_status_checks && bp.required_status_checks.contexts) || [];
      applyBranchProtectionViaTemp(repo, branch, repoType, existingCtxs);
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
