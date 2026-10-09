# The Mac's 11 desktop scheduled tasks: disposition (fleet-ops#9519)

The Mac that ran these tasks was switched off on 2026-10-09. Its 11 scheduled
tasks and their prompts were copied off it first, into
`mac-rescue-20261009/claude-scheduled-tasks.tar` (see
[mac-rescue-2026-10-09.md](mac-rescue-2026-10-09.md) for that folder's
disposition). That copy stays off this public repo. Each task's `SKILL.md`
inside it is the source for what the task actually did, and every reason below
was checked against live state in the run that added this page, not read from
memory.

**No clock is added on this box.** No task moves to a VPS timer, so nothing is
built here (the GLUE-ZERO rule in `docs/ARCHITECTURE.md`). Ten of the 11 are
retired — one of those, the weekly gardener, was retired earlier — and the last,
a weekly database export, is retired from the Mac while its capability stays
open, because its next home is that product repo's own CI, which needs a weekly
schedule there. That last one is handed to the coordinator.

## The two backups first

The issue asked for these two first, because a missed backup breaks a release
gate. They do not end the same way, and the difference matters.

- **`0509-weekly-d1-backup` — retired, nothing to port.** The task exported the
  production D1 database `0509` to an R2 bucket through wrangler logged in on
  the Mac, so the Mac held the only OAuth session it could use. The export
  script and its validator are gone from that repo's `main`
  (`gh api repos/Nishfleet/0509/contents/scripts?ref=main` → HTTP 404), and that
  repo's own recovery doc records the decision in its own words — "No script, no
  cron, no helper. Time Travel is the platform feature and needs none. Nothing in
  this repository runs a backup" (`docs/REBUILD-DONE.md`, the [0922] bullet) —
  with a recovery window of about 30 days and a re-checked-live Time Travel
  bookmark in the [0928] bullet. The nightly `snapshot-backup` Workflow
  (0509#5802) copies site-snapshot objects from `0509-snapshots` to
  `0509-snapshots-backup` at 05:00 UTC; that is a snapshot-objects copy, not a
  database export, so it does not stand in for the D1 export — the platform's
  Time Travel does, by that repo's own recorded decision. Nothing is lost by
  letting the Mac task die.
- **`seofixkit-weekly-d1-backup` — retired from the Mac, capability still
  open.** The weekly export script still exists in the `seofixkit` product repo
  (`nish3451/seo-fix-kit`, `ops/backup-d1.sh`), and the Mac task was its only
  scheduler: that repo's `.github/workflows` holds `deploy-production.yml`,
  `pr-check.yml` and `secret-scan.yml` and no scheduled backup job. It runs
  through wrangler OAuth on the Mac, which this box cannot hold, and Wrangler is
  banned fleet-wide. **Hand-off:** move the weekly export into that product
  repo's own CI, which already holds the repo's Cloudflare token and can use the
  `cf` CLI. This needs the Cloudflare API, which the worker jail cannot reach
  (AGENTS.md), so it goes to the coordinator rather than being solved with an
  ad-hoc credential.

## The other nine

| Task | Disposition | Reason |
| --- | --- | --- |
| `daily-fleet-digest` | retired | Its data source does not exist here: the task read `/home/nish/fleet2/var/` (`DIGEST.md`, `done`, `queue`, `quarantine`) and `var/scout/NEEDS-NISH.md` over ssh, and `/home/nish/fleet2` is absent on this box. Its delivery channel was the Mac's own push-notification tool. The same one-pager now runs here twice a day — `hermes cron list` shows `digest-morning` (08:00 IST) and `digest-evening` (20:00 IST), both active, both delivering to Telegram, last run `ok`. |
| `drive-mac-walk` | retired | macOS GUI walk through the `cua-driver` tools; this box has no display, and desktop work here runs only inside Cua Spaces (fleet-ops#9297, #9298). Its own gate never opened — `gh issue view 760 -R nish3451/drive` answers `OPEN REOPENED`. |
| `fleet-gate-ram-decision` | retired | The admission gate it audited is gone (`/home/nish/workspaces/agent-state/gate` is absent) and this box now carries 32 GiB across 12 vCPU, double the 16 GB the question was asked about. |
| `fleet-steer-heartbeat` | retired | It ran from the Mac over ssh every 4 hours. Its duties are covered here by the hourly fleet judge (`fable-fleet-check.service`, packet `agent-state/fleet-landing-watch/fable-check.md`) plus the Prometheus recording rules and the Alertmanager pipeline — the same pairing the 2026-09-07 cut recorded in the vault's `retired-mechanisms.md` when it retired the `opus-heartbeat` family as "a second judge duplicating the hourly fable-fleet-check judge that already runs with tools". |
| `github-minutes-reset-check` | retired | The PR it watched answers `state=CLOSED` with `mergedAt: null` (0509#770, closed 2026-08-18). The CI-runner decision it existed to make is now owned by this repo's own hourly `blacksmith-flip.timer` (fleet-ops#8936). |
| `inbox-14-gmail-check` | retired | Its own description says DISABLED: it was created from a server session, points at a `/home/nish` path that does not exist on the Mac, and could never start. Gmail is reachable only through the Mac's Claude connector. |
| `monthly-rulebook-redteam` | retired | The "Rulebook red-team cadence" rule it enforced is no longer in the binding rules file — it survives only in `standing-rules-archive.md`, which is history, not instruction. The Mac rulebook files it audited (`~/.codex/AGENTS.md`, `~/.codex/memories/profile.md`) do not exist on this box. |
| `scorecard-mac-helper` | retired | The weekly scorecard already runs here — `hermes cron list` shows `scorecard-weekly` (Mondays 09:00 IST), active, delivering to Telegram. The Mac column it fed came from counting Nish's typed messages in `~/.claude/projects` on the Mac, and that has no source once the Mac is off. It also spent ten paid judge calls a week, which this retires with it. |
| `weekly-fleet-gardener` | retired earlier | Cut on 2026-09-29 (fleet-ops#8954, merged) after filing 0 proposals; recorded in `docs/skill-proposals.md`. |

## Checked, not assumed

Every reason above was checked against live state during the run that added this
page. The commands and their output:

- `tar -tf mac-rescue-20261009/claude-scheduled-tasks.tar` → the 11 task
  directories, each holding the `SKILL.md` quoted above. `sha256sum -c
  SHA256SUMS.txt` in the same folder answers `claude-scheduled-tasks.tar: OK`.
- `ls /home/nish/fleet2` → `No such file or directory`
- `ls /home/nish/workspaces/agent-state/gate` → `No such file or directory`
- `ls /home/nish/workspaces/agent-state/fleet-landing-watch/fable-check.md` →
  present, and its header reads "You are one of two hourly fleet judges"
- `ls /home/nish/.codex/AGENTS.md` → absent; `ls /home/nish/.codex/memories/profile.md`
  → absent
- `grep -n 'RULEBOOK RED-TEAM CADENCE' nish-vault/_system/shared-memory/global-standing-rules.md`
  → no match; the same grep on `standing-rules-archive.md` → line 504
- `hermes cron list` → `digest-morning` (08:00 IST, telegram, last run `ok`),
  `digest-evening` (20:00 IST, telegram, last run `ok`), `scorecard-weekly`
  (Mondays 09:00 IST, telegram, last run `ok`)
- `free -g; nproc` → 31 GiB total, 12 vCPU
- `gh pr view 770 -R Nishfleet/0509 --json number,state,closedAt,mergedAt` →
  `state=CLOSED closedAt=2026-08-18T05:56:29Z mergedAt=null`
- `gh api repos/Nishfleet/0509/contents/scripts?ref=main` → HTTP 404
- `gh api repos/Nishfleet/0509/contents/workers/workflows/snapshot-backup.ts?ref=main`
  → `snapshot-backup.ts`, whose monitor schedule is `0 5 * * *`
- `gh api repos/Nishfleet/0509/contents/wrangler.jsonc?ref=main` → the
  `snapshot-backup` Workflow binding and the comment "0509-snapshots-backup is
  the nightly copy target of the snapshot-backup Workflow below" (0509#5802)
- `gh api repos/nish3451/seo-fix-kit/contents/ops/backup-d1.sh?ref=main` →
  `backup-d1.sh`
- `gh api repos/nish3451/seo-fix-kit/contents/.github/workflows?ref=main` →
  `deploy-production.yml`, `pr-check.yml`, `secret-scan.yml`
- `gh issue view 760 -R nish3451/drive --json number,state,stateReason` →
  `OPEN REOPENED`
- `gh issue view 8936 -R Nishfleet/fleet-ops --json state,title` → `OPEN`,
  "Blacksmith auto-flip: hourly cheap-seat check flips CI_RUNNER at 95% of free
  minutes", and `systemd/blacksmith-flip.timer` on `main` carries
  `OnCalendar=hourly`
- `gh issue view 8954 -R Nishfleet/fleet-ops --json state,title` → `MERGED`,
  "Cut the scheduled agent jobs and the extra workflows"
