# Resilience blueprint for a single-VPS fleet

fleet-ops#455. Nish, 2026-08-26: redundancies upon redundancies, all
mechanical. The frame the pros actually use: untested redundancy is false
confidence, and blind duplication on a single box is theater.

This file is the adopted-delta list and the specs. The drill that proves
the planes is `bin/fleet-resilience-drill`.

Delta contract (#180 research-step): they do X, we do Y, adopting X means Z.

## Adopted deltas

### D1. Untested redundancy is not redundancy

they do X. Google SRE sizes N+1 / N+2 so a planned update and an unplanned
failure can overlap without dropping below the SLO
([Production environment](https://sre.google/sre-book/production-environment/),
[Service best practices](https://sre.google/sre-book/service-best-practices/)).
Error budgets decide when to freeze change vs ship
([Error budget policy](https://sre.google/workbook/error-budget-policy/)).
Reliability tests exist to quantify confidence, not to decorate a diagram
([Testing for reliability](https://sre.google/sre-book/testing-reliability/)).

we do Y. One box. systemd Restart/OnFailure, heartbeat repair, escalation
canary, blind audit, gap-closure loop, healthchecks.io dead-man on the
heartbeat. GitHub is the durable copy of code and config.

adopting X means Z. Do not buy a second box to mimic N+1. Treat every
function as: detected when it fails, auto-repaired or escalated, drilled
on a cycle, state recoverable with proof, plus exactly one out-of-band
layer per plane. A skipped drill is itself a LOUD finding.

### D2. Chaos is an experiment with a blast radius, not a random kill

they do X. Chaos Engineering injects real-world events against a defined
steady state, prefers production, automates the experiments, and
**minimizes blast radius**
([Principles of Chaos Engineering](https://principlesofchaos.org/),
[Netflix 2016](https://arxiv.org/abs/1702.05843)).

we do Y. Isolated stubs (oomd-drill.slice, gap-closure-drill stubs,
this repo's resilience-drill.slice). The 2026-08-26 oomd live kill is the
documented counterexample.

adopting X means Z. Drill Restart=always on a throwaway stub, not by
killing live heartbeat or live tailscaled from an automated worker.
Tailscale is the only SSH path; a remote kill of tailscaled is a lockout,
not an experiment. The live access drill is the written VNC break-glass
runbook plus a policy check (Restart=always applied, ssh not on 0.0.0.0:22).
A human-on-console tailscaled kill stays a Nish game-day.

### D3. Restore time is measured, not hoped

they do X. DORA's stability metrics are change fail rate and failed
deployment recovery time (the old "time to restore service", tightened in
2023 to recovery after a change)
([DORA metrics](https://dora.dev/guides/dora-metrics/),
[history](https://dora.dev/insights/dora-metrics-history/)).
A backup never restored is not a backup. Same lesson as fleet-ops#378
(never-run-audit).

we do Y. `fleet-restore-drill` (#388, 6h) proves the restic mechanism,
parseable control-plane files, and backup coverage. Deploy-clone rebuilds
code from origin.

adopting X means Z. Keep #388 as the state plane. This drill asserts that
timer is armed and last Result=success. Do not rebuild restic.

### D4. One out-of-band layer per plane, not a second copy of the plane

they do X. SRE puts monitoring and paging outside the failing system.
Chaos prefers production but contains fallout. DORA counts recovery, not
replica count.

we do Y. healthchecks.io already watches the heartbeat from outside the
box. GitHub-hosted runners already provide off-box compute for CI.

adopting X means Z. Extend the external dead-man to intake, scout,
intake-reconcile, and restore-drill with *separate* checks (sharing the
heartbeat URL would mask a dead heartbeat). Wire pings on success only.
Until the free-tier UUIDs land in `~/.config/fleet-ops/keystone-hc.env`,
the drill LOUDs `KEYSTONE-HC-UNCONFIGURED` as a SKIP (not a silent pass).
Document GitHub-hosted runners as the compute break-glass. Do not build a
second fleet.

## Rejected

- Second VPS / multi-region HA. Better redundancy money can buy. Zero
  revenue, zero spend. Fleet2 spent 64% of itself on self-maintenance.
  Waits for Nish + revenue.
- Second dispatcher. Banned.
- Kubernetes / ARC. Rejected 2026-08-2x.
- Redundant copies of stateless things. GitHub already is the copy.
- Killing live tailscaled or live heartbeat from this worker. Violates
  minimize-blast-radius. Stub + policy check + VNC runbook instead.
- Sharing the heartbeat healthchecks.io URL across keystones. Would keep
  the dead-man green while the heartbeat is dead.

## Spec: supervision

Keep the lattice: systemd Restart/OnFailure -> heartbeat repair ->
escalation canary -> blind audit -> gap-closure loop. healthchecks.io
dead-man on the heartbeat (already).

Add: `bin/keystone-hc-ping` plus drop-ins on intake, scout, reconcile,
restore. Separate `HC_URL_*` in `~/.config/fleet-ops/keystone-hc.env`.
Resurrection drill: isolated `Restart=always` stub, SIGKILL, new MainPID.

Detection: failed unit, dead-man miss, drill FAIL.
Repair: systemd Restart= + heartbeat repair pass.
Drill: `supervision_resurrection` in `fleet-resilience-drill`.

## Spec: state recovery

GitHub is the replica for code/config. Non-git state is restic + #388.

Detection: restore-drill FAIL / stale backup canary.
Repair: restic restore (system units; nish has no sudo on the repo creds,
so the drill observes Result= via `systemctl show`).
Drill: `state_restore` asserts the #388 timer is active.

## Spec: access plane

SSH is Tailscale-only. tailscaled down = locked out.

Add: system drop-in `Restart=always`, `RestartSec=5s`,
`StartLimitIntervalSec=0`. Applied by `sudo ./install.sh --system`. Does
not restart the running daemon.

Add: written VNC break-glass runbook (`docs/break-glass-access.md`).
No public SSH. The drill fails if `ss` shows `:22` on `0.0.0.0` or `[::]`.

Detection: tailscaled inactive, Restart != always, public SSH bind.
Repair: systemd brings tailscaled back; VNC is the out-of-band layer.
Drill: `access_policy` + `access_runbook`. Live tailscaled kill is a
Nish-on-console game-day, not this timer.

## Spec: compute plane

GitHub-hosted runners are already off-box compute for CI.

Add: document them as break-glass for a critical fix if the VPS is dead
(push from a laptop or from the runner itself). Do not add a self-hosted
runner on this box as the CI path.

Detection: a workflow pins `runs-on: self-hosted`.
Repair: revert that pin.
Drill: `compute_breakglass`.

## Spec: drill schedule

`fleet-resilience-drill.timer` daily at 05:47 (named reason above).
Persistent=true. Restart=no on the service; the timer is the retry.
Failed drill pages via the global OnFailure drop-in.

Results: `$AGENT_STATE/fleet-resilience-drill/last-run.json`. If
`GAP_LOOP_STATE_DIR` exists (#180), a copy lands there so the loop can
consume the snapshot without a new scheduler.

A SKIP (unconfigured keystone URLs, #375 chain not landed) writes a LOUD
triage line every run so it cannot silently drift.

## Break-glass: netcup VNC

See `docs/break-glass-access.md`. Out-of-band, exists today, zero cost.
This worker does not click VNC.

## Break-glass: GitHub-hosted runners

`.github/workflows/*.yml` use `runs-on: ubuntu-latest`. If the VPS is
dead, a fix still lands on GitHub: branch, PR, required checks, merge.
`#149` merge-to-live cannot run until the box is back; the durable copy
is origin, the restore drill is how the box is rebuilt.
