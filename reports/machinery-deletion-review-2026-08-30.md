# Machinery deletion review — every organ re-earns its place, or gets a deletion proposal

Review owner: fleet-ops#1531 (Weekly Fleet Review quality-ratchet lens)
Date: 2026-08-30
Evidence window: **2026-08-16 → 2026-08-30** (trailing 14 days)
Seed: the machinery audit table `reports/machinery-audit-2026-08-28.md` (fleet-ops#1480, PR #1502)
Host: **netcup-rs2000**

## What this review is

Nish (2026-08-28): "concerned we are creating debt more than we might be able
to handle." The standing answer is the no-new-machinery ban + deletion-first.
This review scores every live organ in the audit inventory on three axes and
moves the ones that score no-harm / no-fires / overlapping into the queue as
deletion proposals. Keeping is what needs justification; deleting is free.

A byte of history first: the 2026-08-28 audit's class-(c) sweep was already
adjudicated by the senior-conference trail **before** this review ran:
- #1492 `auditor-stdio-test` — MECHANICAL-INSTEAD (deleted)
- #1493 `ready-work` — MECHANICAL-INSTEAD (deleted; routes through `pi-packet@`)
- #1494 `open-question-sweep` — adjudicated; unit gone from the live host
- #1496 `siterep-pr-conflict-watchdog` — MECHANICAL-INSTEAD (deleted; GH Actions owns it)
- #1497 `quality-baseline-research` — MECHANICAL-INSTEAD (deleted; quality-research-weekly owns it)
- #1498 `memory-index-autocompact` — EXCEPTION-APPROVED (migrated to repo)
- #1573 `agent-scheduler-drift` gap-audit — resolved (migrated into `systemd/`, endorsed rule `sr-agent-agnostic`)

So this review inherits a mostly-justified inventory and re-tests **every**
remaining organ rather than re-litigating the already-clean class-(c) rows.

## Scoring axes

1. **What breaks if deleted** — absent() heartbeat rule in `config/fleet_rules.yml`
   (an organ without one is an invisible-death organ, fleet-ops#1010), registry row in
   `config/fleet-organs.json`, rule-enforcement row, scripts/prompts that consume its output.
2. **Events fired in the trailing 14 days that led to real work** — `journalctl --user`
   per unit since 2026-08-16 (fires, produced-work evidence), host `fleet.prom` metric
   liveness, git history (add-commits), live `systemctl list-timers`.
3. **Overlap with another organ or a stock systemd/Pi primitive** — cross-rows below.

Verdicts: **KEEP** (justification line) · **EXEMPT** (safety organ; still
justified) · **PROPOSE-DELETE** (filed through the queue) · **NEW** (first fire
pending; first-fire evidence due) · **DORMANT** (paused by declared intake
decision) · **OUT-OF-SCOPE** (stock OS / dev-infra tool).

Evidence honesty: a 14-days "no fires → real work" verdict means the journal
for that unit shows no produced-work line in the window. A unit whose inner run
failed (rc≠0 tolerated) gets a broken-run flag, not a free pass — those are
filed as fix findings (below), because a broken sanctioned organ is a repair
owner, not a corpse.

## Scored table

### EXEMPT — safety organs (with justification lines)

| Organ | Fires 14d → real work | Breaks if deleted | Overlap | Verdict |
|---|---|---|---|---|
| vps-maintenance-deadman | Fired weekly + 1 Telegram send 08-25 (maintenance-pause fail-safe resume) | Loses the fail-safe resume if a maintenance window never clears the pause flag | — | EXEMPT (deadman class; standing rule: maintenance without deadman is not allowed) |
| gh-webhook-canary-deadman | Fires every 4 min, silent (silence = channel healthy) | Webhook-channel death goes unnoticed | gh-webhook-canary is its live twin | EXEMPT (deadman class, fleet-ops#1464) |
| agent-governor-orphan-watchdog | Fires every ~5 min; `marked_orphans=0 action=cleaned survivors=0` every run in window | Orphaned agent descendants leak when supervisors die | interactive-session-reap (sessions) vs orphan janitor (descendants) — complementary | EXEMPT (orphan-watchdog class; issue-body known-mandatory) |
| vps-maintenance-quiesce | Fired weekly (T-15 quiesce; stops NEW work before update) | Update/reboot runs with live agents mid-write | vps-weekly-update (sibling of the maintenance window) | EXEMPT (maintenance-window class) |
| vps-weekly-update | **Proven main-bus event**: completed full stack update + `systemctl reboot` 2026-08-30 03:32 (uptime 16:19 confirms the reboot) | Weekly patch/update + reboot rail gone | — | EXEMPT (maintenance window; ledger TOP GEAR) |

### Registered organs (config/fleet-organs.json — each has a live absent() rule; deleting one silently fires the rule and the alert-repair chain rebuilds it)

| Organ | Fires 14d → real work | Overlap | Verdict |
|---|---|---|---|
| metrics-export | Writes `fleet.prom` continuously; same invocation ran `git-mirror-update` and quarantined the corrupt 0509 mirror 08-30 19:40 | Everything heartbeat/absent() depends on it | KEEP — the meter rail; deleting blinds every other organ's death detection |
| completion-canary | LOUD `ISSUE-CLOSE-NO-EVIDENCE` (86 issues in 24h), wrote `fleet-chains.prom`, chain ledger per tick | — | KEEP — failure-chain termination proof |
| undersaturation-guard | `fleet_pi_workers_active` live; alert-repair dispatched `FleetUndersaturated` repair 08-30 19:35 (rc=0) | — | KEEP |
| keystone-routing | `keystone-hc-ping` pings fired inside intake/reconcile/restore/scout runs; `fleet_keystone_routing_heartbeat_seconds` live | — | KEEP — routing ledger pulse |
| self-maintenance | `fleet_self_maintenance_merges/ratio` live (ratio 0.99 on 08-30) | — | KEEP |
| waste-ledger | `fleet_waste_runs{kind=total}` live | — | KEEP |
| console-tile-verify | fleet-console-pi pushed live truth to KV every 5 min; verify lid close | — | KEEP |
| gh-cache | `fleet_gh_cache_fresh` live; mirror quarantine handled 08-30 | — | KEEP |
| scout | 08-30: LOUD `SCOUT-FUTILITY` (0509 consecutive_dry=15, runway 7h), dedup'd to open #2054; fleet-ops scout gate `hours=36 action=rest` | — | KEEP — work-supply + futility detection |
| asset-census | Weekly census 08-30 03:36 — full JSON inventory (13k journal lines) | — | KEEP |
| resilience-drill | Eleven-plane drill PASS 08-30 07:11 (fleet-ops#455+#1463) | — | KEEP |
| gh-webhook-receiver | Webhook pipe live: canary deliveries received and IGNORED (channel proven end-to-end) | — | KEEP |
| gh-webhook-canary | Synthetic push every 4 min | gh-webhook-canary-deadman (its deadman) | KEEP |
| grok-token-refresh | Rotated xai-oauth seat token 08-30 16:04 (access+refresh rotated, expires_in 21600) | — | KEEP — credential continuity |
| truth-staleness | 08-30: 83 claims from 4/8 docs, 69 unique, 0 mismatches, 0 filed (clean = healthy) | — | KEEP |
| gh-rate-limit | `fleet_gh_rate_limit_*` live (fetch 08-30 19:30) | — | KEEP |
| baseline-delta | **NEW** — added #2187 (08-29), live fragment installed 08-30 09:22; first fire **Sun 09-06 04:00** | WFR input #6 baseline-delta pre-pass | KEEP (NEW) — first-fire evidence due 09-06 |

### Repo-sourced organs and rails (audit class (a)/(b))

| Organ | Fires 14d → real work | Overlap | Verdict |
|---|---|---|---|
| fleet-heartbeat | Orchestrator ticks (freshness skip when <20m, dead-man pings); dispatches repairs | — | KEEP — keystone |
| fleet-deploy-check | Every-2-min origin/main check; deployed unit symlinks re-created 08-30 19:47 (this rail is the merge-to-live path) | — | KEEP |
| fleet-blind-audit | 08-30 03:44: findings 133-135 + `filed=5` → filed issue pack | — | KEEP |
| fleet-restore-drill | 08-30 18:11: PASS, all critical fleet paths under restic, restore story proven | — | KEEP |
| fleet-bare-metal-rebuild-drill | 08-30 04:27: PASS, manifest complete (plane 2 container proof) | — | KEEP |
| fleet-weekly-fleet-review | 08-30 05:05: WFR ran SUCCESS (minimax seat, 217s) | — | KEEP (this review is its lens) |
| fleet-aeo-probe | 08-30 03:35: wrote `latest.json` (3/3 engines `no configured seat` — seat config gap, tolerated per WFR input #5) | GEO/AEO measurement agenda (#1245) | KEEP — measurement rail; flagged risk (below) |
| fleet-console-pi | KV push every 5 min (console tile) | console-tile-verify (its verifier) | KEEP |
| fleet-seat-recovery | Path rail, 268k journal lines in window — seat transitions, bench-expired fail-open | seat-walled-probe (marginal, see proposal) | KEEP |
| fleet-researcher | 4 dispatches in window; 08-27 `accepted=3 filed=3` (real admission), 08-28 ×2 and 08-30 `accepted=0 filed=0` | quality-research-weekly (#541) + WFR L5 (research triple) | KEEP — real work in window, low yield; flagged (below) |
| escalation-daily-sweep | Daily synthetic STOP-REASON (dead-man floor for the escalation layer) | — | KEEP |
| intake-reconcile | 08-30 19:32: converged 14 repos; perm-excluded siterep, deferred siterep-public/tinystudio-in | — | KEEP |
| interactive-session-reap | Every fire "no idle sessions past 8h" (prevention organ — dead-seat/EXTLOAD class) | — | KEEP (harm-if-deleted > 0 despite 0 fires→work) |
| pi-intake@/pi-issue@/pi-packet@/pi-audit@/pi-scout@ | Intake ticks dispatch/skip issues continuously (08-30: skipped-blocked-on batches, claims) | — | KEEP — stock Pi primitives |
| pi-escalation-audit | 08-30: PANEL-PENDING flag for #2054 + started `pi-escalation-audit@fleet-ops--2054--straitly` | — | KEEP |
| stop-escalation / unit-escalation@ | Senior-auditor dispatch on failures; 08-30 19:30 dispatch failed `bench=overload_503` (transient, not the organ) | — | KEEP |
| quality-research-weekly | **BROKEN RUN**: 08-30 03:00/03:15 FATAL `no explicit WORKDIR` (agent-cron-run guard); unit bytes trip the guard (probe below) | fleet-researcher + WFR L5 | KEEP + **fix filed** (#2396) — sanctioned quality organ (ledger #457) |
| fleet-heartbeat-failed-notify | OnFailure rail; 08-26 sent to Telegram (hermes gate REFUSE earlier = policy, not breakage) | — | KEEP |
| fleet-gap-closure-loop/-drill/-conference/-auditor@ | Loop 08-30 cycle 2 (2 open gap-audit issues), drills all_pass; conference 08-28 exit 1 (transient seat fail) | — | KEEP |
| oomd-drill-hog / resilience-drill-stub-restart / gap-closure-drill-stub-* | Drill fixtures, used inside the registered drills | — | KEEP — fixtures; deleting breaks the drill planes |
| pi-transport-check | PI-TRANSPORT-OK every fire (fails loud on corruption) | — | KEEP |
| standing-rules-render | Path rail 08-30 06:42: rendered 2 targets, 6 sections | — | KEEP |
| vault-conflict-resolver | Path+hourly conflict resolution runs | — | KEEP |
| vault-knowledge-format | Daily lint report written (08-30 07:45) | — | KEEP |
| nish-memory-curator | 08-30: 21 candidates compiled, 101 trust denials dispositioned, promotion proposals | memory-index-autocompact (Claude auto-memory, distinct) | KEEP |
| memory-index-autocompact | 08-28 run, below threshold (nothing to do) | — | KEEP (EXCEPTION-APPROVED 08-30) |
| prometheus-am-executor | 08-30 19:35 dispatched `FleetUndersaturated` → `alert-repair-*` unit via pi-systemd-run (rc=0) | — | KEEP — alert→repair bridge |
| daily-digest | Daily Telegram push (message_id 1243, chat 1144372019) | evening-highlights-digest (evening twin, wins-only) | KEEP |
| tinystudio-live-site-check | Nightly passes 08-30 03:36 (soft-404, headings, tap targets, social preview) | — | KEEP |
| agent-cron-0509-daily-market-signal | Daily SUCCESS 08-30 08:15 (ollama seat, delivery fallback written) | — | KEEP |
| nish-boundary-notify | Fires with opus heartbeat; boundary-escalation delivery rail | — | KEEP |
| siterep-live-canary | 08-30 19:17: firefox smoke + synthetic monitor PASS | — | KEEP |
| siterep-uptime | Every-2-min probes | — | KEEP |
| siterep-uptime-repair | 0 fires in window (repair agent; uptime healthy → correct zero) | — | KEEP (DORMANT by design) |
| siterep-deploy/-verify/-rollback | Timer **disabled** (declared-permanent-excluded intake); last attempt 08-25 verify/rollback exit-code fail | — | KEEP (DORMANT — paused product rail; resume needs a fix first) |

### Hand-placed class (a) — sanctioned, timebound

| Organ | Fires 14d → real work | Verdict |
|---|---|---|
| opus-heartbeat / opus-heartbeat-thorough | Hourly + 6-hourly duty-officer passes (deep-check battery, 24h trend) | KEEP — **scheduled expiry**: Nish-ordered "until 2026-09-08 return"; deletion candidates at 09-08 (see expiry cohort) |
| fleet-completion-canary / fleet-metrics-export | Registered organs #468; base unit files hand-placed (migration gap #1499 open) | KEEP (registry rows above) |

### NEW — first fire pending (not no-fires verdicts)

| Organ | Added | First fire | Verdict |
|---|---|---|---|
| fleet-baseline-delta | #2187, 08-29 | Sun 09-06 04:00 | KEEP (registry organ, WFR input) |
| evening-highlights-digest | hand-placed, vacation window | **tonight 08-30 21:00** | KEEP — **scheduled expiry 2026-09-08** (vacation end; missing from timer-manifest — #2161 open) |
| fleet-worktree-reaper | #2227/#2234, 08-29 | Mon 08-31 03:33 | KEEP (first-fire evidence due) |

### OUT-OF-SCOPE — stock OS units and dev-infra tools

systemd-tmpfiles-clean, launchpadlib-cache-clean (stock OS); syncthing,
camofox-browser, browser-harness-chrome, crawl4ai, codex-remote-control
(dev-infra, pre-existing; audit's out-of-scope list).

## Deletion proposals this cycle

Scoring yield: **1 proposal, 0 blind deletions.** After the conference trail
already removed the entire class-(c) set, the surviving inventory re-earned
keep on live 14-day evidence (fires → real work) or on safety/new/drill/
enforcement status. The following scored for proposal:

| Organ | Score | Proposal |
|---|---|---|
| **seat-walled-probe** | (1) nothing breaks — its seat-transition duty overlaps fleet-seat-recovery's path rail; (2) 14 days of sweeps: `probed=2 succeeded=0 failed=2 issues_filed=0` every fire, inner pi invocation fails `Unknown provider "test"`; (3) overlap with fleet-seat-recovery + seat governor | **PROPOSE-DELETE** → filed as #2394 (plain). Alternative noted: if the conference judges walled-seat probing essential, the runtime probe bug gets fixed instead — the proposal carries the failure evidence for either path |

No other organ scored all three axes for deletion: every remaining no-fires→
work case either has harm-if-deleted > 0 (interactive-session-reap,
pi-transport-check, memory-index-autocompact), is registered with an absent()
rule feeding the alert-repair chain, is safety-exempt, is drill fixture, or is
a NEW organ whose first fire is still pending (evidence due 08-31/09-06).

## Scheduled-expiry cohort (delete at date, via the recurring lens)

- **2026-09-08 (Nish's return / vacation-window end):** `opus-heartbeat`,
  `opus-heartbeat-thorough` (absence duty officer), `evening-highlights-digest`
  (vacation digest). Hand-placed units; the WFR deletion lens proposes their
  removal on the first cadence after 09-08.

## Fix findings filed (broken-run owners, not deletions)

1. **quality-research-weekly WORKDIR guard** — last two runs FATAL'd
   (`agent-cron-run: no explicit WORKDIR`). Probe: `HOME=/home/nish WORKDIR=/home/nish`
   trips the guard (`[[ "$WORKDIR" == "$HOME" ]]` → true). The twin
   `fleet-weekly-fleet-review` unit is byte-identical in WORKDIR yet ran
   successfully 08-30 05:05 — the pair is inconsistent and both next fires
   (Sun 09-06) are at risk. Filed as fix issue #2396; recommended fixes: WORKDIR to a
   repo path (as `agent-cron-0509-daily-market-signal` does) or
   `AGENT_CRON_ALLOW_HOME_WORKDIR=1`.
2. **fleet-rulebook-redteam fail-loud** — both 08-28 starts: inner pi red-team
   `rc=1`, wrapper `completed filed=0` (silent zero). Commit 58cccdc
   "fail loud when pi returns non-zero" exists — verify it is deployed before
   the next fire (01 Sep). A silent red-team makes #527 `sr-gap-rules-audit`
   enforcement unproven. Filed as fix issue #2395.

## Observed risks (not filed)

- **fleet-aeo-probe** writes all-unavailable (3/3 engines `no configured seat`).
  Seat configuration is money-adjacent (Nish-reserved); WFR input #5 tolerates
  `engine_up=0`. Re-check when seats are configured.
- **fleet-researcher** yield collapsed after 08-27 (0/0/0). If it stays zero
  next cycle, the research-triple overlap (quality-research-weekly + WFR L5)
  makes it the next consolidation candidate.
- **siterep deploy rail** last attempted 08-25 ended in verify/rollback
  exit-code failures before the intake exclusion paused it — resume needs the
  rail fixed first.
- **WFR unit Description** still says "blind 6-lens" while the prompt is 8-lens
  (role-quality-gates enum already fixed; Description is cosmetic — fleet-ops#2215 trail).
- **Stale drop-in dirs** `~/.config/systemd/user/fleet-auto-deploy.timer.d/`,
  `fleet-auto-ship.service.d/` for units that no longer exist (harmless).

## Recurrence

`prompts/weekly-fleet-review.md` now carries this lens (L3 machinery extension):
every WFR run re-scores the inventory on the same three axes, evidence window =
trailing 14 days, safety organs exempt, no-harm/no-fires/overlap → deletion
proposal through the queue. This report is the seed the lens reads.

## Method notes / limitations

- Journal window is 2026-08-16+; earlier evidence not re-scored.
- The 2026-08-30 03:32 reboot (vps-weekly-update) sits inside the window;
  evidence reflects the post-restore fleet.
- Inner-run failures (rulebook rc=1, seat-walled `Unknown provider "test"`)
  are rooted in seat/infra state; each is flagged, none walked past.
- "No fires → real work" for prevention organs (session-reap, transport-check,
  stale-checkers) is their healthy output, not drift — scored as KEEP with the
  harm line, matching the issue's "what breaks if deleted" axis.