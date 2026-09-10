# Plan — Nishfleet/fleet-ops#5079

Dead-PR detector must never read clean over an uncomputed `mergeable` (`"UNKNOWN"`).
Manager mode (`difficulty: heavy`). Implementer: fresh `worker` per phase; `reviewer` on the phase diff.

Inherited from the prior crashed run of this same unit (`claim/issue-5079`, salvage commit
`8bffe36d6`, which banked only the header comment + env seams). The phase split below is that
run's planner output; the amendment is mine.

## Manager amendments

- 2026-09-11: **phases 1 and 2 merged into ONE worker phase.** The new hermetic case pins the
  exact stdout/stderr/exit-code semantics of the classification change (`rc=1` + `parent-state=CLOSED`
  after a successful re-query, vs `rc=2` on a still-undecided parent-closed PR). Neither half can be
  written or reviewed without the other, so splitting them only produces churn. Phase 3 stays a
  separate verification phase (diff-scope + gate-path check, run by the manager).
- 2026-09-11: `.fleet/plan.md` is a tracked file on `origin/main` that the last manager PR overwrote
  (it currently holds the #5000 plan). Keeping this plan **local, uncommitted** so the PR diff stays
  exactly `bin/fleet-dead-pr-detector` + `tests/fleet-dead-pr-detector.test.sh`, per the issue's
  no-new-organ bullet. The plan is carried in the PR body instead.

## Phases

- [x] phase 1+2: `bin/fleet-dead-pr-detector` — classify anything that is not exactly `MERGEABLE` or
  `CONFLICTING` as *unknown*: count it in the `unknown-mergeable` figure (kill the `mergeable == null`
  -only counter) and keep it in the scan (kill the `select(.mergeable == "CONFLICTING")` drop). For
  each unknown PR re-query `gh pr view <n> -R "$REPO" --json mergeable` up to
  `DEAD_PR_UNKNOWN_ATTEMPTS` (default 3) with `DEAD_PR_UNKNOWN_SLEEP` (default 5s) between; only a
  `MERGEABLE`/`CONFLICTING` answer ends the question. Still unknown -> resolve the parent first:
  parent CLOSED/MERGED -> `loud "DEAD-PR-UNRESOLVED"` + `exit 2`; parent OPEN -> log and continue;
  no resolvable parent -> log and skip (consistent with the never-guess rule). Exit codes stay 0/1/2.
  Honesty line counts every non-`MERGEABLE`/non-`CONFLICTING` value. PLUS the hermetic case: extend
  the `gh` shim with `pr view` and add a case where `gh pr list` returns `"mergeable":"UNKNOWN"` for a
  PR whose parent fixture is `CLOSED`, asserting the detector never exits 0 with
  `dead_conflicting_prs=0`; keep cases 1-6 green, incl. case 6 (cross-repo ref -> skipped, exit 0).
- [x] phase 3: Diff scope + gate paths proven, not asserted: `git diff --name-only origin/main...HEAD`
  is exactly the two files; no `.github/workflows/**`, `.github/scripts/**`, `CODEOWNERS`,
  `.gitleaksignore`, `.gitleaks.toml`, `.semgrepignore`, `.semgrep.yml`/`.semgrep.yaml`; no test removed
  or skipped; no `migrations/**`; full `bash tests/fleet-dead-pr-detector.test.sh` green.
- [x] phase 4: Post-merge follow-up (recorded in the PR body, not a code change): the next live tick of
  `fleet-merged-pr-close.service` must flag PR #4978 (parent #4945 CLOSED). Disposition is
  rebase-and-land, not close-with-evidence, unless a fresh read shows `SKIP_TAGS` now contains
  `CLAIM-REAP-NEEDED`.

## Phase review record (manager, per-phase reviewer)

- Phase 1+2 diff (384 lines), stock `reviewer`, read-only. Re-ran the suite plus 35 adversarial
  permutations of list-value x re-query-value x job outcome; every path to a dead PR over a
  CLOSED/MERGED parent ended rc 2 with no measure line. Verdict APPROVE, 0 Act-on.
- 2 findings reclassified Consider -> ACT-ON by the manager (both are remediation for THIS PR,
  not follow-up debt) and fixed in a bounded retry by a fresh worker: (a) `DEAD_PR_UNKNOWN_SLEEP`
  default 5s -> 2s, because the per-PR sleep is serialized inside `TimeoutStartSec=10min` and ~40
  undecided PRs would have turned every tick into a misleading timeout page; (b) case 16 passed
  `DEAD_PR_UNKNOWN_ATTEMPTS=3` explicitly, so the shipped default was pinned by no test — override
  dropped, 3-call assertion kept.
- 2 further Consider findings taken in the same retry (cheap, same file): the test shim's `pr view`
  fallback now fails loudly on an empty fixture instead of silently modelling "view returned
  nothing"; new case 19 covers `"mergeable":null` alongside `"UNKNOWN"`.
- Recorded, not re-delegated: undecided + no resolvable parent still exits 0 (spec-mandated by
  acceptance 5 / never-guess, mitigated by the logged `unknown-mergeable` count); a parent state
  other than OPEN fails closed (safe direction, no 4th exit code); a malformed
  `DEAD_PR_UNKNOWN_ATTEMPTS` skips re-queries but stays fail-closed.
- Dismissed-with-reason: `set -euo pipefail` false-green (falsified, 35 permutations); cases 15-19
  lack teeth (falsified, all fail against the pre-change detector); case 11 CLEAN->MERGEABLE weakens
  coverage (CLEAN is a `mergeStateStatus` value — correcting it is what makes the case honest);
  shim argument order; agent names / dropped tests / gate paths.
- Post-review whole-diff check: `git diff --name-only origin/main...HEAD` still exactly the two files
  the issue allows; suite still 19/19 green.

## Outcome

- PR #5168 opened, auto-merge armed (squash), no labels.
- Live run: `dead_conflicting_prs=3` / rc 1, naming PR #4978 (parent #4945 CLOSED) — the issue's
  metric met — plus #5146 and #5095 surfaced.
- PR #4978 disposition: rebase-and-land (`CLAIM-REAP-NEEDED` still absent from `SKIP_TAGS` on
  `origin/main`, verified by `git show`). Recorded as a comment on #5079.
- Newly surfaced dead PRs #5146/#5095 filed as Nishfleet/fleet-ops#5169 (plain, no labels) — they
  would otherwise page the rail hourly with no issue covering them.
- `.fleet/plan.md` left uncommitted by design (see amendment), so the PR diff stayed at two files.

## Stall log

- (none)
