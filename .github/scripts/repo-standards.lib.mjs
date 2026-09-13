// repo-standards.lib.mjs — the declarative Nishfleet/nish3451 repo standard.
//
// This is the single source of truth for what "a repo meeting the fleet
// standard" means: labels, branch protection, CODEOWNERS on gate paths, merge
// queue triggers, and which thin-caller workflows must be present and SHA-pinned
// to fleet-ops. The sync script (repo-standards-apply.mjs) reads this and is
// mechanical; the standard itself lives here so a rule change is one edit, not
// a script rewrite.
//
// Repo types: different repos carry different required contexts and protection.
// A repo is classified by `classifyRepo(name, language, topics)` below. The
// standard is per-type so a docs repo is not held to a node-app's checks.
//
// Exceptions: a repo may carry `.fleet/standards-exceptions.yml` declaring
// specific deviations (rule/reason/decided/decided_by). Only
// `decided_by: nish` exceptions are honored. The sync skips an excepted rule
// at that repo and REPORTS the exception in every drift report (visible
// forever, never silent). Exception count per repo is tracked — growth is a
// smell the weekly digest mentions. Any undeclared deviation is drift to repair.

// The label triad every repo gets. review:deep is the rationed-review trigger
// (reusable-review-gate.yml); no-auto-merge opts a PR out of auto-enqueue;
// fleet:standards is the marker that this repo is enrolled in the standard.
export const LABEL_TRIAD = [
  { name: "review:deep", color: "B60205", description: "High-risk diff: spend a rationed AI review here" },
  { name: "no-auto-merge", color: "BFD4F2", description: "Opt this PR out of auto-enqueue / auto-merge" },
  { name: "fleet:standards", color: "0E8A16", description: "Repo is enrolled in the Nishfleet repo standard" },
];

// Gate paths that CODEOWNERS must protect so a worker PR cannot edit the check
// judging it. The owner is the repo admin (Nish) — the only identity workers
// do not hold. Until a second admin exists, CODEOWNERS is an audit trail, not
// an authorization boundary, but it still makes a gate edit a visible review.
export const GATE_OWNER_PATHS = [
  ".github/workflows/",
  ".github/scripts/",
  ".github/CODEOWNERS",
  ".gitleaksignore",
  ".gitleaks.toml",
  ".semgrepignore",
  ".semgrep.yml",
  ".semgrep.yaml",
];

// The thin-caller workflows every enrolled repo must carry, pinned by SHA to
// fleet-ops. `sha` is updated by the sync; a repo whose caller pins a stale or
// missing SHA is drift. `required` names the status context branch protection
// must require (empty = advisory only).
//
// NOTE: gate-integrity is intentionally NOT here. Its decision logic is
// repo-specific (gate globs, auto-revert waiver, design-ratchet clauses) and
// cannot be made a thin caller without generalizing the 587-line decision
// script — tracked as a follow-up issue. Repos that need it keep a local copy.
export const THIN_CALLERS = [
  {
    file: ".github/workflows/secret-scan.yml",
    uses: "Nishfleet/fleet-ops/.github/workflows/reusable-gitleaks.yml",
    // sha is filled in at runtime from the latest fleet-ops main tip the sync
    // resolves; a repo pinned to a stale sha is drift.
    required: ["Gitleaks"],
  },
  {
    file: ".github/workflows/semgrep.yml",
    uses: "Nishfleet/fleet-ops/.github/workflows/reusable-semgrep.yml",
    required: ["semgrep"],
  },
  {
    file: ".github/workflows/review-gate.yml",
    uses: "Nishfleet/fleet-ops/.github/workflows/reusable-review-gate.yml",
    required: [], // advisory: labels PRs, does not gate merge
  },
  {
    file: ".github/workflows/auto-enqueue.yml",
    uses: "Nishfleet/fleet-ops/.github/workflows/reusable-auto-enqueue.yml",
    required: [], // advisory: arms queue, does not gate merge
  },
];

// Merge-queue ruleset shape applied to every enrolled repo whose repo type
// has `merge_queue: true` and that does NOT already carry an equivalent ruleset
// (fleet-ops#5787). The 0509 ruleset (id 21391031, "main-merge-queue") is the
// shape every other repo gets — GitHub serialises PRs into merge_group runs
// against latest main + queued entries, the same defence the orchestrator
// packet prose was trying to provide. Five rules in order:
//
//   1. non_fast_forward: no force-push to main (matches the legacy branch-
//      protection `allow_force_pushes.enabled=false`)
//   2. deletion: no branch deletion from main
//   3. merge_queue: HEADGREEN grouping, max 5 in-flight, group on 2 or 5 min
//      wait, 6h check timeout. Matches 0509 verbatim so a queue PR that works
//      there works everywhere.
//   4. required_status_checks: the union of the standard gates for the repo
//      type + whatever the repo's branch protection already required (NEVER
//      weakens — a repo that requires MORE contexts keeps them). Populated
//      at apply time; this constant only carries the envelope so tests can
//      assert the shape.
//
// The ruleset target is `~DEFAULT_BRANCH` (enforced via GitHub's ref_name
// condition, not `main`, so a repo whose default is `master` or has been
// renamed is covered). `enforcement: active` so the ruleset binds.
//
// Rule name (`main-merge-queue`) and the existence of this ruleset on every
// enrolled repo with merge_queue: true is what the acceptance check
// `gh api repos/Nishfleet/<repo>/rulesets` reports. The apply logic creates
// or updates (PUT, never DELETEs a stronger shape) and reports drift on:
//   - missing ruleset
//   - wrong enforcement (e.g. disabled)
//   - missing rules
//   - wrong required_status_checks (missing context, removed context)
//   - any rule field deviating from MERGE_QUEUE_RULESET_PARAMS
//
// .fleet/standards-exceptions.yml may except a single repo with rule:
// `merge-queue-ruleset` (decided_by: nish). The exception rule ships in
// KNOWN_EXCEPTION_RULES below so the exceptions parser recognises it.
export const MERGE_QUEUE_RULESET_NAME = "main-merge-queue";
export const MERGE_QUEUE_RULESET_PARAMS = {
  merge_queue: {
    merge_method: "MERGE",
    max_entries_to_build: 5,
    min_entries_to_merge: 2,
    max_entries_to_merge: 5,
    min_entries_to_merge_wait_minutes: 5,
    grouping_strategy: "HEADGREEN",
    check_response_timeout_minutes: 360,
  },
  non_fast_forward: null,
  deletion: null,
  required_status_checks_envelope: {
    strict_required_status_checks_policy: false,
    do_not_enforce_on_create: false,
  },
};

