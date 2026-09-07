# Self-maintenance ratio stuck at 75% — classify, prove the classifier, fix-or-cut (fleet-ops#2791)

Report date: 2026-09-02
Issue: fleet-ops#2791 — "Self-maintenance ratio stuck at 75% for 4 days (FleetQueueSelfMaintenanceRatioHigh)"
Host: netcup-rs2000

## The reported snapshot (issue body, 2026-09-02)

- `FleetQueueSelfMaintenanceRatioHigh` firing continuously since
  2026-08-29T04:00:44Z with values 0.7465 and 0.7666.
- The alert-repair chain records `terminal=green` for this alertname with
  cycle 72691s (chain 2026-08-31T11:10:29Z → 2026-09-01T07:22:00Z in
  `chains.terminated.jsonl`) — the repair loop "closes" without moving the
  ratio.
- Ask: find what work is classified self-maintenance, prove the classifier
  is right, and either fix the classifier or cut the self-maintenance source.

## Live state (2026-09-02T19:1xZ, this worktree)

- Alert **still firing ×2**: `curl 127.0.0.1:9090/api/v1/alerts` shows
  `FleetQueueSelfMaintenanceRatioHigh` activeAt=2026-08-29T04:00:44Z on both
  queues — 4+ days, not resolved.
- 7d-average tripwire values (the alert input, `avg_over_time[7d]`):
  `agent-ready = 0.7509`, `ready-work = 0.7705` — both above the 0.64
  fleet2 death-number.
- Instantaneous queue ratios (exporter snapshot in `/var/lib/prometheus/
  node-exporter/fleet.prom`, mtime 2026-09-02T19:12:14Z):
  - `ready-work` = 22/32 = **0.6875**
  - `agent-ready` = 22/33 = **0.6667**
- Live gh cross-check (2026-09-02T19:1xZ): 19 fleet-ops + 10 0509 +
  1 inish-site = 30 open agent-ready issues. The counts drift minute-to-
  minute as auto-filers land; both the exporter and the live search agree
  the queue is dominated by fleet-ops.
- Merged PRs, trailing 24h (exporter `merged-prs-detail-cache.json`,
  age 27 min): **45 self / 4 product / 49 total = 0.918** — the fleet
  spent almost its entire daily merge budget on itself.

## What work is being classified self-maintenance

The classifier (`fleet-metrics-export.py` + `config/self-maintenance-
repos.json`) counts every open agent-ready issue and every merged PR whose
repo is in `["fleet-ops"]` as self. Fleet-ops is the control plane, so the
whole bucket IS fleet machinery. Classification of the live open
`agent-ready` queue (2026-09-02T19:1xZ):

