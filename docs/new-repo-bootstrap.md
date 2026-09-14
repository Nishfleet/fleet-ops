# New-repo bootstrap — full gates in one command

The fleet standard (labels, branch protection, merge-queue ruleset,
CODEOWNERS on gate paths, SHA-pinned thin-caller workflows) is enforced by
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
5. **creates the `main-merge-queue` ruleset** on the default branch (see
   *Merge-queue ruleset* below) when the repo type has a merge queue,
6. reports CODEOWNERS gate-path coverage and SHA-current thin callers (file
   drift is left to the file-sync action / a follow-up PR — one writer per
   repo),
7. honors any `.fleet/standards-exceptions.yml` (only `decided_by: nish`), and
   reports every active exception.

## What a new repo gets

| Gate | Reusable workflow in fleet-ops | Required context |
|---|---|---|
| Secret scan | `reusable-gitleaks.yml` | `Gitleaks` |
| Semgrep canonical gate | `reusable-semgrep.yml` | `semgrep` |
| Review gate (budget backpressure) | `reusable-review-gate.yml` | advisory (labels PRs) |
| Auto-enqueue green PRs | `reusable-auto-enqueue.yml` | advisory (arms queue) |
| **Merge queue (ruleset)** | `main-merge-queue` ruleset | HEADGREEN / max-5 build / min-2 entries or 5 min wait / 6 h check timeout |

The thin-caller workflows in the new repo are SHA-pinned to the fleet-ops main
tip at enroll time. The weekly sync keeps them current; a repo whose caller
pins a stale or moving ref (`@main`, `@v1`) is drift and gets a follow-up PR.

## Merge-queue ruleset (fleet-ops#5787)

Repos whose repo type carries `merge_queue: true` (today: `node_app`,
`infra`) get a `main-merge-queue` ruleset on the default branch. The
ruleset:

- blocks force-pushes to the default branch (`non_fast_forward`),
- blocks branch deletion from the default branch (`deletion`),
- routes every pull_request through GitHub's merge queue with
  `grouping_strategy: HEADGREEN`, `max_entries_to_build: 5`,
  `min_entries_to_merge: 2`, `min_entries_to_merge_wait_minutes: 5`,
  `check_response_timeout_minutes: 360` — matches 0509 (ruleset id
  21391031) verbatim, so a queued PR that works there works everywhere,
- requires every status check the repo's branch protection already required
  + the standard thin-caller contexts (the same union the BP apply uses —
  never weakens an extra context the repo was relying on).

The ruleset target is `~DEFAULT_BRANCH` (GitHub's ref_name condition),
so a repo whose default branch is `master` or has been renamed is
covered without a script edit.

Apply is idempotent: a weekly sweep that finds no drift makes no API
calls. A repo that already carries a stricter ruleset (extra rules, extra
required contexts) is reported as `required-status-checks.extra-preserved`
in the drift report — the apply path PUTs the canonical, which preserves
the extra contexts in the next sweep's baseline.

Acceptance check (the issue's `#5787` accept criterion):

```bash
gh api repos/Nishfleet/<repo>/rulesets
```

shows the `main-merge-queue` ruleset active on every enrolled repo.

## Exceptions

If a new repo legitimately cannot meet a standard rule (e.g. a docs repo with
no JS does not need semgrep, or a repo cannot tolerate the merge queue), add
`.fleet/standards-exceptions.yml`:

```yaml
- rule: thin-caller:semgrep.yml
  reason: "repo has no JS; semgrep not applicable"
  decided: "2026-08-26"
  decided_by: nish
- rule: merge-queue-ruleset
  reason: "docs repo; merge queue overhead not worth it"
  decided: "2026-09-12"
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
- **Org-level rulesets with `*` pattern** — bound every repo at creation.
  Skipped on the free plan (Nishfleet is on free); would replace the
  per-repo ruleset work above with a one-line apply the day Nishfleet
  upgrades to Team. See `org-ruleset-skip-detector.mjs` + docs/ci-standard.md.
