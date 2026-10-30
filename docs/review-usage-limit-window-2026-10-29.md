# Review lane at the Claude usage-limit window of 2026-10-29

Measurement for #11112. It finds the window where the review seat hit its
session limit, counts the `review-risky / review` runs that went red inside it,
and counts the `review-held:` comments. #10743 fixes the red run and asks for
the first count to be 0.

## Window

The window is the span where a line in `~/.claude/projects/**/*.jsonl` carries
`"apiError":"usage_limit_reached"`. On 2026-10-29 that is:

    2026-10-29T18:29:45Z .. 2026-10-29T20:58:59Z
    12 events, one every 14 to 15 minutes

Claude printed `You've hit your session limit · resets 2:40am (Asia/Kolkata)`.

The 14 to 15 minute interval is the retry backoff: every ask in flight fails at
the same moment, and the next ask fails after the ladder
`30+60+120+240+480 s` runs out, 930 s later.

An earlier window on the same day, 15:58:39Z to 16:32:57Z, is the baseline
#10743 recorded: 21 red review runs in 34 minutes.

## Count

`review-risky / review` jobs that failed in the window, each with a PR comment
reading `did not finish: ... gave no answer`:

| run | created | PR | head |
|---|---|---|---|
| [40928306135](https://github.com/Nishfleet/fleet-ops/actions/runs/40928306135) | 18:10:35Z | 10998 | f36a8bf9 |
| [40929207605](https://github.com/Nishfleet/fleet-ops/actions/runs/40929207605) | 18:16:16Z | 10918 | f7e4e48b |
| [40929431408](https://github.com/Nishfleet/fleet-ops/actions/runs/40929431408) | 18:17:44Z | 11044 | 65410ff5 |
| [40931193478](https://github.com/Nishfleet/fleet-ops/actions/runs/40931193478) | 18:28:50Z | 11000 | a6fcdd67 |
| [40931833930](https://github.com/Nishfleet/fleet-ops/actions/runs/40931833930) | 18:32:51Z | 11045 | c87e990f |
| [40934056663](https://github.com/Nishfleet/fleet-ops/actions/runs/40934056663) | 18:47:08Z | 11048 | ef6c0098 |
| [40943150138](https://github.com/Nishfleet/fleet-ops/actions/runs/40943150138) | 19:46:54Z | 11058 | 3c9cd832 |
| [40943215923](https://github.com/Nishfleet/fleet-ops/actions/runs/40943215923) | 19:47:22Z | 11055 | 91887e31 |
| [40945232676](https://github.com/Nishfleet/fleet-ops/actions/runs/40945232676) | 20:01:03Z | 11044 | 778b4453 |
| [40945573835](https://github.com/Nishfleet/fleet-ops/actions/runs/40945573835) | 20:03:19Z | 11057 | ede67b39 |
| [40948129869](https://github.com/Nishfleet/fleet-ops/actions/runs/40948129869) | 20:20:23Z | 11037, 11048 | c11ec7d9, ef6c0098 |

That is 12 failing review jobs in 11 runs, on 11 distinct heads. The last run is
the stuck-review sweep, which re-asks for two heads the limit had already
rejected, so its two jobs are the same failure once more.

    12 failing review-risky / review jobs
    11 distinct heads held open by them
     0 review-held: comments

The other 19 failures in the same span are 10 `orchestrate` and 4 `new / work`
jobs, plus the 5 cancelled or superseded `pull_request_target` runs the sweep
replaces. They are not review failures and #11112 does not count them.

## Result

The count is 12, not 0.

The cause is the delivery order, not a regression: #10743's fix is PR #11113,
and #11113 is not merged. `origin/main`'s `agent.yml` has no `review-held`
occurrence, and the `orch/issue-10743` branch that #11113 carries has one. Until
#11113 lands, every usage-limit window turns each ask in flight into a red
review job with the same comment.

#11113 cannot land as it stands: `ratchet / ratchet` is a required check and it
fails at +23 net lines under `.github/workflows`. The fix adds the hold path and
its test cases and deletes nothing, so it is over budget on its own.

## Exit condition

The count reaches 0 when #11113 merges. The next window after that merge is the
one #11112 asked to measure, and it is the first window where the expected value
is 0. Until then this file is the baseline for the fix, and it stays true: a
window measured before `review-held` exists must show a red review run for every
head the limit reached.
