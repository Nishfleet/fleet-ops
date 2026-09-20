# Observe-close for #7142 — 0509-sneaker-resale-recall-canary died on a real recall dip, then the whole mechanism retired into the 0509 Worker cron

fleet-ops#7142 (filed 2026-09-16T12:32:01Z by the unit-death dispatch,
fleet-ops#5456 A(ii)) recorded `0509-sneaker-resale-recall-canary.service`
exiting status=1 at 2026-09-16T18:02 IST and asked the claim to take the
unit's job over: diagnose from the journal, redo the work, and land it.

By the time this claim ran, both halves were already resolved: the dip
the canary caught had recovered, and the canary mechanism itself was
deliberately retired — its check now runs as app code on the 0509
Worker's own 3-hourly cron. No code change remains; this report is the
resolution record, matching the established observe-close pattern (the
#6665 record, PR #7972; the #4142 record, PR #7979; the #7234 record,
PR #7976).

## What was found

1. **The death was the guard working, not a guard bug.** The unit's own
   log (`agent-state/cron-output/0509-sneaker-resale-recall-canary.log`,
   141 runs) shows a clean PASS streak, then a FAIL streak in which
   `underarmour.com` returned `status=200 rows=0` — the /search page
   rendered but produced zero verified/likely rows for a
   coverage-bearing seed-list brand. Under 0509 main `80d555a7a`
   (main tip 2026-09-14T18:06Z → 2026-09-17T11:22Z) the log holds 13
   PASS runs then 32 consecutive FAILs; `underarmour.com` appears in
   all 32, with transient co-dips of `decathlon.com`, `jdsports.com`
   and `on.com` in two runs each. Exit 1 on a dead-ending brand is the
   canary's designed behavior (0509#1945), so the Sep-16 18:02 IST
   failure the issue was filed on was a true-positive detection of a
   production recall dip, not a defect in the unit.
2. **The dip recovered on its own; the canary went green and stayed
   green.** After 0509 `bcf4e8bcb`/`3bd3d44f2` (2026-09-17 evening IST)
   every logged run is a PASS — zero FAIL lines from that point through
   the unit's final run 2026-09-20 09:03 IST. `underarmour.com`
   recovered to 19 verified / 3 likely / 2 unmatched. The user journal
   for the unit (retained back to 2026-09-19) shows every run
   `Finished` cleanly.
3. **The mechanism was then retired by design — the check moved into
   the Worker.** 0509 `ad0af2e42` ("zero(last): scripts/ is empty —
   market-signal as SQL + workflow steps, seed-list recall as Worker
   cron", scripts-to-zero step 3, 0509#3679, committed directly to main
   by nish3451 at 2026-09-20 10:50 IST) deleted
   `scripts/canary-sneaker-resale-recall.mjs`,
   `scripts/bet2-live-verification.mjs` and the ops/ timer bundle, and
   states "The VPS timer and its checkout are removed." The replacement
   is `app/lib/sneaker-resale-recall.server.ts` — the same rule (every
   seed-list brand must show ≥1 verified or likely public-search row),
   now read from the discovery cache via `getSneakerResaleTierByDomain`
   instead of scraping /search over HTTP. `workers/app.ts` calls
   `checkSneakerResaleRecall(env)` when `controller.cron ===
   REGULAR_MONITORING_CRON` (`"0 */3 * * *"` in `workers/schedule.ts`,
   present in `wrangler.jsonc` triggers) — the identical 3-hour cadence
   — and reports `sneaker_resale_recall` through
   `reportScheduledTaskFailure`, the same failure path every other cron
   uses. Detection coverage is preserved; the hand-placed VPS unit was
   the pre-migration shim.
4. **Host state confirms the retirement is live.** On netcup-rs2000 at
   2026-09-21 ~01:45 IST: `systemctl --user cat
   0509-sneaker-resale-recall-canary.{service,timer}` → "No files
   found"; `list-timers --all` shows no recall/canary entries (the
   user-config canary set went with the same sweep —
   `timers.target.wants` last changed 2026-09-20 10:45 IST, matching
   the retirement window); `systemctl --user
   list-units --state=failed` is empty; no leftover dedicated checkout
   for the unit exists under `~/workspaces` (the commit removed it with
   the timer). Residue is one inert artifact: the historical
   `cron-output/0509-sneaker-resale-recall-canary.log`, a log file, not
   machinery.
