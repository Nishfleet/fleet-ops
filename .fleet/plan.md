# Plan — fleet-ops #4468: land-or-close 5 dead CONFLICTING PRs + dead-conflicting-PR detector

## Goal

Close the five dead CONFLICTING PRs (#1016 #1957 #2193 #1301 #4046) with
evidence-citing comments, add a deterministic `bin/fleet-dead-pr-detector`
that fails loud on open conflicting PRs whose parent issue is resolved
(piggybacked on the fleet-merged-pr-close rail, no new timer), and teach the
weekly review's PR section to name `dead_conflicting_prs=<n>` — terminating
when all five are closed and `git grep -q "dead_conflicting_prs" origin/main
-- bin lib` matches.

## Phase 1 — Sweep: close the five dead conflicting PRs with evidence (gh actions, NOT repo edits)

- [x] phase 1: for each of PRs #1016 #1957 #2193 #1301 #4046, first `gh pr view <n> -R Nishfleet/fleet-ops --json state,mergeable` — only close when state==OPEN; if already CLOSED, record and move on (fail-closed on any gh error, flagged same turn)
- [x] phase 1: #1016 -> close with comment citing superseding commit f1a3fcbc "fix(audit): storm-tolerant panel — slice, tick-cap, seat-health preflight, SKIP-on-wall (#1015)" (live `bin/pi-audit-run` lines ~595-617 SKIP-on-wall) as the fix already on origin/main for parent #595 (MERGED)
- [x] phase 1: #1957 -> close with comment citing 78926d97 "fix(seats): keep 429 retry windows; cap-0 401s do not page as dead creds (#3417)" (live `config/fleet_rules.yml` line 113 "Cap=0 rows are excluded") for parent #1941 (MERGED)
- [x] phase 1: #2193 -> close with comment citing c33f4f82 "fix(escalation): exclude pi-issue@* from unit-escalation amplifier loop (fleet-ops#2475, supersedes PR #2193) (#2515)" (live `bin/unit-escalation-write` lines 104-135 pi-issue@* exclude) for parent #2133 (CLOSED)
- [x] phase 1: #1301 -> close with comment citing be7b853a "fix(ram): record memory.current vs VmRSS mismatch without changing admission (#492)" (live `tests/ram-metric-compare.test.sh` 822.6 MiB fixture) for parents #489/#1126 (CLOSED/MERGED)
- [x] phase 1: #4046 -> close with comment citing 6e8a2b90 "chore(retire): pin oracle-* + 0509-surface-probe deletion (fleet-ops#4150) (#4193)" (live `tests/oracle-scripts-deleted.test.sh` pins retirement) as the feature-retired disposition
- [x] phase 1: NO rebase-merge of any of the five — close-with-evidence is the only disposition (acceptance 2)

## Phase 2 — Detector: bin/fleet-dead-pr-detector + MANIFEST + piggyback wiring (no new timer)

- [x] phase 2: new executable `bin/fleet-dead-pr-detector` (bash, deterministic, no LLM): lists open Nishfleet/fleet-ops PRs via `$GH` (env override, default `gh`), filters `mergeable == CONFLICTING`, and for each resolves the parent-originating issue — explicit Closes/Fixes/Resolves #N trailer, then Relates to #N, then `claim/issue-<N>` head-branch fallback, then first bounded #N reference in the body
- [x] phase 2: per dead PR, print one auditable evidence line: PR number, PR title, parent issue number, parent state (dead when MERGED or CLOSED), superseding evidence
- [x] phase 2: always print the measure line `dead_conflicting_prs=<n>` on stdout; exit 1 when n > 0 (fail loud), exit 0 when clean; exit 2 fail-closed when gh/jq missing or any gh call fails (never a false green)
- [x] phase 2: env seams for deterministic testing: `GH=` (mock gh binary), `DEAD_PR_REPO=` (default Nishfleet/fleet-ops)
- [x] phase 2: `MANIFEST` gains `bin/fleet-dead-pr-detector /home/nish/.local/bin/fleet-dead-pr-detector` plus a `# fleet-ops#4468` comment line
- [x] phase 2: add `ExecStartPre=/home/nish/.local/bin/fleet-dead-pr-detector` + a named-reason comment to the existing `systemd/fleet-merged-pr-close.service` — a non-zero detector fails the unit, which fires the existing OnFailure escalation (global `service.d/10-escalate.conf`). Repair of an existing unit; no new unit/timer/MANIFEST unit line

## Phase 3 — Mocked-gh test + hosting (hermetic, no network)

 - [x] phase 3: new `tests/fleet-dead-pr-detector.test.sh` (executable, mocked-gh fixture): cases — conflicting+resolved-parent -> dead_conflicting_prs=1 + exit 1 + evidence line; conflicting+open-parent -> clean exit 0; non-conflicting PR -> ignored, exit 0; gh failure/auth error -> exit 2, no false green; clean sweep -> dead_conflicting_prs=0 + exit 0; gh/jq missing -> exit 2
 - [x] phase 3: host it from the existing P14-listed host runner (verify which: `tests/ci-standards-audit.test.sh` or the established host) so the p14-test-listing gate stays green — NO ci.yml edit (worker App has no workflow scope)
 - [x] phase 3: new test -> EXIT 0 and p14 test-listing gate -> EXIT 0

## Phase 4 — Weekly review PR-section instruction (acceptance 4)

- [x] phase 4: `prompts/weekly-fleet-review.md` PR-section lens gains one instruction: the judge runs `bin/fleet-dead-pr-detector` and names `dead_conflicting_prs=<n>` in the lens findings — the sweep's permanence check is the count sitting at 0 for two consecutive weeks after the sweep

## Phase 5 — Gates -> commit -> PR -> arm (fleet-ops is NOT a product repo: reviewer round skipped, arm directly)

- [x] phase 5: run gate suite against the diff: sgscan, new test, p14 gate, fleet-bin-exclude-canary, manifest-shape, fleet-organ-heartbeat-check (detector is NOT an organ), fleet-no-agent-names-check, fleet-token-efficiency-check, machinery-authorization-gate
- [x] phase 5: `bin/research-before-build-check --body <pr-body>` green (new bin/ file requires research: + help-first: lines)
- [x] phase 5: `bin/prove-one-run-check --body <pr-body>` + `bin/fleet-exec-review-canary --body <pr-body>` green
- [x] phase 5: single commit covering exactly: `bin/fleet-dead-pr-detector`, `tests/fleet-dead-pr-detector.test.sh`, host test file, `systemd/fleet-merged-pr-close.service`, `MANIFEST`, `prompts/weekly-fleet-review.md` — no agent names anywhere
- [x] phase 5: in-worktree `git grep -q "dead_conflicting_prs" -- bin lib` -> rc 0
- [x] phase 5: PR body: `Closes Nishfleet/fleet-ops#4468`, research: + help-first: lines, mechanical-fix note, run-proof block
- [x] phase 5: `gh pr merge --auto --squash -R Nishfleet/fleet-ops 4484` arms the merge (auto-merge enabled 2026-09-08T06:21:46Z)

## Phase 6 — Termination verification

- [x] phase 6: `gh pr view` for #1016 #1957 #2193 #1301 #4046 all state==CLOSED (also #3289 #9 from detector's first live catch — 7 total)
- [ ] phase 6: post-merge, `git grep -q "dead_conflicting_prs" origin/main -- bin lib` -> rc 0 (TERMINATION — pending the auto-merge)

## Phase 7 — Re-base forward onto current main (manager re-entrancy)

- [x] phase 7: `git fetch origin` -> main advanced from 836e9af0 (branch base) to d4edac92 with 5 new merges (#4469 #4473 #4479 #4480 #4482)
- [x] phase 7: `git rebase origin/main` clean (no conflicts); all 6 commits rebased
- [x] phase 7 (re-entrancy resume, 2026-09-08): main advanced further 4edac92 -> 119ea6e8 (6 new merges incl. #4489 #1582 #4488 #2087 #4486 #4485). #4488 touched `prompts/weekly-fleet-review.md` (L1 stale-CONFLICTING namecheck, fleet-ops#4471) -> rebase conflict on commit d8497344. Resolved KEEPING both #4471's stale-namecheck block AND #4468's `dead_conflicting_prs` line (complementary sweeps). Rebase clean; diff re-scoped to the same 8 files.
- [x] phase 7: re-run gates after rebase — diff is now scoped (8 files: detector, test, MANIFEST, service ExecStartPre, weekly-review L1, host runner, plan, pr-body) with no unrelated drift
- [ ] phase 7: force-push rebased `claim/issue-4468` to origin so PR #4484's head points at the rebased tip

## Files to Modify
- `systemd/fleet-merged-pr-close.service` — add `ExecStartPre=/home/nish/.local/bin/fleet-dead-pr-detector` + named-reason comment (repair of an existing unit)
- `MANIFEST` — `bin/fleet-dead-pr-detector /home/nish/.local/bin/fleet-dead-pr-detector` + #4468 comment
- `prompts/weekly-fleet-review.md` — PR-section instruction to run the detector and name dead_conflicting_prs
- host test file — host the new test (same commit)

## New Files
- `bin/fleet-dead-pr-detector` — deterministic fail-loud detector; measure line `dead_conflicting_prs=<n>`; exit 1 when n>0, 0 clean, 2 fail-closed
- `tests/fleet-dead-pr-detector.test.sh` — hermetic mocked-gh matrix

## Risks
- ExecStartPre fail-loud blocks fleet-merged-pr-close's own observe-to-close each tick while a dead conflicting PR lingers (hourly page until swept). That is the designed stop-the-line semantics; Phase 1 clears the current five so baseline is 0.
- Mismatched `mergeable` enum -> detector counts nothing -> false green. Use the exact GitHub enum (`CONFLICTING`).
- Detector parent-resolution must never count a resolved parent as dead when the PR's work is still live — deterministic priority; a false positive fails loud instead of silently wrong.
- Missed P14 host line -> red on main -> fleet auto-revert. Mitigation: host line lands in the same commit + p14 gate run before push.
- Live unit change only takes effect after deploy convergence — do NOT hand-edit the deploy clone.
## Phase notes (manager)

- phase 1 DONE: all five named PRs closed with evidence comments, verified CLOSED.
  Plus the detector's first live catch: #3289 (parent #3111 CLOSED, fix f294a793/#3562 on main)
  and #9 (fix e657737c/#1561 on main; body's #36 is cross-repo siterep-public PR ref) also
  closed with evidence — dead_conflicting_prs is 0 going into deployed state.
- phase 2 DONE: detector + MANIFEST + service ExecStartPre commit 1b77daa3.
- stalled: phase 3 — worker#1 returned no commit (truncated reply). Re-dispatched fresh worker
  with the cross-repo parent-resolution bug fix spec + test matrix + p14 hosting.
- phase 3 DONE (final): commit c9120ad6 — reviewer Act-on round landed (--limit 300,
  plural-PR scrub, exact-number pin case 14, stderr-clean gh calls, owner-match
  tightening, unknown-mergeable log). Live: dead_conflicting_prs=0 exit 0.
- phase 4 DONE: commit b817692a (weekly-review L1 judge line).
- phase 5 DONE: gates green — research-before-build OK, prove-one-run OK (+484
  net-positive-because), exec-review-canary OK, no-agent-names OK, token-efficiency
  OK, organ-heartbeat SKIP (not-an-organ), machinery-authorization-gate PASS,
  sgscan clean, p14 gate OK, ci-standards-audit OK, detector suite 14/14 OK.
- phase 2 DEFECT FIX (re-entrancy resume): commit 0174770a had wrapped the
  ExecStartPre with a leading `-` (```-/bin/bash -c ...```) claiming it only made
  a missing-binary runtime error optional. Per systemd.service(5), a `-` prefix
  on an ExecStartPre command makes ITS failure non-fatal — the unit is NOT
  considered failed and OnFailure escalation never fires, which silently defeats
  the whole fail-loud design (acceptance 3) and contradicts the plan + PR body
  ("fails the unit (exit 1) so OnFailure escalation pages"). Corrected to
  `ExecStartPre=/bin/bash -c ...` (no `-`), mirroring pi-scout's gate
  (ExecCondition fail-loud) not its futility-tracker ('-'). `systemd-analyze
  verify` passes identically with and without the `-` (verified). Detector suite
  14/14 still green. NOT deployed / NOT in .local/bin yet (PR not merged), so no
  live-state inconsistency.
- re-entrancy NOTE: the PR (#4484) had gone `mergeable:CONFLICTING` because main
  advanced past the phase-7 rebase base (d4edac92). Rebased onto current main
  (119ea6e8) + resolved the weekly-fleet-review.md conflict, keeping #4471 +
  #4468. After force-push the PR will be MERGEABLE again.

## Reviewer adjudication (phase 2/3 diff, reviewer seat pass)

- Act on (fixed in c9120ad6): no --limit on gh pr list (silent false-green past
  30) -> --limit 300; plural `PRs #N` surviving the scrub -> plural alternation;
  exact-number #11352-vs-1135 unpinned -> case 14; 2>&1 on success-path gh calls
  (JSON corruption / swallowed errors) -> 2>/dev/null + rc check.
- Consider (fixed same commit): other-owner repo literally named fleet-ops
  surviving the keep -> whole-token owner match; mergeable:null silently skipped
  -> unknown-mergeable counter in the log line.
- Noted: gh issue view never returns MERGED (CLOSED+stateReason); agent-name scan
  hits are the test's own anti-attribution regex and deleted lines; plan/pr-body
  rewrites follow the per-run convention (gate-integrity.yml untouched).
- Dismissed-with-reason: Relates>claim-branch priority (mirrors fleet-merged-pr-close
  #4317/#4373: branch reuse is untrustworthy, body trailer is the delivery);
  pull/pull-request alternate forms untested (code-path probed live); cross-repo
  double-space over-removal (cosmetic, never fabricates); token-minting header
  byte-identical to the proven rail.
