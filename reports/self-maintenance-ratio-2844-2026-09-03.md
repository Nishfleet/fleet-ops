# FleetQueueSelfMaintenanceRatioHigh — classify, cap, closeout (fleet-ops#2844)

Report date: 2026-09-03
Issue: fleet-ops#2844 — "FleetQueueSelfMaintenanceRatioHigh firing for 84h, 0.75-0.77, zero product-repo claims"
Host: netcup-rs2000

## Reported snapshot (2026-09-02T15:45:00Z, issue body)

- `fleet_queue_self_maintenance_ratio{queue="ready-work"}` ≈ **0.7706**
- `fleet_queue_self_maintenance_ratio{queue="agent-ready"}` ≈ **0.7503**
- `ready_work = 54`, `claims_last_2h = 4`
- All 4 claims in the 2-hour window were `Nishfleet/fleet-ops`:
  - #2716 alert-repair verify-hop stall
  - #2724, #2725, #2726 three `gap-audit` findings
- Zero product-repo claims in the window.

## Live state (2026-09-03T00:13Z, this worktree)

- `fleet_queue_self_maintenance_ratio{queue="ready-work"}` = **0.583333** (14/24)
- `fleet_queue_self_maintenance_ratio{queue="agent-ready"}` = **0.560000** (14/25)
- `fleet_ready_work` = 24 (enrolled repos: Nishfleet/0509 + Nishfleet/fleet-ops)
- `gap-closure/precedence` is still `loop` (intensive gap-closure loop is converging)
- 5 open `gap-audit` + `agent-ready` issues still on the board

The live instant ratio is below the 0.64 fleet2 death-number tripwire but still above the 0.50 `product-first` hold threshold, so `fleet-ops` intake is being held to the floor lane while `0509` should proceed once the `gap-audit` board drains.

## Classification — last 50 ready-work items (by createdAt, enrolled repos)

Source: `gh issue list -R Nishfleet/fleet-ops --label agent-ready`, `gh issue list -R Nishfleet/0509 --label agent-ready`, merged and sorted by `createdAt`, last 50.

| Repo                | Count | Class           | Note |
|---------------------|-------|-----------------|------|
| Nishfleet/fleet-ops |    50 | self-maintenance| only repo in `config/self-maintenance-repos.json` |
| Nishfleet/0509      |     0 | product         | 0509 agent-ready items are older than the 50 most recent; the queue head is all fleet-ops |
| **Total**           |    50 |                 |      |

Self / total: 50 / 50 = **1.00** for the last 50 created issues.

### Generator classes within the 50

| Generator class | Count | Share | Examples (issue numbers) |
|-----------------|-------|-------|--------------------------|
| seat / credentials_bad / corpse / FleetSloSeatAvail | 20 | 40% | #2604, #2606, #2612, #2624, #2628, #2634, #2671, #2689, #2710, #2728, #2777, #2778, #2793, #2798, #2804, #2809, #2818, #2867, #2874, #2917 |
| `gap-audit` auto-file | 11 | 22% | #2590, #2591, #2593, #2596, #2597, #2910, #2912, #2913, #2923, #2924, #2925 |
| intake starvation / ready_work anomalies | 5 | 10% | #2592, #2603, #2613, #2653, #2713 |
| alert-repair / main CI red | 4 | 8% | #2673, #2816, #2849, #2908 |
| empty-run storm | 3 | 6% | #2611, #2615, #2623 |
| worktree / hygiene | 3 | 6% | #2616, #2717, #2774 |
| 0509 scout futility (escalate-senior) | 1 | 2% | #2754 |
| metrics-export fix | 1 | 2% | #2920 |

## Top generator and chosen cap

The largest class by count is the **seat/credentials_bad/corpse** cluster (20 issues). These are alert-repair and canary responses to live seat failures; they are not produced by a single unconstrained generator, so they cannot be capped without masking real fleet faults.

The most cap-able mechanical generator is the **`gap-audit` auto-file storm** (11 issues, 22% of the last 50). The previous audit run that created #2590-#2597 filed 5 `gap-audit` issues in a 14-second window. While `precedence=loop`, any open `gap-audit` issue causes `fleet-gap-closure-yield` to make product repos yield. A burst of 5 keeps the board non-empty for 5 consecutive claims, which starves product work.

The chosen cap: lower `AUDIT_MAX_FINDINGS` in `bin/fleet-blind-audit` from **5 to 1**.

Effect:
- A single `fleet-blind-audit` run can now file at most one `gap-audit` issue.
- The panel still ranks findings; the top one is filed, the rest are logged as skipped in the report.
- The `gap-audit` board drains to one claim, then to zero, opening a `proceed` window for `0509` under `fleet-gap-closure-yield`.
- The `fleet-gap-closure-loop` can then advance through drill/measure/conference without the board being re-filled by a 5-issue burst.
- `AUDIT_MAX_FINDINGS` remains overridable via environment for drills or exceptional sweeps.

## Closeout

- `bin/fleet-blind-audit` updated: `MAX_FINDINGS` default changed from 5 to 1; help text updated.
- `tests/fleet-blind-audit.test.sh` passed; the test still sets `AUDIT_MAX_FINDINGS=5` to exercise the cap path.
- The cap is a one-line parameter change, not new machinery.

Closes #2844.
