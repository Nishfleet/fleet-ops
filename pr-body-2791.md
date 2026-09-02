## Why

`FleetQueueSelfMaintenanceRatioHigh` has fired since 2026-08-29T04:00:44Z
(4+ days) with the 7d-average ratio at 0.75-0.77, and the alert-repair chain
recorded `terminal=green` without moving the ratio. The issue asks for the
classification of what the fleet counts as self-maintenance, proof the
classifier is right, and a fix-the-classifier-or-cut-the-source decision.
This PR is the verified answer to that ask: a classification report with
live evidence and the decision record. It ships the report only — the
mechanisms that lower the ratio are already merged elsewhere (see Scope).

## Scope

- Adds `reports/self-maintenance-ratio-2791-2026-09-02.md` (docs only, no
  code or machinery).
- Classifies the live open `agent-ready` queue: 19 fleet-ops (self) + 10
  0509 + 1 inish-site = 30; merges trailing 24h = 45 self / 4 product
  (0.918).
- Proves the repo-based classifier (config/self-maintenance-repos.json)
  is honest, and documents its only error direction: the 10 0509 issues
  are fleet-ops CI wiring counted as product — the metric undercounts
  self, never overcounts, so no misclassification can falsely trip the
  alert.
- Fix-or-cut verdict: fix-classifier rejected (policy-anchored, wrong
  direction); cut-the-source is already merged (#2762 close-duplicates
  drain PR #2900, #2833 RESOLVED-receipt fix, #2726 auto-file cap),
  tracked (#2899 semantic seat-cluster, #2667 seat retirements), and the
  current binding constraint is the deploy block #2858 (dirty deploy-clone,
  `deploy_rc=1`) that keeps the merged drain from going live.

## Tradeoffs

No classifier change: any "fix" would raise the ratio (re-classifying the
10 0509 CI-wiring issues as self) and re-litigating the 2026-08-26
in-scope policy is a Nish call. No class-park change: the existing park
(`decision_class_until=2026-09-08T18:00:00Z`) already silences the
dispatch loop (actions.log SKIPs at 05:10Z/11:10Z/17:10Z), and its expiry
is the correct re-check guard.

## Blast Radius

Docs-only change; touches nothing that runs. The report cites live
evidence only (Prometheus values, exporter cache, gh issue states, a
dry-run of the merged drain). No unit, timer, workflow, or bin/ change —
none of the organ-heartbeat, research-before-build, or help-first gates
apply.

## Verification

- `curl 127.0.0.1:9090/api/v1/alerts` → `FleetQueueSelfMaintenanceRatioHigh`
  firing ×2, activeAt 2026-08-29T04:00:44.9Z.
- `curl 127.0.0.1:9090/api/v1/query` `avg_over_time(fleet_queue_self_maintenance_ratio[7d])`
  → agent-ready 0.7509, ready-work 0.7705 (both > 0.64).
- `grep fleet.prom` → queue ready-work 22/32 = 0.6875, agent-ready 22/33 =
  0.6667; merges 45 self / 49 total = 0.918 (exporter snapshot mtime
  2026-09-02T19:12:14Z).
- `gh search issues --label agent-ready` ×2 + `gh issue list` (REST
  cross-check) → fleet-ops 19, 0509 10, inish-site 1 (counts drift as
  auto-filers land).
- `python3 lib/issue-file.py close-duplicates --dry-run` (this worktree,
  includes PR #2900) → dry-run, zero GitHub writes: would close 7
  agent-ready duplicates (#2849→#1296, #2844→#2762, #2809→#2742,
  #1220/#1223/#1225/#1227→#1151), comment-only the protected member
  #2791→#2762. Matches the merged PR #2900's own quantification.

run-proof: transcript of the Prometheus + gh + dry-run commands is inline
in the report's "Live state" and "Live proof" sections; alert still firing
after the run (expected: 7d-avg lagging integrator, fleet-ops#2171).

mechanism-impossible: every lever that lowers the ratio is already merged
but not deployed (#2858 dirty deploy-clone), tracked (#2899), or
Nish-owned (#2667 seat corpses = money/credentials). Building a new
detector would duplicate the existing close-duplicates drain (PR #2900);
the alert's 7d-average window is a lagging integrator that cannot clear
in-turn even on a healthy queue.

Closes #2791