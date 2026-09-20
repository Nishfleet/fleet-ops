# Observe-close for #6467 — dead-CONFLICTING wedge on the deleted fleet-merged-pr-close rail

Issue #6467 (filed 2026-09-13) demonstrated a two-tick wedge of
`fleet-merged-pr-close.service`: its `ExecStartPre=`
`bin/fleet-dead-pr-detector` found dead-CONFLICTING PR #5352 (parent issue
MERGED) at 15:54:48Z and again at 16:00:03Z, exited 1 both times per the
fleet-ops#4468 fail-loud design, and the `ExecStart` observe-to-close
sweep was skipped on both ticks. The detector was flag-only — nothing in
the rail closed the dead PR — so the wedge stood until #5352's own
progression (flipped MERGEABLE 16:01:06Z, auto-merged 16:15:14Z) cleared
it by luck. The issue asked for a named unwedge mechanism for the
DEAD-CONFLICTING class: either the detector closes the PR itself, or its
`$STATE_DIR` marker hands the close to a named owner rail.

By the time this claim ran (2026-09-20), the entire rail the issue
targets was already deleted from main. No new code is needed; this
report is the resolution record.

## What was found

1. **The detector, the sweep, and their units are deleted.** `0dc5dd4ac`
   ("refactor(prs): GitHub closes the issue — drop the observe-to-close
   sweep", 2026-09-18) removed `bin/fleet-dead-pr-detector` (439 lines),
   `bin/fleet-merged-pr-close` (692 lines),
   `systemd/fleet-merged-pr-close.service` (47 lines) and `.timer` (20
   lines), the gh-webhook-receiver `pull_request/closed` route that fired
   them, and `tests/fleet-dead-pr-detector.test.sh` (673 lines); MANIFEST
   and `systemd/timer-manifest.json` rows re-staged. `git merge-base
   --is-ancestor 0dc5dd4ac origin/main` passes at origin/main
   `94497e76e`. The commit's recorded rationale: GitHub already closes an
   issue on its merged PR's `Closes #<N>` trailer — required by the
   worker PR-body contract — so the sweep "watched the fleet's own
   paperwork rather than moving an issue toward a merge"; the detector
   had already been demoted to non-fatal after failing 106 of 149 starts,
   and its only other caller went with the heartbeat tower earlier that
   day.
2. **No live reference remains on main.** Greps over origin/main
   (`94497e76e`) for `fleet-dead-pr-detector`, `fleet-merged-pr-close`,
   `dead-pr` and `dead_conflicting` across `bin/`, `libexec/`, `systemd/`,
   `config/` and `tests/` return zero hits; the only matches anywhere are
   historical records under `reports/` (the 2026-09-17 timer audit) and
   `.fleet/` fixtures.
3. **The host carries no residue.** On netcup-rs2000: `systemctl --user
   status fleet-merged-pr-close.service` → "could not be found";
   `~/.config/systemd/user/` holds no `fleet-merged-pr-close`/`dead-pr`
   unit or timer files; `systemctl --user list-timers` shows no matching
   timer. The wedge has no rail left to block.
4. **The salvage from earlier claims is obsolete by the same deletion.**
   `origin-wip/pi-issue-fleet-ops-6467-20260913T234613Z` (`849829c6d`,
   `0f1be95ca`) carries a detector-self-close patch plus
   `.fleet/plan-6467.md`, written against the pre-deletion tree (base
   `83e0d110e`). It was deliberately not cherry-picked: it edits a file
   `0dc5dd4ac` deleted, and the mechanism it plans — the detector closing
   the PR, pinned by a new test case — is machinery for a rail that no
   longer exists.
5. **The motivating live case resolved days ago.** PR #5352 — the dead
   branch whose two-tick wedge is the issue's evidence — merged
   2026-09-13T16:15:14Z (`4a8302fdbe04d772b69690b0e1a278cb86570753`); the
   failed unit cleared by 16:17:42Z the same day.

## Why neither accept arm applies as written

Both accept-1 mechanisms presuppose the rail: "the detector closes the
dead-CONFLICTING PR itself" and "the `$STATE_DIR` marker hands the close
to a named owner rail" are patches to `bin/fleet-dead-pr-detector`, which
does not exist. Accept 2's test pin targets
`tests/fleet-dead-pr-detector.test.sh`, deleted with it. The deletion is
a stronger resolution than either proposed arm: a wedge needs a sweep
gated behind a failing `ExecStartPre`, and neither the sweep, the gate,
nor the detector remains — there is no tick left to skip. Re-adding the
rail to then unwedge it would reinstate the `0dc5dd4ac` retire decision.

The `termination:` clause (`bash tests/fleet-dead-pr-detector.test.sh` +
grep for `ok dead-class unwedge`) is unreachable: the suite it names was
deleted with the rail. What it measured — a dead-CONFLICTING finding
starving the observe-to-close sweep — cannot be produced by anything on
main since 2026-09-18. This is the land-or-close outcome the 2026-09-14
parking comment predicted; the issue stays OPEN until this record's PR
closes it.

## Acceptance verification (2026-09-20, netcup-rs2000)

| Check | Result |
|---|---|
| `0dc5dd4ac` deletions on origin/main | `git merge-base --is-ancestor` → yes (origin/main `94497e76e`) |
| Live-code references | `git grep` over `bin/ libexec/ systemd/ config/ tests/` for `fleet-dead-pr-detector`, `fleet-merged-pr-close`, `dead-pr`, `dead_conflicting` → zero hits; repo-wide matches are `reports/timer-audit-2026-09-17.*` + `.fleet/` history only |
| Host units/timers | `systemctl --user status fleet-merged-pr-close.service` → "could not be found"; no unit/timer files in `~/.config/systemd/user/`; no matching entry in `list-timers` |
| Wedged PR | `gh pr view 5352 -R Nishfleet/fleet-ops` → MERGED 2026-09-13T16:15:14Z |
| Fleet alive while on this check | litellm `/health/readiness` → healthy, db connected; raw-model `litellm_deployment_state` gauges all 0.0; `list-units --state=failed` → one unrelated unit (`devin-issue@0509-2513.service`, StartLimitBurst on its own lane) |

## Residual note

The issue carries `awaiting-runtime-gate` and `agent-in-progress` from
the 2026-09-14 parking; this record's PR performs the `Closes #6467`
close under the new trailer regime — the same close path that replaced
the deleted sweep. No follow-up is filed: there is no surface left to
unwedge, and the escalation-organ repair (#6105) the issue cited as
why-nothing-cleared-it is tracked on its own ticket.
