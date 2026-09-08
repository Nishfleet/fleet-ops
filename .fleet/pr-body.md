feat(pr-hygiene): sweep 7 dead CONFLICTING PRs + fail-loud dead-conflicting-PR detector (fleet-ops#4468)

## Summary

Sweeps seven dead conflicting branches whose fixes already landed on
`origin/main` (the five named in the issue plus two the new detector
surfaced at its first live run), closing each with an evidence comment
citing the superseding commit. Closes the prevention gap (fleet-ops#4468
"Prevention gap" section) with a deterministic, fail-loud detector on the
existing fleet-merged-pr-close rail — no new timer — and a weekly-review
judge line so the permanence check is `dead_conflicting_prs=0` for two
consecutive weeks.

## The seven closes (close-with-evidence per acceptance 1-2; never rebase-merge)

| PR | Parent issue | Parent state | Superseded by (on origin/main) |
|---|---|---|---|
| #1016 fix(pi-audit): SKIP vote on provider wall | #595 | MERGED | f1a3fcbc (#1015) — `bin/pi-audit-run` SKIP-on-wall lines ~595-617 |
| #1957 fix(alert): FleetDeadCredentialSeats cap>0 filter | #1941 | MERGED | 78926d97 (#3417) — `config/fleet_rules.yml` "Cap=0 rows are excluded" |
| #2193 fix(escalation): exclude pi-issue@* from amplifier | #2133 | CLOSED | c33f4f82 (#2515, "supersedes PR #2193") — `bin/unit-escalation-write` exclude block |
| #1301 fix(tests): ram-metric-compare live 822.6 shape | #489/#1126 | CLOSED/MERGED | be7b853a (#492) — `tests/ram-metric-compare.test.sh` live fixture |
| #4046 feat(oracle): Always Free outside-in monitor | retired | - | 6e8a2b90 (#4193) — `tests/oracle-scripts-deleted.test.sh` pins retirement |
| #3289 fix(metrics-export): seat observed_at UTC decode | #3111 | CLOSED | f294a793 (#3562) — `libexec/fleet-metrics-export.py` `calendar.timegm` decode (detector's first catch) |
| #9 fix(canary): pin header by default | cross-repo body ref (siterep-public PR #36) | - | e657737c (PR #1561 MERGED) — `bin/siterep-live-canary` pin design |

All seven verified CLOSED after the sweep: `gh pr view <n> --json state -q .state`
-> `CLOSED` for each of 1016 1957 2193 1301 4046 3289 9.

## The prevention mechanism (mechanical-fix, fleet-ops#366)

New `bin/fleet-dead-pr-detector` (deterministic, no LLM): lists open
fleet-ops PRs via `gh pr list --json mergeable`, keeps
`mergeable == "CONFLICTING"`, resolves the parent-originating issue with a
fixed priority — delivery trailer (`Closes|Fixes|Resolves #N`), then
`Relates to #N`, then `claim/issue-<N>` head branch, then a bounded `#N`
body reference (exact-number, never substring). Cross-repo-qualified refs
(`owner/repo#N` for a repo other than the scanned one) and explicit PR
references (`PR #N`, `pull request #N`) are scrubbed before matching — a
live-regression replay: PR #9's "Nishfleet/siterep-public PR #36" must never
resolve to fleet-ops issue #36. A PR is dead iff its parent issue is
MERGED/CLOSED; a PR with no resolvable parent is skipped, never guessed.

Output: one auditable `dead-pr: <n> <title> parent=<i> parent-state=<S> <url>`
line per dead PR, then the measure line `dead_conflicting_prs=<n>` last.
Exit 1 when n > 0 (fail loud), 0 when clean, 2 fail-closed when gh/jq is
missing or any gh call fails (never a false green).

Wired as `ExecStartPre` of the existing `fleet-merged-pr-close.service`
(hourly backstop timer + webhook — piggybacked rail, no new timer/unit): a
non-zero detector fails the unit and the existing OnFailure escalation
pages. `prompts/weekly-fleet-review.md` (L1 throughput lens) now instructs
the judge to run the detector and name `dead_conflicting_prs=<n>` — the
issue's permanence check (two consecutive weeks at 0).

## Verification

- Sweep: `gh pr view 1016/1957/2193/1301/4046/3289/9 -R Nishfleet/fleet-ops --json state -q .state` -> CLOSED x7.
- Detector live run (post-sweep): exit 0, `dead_conflicting_prs=0`; pre-sweep it had flagged the seven (count 7 -> 2 after the five named closes -> 0 after the two extra closes).
- `tests/fleet-dead-pr-detector.test.sh`: 13/13 cases PASS (mocked gh, hermetic, no network), incl. trailer/relates/branch/bare parents, live parent (no flag), cross-repo scrub regression replay, PR-ref scrub, mixed count, infra failure exit 2, missing-gh exit 2, clean sweep.
- `tests/p14-test-listing-gate.test.sh`: exit 0 (422 tests accounted).
- `tests/ci-standards-audit.test.sh`: exit 0.
- `bash -n bin/fleet-dead-pr-detector`, `git diff --check`: clean.

run-proof: systemd/fleet-merged-pr-close.service gains
ExecStartPre=/home/nish/.local/bin/fleet-dead-pr-detector (runs on the
existing fleet-merged-pr-close.timer `*:23:00` hourly backstop + webhook;
no new unit or timer); bin/fleet-dead-pr-detector + tests/fleet-dead-pr-detector.test.sh
hosted from tests/ci-standards-audit.test.sh (P14); prompts/weekly-fleet-review.md
L1 judge line; MANIFEST entry for the new bin.

research: compared `bin/fleet-merged-pr-close` (observe-to-close issues
delivered by merged PRs — not PR-conflict parentage) and
`.github/scripts/semantic-conflict-detector.mjs` (conflicting diffs INSIDE a
PR, not dead-vs-parent-resolution) before building; neither flags a
CONFLICTING PR whose originating issue resolved, so a dedicated detector is
the minimal new piece (fleet-ops#4468 "Prevention gap" section).

help-first: `gh pr list --json mergeable` returns the raw field but has no
parent-resolution or resolved-parent classification (`gh pr list --help`,
`gh pr view --help` confirm); the closest existing rail
(fleet-merged-pr-close) never examines mergeable state or parent issue
resolution — the detector is the minimal wrapper, reusing its token-minting
and fail-closed conventions.

mechanical-fix: this PR ships the detector + tests + observe-to-close (the
seven closes) that close the defect class; no `mechanism-impossible` needed.

Test plan: the 13-case hermetic suite is the reproducible gate; live
end-state proven with the real repo (`dead_conflicting_prs=0`, exit 0, all
seven PRs CLOSED).

Closes #4468