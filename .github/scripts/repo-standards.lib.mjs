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
export const LOCAL_RICHER = [
  "Nishfleet/0509", // hardened required-verifier-integrity + gate-integrity + sole-admin attestation
];

export function isHandsOff(repo) {
  return HANDS_OFF.includes(repo);
}

export function isLocalRicher(repo) {
  return LOCAL_RICHER.includes(repo);
}
