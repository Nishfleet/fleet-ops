## What

Regression test for the `ESCALATION-PANEL-PENDING` alarm lifecycle (fleet-ops#4968, detector->queue reconciler fleet-ops#362). The senior escalation panel writes this LOUD line from `bin/pi-escalation-audit` while a candidate `escalate-senior` issue has no completed panel, and the reconciler files one observe-to-close issue per signal.

This PR does **not** close #4968 — the reconciler closes it via observe-to-close once the detector reports green (Per the issue body). The panel for candidate #4939 has since convened (unanimous FAIL, 2-of-3 dismiss), and #4938 was admitted, so both drop off the open `escalate-senior` set, the `ESCALATION-PANEL-PENDING` line stops firing, and #4968 observe-to-closes.

## What the test locks in

The alarm's signal key derives from the phrase, not a literal `signal:`/`unit=` token. It must stay **stable** — `loud/escalation-panel-pending/fleet-ops-candidate-age_s-active-missing` — no matter the candidate number or the audit counters, or the same never-green churn that hit FAILED-COMMAND-FAIL (#4944) returns. Scenario 14 proves:

- `14a` fresh PANEL-PENDING line auto-files agent-ready with the correct stable signal key and routing.
- `14a-key` the key is constant across candidates/counters (STOPWORD + DYNAMIC_RE stripping).
- `14b` while still alarmed, the open issue dedupes (heartbeat comment) and stays open.
- `14c` once the panel convenes (loud line gone -> detector green), the filed issue observe-to-closes.

## Verification

Real run (Execution IS the review, inner loop):

```
OK: scenario 14a: fresh ESCALATION-PANEL-PENDING auto-files agent-ready with the stable signal key
OK: scenario 14a-key: ESCALATION-PANEL-PENDING key is constant across candidates and counters
OK: scenario 14b: PANEL-PENDING still alarmed -> deduped, stays open
OK: scenario 14c: green ESCALATION-PANEL-PENDING observe-to-closes the filed issue
OK: all signal-reconcile scenarios passed
```

`bash tests/signal-reconcile.test.sh` -> all 9k/9h/13/14 scenarios pass; exit 0. `bash tests/escalation-coverage-canary.test.sh` -> pass. `bash bin/sgscan` -> no new security findings.

run-proof: signal-reconcile.test.sh (scenario 14a/14a-key/14b/14c) exercised against `lib/detector-queue-reconciler.py` with the fake gh + fleet-issue-file harness.

net-positive-because: the 81 added lines are a single durable regression test locking the observe-to-close closeout for the exact alarm class of #4968; it is self-limiting (no new tests/timers/workflows/units, no new bin/ files).

Test-only change: no systemd unit/timer/workflow touched, no bin/ files added, no shellcheck surface beyond the test file.

Relates to #4968 (fleet-ops#362).