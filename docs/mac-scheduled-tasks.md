# The Mac's 11 desktop scheduled tasks: disposition (fleet-ops#9519)

The Mac that ran these tasks was switched off on 2026-10-09. Its 11 scheduled
tasks and their prompts were copied off it first, into
`mac-rescue-20261009/claude-scheduled-tasks.tar` (see
[mac-rescue-2026-10-09.md](mac-rescue-2026-10-09.md) for that folder's
disposition). That copy stays off this public repo. Each task's `SKILL.md`
inside it is the source for what the task actually did. Every reason below was
checked against those `SKILL.md` files and against live state on this box, not
read from memory. Vault files cited below live under
`nish-vault/_system/shared-memory/`.

**No clock is added on this box.** No task moves to a VPS timer, so nothing is
built here (the GLUE-ZERO rule in `docs/ARCHITECTURE.md`). All 11 leave the
Mac. Ten are retired outright, and one of those ten — the weekly gardener — was
retired earlier. The last one, the weekly `seofixkit` database export, also
leaves the Mac, but its capability has a next home in that product repo's own
CI, and that CI needs a weekly schedule there, so it is handed to the
coordinator instead of getting a tombstone.

## The two backup tasks

The issue asked for these two first, because a missed backup breaks a release
gate. They do not end the same way, and the difference matters.

