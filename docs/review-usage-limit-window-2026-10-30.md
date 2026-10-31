# Review lane at the Claude usage-limit window of 2026-10-30

Measurement for #11112, after `docs/review-usage-limit-window-2026-10-29.md`.
Same method: find the span where a line in `~/.claude/projects/**/*.jsonl`
carries `"apiError":"usage_limit_reached"`, count the `review-risky / review`
runs that went red, count the `review-held:` comments. #11113's fix is still
not merged, so a non-zero count is the expected pre-fix baseline, not a new
bug.

## Window

The seat hit its session limit twice on this day, measured from the end of the
recorded 2026-10-29 window, 20:58:59Z:

    2026-10-29T23:44:02Z .. 2026-10-30T04:28:56Z   night: 23 events on a 15-min cadence
    2026-10-30T14:25:44Z .. 2026-10-30T16:59:01Z   day:   19 events on a 15-min cadence

Claude printed
`You've hit your session limit · resets 10:10am (Asia/Kolkata)` in the night
window (reset 04:40:00Z) and `You've hit your session limit · resets 10:40pm
(Asia/Kolkata)` in the day window (reset 17:10:00Z); both rejections read `"rateLimitType":"five_hour"` with
`"overageStatus":"rejected","overageDisabledReason":"out_of_credits"`, so each
window is one five-hour period the seat spent rejected. The events fall on a
15-minute cadence, with same-minute neighbours where several asks were in
flight together, as in the 2026-10-29 window.

## Count

### Night window: 0 red review runs

45 agent-dispatch runs went red inside the night span, at the `orchestrate`
and `new / work` jobs; `review-risky` is skipped in every one of them. No
review ask was in flight at those hours, so both counts for #11112 are 0. The
review lane cannot go red when it does not run, so this window is not the fix
evidence either way.

### Day window

`review-risky / review` jobs that failed in the day window and its fallout:

| run | created | PR | head | failure comment on the PR |
|---|---|---|---|---|
| [41070419849](https://github.com/Nishfleet/fleet-ops/actions/runs/41070419849) | 14:16:29Z | 11203 | 800ad985 | none; the re-ask approved at 14:37 |
| [41071277144](https://github.com/Nishfleet/fleet-ops/actions/runs/41071277144) | 14:23:27Z | 11204 | 202e0b1d | none |
| [41071432073](https://github.com/Nishfleet/fleet-ops/actions/runs/41071432073) | 14:25:10Z | 11205 | 6dd78f9a | did not finish: the first review (claude-opus-5-5) gave no answer |
| [41074600918](https://github.com/Nishfleet/fleet-ops/actions/runs/41074600918) | 14:46:26Z | 11200 | 8d630f9f | did not finish: the first review (claude-opus-5-5) gave no answer |
| [41084595195](https://github.com/Nishfleet/fleet-ops/actions/runs/41084595195) | 15:51:44Z | 11119 | 3edf0313 | did not finish: the first review (claude-opus-5-5) gave no answer |
| [41089179281](https://github.com/Nishfleet/fleet-ops/actions/runs/41089179281) | 16:21:45Z | 11177 | 5568e9fc | did not finish: the first review (claude-opus-5-5) gave no answer |
| [41095104815](https://github.com/Nishfleet/fleet-ops/actions/runs/41095104815) | 17:01:16Z | 11221 | e20b4ff1 | Jev block on a judged review: not a limit failure |
| [41096760711](https://github.com/Nishfleet/fleet-ops/actions/runs/41096760711) | 17:12:18Z | 11228 | 48547502 | did not finish after retries: the router said: No deployments available for selected model, Try again in 1800 seconds |
| [41097910116](https://github.com/Nishfleet/fleet-ops/actions/runs/41097910116) | 17:20:09Z | 11229 | 6efeed9b | the same router-cooldown wording |
| [41099127481](https://github.com/Nishfleet/fleet-ops/actions/runs/41099127481) | 17:28:29Z | 11113 | c7e92240 | the same router-cooldown wording |

That is 10 red `review-risky / review` jobs across the day window and its
fallout, on 10 heads, of which 9 are limit-family:

    6 red review jobs in the same limit cluster (14:16 .. 16:21), 6 heads.
      The cluster runs are counted by run creation time, and the 14:16 and
      14:23 runs sit before the first recorded 429 line, the same shape as
      the 2026-10-29 window, whose first red run at 18:10:35Z also precedes
      its first recorded event at 18:29:45Z
    4 of them carry the "gave no answer" comment the #11112 count reads
    2 carry no comment; their re-asks recovered within 25 min
    3 more red review jobs in the 17:01 .. 17:28 fallout, after the 17:10 reset
      (the router keeps the seat cold with "Try again in 1800 seconds")
    1 of the 10 is a judged block, not a limit failure, and is not counted
    1 red review-risky / arm job [41097652186](https://github.com/Nishfleet/fleet-ops/actions/runs/41097652186)
      at 17:18 whose review had passed; the approval followed at 17:36
     0 review-held: comments

The 4-run total for the exact wording #11112 counts is not 0. Counting
routinely is impossible from the comment alone, because the same limit then
spoke in three shapes: silent recovery, "gave no answer", and the router's
"No deployments available" cooldown.

## Result

The count is not 0, and the cause is the one the 2026-10-29 measurement
recorded: the fix that holds the head is not on main. The delivery gate is
unchanged — merge #11113 (or #11202, the branch carrying the same fix), then
the next window is the first where 0 is the expected value.

## Exit condition

`review-held: <sha>` comments, not red `review-risky / review` runs. One per
ask the limit rejects, added by `agent.yml` once the fix merge lands.
