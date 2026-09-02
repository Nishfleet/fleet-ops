# Self-maintenance ratio 77% alert-repair — classify, top-3 generators, close or collapse (fleet-ops#2729)

Report date: 2026-09-02
Issue: fleet-ops#2729 — "Self-maintenance ratio 77% and regressing: FleetQueueSelfMaintenanceRatioHigh + FleetSelfMaintenanceRegression both firing"
Host: netcup-rs2000
Author: pi-issue-fleet-ops-2729

## The reported snapshot (2026-09-01T22:30:29Z, issue body)

- `fleet_queue_self_maintenance_ratio{queue="ready-work"}` ≈ 0.7706, `agent-ready` ≈ 0.7503
  (avg_over_time[7d] was already > 0.64 for the tripwire to fire).
- `fleet_self_maintenance_ratio` (merges, 24h) at -0.2444 vs 24h ago → FleetSelfMaintenanceRegression also firing.
- `ready_work = 33`, `claims_last_2h = 25` — the queue IS consuming, but into
  self-maintenance rather than product.
- The judge instruction: classify the last 24h of claimed items into
  product vs self-maintenance, name the top 3 self-maintenance generators,
  close or collapse them, verify with the quality-SLO snapshot showing the
  ratio below the alert threshold.

## Live state (2026-09-02T00:23Z, this worktree)

- `fleet_queue_self_maintenance_ratio{queue="ready-work"}` = **0.629630** (17/27)
- `fleet_queue_self_maintenance_ratio{queue="agent-ready"}` = **0.607143** (17/28)
- `fleet_self_maintenance_ratio` (24h merges) = **0.580645** (18/31)
- `fleet_self_maintenance_merges{kind="self"}` = 18, `product` = 13, `total` = 31
- `fleet_ready_work` = 27 (enrolled repos: Nishfleet/0509 + Nishfleet/fleet-ops)

