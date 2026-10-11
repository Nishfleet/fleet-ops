# 2026-10-10: the evening digest delivered three times for one slot

Blameless. Times are IST (+05:30). Run data comes from the box's own cron ledger,
`~/.hermes/cron/executions.db`, read read-only. Job ids are hermes cron job ids.

## Impact

The 20:00 IST evening digest slot of 2026-10-10 was served and delivered once by
its own scheduled run, then served and delivered twice more, at 23:26 and 23:38.
Nish received the same 12-hour digest three times, the second and third 3 h 26 m
and 3 h 38 m after the slot started. The two late runs produced the same content
in ~12 KB files against the normal ~5.5 KB, so they were near-duplicates rather
than new information.

No other digest slot that week was affected.

## Timeline

- 20:00:42 `83234c69018e4d03917673afa98912dd` — `source=builtin`,
  `scheduled_instant=2026-10-10T14:30:00Z`, pid 1153247 (the gateway), finished
  20:21:14, `delivery_outcome=delivered`. **This run served the slot.**
- 23:26:49 a fleet orchestrator session working issue 9560 ran
  `hermes cron run 682de9846caa`.
- 23:26:51 `b05bef3697014e45a7ed043d43cd8f00` — `source=direct`,
  `scheduled_instant=NULL`, pid 2894446, finished 23:32:34, delivered.
- 23:38:16 the same session ran `hermes cron run 682de9846caa` again.
- 23:38:17 `1f3973c28f6440a8b5c05f05d2dcac7f` — `source=direct`,
  `scheduled_instant=NULL`, pid 2904546, finished 23:49:07, delivered.

## Cause

Two causes, one in hermes and one in the fleet.

### 1. hermes: the manual-fire path binds no occurrence identity

`claim_job_for_fire` (`cron/jobs.py:2651`) decides whether a fire is manual with

```
manual_fire = force or manual or job.get("manual_run_at") == job.get("next_run_at")
instant = None if manual_fire else scheduled_instant(job.get("next_run_at"))
```

and consults the ledger served-check `completed_occurrence(job, instant)` only
when `instant` is not None. So a manual fire carries **no occurrence identity at
all**. For a recurring job it still advances `next_run_at`, so the slot is
consumed, but nothing records that the slot was served. The docstring records the
deliberate trade-off: a 2026-09-08 incident where a manual run at 19:53 consumed
the next day's 19:00 occurrence.

With no occurrence to compare, `run_one_job` (`cron/scheduler.py:2707` and
`:3135`) creates the execution with `source="direct"` and
`scheduled_instant=None`, which is exactly the signature of the two late runs.

The only guard on a second manual fire is
`_claim_is_live(job.get("fire_claim"), now, claim_ttl_seconds)` with
`FIRE_CLAIM_TTL_SECONDS = 300`, and `mark_job_run` clears the fire claim when the
run finishes. That is a concurrency guard: it stops two fires at the same moment,
not a second fire 11 minutes later. There is no config key and no
`HERMES_CRON_*` environment variable that turns a served-check on for this path —
`cron/`, `tools/`, `hermes_cli/` and `gateway/` were searched, and the live knobs
are `cron.catch_up_missed`, `cron.misfire_grace_minutes`,
`cron.retry_unreachable`, `cron.inflight_max_minutes`, `cron.max_parallel_jobs`,
`cron.require_restart_safe_scope`, `cron.session_db_timeout_seconds` and the
model/provider keys.

The fleet cannot patch this, cannot wrap it, and owns no knob for it. Every
scheduler entry point that the fleet could reasonably reach stamps
`source="builtin"` and an occurrence — the ticker, the gateway misfire backstop,
the dashboard's Run now and `hermes cron tick`. Only `hermes cron run`, which
reaches `run_one_job` through `hermes_cli/cron.py` → `tools/cronjob_tools.py`,
produces the occurrence-free `direct` run.

