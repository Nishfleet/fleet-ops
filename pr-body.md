## What

Daily auto-rebase of CONFLICTING PRs (fleet-ops#2525). A PR that turned
CONFLICTING when main moved has no event that re-reconciles it, so worker
fixes (many with run-proofs) sit stuck — on 2026-08-31 there were 12 open
CONFLICTING PRs in this repo, several stuck for weeks (#2087 gap-closure
rate-limit guard, #1923 0509 surface probe, #1696 pi-audit empty verdict,
#1582 alarm->ticket reconciler, #2511 seat corpse retirement).

New organ (bin/fleet-pr-rebase + systemd fleet-pr-rebase.{service,timer},
daily 06:00 IST):

- For every open CONFLICTING PR without the `rebase-failed` label, runs
  `gh pr update-branch <n> --rebase` (gh >= 2.40; this box runs 2.93.0).
  Success -> GitHub recomputes mergeability; an armed PR proceeds the
  moment it turns MERGEABLE (the existing auto-merge queue takes over).
- On update failure, a throwaway shallow local clone merges the PR head
  into current main to PROVE a genuine content conflict before touching
  anything. A true conflict -> the `rebase-failed` label (created once) +
  a comment naming the conflicted files; the PR author resolves manually.
  A gh failure for another reason (permissions / rate limit / branch
  protection) is logged, never labeled, retried next tick.
- PRs already labeled `rebase-failed` are skipped.
- Credentials: mints a short-lived nishfleet-worker App token itself via
  worker-token --print when GH_TOKEN is absent; missing creds or failed
  mint = DEAD APP IDENTITY, exit 1, no human gh-auth fallback.
- Metrics (textfile node-exporter): fleet_pr_rebased_total (counter,
  cumulative), fleet_pr_conflicting_total (counter, cumulative),
  fleet_pr_rebase_last_green_seconds (gauge, heartbeat).

Registered for observability in the same PR: fleet-organs.json entry
(pr-rebase, heartbeat fleet_pr_rebase_last_green_seconds, absent alert
FleetPrRebaseAbsent), the absent()/stale prom rule in fleet_rules.yml
(severity warning — nothing pages), the timer-manifest.json named-reason
entry, and MANIFEST install wiring (bin + service + timer).

Rollback is disabling the timer; the manual rebase process is unchanged.

architect skipped: depth-1 worker — owned the diff directly; the design
follows the established organ pattern (bin + oneshot + timer + textfile
metrics + absent rule, sibling of fleet-seat-comeback-release). Design
it twice: (A) standalone daily timer organ — chosen, matches the issue's
accept text and keeps a PR-mutating action out of the 30-min heartbeat
loop; (B) fold into fleet-heartbeat tier1 (like fleet-stale-auto-revert
-sweep) — rejected: a mutation inside the orchestrator loop is high blast
radius, a 14-PR rebase would blow tier1's 10-min budget, and the issue
explicitly asks for a dedicated daily schedule. (C) GitHub-native
merge-queue/dependabot — rejected: the queue does not resolve conflicts
(a CONFLICTING PR cannot enter), and dependabot only updates the
dependency-bump PRs it owns.

## Verification

Real end-to-end run (destructive edge, drill fixture, restored in the
same turn):

1. Created synthetic conflict PR #2537 (branch test/pr-rebase-drill,
   based at main~1 editing bin/scout-futility-check at a hunk that
   overlaps main's head). Confirmed CONFLICTING/DIRTY.
2. Ran the bin live, scoped with FLEET_PR_REBASE_NUMBERS=2537:

   [fleet-pr-rebase]   Nishfleet/fleet-ops#2537: rebasing onto main (test/pr-rebase-drill)
   [fleet-pr-rebase]   Nishfleet/fleet-ops#2537: update-branch failed (rc=1): X Cannot update PR branch due to conflicts
   [fleet-pr-rebase]   Nishfleet/fleet-ops#2537: REAL conflict — labeling rebase-failed
   [fleet-pr-rebase]   label rebase-failed already present on Nishfleet/fleet-ops
   fleet-pr-rebase rebased=0 conflicts_seen=1 repos_ok=1 repos_failed=0

3. Verification on the PR: labels = ["rebase-failed"]; the posted comment
   (by nishfleet-worker) was:

   Rebase of this branch onto `main` cannot be applied automatically (daily
   PR-rebase sweep, fleet-ops#2525). Conflicted files:
   ```
   bin/scout-futility-check
   ```
   Resolve locally (`git fetch origin`; `git rebase origin/main`), then
   push. The sweep skips PRs carrying the `rebase-failed` label until it is
   removed.

4. Drill PR #2537 closed and branch test/pr-rebase-drill deleted in the
   same turn (fixture restored).

5. Whole-repo read-only dry-run over the live list (12 CONFLICTING PRs,
   no mutation):

   [fleet-pr-rebase]   DRY Nishfleet/fleet-ops#2511: would gh pr update-branch 2511 --rebase (claim/issue-2469)
   [fleet-pr-rebase]   DRY Nishfleet/fleet-ops#2292: would gh pr update-branch 2292 --rebase (fix/worker-md-cite-958)
   ... (all 12 candidates listed) ...
   fleet-pr-rebase dry-run candidates_seen=12 repos_ok=1 repos_failed=0

6. Automated: bash tests/fleet-pr-rebase.test.sh — 17 cases green
   (success path, true-conflict path incl. the correct
   `gh pr edit --add-label` + comment-with-files, clean-failure no-label,
   rebase-failed skip, numbers drill hook, dry-run no-mutation, dead-App
   identity x2, mint-success, counter accumulation, MANIFEST /
   timer-manifest / organs registry / absent-rule / ci.yml contracts,
   systemd-analyze verify, shellcheck). sgscan on the diff: no new
   findings. crgate skipped: CodeRabbit is not signed in on this machine.

run-proof: journal lines above + prom textfile from the live drill
(fleet_pr_rebased_total 0, fleet_pr_conflicting_total 1,
fleet_pr_rebase_last_green_seconds <epoch>) + live PR #2537 artifacts
(comment + label), scrubbed by closing the drill PR in the same turn.

research: official docs (docs.github.com "keeping your pull request in sync with the base branch": Update branch / Update with rebase is the only sync path; merge queue + auto-merge do NOT resolve conflicts) + `gh pr update-branch --help`, checked the existing options — folding into fleet-heartbeat tier1 (rejected: mutation inside the orchestrator loop, blows tier1 budget), GitHub merge queue / dependabot (rejected: queue cannot admit a CONFLICTING PR, dependabot only owns dependency bumps), the existing mass-close-guard workflow (rejected: closes only resolved-issue PRs, never rebases) and auto-merge-arm (rejected: arms on green, never resolves conflicts) — a standalone daily organ was adopted as the smallest change matching the issue's accept criteria.

help-first: ran `gh pr update-branch --help` (gh 2.93 manual) — update-branch --rebase is the documented programmatic update-with-rebase, and gh has NO pr add-label command (labels applied via `gh pr edit --add-label`, which the bin uses); no existing tool rebases arbitrary worker PRs on a schedule.

Closes #2525