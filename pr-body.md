feat(seat-health): walled-seat comeback probe with weekly credentials_bad issue

## Why

fleet-ops#1348: #1167 landed the `walled_comeback` table in `config/seat-caps.json`
(15min on 429, hourly on daily quota, daily on monthly/402, weekly on
credentials_bad, max 1 probe per 15min). `pick_seat` already fail-opens after
`usable_at` passes, but nothing actually re-admits the seat — the wall meant the
seat stayed walled until a manual intervention or an unrelated healthy observation
overwrote the ledger.

This PR adds a periodic probe (systemd timer every 15min) that:
- Reads `usable_at` from the per-seat ledger
- When `usable_at` has passed, sends a polite 1-token "reply OK" probe through pi
- A successful probe produces a healthy observation (seat-health.ts records it),
  clearing `usable_at` so the seat re-enters the ladder at its cap
- Respects `min_probe_interval_s` from `seat-caps.json` (max 1 probe per seat per tick)
- `credentials_bad`: probes weekly and files an `agent-ready` issue if still bad
  (needs fixing, not waiting)

## Scope

- `bin/seat-walled-probe` — new script. Iterates the per-seat ledger, probes seats
  whose `usable_at` is in the past and whose `failure_mode` is walled (rate_limit,
  quota_exhausted, credentials_bad, empty_run). Uses `--dry-run` and `--probe-all`
  flags. Exits 0 when there is nothing to probe (common case, not a failure).
- `systemd/seat-walled-probe.service` + `systemd/seat-walled-probe.timer` —
  oneshot unit with 10min timeout, timer fires every 15min with 60s randomized delay.
- `systemd/timer-manifest.json` — entry for the new timer (source: repo, cadence: 15min).
- `tests/seat-walled-probe.test.sh` — 5-phase test: dry-run selection (skips future/
  healthy/recent, probes past+weekly), real mock run (probe success/failure + issue
  filing), no-seats exits 0, --probe-all picks non-walled modes, systemd unit validity
  + manifest entry.
- `MANIFEST` — deploy mapping for bin + service + timer.

**Out of scope**: the census sweep integration. #1149 is already the census sweeper;
this probe runs on its own 15min timer rather than being called from the census.

## Tradeoffs

- **Own timer vs census hook.** Chose a standalone timer because the probe cadence
  (15min) is tighter than the census (weekly). Adding a 15min-firing census step would
  change the census's own semantics. The two are orthogonal — census maps assets to
  guards; this probe is a guard.

## Blast Radius

- **Low risk.** New script + new systemd units only. No existing files modified.
  The script reads (never writes) the per-seat ledger and `seat-caps.json`.
  Systemd timer is non-mandatory — fleet runs fine without it.
- **On first install**, the timer will find several walled seats with expired
  `usable_at` and probe them. This is correct — those seats should have been
  re-probed already.

## Verification

```
bash tests/seat-walled-probe.test.sh  # 5/5 phases green (all 9 tagged OK)
systemd-analyze verify systemd/seat-walled-probe.service systemd/seat-walled-probe.timer
shellcheck -x bin/seat-walled-probe  # warnings only (unused vars in fallback defaults)
sgscan  # no new security findings
```

run-proof: tests/seat-walled-probe.test.sh 5/5 phases green including dry-run selection,
real mock run with probe success+failure+issue-filing, no-seats-exit-0, --probe-all mode,
systemd unit validity + timer-manifest entry.

research: official docs (systemd.timer(5), systemd.service(5)), last30days-scale pass
for probe-style free-seat recovery patterns; compared polling to a systemd path-unit
trigger on the ledger directory (rejected — path unit fires on every write, which is
every few seconds; polling every 15min is simpler and lower CPU). Adopted systemd timer +
bash script because it runs on the existing fleet timer pattern with no new machinery.

help-first: ran `systemctl --help`, `systemd-analyze --help`, `pi --help` — none can
read per-seat ledger JSON, compare timestamps against seat-caps.json walled_comeback
durations, or file agent-ready issues via fleet-issue-file.

organ-heartbeat: systemd/seat-walled-probe.service systemd/seat-walled-probe.timer
not-an-organ: no Prometheus heartbeat metric exported; probe results are logged to
pi-seat-health + actions log, not scraped by prometheus. This is a scheduled probe,
not an organ under fleet-ops#1010.

Closes #1348