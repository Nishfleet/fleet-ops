## Summary

`fleet-seat-recovery.path` watches the seats/ **directory** with `PathChanged`, so every seat-health ledger write (~every 1.3s, ~2500/h measured live) spawned a `fleet-seat-recovery.service` activation — the top `unit-churn` line (2419-2536 starts/h) while the box idled at `sy=16%`.

The issue's named mechanism — `TriggerLimitIntervalSec=30s` + `TriggerLimitBurst=1` in `[Path]` — is **unusable on systemd 255**: when a path unit's trigger limit is hit the unit is placed into `trigger-limit-hit` failure and *stops watching until restarted*. That is the #617 watcher-dead wedge, not a debounce. Proven live on this box: second write inside the window → `Result=trigger-limit-hit`, `ActiveState=failed`, `Triggering OnFailure=` fired.

So this implements the issue's *semantics* ("a burst of seat writes coalesces into ONE service run per ~30s window") with a mechanism that actually coalesces:

- `systemd/fleet-seat-recovery.service`: `ExecStartPost=/bin/sleep 25` — the bin runs immediately on the triggering write, then the unit lingers in `start-post` for 25s; `PathChanged` events inside the window enqueue start jobs that **merge into the in-flight job** instead of spawning new activations. Ceiling ~144 starts/h (<200 acceptance). A mid-hold transition is caught by the next activation ~25s + one ledger-write interval later (the bin re-reads the whole ledger each run) — inside the issue's 30s recovery bound. do#2 holds: the path unit stays, recovery stays event-driven, the NO-USABLE-SEAT→usable fire is not debounced (the bin's own 120s cooldown still gates the intake side-effect).
- Same file: the StartLimit accommodations are **removed, not raised** (`StartLimitIntervalSec=0` from #617, `1h/2000` from #622) — the hold makes the stock 5-per-10s structurally unreachable. If the hold regresses, the default limit wedges the unit loud through OnFailure instead of storming silently — the intended tripwire.
- `systemd/fleet-seat-recovery.path`: comment-only — locks out the `TriggerLimit*` wedge trap with the live proof, so the next worker doesn't "fix" it into a dead watcher.
- do#3 — `bin/fleet-resilience-drill` gains plane 12 `seat_recovery_coalesce`: installs the shipped units name-swapped to the escalation-excluded `resilience-drill-stub-` prefix, storms a **scratch** trigger (never the seat ledger), asserts `activations << writes` and `.path` stays `active/success`. The throwaway drill units now fire only under `fleet-resilience-drill.timer` (daily) — they no longer exist during repo test runs at all. The live-drill phase is deleted from `tests/fleet-seat-recovery-units.test.sh`; that file is read-only now.
- Regression locks updated: `fleet-seat-recovery-units.test.sh` asserts the hold, asserts **no** `TriggerLimit*` in `[Path]`, asserts **no** `StartLimit*` accommodation; `escalation-units-shape.test.sh` 7b updated to the same model. The #884 p14 SKIP-block anchors are preserved verbatim.

## Relationship notes

- PR #5095 (`fix/auditor-seat-recovery-start-limit`, open for #622/#5024) deletes the burst pair but leaves the storm unthrottled at ~2500/h — it does not meet this issue's <200/h bar. This PR supersedes it on the mechanism point while landing the same pair-deletion.
- Live drop-in `~/.config/systemd/user/fleet-seat-recovery.service.d/20-no-start-limit.conf` (senior-auditor bridge, `StartLimitIntervalSec=0`) is now redundant-but-harmless; its own comment says remove once the durable deletion propagates. Follow-up filed for the post-deploy sweep.

net-positive-because: the fix is +99 lines of unit comments/test locks and +105 for the drill plane vs −147 removed (live-drill phase + StartLimit accommodation); the mechanism itself is 1 added directive (`ExecStartPost=/bin/sleep 25`) and 3 deleted directives.

Verification:

```
$ systemd-analyze verify --man=no systemd/fleet-seat-recovery.{service,path}   # rc=0

# TriggerLimit wedge trap, proven live (throwaway path unit, systemd 255):
#   2 touches in ~1s -> Result=trigger-limit-hit, ActiveState=failed,
#   "Trigger limit hit, refusing further activation", OnFailure fired.

# Activation-hold coalescing, proven live (ExecStartPost=/bin/sleep probe):
#   20 trigger writes over ~10s -> 2 service starts; .path ActiveState=active,
#   Result=success.

# Drill plane exercised live (extracted function, real user systemd):
#   seat_recovery_coalesce pass: 16 trigger writes -> 3 activations at 3s
#   drill-scale hold; resilience-drill-stub-seat-recovery.path active/success.
#   Escalation carve-out held: "unit-escalation-write: skipping excluded unit
#   'resilience-drill-stub-seat-recovery.service'" — no STOP-REASON written.

$ bash tests/fleet-seat-recovery.test.sh        # ALL OK (units + comeback + probe + bin)
$ bash tests/fleet-resilience-drill.test.sh     # ALL OK (12-plane green run, roster locked)
$ bash tests/escalation-units-shape.test.sh     # ALL PHASES PASSED
$ bash tests/p14-unstubbed-unit-verify.test.sh  # ALL OK (#884 SKIP lock holds)
$ bash tests/fleet-heartbeat-failed-units-recover.test.sh  # all phases passed
$ bash tests/manifest-shape.test.sh             # OK
$ bash tests/fleet-organ-heartbeat.test.sh      # ALL PHASES PASSED
$ bash tests/install-prometheus-rules-reload.test.sh       # OK
$ bin/fleet-organ-heartbeat-check verify        # all 27 organs have absent() rules
```

run-proof: tests/fleet-seat-recovery.test.sh + tests/fleet-resilience-drill.test.sh + live seat_recovery_coalesce plane run (16 writes -> 3 activations) on netcup-rs2000 2026-09-11
organ-heartbeat: bin/fleet-resilience-drill is a registered organ; its absent() rule `ResilienceDrillAbsent` in config/fleet_rules.yml is kept (and updated to twelve planes)
reviewer-round: skipped — fleet-ops PRs are exempt from the product-repo reviewer round
loose-ends: live bridge drop-in `fleet-seat-recovery.service.d/20-no-start-limit.conf` becomes redundant after deploy (removal is live-state sweep, tracked in follow-up issue)

Closes #5106
