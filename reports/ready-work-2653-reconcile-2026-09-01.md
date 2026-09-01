# ready_work 87→21 reconcile — bulk close sweep + claims (fleet-ops#2653)

Report date: 2026-09-01
Issue: fleet-ops#2653 — "ready_work dropped 87->21 in one hour with only 7 claims — 59 items unaccounted. Reconcile the gauge against the actual agent-ready open issue set across enrolled reposand name which side is wrong"
Host: netcup-rs2000

## The reported snapshot (2026-09-01T11:30:11Z → 12:30:13Z)

- `fleet_ready_work` 87.0 →  21.0 (−66)
- `claims_last_2h` = 7 (5 x 0509, 2 x fleet-ops);`dispatches_last_2h`=2;`empty_runs`=0;`at_capacity`=0
- Judge hypothesis:"either items were closed/relabelled in bulk or the ready_work gauge is miscounting".

## Reconciled answer

**The gauge was counting correctly. The drop was real and fully explained. No side was miscounting.**

- 64 agent-ready issues in Nishfleet/fleet-ops were bulk-closed between 2026-09-01T11:44:02Z and 11:55:35Z — the queue-noise dedupe sweep,actor nish3451,closed as DUPLICATE/COMPLETED (spot stateReason:"Duplicate of #2636 (most recent seat credentials_bad alert...keeping latest only"` and"Gap-audit finding...superseded"`/"Likely resolved or superseded. Closing to reduce self-maintenance queue noise"`).
- 2 more were claimed at  12:11Z (fleet-ops #2538, #2594 → agent-in-progress,removed from the ready set).

The math:87 (pre-close set) − 64 (bulk closes)) −  2 (claims)) =  21 = the  12:30 gauge value. Exact. No new agent-ready issue was created in the  11:30–12:30 window(verified via `gh search issues --label agent-ready --created` = 0),so nothing masked the drop. plain

## Evidence chain

1. **Closed-in-window set** — `gh search issues --owner Nishfleet --label agent-ready --state closed --json number,repository,closedAt,title --limit  500`:64 hits,all Nishfleet/fleet-ops,closed 11:44:02Z–11:55:35Z by nish3451. Title classes:rulebook-redteam 14,seat-credentials-bad 10,worktree-sprawl 6,seat-other 6,land-or-close-pr 5,empty-run-storm 4,intake-starvation 4,self-maint-ratio 4,gap-audit 2,other 8. Spot-checked stateReason on #2634/#2628 (DUPLICATE),#2616 (DUPLICATE),#2582/#2559/#2477 (COMPLETED)
2. **Created-in-window set** — `gh search issues --owner Nishfleet --label agent-ready --created "2026-09-01T11:30:00Z..2026-09-01T12:30:00Z"`:0 hits.— no new agent-ready issue masked the drop.
3. **Claims log** — `~/workspaces/agent-state/ready-work-claims.log`,10:30–12:30 window:6 claim lines;fleet-ops #2538+#2594 at12:11 are the only fresh claims(with a net ready-set effect);the 0509 lines (#1501,#1513) are re-claims of already-in-progress items(no further count change.The judge's "7" includes those repeat lines;the count that actually REMOVES items from the ready set is exactly the  2 claims folded into the math above.
4. **Prometheus series** — `query_range fleet_ready_work 10:00→15:00Z,step 300`:85–88 through  12:25 (87 at  11:30);then21 at12:30,then18 at13:00,16 at14:00,19 at14:50 — consistent with a fresh fetch catching up after the closes+claims,and later churn(claims advancing,new agent-ready filings adding,.The persistent 87 through12:25 with the closes already completed by11:55 shows the gauge was SERVED from a cached value(up to ~1h old,because the fleet-metrics-export single-gh-fetch-per-run budget + PR_CACHE_STALE=7200s design band can serve the queue-composition family up-to-2h)until its next fresh fetch turn at~12:25–12:30. The exporter journal 12:00–12:35Z has NO "gh failed, serving stale cache" line — the stale serve took the silent path in `_cached_json` (the already-fetched-this-run branch,not the loud fetch-failure path).
5. **Live re-verification** (~16:00Z,2026-09-01:):`gh search issues --owner Nishfleet --label agent-ready --state open --json number,repository` → 26 rows;enrolled repos(Nishfleet/0509 + Nishfleet/fleet-ops)=25(15 fleet-ops +10 0509;Nishfleet/inish-site 1 non-enrolled,excluded by design).The exporter's cache(ts≈15:30,`queue-composition-cache.json`)holds ready-work total=25,and agent-ready total=26 — identical to the live count.The gauge's fresh value = the actual open agent-ready set across enrolled repos,verified twice.



## Verdict

- **Which side is wrong? Neither.** The gauge counts the open agent-ready set across enrolled repos correctly (`queue-composition-cache.json` 25 = live count  25`.`).The delta was a real bulk-close event(64 issues,queue-noise dedupe,)plus 2 claims%;no gauge fault,no fabricated drop,no counting bug.



- **The only imprecision:**the 87 read the judge saw was up to ~1h stale — the exporter's designed ≤2h PR_CACHE_STALE band + one-gh-fetch-per-run budget,served silently(no staleness signal in the snapshot.In the judge framed it as a 11:30→12:30 delta;the actual movement happened 11:44–11:55 (closes) + 12:11 (claims);the gauge simply caught up at12:30. Neither value was miscounted — one was designed-stale,the other fresh,,both count correctly. The staleness-visibility gap itself is tracked as follow-up #2684.

## Follow-ups

- **fleet-ops#2684** (filed 2026-09-01,:fleet_ready_work/queue-composition can be served from a ≤2h-old cache **silently**(the `_cached_json` already-fetched-this-run branch logs nothing),so a stale ready_work presents as current to the judge and dashboards.Proposed:staleness-visible (e.g. a cache-age signal on the ready_work family,or at minimum a stderr log line on the silent serve path,the same shape as the existing fetch-failure serve branch.

## Scope note

No code/machinery change shipped in this PR — the reconcile demand was met by live verification and this record.A queue-noise dedupe sweep legitimately dropped ready_work;the gauge is not broken;,and adding auto-bulk-close detection to the judge would suppress future genuine reconcile requests,and not strengthen them.Per fleet-ops#366,this is declared not-a-failure-fix:the judge's alarm was correct and useful(the drop was real and worth one reconcile,the flow worked,and the only weak facet — silent cache staleness on a health gauge — is filed as follow-up #2684 rather than bolted onto this closeout.