// Branch-protection payload per repo type. `required_contexts` is the union of
// the repo's own product checks (passed in) plus the standard gates. The sync
// NEVER weakens: if a repo's live protection requires MORE contexts than the
// standard asks, the extra ones are preserved (never removed).
export const REPO_TYPES = {
  node_app: {
    description: "Node/JS product app with tests",
    required_contexts_extra: [], // product checks are repo-specific; passed in
    enforce_admins: true,
    required_linear_history: false,
    allow_force_pushes: false,
    allow_deletions: false,
    merge_queue: true,
  },
  static_site: {
    description: "Static site / docs / marketing",
    required_contexts_extra: [],
    enforce_admins: true,
    required_linear_history: false,
    allow_force_pushes: false,
    allow_deletions: false,
    merge_queue: false,
  },
  infra: {
    description: "Infra / ops / control plane (fleet-ops, agent-governor, etc.)",
    required_contexts_extra: [],
    enforce_admins: true,
    required_linear_history: false,
    allow_force_pushes: false,
    allow_deletions: false,
    merge_queue: true,
  },
  archive: {
    description: "Archived — skipped entirely",
    skip: true,
  },
};

// Classify a repo into a type. Uses language + name heuristics; the sync can
// also read a `.fleet/repo-type` hint file in the repo. Unknown -> static_site
// (the least-privilege default: no merge queue, standard gates only).
export function classifyRepo(name, languages, topics = []) {
  const lang = (languages || []).map((l) => (l.toLowerCase ? l.toLowerCase() : String(l).toLowerCase()));
  const t = (topics || []).map((x) => String(x).toLowerCase());
  if (lang.includes("typescript") || lang.includes("javascript") || lang.includes("tsx") || lang.includes("jsx")) {
    if (name.includes("fleet-ops") || name.includes("governor") || name.includes("control") || name.includes("tower") || t.includes("infra") || t.includes("ops")) {
      return "infra";
    }
    return "node_app";
  }
  if (name.includes("fleet-ops") || t.includes("infra")) return "infra";
  return "static_site";
}

// Hands-off repos: the sync skips them entirely (never reads settings, never
// opens PRs). These are repos where Nish has reserved manual control. Sourced
// from config/intake-repos.json excluded[] + an explicit hands-off list.
export const HANDS_OFF = [
  "Nishfleet/fleet2", // experimental second fleet — paused
  "Nishfleet/siterep", // archived
  "nish3451/BabyStoryApp", // archived
  "nish3451/VibecodedProjects", // archived
  "nish3451/Drishti-Mindful-Screen-Time", // archived
  "nish3451/Promptly", // archived
  "nish3451/HotelDealsApp", // archived
  "nish3451/vibecoded-projects-scripts", // archived
  "nish3451/fleet-bootstrap-drill", // archived
  "nish3451/openclaw-workflows", // archived
];

// Repos that already carry a richer local gate that the standard must NOT
// overwrite (e.g. 0509's hardened secret-scan.yml with its sole-admin
// attestation path). The sync reports these as "local-richer" and skips the
// thin-caller migration for that file, filing no PR.
//
// fleet-ops is local-richer because it runs Gitleaks+Semgrep folded into the
// batched "P14 tests" caller in its own ci.yml (scan-secrets: true) and owns
// extra gates (gate-integrity, mass-close-guard). Requiring the four thin
// callers would demand four new runner files where the gates already run
// natively — that is fleet-ops#4590's judge ruling (2026-09-09): no new
// organs, retarget the drift canary instead.
//
// NOTE (fleet-ops#4590): this quirk is fleet-ops-specific. Consumer repos
// outside LOCAL_RICHER still MUST carry the thin callers; only repos that
// already produce the gates through a richer local path are exempt.
export const LOCAL_RICHER = [
  "Nishfleet/0509", // hardened required-verifier-integrity + gate-integrity + sole-admin attestation
  "Nishfleet/fleet-ops", // gates folded into ci.yml "P14 tests" (scan-secrets: true) + extra local gates
];

export function isHandsOff(repo) {
  return HANDS_OFF.includes(repo);
}

export function isLocalRicher(repo) {
  return LOCAL_RICHER.includes(repo);
}