| Repo | Count | Class | What it actually is |
|------|-------|-------|---------------------|
| Nishfleet/fleet-ops | 19 | self | 10 seat/SeatAvail corpse-credentials (corpse, credentials_bad, comeback) · 2 fleet-ops main-CI red (#2816 #2849) · 5 fleet machinery/hygiene (#2754 #2770 #2774 #2841 #2899) · 2 this alert's own re-filings (#2762 canonical, #2844) |
| Nishfleet/0509 | 10 | product (by repo) | **ALL 10 are fleet-ops CI wiring** — "add tests/X.test.sh to fleet-ops ci.yml P14 verify-command list" (#1157/1161/1188/1197/1205/1220/1223/1225/1226/1227). Self-maintenance filed in 0509 to dodge the worker token's `.github/workflows/**` push restriction. |
| Nishfleet/inish-site | 1 | product | genuine product deploy issue (#141) |
| **Total** | **30** | | |

Merges (24h): the 45 self merges are genuine fleet-ops repairs — seat-corpse
retirements and ledger fixes, canary fixes (auto-file cap #2726, RESOLVED-
receipt #2833, frozen-queue), escalation drain (#2677), deploy SLOs, CI
hosting. The 4 product merges are real 0509 work (landing-page, ads,
pricing, sneaker-resale).

## Prove the classifier is right

- The classifier is **repo membership**, PR-tunable via
  `config/self-maintenance-repos.json`, anchored to the policy decision
  (Nish 2026-08-26: control-plane work is in scope as an investment).
- Every open fleet-ops issue examined above is genuinely fleet machinery —
  seats, CI, canaries, escalation. None is product work mislabeled self.
- The classifier's **only** error direction is to UNDERCOUNT self: the 10
  0509 issues are fleet-ops-CI-wiring counted as product. An honest
  topic-based ratio would be ~(19+10)/(30) = 0.97, not the reported 0.63-0.69.
  No misclassification exists that makes the ratio read falsely HIGH.
- Verdict: the classifier is right; the metric is honest, even flattering.

## Fix the classifier or cut the source — decision

**Fix the classifier: rejected.** It is policy-anchored and its error
direction hides self-maintenance; a "fix" would raise the ratio, not lower
it, and re-litigating the 2026-08-26 in-scope decision is a Nish call, not a
worker call.

**Cut the source: the fleet already built it.** The generator of the queue
is auto-filed fleet-ops work (seat corpses, canaries, CI red, escalations).
The mechanisms that cut that flow:

- **#2762 close-duplicates drain — MERGED** (PR #2900, 2026-09-02T19:12Z):
  heartbeat block 21 closes token-overlap duplicate `agent-ready` issues. This
  issue (#2791) and #2844 are themselves that drain's target list
  (`#2791, #2844 → #2762`).
- **#2833 canary RESOLVED-receipt fix — MERGED** (PR #2893,
  2026-09-02T18:54Z): "RESOLVED receipt while alert still firing no longer
  closes green". The `terminal=green` repair-loop behavior this issue names
  (cycle 72691s) is precisely the pre-fix bug: a chain wrote RESOLVED on
  2026-09-01T07:22Z while the alert was still firing. Fixed in the same
  workstream.
- **#2726 age-based auto-file cap — MERGED**: bounds canary auto-file volume.
- **#2899 semantic seat-corpse clustering — OPEN**: the follow-up that drains
  the 11 seat/SeatAvail duplicates that score 0.37-0.57 (below the 0.65
  token-overlap threshold). This is the lever that takes the queue under 0.64.
- **Residual: seat corpses are Nish-owned** (money/credentials: re-auth or
  retire per #2667's plan). No worker change can clear them.

**Deploy blocker:** all three merged mechanisms are NOT live yet — the
production deploy-clone is on a feature branch with dirty tracked files
(`fix/gap-closure-drill-method`, uncommitted `config/seat-caps.json` +
`libexec/fleet-metrics-export.py`), so `fleet-deploy-check` reports
`deploy_rc=1` and the heartbeat still runs pre-#2900 code. This is already
tracked: **#2858** ("Live fleet-ops-deploy-clone is on main but
dirty/diverged, blocking merge-to-live") and #1635. The drain fires the
moment the deploy recovers. Until then the ratio cannot move mechanically.

## Live proof of the cut-the-source mechanism (drain dry-run)

From this worktree (contains PR #2900):

```
$ python3 lib/issue-file.py close-duplicates --dry-run
open_count: 356 … duplicate_clusters: 21 … capped: 10
  would close 7 agent-ready duplicates:
    Nishfleet/fleet-ops#2849 → #1296
    Nishfleet/fleet-ops#2844 → #2762
    Nishfleet/fleet-ops#2809 → #2742
    Nishfleet/0509#1220/#1223/#1225/#1227 → #1151
  would comment-only 1 protected member:
    Nishfleet/fleet-ops#2791 (this issue) → #2762
```

Dry-run performs zero GitHub writes (fail-closed gate
`FLEET_CLOSE_DUPLICATES_OK=1` is unset; protected members are commented by
reference, never closed). The close list matches the merged PR #2900's own
quantification.

Ratio effect, honestly computed: self-closes lower the ratio; product-closes
raise it. The drain closes 3 fleet-ops self + 4 0509 product dups, so its
net instant-ratio effect is roughly neutral-to-up. The ratio drops durably
only via **self** closes — i.e. #2899's semantic seat-cluster drain (11 self
dups → self 19→8, total 30→19 → ~0.42) plus the seat-corpse retirement
plan. The 7d-average alert will not clear for ~4-9 days after the queue goes
healthy regardless (lagging-integrator design, fleet-ops#2171).

## Close-or-collapse analysis

- #2791 is a token-overlap duplicate of #2762 (the drain's own list says so);
  #2844 is the same alert family. #2762 remains the canonical; #2844 closes
  via the drain; #2791 closes via this PR.
- The dispatch loop is currently silent: the class-park
  (`fleet-completion-canary/open/FleetQueueSelfMaintenanceRatioHigh.json`,
  `decision_class_until=2026-09-08T18:00:00Z`) is honored by
  `libexec/alert-repair-dispatch` — actions.log shows
  `SKIP ... reason=class-park until=2026-09-08T18:00:00Z` at 05:10Z /
  11:10Z / 17:10Z on 2026-09-02. No fresh LLM seat is being burned re-
  deriving the same conclusion each 6h repeat.
- The park expires 2026-09-08; if the queue is still above 0.64 then, a
  fresh dispatch re-derives the same verdict. That is correct guard behavior,
  not a defect.

## Mechanism / scope

Not a failure-fix per fleet-ops#366: the queue ratio is a symptom, not a
broken invariant. The tripwire fires correctly on a real signal (the fleet
is genuinely majority self-maintenance), and the response mechanisms are
already merged (#2762/#2833/#2726) and tracked (#2899, #2858).

`mechanism-impossible: an alert-repair worker cannot move the ratio this
turn — every lever that lowers it is already merged-but-not-deployed (#2858
deploy block), already tracked as an open issue (#2899), or Nish-owned
(money/credential seat corpses per #2667). Building a NEW detector here
would duplicate an existing organ; the fleet shipped the close-duplicates
drain (PR #2900) as the mechanism and it fires on the next deploy. The
alert's 7d-average window is a lagging integrator (fleet-ops#2171) that
cannot clear in-turn even when the queue is healthy.`

## Follow-ups (already tracked, not filed here)

- #2858 / #1635 — deploy-clone dirty; blocks the merged drain + canary fix
  from going live. This is the current binding constraint on the ratio.
- #2899 — semantic seat-corpse clustering: the durable ratio lever.
- #2667 — retire/re-auth the credentials_bad corpse seats (Nish-owned).