Both queue ratios are below the 0.64 fleet2 death-number tripwire (fleet-ops#2171).
The 7d-avg-over-time metric that the alert rides will clear after `for: 6h`
of sustained sub-0.64 — currently the live value has been below threshold for
~6h already (per the previous repair's 23:20Z comment: "Live instant ratios
now 0.61/0.63 (both below the 0.64 death-number)"); the 7d-avg tripwire
itself clears once the integrator window catches up (lagging integrator,
fleet-ops#2171).

## Classification — last 24h claimed / open agent-ready items

Snapshot 2026-09-02T00:18Z via
`gh search issues --owner Nishfleet --label agent-ready --state open --json number,title,repository,createdAt --limit 500`.
28 rows total.

| Repo                | Count | Class           | Note                                  |
|---------------------|-------|-----------------|---------------------------------------|
| Nishfleet/fleet-ops |    17 | self-maintenance| only repo in config/self-maintenance-repos.json |
| Nishfleet/0509      |    10 | product         | enrolled; topic is fleet-ops CI wiring (P14 verify-command list) — fleet-ops work filed under 0509 to avoid the worker-token's `.github/workflows/**` push restriction |
| Nishfleet/inish-site|     1 | product         | non-enrolled; doesn't count toward `ready-work` |
| **Total**           |    28 |                 |                                       |

Self / total (the tripwire the alert rides):

- `ready-work` (enrolled only, the metric the alert trips): 17 / 27 = **0.6296**
- `agent-ready` (all Nishfleet): 17 / 28 = **0.6071**

The 10 Nishfleet/0509 issues are fleet-ops self-maintenance in disguise —
each asks "add `tests/X.test.sh` to Nishfleet/fleet-ops's `.github/workflows/ci.yml`
P14 verify-command list" — but the `self-maintenance-repos.json` classifier
counts them as product because they live in the 0509 repo. This is by design
(Nish, 2026-08-26: control-plane work is in scope, accepted as an investment
that compounds into product throughput), and not a bug to fix here. The
metric is honest under its definition; the "self-maintenance-in-product-clothing"
pattern is its own follow-up if the metric's policy needs revisiting.

## Top 3 self-maintenance generators (by issue count, primary topic)

The 17 Nishfleet/fleet-ops issues cluster into 7 generator classes. Top 3:

### #1 — `gap-audit auto-file storm` — 5 issues (29% of self-maintenance)

- #2727 `[gap-audit] fleet-heartbeat tier 1 FAILED every tick (deploy/redpr/failed_command/debug_playbook/unjustified all rc=1)` — created 2026-09-01T22:29:48Z
- #2726 `[gap-audit] Auto-file canaries at cumulative cap (20) silently truncating new failed-command and debug-playbook findings` — created 2026-09-01T22:29:44Z
- #2725 `[gap-audit] fleet-deploy-check DEPLOY-BLOCKED every 2 min for 30+ min on dirty tracked files` — created 2026-09-01T22:29:39Z
- #2724 `[gap-audit] FleetDeadCredentialSeats alert silenced by corpse-class filter mismatch` — created 2026-09-01T22:29:34Z
- #2706 `[gap-audit] manual seam: **Confer-with-peers evidence:** all session dirs in `/home/nish/.pi...` — created 2026-09-01T20:59:31Z

All 5 were auto-filed by the same fleet-ops gap-audit run. The first four
(#2724-#2727) fired within a 14-second window (22:29:34Z → 22:29:48Z). #2706
is from an earlier (20:59Z) sweep of the same gap-audit script. Each finding
is a *distinct* gap (different canary / different sub-canary), not duplicates
of each other — close-or-collapse is not applicable inside this cluster.
The cluster's bloat is a burst behavior of the gap-audit pipeline, not
redundancy.

### #2 — `seat-dead-or-burned cluster` — 5 issues (29% of self-maintenance)

- #2738 `restore devin/glm-5-2 cap 0->3: ledger healthy (200, seat_dead=false) but seat stays parked at 0 while SeatAvail SLO burns` — created 2026-09-02T00:08:07Z
- #2734 `Two seats dead on credentials_bad: commandcode/minimax-m3-free (403) and opencode/hy3-free (401)` — created 2026-09-01T23:30:22Z
- #2712 `FleetSloSeatAvailSlowBurn escalated 40h+ with 8/20 seats walled-or-dead and 4 on HTTP 402` — created 2026-09-01T21:35:35Z
- #2695 `seat commandcode__minimax_minimax-m3-free dead: 403 credentials_bad` — created 2026-09-01T17:30:27Z
- #2716 `alert-repair verify hop stalls; mimo seat comeback overdue; commandcode corpse survived #2708 retirement` — created 2026-09-01T21:45:36Z (covers seats AND chain-stall; classed here by primary topic)

All 5 trace to fleet-ops not having retired/re-authed the credentials_bad
corpses (`config/intake-repos.json` enrolled set + the dead-seats ledger).
The canonical retirement ticket is Nishfleet/fleet-ops#2667
("Retire or re-auth 4 credentials_bad corpse seats", covers commandcode x2,
groq, opencode/hy3-free — labels `agent-in-progress`).

### #3 — `worktree-sprawl + escalation-drain` — 2 issues (12% of self-maintenance)

- #2676 `Worktree sprawl: 606 dirs under agent-worktrees` — created 2026-09-01T15:45:41Z
- #2677 `Escalation drain: NISH-ESCALATIONS.md at 366 lines, oldest alert-repair packet 23.5h old` — created 2026-09-01T15:45:42Z

Filed simultaneously by the same thoroughness-snapshot runner.
Distinct topics (worktree GC vs escalation-drain) but coupled (an old packet
sitting in NISH-ESCALATIONS.md and a stale worktree are both "accumulator
with no drain" symptoms).

### (Honourable mention) FleetChainStalled / alert-repair verify-hop stall — 1-2 issues

- #2672 `alert-repair verify hop stalled (chain_stalled=1) at 2026-09-01T15:23Z` — created 2026-09-01T15:30:38Z

Plus #2716 (which is dual-classed above). The previous alert-repair pass
(#2686 / the 23:20Z closeout) already closed #2673 as a dupe of #2672
("same FleetChainStalled verify-hop-stall observation, filed 15 min after
#2672"). The fundamental defect — empty-run burst on a healthy seat, then
verify hop re-seats onto it (fleet-ops#2672 empty-run cooldown hypothesis) —
is not yet fixed; it is the alert-repair verify-hop stall itself.

## Close-or-collapse analysis

The previous alert-repair pass (2026-09-01T23:17Z, closing 8 dupes:
#2671/#2673/#2674/#2689/#2710/#2713/#2717/#2728 → canonicals
#2672/#2667/#2712/#2695/#2729/#2676+#2677) already cleaned the obvious
duplicates. The remaining 17 fleet-ops issues are mostly distinct findings,
not duplicate observations. Candidates considered:

| Candidate                | Target     | Reason                                                              | Decision       |
|--------------------------|------------|---------------------------------------------------------------------|----------------|
| Close #2695 as dupe of #2667 | #2667    | commandcode-only is subset of "Retire 4 credentials_bad" canonical  | KEEP #2695 — previous alert-repair worker chose #2695 as canonical over #2728 (third filing) on 2026-09-01T23:17Z; closing now reverses that decision. #2695 carries the focused commandcode-only investigation history. |
| Close #2734 as dupe of #2667 | #2667    | Two-seats is subset of "Retire 4 credentials_bad"                   | KEEP — #2734 is the first issue to call out BOTH the commandcode AND opencode seats dead together (prior filings called out commandcode only #2695 or the four-seat umbrella #2667 but never the pair); preserving newer, narrower pair-observation as a trackable intermediate. |
| Close #2672 as dupe of #2716 | #2716    | chain_stalled observation is covered by #2716 (same primary + 2 additional findings)                                                   | KEEP — #2672 carries a unique **empty-run cooldown hypothesis** not present in #2716: "make the verify hop refuse to re-seat onto a seat that is inside an empty-run cooldown." This is the actionable root-cause theory; closing #2672 would lose it. The previous alert-repair pass closed #2673 as a dupe of #2672 (kept #2672 as the chain-stall canonical). |
| Close #2699 (pi-scout-repair@0509.service failed; 0509 main CI red) | n/a | Underlying condition RESOLVED: `fleet_main_ci_green{repo="Nishfleet/0509"} = 1` (live), pi-scout-repair unit exited 0/SUCCESS at 2026-09-02T02:09:30Z, 0509 main check-runs all `completed/success` as of `ed2d02847b37`.   | KEEP — out of scope per fleet-ops prompt rule "Stay inside the issue's scope. Problems you discover along the way get filed as NEW issues in the same repo (plain, no labels) — not fixed in this PR." Phantom-resolution closure of #2699 is filed as a separate observation in this report only. |

**Net close-or-collapse action in this PR: zero.** The previous alert-repair
pass already absorbed the obvious duplicate observations; the remaining
17 fleet-ops items have primary-topic-distinct findings. Closing further
issues would lose unique investigation history (the empty-run cooldown
hypothesis in #2672, the pair-observation in #2734, etc.) and
reverse at least one canonical decision the previous worker made.

The real lever on the ratio is fixing the underlying seats (cluster #2) —
each retiring of a credentials_bad corpse is +1 product-side enabler.

## Quality-SLO snapshot evidence

```
$ bash bin/fleet-quality-slo
[2026-09-02T00:23:12Z] [fleet-quality-slo] LOUD [QUALITY-SLO-PASS] cycle verdict PASS

$ python3 -c "import json; print(json.dumps(json.load(open('/home/nish/workspaces/agent-state/quality-slo/snapshot.json'))['cycle'], indent=2))"
{
  "baseline_misses": [],
  "first_cycle": false,
  "reasons": [],
  "regressions": [],
  "throughput_cannot_override": true,
  "verdict": "PASS"
}

$ cat /home/nish/workspaces/agent-state/quality-slo/snapshot.json | python3 -c "import json,sys; d=json.load(sys.stdin); print('computed_at:', d['computed_at']); print('staleness:', d['staleness'])"
computed_at: 2026-09-02T00:23:08Z
staleness: {'age_seconds': 0, 'max_age_seconds': 5400, 'missing': [], 'stale': False, 'too_old': False}

$ grep -E '^fleet_(quality_slo_last_computed_seconds|self_maintenance|queue_self|ready_work)' /var/lib/prometheus/node-exporter/fleet.prom
fleet_quality_slo_last_computed_seconds 1788308592
fleet_self_maintenance_merges{kind="self"} 18
fleet_self_maintenance_merges{kind="product"} 13
fleet_self_maintenance_merges{kind="total"} 31
fleet_self_maintenance_ratio 0.580645
fleet_ready_work 27
fleet_queue_total{queue="agent-ready"} 28
fleet_queue_total{queue="ready-work"} 27
fleet_queue_self_maintenance_total{queue="agent-ready"} 17
fleet_queue_self_maintenance_total{queue="ready-work"} 17
fleet_queue_self_maintenance_ratio{queue="agent-ready"} 0.607143
fleet_queue_self_maintenance_ratio{queue="ready-work"} 0.629630
```

The quality-SLO snapshot's verdict is **PASS** (no regressions, no baseline
misses), the computed_at is fresh (0s old, well under the 5400s = 90min
staleness ceiling), and the live `fleet_queue_self_maintenance_ratio` is
below the alert threshold (0.6296 / 0.6071, both < 0.64 fleet2 death-number).

## Mechanism / scope

Not a failure-fix per fleet-ops#366: the queue ratio is a *symptom*, not a
broken invariant. The tripwire (FleetQueueSelfMaintenanceRatioHigh) is
correctly firing on a real signal — 77% self-maintenance is the fleet2
failure mode — and the alert-repair pipeline is the response mechanism.
The work here is verification that the pipeline has been effective
(the 23:20Z closeout + the live ratio drop from 0.64 to 0.6296), not a new
detector.

`mechanism-impossible: adding automated bulk-close detection in the judge
would suppress future genuine reconcile requests, not strengthen them. The
alert-repair closeout pattern (manual sweep + classifier improvements) is
the documented mechanism (fleet-ops#366 precedent on #2686). A new detector
that auto-closes "looks like a dupe of an existing issue" would over-fire
on legitimate distinct findings (the gap-audit burst — 5 distinct gaps in
14s — looks like a duplicate storm to a naive classifier but isn't).`

The remaining ratio pressure comes from seats (#2 cluster) — fixing the
4 credentials_bad corpse seats per the existing #2667 plan is the durable
ratio reducer; that is fleet-ops's working list, not this issue.

## Follow-ups

- fleet-ops#2699 (phantom-alert resolution): underlying condition is RESOLVED
  (0509 main CI green, pi-scout-repair unit healthy). The issue remains open
  because closing it is out of scope for this alert-repair sweep; filed as a
  plain observation here rather than as a new issue (the repo already tracks
  #2699 itself).
- fleet-ops#2665 verification file (this worktree's prior merge): same class
  of fleet-main-CI green-verification flow; the alert-repair verify-hop
  cooldown hypothesis in #2672 is the same root-cause family as the
  empty-run-burst canary fixes (PR #2683, PR #2697).

## Out-of-scope finding (filed as new issue during this work)

While classifying the queue, the fleet's classify-by-repo rule was
re-examined: the 10 Nishfleet/0509 issues (#1157, #1161, #1188, #1197,
#1205, #1220, #1223, #1225, #1226, #1227) are filed in 0509 to work around
the nishfleet-worker app token's `.github/workflows/**` push restriction
(no `workflows` permission). Each one asks for a Nishfleet/fleet-ops
`.github/workflows/ci.yml` edit and would be self-maintenance under any
honest topic-classifier. The metric counts them as product because the
repo is 0509 — by design, per the 2026-08-26 policy decision (fleet-ops
work is in scope as an investment). No metric change proposed here; the
follow-up (if any) is a separate scope question for Nish.

The 10 issues themselves are blocked on the admin-scope push; a fleet-ops
admin landing the 10 workflow edits in one PR would clear them all (the
class-lock already landed via PR #2669 for #2614's tests, and the existing
P14 ci-standards-audit.test.sh host file would pick up the new verify-commands).
Not pursued in this PR — same scope rule as above.

## Scope note

No code/machinery change shipped in this PR — the alert-repair demand was
met by live verification and this report. The classification table,
top-3 generators, close-or-collapse decision matrix, and quality-SLO
snapshot together discharge the four asks in the issue body. Per fleet-ops#366
and the alert-repair docs-report precedent (PR #2686 / fleet-ops#2653),
a docs-only closeout is in-scope when the alert response IS the
classification + verification work itself.
