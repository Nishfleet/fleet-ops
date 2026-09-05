fix(canary): announce a green live detection on every exporter tick (fleet-ops#3060)

## What the escalation was

CanaryEffectivenessLow fired at 0.0 on three organs and
CanarySilentTooLong at 8 since 2026-09-02T20:45Z: the effectiveness
exporter emitted caught=0 (and, after the pre-observe fix, missed=0)
while nothing on the live box could prove the classify path worked. A
canary that emits no signal is indistinguishable from a working one —
review/detection coverage was unproven.

## Diagnosis (verified live, 2026-09-05)

1. The three real incidents in the 30d window (0509#1132 08-26,
   0509#1411 08-28, fleet-ops#1466 08-28) all predate each organ's first
   observed event in the durable store (~08-29). Per the
   pre-observe rule (fleet-ops#2757, #3175) a canary cannot miss a
   regression it was not yet watching, so they are honestly
   unclassified: caught=0 and missed=0 with ratio=0.0. Attribution
   only resumes with the next post-observe bug/regression issue.
2. The 30d window outlived the ~7d retention of Prometheus and
   journald, so older incidents would have been silently re-ignored
   every tick — closed by the durable event store (fleet-ops#3052).
3. The classify path could silently break while no drill ran anywhere
   (the 2026-09-02 class pinned caught=0 for 19h) — closed by the
   hermetic injected-fault drill in every live tick (fleet-ops#3055,
   #3415).
4. Remaining gap, fixed here: a PASSING drill was journal-invisible.
   The exporter only printed DRILL RED on failure; a green detection
   existed solely as a gauge. That is still "no signal" for anyone
   reading the journal, and it is the same silent-even-while-healthy
   failure class.

## The fix

run_live_drill now prints DRILL GREEN with the self-test summary on
every passing tick, so each exporter run's stderr proves the injected
fault was caught end to end (caught=1, ratio=1.0). The regression test
locks the announcement: a future change that silences the green
detection fails CI.

mechanism: regression test + live-tick drill already ship the
FleetCanaryEffectivenessDrillStale guard (fleet-ops#3055); this PR makes
the guard's green firing journal-visible and locks it with a test
assertion so silent-green cannot hide again.

## Verification

Live tick in its production environment (same store,
`/var/lib/prometheus/node-exporter/fleet-canary-effectiveness.prom`,
same command shape as the systemd drop-in ExecStart):

```
$ /usr/bin/python3 ./lib/canary-effectiveness.py
canary-effectiveness: DRILL GREEN: SELF-TEST OK: injected fault detected (caught=1, ratio=1.0)
canary-effectiveness: wrote /var/lib/prometheus/node-exporter/fleet-canary-effectiveness.prom (4 organs, 905 events, 3 incidents)
```

Exported drill gauges after that tick (fleet.jsonl store 905 events;
heartbeat fresh):

```
fleet_canary_effectiveness_drill_last_green_seconds 1788567244
fleet_canary_effectiveness_drill_ok 1
fleet_canary_effectiveness_last_run_seconds 1788567244
```

Live alertmanager (2026-09-05T00:15Z): no Canary* alert active —
CanaryEffectivenessLow / CanarySilentTooLong / DrillStale all clear
(7 unrelated alerts active; pre-existing, filed separately if they
belong to this repo).

Repo tests:
- `bash tests/canary-effectiveness.test.sh` — PASS (failing-repro
  check: the new DRILL GREEN assertion fails against the pre-change
  code, which printed nothing on stderr for a passing drill)
- `bash tests/ci-standards-audit.test.sh` — PASS (hosts the canary
  effectiveness suite + 21 sibling suites)
- `python3 -m py_compile lib/canary-effectiveness.py` — PASS
- `bash -n tests/canary-effectiveness.test.sh` — PASS
- `shellcheck tests/canary-effectiveness.test.sh` — PASS
- sgscan — no new security findings
- crgate — SKIP: CodeRabbit CLI not signed in on this host

Closes #3060