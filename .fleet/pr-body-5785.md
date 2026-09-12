## fleet-ops#5785 — deploy-fault close gate + FleetProductionStale flagship alert

Salvage of unit pi-issue-fleet-ops-5785 (prior worker reached StartLimitBurst; work was banked on wip/pi-issue-fleet-ops-5785-20260912T052747Z, rebased clean onto origin/main and verified — no work restarted from zero). Scope: smallest durable fix for both blind spots; no new unit or timer; reuse of alert-repair receiver, fleet_rules.yml, lifecycle-label-sweep; deploy-gate semantics untouched.

### What ships
1. Closing gate (accept 1) — `lib/deploy-fault-gate.sh` shared detector/proof lib:
   - `bin/fleet-merged-pr-close`: a deploy-fault issue (label or body citing a failed `Deploy production` run) may not close unless a green `Deploy production` run's head SHA contains the delivery merge. No proof → stays OPEN with a deduped marker comment naming the missing evidence; the same path closes it on the first tick after production goes green, with the run URL in the closing comment.
   - `bin/lifecycle-label-sweep`: same class gets a label-fixer pass (open issue citing a failed production run → `deploy-fault` label) and a closed-issue REOPEN pass that reopens any deploy-fault issue closed without proof — replay of 0509#2662/#2949 reopens it (tested).
2. Detector (accept 2): `FleetProductionStale` in `config/fleet_rules.yml` — critical, `repair_seat=flagship`, fires when a product repo's last green production deploy is >2h old while main carries a newer merge (`fleet_product_production_stale_hours > 2` + `fleet_product_undeployed_merges == 1`), with failing-step and evidence JSON annotations. Dispatch rides the existing `alert-repair-dispatch` receiver via the flagship ladder (`senior_seats_in_order` first, loud degradation to the normal pick). Halts are not the escalation path (tripwire without repair_seat for the audit alert below; no-op on halts).
3. Metric: `fleet_deploy_fault_closed_without_green` gauge + a `must-stay-0` audit alert; `fleet_product_production_stale_hours` gauge per the issue metric, exported by `libexec/fleet-metrics-export.py` on the existing 5-min tick, gauges derived in `lib/fleet-deploy-quality.py`. No new unit or timer.
4. Documented in `prompts/heartbeat.md` (Step-1 sweep prose) and the rule annotations in `fleet_rules.yml` (accept 4). MANIFEST entry for the new lib.
5. `Any OTHER` close paths: GitHub auto-close on a merged trailer is swept by the reopen pass; `stateReason=NOT_PLANNED` (deliberate non-fix) is left alone, tested.

### Verification:
- `bash tests/fleet-deploy-fault-gate.test.sh` → rc=0: REPLAY 0509#2662/#2949 reopens the closed deploy-fault issue + labels it; green run containing the delivery merge → close stands with run URL; green run NOT containing the fix → reopened; NOT_PLANNED untouched; close gate holds open while production red, closes on green.
- `bash tests/fleet-production-stale-alert.test.sh` → rc=0 (promtool): FleetProductionStale fires on the recorded 2026-09-12 state (54.3h stale + undeployed merges), silent on the post-green state and on merge-free staleness; tripwire fires on nonzero.
- `bash tests/alert-repair-flagship-seat.test.sh` → rc=0: flagship packet routed to first usable senior seat, not the cheap healthy pick; degrades loudly when no senior seat usable; claim mutex skips duplicates.
- `bash tests/fleet-metrics-export.test.sh` → rc=0; `bash tests/fleet-product-deploy-0509.test.sh` → rc=0.
- Existing consumers unaffected: `bash tests/fleet-merged-pr-close.test.sh tests/lifecycle-label-sweep.test.sh tests/lifecycle-label-sweep-admission.test.sh tests/fleet-heartbeat-low-water-mark.test.sh tests/role-quality-gates.test.sh tests/silent-drop-canary.test.sh` → all rc=0.
- Live drill (accept 3): fake FleetProductionStale flagship alert driven through the REAL `libexec/alert-repair-dispatch` with spawn suppressed in the drill — it picked `devin/glm-5-2 reason=flagship` and rendered packet `packet-FleetProductionStale-20260912T054454Z.md` (unit `alert-repair-FleetProductionStale-20260912T054454Z`); clearing shows via the promtool pass that the rule stays silent once a green run exists (no packet rendered again).
- `bin/sgscan --base origin/main` → "No new security findings."

### run-proof:
- Proof script run by this worker: `bin/prove-one-run-check` receipt below (see PR checks). Units exercised: the hermetic test suite + one alert-repair-dispatch drill call (drill-only, NO_SPAWN).

net-positive-because: the acceptance bullets themselves demand the replay/fire tests — 5 new hermetic test files (+971 of the +1582 lines) prove the close gate, the reopen sweep, the flagship seat ladder and the promtool rule; ~35 reusable lines are the shared lib wired into two existing sweeps instead of new units.

### run-receipt:
- verified 2026-09-12 against branch claim/issue-5785 (rebased on origin/main 238d81765).

### mechanism matters:
- Gate is mechanical: `deploy_fault_has_proof` resolves the green production run's head SHA vs the delivery merge; unresolvable SHA = unverifiable = no close (fail-closed). Reopen pass re-derives proof from Issues API only — no human.

Mechanical-fix note (fleet-ops#366): detector (FleetProductionStale), gates (close gate + reopen sweep), tests (5 files), observe-to-close (must-stay-0 gauge + tripwire alert), docs (fleet_rules.yml annotations + heartbeat prose) shipped. mechanism-impossible: the drill did not drive a real live AlertmanagerX firing loop against prod Prometheus — writing a fake alert into the live AMX would noisily page the flagship seat for the drill itself; the drill ran the real dispatch path with suppression instead, and the live rule itself fires on the production tick without any further wiring.

loose-ends: the 0509 production fault itself is still live — Gate C `proof_email_dispatch_invalid` needs a flagship repair; that is out of this issue's scope (the alert this PR ships will dispatch it automatically, or file follow-ups under Nishfleet/0509).

Closes #5785
