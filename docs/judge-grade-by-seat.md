# Judge grade by seat

Measured Opus-grade D/F rate for 0509 worker PRs, per worker seat and per issue
label, over the 7-day window ending 2026-09-23T21:41:32Z. Doc-only measurement
for fleet-ops#8478 (parent: #8420).

Numbers were pulled on 2026-09-23T21:41Z with the commands below. Nothing is
modelled or estimated; every figure is a count over the PRs named in table 1.

## Method

Window: `created:>=2026-09-16` (2026-09-16T00:00:00Z) through
2026-09-23T21:41:32Z UTC.

1. **PR list.** `gh pr list -R Nishfleet/0509 --state all --author "app/nishfleet-worker" --search "created:>=2026-09-16" --limit 500 --json number,headRefName,createdAt` returned 292 PRs; only the 287 whose `headRefName` matches `claim/issue-<N>` are in scope here.
2. **Grade.** `gh pr view <pr> -R Nishfleet/0509 --json comments --jq "[.comments[] | select(.body | startswith(\"Opus grade:\"))]"` then the letter after `Opus grade:`. sticky comment: current letter, not guaranteed first — the grader's `use_sticky_comment: true` action did not collapse to one comment, and 104 of the 164 graded PRs carry more than one grade comment (a re-grade after each push), so the current letter is the LAST comment's letter. A table below also carries the first posted comment for contrast. PRs with no grade comment go in the `ungraded` column and are excluded from every rate.
3. **Seat.** `journalctl --user --since -7d -o json --no-pager -u 'pi-issue@0509-*.service' -u 'router-issue@0509-*.service' -u 'cursor-issue@0509-*.service' -u 'devin-issue@0509-*.service'` with `.USER_UNIT // ._SYSTEMD_USER_UNIT` as the owning unit (`_SYSTEMD_USER_UNIT` alone reads `init.scope` for the manager's own lines), the earliest record per unit instance as its first journal line. If more than one engine ran issue N, the seat is the engine whose first journal line is the latest one still before the PR's `createdAt`.
4. **Labels.** `gh issue view <N> -R Nishfleet/0509 --json labels`, ignoring the workflow labels `agent-ready`, `agent-in-progress`, `agent-blocked`, `needs-split`, `cheap-ok`, `strong-only`, `epic`, `blocked-by-judge`.

Seat labels come from each unit's `PI_SEAT_MODEL` in `systemd/`:
`pi-issue` = `grok-4.7:xhigh`, `router-issue` = `worker-capable`,
`cursor-issue` (CLI flag `--model grok-4.7-xhigh`, no `PI_SEAT_MODEL`),
`devin-issue` (CLI flag `--model swe-2-max`, no `PI_SEAT_MODEL`).

**Two coverage limits the reader has to hold in mind:**

* **Journal retention.** `journalctl --user --since -7d` on this host only
  reaches back to 2026-09-22T13:54:26Z (active + archived journals are 260.8M,
  vacuumed), so runs earlier in the window have no journal line left. 180 of
  287 PRs are seat `unknown`: no journal line at all, or the instance's only
  surviving first line is after the PR was created (a re-run of an issue whose
  original run was rotated out). Both cases are `unknown`; the seat rule above
  needs a first line *before* `createdAt`, and in both cases there is none.
  Every seat-specific row below therefore covers 2026-09-22T13:55Z onward only.
* **Grading started inside the window.** The first graded PR is #3941 at
  2026-09-21T19:32:55Z, so PRs created before that account for most of the 123
  ungraded ones.

44 PRs whose issue carried no label other than the ignored workflow labels are
excluded from table 2 (they are still in table 1). A PR with two non-workflow
labels counts once in each of that seat's label rows, so table 2's `graded`
denominators do not sum to 164.

## Table 1 — by seat

| seat | PRs | graded | ungraded | D/F | first-grade D/F % | PR numbers |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| cursor-issue | 33 | 33 | 0 | 13 | 39% | #4206 #4214 #4215 #4223 #4235 #4237 #4238 #4241 #4245 #4249 #4254 #4260 #4268 #4273 #4283 #4284 #4285 #4289 #4292 #4302 #4312 #4337 #4340 #4341 #4343 #4344 #4345 #4348 #4453 #4491 #4517 #4549 #4560 |
| devin-issue | 26 | 26 | 0 | 3 | 12% | #4213 #4231 #4240 #4286 #4299 #4300 #4304 #4307 #4319 #4336 #4370 #4387 #4436 #4446 #4450 #4452 #4459 #4461 #4492 #4493 #4494 #4495 #4512 #4514 #4515 #4519 |
| pi-issue grok-4.7:xhigh | 30 | 30 | 0 | 11 | 37% | #4338 #4372 #4373 #4374 #4375 #4376 #4377 #4378 #4379 #4381 #4384 #4447 #4448 #4449 #4451 #4454 #4455 #4456 #4457 #4458 #4463 #4464 #4465 #4466 #4467 #4490 #4513 #4569 #4577 #4582 |
| router-issue worker-capable | 18 | 18 | 0 | 7 | 39% | #4211 #4212 #4216 #4217 #4221 #4222 #4236 #4255 #4263 #4271 #4277 #4278 #4279 #4291 #4294 #4297 #4346 #4386 |
| unknown | 180 | 57 | 123 | 7 | 12% | #3574 #3575 #3580 #3588 #3590 #3594 #3595 #3596 #3600 #3601 #3605 #3609 #3611 #3612 #3625 #3627 #3628 #3629 #3630 #3632 #3634 #3637 #3638 #3642 #3643 #3647 #3649 #3650 #3654 #3655 #3656 #3657 #3658 #3660 #3661 #3662 #3663 #3664 #3665 #3667 #3668 #3672 #3674 #3680 #3683 #3688 #3694 #3696 #3697 #3698 #3699 #3700 #3701 #3702 #3703 #3704 #3707 #3708 #3709 #3710 #3713 #3715 #3725 #3726 #3727 #3728 #3729 #3734 #3735 #3737 #3745 #3746 #3749 #3751 #3752 #3754 #3755 #3769 #3771 #3785 #3791 #3797 #3799 #3800 #3804 #3805 #3807 #3809 #3811 #3812 #3813 #3819 #3820 #3823 #3827 #3829 #3830 #3833 #3834 #3836 #3838 #3839 #3849 #3850 #3851 #3853 #3854 #3855 #3856 #3857 #3859 #3865 #3867 #3869 #3873 #3876 #3882 #3883 #3890 #3902 #3937 #3939 #3941 #3943 #3945 #3952 #3953 #3954 #3958 #3959 #3960 #3963 #3964 #3991 #4028 #4081 #4168 #4169 #4170 #4175 #4176 #4177 #4178 #4188 #4191 #4192 #4193 #4194 #4195 #4197 #4198 #4199 #4200 #4201 #4202 #4203 #4204 #4205 #4209 #4545 #4546 #4548 #4554 #4558 #4559 #4563 #4564 #4565 #4567 #4571 #4572 #4575 #4580 #4583 #4584 #4590 #4591 #4593 #4594 #4596 |
| **all** | **287** | **164** | **123** | **41** | **25%** | |

## Table 2 — by seat x label

Current letter. One row per seat x label with at least 1 graded PR, grouped by
seat.

| seat | label | graded | D/F | first-grade D/F % |
| --- | --- | ---: | ---: | ---: |
| cursor-issue | machine-reported | 1 | 1 | 100% |
| cursor-issue | needs-nish-decision | 6 | 4 | 67% |
| cursor-issue | critical-path | 25 | 10 | 40% |
| cursor-issue | agent-failed | 4 | 2 | 50% |
| cursor-issue | enhancement | 2 | 1 | 50% |
| cursor-issue | scout-candidate | 1 | 1 | 100% |
| cursor-issue | priority-now | 4 | 1 | 25% |
| cursor-issue | bug | 1 | 0 | 0% |
| devin-issue | agent-failed | 3 | 1 | 33% |
| devin-issue | critical-path | 25 | 3 | 12% |
| devin-issue | enhancement | 3 | 0 | 0% |
| devin-issue | needs-nish-decision | 2 | 0 | 0% |
| devin-issue | priority-now | 3 | 0 | 0% |
| devin-issue | scout-candidate | 1 | 0 | 0% |
| pi-issue grok-4.7:xhigh | needs-nish-decision | 1 | 1 | 100% |
| pi-issue grok-4.7:xhigh | enhancement | 6 | 4 | 67% |
| pi-issue grok-4.7:xhigh | agent-failed | 9 | 4 | 44% |
| pi-issue grok-4.7:xhigh | critical-path | 30 | 11 | 37% |
| pi-issue grok-4.7:xhigh | needs-orchestrator | 1 | 0 | 0% |
| router-issue worker-capable | bug | 1 | 1 | 100% |
| router-issue worker-capable | deploy-regression | 1 | 1 | 100% |
| router-issue worker-capable | needs-orchestrator | 1 | 1 | 100% |
| router-issue worker-capable | critical-path | 14 | 6 | 43% |
| router-issue worker-capable | needs-nish-decision | 2 | 1 | 50% |
| router-issue worker-capable | priority-now | 2 | 1 | 50% |
| unknown | priority-now | 4 | 2 | 50% |
| unknown | critical-path | 46 | 7 | 15% |
| unknown | agent-failed | 3 | 0 | 0% |
| unknown | needs-nish-decision | 6 | 0 | 0% |
| unknown | enhancement | 2 | 0 | 0% |
| unknown | needs-orchestrator | 1 | 0 | 0% |

rule: routing change applies to seat x label rows with graded >= 6 and first-grade D/F % > 30

On the current letter, 6 rows trip that rule: `cursor-issue x critical-path`
(40%), `cursor-issue x needs-nish-decision` (67%), `pi-issue grok-4.7:xhigh x
critical-path` (37%), `pi-issue grok-4.7:xhigh x enhancement` (67%),
`pi-issue grok-4.7:xhigh x agent-failed` (44%) and `router-issue worker-capable
x critical-path` (43%). The only seat x label cell above the threshold with
`graded >= 6` and a seat of `unknown` is nowhere near it (15%).

## First posted comment, for contrast

Because the grader re-grades on every push, the current letter is the score
after iteration and the first comment is the first-pass score. Same 164 graded
PRs, first comment's letter:

| seat | graded | D/F | first-grade D/F % |
| --- | ---: | ---: | ---: |
| pi-issue grok-4.7:xhigh | 30 | 22 | 73% |
| cursor-issue | 33 | 22 | 67% |
| devin-issue | 26 | 17 | 65% |
| router-issue worker-capable | 18 | 11 | 61% |
| unknown | 57 | 14 | 25% |
| **all** | **164** | **86** | **52%** |

The same comparison per seat x label, on the first posted comment's letter, in
table 2's row order:

| seat | label | graded | D/F | first-grade D/F % |
| --- | --- | ---: | ---: | ---: |
| cursor-issue | machine-reported | 1 | 1 | 100% |
| cursor-issue | needs-nish-decision | 6 | 5 | 83% |
| cursor-issue | critical-path | 25 | 17 | 68% |
| cursor-issue | agent-failed | 4 | 4 | 100% |
| cursor-issue | enhancement | 2 | 2 | 100% |
| cursor-issue | scout-candidate | 1 | 1 | 100% |
| cursor-issue | priority-now | 4 | 3 | 75% |
| cursor-issue | bug | 1 | 1 | 100% |
| devin-issue | agent-failed | 3 | 3 | 100% |
| devin-issue | critical-path | 25 | 16 | 64% |
| devin-issue | enhancement | 3 | 2 | 67% |
| devin-issue | needs-nish-decision | 2 | 1 | 50% |
| devin-issue | priority-now | 3 | 1 | 33% |
| devin-issue | scout-candidate | 1 | 1 | 100% |
| pi-issue grok-4.7:xhigh | needs-nish-decision | 1 | 0 | 0% |
| pi-issue grok-4.7:xhigh | enhancement | 6 | 4 | 67% |
| pi-issue grok-4.7:xhigh | agent-failed | 9 | 7 | 78% |
| pi-issue grok-4.7:xhigh | critical-path | 30 | 22 | 73% |
| pi-issue grok-4.7:xhigh | needs-orchestrator | 1 | 1 | 100% |
| router-issue worker-capable | bug | 1 | 1 | 100% |
| router-issue worker-capable | deploy-regression | 1 | 1 | 100% |
| router-issue worker-capable | needs-orchestrator | 1 | 1 | 100% |
| router-issue worker-capable | critical-path | 14 | 10 | 71% |
| router-issue worker-capable | needs-nish-decision | 2 | 2 | 100% |
| router-issue worker-capable | priority-now | 2 | 1 | 50% |
| unknown | priority-now | 4 | 2 | 50% |
| unknown | critical-path | 46 | 13 | 28% |
| unknown | agent-failed | 3 | 1 | 33% |
| unknown | needs-nish-decision | 6 | 2 | 33% |
| unknown | enhancement | 2 | 0 | 0% |
| unknown | needs-orchestrator | 1 | 0 | 0% |

## What the numbers do and do not support

* Every resolved seat landed in a band of 12% to 39% on the current letter, so
  the seat dimension alone separates nothing here.
* On the first posted comment every resolved seat is 61% to 73% D/F. The 104
  re-graded PRs are where the difference lives, and which letter is the one a
  routing decision is meant to act on is not settled by this measurement.
* `graded >= 6` is met by `critical-path` and the four named seats, and by
  `agent-failed` at `cursor-issue` (4 graded, below the threshold) and
  `pi-issue grok-4.7:xhigh` (9 graded). Everything else is n < 6, so single-PR
  rows of 100% carry no weight.
* 180 of 287 PRs are seat `unknown`, all of them seated before the rotation
  floor, so no seat-level conclusion covers the full 7-day window.
