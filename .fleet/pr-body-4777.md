## What

Add a test-pollution guard to the deadman so a phantom `test-unit` / `dispatch=x` series cannot fire `DetachedJobDied` forever.

A phantom `fleet_detached_job_died{unit="test-unit",dispatch="x",...} 1` series was live in the production node-exporter textfile for ~8h (starts_at 1788940504), firing the critical `DetachedJobDied` alert continuously and polluting every repair-dispatch packet. The deadman wrote any series to the textfile regardless of dispatch shape, and a series is only cleared by a success verdict for the same unit or a manual `--clear` — so a phantom unit name fires forever.

## Fix

- **Guard the DEATH write path** (`_textfile_set` want=1) in `bin/pi-detached-deadman`: refuse to write a `fleet_detached_job_died` series when `PI_DEADMAN_DISPATCH` is set but is not UUID-shaped (placeholder like `x`, `test`, or a bare unit name). A real pi-systemd-run dispatch is always a UUID (`uuidgen` / `/proc/sys/kernel/random/uuid`). Log a stderr line naming the rejected dispatch so a misconfigured caller is visible in the journal.
- **`--clear` and success-clear paths unaffected**: they only ever remove series (dispatch="" / want=0), never create one.
- **Regression test** in `tests/pi-detached-deadman.test.sh`: a non-UUID dispatch (`x`, unit `u-testpollution`) writes no died series and logs the rejection; the existing death-path cases now use real UUID dispatches and still write.

## Verification

```
$ bash tests/pi-detached-deadman.test.sh
OK: not armed (no dispatch id) is a no-op
OK: clean stop without deliverable: died series + STOP-REASON writer called
OK: non-clean failure: died series only, OnFailure rail owns STOP-REASON
OK: success with deliverable: stale series for THAT unit cleared, others kept
OK: exit 0 without deliverable == death (the exact #4266 gap)
OK: non-UUID dispatch (x) writes no died series and logs the rejection (fleet-ops#4777)
OK: success-clear path unaffected by the dispatch-shape guard
OK: --clear removes exactly the named unit's series (empty dispatch)
OK: dry-run prints verdict, writes nothing
OK: 10 write/clear cycles leave one HELP/TYPE pair (no header accumulation)
OK: textfile is written 0644 so node_exporter can read it
OK: promtool parses the repeatedly-written textfile
OK: CLI --help with inherited PI_DEADMAN_* is not a death (fleet-ops#4675)
OK: bare CLI call with SERVICE_RESULT unset is not a death (fleet-ops#4675)
PASS: pi-detached-deadman verdict matrix (12 cases)
```

```
$ bash tests/pi-systemd-run.test.sh   # hosts the deadman test (ci.yml line 89)
PASS: pi-detached-deadman verdict matrix (12 cases)
```

```
$ sgscan
Scanning changes since origin/HEAD (a0297473)…
No new security findings.
```

```
$ bin/fleet-organ-heartbeat-check
OK: all 27 registered organs have an absent() heartbeat rule
```

## run-proof

- `tests/pi-detached-deadman.test.sh` — 12 cases PASS (hosted by `tests/pi-systemd-run.test.sh`, ci.yml line 89)
- `tests/pi-systemd-run.test.sh` — PASS (hosts the deadman test)
- `sgscan` — no new security findings
- `bin/fleet-organ-heartbeat-check` — all 27 organs have an absent() heartbeat rule
- `bin/fleet-no-agent-names-check --commit-range origin/main..HEAD` — OK, no agent attribution

## Phantom clear

The live phantom `test-unit` series was already removed from the production textfile (no `unit="test-unit"` series present). Termination condition met:

```
$ grep -q 'unit="test-unit"' /var/lib/prometheus/node-exporter/fleet-detached.prom && echo PRESENT || echo CLEAN
CLEAN
```

## mechanism

The dispatch-shape guard + regression test is the prevention mechanism. The one-time clear alone is not the fix.

net-positive-because: the +45 lines are the prevention mechanism the issue mandates — a 13-line guard in the death write path plus a regression test that proves a non-UUID dispatch writes no died series. Without it, a future test or manual run that forgets PI_DEADMAN_TEXTFILE re-pollutes the production alert and fires DetachedJobDied for hours again. The guard is the durable fix; the one-time clear is not.

## Test plan

- `bash tests/pi-detached-deadman.test.sh` — the new case (non-UUID dispatch writes no died series) must pass
- `bash tests/pi-systemd-run.test.sh` — hosting test must pass
- `! grep -q 'unit="test-unit"' /var/lib/prometheus/node-exporter/fleet-detached.prom` — phantom gone

## Rollback

Revert the dispatch-shape guard in `bin/pi-detached-deadman` and remove the new test case; the one-time `--clear test-unit` is forward-only (removes a phantom series, no real state lost).

Closes #4777
