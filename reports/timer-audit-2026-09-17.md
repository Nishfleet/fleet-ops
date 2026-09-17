# Timer audit, 17 September 2026

No live timer was changed. The audit found no supported deletion candidate.
Follow-up work is queued in [#7511](https://github.com/Nishfleet/fleet-ops/issues/7511).

## Scope and proof

This is the one-off advisory sweep requested in #7461, under #7370.
Source commit `0b5c34270d97d0dafd46acf1989e4559c1d04d9a` contains 89 timer manifest records.
The snapshot adds four live-only records, for 93 unique records in total.
Templates, disabled entries and deprecated records are included, so 93 is not a count of running timers.

The complete gateway pass ran from 2026-09-17T17:09:40Z to 17:15:35Z using the existing `bin/jev-eval.mjs` SDK helper.
[The JSONL report](timer-audit-2026-09-17.jsonl) retains every state, question, probability, usage receipt and real-record reference.
On resume, all 93 hashes matched the committed states and all 93 references/hashes/answers matched the helper log.
The pass used 131,398 input tokens, estimated $0.005518716 at the helper's $0.042 per million input tokens.
The closeout call used 21,327 input tokens, estimated $0.000895734. The earlier partial pass also incurred cost; these two amounts are not the total task cost.
The helper's cumulative spend file showed $0.01193346 before closeout. No cap was raised; the helper enforces the $1 cap.

A prior 59-record pass is superseded and its duplicate summary removed. Eleven displayed event booleans differed across passes. These are advisory estimates, not calibrated deletion permissions.

## Reading the answers

The table displays `event_possible` and `delete` as booleans using probability greater than 0.5, alongside the unrounded probability. This is a report convention only, never an automated gate.
`event_possible=true` includes an existing event primary. It does not mean its timer backstop can be removed.
There are 24 event-positive rows and zero delete-positive rows. Maximum delete probability is 0.26.

Each JSONL state contains the manifest purpose, timer/service source where available, the live observation, and verified event channels.
Polling behavior is inferred from the purpose and service source, not a trace of every process or network request.
No external webhook is assumed merely because a job could in theory publish one.
A record absent from list-timers is not proof that its unit file is absent or obsolete.
Live-only rows cite the source commit and inventory namespace in their ref, but their unit evidence is the timestamped live observation, not a manifest entry.

## Event channels and disposition

- The existing GitHub receiver handles issue opened/labeled/closed and pull request closed events. Intake, lifecycle sweep, duplicate drain and merged-PR closure already use these signals. Keep the missed-event timers.
- `vault-conflict-resolver.path` already supplies the fast trigger. Its globs cover selected directories, not the whole nested tree. Keep the 10-minute recovery timer. The manifest's CONVERTING description is stale.
- `fleet-deploy-check.service` records that the old path trigger was removed after git ref replacement caused repeated events, per #2123. Its 2-minute timer is deliberate. Do not recreate that failed conversion from the manifest's stale description.
- `intake-reconcile.path` and the live `pi-transport-check.path` are existing file-change channels. A path event is not evidence of whole-job replacement or deletion safety.
- Web probes, missing-event checks, age-based cleanup, quota release and calendar reviews retain clock-based work. OnFailure repair services are already event-triggered; their pseudo-timer manifest rows need source reconciliation, not new timers.

## Follow-up and review

[#7511](https://github.com/Nishfleet/fleet-ops/issues/7511) owns the manifest corrections and inventory reconciliation. It cites the existing timer-manifest test and drift canary as prior art. No new checker, path unit, service or timer is proposed here.

Act on: queue the stale conversion descriptions and inventory mismatch. The live `tests/timer-manifest.test.sh` run during closeout failed because `0509-digest-headline-ratio-guard.timer` is missing from the manifest. All repo timer entries and shape checks passed before that failure.

Consider: deprecated fleet2 and repair pseudo-timer records need installed-file/OnFailure verification. Do not delete from snapshot absence alone.

Noted: the two OS cleanup timers are explicitly excluded by the existing test. The temporary quota timer is a one-shot snapshot record, not a new permanent schedule to adopt.

Dismissed with reason: converting the vault again duplicates an existing path unit; restoring the deploy path repeats a documented failure. Deleting recovery timers is not supported by this audit.

The closeout decision used these actual source comments and all 93 record summaries. Helper site `timer-audit-7461-closeout`, real ref `Nishfleet/fleet-ops#7461:9e160896bc134e462e32d4290c4a20d673eba844`, returned publish-report 0.89 and file-manifest-follow-up 0.91 at 2026-09-17T18:03:03Z. State hash `c074d80bdf16b3b4414320e89f359f37cf6873292a5d07a40babe75fa8d8ddb8`. I adopt those scoped recommendations, not automated timer changes.

Rollback: this is a static report, with no recurring invocation or enabled decision site to switch off. Stop the one-off call to stop evaluation; reverting the report has no effect on timers. No per-site runtime flag or new mechanism was added.

## Per-record answers

The purpose/poll column is the manifest reason, or the live service description for the four extra records. Full service text and event-channel context are in the corresponding JSONL state, keyed by unit and source ref. Stale manifest claims in this column are quoted evidence, not endorsed conclusions.

| Unit | Purpose / what it polls | event_possible | P(event) | delete | P(delete) |
| --- | --- | --- | ---: | --- | ---: |
| `0509-demo-brand-timeline-canary.timer` | Daily 06:10 IST 0509 demo-brand offer timeline public-surface canary (Nishfleet/0509#1899) — probes each demo brand's public /timeline page for a rendered dated ledger; deliberately a hand-placed user unit (like 0509-search-tier-canary, #1452) because the worker GitHub App token cannot write .github/workflows and the check needs no secrets, only outbound HTTPS to 0509.io; runs from a dedicated read-only checkout that self-syncs to main (machinery-allowlist class a, fleet-ops#4400) | false | 0.21 | false | 0.1 |
| `0509-digest-headline-ratio-guard.timer` | 0509 BET 1 digest headline-ratio regression guard | false | 0.29 | false | 0.09 |
| `0509-search-tier-canary.timer` | Daily 06:10 IST §1.8 six-domain /search tier regression canary for 0509 (Nishfleet/0509#1452) — true calendar job; the worker GitHub App token cannot write .github/workflows and the check needs no secrets, only outbound HTTPS to 0509.io (fleet-ops#3735) | false | 0.11 | false | 0.07 |
| `0509-sneaker-resale-recall-canary.timer` | Every 3h (03:00/3:00 IST) 0509 sneaker-resale seed-list recall guard (Nishfleet/0509#1945) — fails when any sneaker-resale seed-list brand with genuine Meta ad coverage returns 0 verified/likely rows on production /search; deliberately a hand-placed user unit (like 0509-demo-brand-timeline-canary, #1899) because the worker GitHub App token cannot write .github/workflows and the check needs no secrets, only outbound HTTPS to 0509.io; runs from a read-only checkout that self-syncs to main (fleet-ops#4647) | false | 0.22 | false | 0.09 |
| `agent-cron-0509-daily-market-signal.timer` | Daily 0509 market signal cron — true calendar job at 08:15 IST | false | 0.15 | false | 0.07 |
| `agent-scheduler-drift.timer` | Daily scheduler drift check — detects drift between declared and actual timer state; runs at 03:00 IST | false | 0.19 | false | 0.09 |
| `daily-digest.timer` | 9 AM IST daily digest push — live Pi-era data only (merged PRs, failed units, Prometheus alerts, seat health, disk %) | false | 0.34 | false | 0.08 |
| `escalation-daily-sweep.timer` | Daily dead-man floor for SENIOR-AUDITOR escalation layer — bounds max time-to-audit at 24h for failures with no dedicated tripwire | false | 0.21 | false | 0.06 |
| `escalation-drain.timer` | Hourly bounded-file maintainer for NISH-ESCALATIONS.md and alert-repair packet dir (fleet-ops#2677 + #2773) — accumulation is structural (every CAP-REACHED + every Alertmanager webhook appends), so hourly bounds the live file to roughly one cycle's worth of growth; daily-sweep is the dead-man floor if the drain dies | false | 0.22 | false | 0.08 |
| `escalation-organ-watch.timer` | 5-min organ-death watcher for the anti-recursion-excluded escalation organs (fleet-ops#5854) — those organs are excluded from their own STOP-REASON chain, so their death is otherwise silent until the next hourly tier1 failed-units sweep; this timer bounds detection to the 5-min contract | false | 0.15 | false | 0.06 |
| `evening-highlights-digest.timer` | 9 PM IST evening highlights digest push (vacation window through 2026-09-08) — second sanctioned digest slot, wins-only; silence if nothing worth saying | false | 0.24 | false | 0.1 |
| `fable-fleet-check-kimi.timer` | Hourly fleet judge on Kimi K3 (pi cursor/kimi-k3-max), offset :20 UTC (fleet-ops#4455 third POV) — main consumer of the Ultra 'Other Models' $400/month bucket; initial hourly cadence per Nish 2026-09-08 'use generously to use up the $400 before sub expires', adjusted from measured $/run. Repo-sourced. | false | 0.18 | false | 0.09 |
| `fable-fleet-check-opus.timer` | Hourly fleet judge on Opus 5, offset :40 UTC (second POV; Nish 2026-09-07) — unit adopted into the repo by fleet-ops#4906 (was hand-placed) | false | 0.3 | false | 0.1 |
| `fable-fleet-check.timer` | Hourly fleet judge (agent-cron-run senior ladder), offset :00 UTC — first of three non-overlapping POVs; unit adopted into the repo by fleet-ops#4906 (was hand-placed 2026-09-04) | false | 0.23 | false | 0.08 |
| `fleet-aeo-probe.timer` | Weekly AEO visibility probe — measurement window is weekly; must land before Weekly Fleet Review (Sun 04:30 IST) | false | 0.18 | false | 0.09 |
| `fleet-asset-census.timer` | Weekly VPS asset census — runs before Weekly Fleet Review so Pi review starts from enumerated, guarded surface | false | 0.23 | false | 0.07 |
| `fleet-bare-metal-rebuild-drill.timer` | Weekly bare-metal rebuild drill — manifest completeness invariant is not an event signal; weekly container proof catches drift | false | 0.14 | false | 0.07 |
| `fleet-baseline-delta.timer` | Weekly baseline-delta strangeness pre-pass (fleet-ops#1151) — unknown-unknown metric strangeness has no event to subscribe to; fires Sun 04:00 IST, 30 min before the 04:30 WFR whose input dir it writes (after quiesce 03:15 / vps-weekly-update 03:30) | false | 0.1 | false | 0.06 |
| `fleet-blind-audit.timer` | Daily blind audit floor — unknown unknowns have no event to subscribe to; daily calendar floor is the only correct primary trigger | false | 0.15 | false | 0.03 |
| `fleet-console-pi.timer` | Fleet Console (Pi) page refresh — GitHub PR/CI state drifts continuously; 12-min cadence keeps page current inside API budget. CONVERTING TO PATH UNIT | false | 0.38 | false | 0.08 |
| `fleet-deploy-check.timer` | Merge-to-live deploy check — TOP GEAR: merged-but-not-live latency bound. CONVERTING TO PATH UNIT on state file changes | true | 0.7 | false | 0.08 |
| `fleet-heartbeat.timer` | Orchestrator continuity across interactive-session restarts — event notifications die with sessions; this timer survives every session exit. fleet-ops#3270: cadence 15->60 min; the three GitHub-reading sections (lifecycle-label-sweep, merged-pr-close, close-duplicates) moved behind webhook triggers, so the heartbeat keeps only host-local sections (deploy, queue, reclaim, failed-unit recovery, RAM, seat-health, canaries) | true | 0.61 | false | 0.06 |
| `fleet-issue-close-duplicates.timer` | fleet-ops#3270: daily backstop for the duplicate-issue drain. Webhooks (issues/closed via gh-webhook-receiver) are the primary trigger; this timer catches webhooks that never arrive. A duplicate is waste but not breakage — the canonical issue still gets dispatched — so daily is proportionate | true | 0.85 | false | 0.05 |
| `fleet-litellm-health-canary.timer` | 60s LiteLLM proxy /health/readiness probe (fleet-ops#4130 P1) — the proxy is a daemon whose death must surface in <2 min, not on the 5-min metrics-export cadence. The 60s timer is the named reason (organ-death latency). | false | 0.15 | false | 0.05 |
| `fleet-merged-pr-close.timer` | fleet-ops#3270: hourly backstop for merged-pr observe-to-close. Webhooks (pull_request/closed via gh-webhook-receiver) are the primary trigger; this timer catches webhooks that never arrive. A forgotten Closes #<N> trailer is not urgent — the issue stays open and intake re-queues it — so hourly is proportionate | true | 0.87 | false | 0.05 |
| `fleet-metrics-export.timer` | Fleet Prometheus metrics export — 5-min cadence for metrics freshness; piggybacks git-mirror-update and waste-ledger. Metrics are an aggregate snapshot with no single upstream event; 5-min cadence is the scrape interval floor | false | 0.19 | false | 0.07 |
| `fleet-resilience-drill.timer` | Daily four-plane resilience drill — each plane's failure is silent without periodic proof; daily at 05:47 IST off heartbeat cluster | false | 0.21 | false | 0.07 |
| `fleet-restore-drill.timer` | 6h control-plane restore drill — rebuild story is a continuity invariant with no event signal; 6h catches stale backup within one waking window | false | 0.12 | false | 0.07 |
| `fleet-rulebook-redteam.timer` | Monthly rulebook red-team floor — heading-growth bonus fires via heartbeat; calendar floor catches a month the box was down | false | 0.2 | false | 0.05 |
| `fleet-seat-comeback-release.timer` | 15-min ACTIVE come-back release (fleet-ops#2421): a walled seat whose wall clock (bench_until ?? usable_at) has passed is re-probed with a 1-token reply-OK dispatch and a provably-usable seat is unwalled (healthy observation written to the ledger, priming fleet-seat-recovery). Loud stalled check: expired walls remain with zero releases -> exit 1 + fleet_seat_comeback_release_stalled=1 | false | 0.16 | false | 0.05 |
| `fleet-weekly-fleet-review.timer` | Weekly Fleet Review (WFR) — mandated weekly senior review per WBR/kaizen pattern; Sun 04:30 IST post-maintenance chain | false | 0.19 | false | 0.06 |
| `fleet-worktree-reaper.timer` | Daily orphan agent-worktree GC (fleet-ops#2227 + #2637 + #2774 + #3023) — Mode A: claim/issue-<N> + merged or closed PR. Mode B: issue-<short>-<N> PATH + dispatch-ledger terminal entry + HEAD on origin. Mode C: any worktree + HEAD on origin + 24h age gate. Mode D: dirty worktree stale >=14d is banked to wip/wfr-<name>-<ts> on origin via pi-salvage-worktree (secret-scan + quarantine), then the mode gates reap it — capped at 50 banks/run so the backlog drains across daily ticks. Every mode's full gate chain must pass (no live worker, work preserved on origin before removal). Fail-safe: dry-run capable, gh failure skips repo, missing ledger fails closed, unbanked salvage keeps the tree. 2026-09-11: cadence raised daily->every-6h (03:30/09:30/15:30/21:30) after DiskWillFillIn24h fired — worker churn outpaced a single daily drain. | true | 0.6 | false | 0.05 |
| `fleet2-digest.timer` | DEPRECATED: fleet2 legacy digest timer — to be removed per fleet-ops simplification | false | 0.39 | false | 0.12 |
| `fleet2-dispatch.timer` | DEPRECATED: fleet2 legacy dispatch timer — to be removed per fleet-ops simplification | false | 0.41 | false | 0.11 |
| `fleet2-events.timer` | DEPRECATED: fleet2 legacy events timer — to be removed per fleet-ops simplification | true | 0.58 | false | 0.1 |
| `gap-closure-drill-stub-mask.timer` | Throwaway yearly timer for gap-closure mask-detection drills — never enabled; the drill runtime-masks then unmasks it. Named so timer-manifest shape lock does not fail on the repo file. | false | 0.17 | false | 0.22 |
| `gh-webhook-canary.timer` | GitHub push-channel synthetic canary — every 5 min posts a synthetic issues/labeled/agent-ready event through the local receiver and bumps the last-green metric (fleet-ops#1464). | true | 0.62 | false | 0.07 |
| `grok-token-refresh.timer` | Headless OAuth refresh of SuperGrok xai-oauth seat — access token lifetime is 6h; 4h cadence keeps <local-path> fresh so an idle prepaid seat does not wake into a 401 (fleet-ops#41). | false | 0.14 | false | 0.06 |
| `intake-reconcile.timer` | 30-min backstop for intake reconciler — path unit handles synchronous file-change trips; this timer catches missed mtime bumps or masked path units | true | 0.6 | false | 0.05 |
| `interactive-session-reap.timer` | Hourly stale-interactive-session reaper — idle age is a clock fact, not an event; hourly is proportionate to measured 8h idle threshold | false | 0.16 | false | 0.08 |
| `launchpadlib-cache-clean.timer` | Clean up old files in the Launchpadlib cache | false | 0.21 | false | 0.13 |
| `lifecycle-label-sweep.timer` | fleet-ops#3270: hourly backstop for the lifecycle-label sweep. Webhooks (issues/opened + issues/labeled via gh-webhook-receiver) are the primary trigger; this timer catches webhooks that never arrive. The sweep is idempotent (only relabels unlabeled), so a webhook + timer double-fire dedupes naturally | true | 0.89 | false | 0.05 |
| `minimax-token-refresh.timer` | Headless MiniMax OAuth rotation check — the fleet-litellm-proxy organ captures MINIMAX_API_KEY once at startup but the underlying <local-path> access token rotates silently every ~12h inside claude-minimax-key. A stale key 401s every anthropic/MiniMax-M3 deployment in the senior / judge / worker-cheap / worker-capable / worker-private groups and pi exits 1 on the failure (killing flagship workers). 2h cadence gives ~6x margin over the 12h rotation; the script compares the wrapper's fresh key to the proxy's captured env var and bounces the proxy on mismatch. Mirrors grok-token-refresh structure (fleet-ops#41). fleet-ops#5788. | false | 0.18 | false | 0.05 |
| `nish-memory-curator.timer` | 5-min shared-memory curation — compiles verified Nish captures from vault; could be event-driven on vault changes but vault churn is high | false | 0.35 | false | 0.07 |
| `pi-escalation-audit.timer` | Hourly senior escalation panel intake — escalations are rare and network-bound; hourly floor keeps time-to-panel under an hour | false | 0.39 | false | 0.09 |
| `pi-intake-repair@.timer` | Template repair timer for pi-intake instances — instantiated per repo by intake-reconcile | true | 0.56 | false | 0.11 |
| `pi-intake-repair@0509-telemetry.timer` | Pi intake repair for 0509-telemetry — OnFailure trigger for pi-intake@0509-telemetry | false | 0.49 | false | 0.12 |
| `pi-intake-repair@TinyStudio.io-public.timer` | Pi intake repair for TinyStudio.io-public — OnFailure trigger for pi-intake@TinyStudio.io-public | true | 0.54 | false | 0.12 |
| `pi-intake-repair@TinyStudio.io.timer` | Pi intake repair for TinyStudio.io — OnFailure trigger for pi-intake@TinyStudio.io | false | 0.49 | false | 0.13 |
| `pi-intake-repair@aiconverter-app.timer` | Pi intake repair for aiconverter-app — OnFailure trigger for pi-intake@aiconverter-app | false | 0.47 | false | 0.13 |
| `pi-intake-repair@context-hub.timer` | Pi intake repair for context-hub — OnFailure trigger for pi-intake@context-hub | true | 0.51 | false | 0.13 |
| `pi-intake-repair@egress-probe.timer` | Pi intake repair for egress-probe — OnFailure trigger for pi-intake@egress-probe | false | 0.45 | false | 0.13 |
| `pi-intake-repair@inish-site.timer` | Pi intake repair for inish-site — OnFailure trigger for pi-intake@inish-site | false | 0.45 | false | 0.12 |
| `pi-intake-repair@tinystudio-in.timer` | Pi intake repair for tinystudio-in — OnFailure trigger for pi-intake@tinystudio-in | false | 0.49 | false | 0.12 |
| `pi-intake@.timer` | Template timer for pi-intake instances — instantiated per repo by intake-reconcile | true | 0.79 | false | 0.06 |
| `pi-intake@0509-telemetry.timer` | Pi issue intake for 0509-telemetry — instantiated by intake-reconcile from config/intake-repos.json | true | 0.8 | false | 0.05 |
| `pi-intake@0509.timer` | Pi issue intake for 0509 — 15-min schedule because GitHub has no push channel to VPS; also fires on seat-recovery transitions and issue-filed-by-heartbeat. CONVERTING TO EVENT-DRIVEN | true | 0.79 | false | 0.06 |
| `pi-intake@TinyStudio.io-public.timer` | Pi issue intake for TinyStudio.io-public — instantiated by intake-reconcile from config/intake-repos.json | true | 0.8 | false | 0.06 |
| `pi-intake@TinyStudio.io.timer` | Pi issue intake for TinyStudio.io — instantiated by intake-reconcile from config/intake-repos.json | true | 0.81 | false | 0.06 |
| `pi-intake@aiconverter-app.timer` | Pi issue intake for aiconverter-app — instantiated by intake-reconcile from config/intake-repos.json | true | 0.81 | false | 0.06 |
| `pi-intake@context-hub.timer` | Pi issue intake for context-hub — instantiated by intake-reconcile from config/intake-repos.json | true | 0.81 | false | 0.07 |
| `pi-intake@egress-probe.timer` | Pi issue intake for egress-probe — instantiated by intake-reconcile from config/intake-repos.json | true | 0.82 | false | 0.06 |
| `pi-intake@fleet-ops.timer` | Pi issue intake for fleet-ops — 15-min schedule because GitHub has no push channel to VPS; also fires on seat-recovery transitions and issue-filed-by-heartbeat. CONVERTING TO EVENT-DRIVEN | true | 0.82 | false | 0.06 |
| `pi-intake@inish-site.timer` | Pi issue intake for inish-site — instantiated by intake-reconcile from config/intake-repos.json | true | 0.81 | false | 0.06 |
| `pi-intake@tinystudio-in.timer` | Pi issue intake for tinystudio-in — instantiated by intake-reconcile from config/intake-repos.json | true | 0.79 | false | 0.07 |
| `pi-packet-logrotate.timer` | Size-based rotation of pi-packet watch.log — seat-selection lines accumulate on every pick and the log was 104 MB unrotated; 10-min cadence bounds growth and logrotate keeps 5 compressed back copies | false | 0.18 | false | 0.08 |
| `pi-scout-repair@.timer` | Template repair timer for pi-scout instances — instantiated per repo by intake-reconcile | false | 0.42 | false | 0.1 |
| `pi-scout-repair@0509-telemetry.timer` | Pi scout repair for 0509-telemetry — OnFailure trigger for pi-scout@0509-telemetry | false | 0.44 | false | 0.11 |
| `pi-scout-repair@TinyStudio.io-public.timer` | Pi scout repair for TinyStudio.io-public — OnFailure trigger for pi-scout@TinyStudio.io-public | false | 0.4 | false | 0.11 |
| `pi-scout-repair@TinyStudio.io.timer` | Pi scout repair for TinyStudio.io — OnFailure trigger for pi-scout@TinyStudio.io | false | 0.42 | false | 0.12 |
| `pi-scout-repair@aiconverter-app.timer` | Pi scout repair for aiconverter-app — OnFailure trigger for pi-scout@aiconverter-app | false | 0.33 | false | 0.09 |
| `pi-scout-repair@context-hub.timer` | Pi scout repair for context-hub — OnFailure trigger for pi-scout@context-hub | false | 0.46 | false | 0.1 |
| `pi-scout-repair@egress-probe.timer` | Pi scout repair for egress-probe — OnFailure trigger for pi-scout@egress-probe | false | 0.34 | false | 0.11 |
| `pi-scout-repair@inish-site.timer` | Pi scout repair for inish-site — OnFailure trigger for pi-scout@inish-site | false | 0.34 | false | 0.11 |
| `pi-scout-repair@tinystudio-in.timer` | Pi scout repair for tinystudio-in — OnFailure trigger for pi-scout@tinystudio-in | false | 0.45 | false | 0.11 |
| `pi-scout@.timer` | Template timer for pi-scout instances — instantiated per repo by intake-reconcile | false | 0.4 | false | 0.08 |
| `pi-scout@0509.timer` | Pi product scout for 0509 — 4h supply generation is inherently periodic; intake claiming stays event-gated | false | 0.38 | false | 0.05 |
| `pi-scout@fleet-ops.timer` | Pi product scout for fleet-ops — 4h supply generation is inherently periodic; intake claiming stays event-gated | false | 0.37 | false | 0.06 |
| `pi-transport-check.timer` | Pi transport integrity fallback heartbeat — 30-min backstop for .path unit that can miss replace-by-rename or be inactive across restarts | false | 0.38 | false | 0.07 |
| `quality-research-weekly.timer` | Weekly quality>speed>efficiency research sweep — outside world changes weekly; Sunday 03:00 IST off-peak delta sweep | false | 0.24 | false | 0.09 |
| `restart-fleet-ops-intake-after-quota.timer` | one-shot: restart pi-intake@fleet-ops.timer after the GitHub App quota resets (claude-vps 2026-09-17) | false | 0.31 | false | 0.08 |
| `siterep-deploy.timer` | DISABLED: siterep.net autonomous deploy drift tick — deliberately NOT installed per packet p51; kept for reference | false | 0.3 | false | 0.26 |
| `siterep-live-canary.timer` | Hourly siterep.net live canary (T3 deep tier) — chromium+firefox layout smoke + synthetic monitor; hourly per three-tier monitoring cadence | false | 0.2 | false | 0.07 |
| `siterep-pr-conflict-watchdog.timer` | PR conflict watchdog for siterep.net — detects merge conflicts on open PRs | false | 0.47 | false | 0.09 |
| `siterep-uptime.timer` | 2-min uptime probe for siterep.net (T1) — decisive HTTP 200 + TLS + title marker; Persistent=false so missed probes don't stack on boot | false | 0.12 | false | 0.08 |
| `systemd-tmpfiles-clean.timer` | Cleanup of User's Temporary Files and Directories | false | 0.3 | false | 0.1 |
| `tinystudio-live-site-check.timer` | Nightly live-site check for tinystudio.in — soft-404, headings, tap targets, social preview, promptly support | false | 0.23 | false | 0.09 |
| `vault-conflict-resolver.timer` | 10-min Syncthing conflict resolver — *.sync-conflict-* files freeze every vault writer; 10-min matches resolver's DISPATCH_COOLDOWN_SEC. CONVERTING TO PATH UNIT | true | 0.88 | false | 0.06 |
| `vault-knowledge-format.timer` | Daily vault knowledge-format lint — daily floor catches drift in 03 Knowledge shape before monthly red-team review | false | 0.18 | false | 0.07 |
| `vps-maintenance-deadman.timer` | Fail-safe resume if maintenance window never cleared pause flag — Tue 23:09 IST dead-man | false | 0.25 | false | 0.09 |
| `vps-maintenance-quiesce.timer` | Weekly maintenance quiesce (T-15) — stops NEW work only; Sun 03:15 IST before vps-weekly-update | false | 0.16 | false | 0.09 |
| `vps-post-reboot-verify.timer` | Re-verify agent stack ~30 min after expected reboot (fleet-ops#1160) — catches delayed tailscale recovery or failed unit recovery that the first vps-post-reboot-verify.service missed; Persistent=true so it survives a reboot during the maintenance window | false | 0.2 | false | 0.11 |
| `vps-weekly-update.timer` | Weekly VPS full-stack update — apt, npm globals, self-updaters, docker; Sun 03:30 IST after 15-min quiesce drain | false | 0.22 | false | 0.08 |
