# New-repo bootstrap — full gates in one command

The fleet standard (labels, branch protection, CODEOWNERS on gate paths,
SHA-pinned thin-caller workflows, merge-queue triggers) is enforced by
`repo-standards-apply.yml`, which sweeps every non-archived repo in Nishfleet
+ nish3451 weekly (Mondays 03:17 UTC). A repo created today is enrolled within
7 days with no manual step.

To enroll a new repo **now** instead of waiting for the weekly sweep:

```bash
# From a fleet-ops checkout, with FLEET_SYNC_PAT exported:
GH_TOKEN="$FLEET_SYNC_PAT" \
  node .github/scripts/repo-standards-apply.mjs \
    --apply --org Nishfleet --org nish3451 --format markdown
```

That single command:
1. discovers every non-archived non-fork repo in both accounts (including the
   one you just created),
2. classifies it by repo type (node_app / infra / static_site) from its
   languages + topics,
3. applies the label triad (`review:deep`, `no-auto-merge`, `fleet:standards`)
   via the API,
4. sets branch protection on the default branch (enforce_admins, no
   force-push, no deletions, required contexts = standard gates + any the repo
   already requires — never weakens),
5. reports CODEOWNERS gate-path coverage and SHA-current thin callers (file
   drift is left to the file-sync action / a follow-up PR — one writer per
   repo),
6. honors any `.fleet/standards-exceptions.yml` (only `decided_by: nish`), and
   reports every active exception.

## What a new repo gets

| Gate | Reusable workflow in fleet-ops | Required context |
|---|---|---|
| Secret scan | `reusable-gitleaks.yml` | `Gitleaks` |
| Semgrep canonical gate | `reusable-semgrep.yml` | `semgrep` |
| Review gate (budget backpressure) | `reusable-review-gate.yml` | advisory (labels PRs) |
| Auto-enqueue green PRs | `reusable-auto-enqueue.yml` | advisory (arms queue) |

The thin-caller workflows in the new repo are SHA-pinned to the fleet-ops main
tip at enroll time. The weekly sync keeps them current; a repo whose caller
pins a stale or moving ref (`@main`, `@v1`) is drift and gets a follow-up PR.

## Exceptions

If a new repo legitimately cannot meet a standard rule (e.g. a docs repo with
no JS does not need semgrep), add `.fleet/standards-exceptions.yml`:

```yaml
- rule: thin-caller:semgrep.yml
  reason: "repo has no JS; semgrep not applicable"
  decided: "2026-08-26"
  decided_by: nish
```

Only `decided_by: nish` exceptions are honored. An agent may PROPOSE one via
PR, but it merges only with Nish's approval label. Every active exception is
reported in every weekly drift report (visible forever, never silent).
Exception count per repo is tracked — growth is a smell the digest mentions.

## What is NOT auto-enrolled

- **gate-integrity** — its decision logic is repo-specific (gate globs,
  auto-revert waiver, design-ratchet clauses) and cannot be a thin caller
  without generalizing the 587-line decision script. Tracked as a follow-up.
  Repos that need it keep a local copy (see 0509).
- **required-verifier-integrity** — same shape, repo-specific verifier list.
  0509 carries a hardened local copy with a sole-admin attestation path.
- **Product checks** (e.g. `codex-node-checks`) — repo-specific; the sync
  preserves whatever the repo already requires and never removes it.
