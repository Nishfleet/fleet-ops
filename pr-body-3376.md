## What

Close #3376 (`FleetEscalationStorm` firing 20h at 964 escalations). The storm
has two sources: the `fleet_escalations_24h` metric was counting
writer-refused `unit-escalation@` starts (`pi-issue@*`, `alert-repair-*`), and
a firing 24h rolling count cannot be repaired by a worker so the alert-repair
plane was laddering into a `terminal=escalated` chain.

This PR adds the missing canary `SKIP_FIRING` guard and a regression test. The
exporter fix (`fleet-ops#3180`, #3579) and the dispatcher skip (`fleet-ops#3180`,
#3469) are already on main.

## Root cause (verified live)

`fleet_escalations_24h` reads `journalctl --user -u unit-escalation@*` and
counts `Starting unit-escalation@<unit>.service` lines. The exclusion list in
`libexec/fleet-metrics-export.py` had drifted from `bin/unit-escalation-write`'s
first refuse case, so it counted:

- `pi-issue@*` starts from no-seat crash loops. These workers have their own
  `OnFailure=pi-issue-failed@%i` reaper and re-dispatch lane; the writer refuses
  them (`fleet-ops#2133/#2475`). A live 24h sample had 1348 total
  `unit-escalation@` starts, 1158 of them `pi-issue@*`.
- `alert-repair-*` recovery units, which escaped the older `*-repair@*` glob
  (`fleet-ops#3349`).

The `FleetEscalationStorm` rule (`sum(fleet_escalations_24h) > 300`) tripped on
this overcount. Because the metric is a 24h rolling window, a repair worker
cannot clear it; the 6h Alertmanager repeat instead kept re-summoning workers,
which stalled at hop=verify and escalated to the senior conference.

## Fix (this PR)

- `bin/fleet-completion-canary.py`: add `FleetEscalationStorm` to `SKIP_FIRING`
  so the canary does not ladder a firing-without-dispatch chain to
  `STOP-REASON`.
- `tests/alert-repair-fleet-escalation-storm-skip.test.sh`: offline regression
  test proving `FleetEscalationStorm` is in both `libexec/alert-repair-dispatch`
  `SKIP_SET` and `bin/fleet-completion-canary.py` `SKIP_FIRING`, and that
  neither dispatch nor canary ladders.
- `tests/ci-standards-audit.test.sh`: host the new test in P14.

The dispatcher already skips `FleetEscalationStorm` after #3469; the canary
skip is the missing complement.

## Verification

Live Prometheus query at claim time:

```
$ curl -s 'http://localhost:9090/api/v1/query?query=sum(fleet_escalations_24h)'
{ "status": "success", ... "value": [ ..., "82" ] }

$ curl -s 'http://localhost:9090/api/v1/query?query=topk(1,fleet_escalations_24h)%20and%20on()%20(sum(fleet_escalations_24h)%20%3E%20300)'
{ "status": "success", "data": { "resultType": "vector", "result": [] } }
```

- Total `fleet_escalations_24h` is 82, below the 300 threshold.
- The exact `FleetEscalationStorm` PromQL expression returns an empty vector.
- `FleetEscalationStorm` is absent from `ALERTS`.
- No open `FleetEscalationStorm` chain in
  `/home/nish/workspaces/agent-state/fleet-completion-canary/open`.

```
$ bash tests/alert-repair-fleet-escalation-storm-skip.test.sh
OK: fleet-ops#3376 FleetEscalationStorm skip-list lock passes

$ bash tests/fleet-metrics-export.test.sh
OK: fleet-ops#3180: fleet_escalations_24h exclusions locked to unit-escalation-write refuse list

$ bash tests/fleet-rules-escalation-storm.test.sh
OK: promtool: dominant-producer naming + total-gate semantics

$ python3 -m py_compile libexec/alert-repair-dispatch bin/fleet-completion-canary.py
# exit 0
```

run-proof: live PromQL `sum(fleet_escalations_24h)=82` and the
`topk(1, ...) and on() (sum(...) > 300)` rule both return clean; targeted
`tests/alert-repair-fleet-escalation-storm-skip.test.sh`,
`tests/fleet-metrics-export.test.sh`, and `tests/fleet-rules-escalation-storm.test.sh`
pass.

## Mechanical-fix

Class: "a 24h rolling count gauge (`fleet_escalations_24h`) trips
`FleetEscalationStorm` because it momentarily counts refused
`unit-escalation@` starts; a repair worker cannot clear it, so the
alert-repair/canary plane laddered into an unrepairable
`STOP-REASON`/escalation."

Mechanisms that now guard this:

1. `libexec/fleet-metrics-export.py` resynced its exclusion set with
   `bin/unit-escalation-write`'s refuse list (`#3579`).
2. `libexec/alert-repair-dispatch` skips `FleetEscalationStorm` so the 6h
   Alertmanager repeat cannot spawn a repair worker (`#3469`).
3. `bin/fleet-completion-canary.py` now skips it in `SKIP_FIRING` so the
   canary cannot ladder a firing-without-dispatch chain (this PR).

mechanism-impossible: raising the threshold or hand-clearing the alert. The
threshold is correct for genuine flap; the source was the metric, and a manual
clear would just refire.

## What this PR ships

Code: `bin/fleet-completion-canary.py`,
`tests/alert-repair-fleet-escalation-storm-skip.test.sh`,
`tests/ci-standards-audit.test.sh`.

Paper: `verification-3376.md` and `pr-body-3376.md`.

Closes #3376
