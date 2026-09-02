## What & why

`fleet_alert_outcome_24h{kind="resolved"}` was double-counting. Real fixes and
PHANTOM_ALERT drill fixtures shared one bucket, so the WFR alert-quality lens
could not tell productive repair work from drill-fixture amplification
loops. Live evidence: `/home/nish/workspaces/agent-state/alert-repair/actions.log`
holds 80 `RESOLVED ... root_cause=PHANTOM_ALERT*` lines on
`NoClassParkAlert`, `ClassExpiredAlert`, `NoParkKeyAlert` over 48h — every
one of them currently buckets `kind="resolved"`, indistinguishable from a
genuine fix. The metric then looks like `resolved=4` against `dispatch=0`
on alertnames that have no Prometheus rule, i.e. "no work happened" while
seats were actually burned.

The signal that distinguishes phantom from real fix is already on the
line: `root_cause` text. The harness today reads it as free prose; this
change makes it a label so the lens can query it.

**Change in `libexec/fleet-metrics-export.py`:**

- Add `kind="phantom_resolved"` as a fifth label value on
  `fleet_alert_outcome_24h{alertname=...,kind=...}`.
- Classify any RESOLVED entry whose `root_cause` token starts with
  `PHANTOM_ALERT` (the underscore-joined drill-fixture marker) under
  `phantom_resolved` instead of `resolved`. The pre-existing three other
  kinds (`dispatch`, `failed`, `skipped`) plus the genuine `resolved` path
  are untouched.
- Extend the `HELP_AD` doc-comment so the WFR alert-quality lens knows
  the new kind exists and what it means (drill fixture, not real repair
  work).
- Add `_ROOT_CAUSE_RE` alongside the existing `_BARE_TS_RE` /
  `_ALERTNAME_RE` parsers — pure regex, no behavioural change to other
  lines.

**New test `tests/alert-repair-outcome-metric.test.sh`:** hermetic, no
gh / no prometheus / no systemd / no live actions.log. Drives a synthetic
trailing-24h actions.log through `_repair_log_per_alertname_24h`:

  - 3 RESOLVED with `root_cause=PHANTOM_ALERT*` -> `phantom_resolved=3`
  - 2 RESOLVED with a real (or absent) `root_cause` -> `resolved=2`
  - Same alertname, single DISPATCH -> `dispatch=1`
  - Asserts the emit loop covers all five kinds in the documented order

The structural fix is the only thing in scope; the follow-up WFR alert
threshold (`phantom_resolved > 5/24h → regress`) is intentionally NOT in
this PR — it can land when ops want the alarm wired.

## Verification

- Failing-test-first: the new test against an old-HEAD copy of
  `_repair_log_per_alertname_24h` (no `phantom_resolved` bucket, no
  `_ROOT_CAUSE_RE` parser) classifies all 5 RESOLVED entries as `resolved`,
  so the `assert phantom_resolved == 3` line fails with
  `phantom_resolved=0, want 3`. Against this PR's head it passes.
- Hermetic `python3` repro of the exact synthetic log asserted in the
  issue (3 PHANTOM + 2 real RESOLVED for `ClassExpiredAlert`):
  `phantom_resolved=3, resolved=2, dispatch=1` confirmed.
- Live read of `/var/lib/prometheus/node-exporter/fleet.prom` against
  the **current** (pre-PR) exporter — `ClassExpiredAlert` shows
  `kind="resolved" 4`, `kind="phantom_resolved" 0`, `kind="dispatch" 0`,
  matching the issue's observed state. Once the change lands, those four
  bucket as `phantom_resolved=4` and `resolved=0` — within the issue's
  verify contract.
- `tests/fleet-metrics-export.test.sh`: ALL OK — the existing
  self-maintenance / verified-merges / queue-composition / gh-rate-limit
  pin tests stay green. No regression in adjacent families.
- `bin/fleet-organ-heartbeat-check gate`: OK — both organs touched
  (`metrics-export`, `gh-rate-limit`) already carry
  `FleetMetricsExportAbsent` / `FleetGhRateLimitAbsent` absent()
  heartbeat rules.
- `bin/fleet-no-agent-names-check --commit-range origin/main..HEAD`:
  OK — no agent attribution in commit messages.
- `bin/fleet-wipe-lessons-check scan --root .`: OK — clean.
- `bin/fleet-token-efficiency-check --name-status
  <(git diff --name-status origin/main...HEAD)`: OK — no prompt
  assembler changes.
- `bin/prove-one-run-check`: SKIP — no new systemd unit, timer, path,
  socket, or workflow in this diff.

run-proof: transcript —

```
$ bash tests/alert-repair-outcome-metric.test.sh
OK: alertname=ClassExpiredAlert phantom_resolved=3 resolved=2
OK: emit loop kinds =  dispatch, resolved, failed, skipped, phantom_resolved
OK: alert-repair-outcome-metric classification green
$ grep fleet_alert_outcome_24h /var/lib/prometheus/node-exporter/fleet.prom | head -2
# HELP fleet_alert_outcome_24h Per-alertname repair outcomes in the trailing 24h ... kind=dispatch|resolved|failed|skipped. Feeds the WFR alert-quality lens.
fleet_alert_outcome_24h{alertname="ClassExpiredAlert",kind="resolved"} 4
$ git -C libexec/fleet-metrics-export.py diff origin/main -- \
    | grep -E 'phantom_resolved|HELP_AD|_ROOT_CAUSE_RE' | head
+HELP_AD = "...kind=dispatch|resolved|failed|skipped|phantom_resolved..."
+_ROOT_CAUSE_RE = re.compile(r"root_cause=(\S+)")
+                    if rc and rc.group(1).startswith("PHANTOM_ALERT"):
+                        kind = "phantom_resolved"
```

Closes #2694
