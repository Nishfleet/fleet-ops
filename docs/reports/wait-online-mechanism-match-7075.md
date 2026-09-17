# Wait-online mechanism match for #7075

Issue #7075 cites #3103. Its duplicate #7079 cites #3098, which was
folded into #3039. Both describe the system-scope wait-online failure
starting 2026-09-03T02:17:40Z. The September 7 recovery comment on #3039
alone does not prove prevention. This report maps both records to the
existing repair documentation and regression coverage.

## Existing delivery

[PR #3115](https://github.com/Nishfleet/fleet-ops/pull/3115) attempted to
mask the unit. That is NOT the accepted repair.
[PR #3141](https://github.com/Nishfleet/fleet-ops/pull/3141), merged on
2026-09-04T07:38:02Z as `fce8791e5d06f67c516187af0d6565515150fad9`,
removed that manifest entry and replaced its test with a no-mask guard.

The #3141 investigation recorded eth0 stuck in `configuring` while waiting
for DHCPv6. Wait-online succeeded once eth0 reached `routable (configured)`.
Netplan regenerated and re-enabled the unit, so masking was neither a
network repair nor durable prevention.

Current ownership on tested base `a8491b36ae18b13e95c98811a3cb813cc7d73015`:

- `docs/bare-metal-rebuild.md`, "Do NOT mask" section: records the diagnosis,
  static-network repair and recurrence checks.
- `config/bare-metal-rebuild-manifest.json`: excludes wait-online from
  `masked_units`; the description explains why.
- `tests/fleet-bare-metal-rebuild.test.sh`, section 5c: fails if wait-online
  is reintroduced to that list.
- `bin/fleet-rebuild-verify-check` and its test require actual verification
  evidence for rebuild changes. The test includes the #3141 change shape.
- `config/fleet_rules.yml`, `SystemUnitFailed`: detects system units failed
  for five minutes. Detection is not automatic network repair.

## Real acceptance receipts, 2026-09-17

`git merge-base --is-ancestor fce8791e5d06f67c516187af0d6565515150fad9 origin/main`
returned 0. The owning delivery is already on main. This report is not a deploy.

At 20:35 UTC, `networkctl status eth0 --no-pager` reported
`routable (configured)` and `Online state: online`.
At 20:45:15 UTC, system-scope observations of the real unit returned:

```text
systemctl show systemd-networkd-wait-online.service
LoadState=loaded
ActiveState=active
SubState=exited
Result=success
ExecMainStatus=0
NRestarts=0
ExecMainStartTimestamp=Sun 2026-09-13 03:33:05 IST
systemctl is-enabled systemd-networkd-wait-online.service
enabled-runtime
```

The start timestamp is 2026-09-12T22:03:05Z. This is a completed boot run,
not merely an enabled unit. No restart was forced.

At 20:45:15 UTC, the local Prometheus `/api/v1/query` request for
`ALERTS{alertname="SystemUnitFailed"}` returned `status=success` and an empty
result vector. System-scope `systemctl list-units --state=failed` also
listed zero units at 20:35 UTC.

Both existing suites passed:

```sh
bash tests/fleet-bare-metal-rebuild.test.sh
bash tests/fleet-rebuild-verify-check.test.sh
```

The first exercised the real manifest's wait-online exclusion. Its container
checks use skipped/mocked containers; they are not a real host rebuild proof.
The second exercised rejection of missing rebuild receipts and acceptance
of the #3141 receipt shape. These checks prove the existing guards, not
automatic recovery from a fresh DHCPv6 fault.

## Boundary

mechanism-impossible: Automatic root-level network repair is outside this
issue's authorized scope. #3141 already records that limit. The existing
no-mask regression guard, diagnosis/runbook and failed-unit detection are
the matched coverage. No unattended network repair is claimed or added.

The #7079 record is included in this mapping. No units were masked, no
network or security controls changed, and no claim of a new repair is made.
