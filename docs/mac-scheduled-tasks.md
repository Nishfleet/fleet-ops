# The Mac's 11 desktop scheduled tasks: disposition (fleet-ops#9519)

The Mac that ran these tasks is going off. The 11 scheduled tasks were copied
off it first; that copy stays off this public repo. This page records what each
one becomes now that it can no longer run there.

**No clock is added on this box.** No task moves to a VPS timer, so nothing is
built here (the GLUE-ZERO rule in `docs/ARCHITECTURE.md`). Nine of the 11 are
retired outright, one (the weekly gardener) was retired earlier, and the last
— a weekly database export — is retired from the Mac while its capability
stays open: its next home is that product repo's own CI, which needs a weekly
schedule there. That last one is handed to the coordinator.

The receipts (commands, outputs, paths, ids) are kept off this public repo in a
private proof note.

## The two backups first

The issue asked for the two backup tasks first, because a missed backup breaks a
release gate.

- **`0509-weekly-d1-backup` — retired, superseded.** The export script and its
  validator it invoked are gone from that repo's `main`. That repo's own
  recovery doc states the decision — "No script, no cron, no helper. Time
  Travel is the platform feature and needs none" — and measures a 30-day
  point-in-time recovery window and an 11-second restore. A daily Worker cron in
  the same repo already copies snapshots into a backup bucket. Nothing is lost
  by letting the Mac task die.
- **`seofixkit-weekly-d1-backup` — retired from the Mac, capability still
  open.** The weekly export script still exists in the `seofixkit` product repo
  (`nish3451/seo-fix-kit`), and the Mac task was its only scheduler. It runs
  through an interactive OAuth login this box cannot hold, and Wrangler is banned
  fleet-wide. **Hand-off:** move the weekly export into that product repo's own
  CI, which already holds the repo's Cloudflare token and can use the `cf` CLI.
  This needs the Cloudflare API,
  which the worker jail cannot reach (AGENTS.md), so it goes to the coordinator
  rather than being solved with an ad-hoc credential.

## The other nine

| Task | Disposition | Reason |
| --- | --- | --- |
| `daily-fleet-digest` | retired | Superseded by the two digest jobs already running on this box (morning and evening, delivered to Telegram); it read a dispatcher tree that has since been removed. |
| `drive-mac-walk` | retired | macOS GUI walk; this box has no display, and desktop work here runs only inside Cua Spaces. The Linux walk is tracked (fleet-ops#9297, #9298), and the Mac walk was gated on drive#760, still open. |
| `fleet-gate-ram-decision` | retired | The admission gate it audited is gone, and the box's memory has doubled since; the question it asked no longer binds. |
| `fleet-steer-heartbeat` | retired | Superseded by the hourly fleet judge plus the Prometheus recording rules and Alertmanager pipeline; it read the removed dispatcher tree. |
| `github-minutes-reset-check` | retired | The PR it watched was closed unmerged on 2026-08-18, and the CI-runner decision it existed to make is now owned by this repo's own runner-flip unit (fleet-ops#8936). |
| `inbox-14-gmail-check` | retired | Already disabled by its own description: it was created from a server session and could never start, and Gmail is reachable only through the Mac's Claude connector. |
| `monthly-rulebook-redteam` | retired | The cadence rule it enforced was consolidated out of the binding rules file in the 2026-09-07 rule-debt cut (the archive file is history, not instruction), and the Mac rulebook files it audits do not exist on this box. |
| `scorecard-mac-helper` | retired | The scorecard job already runs here and counts this box's sessions and Telegram; the Mac column it added has no source once the Mac is gone. |
| `weekly-fleet-gardener` | retired earlier | Cut on 2026-09-29 (fleet-ops#8954) after filing 0 proposals; recorded in `docs/skill-proposals.md`. |

## Checked, not assumed

Every reason above was checked against live state during this run, not read from
memory. The product repo's `main` was queried through the GitHub API, the two
digest jobs and the scorecard job are active in the scheduler with a last run of
`ok`, the box's memory and the removed dispatcher tree were measured, the
watched PR answers `state=CLOSED` with `mergedAt: null`, the cadence rule is
absent from the binding rules file, and the only trace of the weekly-export
scheduler is the Mac task itself. The exact commands and their output are pasted
in the pull request that added this page.
