# Hand-built vs. off-the-shelf — replace/delete table

Status: design doc for fleet-ops#4140 (umbrella). Companion to
`docs/design/litellm-vs-seat-lib.md` (fleet-ops#4130). Nish 2026-09-07:
"queue all on priority. the retired stuff must be wiped and saved to memory to
never build again unless a good reason exists." This doc is the inventory and
verdict table; each GO row is filed as its own agent-ready issue referencing
this one. This doc is phase-0 output — it is NOT a gate; the GO rows proceed
one PR per issue.

All line counts below are verified live (`wc -l`) on 2026-09-07, not from
memory. Where a seed-map number differs from the live count, the live count
wins and the delta is named.

## 1. Inventory scope and snapshot

Scope (per issue): `~/.local/bin`, `~/.local/libexec`, `~/.local/lib`,
`fleet-ops-deploy/{bin,lib,libexec}`, all `~/.config/systemd/user` units, and
every `fleet-*.prom` textfile writer.

Live snapshot 2026-09-07:
- `~/.local/bin` + `~/.local/libexec` + `~/.local/lib`: 60 shebang scripts,
  19,838 lines (issue snapshot; verified present).
- systemd user units: 80 `pi-*` + 47 `fleet-*` unit files (issue said 82/48;
  two units were retired since the snapshot — delta named, not trusted).
- `fleet-*.prom` textfiles: 3 (`fleet-seat-failure-ceiling.prom`,
  `fleet-seat-floor-failopen.prom`, `fleet-seat-selection.prom`), all written
  by seat-lib (covered by #4130).

## 2. Verdict table (one row per mechanism)

| # | Mechanism | Lines (live) | Owner unit(s) | Off-the-shelf replacement | What gets DELETED | Verdict |
|---|---|---|---|---|---|---|
| 1 | opus-heartbeat family | 3,249 (+7,858 .bak) | `opus-heartbeat.timer` + `heartbeat-audit` + `opus-heartbeat-run` + `opus-heartbeat-fallback` | PromQL recording rules + Alertmanager; judge packet reads `/api/v1/query` | gather + heartbeat + audit + run + fallback + 6 `.bak` copies | **GO** |
| 2 | repo-sync-snapshot.py | 1,311 | `repo-sync-snapshot.timer` | `gh` GraphQL directly, or a github-exporter for Prometheus | repo-sync-snapshot.py | **GO** |
| 3 | venue-claim + open-question | 1,810 | `venue-claim` / `open-question` (webhook/timer) | GitHub issue assignment + Projects, Actions concurrency groups, flock/systemd for local locks | venue-claim, open-question | **DONE** (retired 2026-09-07, #4143) |
| 4 | fleet-pr-rebase | 0 (already retired) | — | GitHub merge queue + auto-merge + `gh pr update-branch` | already gone (git history only) | **NO-GO** (already retired) |
| 5 | claude-telegram-bridge.py | 412 (+753 .bak) | `claude-telegram-bridge` | Hermes (Nish-owned) — one Telegram path | bridge + 2 `.bak` | **GO** (Nish decision on Telegram path) |
| 6 | seat prom writers + corpse-retire + comeback-release | 2,163 | `fleet-seat-comeback-release.timer` + seat-lib | LiteLLM health checks/cooldowns/budgets (fleet-ops#4130) | corpse-retire, comeback-release, 3 `.prom` writers | **GO** (covered by #4130) |
| 7 | dead-man canaries: gh-webhook-canary-deadman.py + fleet-completion-canary + loose-ends | 2,267+ | `fleet-completion-canary.timer` + `fleet-loose-ends-canary.timer` | healthchecks.io (account exists) + Prometheus `absent()`/Watchdog rules | deadman.py, completion-canary, loose-ends canary | **GO** |
| 8 | load-storm-brake + agent-orphan-watchdog | 376 | `load-storm-brake` / `agent-orphan-watchdog` | systemd-oomd, CPUWeight/IOWeight, cgroup scoping (`systemd-run --scope`, `KillMode=control-group`) | both scripts | **GO** |
| 9 | codex wrapper | 281 | `codex` (launcher) | systemd-run properties on the unit | codex wrapper | **GO** |
| 10 | fleet-* timers (47 units) | classify | 20 `fleet-*.timer` | Prometheus alert rule / GitHub Actions scheduled workflow / genuine drill | the non-drill timers | **PARTIAL** (see §4) |
| 11 | memory-index-dedupe.py + hermes-staff generator + oracle-* + 0509-surface-probe | 702 | various | classify | classify | **DONE** (hermes-staff GO retired 2026-09-07 #4150; memory-index-dedupe NO-GO kept; oracle-* GO retired #4162; 0509-surface-probe GO retired #1150) |

## 3. Per-row detail

### Row 1 — opus-heartbeat family → PromQL + Alertmanager (GO)

Live lines: `opus-heartbeat-gather` 1,749, `opus-heartbeat` 771,
`heartbeat-audit` 470, `opus-heartbeat-run` 146, `opus-heartbeat-fallback`
113 = **3,249 lines**. Plus **6 `.bak` copies of gather** in libexec
(1,166 + 1,214 + 1,235 + 1,353 + 1,413 + 1,477 = **7,858 lines**) — git is the
backup; delete all six.

The family re-derives fleet state (unit health, timers, PRs, claims) that
Prometheus already holds. Replacement: PromQL recording rules + Alertmanager;
the judge packet reads `/api/v1/query` instead of re-gathering.

**GO.** Delete 3,249 lines + 7,858 `.bak` lines. New organ: none — Prometheus
and Alertmanager already run. Filed as issue (see §6).

### Row 2 — repo-sync-snapshot.py → gh GraphQL / github-exporter (GO)

Live: 1,311 lines. Produces an org PR/CI snapshot. Replacement: `gh` GraphQL
directly, or a github-exporter for Prometheus.

**GO.** Delete 1,311 lines. No new organ (gh CLI / github-exporter are
off-the-shelf). Filed as issue.

### Row 3 — venue-claim + open-question → GitHub native (DONE)

Live: `venue-claim` 1,008, `open-question` 802 = **1,810 lines**. Claim/lock/
queue semantics. Replacement: GitHub issue assignment + Projects, Actions
concurrency groups, flock/systemd for local locks.

**DONE (2026-09-07, #4143).** Both scripts were orphaned (no units, no data
dir) and are wiped from the live path. The fleet already runs claim/lock/queue
on GitHub issue assignment + Projects, Actions concurrency groups, and
flock/systemd. No new organ.

### Row 4 — fleet-pr-rebase → already retired (NO-GO)

`bin/fleet-pr-rebase` is gone from the repo (git history only, last commit
`5298d67f`). No live unit, no live script. The seed-map row is stale.

**NO-GO** — already retired. Nothing to delete. No issue filed.

### Row 5 — claude-telegram-bridge.py → Hermes (GO, Nish decision)

Live: 412 lines + 2 `.bak` (371 + 382 = 753). Duplicates Hermes (Nish-owned).
Replacement: one Telegram path only, via Hermes.

**GO** — but the Telegram path is a Nish-owned decision (which bridge is
canonical). Filed as issue with a `nish-decision` note on the Telegram path.

### Row 6 — seat prom writers + corpse-retire + comeback-release → LiteLLM (GO, covered)

Live: `fleet-seat-corpse-retire` 458, `fleet-seat-comeback-release` 1,705,
plus the 3 `fleet-*.prom` writers (in seat-lib) = **2,163 lines**. All replaced
by LiteLLM health checks/cooldowns/budgets under fleet-ops#4130.

**GO** — already covered by #4130. No new issue; the #4130 program owns the
deletion. Reference only.

### Row 7 — dead-man canaries → healthchecks.io + Prometheus absent() (GO)

Live: `gh-webhook-canary-deadman.py` 228, `fleet-completion-canary` 2,039,
`fleet-loose-ends-canary` (repo bin) = **2,267+ lines**. Dead-man patterns.
Replacement: healthchecks.io (account exists) + Prometheus `absent()`/Watchdog
rules.

**GO.** Delete 2,267+ lines. No new organ (healthchecks.io + Prometheus
already exist). Filed as issue.

### Row 8 — load-storm-brake + agent-orphan-watchdog → systemd-oomd (GO)

Live: `load-storm-brake` 197, `agent-orphan-watchdog` 179 = **376 lines**.
Replacement: systemd-oomd, CPUWeight/IOWeight, cgroup scoping
(`systemd-run --scope`, `KillMode=control-group`) which makes orphans
impossible.

**GO.** Delete 376 lines. No new organ (systemd-oomd already deployed,
fleet-ops#3971). Filed as issue.

### Row 9 — codex wrapper → systemd-run properties (GO)

Live: `~/.local/bin/codex` 281 lines. Launcher governance. Replacement:
systemd-run properties on the unit.

**GO.** Delete 281 lines. No new organ. Filed as issue.

### Row 10 — fleet-* timers → classify (PARTIAL, see §4)

### Row 11 — memory-index-dedupe + hermes-staff + oracle + 0509-surface-probe → classify (DONE, see §5)

## 4. fleet-* timer classification (row 10)

20 `fleet-*.timer` units. Each is one of: a Prometheus alert rule, a GitHub
Actions scheduled workflow, or a genuine drill. Classified live:

**Genuine drills / host-side mechanisms — KEEP (13):**
`fleet-asset-census`, `fleet-bare-metal-rebuild-drill`, `fleet-blind-audit`,
`fleet-console-pi`, `fleet-deploy-check`, `fleet-heartbeat`,
`fleet-metrics-export` (feeds Prometheus), `fleet-resilience-drill`,
`fleet-restore-drill`, `fleet-rulebook-redteam`, `fleet-weekly-fleet-review`,
`fleet-worktree-reaper`, `fleet-aeo-probe` (GEO/AEO measurement, owned-content
tactic).

**Prometheus-alert-rule candidates — GO (2):**
`fleet-baseline-delta` (weekly strangeness report → Prom alert rule),
`fleet-truth-staleness-check` (staleness → Prom alert rule).

**Dead-man / healthchecks.io — GO (2):** `fleet-completion-canary`,
`fleet-loose-ends-canary` (row 7).

**GitHub Actions scheduled-workflow candidates — GO (2):**
`fleet-issue-close-duplicates`, `fleet-merged-pr-close` (both webhook-triggered
with a timer fallback; the timer fallback can move to a scheduled workflow).

**LiteLLM — GO (1):** `fleet-seat-comeback-release` (row 6, #4130).

Net: 13 KEEP, 7 GO (2 Prom-alert, 2 dead-man, 2 Actions, 1 LiteLLM). The GO
timers are deleted with their replacement issues.

## 5. Classify rows (row 11)

- `memory-index-dedupe.py` (222): dedupes the memory index. **Classify** —
  if the index is a plain file, dedupe is a one-shot maintenance script, not a
  mechanism; keep as a manual tool, no timer. Verdict: **NO-GO (KEEP)** —
  consumer is `bin/memory-index-autocompact` (tier-1 deterministic rebuild);
  no off-the-shelf deterministic equivalent exists (tier-2 uses Anthropic's
  shipped `consolidate-memory` skill but burns an Opus run on a mechanical
  edit; dedupe exists to avoid that spend). The autocompact path unit is the
  mechanism; dedupe is its cost-saving helper with no timer of its own. Kept
  (#4150).
- `hermes-staff/gen_hermes_staff.py` (147) + `run-agent` (54) + `run-script`
  (61) + `run-common.sh` (97) = 359 lines: hand-built systemd-twin generator
  for hermes cron agent/script jobs. **Classify** — live state 2026-09-07:
  orphaned. Generated units gone from systemd, `~/.hermes/cron/jobs.json`
  empty (`"jobs": []` since 2026-08-26), last run logs 2026-08-23. The
  scheduling it duplicated is owned by hermes cron (built into the hermes CLI,
  gateway live PID 1464, ticker heartbeat <60s). Verdict: **GO (retired
  2026-09-07, #4150)** — wiped: `~/.local/libexec/hermes-staff/`,
  `~/.local/state/hermes-staff/`, 13 orphan `stamp-hermes-staff-*.timer`.
  Replacement proven live: `hermes cron status` rc=0 (gateway running, ticker
  45s ago). Vault entry appended to `retired-mechanisms.md`.
- `oracle-arm-fish` (147) + `oracle-bootstrap-micro` (186): oracle scripts.
  **Classify** — Verdict: **GO (retired 2026-09-07, #4162)** — wiped and
  vault entry appended; replaced by hitrov/oci-arm-host-capacity.
- `0509-surface-probe` (163): hand-built authenticated surface-matrix probe.
  Verdict: **GO (retired 2026-09-07, #1150)** — wiped and vault entry
  appended; replaced by 0509 CI `e2e/surface-audit.mjs` +
  `cross-browser-matrix.yml`.

## 6. Total hand-built lines after the GO rows land

GO-row deletions (rows 1, 2, 3, 5, 6, 7, 8, 9 + row-10 GO timers):

| Row | Lines deleted |
|---|---|
| 1 opus-heartbeat family | 3,249 (+7,858 `.bak`) |
| 2 repo-sync-snapshot.py | 1,311 |
| 3 venue-claim + open-question | 1,810 (retired 2026-09-07) |
| 5 claude-telegram-bridge.py | 412 (+753 `.bak`) |
| 6 seat prom writers + corpse-retire + comeback-release | 2,163 |
| 7 dead-man canaries | 2,267+ |
| 8 load-storm-brake + agent-orphan-watchdog | 376 |
| 9 codex wrapper | 281 |
| 10 fleet-* timer GO rows | (units, not lines — the scripts they run are counted above) |
| **Total** | **~11,869 lines** (+8,611 `.bak` lines) |

**Total hand-built lines deleted after the GO rows land: ~11,869 lines of
live code + 8,611 lines of `.bak` copies = ~20,480 lines.** This is against a
19,838-line `~/.local` snapshot, so the GO rows remove the majority of the
hand-built surface. The seat-lib deletion (row 6) is the single largest chunk
and is owned by #4130.

No new organ is proposed in any GO row without naming what it deletes: every
replacement (Prometheus, Alertmanager, gh CLI, github-exporter, GitHub native,
Hermes, healthchecks.io, systemd-oomd, systemd-run, LiteLLM) already exists or
is off-the-shelf, and each row names the exact deletion.

## 7. Filed issues (one per GO row)

Each GO row is filed as an agent-ready issue referencing this doc and #4140.
Row 6 is covered by #4130 (no new issue). Row 4 is NO-GO (already retired).
Row 11 classify rows are filed as classify issues.

| Row | Filed issue |
|---|---|
| 1 opus-heartbeat family | #4153 |
| 2 repo-sync-snapshot.py | #4154 |
| 3 venue-claim + open-question | #4143 (dup #4155) |
| 5 claude-telegram-bridge.py | #4156 |
| 7 dead-man canaries | #4157 |
| 8 load-storm-brake + agent-orphan-watchdog | #4158 |
| 9 codex wrapper | #4159 |
| 10 baseline-delta + truth-staleness -> Prom alert | #4160 |
| 10 issue-close-duplicates + merged-pr-close -> Actions | #4161 |
| 11 oracle-* classify | #4162 |
| 11 memory-index-dedupe + hermes-staff + 0509-surface-probe classify | #4150 |
