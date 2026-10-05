# 2026-10-05: agent dispatch and the merge guard down for 2.5 h

Blameless. Times are UTC. Run and PR data come from the GitHub REST API; the
box's `fleet-update` journal was not read for this write-up.

## Impact

From about 08:11 to 10:47Z, `agent-dispatch` ran nothing in Nishfleet/fleet-ops,
Nishfleet/0509 and nish3451/drive. No `agent-ready` issue was dispatched, no red
claim PR was reworked, and no sweep ran.

The merge guard (`hold-risky`) was off for the same window, but only part of
the window could have had it:

- `hold-risky` only existed from 08:37:35, when fleet-ops#9285 merged. A merge
  before that was outside the guard by design, not missed by it.
- 0509's stub only forwarded the PR events `hold-risky` needs from 09:16:27
  (0509#7100). drive's stub never forwarded them (nish3451/drive#624 adds them).
  0509 merges before 09:16 and every drive merge were outside the guard
  whether or not the workflow was enabled.

So the outage removed the guard from two merges only. Both touched risky
paths, by the current `config/risky-paths.json`:

- fleet-ops#9286 at 08:51:36
- 0509#7058 at 09:23:41

Both were merged by nish3451, the configured approver, and not by auto-merge.
Neither head carries a `coordinator-approval` comment or status. No other merge
in the window is attributable to this outage.

## Timeline

- 08:10:10 last drive agent-dispatch run before the gap.
- 08:11:10 fleet-ops#9263 merges (weekly update fixes; it changes only
  `ansible/update.yml` and README). deploy-box starts at 08:11:12.
- 08:11:14 last fleet-ops agent-dispatch run before the gap (run 4286).
- 08:11:38 last 0509 agent-dispatch run before the gap (run 18115).
- 08:37:35 fleet-ops#9285 merges: `hold-risky` exists on main from here.
- 08:51:36 fleet-ops#9286 merges: an approver PR comment counts as approval.
- 09:16:27 0509#7100 merges: the 0509 stub forwards `hold-risky`'s PR events.
- 08:11 to 10:47 no agent-dispatch run in any of the three repos (0 runs in
  each between 08:30 and 10:46).
- 10:47:23 fleet-ops run 4288, `workflow_dispatch` by nish3451: the update's
  resume sweep (`gh workflow run`, as nish). 0509 sweeps at 10:47:26. Events
  flow again from 10:47:46.
- 13:10:47 fleet-ops#9293 opened with the root cause. This is the earliest
  GitHub record of the detection (see Detection).
- 13:39:04 fleet-ops#9293 merges: the update pauses with a variable.
- 13:47:58 fleet-ops#9295 opened: a failed clear pages, plus this write-up.
  It was not merged when this was written; its merge time is on the PR.

## Cause

`ansible/update.yml` paused the fleet with
`gh workflow disable agent-dispatch.yml` in each queue repo. As of 1ca06cc8
(#9263) this is the task "Turn agent-dispatch off where it is on (no new agent
jobs)". It turned the workflow back on only in the `always:` block ("Turn
agent-dispatch back on where this run turned it off"), after the drain (up to
150 min), the prune, apt and every tool update. While a workflow is
disabled, GitHub drops every trigger and queues nothing, so every job in the
file stopped, `hold-risky` included. Pausing the work loop also switched off
the safety check.

The update was not the weekly timer: that fires on Sunday 03:30 IST, and
2026-10-05 was a Monday. The gap opens within seconds of #9263 merging, so
the update was most likely started by hand to try #9263 on the box. This is
inferred and not confirmed. The box's
`journalctl -u fleet-update --since '2026-10-05 08:00'` would show the start
time and how it was started. The 2 h 36 min length is what this playbook
takes: drain, prune, `apt dist-upgrade`, tool updates, then the resume.

## Detection

A coordinator worker saw the gap in agent-dispatch run times. No alert fired:
the unit was still running, and nothing watches for a dispatch workflow that is
disabled or quiet. The exact moment is not recorded on GitHub: no issue or
comment in the three repos between 08:11 and 13:10 mentions it. The earliest
record is fleet-ops#9293, opened at 13:10:47 with the root cause. Detection
was therefore no later than 13:10, about 2 h 24 min after dispatch had already
resumed on its own.

## Fix

- fleet-ops#9285 and #9286 (merged during the window) added `hold-risky` and
  comment approval. The outage then showed that a guard in the dispatch workflow
  stops whenever that workflow is turned off.
- fleet-ops#9293: the update pauses with the repo variable
  `FLEET_DISPATCH_PAUSED` instead of disabling the workflow. Only jobs that start
  workers skip; `hold-risky` and `close-claim` keep running. A root-owned marker
  (`/var/lib/fleet-ops/dispatch-paused-by-update`) lets the next run clear a pause
  left by a killed run. ci.yml fails if a guard job ever reads the flag.

## Prevention

- fleet-ops#9295: a failed clear in the update's `always:` block is read back.
  A repo still paused fails the unit, which pages, and the report and failure
  message name it as "DISPATCH STILL PAUSED". It used to be ignored until the
  next Sunday. The ci.yml check now checks each named pause task's place and
  content, including that the marker is written as root with mode 0600.
- nish3451/drive#624: the drive stub forwards `hold-risky`'s PR events, which
  it never did.
- Open: nothing alerts when a queue repo has no agent-dispatch run for longer
  than its sweep interval. A dead-man check on that would have caught this in
  about an hour, instead of after the fact.
