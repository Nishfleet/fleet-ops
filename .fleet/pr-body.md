fix(detached-deadman): every detached job gets a dead-man, OnFailure escalation, deliverable check, and a stop audit trail (fleet-ops#4266)

## Summary

Detached fleet work launched with raw `systemd-run` could be stopped at exit 0
with zero output and nothing fired — a stop counts as success, there was no
dead-man on the deliverable, and user-manager stop jobs do not log the
requester. This makes a lot of work die unnoticed.

This PR makes `pi-systemd-run` the only way to launch detached work and wires
the missing rails inside existing organs (no new organ):

1. **pi-systemd-run is the only launcher** (`bin/pi-systemd-run`): adds by
   default `--property=OnFailure=unit-escalation@%n.service`, a healthchecks.io
   dead-man (ping `/start` at launch, `/<uuid>` on success from ExecStopPost
   salvage, `/fail` on non-zero), `--deadline` (grace = RuntimeMaxSec), and a
   `--deliverable PATH` flag. ExecStopPost salvage (`bin/pi-detached-deadman`)
   marks the run FAILED (STOP-REASON + `/fail` ping) when the unit ends without
   that file — **a stop is then a failure, not a success**.
2. **Audit trail** (`config/audit/rules.d/30-fleet-unit-stop.rules` +
   `bin/fleet-who-stopped`): an auditd rule (off-the-shelf distro package) on
   execve of `systemctl`/`kill` with args `stop|kill|reset-failed` for uid 1000,
   so "who stopped it" is always answerable from `ausearch`. No hand-written
   watcher.
3. **Prometheus / alert path**: healthchecks failures already flow via the
   #4146 replacement (hc + `absent()` rules); the dead-man `/fail` ping feeds
   the same path. The escalation canary's new block 14 surfaces raw
   `systemd-run` transients without OnFailure as a VIOLATION naming the unit.
4. **Lint** (`bin/fleet-escalation-canary` block 14): checks that no user unit
   was created by raw `systemd-run` in the last 24h without OnFailure
   (`systemctl show -p OnFailure` over transient units + the auditd execve
   trail). A false-clean guard (`auditctl -l`) makes an empty `ausearch` result
   PENDING (loud, not fail) when the `fleet-unit-run` rule is not loaded yet.
5. **Standing text** (`prompts/worker.md`): detached work = `pi-systemd-run`
   with `--deadline` and `--deliverable`; raw `systemd-run`/`nohup` are
   forbidden. (Out-of-repo standing text — the hourly judge packet
   `agent-state/fleet-landing-watch/fable-check.md` and the vault
   `global-standing-rules.md` — is a separate cross-project edit, filed as
   follow-up.)

`bin/fleet-who-stopped` is the ausearch helper that names the stopper from the
audit trail. `bin/pi-detached-deadman` is the ExecStopPost salvage that turns
"exit 0 without deliverable" into a FAILURE with a STOP-REASON + `/fail` ping,
and clears the stale dead-man series on a real success.

Mechanical-fix (fleet-ops#366): the new canary block 14 + the
`pi-detached-deadman` verdict matrix test are the detector/test that prevent
this bug class from recurring; `fleet-who-stopped` is the observe-to-close
helper.

## Closes

Closes Nishfleet/fleet-ops#4266

## Verification

```
$ bash tests/pi-detached-deadman.test.sh
OK: exit 0 without deliverable == death (the exact #4266 gap)
OK: clean stop without deliverable: died series + STOP-REASON writer called
OK: non-clean failure: died series only, OnFailure rail owns STOP-REASON
OK: success with deliverable: stale series for THAT unit cleared, others kept
OK: --clear removes exactly the named unit's series (empty dispatch)
OK: dry-run prints verdict, writes nothing
PASS: pi-detached-deadman verdict matrix (7 cases)
EXIT: 0

$ bash tests/pi-systemd-run.test.sh
OK: dry-run accepts --deadline/--provider/--model/--chain-id/--hop (fleet-ops#1009)
OK: --deadline 30 wires RuntimeMaxSec=30min (fleet-ops#3328)
OK: real dispatch: ledger append + packet copy + provider parse (fleet-ops#1009)
OK: --deadline/--hop validation rejects junk (fleet-ops#1009)
OK: FLEET_DISPATCH_LEDGER_NO_WRITE suppresses ledger append (fleet-ops#1009)
EXIT: 0

$ bash tests/escalation-coverage-canary.test.sh
OK: scenario2e: empty systemd-run audit trail is clean (fleet-ops#4266)
OK: scenario2f: raw systemd-run transient named and canary exits 1 (fleet-ops#4266)
OK: scenario2g: pi-systemd-run execve (with OnFailure) is clean (fleet-ops#4266)
OK: scenario2h: fleet-unit-run rule not loaded -> PENDING, not false-clean (fleet-ops#4266)
OK: escalation-coverage-canary: covers VPS + GitHub planes, exclusions, and pending holes
EXIT: 0

$ bash tests/fleet-resilience-drill.test.sh
OK: fleet-ops#455 resilience drill acceptance pass
EXIT: 0
```

## run-proof

- `tests/pi-detached-deadman.test.sh` — new, runs in the P14 `tests:` job
  `verify-command` list (hosted by `tests/pi-systemd-run.test.sh` per the P14
  listing gate).
- `tests/escalation-coverage-canary.test.sh` — extended with scenarios 2e-2h
  (fleet-ops#4266) and block 14 of the canary.
- `tests/fleet-resilience-drill.test.sh` — extended with the dead-man drill
  acceptance.
- No new unit/timer/path-unit/workflow added — only edits to existing
  `bin/`/`config/`/`prompts/` + two new `bin/` helpers + one new `tests/` file.

research: official docs (systemd.exec ExecStopPost, ausearch(8), auditctl(8), healthchecks.io ping API) + existing bin/keystone-hc-ping checked. Compared: (a) hand-written stop-requester watcher — rejected, the issue forbids it ("No hand-written watcher"); (b) systemd's own OnFailure= + ExecStopPost — adopted for the verdict rail (off-the-shelf, no new organ); (c) auditd/ausearch — adopted for the audit trail (off-the-shelf distro package, the issue names it); (d) healthchecks.io ping API via existing keystone-hc-ping — adopted for the dead-man transport. bin/pi-detached-deadman is the ExecStopPost salvage (mechanism is systemd's; no off-the-shelf tool turns exit-0-without-deliverable into a FAILURE). bin/fleet-who-stopped is a thin ausearch formatter (ausearch already does the query; the helper just names the stopper for the journal).

help-first: `ausearch --help` + `auditctl --help` + `systemd-run --help` read. ausearch already queries the audit trail but does not name "who stopped THIS unit" in one line — fleet-who-stopped formats that. systemd-run already accepts --property=OnFailure and ExecStopPost= but does not check a deliverable or ping healthchecks — pi-systemd-run + pi-detached-deadman add that.

## Diff scope

- `bin/pi-systemd-run`: +OnFailure, +healthchecks dead-man, +`--deadline`,
  +`--deliverable`, +ExecStopPost salvage wiring.
- `bin/pi-detached-deadman` (NEW): ExecStopPost salvage + verdict matrix.
- `bin/fleet-who-stopped` (NEW): ausearch stopper-naming helper.
- `bin/keystone-hc-ping`: +`detached` mode (start/success/fail pings).
- `bin/fleet-escalation-canary`: +block 14 (raw systemd-run lint + false-clean
  guard), +live-dummy exclusion carve-out for proof units.
- `bin/unit-escalation-write`: +live-dummy* exclusion so proof units do not
  summon the senior auditor.
- `config/audit/rules.d/30-fleet-unit-stop.rules` (NEW): auditd execve watch.
- `config/fleet_rules.yml` + `config/bare-metal-rebuild-manifest.json` +
  `MANIFEST` + `install.sh`: ship the audit rule file + new binaries.
- `prompts/worker.md`: standing text (raw systemd-run/nohup forbidden;
  --deadline + --deliverable required).
- `systemd/scope.d/10-escalate.conf`: scope escalation drop-in.
- `tests/`: pi-detached-deadman (NEW), pi-systemd-run (+host), escalation
  coverage canary (+scenarios 2e-2h), resilience drill (+dead-man), unit
  escalation write exclusion, metrics export, merged-pr-close, salvage.

## Notes

- Senior reviewer round skipped — fleet-ops is not a product repo per
  `config/intake-repos.json` (exempt).
- Out-of-repo standing text (judge packet `fable-check.md`, vault
  `global-standing-rules.md`) is a separate cross-project edit, filed as
  follow-up.

net-positive-because: new mechanism (fleet-ops#4266) — the dead-man verdict hook (pi-detached-deadman), the stop audit trail helper (fleet-who-stopped), the auditd rule, and the canary lint block 14 are net-new rails with no prior equivalent; the test coverage (pi-detached-deadman verdict matrix + 4 new canary scenarios + resilience drill) is the detector that prevents the bug class from recurring (mechanical-fix #366). Deletion-first applied: no new organ, no new unit/timer/workflow — all rails wired into existing bin/pi-systemd-run, bin/fleet-escalation-canary, bin/keystone-hc-ping, bin/unit-escalation-write.

loose-ends: out-of-repo standing text (judge packet + vault global-standing-rules) for fleet-ops#4266
