# The Mac's 11 desktop scheduled tasks: disposition (fleet-ops#9519)

The Mac that ran these tasks was switched off on 2026-10-09
([mac-rescue-2026-10-09.md](mac-rescue-2026-10-09.md) records that date). Its 11
scheduled tasks and their prompts were copied off it first, into
`/home/nish/workspaces/tooling/mac-rescue-20261009/claude-scheduled-tasks.tar`
(see [mac-rescue-2026-10-09.md](mac-rescue-2026-10-09.md) for that folder's
disposition). That copy stays off this public repo. Each task's `SKILL.md`
inside it is the source for what the task actually did. Every reason below was
checked against those `SKILL.md` files and against live state on this box, not
read from memory. Vault files cited below live under
`/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/`, which is the
root the vault's own status note records.

**No clock is added on this box.** No task moves to a VPS timer, so nothing is
built here (the GLUE-ZERO rule in `docs/ARCHITECTURE.md`). All 11 leave the Mac.
Ten are retired outright, and one of those ten — the weekly gardener — was
retired earlier. The last one, the weekly `seofixkit` database export, also
leaves the Mac, but its capability has a next home in that product repo's own
CI, and that CI needs a weekly schedule there, so it is handed to the
coordinator instead of getting a tombstone.

`seofixkit` is this repo's short name for the SEO Fix Kit product repo. That
repo is public, and this box's GitHub token can read public repos, but its
installation — the only repo it can write to — is fleet-ops alone
(`gh api /installation/repositories` → `total_count: 1`).

## The two backup tasks

The issue asked for these two first, because a missed backup breaks a release
gate. They do not end the same way, and the difference matters.

- **`0509-weekly-d1-backup` — retired, nothing to port.** The task exported the
  production D1 database `0509` to an R2 bucket through wrangler logged in on
  the Mac, so the Mac held the only OAuth session it could use.
- The export script and its validator are gone from that repo's `main`. The
  repo itself is readable, so the 404 is a missing path and not a permission
  denial: `gh api repos/Nishfleet/0509` answers `"private": false`, and
  `gh api repos/Nishfleet/0509/contents/wrangler.jsonc?ref=main` answers 200,
  while `gh api repos/Nishfleet/0509/contents/scripts?ref=main` answers HTTP 404.
- That repo's own recovery doc records the decision in its own words — "No
  script, no cron, no helper. Time Travel is the platform feature and needs none.
  Nothing in this repository runs a backup" (`docs/REBUILD-DONE.md`, the
  2026-09-22 bullet, written `[0922]` there) — with a recovery window of about 30
  days and a re-checked-live Time Travel bookmark in the 2026-09-28 bullet
  (`[0928]`).
