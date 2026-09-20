# Observe-close for #5272 — FleetSloSeatAvailSlowBurn terminus: the alert, its metric, its dispatcher, its park/close machinery and its accept gate were all retired in the 2026-09-18/19 glue sweep

fleet-ops#5272 (auto-filed 2026-09-11 by the alert-repair dispatcher) was the
terminus for `FleetSloSeatAvailSlowBurn` — the seat-availability SLO
(`fleet_slo_compliance{slo="seat_availability"}` vs a 0.90 target) that had
been burning since 2026-09-08. The issue's job was to hold a live claim while
the alert fired, run a repair rung per dispatch tick, and let the
fleet-ops#5299 observe-to-close pass close it on `AMX_STATUS=resolved`. Its
accept bullet ran `python3 lib/agent-ready-spec-gate.py check-body`; its
termination bullet named the observe-to-close pass.

By the time this claim ran, the entire organ this issue tracks had been
deliberately retired on main — the alert rule, the metric family, the
exporter, the dispatcher shim, the spec gate, and the observe-to-close pass
are all gone. No code change remains; this report is the resolution record,
matching the established observe-close pattern (the #6665 record, PR #7972;
the #6799 record, PR #7968).

## What was found

1. **The alert rule is deleted, on main and deployed.** `f65e812c4`
   ("cut(exporter): 67 alert rules -> 14, all on stock-exporter metrics",
   2026-09-18 18:20 UTC, ancestor of origin/main) removed
   `FleetSloSeatAvailSlowBurn` from `config/fleet_rules.yml`. The installed
   `/etc/prometheus/fleet_rules.yml` now holds 17 `alert:` entries; none is
   SeatAvail/SLO-shaped. Survivors are all on stock exporters
   (`litellm_*`, `node_*`, `up{}`, textfile proofs).

2. **The metric source is deleted.** The same `f65e812c4` deleted
   `libexec/fleet-metrics-export.py` (4,679 lines, ~90 `fleet_*` families)
   and `tests/fleet-metrics-export.test.sh`. Live `fleet.prom`
   (mtime 2026-09-20T20:10Z) now carries only the probe families
   (`fleet_main_ci_*`, `fleet_prepaid_*`, `ci_*`). Instant queries at
   2026-09-20T20:1xZ: `fleet_slo_compliance` → 0 series; `fleet_seat_healthy`
   → 0 series. The SLO numerator/denominator cannot be computed — the alert
   could not fire even if the rule still existed.

3. **The alert stopped evaluating the moment the rule was deleted.**
   `query_range` on `ALERTS{alertname="FleetSloSeatAvailSlowBurn"}` over
   2026-09-18..21 shows `firing` samples ending 2026-09-18 ~18:00 UTC — the
   rule's last evaluation before `f65e812c4` deployed at 18:20 UTC.
   `/api/v1/alerts` and the Alertmanager v2 API at 2026-09-20T20:1xZ each
   list exactly 3 active alerts (`FleetMainRed`, `FleetNishPageRailDown`,
   `Watchdog`); the slowburn is permanently absent, i.e. the burn the
   terminus exists to track has terminated — by organ retirement, not by
   seat recovery.

4. **Every mechanism the issue body names is retired.**
   `libexec/alert-repair-dispatch` was deleted by `10b470a83`
   ("refactor(alerts): am-executor runs pi --print with the alert JSON on
   stdin"). `lib/agent-ready-spec-gate.py` — the accept bullet's command —
   was deleted by `4d7ab9f28` ("cut(gates-evaluators): delete 21 of the 31
   process gates"); the accept criterion is unverifiable as written because
   the script no longer exists. `lib/` on main holds only `__pycache__/`
   (sweeps `6fee069b6`, `6cafdd431`, `a437f7be6` took the rest). The
   observe-to-close pass named in the termination clause was retired in the
   same cuts (per the #6665 record: "the observe-to-close sweep was
   retired", fleet-ops#7828).

5. **The repair-rung work the issue tracked already landed — and was
   itself retired.** Linked repairs `#5281` (prefer-class empty-bucket
   phantom seat, merged #5311/#5302) and `#5274` (dead free-tier roster
   entries, config merged #5282, 404-corpse classifier #5304) closed the
   worker-repairable share. PR #5322 (merged 2026-09-11T06:20Z, head
   `claim/issue-5272`) added the `termination:` clause so the fleet-ops#4540
   park gate could engage; PR #5299 built the observe-to-close pass. The
   residual deficit at last firing was `quota_exhausted` prepaid seats on
   operator-owned billing walls — never worker-repairable, and the alert's
   own description forbade paging Nish.

6. **Seat availability is not unguarded post-retirement.** The cut moved
   seat health to the seat proxy's own instrumentation: LiteLLM's
   prometheus callback exports `litellm_deployment_state`, cooldowns and
   fallbacks; `FleetLitellmProxyAbsent` (`up{job="litellm"}`) and
   `RepairDispatchDown` (`up{job="am-executor"}`) survive in the 14-rule
   set; intake capacity is governed by measured `max_parallel_requests`
   over healthy rungs (fleet-ops#7820).

7. **How this run was claimed.** The fleet-ops#4540 park gate set
   `awaiting-runtime-gate` and removed `agent-ready` at 2026-09-11T08:40Z
   after four re-claims. `agent-ready` was re-applied at
   2026-09-20T17:47:05Z — actor `nish3451` with no `lifecycle-label:`
   heartbeat comment, i.e. an owner re-arm, not the fleet-ops#376 labeler
   (which comments when it labels). Intake then claimed it at
   2026-09-20T20:08:41Z per its own rules (`agent-ready` present,
   `critical-path` ordered first). Five claims total for a terminus whose
   subject no longer exists.

8. **The salvage commit was evaluated and deliberately not picked.**
   `b76c52868` ("salvage: bank uncommitted work for unit
   pi-issue-fleet-ops-5272", 2026-09-11) carries an
   `_enrolled_seat_providers` fix to `libexec/fleet-metrics-export.py` plus
   its test — both files deleted by `f65e812c4`. Cherry-picking it would
   resurrect a retired organ; the fix is moot.

9. **`fleet-metrics-export`'s systemd units survive on purpose — not
   residue.** `systemd/fleet-metrics-export.{service,timer}` were
   repurposed in the sweep to run `libexec/fleet-metrics-probe.sh`, which
   writes the three vendor-API facts with no stock exporter
   (`fleet_main_ci_green`, `fleet_product_up`, `fleet_prepaid_credits_usd`)
   to the textfile. Live: timer armed (`*:0/5`), service finishing exit 0
   every 5 minutes, `fleet.prom` fresh at 20:10Z.

10. **Close path.** The issue is protected (`critical-path`,
    owner-authored), so observe-to-close was always comment-only here — and
    that organ is gone anyway. The close runs through this PR's
    `Closes #5272` trailer via the merged-PR path — the same path the
    post-sweep fleet uses for retired-organ termini (fleet-ops#7828; the
    #6665 record).

## Verification

- `git merge-base --is-ancestor f65e812c4 origin/main` → yes;
  `git log --diff-filter=D` on main attributes the deletions:
  `config/fleet_rules.yml` rule + `libexec/fleet-metrics-export.py` +
  `tests/fleet-metrics-export.test.sh` → `f65e812c4`;
  `lib/agent-ready-spec-gate.py` → `4d7ab9f28`;
  `libexec/alert-repair-dispatch` → `10b470a83`. All ancestors of
  origin/main `94444b04d`.
- Live Prometheus on netcup-rs2000, 2026-09-20 ~20:1x UTC:
  `GET /api/v1/alerts` → `FleetMainRed`, `FleetNishPageRailDown`,
  `Watchdog` only; `fleet_slo_compliance` / `fleet_seat_healthy` → empty
  vectors; `ALERTS{alertname="FleetSloSeatAvailSlowBurn"}` range
  2026-09-18..21 → firing samples end 2026-09-18 ~18:00 UTC.
  `GET 127.0.0.1:9093/api/v2/alerts` → same 3 active, none SeatAvail.
- `grep -n 'alert:' /etc/prometheus/fleet_rules.yml` → 17 entries, no
  SeatAvail/SLO rule; `ls lib/` on main → `__pycache__` only.
- Issue timeline (`gh api .../issues/5272/timeline`):
  `awaiting-runtime-gate` labeled 2026-09-11T08:40:31Z; `agent-ready`
  re-labeled 2026-09-20T17:47:05Z actor=`nish3451`; `agent-in-progress`
  2026-09-20T20:08:41Z actor=`nish3451`.
- `git show b76c52868 --stat` → touches only
  `libexec/fleet-metrics-export.py` and `tests/fleet-metrics-export.test.sh`
  (both deleted on main); salvage not cherry-picked.
- `systemctl --user list-timers` → `fleet-metrics-export.timer` armed;
  `journalctl --user -u fleet-metrics-export.service --since 2026-09-19` →
  clean exit-0 `Finished` records every ~5 min; `fleet.prom` mtime
  2026-09-20T20:10Z.
- `systemctl --user list-units --state=failed` → one unrelated entry
  (`cursor-issue@fleet-ops-4626.service`, another lane's worker; its
  claim-release unit owns the reap). No failed unit from this organ.

run-proof: probes ran live on netcup-rs2000 2026-09-20 ~20:1x UTC against
origin/main `94444b04d`; commit ancestry via `git merge-base --is-ancestor`;
alert state via Prometheus `/api/v1/alerts` + `query_range` and Alertmanager
`/api/v2/alerts`; unit/timer state via `systemctl --user` /
`journalctl --user`; docs-only record — no unit, timer, workflow or script
path touched.

loose-ends: none — docs-only resolution record for a terminus whose organ
was deliberately retired on main; nothing half-done.