### 2. the fleet: the hand-off packet told the agent to prove work with a real run

`prompts/orchestrator-handoff.md` set the finish line as "the issue's acceptance
bullets met, each by real run output", and the packet had no rule about
production jobs that deliver to a person. Issue 9560's acceptance ended with
"Done only when a real run proves it, with id/timestamp", so the orchestrator
session read a real run of the evening digest as the required proof and fired the
production job twice. Its own words, from the session log:

- 23:26:49 "Live and verified. Now run the evening digest for real, as the issue
  demands".
- 23:38:16 "Only step 1 changed; no other job field touched. Now a final real run
  on the hardened prompt."

The same evening a second agent family ran the same command against other jobs,
including two temporary copies of the evening digest. Those copies were created
with local delivery, so they reached nobody. The pattern that is safe already
existed; the packet did not say which one to use.

## Detection

Nish's audit comment on issue 9560 (2026-10-11) counted executions `b05bef36` and
`1f3973c2` and found two more step-1 count drifts, which is how the duplicate
runs surfaced. Nothing in the fleet detected them: the audit hermes jobs flag a
run that starts more than 30 minutes after its slot, but a `direct` execution has
`scheduled_instant=NULL`, so lateness is not computable and the row is never
flagged.

## Fix

`prompts/worker.md` and `prompts/orchestrator-handoff.md` now forbid
`hermes cron run` on a job that delivers to a person, and require the proof run
to be a copy created with local delivery. A copy cannot reach the reader, so a
late second fire of it is harmless. Read-only probes stay allowed.

This fixes the fleet's half. It does not fix hermes's half.

## Prevention

Ask hermes for a slot-level served-check on the manual and background fire path:
bind an occurrence identity for a manual fire of a recurring job, or consult
`completed_occurrence` against the job's own last served slot before creating the
execution, so a late re-fire is refused with a reason instead of delivered twice.
The 300 s fire-claim TTL cannot carry this, because it is cleared when the run
finishes.

Open: nothing detects a duplicate delivery. A check that counts deliveries per
slot from the cron ledger would have caught this within minutes.

## Observe to close

Audit of the three digest jobs, read from `~/.hermes/cron/executions.db`, runs per
slot since 2026-10-08. One run and one delivery per slot is the pass condition;
`direct` counts fires with no occurrence identity.

| slot (UTC) | job | runs | delivered | direct |
| --- | --- | --- | --- | --- |
| 2026-10-08T02:30 | digest-morning | 1 | 1 | 0 |
| 2026-10-08T14:30 | digest-evening | 1 | 1 | 0 |
| 2026-10-09T02:30 | digest-morning | 1 | 1 | 0 |
| 2026-10-09T14:30 | digest-evening | 1 | 1 | 0 |
| 2026-10-10T02:30 | digest-morning | 1 | 1 | 0 |
| 2026-10-10T14:30 | digest-evening | 1 | 1 | 0 |
| 2026-10-11T02:30 | digest-morning | 1 | 1 | 0 |

The incident itself sits outside that table because its two runs carry no slot:
`682de9846caa`, `scheduled_instant=NULL`, 2 runs, 2 delivered, 2 direct, both on
2026-10-10 after the 14:30Z slot had been served.

Since `1f3973c28f6440a8b5c05f05d2dcac7f` finished at 23:49:07 on 2026-10-10 there
have been no further executions of any digest job except one: `e078ee1c…`,
`source=builtin`, `scheduled_instant=2026-10-11T02:30:00Z`, 08:00:42 to 08:01:31
on 2026-10-11, delivered. That is the first slot audited after this fix landed,
and it shows one run, one delivery, one claimed execution id.

## How to switch the rule off

Delete the two bullets added to `prompts/worker.md` and
`prompts/orchestrator-handoff.md`. Nothing else in the fleet changes behaviour:
the rule is prose in the two packets, not a gate.
