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
Mac, and all 11 are retired. Ten were retired outright, one of those ten — the
weekly gardener — earlier than the rest. The last one, the weekly `seofixkit`
database export, is retired too, by the product repo itself: that repo deleted
the export script and its scheduler on 2026-10-23 and moved its restore path to
stock D1 Time Travel. The one question that path leaves open belongs to that
repo and is Nish's, so fleet-ops#9527's hand-off is superseded rather than
built, and that issue closes as superseded when this lands.

## The two backup tasks

The issue asked for these two first, because a missed backup breaks a release
gate. Both end retired, but for different reasons, and the difference matters.

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
- **`seofixkit-weekly-d1-backup` — retired, by the product repo.** The Mac task
  ran `ops/backup-d1.sh` through wrangler OAuth, and the Mac held the only
  session that script could use. The script and its out-of-repo scheduler are
  both gone: that repo's glue audit deleted them on 2026-10-23
  (Nishfleet/seo-fix-kit#304, PR #307, squash `5e978e0d`), and its
  `docs/restore-runbook.md` documents only the stock restore path — D1 Time
  Travel, always on, the last 30 days, no statement-size limit, nothing to
  schedule — and records why the dump went: the 2026-06-12 rehearsal hit
  `SQLITE_TOOBIG` on oversized `audit_reports.report_json` rows, "so a dump
  import would silently drop report bodies, and being weekly it could lose up to
  a week of writes".

  **Hand-off superseded.** fleet-ops#9527 asked for a weekly export in that
  repo's own CI, using the `cf` CLI and the Cloudflare token that repo already
  holds. Nothing is built: the issue was filed on 2026-10-09, that repo deleted
  the script on 2026-10-23, and a CI job would rebuild the same weekly, partial,
  same-account dump it had just removed. The token would not have carried it
  either — the managed `seo-fix-kit` entry in `infra/cloudflare-tokens` grants
  Workers Scripts, D1, Queues and Account Settings and no R2 permission, so an
  upload to `seofixkit-backups` needs a scope change to a repo secret, which is
  Nish's.

  What Time Travel does not cover is an open decision, and it is Nish's, in
  Nishfleet/seo-fix-kit#308: a copy that survives the database's own deletion, or
  one older than 30 days. Cloudflare's Workflows export guide is named there as
  the stock answer if the answer is yes — it runs inside the account on a
  schedule, with no host scheduler and no shell script. Nothing is built here or
  in that repo's CI until he decides.

  The loose user unit that stood in for the Mac task in October is gone too, so
  this box no longer schedules the export. fleet-ops#10145 and fleet-ops#10150
  retired it: the deploy stops and disables the timer, then deletes the three
  host paths. The unit pair that the second of those said had moved into the
  product repo never landed there — Nishfleet/seo-fix-kit#305 closed unmerged on
  2026-10-28, and no commit on that repo's default branch has ever contained
  `ops/seofixkit-d1-backup.service` — so that repo schedules nothing either.

## The other nine

| Task | Disposition | Reason |
| --- | --- | --- |
| `daily-fleet-digest` | retired | Its data source does not exist here: the task read `/home/nish/fleet2/var/` (`DIGEST.md`, `done`, `queue`, `quarantine`) and `var/scout/NEEDS-NISH.md` over ssh, and `/home/nish/fleet2` is absent on this box. Its delivery channel was the Mac's own push-notification tool. The same one-pager now runs here twice a day — `hermes cron list` shows `digest-morning` (08:00 IST) and `digest-evening` (20:00 IST), both active, both delivering to Telegram, last run `ok`. |
| `drive-mac-walk` | retired | macOS GUI walk through the `cua-driver` tools. This box has no display, and desktop work here runs only inside Cua Spaces (fleet-ops#9297, #9298). Its own gate never opened — `gh issue view 760 -R nish3451/drive` answers `OPEN REOPENED`. |
| `fleet-gate-ram-decision` | retired | The admission gate it audited is gone (`/home/nish/workspaces/agent-state/gate` is absent) and this box now reports 31 GiB across 12 vCPU, double the 16 GB the question was asked about. |
| `fleet-steer-heartbeat` | retired | It ran from the Mac over ssh every 4 hours and sent one short Telegram message with fleet state. The Mac's ssh path is gone, and its cadence duplicated the twice-daily digest jobs that do run here. Its closest VPS twin, the hourly `fable-fleet-check` judge trio, was cut on 2026-09-18 as a money burn — three timers running one packet through three expensive models, about 600 paid flagship calls a week, two of the three failing more often than they succeeded (`agent-state/glue-sweep/kill-list-20260918T091044Z.md` §5). No `fable-*` unit is installed on this box now, and re-adding a 4-hour LLM judge would rebuild exactly that burn. What does run and covers the ground is the `hermes` digest jobs and the Grafana alerting rules provisioned under `config/grafana/provisioning/alerting/`. The CI-runner decision is made by hand (the hourly `blacksmith-flip.timer` was retired in fleet-ops#9670). |
| `github-minutes-reset-check` | retired | The PR it watched answers `state=CLOSED` with `mergedAt: null` (0509#770, closed 2026-08-18). The CI-runner decision it existed to make is now made by hand (an hourly `blacksmith-flip.timer` owned it until fleet-ops#9670). |
| `inbox-14-gmail-check` | retired | Its own description says DISABLED: it was created from a server session, points at a `/home/nish` path that does not exist on the Mac, and could never start. Gmail is reachable only through the Mac's Claude connector. |
| `monthly-rulebook-redteam` | retired | The "Rulebook red-team cadence" rule it enforced is no longer in the binding rules file — it survives only in `standing-rules-archive.md`, which is history, not instruction. The Mac rulebook files it audited (`~/.codex/AGENTS.md`, `~/.codex/memories/profile.md`) do not exist on this box. |
| `scorecard-mac-helper` | retired | The weekly scorecard already runs here — `hermes cron list` shows `scorecard-weekly` (Mondays 09:00 IST), active, delivering to Telegram. The Mac column it fed came from counting Nish's typed messages in `~/.claude/projects` on the Mac, and that has no source once the Mac is off. It also spent ten paid judge calls a week, which this retires with it. |
| `weekly-fleet-gardener` | retired earlier | Cut on 2026-09-29 (fleet-ops#8954, merged) after filing 0 proposals. Recorded in `docs/skill-proposals.md`. |

## The digest prompts' canonical home (fleet-ops#9706)

The `digest-morning` and `digest-evening` jobs' prompt text lives in this repo:
`config/hermes/digest-morning.md` and `config/hermes/digest-evening.md`. The
live copies under `~/.hermes/cron/jobs.json` on this box are applied from these
files by `ansible/host.yml`, never edited by hand:

1. Edit the file under `config/hermes/` and land it through a PR (the shape
   gate `tests/test_digest_reply_shape.py` and the check gate
   `tests/test_digest_checks.py` run in CI; the first fails a prompt that drops
   the reply contract, the second fails a prompt that reads the wrong feed or
   uses a command the Hermes shell guard blocks). The shape gate flags a reply
   with sections, internal names, questions or asks, config advice, commands or
   paths, a first-person voice, a line whose only point is that a check passed
   or a service is live, up or running, a line that only says nothing happened,
   and any line written before the reply itself (fleet-ops#9921).
2. The deploy applies it: `fleet-host-config.service` (started on every push to
   main) runs `ansible/host.yml`, whose task "Apply config/hermes/digest-*.md to
   the live digest jobs" runs the stock `hermes cron edit <job id> --prompt`
   only when the live prompt differs from the file. A run that leaves any live
   prompt different from its file fails the task "Fail when a live digest prompt
   differs from config/hermes/", so the daily run and `--check` report drift.

The Hermes shell guard blocks a command that matches an `approvals.deny` glob
(`*curl*|*sh*` matches any `curl`, then a pipe, then `sh` anywhere after it,
and "Nishfleet" or "nish.sh" contain `sh`) and a command whose shell body its
scanner cannot resolve: a bracket test `[ ... ]`, or `x=$(...)` inside a
`for` or `while` loop. The prompt commands avoid both; keep them that way.

To check the live copy still matches the canonical file, diff them:
`diff <(jq -r '.jobs[] | select(.name=="digest-<which>") | .prompt' ~/.hermes/cron/jobs.json) config/hermes/digest-<which>.md` — no output means they match.

To switch a digest off: `hermes cron pause <job id>` stops it without deleting
anything, and `hermes cron resume <job id>` brings it back. To restore the
previous wording, `~/.hermes/cron/jobs.json.bak-9706` holds the pre-#9706
prompts (copy the old `prompt` value back with the same `hermes cron edit`
command).

## Checked, not assumed

Every reason above was checked against live state, in the run that added this
page or in the run that corrected it for fleet-ops#9527. The live-state
commands and their output:

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
- `gh api repos/Nishfleet/seo-fix-kit/contents/ops?ref=main` → HTTP 404, and
  `gh api "repos/Nishfleet/seo-fix-kit/commits?path=ops/seofixkit-d1-backup.service"`
  → `[]`, so the unit pair that stood in for the Mac task is in no commit on
  that repo's default branch
- `ls ~/.config/systemd/user/seofixkit-d1-backup.service
  ~/.config/systemd/user/seofixkit-d1-backup.timer
  ~/.config/systemd/user/timers.target.wants/seofixkit-d1-backup.timer` → all
  three answer `No such file or directory`; `find` over `/etc/systemd` and the
  user tree finds no unit of that name, and `grep -rl seofixkit-d1-backup` over
  both finds no enablement
- `rg -n -A 6 '"seo-fix-kit" = \{' infra/cloudflare-tokens/main.tf` → the
  `account` list is `Workers Scripts Write`, `D1 Write`, `Queues Write`,
  `Account Settings Read`, with no R2 group
- `gh issue view 304 -R Nishfleet/seo-fix-kit --json state,stateReason` →
  `CLOSED COMPLETED`
- `gh pr view 307 -R Nishfleet/seo-fix-kit --json state,mergedAt,mergeCommit` →
  `MERGED`, `mergedAt=2026-10-23T12:36:29Z`, squash
  `5e978e0da0fdec692bdc938c58349a66797ed081`; `gh pr view 305 -R
  Nishfleet/seo-fix-kit --json state,mergedAt` → `CLOSED`, `mergedAt=null`;
  `gh issue view 308 -R Nishfleet/seo-fix-kit --json state` → `OPEN`
- `gh issue view 760 -R nish3451/drive --json number,state,stateReason` →
  `OPEN REOPENED`
- `gh issue view 8936 -R Nishfleet/fleet-ops --json state,title` → `OPEN`,
  "Blacksmith auto-flip: hourly cheap-seat check flips CI_RUNNER at 95% of free
  minutes" (the flip this issue built was retired and the variable deleted in
  fleet-ops#9670; the open remainder is the consumer job, #9043)
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
- `docs/restore-runbook.md` in `Nishfleet/seo-fix-kit` — read through
  `gh api repos/Nishfleet/seo-fix-kit/contents/docs/restore-runbook.md?ref=main`.
  Its only restore path is D1 Time Travel, and the quoted sentence sits under
  the 2026-06-12 rehearsal: "so a dump import would silently drop report bodies,
  and being weekly it could lose up to a week of writes."
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