5. **Redo-the-work proof: the exact retired canary was re-run live and
   passes today.** The deleted `scripts/canary-sneaker-resale-recall.mjs`,
   `scripts/bet2-live-verification.mjs` and
   `data/seed-lists/sneaker-resale.json` were extracted verbatim from
   0509 `ad0af2e42^` (the last revision where they existed) into /tmp
   and run as the unit ran them — `node
   scripts/canary-sneaker-resale-recall.mjs --base-url https://0509.io`.
   Result: PASS — all 26 seed-list domains return ≥1 verified/likely
   row, including `underarmour.com` (25 rows: 20 verified / 3 likely).
   The guarded surface is healthy and its guard now lives where the
   product's other cron checks live.
6. **Why the issue was still open.** The unit-death issue named a
   triage line for the observe-to-close sweep to grep; that sweep was
   itself deleted in the 2026-09-18/19 cuts (`0dc5dd4ac`, "GitHub
   closes the issue — drop the observe-to-close sweep"). This PR's
   `Closes #7142` trailer performs the close through the merged-PR
   path — the close path the fleet adopted once the sweep was retired.

## Verification

- `gh issue view 7142 -R Nishfleet/fleet-ops` → OPEN, unit-death
  dispatch for `0509-sneaker-resale-recall-canary.service`, detected
  2026-09-16T12:32:01Z, journal tail shows `status=1/FAILURE` at
  18:02 IST.
- `journalctl --user -u 0509-sneaker-resale-recall-canary.service`
  (earliest retained entry 2026-09-19 09:00 IST) → every run
  `Finished`; last run 2026-09-20 09:00→09:03 IST, then nothing.
- Canary log
  `agent-state/cron-output/0509-sneaker-resale-recall-canary.log` → 141
  runs; the FAIL streak under 0509 `80d555a7a` names
  `underarmour.com (rows=0, status=200)` in all 32 entries;
  0 FAIL lines after `bcf4e8bcb`/`3bd3d44f2` (2026-09-17 evening IST).
- 0509 main: `git merge-base --is-ancestor ad0af2e42 origin/main` →
  yes; `gh api repos/Nishfleet/0509/contents/
  scripts/canary-sneaker-resale-recall.mjs` → 404;
  `workers/schedule.ts` → `REGULAR_MONITORING_CRON = "0 */3 * * *"`;
  `workers/app.ts` → `checkSneakerResaleRecall` wired under that cron
  with `reportScheduledTaskFailure(env, "sneaker_resale_recall", ...)`;
  `wrangler.jsonc` triggers include `"0 */3 * * *"`.
- Live re-run 2026-09-21 ~01:50 IST on netcup-rs2000: extracted canary
  at `ad0af2e42^` → `node scripts/canary-sneaker-resale-recall.mjs
  --base-url https://0509.io` → "PASS: every coverage-bearing
  sneaker-resale brand returned at least one verified or likely row"
  (26 domains, all covered).
- Host: `systemctl --user cat` → no files; `list-timers --all` → no
  recall timer; `list-units --state=failed` → empty;
  `~/.config/systemd/user/` → no recall/canary unit files.

run-proof: probes above ran live on netcup-rs2000 2026-09-21 ~01:45 IST
against fleet-ops origin/main `53f882c5c` and 0509 origin/main
`ad0af2e42`-containing tip; commit ancestry via `git merge-base
--is-ancestor`; live unit state via `systemctl --user` /
`journalctl --user`; the recall re-run used the verbatim canary code
from `ad0af2e42^` against production https://0509.io; docs-only record
— no unit, timer, workflow or script path touched.

loose-ends: none — docs-only resolution record for a mechanism
deliberately retired on 0509 main with its check preserved as Worker
cron code; nothing half-done.
