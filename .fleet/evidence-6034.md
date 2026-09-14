# Evidence — fleet-ops#6034: journal root cause (phase 1)

Source: nish user-journal on netcup-rs2000, Sep 12 2026, window 08:00–21:00,
units `pi-intake-repair@0509.service` + `pi-intake-repair@fleet-ops.service`,
filtered to the load-bearing line set
(`Starting|Finished pi-intake-repair|PACKET-VERDICT|timed out|Failed with result|start-limit-hit|SPAWN_BLOCKED|Failed to start`).
bash PIDs map to lanes via per-unit `_SYSTEMD_USER_UNIT=` queries
(0509: 636556, 3999642, 71446, 1710752; fleet-ops: 555912, 4003978, 148587, 1711200).
Live unit in this worktree carries exactly `StartLimitIntervalSec=21600` (l.3),
`StartLimitBurst=2` (l.4), `TimeoutStartSec=1800` (l.15); the spawn-guard rule
`home_wide_filesystem_sweep` lives at `template/extensions/spawn-guard-core.ts:102`
(repo-owned, fleet-ops#4896).

## Morning run — both lanes finished inside the 1800s cap

```
Sep 12 08:25:17 netcup-rs2000 systemd[1160281]: Starting pi-intake-repair@fleet-ops.service - Pi fleet intake repair agent for Nishfleet/fleet-ops...
Sep 12 08:54:30 netcup-rs2000 systemd[1160281]: Finished pi-intake-repair@fleet-ops.service - Pi fleet intake repair agent for Nishfleet/fleet-ops.
Sep 12 08:54:30 netcup-rs2000 bash[555912]: PACKET-VERDICT tools=10 class=worked
```

fleet-ops: 08:25:17 → 08:54:30 = 29m13s wall, tools=10, class=worked — the longest
observed successful run, still ~47s *inside* the 1800s cap.

Delta (plan quoted one morning run; journal shows two — additive, strengthens the
verdict): 0509 also ran 08:30:05 → 08:54:49 (24m44s), `PACKET-VERDICT tools=11
class=worked` at 08:54:49 — also inside the cap.

## Evening pair + SPAWN_BLOCKED (same second, both lanes)

```
Sep 12 18:52:55 netcup-rs2000 systemd[1160281]: Starting pi-intake-repair@0509.service - Pi fleet intake repair agent for Nishfleet/0509...
Sep 12 18:53:20 netcup-rs2000 systemd[1160281]: Starting pi-intake-repair@fleet-ops.service - Pi fleet intake repair agent for Nishfleet/fleet-ops...
Sep 12 18:54:17 netcup-rs2000 bash[3999642]: SPAWN_BLOCKED reason=home_wide_filesystem_sweep
Sep 12 18:54:17 netcup-rs2000 bash[4003978]: SPAWN_BLOCKED reason=home_wide_filesystem_sweep
Sep 12 19:10:57 netcup-rs2000 bash[3999642]: PACKET-VERDICT tools=43 class=worked
```

Both lanes hit the repo-owned home-wide-sweep guard in the same second (0509 at
1m22s into its run, fleet-ops at 57s). The guard costs time, it does not wedge a
run: the evening 0509 lane worked straight through it and finished one
second after its verdict (Finished 19:10:58 = 18m03s wall, inside the cap) — the
SPAWN_BLOCKED lines are not the failure. (Journal prints only `reason=`; the
"blocks the agent's own ~-rooted find/rg" reading is from the guard's rule id at
spawn-guard-core.ts:102, not a journal line.)

## 19:23:20 — same-second triple: verdict, kill, and failure recorded together

```
Sep 12 19:23:20 netcup-rs2000 systemd[1160281]: pi-intake-repair@fleet-ops.service: start operation timed out. Terminating.
Sep 12 19:23:20 netcup-rs2000 bash[4003978]: PACKET-VERDICT tools=53 class=worked
Sep 12 19:23:20 netcup-rs2000 systemd[1160281]: pi-intake-repair@fleet-ops.service: Main process exited, code=killed, status=15/TERM
Sep 12 19:23:20 netcup-rs2000 systemd[1160281]: pi-intake-repair@fleet-ops.service: Failed with result 'timeout'.
Sep 12 19:23:20 netcup-rs2000 systemd[1160281]: Failed to start pi-intake-repair@fleet-ops.service - Pi fleet intake repair agent for Nishfleet/fleet-ops.
Sep 12 19:23:20 netcup-rs2000 bash[147002]: unit-escalation-write: wrote STOP-REASON for pi-intake-repair@fleet-ops.service (result=timeout oom=no)
```

18:53:20 → 19:23:20 is exactly 1800s — the run died at the wall, mid-flight.
The packet-verdict pi extension prints its verdict during the SIGTERM unwind, so
"PACKET-VERDICT tools=53 class=worked" sits in the same second as `status=15/TERM`
and `Failed with result 'timeout'`: benign but misleading — the session never
finished (no `Finished …` line exists for that run; the verdict was the dying
pipe's last breath, not a completed run). The escalation machinery recorded
STOP-REASON result=timeout and fired OnFailure.

The latch then bites (consequence, not cause): with two permitted starts already
inside the 6h window (fleet-ops 18:53:20 + 19:23:30; 0509 18:52:55 +
19:20:28), `StartLimitBurst=2` denied every further start:

```
Sep 12 20:00:12 netcup-rs2000 systemd[1160281]: pi-intake-repair@0509.service: Failed with result 'start-limit-hit'.
```

fleet-ops tripped at 20:01:19; the ~61s retrigger cadence then kept both lanes
wedged — 11 refusals on 0509 (20:00:12→20:09:22) and 9 on fleet-ops
(20:01:19→20:09:28), one 30s double-fire at 20:03:46 — each refusal also
re-tripping OnFailure=unit-escalation (later trips suppressed by the recurrence
gate, `suppress_n=3`).

## Post-reset counter-evidence — both lanes finished inside the cap

```
Sep 12 20:10:23 netcup-rs2000 systemd[1160281]: Starting pi-intake-repair@0509.service - Pi fleet intake repair agent for Nishfleet/0509...
Sep 12 20:10:29 netcup-rs2000 systemd[1160281]: Starting pi-intake-repair@fleet-ops.service - Pi fleet intake repair agent for Nishfleet/fleet-ops...
Sep 12 20:28:45 netcup-rs2000 systemd[1160281]: Finished pi-intake-repair@fleet-ops.service - Pi fleet intake repair agent for Nishfleet/fleet-ops.
Sep 12 20:28:45 netcup-rs2000 bash[1711200]: PACKET-VERDICT tools=40 class=worked
Sep 12 20:30:46 netcup-rs2000 systemd[1160281]: Finished pi-intake-repair@0509.service - Pi fleet intake repair agent for Nishfleet/0509.
Sep 12 20:30:46 netcup-rs2000 bash[1710752]: PACKET-VERDICT tools=43 class=worked
```

After the latch cleared, both lanes ran again and finished inside the cap.

Delta (corrected pairing): the plan's "18m22s/20m17s" cross-pairs start/finish
across units; same-unit walls are **18m16s** (fleet-ops 20:10:29→20:28:45,
tools=40) and **20m23s** (0509 20:10:23→20:30:46, tools=43). The tools=40/43
attribution and the 20:28:45/20:30:46 finish order match the plan exactly.

Delta (reset attribution): the plan says "manual reset+start"; the journal shows
the 20:10:23/29 starts landing exactly on the 61s retrigger beats (20:09:22+61s,
20:09:28+61s), and the reset action itself leaves no line in the user journal
(reset-failed is silent). A rate-limit clear demonstrably happened (a bare 6h
sliding window would still deny — 0509's 18:52:55 counted start stays in-window
until ~00:53), so: reset + next-cadence start, not provably a human-timed start.

Delta (omitted, additive): the plan's evening bullet skips two more finished
runs — 0509 19:20:28→19:38:41 (18m13s, `tools=59 class=worked`) and the fleet-ops
same-lane retry 19:23:30→19:45:13 (21m43s, `tools=72 class=worked`) — the retry
did *more* work (72 tools) than the killed attempt (53) and still finished.

## verdict

**The runs are slow-working, not stuck.** Tools kept accumulating in every
attempt; five of the window's seven full runs finished healthy inside the cap
(24m44s, 29m13s morning; 18m03s evening; 18m13s, 18m16s, 20m23s, 21m43s post-
reset/retry); the only casualty was the 18:53:20 fleet-ops run, killed at exactly
1800s while it had just logged 53 tools' worth of healthy work — and the
SPAWN_BLOCKED guard hit that both lanes absorbed (fleet-ops#4896,
spawn-guard-core.ts:102, over a ~282 GB home that makes home-rooted sweeps
genuinely expensive) did not stop the 0509 lane from finishing. 2700s is the
right lever because it gives ~1.5× headroom over the longest observed successful
wall (29m13s ≈ 1753s) while leaving the `StartLimitIntervalSec=21600` /
`StartLimitBurst=2` latch untouched — the latch's own journal behavior (first
timeout → escalation STOP-REASON → burst tripped → ~61s refusal loop → both
lanes wedged for ~10 minutes) confirms fleet-ops#5036's warning that raising the
burst would just re-wedge differently. The same-second verdict/TERM line means
the wrapper's verdict is unwound, never delivered: a killed run courts
mis-reading as "worked" — the phase-3 elapsed/budget stamp on PACKET-VERDICT
removes exactly that ambiguity. In one sentence for the PR body: the journal
shows healthy mid-flight runs being killed by the 1800s wall and then StartLimit−
latched (with every ~61s re-trip firing unit-escalation), so the single fix is
`TimeoutStartSec=1800 → 2700` with StartLimit* untouched.