- **`0509-weekly-d1-backup` — retired, nothing to port.** The task exported the
  production D1 database `0509` to an R2 bucket through wrangler logged in on
  the Mac, so the Mac held the only OAuth session it could use. The export
  script and its validator are gone from that repo's `main`
  (`gh api repos/Nishfleet/0509/contents/scripts?ref=main` → HTTP 404), and that
  repo's own recovery doc records the decision in its own words — "No script, no
  cron, no helper. Time Travel is the platform feature and needs none. Nothing in
  this repository runs a backup" (`docs/REBUILD-DONE.md`, the 2026-09-22 bullet,
  written `[0922]` there) — with a recovery window of about 30 days and a
  re-checked-live Time Travel bookmark in the 2026-09-28 bullet (`[0928]`). The
  nightly `snapshot-backup` Workflow (0509#5802) copies site-snapshot objects
  from `0509-snapshots` to `0509-snapshots-backup` at 05:00 UTC. That is a
  snapshot-objects copy, not a database export, so it does not stand in for the
  D1 export. The platform's Time Travel does, by that repo's own recorded
  decision. Nothing is lost by letting the Mac task die.
- **`seofixkit-weekly-d1-backup` — retired from the Mac, capability still
  open.** The weekly export script still exists in the `seofixkit` product repo
  (`nish3451/seo-fix-kit`, `ops/backup-d1.sh`), and the Mac task was its only
  scheduler: that repo's `.github/workflows` holds `deploy-production.yml`,
  `pr-check.yml` and `secret-scan.yml` and no scheduled backup job. It runs
  through wrangler OAuth on the Mac, which this box cannot hold, and Wrangler is
  banned fleet-wide — the vault's `global-standing-rules.md` says Cloudflare work
  uses the `cf` CLI and "No Wrangler, in any repo, CI job, packet or skill"
  (Nish, 2026-09-28), which is also why the replacement uses `cf` and not
  wrangler. **Hand-off:** move the weekly export into that product
  repo's own CI, which already holds the repo's Cloudflare token and can use the
  `cf` CLI. That hand-off is tracked in a plain issue, fleet-ops#9527, filed in
  this repo with no label, because the worker's GitHub token reaches only
  fleet-ops and because a label here would put Cloudflare work in the worker
  queue. This needs the Cloudflare API, which the worker jail cannot reach
  (AGENTS.md), so it goes to the coordinator rather than being solved with an
  ad-hoc credential.

## The other nine

| Task | Disposition | Reason |
| --- | --- | --- |
| `daily-fleet-digest` | retired | Its data source does not exist here: the task read `/home/nish/fleet2/var/` (`DIGEST.md`, `done`, `queue`, `quarantine`) and `var/scout/NEEDS-NISH.md` over ssh, and `/home/nish/fleet2` is absent on this box. Its delivery channel was the Mac's own push-notification tool. The same one-pager now runs here twice a day — `hermes cron list` shows `digest-morning` (08:00 IST) and `digest-evening` (20:00 IST), both active, both delivering to Telegram, last run `ok`. |
| `drive-mac-walk` | retired | macOS GUI walk through the `cua-driver` tools. This box has no display, and desktop work here runs only inside Cua Spaces (fleet-ops#9297, #9298). Its own gate never opened — `gh issue view 760 -R nish3451/drive` answers `OPEN REOPENED`. |
| `fleet-gate-ram-decision` | retired | The admission gate it audited is gone (`/home/nish/workspaces/agent-state/gate` is absent) and this box now reports 31 GiB across 12 vCPU, double the 16 GB the question was asked about. |
| `fleet-steer-heartbeat` | retired | It ran from the Mac over ssh every 4 hours and sent one short Telegram message with fleet state. The Mac's ssh path is gone, and its cadence duplicated the twice-daily digest jobs that do run here. Its closest VPS twin, the hourly `fable-fleet-check` judge trio, was cut on 2026-09-18 as a money burn — three timers running one packet through three expensive models, about 600 paid flagship calls a week, two of the three failing more often than they succeeded (`agent-state/glue-sweep/kill-list-20260918T091044Z.md` §5). No `fable-*` unit is installed on this box now, and re-adding a 4-hour LLM judge would rebuild exactly that burn. What does run and covers the ground is the `hermes` digest jobs, the Grafana alerting rules provisioned under `config/grafana/provisioning/alerting/`, and `blacksmith-flip.timer`, which is hourly and owns the CI-runner decision. |
| `github-minutes-reset-check` | retired | The PR it watched answers `state=CLOSED` with `mergedAt: null` (0509#770, closed 2026-08-18). The CI-runner decision it existed to make is now owned by this repo's own hourly `blacksmith-flip.timer` (fleet-ops#8936). |
| `inbox-14-gmail-check` | retired | Its own description says DISABLED: it was created from a server session, points at a `/home/nish` path that does not exist on the Mac, and could never start. Gmail is reachable only through the Mac's Claude connector. |
| `monthly-rulebook-redteam` | retired | The "Rulebook red-team cadence" rule it enforced is no longer in the binding rules file — it survives only in `standing-rules-archive.md`, which is history, not instruction. The Mac rulebook files it audited (`~/.codex/AGENTS.md`, `~/.codex/memories/profile.md`) do not exist on this box. |
| `scorecard-mac-helper` | retired | The weekly scorecard already runs here — `hermes cron list` shows `scorecard-weekly` (Mondays 09:00 IST), active, delivering to Telegram. The Mac column it fed came from counting Nish's typed messages in `~/.claude/projects` on the Mac, and that has no source once the Mac is off. It also spent ten paid judge calls a week, which this retires with it. |
| `weekly-fleet-gardener` | retired earlier | Cut on 2026-09-29 (fleet-ops#8954, merged) after filing 0 proposals. Recorded in `docs/skill-proposals.md`. |

## Checked, not assumed

Every reason above was checked against live state during the run that added this
page. The live-state commands and their output:

- `tar -tf mac-rescue-20261009/claude-scheduled-tasks.tar` → the 11 task
  directories, each holding the `SKILL.md` quoted above. `sha256sum -c
  SHA256SUMS.txt` in the same folder answers `claude-scheduled-tasks.tar: OK`.
- `ls /home/nish/fleet2` → `No such file or directory`
- `ls /home/nish/workspaces/agent-state/gate` → `No such file or directory`
- `ls /home/nish/workspaces/agent-state/fleet-landing-watch/fable-check.md` →
  present, and its header reads "You are one of two hourly fleet judges".
  `ls /home/nish/.config/systemd/user/fable-*` → `No such file or directory`, and
  `grep -rl fable-fleet-check /etc/systemd /home/nish/.config/systemd` → no
  match, so no judge unit is installed on this box.
- `ls /home/nish/.codex/AGENTS.md` → absent, and
  `ls /home/nish/.codex/memories/profile.md` → absent
- `grep -n 'RULEBOOK RED-TEAM CADENCE' nish-vault/_system/shared-memory/global-standing-rules.md`
  → no match, and the same grep on `nish-vault/_system/shared-memory/standing-rules-archive.md`
  → line 504
- `hermes cron list` → `digest-morning` (08:00 IST, telegram, last run `ok`),
  `digest-evening` (20:00 IST, telegram, last run `ok`), `scorecard-weekly`
  (Mondays 09:00 IST, telegram, last run `ok`)
- `free -g` → 31 GiB total
- `nproc` → 12
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
  minutes"
- `git show origin/main:systemd/blacksmith-flip.timer` → `Description=Hourly
  Blacksmith CI_RUNNER auto-flip (fleet-ops#8936)`, `OnCalendar=hourly`,
  `Persistent=true`
- `gh pr view 8954 -R Nishfleet/fleet-ops --json state,mergedAt` → `MERGED`,
  `mergedAt=2026-09-29T12:00:09Z`, "Cut the scheduled agent jobs and the extra
  workflows"

The rest of the page quotes documents rather than live state. Each quote below is
named with the command that read it:

- `docs/REBUILD-DONE.md` in `Nishfleet/0509` — read through
  `gh api repos/Nishfleet/0509/contents/docs/REBUILD-DONE.md?ref=main`. The
  quoted sentence is in the 2026-09-22 bullet (`[0922]`), "No script, no cron, no
  helper. Time Travel is the platform feature and needs none. Nothing in this
  repository runs a backup." The 2026-09-28 bullet (`[0928]`) records the
  re-checked-live bookmark and the export-to-import round trip.
- `agent-state/glue-sweep/kill-list-20260918T091044Z.md` §5, the fable-judge-trio
  entry — read on this box. It names the six unit files, the packet
  `agent-state/fleet-landing-watch/fable-check.md`, the failure counts
  (`fable-fleet-check` 226 starts / 371 failures, `-opus` 267 / 566, `-kimi`
  120) and the ~600 paid flagship invocations a week.
- `config/grafana/provisioning/alerting/` on `main` — read through
  `git ls-tree -r --name-only origin/main`, which returns 7 alerting rule files
  (`cloudflare-spend-contact`, `cloudflare-spend-delivery`, `cloudflare-spend`,
  `cpu-pressure`, `paid-plan-idle`, `prompt-cache-hit`, `router-dead-row`).
- `gh pr view 8954 -R Nishfleet/fleet-ops --json state,mergedAt` → `MERGED`,
  `mergedAt=2026-09-29T12:00:09Z`, "Cut the scheduled agent jobs and the extra
  workflows"
