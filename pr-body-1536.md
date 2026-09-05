## What and why

ResilienceDrillAbsent went pending critical 2026-08-28T06:06Z and the drill's
metric never showed in Prometheus for the first two days of the incident run.

Root cause: `bin/fleet-resilience-drill`'s default prom path was
`$AGENT_STATE/fleet-resilience-drill/resilience-drill.prom` — a directory
node-exporter does NOT scan (it scans `/var/lib/prometheus/node-exporter/`).
Every systemd-timer run wrote there, so the drill PASSED daily while its
metric stayed invisible to Prometheus (`absent()` fired). The only samples
Prometheus ever saw were from ad-hoc runs that happened to export with the
env override, and the metric froze for a full day (Aug 29 00:25Z run) until a
manual run refreshed it. The systemd env line was restored in #2130, which is
why the alert is now clear — but the underlying trap (default export path
unscraped) remained: any run without the env override (manual, or a future
unit rewrite that drops the env line — the exact #1484-class rewrite that
started this) silently goes dark again.

Fix: the script's DEFAULT prom path is now the node-exporter textfile
directory that Prometheus scrapes. The env override stays for tests/scratch.
A run with no environment — however it is invoked — now lands where the
alert can see it.

## Mechanism (failure-fix, fleet-ops#366)

- Script default moved to the scraped path, so a drill run can never export
  to an unscraped file again (no env required).
- `tests/fleet-resilience-drill.test.sh` pins the default to the
  node-exporter textfile dir (regression lock), and exports
  `FLEET_RES_DRILL_PROM_FILE` to scratch so tests never write the live
  scraped file. The drill test runs in CI via escalation-coverage-canary.

## Verification

Repo test suite (drill): `bash tests/fleet-resilience-drill.test.sh` —
33/33 OK including the new default-path assertion and the full eleven-plane
green/red matrix.

Live drill via the real systemd unit:

```
$ systemctl --user start fleet-resilience-drill.service
Aug 30 07:11:26 netcup-rs2000 bash[2308904]: [2026-08-30T01:41:26Z] OK: fleet-ops#455+#1463 eleven-plane drill pass
Aug 30 07:11:26 netcup-rs2000 systemd[1038]: Finished fleet-resilience-drill.service - ... (Result=success)
```

New default proven WITHOUT the env override (the worktree script, no
FLEET_RES_DRILL_PROM_FILE):

```
$ env -u FLEET_RES_DRILL_PROM_FILE ./bin/fleet-resilience-drill
OK: fleet-ops#455+#1463 eleven-plane drill pass
$ grep '^fleet_resilience_drill_last_green_seconds ' /var/lib/prometheus/node-exporter/fleet-resilience-drill.prom
fleet_resilience_drill_last_green_seconds 1788054100
$ curl 'localhost:9090/api/v1/query?query=fleet_resilience_drill_last_green_seconds'
1788054100  (2026-08-30 01:41:40Z — scraped, fresh)
```

Alert cleared, re-checked after the runs:

```
ResilienceDrillAbsent: state=inactive, health=ok, alerts=0
(time() - fleet_resilience_drill_last_green_seconds) > 93600  -> [] (no alerting vector)
absent(fleet_resilience_drill_last_green_seconds)             -> []
fleet_resilience_drill_last_green_seconds == 0                -> []
```

run-proof: service run `systemctl --user start fleet-resilience-drill.service` -> journal
`[2026-08-30T01:41:26Z] OK: ... eleven-plane drill pass` + `Result=success`; prometheus
query returned fresh `1788054100`; `ResilienceDrillAbsent` inactive with 0 alerts.

Closes #1536