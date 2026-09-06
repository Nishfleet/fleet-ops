# Organ catalog — reuse before you build

Source: fleet-ops#1480 machinery audit (2026-08-28). One always-loadable file
mapping **job classes** to their **existing owner** (unit / issue / mechanism),
so reuse is cheaper than building. The no-new-machinery ban (decisions-ledger
2026-08-26) forbids hand-rolled dispatchers, retry loops, cooldown timers,
pollers, queue daemons, and watchdog scripts. Before building any of those, find
the row that already does the job. If no row fits, write a design proposal
through the senior-conference channel — do not build by fiat.

Industry pattern: Spotify Backstage catalog / Netflix paved road — reuse must be
cheaper than building, because prose bans lose to urgency at decision time.

## How to use

1. Name the job class you are about to build.
2. Find it in the table below.
3. Use the existing owner. If the existing owner is broken, **fix it** (repairs
   are ungated), do not build a parallel one.
4. If no row fits, open a design proposal — the conference adjudicates
   (MECHANICAL-INSTEAD / EXCEPTION-APPROVED / NISH-RESERVED).

## Catalog

| Job class | Existing owner | Unit / mechanism | Ref |
|---|---|---|---|
| Fleet heartbeat / liveness (host-local) | fleet-heartbeat | `fleet-heartbeat.timer` | #468, #3270 |
| Lifecycle-label sweep (webhook) | lifecycle-label-sweep | `lifecycle-label-sweep.{service,timer}` | #3270 |
| Merged-PR observe-to-close (webhook) | fleet-merged-pr-close | `fleet-merged-pr-close.{service,timer}` | #3270 |
| Duplicate-issue drain (webhook) | fleet-issue-close-duplicates | `fleet-issue-close-duplicates.{service,timer}` | #3270 |
| Loose-ends canary (webhook) | fleet-loose-ends-canary | `fleet-loose-ends-canary.{service,timer}` | #3270 |
| Tight merge→live deploy | fleet-deploy-check | `fleet-deploy-check.timer` | #468, TOP GEAR |
| Blind audit / gap-closure | fleet-blind-audit | `fleet-blind-audit.timer` | #377 |
| Resilience drill | fleet-resilience-drill | `fleet-resilience-drill.timer` | #1010 |
| Restore drill | fleet-restore-drill | `fleet-restore-drill.timer` | #1135 |
| Bare-metal rebuild drill | fleet-bare-metal-rebuild-drill | `…-drill.timer` | docs/bare-metal-rebuild.md |
| OOM drill hog | oomd-drill-hog | `oomd-drill-hog.service` | #1010 |
| Weekly review / watches | fleet-weekly-fleet-review | `fleet-weekly-fleet-review.timer` | #1146 |
| Asset census | fleet-asset-census | `fleet-asset-census.timer` | #1149 |
| Baseline-delta | fleet-baseline-delta | `fleet-baseline-delta.timer` | #1151 |
| GEO/AEO probe | fleet-aeo-probe | `fleet-aeo-probe.timer` | #1245 |
| Console tile truth | fleet-console-pi | `fleet-console-pi.timer` | #1157 |
| Seat recovery | fleet-seat-recovery | `fleet-seat-recovery.{path,service}` | seat governor |
| Metrics export | fleet-metrics-export | `fleet-metrics-export.timer` | organ: metrics-export |
| Completion canary | fleet-completion-canary | `fleet-completion-canary.timer` | organ: completion-canary |
| Scout canary | pi-scout@ | `pi-scout@.timer` | organ: scout |
| Intake (per repo) | pi-intake@ | `pi-intake@<repo>.timer` | intake-repos.json |
| Intake repair | pi-intake-repair@ | `pi-intake-repair@<repo>.timer` | stock Pi |
| Issue dispatch | pi-issue@ | `pi-issue@.service` | stock Pi |
| Packet dispatch | pi-packet@ | `pi-packet@.service` | stock Pi |
| Escalation daily sweep | escalation-daily-sweep | `escalation-daily-sweep.timer` | escalation rail |
| Escalation audit | pi-escalation-audit | `pi-escalation-audit.timer` | escalation rail |
| Stop-escalation | stop-escalation | `stop-escalation.{path,service}` | escalation rail |
| Unit escalation | unit-escalation@ | `unit-escalation@.service` | escalation rail |
| Intake reconcile | intake-reconcile | `intake-reconcile.{path,timer}` | #32 |
| Interactive session reap | interactive-session-reap | `interactive-session-reap.timer` | dead-seat EXTLOAD |
| Vault conflict resolve | vault-conflict-resolver | `vault-conflict-resolver.timer` | vault sync guard |
| Vault knowledge format | vault-knowledge-format | `vault-knowledge-format.timer` | vault format |
| Standing-rules render | standing-rules-render | `standing-rules-render.{path,service}` | vault |
| Siterep deploy / verify / rollback | siterep-deploy* | `siterep-deploy*` | siterep rail |
| Siterep live canary | siterep-live-canary | `siterep-live-canary.timer` | canary |
| Siterep uptime | siterep-uptime | `siterep-uptime.timer` | uptime rail |
| Quality research (weekly) | quality-research-weekly | `quality-research-weekly.timer` | #457 |
| Opus duty-officer watch | opus-heartbeat(+ -thorough) | `opus-heartbeat*.timer` | Nish-ordered |
| Boundary-notify (Nish-reserved) | nish-boundary-notify | `nish-boundary-notify.service` | standing rule |
| Memory curator | nish-memory-curator | `nish-memory-curator.timer` | memory compound |
| VPS maintenance (quiesce/deadman/update) | vps-maintenance-* / vps-weekly-update | `vps-maintenance-*.timer` | systemd-by-default |
| Orphan reap (all-agents) | agent-governor-orphan-watchdog | `agent-governor-orphan-watchdog.timer` | known-mandatory |
| Alert→repair bridge | prometheus-am-executor | `prometheus-am-executor.service` | alert pipeline |
| Transport integrity | pi-transport-check | `pi-transport-check.timer` | Pi transport |
| Daily digest | daily-digest | `daily-digest.timer` | Pi-era data |
| Evening highlights digest | evening-highlights-digest | `evening-highlights-digest.timer` | fleet-ops#1384 (vacation window) |
| Product nightly site check | tinystudio-live-site-check | `tinystudio-live-site-check.timer` | product-ops |
| Product cron | agent-cron-0509-* | `agent-cron-0509-*.timer` | product cron |
| pi-packet log rotation | pi-packet-logrotate | `pi-packet-logrotate.timer` | #3272 |

## Job classes with NO existing organ — do not build, propose

These banned classes have no sanctioned organ because the standing rule is to
use a primitive, not a script:

| Job class | Use instead |
|---|---|
| Retry loop / cooldown | systemd `Restart=` / `WatchdogSec=` / `StartLimitBurst` |
| Backoff | systemd `RestartSec=` + `StartLimitInterval` |
| Poller for work | event-driven: `.path` unit, `fleet-deploy-check` rev-compare, or a timer with a named reason |
| Queue daemon | Pi stock `subagent` extension (`/implement`, `/scout-and-plan`) or systemd `pi-systemd-run` |
| Watchdog for a thing Nish wants watched | the Weekly Fleet Review + blind audit carry the watch lens; file an issue, do not script a watcher |
| Hand-rolled dispatcher | Pi stock dispatch (`pi-issue@`, `pi-packet@`, `pi-scout@`) — extend intake-repos.json, do not write a new dispatcher |

If you reach for a row in this second table, stop and open a design proposal.
The conference adjudicates; most close autonomously with a recorded rationale;
only Nish-reserved verdicts reach Nish.
