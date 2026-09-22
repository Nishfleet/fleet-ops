# Observe-close for #7709 — intake hold and its gauge were deleted in the 2026-09-18 glue sweep; retained TSDB data says coincidence, not causation

Issue #7709 (filed 2026-09-18, auto-labeled `agent-ready` by fleet-heartbeat
at 10:47:56Z) asked two things: (1) determine whether the precedence-band
product-first hold *caused* the lower product merge rate its new gauge
measured — `fleet_intake_effectiveness_ratio{repo="fleet-ops"} = 0.733763`,
product merges 42.3/day inside hold windows vs 57.7/day baseline — or merely
coincided with it; and (2) re-tune `PRODUCT_FIRST_SELF_RATIO_MAX` in
`lib/precedence-band.sh` or the hold's engagement conditions if the effect
was causal or persistent (ratio < 0.9 across multiple consecutive windows).

By the time this claim ran (2026-09-22), neither the mechanism nor the
measurement exists. Both were deleted the same day the issue was filed, in
the verified glue sweep. The causal question is still answerable from the
Prometheus TSDB, which retained the whole `fleet_intake_*` family
(retention 40d) through the deletion point — this report is the resolution
record.

## What was found

1. **The hold mechanism is deleted — it was already uncalled glue.**
   `lib/precedence-band.sh` (530 lines, home of `PRODUCT_FIRST_SELF_RATIO_MAX`,
   `product_first_hold`, `product_first_is_self_maintenance`, and the
   `held-in-buffer:` evidence lines) was removed by `68e0954e7`
   ("cut(glue): delete 5 uncalled lib files …", 2026-09-18 21:46 IST) after
   every caller was re-verified live against `bin/ libexec/ systemd/
   prompts/ .github/ lib/`. At origin/main `07b6779a2` nothing emits
   `held-in-buffer` (zero grep hits outside `.git`), the intake journal has
   zero `held-in-buffer` lines on either side of the deletion
   (`journalctl --user -u pi-intake@fleet-ops.service`, checked
   2026-09-22 ~05:4x IST), `config/self-maintenance-repos.json` is gone, and
   `prompts/intake.md` carries no hold logic (only the unrelated
   "someone already holds it; skip" claim rule). `68e0954e7` is an ancestor
   of origin/main (`git merge-base --is-ancestor` passes).

2. **The measurement is deleted — the gauge lived about one hour.**
   `81227264f` ("chore(glue-sweep): cut the metrics-slo meta-monitoring
   cluster", 2026-09-18 17:42 IST) removed
   `lib/intake-prioritization-effectiveness.py`, the intake-effectiveness
   exporter drop-in, and the `fleet_intake_prioritization` alert group
   (3 alerts incl. `IntakePrioritizationIneffective`) from
   `config/fleet_rules.yml`, explicitly replacing meta-monitoring
   ("did the intake hold lift product throughput?") with the primary alerts
   firing or not firing. Live state 2026-09-22: the cited evidence file
   `/var/lib/prometheus/node-exporter/fleet-intake-effectiveness.prom` is
   absent; `fleet_intake_effectiveness_last_run_seconds` shows the last
   export at 2026-09-18T11:55:11Z, ~17 min before the deletion commit;
   every `fleet_intake_*` series in the TSDB ends 2026-09-18T12:00Z. The
   ratio gauge the issue reads — shipped that morning by PR #7704
   (fleet-ops#7667) — produced exactly 5 samples over ~1h
   (11:00–12:00Z, ≈0.7723). The issue's `verify` step (the gauge across
   ≥2 non-overlapping 14d windows) was never achievable: the instrument's
   entire lifetime was one hour.

3. **The retained data says coincidence — the confound the issue named is
   structural.** The hold engaged only when the agent-ready queue's
   self-maintenance share exceeded `PRODUCT_FIRST_SELF_RATIO_MAX = 0.5`,
   i.e. it *selected* maintenance-dominated windows. Over its whole retained
   life the hold was engaged ≤5.5% of any trailing 14d window
   (`fleet_intake_hold_fraction_14d`: 0.032 → 0.053, max 0.0549,
   Sep 10–18), so `rate_during_hold` is computed on a small biased slice:
   when the queue is mostly fleet-ops issues, the product inflow is thin by
   construction and product merges/day mechanically dips — regardless of
   what the hold does. The metric confirms the noise rather than a stable
   effect: `fleet_intake_prioritization_effectiveness{repo="0509"}`
   oscillated from −1.00 to **+2.03** across Sep 10–18, was **+0.057** as
   late as Sep 15, and only printed its negative tail (−0.23, the −0.266
   the issue cites) in the final hours — during the glue sweep itself, the
   heaviest self-maintenance burst of the window. Meanwhile the hold's
   actual lever worked as designed: control-plane merge rate inside holds
   ran 44.5–54.3/day vs a 64–87/day baseline — the hold suppressed
   fleet-ops, freeing slots; it cannot consume product capacity, so a
   *causal* reduction of product merges has no mechanism.

4. **The persistence trigger was never met.** Accept #2 fires only on
   "ratio < 0.9 for multiple consecutive windows". The effectiveness series
   changed sign repeatedly within a single window (positive Sep 15,
   negative Sep 18); the ratio gauge never accumulated even one full
   window. Nothing in the retained data satisfies the re-tune condition —
   and there is no longer anything to re-tune.

## Resolution

The question the issue poses is moot: the system under test was deleted in
the same sweep that authored the filing's stimulus reading. On the evidence
that remains, the 0.73 reading is the expected signature of a
conditioned-on-maintenance-window measurement, not proof the hold harmed
product throughput; the hold's observable effect (suppressing fleet-ops
merges during maintenance-heavy windows) was the intended one. No code,
config, or alert change is warranted; restoring the hold would reverse a
deliberate, caller-verified deletion and is an orchestrator-level call this
report does not make.

Evidence receipts: commits `81227264f`, `68e0954e7`, `1ae2704cc` (all
ancestors of origin/main `07b6779a2`); prom queries against
127.0.0.1:9090 on 2026-09-22 (40d retention; series inventory via
`/api/v1/label/__name__/values`, ranges via `/api/v1/query_range`
Sep 10–22, step 15m/30m); `journalctl --user -u pi-intake@fleet-ops.service`
`held-in-buffer` count = 0 both sides of 2026-09-18T12:00Z.