- The nightly `snapshot-backup` Workflow (0509#5802) copies site-snapshot
  objects from `0509-snapshots` to `0509-snapshots-backup` at 05:00 UTC. That is
  a snapshot-objects copy, not a database export, so it does not stand in for the
  D1 export. The platform's Time Travel does, by that repo's own recorded
  decision. Nothing is lost by letting the Mac task die.
- **`seofixkit-weekly-d1-backup` — retired from the Mac, capability still
  open.** The weekly export script still exists in the `seofixkit` product repo
  (`ops/backup-d1.sh`), and the Mac task was its only scheduler.
- That repo's `.github/workflows` holds `deploy-production.yml`, `pr-check.yml`
  and `secret-scan.yml` and no scheduled backup job.
- The task runs through wrangler OAuth on the Mac, which this box cannot hold.
  Wrangler is banned fleet-wide: the vault's `global-standing-rules.md` says
  Cloudflare work uses the `cf` CLI and "No Wrangler, in any repo, CI job,
  packet or skill" (Nish, 2026-09-28). That is also why the replacement uses
  `cf` and not wrangler.
- **Hand-off.** Move the weekly export into that product repo's own CI, which
  already holds a Cloudflare token for it — `deploy-production.yml` sets
  `CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}`.
- The work needs the Cloudflare API, which the worker jail cannot reach
  (AGENTS.md), so it goes to the coordinator rather than being solved with an
  ad-hoc credential.
- The hand-off is tracked in a plain issue, fleet-ops#9527, filed in this repo
  with no label. A label here would put Cloudflare work in the worker queue, and
  this box's token cannot file in the product repo anyway.
- The coordinator sees it from this PR's body and from the open-issue list,
  because a docs-only change self-arms: the arm step's own allowlist carries
  `docs/`, so no coordinator review happens on this PR.

## The other nine

| Task | Disposition | Reason |
| --- | --- | --- |
| `daily-fleet-digest` | retired | Its data source does not exist here: the task read `/home/nish/fleet2/var/` (`DIGEST.md`, `done`, `queue`, `quarantine`) and `var/scout/NEEDS-NISH.md` over ssh, and `/home/nish/fleet2` is absent on this box. Its delivery channel was the Mac's own push-notification tool. The same digest job now runs here twice a day — `hermes cron list`, from this box's job scheduler, shows `digest-morning` (08:00 IST) and `digest-evening` (20:00 IST), both active, both delivering to Telegram, last run `ok`. |
| `drive-mac-walk` | retired | macOS GUI walk through the `cua-driver` tools. This box has no display, and desktop work here runs only inside Cua Spaces (fleet-ops#9297, #9298), the hosted browser-desktop service that replaced local desktop automation. Its own gate never opened — `gh issue view 760 -R nish3451/drive` answers `OPEN REOPENED`. |
| `fleet-gate-ram-decision` | retired | Its own description asks whether 16 GB is limiting fleet output, and the admission gate it audited is gone (`/home/nish/workspaces/agent-state/gate` is absent). This box now reports 31 GiB across 12 vCPU, about twice the 16 GB the question was asked about. |
| `fleet-steer-heartbeat` | retired | It ran every 4 hours from the Mac, whose `ssh netcup-rs2000` alias no longer exists. See the note below the table for what covered its checks and why its judge twin does not run. |
| `github-minutes-reset-check` | retired | Its own description is "Re-test GitHub-hosted runner availability after monthly minutes reset; reopen PR 770 if green". The PR it would reopen answers `state=CLOSED` with `mergedAt: null` (0509#770, closed 2026-08-18). The CI-runner decision it existed to make is now owned by this repo's own hourly `blacksmith-flip.timer` (fleet-ops#8936), the timer that flips the CI runner when free minutes run low. |
| `inbox-14-gmail-check` | retired | Its own description says DISABLED: it was created from a server session, so it points at a `/home/nish` path that does not exist on the Mac and it could never start. The description also says the Gmail check now runs in the server session instead. |
| `monthly-rulebook-redteam` | retired | The "Rulebook red-team cadence" rule it enforced is no longer in the binding rules file — it survives only in `standing-rules-archive.md`, which is history, not instruction. The Mac rulebook files it audited (`~/.codex/AGENTS.md`, `~/.codex/memories/profile.md`) do not exist on this box. |
| `scorecard-mac-helper` | retired | The weekly scorecard already runs here — `hermes cron list` shows `scorecard-weekly` (Mondays 09:00 IST), active, delivering to Telegram. The Mac column it fed came from counting Nish's typed messages in `~/.claude/projects` on the Mac, and that has no source once the Mac is off. It also spent ten paid judge calls a week (its own description has it "grade 10 merged 0509 PRs"), which this retires with it. |
| `weekly-fleet-gardener` | retired earlier | Cut on 2026-09-29 (fleet-ops#8954, merged) after filing 0 proposals. Recorded in `docs/skill-proposals.md`. |

### `fleet-steer-heartbeat` in full

The task's own checks were stale feeds, backlog-console dashboard freshness,
saturation decisions, lane errors and restic backups under 24h old. Each has a
live owner on this box now:

- The twice-daily digest jobs from `hermes cron`, listed above.
- The Grafana alerting rules provisioned under
  `config/grafana/provisioning/alerting/`, which hold the spend, CPU, idle and
  router alerts.
- `blacksmith-flip.timer`, which is hourly.

Its closest VPS twin was the hourly fleet judge, `fable-fleet-check`. That judge
was cut on 2026-09-18 as a money burn: three timers ran one packet through three
expensive models, about 600 paid flagship calls a week. In that sweep's own
words, "Two of three fail more often than they succeed", and its 7-day counts are
226 starts / 371 failures for `fable-fleet-check` and 267 / 566 for `-opus`,
where the failure counter runs above the start counter
(`agent-state/glue-sweep/kill-list-20260918T091044Z.md` §5). No `fable-*` unit is
installed on this box now. Re-adding a 4-hour LLM judge would rebuild exactly
that burn.

## Checked, not assumed

Every reason above was checked against the rescued `SKILL.md` files and against
live state on this box, not read from memory. The tar's checksum verifies
(`claude-scheduled-tasks.tar: OK`), and the reason in each row quotes that
task's own `description` line or its own body: `daily-fleet-digest` names
`/home/nish/fleet2` and the PushNotification tool, `drive-mac-walk` names
`cua-driver` and the gate issue, `fleet-gate-ram-decision` names the 16 GB
question, `fleet-steer-heartbeat` names the 4-hour cadence and the ssh host,
`github-minutes-reset-check` names PR 770, `inbox-14-gmail-check` says DISABLED
in its own description, `scorecard-mac-helper` names the typed-message count and
Jev grading, and `weekly-fleet-gardener` names the memory consolidation.

The live-state commands and their output:

- `tar -tf /home/nish/workspaces/tooling/mac-rescue-20261009/claude-scheduled-tasks.tar`
  → the 11 task directories, each holding the `SKILL.md` quoted above.
  `sha256sum -c SHA256SUMS.txt` in the same folder answers
  `claude-scheduled-tasks.tar: OK`.
- `ls /home/nish/fleet2` → `No such file or directory`
- `ls /home/nish/workspaces/agent-state/gate` → `No such file or directory`
- `ls /home/nish/workspaces/agent-state/fleet-landing-watch/fable-check.md` →
  present, and its header reads "You are one of two hourly fleet judges". That
  header is the packet's own wording, and it is stale: the sweep's kill-list
  names three timers, so the packet text predates the third judge.
- `find /usr/lib/systemd/user /usr/local/lib/systemd/user /etc/systemd/user
  /etc/systemd/system /home/nish/.config/systemd /home/nish/.local/share/systemd/user
  -maxdepth 2 -name 'fable*'` → no output. Two of the six directories do not
  exist on this box and `find` reports them on stderr. `systemctl --user
  list-unit-files 'fable*'` cannot run in the worker jail (it answers `Failed to
  connect to bus: No data available`), which is why the check is a filesystem
  walk instead.
- `ls /home/nish/.codex/AGENTS.md` → absent, and
  `ls /home/nish/.codex/memories/profile.md` → absent
- `grep -n 'RULEBOOK RED-TEAM CADENCE'
  /home/nish/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md`
  → no match, and the same grep on
  `.../nish-vault/_system/shared-memory/standing-rules-archive.md` → line 504
- `hermes cron list` → `digest-morning` (08:00 IST, telegram, last run `ok`),
  `digest-evening` (20:00 IST, telegram, last run `ok`), `scorecard-weekly`
  (Mondays 09:00 IST, telegram, last run `ok`)
- `free -g` → 31 GiB total
- `nproc` → 12
- `gh api /installation/repositories --jq '.total_count'` → 1
- `gh pr view 770 -R Nishfleet/0509 --json number,state,closedAt,mergedAt` →
  `state=CLOSED closedAt=2026-08-18T05:56:29Z mergedAt=null`
- `gh api repos/Nishfleet/0509 --jq '.private'` → `false`, so the 404 below is a
  missing path and not a permission denial
- `gh api repos/Nishfleet/0509/contents/scripts?ref=main` → HTTP 404
- `gh api repos/Nishfleet/0509/contents/workers/workflows/snapshot-backup.ts?ref=main`
  → 200, and `grep -n '0 5 \* \* \*'` on the file's own content answers line 14,
  `schedule: { type: "crontab", value: "0 5 * * *" }`
- `gh api repos/Nishfleet/0509/contents/wrangler.jsonc?ref=main` → 200, and the
  comment at its line 196 reads "nightly copy target of the snapshot-backup
  Workflow below and carries the" (0509#5802)
- `gh api repos/nish3451/seo-fix-kit/contents/ops/backup-d1.sh?ref=main` →
  `backup-d1.sh`
- `gh api repos/nish3451/seo-fix-kit/contents/.github/workflows?ref=main` →
  `deploy-production.yml`, `pr-check.yml`, `secret-scan.yml`
- `gh api repos/nish3451/seo-fix-kit/contents/.github/workflows/deploy-production.yml?ref=main`
  → `CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}` and
  `CLOUDFLARE_ACCOUNT_ID`, so that repo's own CI already holds a Cloudflare
  token for the replacement export
- `gh issue view 760 -R nish3451/drive --json number,state,stateReason` →
  `OPEN REOPENED`
- `gh issue view 8936 -R Nishfleet/fleet-ops --json state,title` → `OPEN`,
  "Blacksmith auto-flip: hourly cheap-seat check flips CI_RUNNER at 95% of free
  minutes"
- `git show origin/main:systemd/blacksmith-flip.timer` → `Description=Hourly
  Blacksmith CI_RUNNER auto-flip (fleet-ops#8936)`, `OnCalendar=hourly`,
  `Persistent=true`
- `gh pr view 8954 -R Nishfleet/fleet-ops --json number,state,title,mergedAt` →
  `state=MERGED`, "Cut the scheduled agent jobs and the extra workflows",
  `mergedAt=2026-09-29T12:00:09Z`
- `gh issue view 9527 -R Nishfleet/fleet-ops --json number,state,labels` →
  `number=9527`, `state=OPEN`, `labels=[]`
- `grep -n 'GLUE-ZERO' docs/ARCHITECTURE.md` → line 43, "## GLUE-ZERO — no
  hand-rolled code"
- `grep -n 'safe=' .github/workflows/agent.yml` → line 455, whose pattern list
  ends with `docs/`, which is why this docs-only PR self-arms
- `grep -n 'No Wrangler'
  /home/nish/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md`
  → line 31, the `cf` CLI rule quoted above
- `grep -n 'gardener' docs/skill-proposals.md` → line 17, "The weekly gardener
  was cut on 2026-09-29 (fleet-ops#8954) and filed 0 skill"

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
