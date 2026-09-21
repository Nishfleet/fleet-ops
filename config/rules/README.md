# Branch rulesets — committed verification receipts (fleet-ops#6476)

This directory is the durable, in-repo verification receipt for the
branch-ruleset adoption on `Nishfleet/fleet-ops` main that research-delta
#6476 asked for. It carries byte-faithful snapshots of the live branch-rules
API responses plus the metadata needed to re-verify them; the structural pin
lives in `tests/rules-parity.test.sh`.

## Why committed snapshots, not live probes

- Repo settings are Nish-reserved (fleet-ops#7464 item 2/11, 2026-09-17
  orchestrator sweep). Agents do not write rulesets, and there is no dedup
  counteragent to reconcile them — the authorized admin applies changes.
- CI cannot read the live layer at all: the branch-rules endpoints need
  Administration-scoped read, which neither CI's default token nor the
  worker token when run from CI carries. So a PR-time live gate is not
  buildable on this plane; the tests over these snapshots are the only
  reachable in-repo mechanism — the same pattern 0509 uses for
  `tests/required-context-no-skip.test.ts` (0509#3335).
- A scheduled live probe ("alert when the ruleset regresses") is a separate,
  already-filed ask: fleet-ops#7905 (agent-ready). Do not resurrect it here.

## What is recorded (as verified 2026-09-21)

- `fleet-ops-main.json` — `GET /repos/Nishfleet/fleet-ops/rules/branches/main`
  → 4 rules: `non_fast_forward`, `deletion` (the #6476 stage-1 pair, adopted
  2026-09-19 by the authorized admin in the #7844 rules sweep, alongside the
  #5787 adoption), `merge_queue` (SQUASH, HEADGREEN, max 5 build, min 1) and
  `pull_request` (0 required approvals — the worker auto-merge path). The
  sweep went further than stage-1's two context-free rules: the merge queue
  is live, which closes the stage-2 `merge_queue` half of #6476 ahead of
  schedule.
- `0509-main.json` — the parity target named by #6476: 4 rules including
  `required_status_checks` (Gitleaks, codex-node-checks, semgrep,
  preview-assert) and a MERGE-method queue. This file records 0509's FACTUAL
  state; it is not a fleet-ops adoption record.
- Every snapshot carries `payload_sha256` — the SHA-256 of the canonicalized
  `.rules` array (`jq -cS .rules`) as GitHub returned it at
  `verified_at_utc`. `tests/rules-parity.test.sh` re-derives the hash from
  the committed bytes, so an undocumented edit to a snapshot fails the test.

## fleet-ops#5787 live acceptance evidence (verified 2026-09-21)

- Ruleset active on every enrolled repo: `gh api
  repos/Nishfleet/fleet-ops/rulesets` → `main-merge-queue` active (id
  23692529); `repos/Nishfleet/0509/rulesets` → `main-merge-queue` active (id
  21391031). Enrolled set = `config/intake-repos.json` `repos[]` = {0509,
  fleet-ops}; coverage 2/2.
- One live PR per repo merges through the queue with auto-merge only:
  fleet-ops PRs #8023 (cbe95921) and #8024 (3028cd93) on 2026-09-21 show
  `added_to_merge_queue -> merged -> removed_from_merge_queue` in
  `gh api repos/Nishfleet/fleet-ops/issues/<pr>/timeline`; 0509 PR #3901
  (merged 2026-09-21T10:03Z) shows the same sequence. The queue merged each
  with no human dequeue/admin action.
- Stale queued entries: none exist to repair — GraphQL
  `mergeQueue(branch:"main") { entries }` returned `[]` on both repos at
  check time. The `red-pr-repair` machinery this issue named
  (`repair:`-label + `repair-queue-jump.mjs` + heartbeat sweep) was deleted
  in the 2026-09-18/19 glue sweep (#7828) and has no live caller; with zero
  required checks on the fleet-ops side the queue merges each entry
  immediately, so entries cannot stale. Resurrecting a jump path is new
  work under the sweep's terms, not this issue.
- Required-checks residual stays deferred exactly as the stage-2 line below
  records; no context was guessed into a settings change or a snapshot.

## Refresh procedure (worker-token, read-only)

```sh
raw=/tmp/rules-${repo}-main.json
gh api /repos/Nishfleet/${repo}/rules/branches/main > "$raw"   # must exit 0
sha=$(jq -cS . "$raw" | sha256sum | cut -d' ' -f1)
jq --arg sha "$sha" --arg repo "${repo}" '
  {endpoint: ("GET /repos/Nishfleet/" + $repo + "/rules/branches/main"),
   http_status: 200,
   verified_at_utc: ("" | format "2026-…", .),
   rules: .}' "$raw"
```

Then hand-complete `verified_at_utc`, `verified_by`, and `payload_sha256`
from the computed value, keeping the receipts current. Editing a snapshot and
adding/changing a rule type can only make `tests/rules-parity.test.sh` green
by also updating the routing notes below — the pin routes the change through
this record.

# stage-2 residual: required_status_checks — deferred by fleet-ops#6476 itself
("after #3652/#3653 settle — contexts = the consolidation's outcome, not
guessed"). Neither #3652 nor #3653 has landed. Settings writes are
Nish-reserved (fleet-ops#7464 item 2/11), so landing the contexts is an
admin-lane decision, tracked by fleet-ops#5787 (the spec-gated successor that
also carries the possible-duplicate-of header over #6476), #3345, and the
#7905 probe proposal. Do not guess contexts into a snapshot or a settings
change; the pin in `tests/rules-parity.test.sh` fails any snapshot that
arrives with a `required_status_checks` rule on the fleet-ops side before
this line is cleared by the same PR.
