# Machinery audit — every VPS user unit/timer vs the no-new-machinery ban

Audit owner: fleet-ops#1480
Date: 2026-08-28
Host: **netcup-rs2000** (the issue body originally said `hostinger-kvm4`; the fleet
runs on netcup-rs2000, so this is the live target. The stale host text was corrected
in the issue body 2026-08-30 via fleet-ops#1501 — a doc nit, not a class-(c) item.)

## What this audit is

Nish (2026-08-28): building new fleet machinery is banned and non-negotiable.
The ban (decisions-ledger 2026-08-26): no hand-rolled dispatchers, retry loops,
cooldown timers, pollers, queue daemons, or watchdog scripts. Composition is
systemd primitives + GitHub-inbuilt gates + Pi stock extensions + tested repo
scripts that are pure logic.

This audit inventories every user-scope unit/timer on the host, gives
provenance, classifies each into:

- **(a) Nish-endorsed / sanctioned** — explicit endorsement in the decisions
  ledger, a standing rule, the issue body, or shipped through the canonical
  repo channel (PR-reviewed `systemd/` in fleet-ops).
- **(b) sanctioned-class, never explicitly endorsed** — a watchdog / drill /
  heartbeat / repair whose *class* is sanctioned but which has no explicit
  Nish endorsement on record.
- **(c) unsanctioned build** — hand-placed, bypasses the repo, matches a banned
  class (dispatcher / poller / watchdog), no endorsement found. Follow-up
  issues filed; the senior conference adjudicates (no mass-delete).

## Method

1. `systemctl --user list-timers --all` + `list-unit-files` (service + timer).
2. For each unit: fragment path → symlink target vs real file. **Symlinked to
   `fleet-ops-deploy-clone/systemd/`** = repo-sourced (PR-reviewed). **Real file
   in `~/.config/systemd/user/`** = hand-placed (bypassed the repo).
3. ExecStart + Description from the unit file; journal first-run; file mtime.
4. Endorsement check against the vault decisions ledger, global-standing-rules,
  `config/fleet-organs.json`, and the issue body.
5. Class-(c) candidates get a follow-up issue (deletion/disable or adjudication),
  not a blind delete.

## Summary

- 42 active timers; 73 timer unit-files (many are masked template instances →
  `/dev/null`, benign); 124 service unit-files.
- **Repo-sourced (symlinked to the deploy-clone): 39 distinct units.** These
  went through PR review in fleet-ops — the sanctioned channel. Class (a) where
  the ledger endorses the family, else (b). None are class (c): they did not
  bypass the repo.
- **Hand-placed (real files, no repo base): 22 distinct units.** These bypassed
  the repo. Of these:
  - 9 class (a): explicit Nish endorsement (ledger / standing rule / issue /
    registered organ).
  - 6 class (b): sanctioned-class, no explicit endorsement on record.
  - 7 class (c): unsanctioned build — follow-up issues filed.
- 5 hand-placed entries are dev/infra tools (syncthing, camofox-browser,
  browser-harness-chrome, crawl4ai, codex-remote-control), not fleet machinery.
  Out of the ban's scope; listed for completeness, class (a) infra.

## Repo-sourced units (symlinked to fleet-ops-deploy-clone/systemd/) — class (a)/(b)

All PR-reviewed through the repo. The repo is the sanctioned channel; bypassing
it is the ban's target, so repo-sourcing alone clears the "unsanctioned build"
bar. (a) = ledger/issue endorses the family; (b) = sanctioned-class, no explicit
endorsement found.

| Unit | Class | Endorsement / note |
|---|---|---|
| fleet-heartbeat | (a) | ledger: keystone heartbeat; fleet-ops#468 |
| fleet-heartbeat-failed-notify | (a) | heartbeat notify rail |
| fleet-deploy-check | (a) | ledger 2026-08-27 TOP GEAR; fleet-ops#468 |
| fleet-blind-audit | (a) | ledger #377 blind-audit + gap-closure |
| fleet-resilience-drill | (a) | ledger: drills #1010 |
| fleet-restore-drill | (a) | ledger: DR #1135 |
| fleet-bare-metal-rebuild-drill | (a) | docs/bare-metal-rebuild.md |
| fleet-weekly-fleet-review | (a) | ledger: WFR #1146; ratchet owner |
| fleet-asset-census | (a) | registered organ; #1149 |
| fleet-aeo-probe | (a) | ledger: GEO/AEO #1245 |
| fleet-console-pi | (a) | registered organ (console-tile-verify); #1157 |
| fleet-seat-recovery | (a) | seat governor rail |
| fleet-researcher | (b) | sanctioned-class; no explicit endorsement found |
| escalation-daily-sweep | (a) | escalation rail |
| intake-reconcile | (a) | ledger: reconciler fleet-ops#32 |
| interactive-session-reap | (a) | dead-seat EXTLOAD prevention |
| open-question… (repo has no unit) | — | see hand-placed open-question-sweep below |
| pi-intake@ / pi-intake-repair@ | (a) | stock Pi intake; intake-repos.json |
| pi-scout@ / pi-scout-repair@ | (a) | registered organ (scout) |
| pi-issue@ / pi-issue-failed@ | (a) | stock Pi issue dispatch |
| pi-packet@ / pi-packet-failed@ | (a) | stock Pi packet dispatch |
| pi-audit@ / pi-escalation-audit | (a) | escalation audit rail |
| quality-research-weekly | (a) | ledger: quality #457 |
| siterep-deploy / -verify / -rollback | (a) | siterep deploy rail |
| siterep-live-canary | (a) | registered canary |
| siterep-uptime | (a) | uptime rail |
| standing-rules-render | (a) | vault standing-rules render |
| stop-escalation / unit-escalation@ | (a) | escalation rail |
| vault-conflict-resolver | (a) | ledger: vault sync guard |
| vault-knowledge-format | (a) | vault format rail |
| agent-cron-0509-daily-market-signal | (b) | product cron; sanctioned-class, no explicit endorsement |
| oomd-drill-hog | (a) | resilience drill hog (drill class) |
| resilience-drill-stub-restart | (a) | drill plumbing |

## Hand-placed units (real files in ~/.config/systemd/user/, no repo base)

### Class (a) — Nish-endorsed / sanctioned

| Unit | First run | ExecStart | Endorsement |
|---|---|---|---|
| opus-heartbeat | 2026-08-27 | `opus-heartbeat` | ledger: Nish-ordered watch during absence |
| opus-heartbeat-thorough | 2026-08-28 | `opus-heartbeat` | timer desc: "Nish, until 2026-09-08 return" |
| nish-boundary-notify | 2026-08-26 | `nish-boundary-notify` | standing rule: Nish-RESERVED escalations |
| nish-memory-curator | 2026-08-22 | `memoryctl.py curate` | standing rule: memory compound; repo drop-in override |
| vps-maintenance-deadman | 2026-08-25 | `vps-maintenance-deadman` | issue body: known-mandatory; ledger systemd-by-default |
| vps-maintenance-quiesce | 2026-08-25 | `vps-maintenance-quiesce` | vps-maintenance family |
| vps-weekly-update | (no journal yet) | `vps-weekly-update` | ledger TOP GEAR; repo drop-in override |
| agent-governor-orphan-watchdog | 2026-08-22 | `agent-orphan-watchdog` | issue body: known-mandatory |
| fleet-completion-canary | 2026-08-27 | `fleet-completion-canary` | registered organ (fleet-organs.json); #468 |
| fleet-metrics-export | 2026-08-23 | `fleet-metrics-export.py` | registered organ (metrics-export); repo drop-in override |

Note: `fleet-completion-canary` and `fleet-metrics-export` are registered organs
but their base unit files are hand-placed, not repo-sourced. This is a
**migration gap**, not a violation — the organ is sanctioned; the unit file
should move into `systemd/` so the repo owns it. Filed as a follow-up.

### Class (b) — sanctioned-class, no explicit endorsement on record

| Unit | First run | ExecStart | Note |
|---|---|---|---|
| daily-digest | 2026-08-27 | `daily-digest` | "live Pi-era data only" Telegram push |
| pi-transport-check | 2026-08-25 | `pi-transport-check` | Pi transport integrity heartbeat; repo drop-in |
| siterep-uptime-repair | (none) | pi prompt via glm-5-2 | repair agent for siterep-uptime |
| tinystudio-live-site-check | 2026-08-24 | `tinystudio-live-site-check` | product nightly site check |
| pi-packet-escalate@ | 2026-08-25 | (template) | escalation template |
| prometheus-am-executor | 2026-08-27 | `prometheus-am-executor` | alert→repair bridge (existing infra) |
| memory-index-autocompact | 2026-08-24 | `memory-index-autocompact` | **ADJUDICATED 2026-08-30: EXCEPTION-APPROVED** (migrated to repo as class (b) sanctioned maintenance script; distinct from nish-memory-curator (vault memory vs Claude auto-memory). Script has tier-1 deterministic dedupe + tier-2 Opus headless compaction; path unit triggers on MEMORY.md growth) |

### Class (c) — unsanctioned build (follow-up issues filed)

Each is hand-placed, matches a banned class (dispatcher / poller / watchdog),
and has no endorsement on record. Follow-up issues filed for adjudication /
delete-disable. The senior conference adjudicates per the #1480 acceptance
criteria; no blind mass-delete.

| Unit | First run | Banned class | Follow-up |
|---|---|---|---|
| auditor-stdio-test | 2026-08-26 | test debris (ExecStart is `cat > /tmp/…`) | #1492 — **ADJUDICATED 2026-08-30: MECHANICAL-INSTEAD** (deleted; not fleet machinery — a stdio-ordering test fixture left installed as a user unit; no repo trace, no live safety gate depends on it; live unit file deleted + disabled) |
| ready-work | 2026-08-25 | dispatcher ("one continuation packet per firing") | #1493 — adjudicated MECHANICAL-INSTEAD (deleted; routes through Pi stock dispatch `pi-packet@`) |
| open-question-sweep | 2026-08-24 | watchdog / poller ("re-drive stalled open questions") | #1494 |
| agent-scheduler-drift | 2026-08-25 | watchdog ("enforce agent-agnostic scheduling rule") | #1495 |
| siterep-pr-conflict-watchdog | 2026-08-24 | watchdog ("conflicting open-PR pile exceeds cap") | #1496 — **ADJUDICATED 2026-08-29: MECHANICAL-INSTEAD** (GH Actions workflow `pr-conflict-watchdog.yml` in `nish3451/siterep` already provides this check via the sanctioned repo channel; VPS timer was a hand-placed redundant duplicate, already disabled; live unit + script deleted; cost concern is Nish's money decision) |
| quality-baseline-research | 2026-08-25 | dispatcher ("research refresh via Pi worker") | #1497 — **ADJUDICATED 2026-08-30: MECHANICAL-INSTEAD** (deleted; quality research is owned by the sanctioned `quality-research-weekly` class (a) repo-sourced per `docs/organ-catalog.md`. Hand-placed `quality-baseline-research.service/.timer` + `~/.local/bin/quality-baseline-refresh` was a hand-rolled dispatcher with no repo base, built 2026-08-25 (day before the ban). Both runs produced SKIP-WITH-NUDGE — zero research in 5 days, no gate it depends on is live. `visual-quality-waves.md` stays as the escalation-layer program doc; only the dispatcher was deleted. Same shape as #1493) |
| memory-index-autocompact | 2026-08-24 | (borderline b/c — filed for adjudication) | #1498 — **ADJUDICATED 2026-08-30: EXCEPTION-APPROVED** (migrated to repo as class (b) sanctioned maintenance script; distinct from nish-memory-curator (vault memory vs Claude auto-memory). Script has tier-1 deterministic dedupe + tier-2 Opus headless compaction; path unit triggers on MEMORY.md growth) |

### Out of scope — dev/infra tools, not fleet machinery

| Unit | Note |
|---|---|
| syncthing | private vault sync (pre-existing tool) |
| camofox-browser | browser service |
| browser-harness-chrome | headless Chrome CDP |
| crawl4ai | localhost markdown service |
| codex-remote-control | codex remote-control daemon |

## Builder attribution (step 4, part 1)

The class-(c) units are hand-placed (no repo base), so there is no in-repo git
history to attribute them. Provenance signals available:

- **Unit-file mtime + journal first-run** pin the build window (see table).
- The builder is the agent identity running sessions in that window. Attributing
  to a named agent requires correlating the mtime against session outcome/action
  logs and vault `agent-drop/` captures — that correlation is itself a
  hand-built hunt, so it is filed as a follow-up rather than run inline by this
  audit. The instruction gap closes at the writer the same way the ban itself
  closes: the conference adjudicates the follow-up and the WFR carries the
  "manual-seam" lens (#377) into the next blind-audit cycle.

What this audit can state with evidence: every class-(c) unit was placed between
2026-08-24 and 2026-08-26, i.e. **after** the 2026-08-26 hand-built-plumbing ban
landed in the ledger for `auditor-stdio-test` (2026-08-26), and straddling it for
the rest. That timing is the real finding: the ban existed in prose before the
gate, and prose bans lose to urgency at decision time — which is exactly the
problem the organ catalog + step-4 gate exist to fix.

## Step 4 — proposed mechanical gate (extends the #366 gate class)

Per the issue and the 2026-08-28 ledger entries (104–110): the by-fiat
machinery-gate build is VOID. This audit **proposes** the mechanism; the senior
conference + WFR decide and ship it. No agent ships one by fiat. The proposal
satisfies Nish's standing acceptance criteria (default-deny; violations
self-adjudicate via senior conference; only Nish-reserved verdicts reach Nish;
organ catalog from this inventory; enforcement as pipeline/policy-as-code).

### Shape: extend the existing #366 mechanical-fix gate class

The repo already has the pattern: `lib/failure-mechanism-gate.py` (pure
evaluator: `evaluate` + `hunt` subcommands, no GitHub writes) +
`bin/fleet-failure-mechanism-gate` + `bin/fleet-organ-heartbeat-check` (the same
gate class for organs) + a regression test + blind-audit integration. The
machinery-authorization gate is the same shape, one new evaluator, no new
orchestration organ.

### Proposed evaluator: `lib/machinery-authorization-gate.py`

Pure evaluator, no dispatch, no GitHub writes:

- `evaluate` — takes a PR name-status diff + the authorized-units allowlist.
  REJECT if the diff adds a new file under `systemd/**` or a new MANIFEST line
  mapping to a `systemd/` unit, AND the unit is not on the allowlist, AND the PR
  does not carry the Nish-only authorization signal. Repairs and deletions of
  existing machinery stay ungated (fix-it-now unaffected).
- `hunt` — enumerates live user units (`systemctl --user list-unit-files`) and
  flags any non-transient unit whose fragment is a real file in
  `~/.config/systemd/user/` (hand-placed) and not on the allowlist. This is the
  blind-audit lens that catches the bypass the repo gate cannot see (direct
  local write). Output is a finding per unit, ready for the queue.

### Allowlist

The (a)/(b) inventory above is the seed for the authorized-units allowlist. It
becomes authoritative when Nish human-locks it in the vault (Nish's action, not
this PR). Until then, the `hunt` subcommand runs against the in-repo seed
(`config/machinery-allowlist.json`, this PR) and reports drift; it does not
quarantine. The quarantine step (extend `fleet-deploy-check` to mask non-
allowlisted hand-placed units) lands only AFTER the allowlist is final — per the
issue's explicit ordering, because non-fleet-ops-sourced sanctioned units exist
(memory curator, agent-cron, pi-intake instances, skills-library-link, safety
organs).

### Self-adjudication rail (no new organ)

A `hunt`/`evaluate` REJECT auto-files an `agent-ready` issue (existing queue +
pi-issue dispatch, zero new organs). The convener runs two blind senior POVs
(Parallel-POV doctrine) then verdicts:

- **MECHANICAL-INSTEAD** — redirect to the existing organ/catalog row (default on
  doubt). The organ catalog (`docs/organ-catalog.md`, this PR) makes reuse
  cheaper than building.
- **EXCEPTION-APPROVED** — convener records the exception with both POVs on
  record; the unit is added to the allowlist via PR.
- **NISH-RESERVED** — boundary-notify; the only path that reaches Nish.

WFR audits every verdict (quality ratchet). This is exactly the #366 gate class:
evaluator + hunt + regression test + blind-audit integration, no hand-built
dispatch.

### Residual, stated honestly

Agents authenticate as `nish3451` and hold sudo (Nish's standing choice), so the
gate makes violations deliberate and auditable, not cryptographically
impossible. The harder wall is the nishfleet-worker identity split (fleet-ops#413).

## Organ catalog

Shipped as `docs/organ-catalog.md` — one always-loadable file mapping job
classes to their existing owner (unit / issue / mechanism), so reuse is cheaper
than building. An agent reaching for a banned class finds the existing row
instead.

## Follow-up issues filed

Class (c) — adjudicate / delete-disable:
- #1492 auditor-stdio-test (delete test debris) — **ADJUDICATED 2026-08-30: MECHANICAL-INSTEAD** (deleted)
- #1493 ready-work (adjudicate dispatcher)
- #1494 open-question-sweep (adjudicate watchdog/poller)
- #1495 agent-scheduler-drift (adjudicate watchdog)
- #1496 siterep-pr-conflict-watchdog (adjudicate watchdog)
- #1497 quality-baseline-research (adjudicate dispatcher) — **ADJUDICATED 2026-08-30: MECHANICAL-INSTEAD**
- #1498 memory-index-autocompact (adjudicate borderline b/c) — **ADJUDICATED 2026-08-30: EXCEPTION-APPROVED**

Other:
- #1499 migration gap: `fleet-completion-canary` + `fleet-metrics-export` base
  unit files → move into `systemd/`.
- #1500 builder-attribution correlation hunt (manual-seam lens, next blind-audit).
- #1501 doc nit: issue body `hostinger-kvm4` → `netcup-rs2000`.
