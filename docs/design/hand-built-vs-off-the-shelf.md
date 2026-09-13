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
| 1 | opus-heartbeat family | 3,249 (+7,858 .bak) | `opus-heartbeat.timer` + `heartbeat-audit` + `opus-heartbeat-run` + `opus-heartbeat-fallback` | PromQL recording rules + Alertmanager; judge packet reads `/api/v1/query` | gather + heartbeat + audit + run + fallback + 6 `.bak` copies | **DONE** (#4141) |
| 2 | repo-sync-snapshot.py | 1,311 | `repo-sync-snapshot.timer` | (none — see row detail) | (none — see row detail) | **NO-GO** (misdescribed: not an org PR/CI snapshot; see row detail) |
| 3 | venue-claim + open-question | 1,810 | `venue-claim` / `open-question` (webhook/timer) | GitHub issue assignment + Projects, Actions concurrency groups, flock/systemd for local locks | venue-claim, open-question | **DONE** (retired 2026-09-07, #4143) |
| 4 | fleet-pr-rebase | 0 (already retired) | — | GitHub merge queue + auto-merge + `gh pr update-branch` | already gone (git history only) | **NO-GO** (already retired) |
| 5 | claude-telegram-bridge.py | 412 (+753 .bak) | `claude-telegram-bridge` | Hermes (Nish-owned) — one Telegram path | bridge + 2 `.bak` | **GO** (Nish decision on Telegram path) |
| 6 | seat prom writers + corpse-retire + comeback-release | 2,163 | `fleet-seat-comeback-release.timer` + seat-lib | LiteLLM health checks/cooldowns/budgets (fleet-ops#4130) | corpse-retire, comeback-release, 3 `.prom` writers | **GO** (covered by #4130) |
| 7 | dead-man canaries: gh-webhook-canary-deadman.py + fleet-completion-canary + loose-ends | 2,267+ | `fleet-completion-canary.timer` + `fleet-loose-ends-canary.timer` | healthchecks.io (account exists) + Prometheus `absent()`/Watchdog rules | deadman.py, completion-canary, loose-ends canary | **GO** |
| 8 | load-storm-brake + agent-orphan-watchdog | 376 | `load-storm-brake` / `agent-orphan-watchdog` | systemd-oomd, CPUWeight/IOWeight, cgroup scoping (`systemd-run --scope`, `KillMode=control-group`) | both scripts | **DONE** (retired 2026-09-07, #4147) |
| 9 | codex launcher (wrapper + governed-run + agent-governor-runtime) | 3,976 (+281 `.bak`) | `codex` (launcher) | per-role systemd unit templates `codex-sol@.service` (unused paper; Sol retired) + `codex-luna@.service` — identity pinned in ExecStart (model/provider/effort fixed) | wipe gated on one green Luna-class run after ChatGPT usage reset | **SHAPE-ONLY** (#4148; wipe gated; #4159 closed as dup) |
| 10 | fleet-* timers (47 units) | classify | 20 `fleet-*.timer` | Prometheus alert rule / GitHub Actions scheduled workflow / genuine drill | the non-drill timers | **PARTIAL** (see §4) |
| 11 | memory-index-dedupe.py + hermes-staff generator + oracle-* + 0509-surface-probe | 702 | various | classify | classify | **DONE** (hermes-staff GO retired 2026-09-07 #4150; memory-index-dedupe NO-GO kept; oracle-* GO retired #4162; 0509-surface-probe GO retired #1150) |

## 3. Per-row detail

### Row 1 — opus-heartbeat family → PromQL + Alertmanager (DONE, #4141)

Retired 2026-09-07. Live lines were: `opus-heartbeat-gather` 1,749, `opus-heartbeat` 771,
`heartbeat-audit` 470, `opus-heartbeat-run` 146, `opus-heartbeat-fallback`
113 = **3,249 lines**. Plus **6 `.bak` copies of gather** in libexec
(1,166 + 1,214 + 1,235 + 1,353 + 1,413 + 1,477 = **7,858 lines**) — git is the
backup; all deleted.

The family re-derived fleet state (unit health, timers, PRs, claims) that
Prometheus already holds. Replacement: PromQL recording rules (group
`fleet_duty_officer_recording` in `config/fleet_rules.yml`) + the existing
hourly fleet judge (`fable-fleet-check.service`, packet
`agent-state/fleet-landing-watch/fable-check.md`) which now queries
`/api/v1/query` with an anti-fabrication rule. The 5 live scripts were
archived to `archive/opus-heartbeat-retired-2026-09-07/` before deletion.

### Row 2 — repo-sync-snapshot.py → NO-GO (misdescribed seed map)

Live: 1,311 lines (`~/.local/libexec/repo-sync-snapshot.py`, 44,138 bytes;
source in the local-only `control-plane` repo, which has no GitHub remote and
where `Nishfleet/control-plane` does not exist).

The seed map described this as "org PR/CI snapshot" and proposed `gh` GraphQL
or a Prometheus github-exporter as the replacement. That description is
factually wrong, verified live 2026-09-07:

- The file's docstring is "Safely replicate Git repositories and dirty work
  between two machines." It is a Mac↔VPS **Git repository replication** tool,
  not an org PR/CI snapshot tool.
- Functions: `sync_repositories`, `create_snapshot`, `publish_repository`,
  `fetch_peer_repository`, `ensure_local_bare_repo`, `ensure_remote_bare_repo`,
  `create_stash_snapshots` — all replication, zero PR/CI.
- `grep -iE 'pull.?request|pr[_-]|ci[_-]|check.?run|workflow.?run|graphql|
  github.?exporter|prometheus|\.prom'` over the file → 0 matches.
- The proposed replacement (gh GraphQL / github-exporter) snapshots org PRs/CI
  — a different function. It does not replicate Git repositories between
  machines.

The mechanism is also **dormant**, not running:

- Consuming units `repo-sync-snapshot.{service,timer}` and
  `repo-sync-tooling.{service,timer}` exist only as files under
  `control-plane/systemd/`; they are NOT installed in
  `~/.config/systemd/user/` (`systemctl --user list-unit-files 'repo-sync*'` →
  0; `list-timers 'repo-sync*'` → 0).
- `~/.local/state/repo-sync/state.json` last modified 2026-08-23 (before the
  2026-08-25 fleet restoration); backups dir `/home/nish/repo-sync-backups/`
  last written 2026-08-24.

**NO-GO** for the proposed replacement — it does not cover the file's actual
job, and the file is not in fleet-ops (a fleet-ops PR cannot delete it). The
seed-map row is corrected here. Whether the dormant Mac↔VPS Git replication
should itself be retired — and with what substitute (e.g. both machines pull
from the existing GitHub mirrors / `.mirrors/`) — is a separate, correctly
described decision for Nish, not this row. Issues #4142 and #4154 were filed
from the wrong row and cannot be implemented as written.

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

### Row 8 — load-storm-brake + agent-orphan-watchdog → systemd-oomd (DONE)

Live: `load-storm-brake` 197, `agent-orphan-watchdog` 179 = **376 lines**.
Replacement: systemd-oomd, CPUWeight/IOWeight, cgroup scoping
(`systemd-run --scope`, `KillMode=control-group`) which makes orphans
impossible.

**DONE (2026-09-07, #4147).** Both scripts are wiped from the live path (rm,
no .bak, no parked copies). Every agent launch runs as a scope/service
(`KillMode=control-group`) so orphans cannot exist (verified live:
`pi-issue@fleet-ops-4147.service` runs under `app-pi-issue.slice` with
`KillMode=control-group`); load storms are prevented by systemd-oomd
(active since 2026-09-03, fleet-ops#3971) + CPUWeight/IOWeight
(`user-1000.slice` CPUWeight=60, `fleet-work.slice` CPUWeight=80,
`tmux-spawn-*.scope.d` interactive CPUWeight=300). The
`agent-governor-orphan-watchdog.timer` + LoadStorm skip-listing in
alertmanager/alert-repair-dispatch are gone. No new organ.

### Row 9 — codex launcher → per-role systemd unit templates (SHAPE-ONLY #4148)

Live: `~/.local/bin/codex` 281 lines + `~/.local/bin/governed-run` 31 lines +
`~/.local/libexec/agent-governor-runtime/` ~3,664 lines (+ one 281-line
`.bak`). Launcher governance: launch-time identity/policy gates
(broker/manifest/trace, certified policy, allow-listed models/efforts,
provider pin, `--oss`/`--local-provider` denial, process-group supervision).

Replacement (DECISIONS on #4148, canonical; #4159 closed as duplicate):
per-role systemd unit templates whose ExecStart hard-codes identity —
`codex-sol@.service` = `codex-real exec --json -m gpt-5.6-sol
-c model_provider=openai` with effort as the instance (`@medium`/`@xhigh`);
`codex-luna@.service` = `gpt-5.6-luna` + `openai` + `effort=max`. A launch
through a template cannot express another identity, so the wrapper's
allow-list holds by construction. Anything not expressible as a fixed
ExecStart was dropped and listed in the #4148 PR body (`agent_type`,
`fork_turns`, `--oss`/`--local-provider` denial, broker decision, signal
supervision — the last replaced natively by systemd `KillMode=control-group`).

**SHAPE-ONLY** (#4148; wipe gated; #4159 closed as duplicate). Archived to
`archive/codex-launcher-retired-2026-09-07/` (wrapper + runtime +
governed-run; git history is the backup, same rule as #4141) and the two
templates are committed. The DECISIONS proof run (one real Sol packet
through `codex-sol@`) FAILED: ChatGPT-account auth rejects `gpt-5.6-sol`
(400). Nish 2026-09-07 then retired Sol (do not top up straitly); the
Sol-run proof is dropped. Proof (c) is one Luna-class run through
`codex-luna@` after the ChatGPT usage reset (2026-09-12T14:31Z). Until
then do not delete the live wrapper, `governed-run`, or
`agent-governor-runtime`. Wipe follow-up: #4278. Templates are launch
paper, not scheduled machinery; no new organ. Live launches still go
through the PATH wrapper until that wipe.

### Row 10 — fleet-* timers → classify (PARTIAL, see §4)

### Row 11 — memory-index-dedupe + hermes-staff + oracle + 0509-surface-probe → classify (DONE, see §5)

## 4. fleet-* timer classification (row 10)

> **2026-09-07 update (fleet-ops#4149):** the 2026-08-24 snapshot below
> counted 20 `fleet-*.timer` unit files in the repo; the LIVE count at
> classification time is 19 (the dead-man canaries were retired by #4182,
> and the original 20 included drop-ins/backups). Every live timer is now
> classified; each row below is annotated with its outcome.

19 live `fleet-*.timer` units. Each is one of: a Prometheus alert rule, a
GitHub Actions scheduled workflow, or a genuine drill. Classified live:

**Genuine drills / host-side mechanisms — KEEP (14):**
`fleet-asset-census`, `fleet-bare-metal-rebuild-drill`, `fleet-blind-audit`,
`fleet-console-pi`, `fleet-deploy-check`, `fleet-heartbeat`,
`fleet-metrics-export` (feeds Prometheus), `fleet-resilience-drill`,
`fleet-restore-drill`, `fleet-rulebook-redteam`, `fleet-weekly-fleet-review`,
`fleet-worktree-reaper`, `fleet-aeo-probe` (GEO/AEO measurement, owned-content
tactic), `fleet-baseline-delta` (RE-CLASSIFIED, below).

**RE-CLASSIFIED KEEP — `fleet-baseline-delta` (fleet-ops#4149):** the
original table listed it as a Prom-alert candidate ("weekly strangeness
report"). The mechanism's own contract — fleet-ops#1151, pinned by the unit's
named reason and the `FleetBaselineDeltaAbsent` rule in config/fleet_rules.yml
("a high |z| is a report line for the review conference, never a page") — is
that it produces the ranked top-20 baseline-delta pre-digest the weekly review
conference reads. A Prometheus alert rule cannot reproduce the report (the
median/MAD strangeness math is not expressible in PromQL, and paging on every
anomaly is the wrong contract), and it must run on the VPS against localhost
Prometheus, so it cannot move to Actions. No off-the-shelf equivalent exists.
It fails the deletion bar, so it stays.

**Retired as Prom-alert-rule — `fleet-truth-staleness-check` (fleet-ops#4149,
this PR):** the weekly staleness checker + its auto-filed GitHub issues were a
hand-built alert channel. The detector stays — it piggybacks the
fleet-metrics-export tick via ExecStartPost (systemd/fleet-metrics-export
.service.d/staleness-checker.conf), so no timer of its own — and the
off-the-shelf notifier is the new `TruthStalenessMismatch` alert rule
(`fleet_truth_staleness_mismatches_by_kind > 0`, severity=warning) in
config/fleet_rules.yml, beside the existing `TruthStalenessAbsent` heartbeat.
The timer, service, and the issue-filing machinery in the checker are deleted
in #4149; the finding details live in the JSON cache
(~/workspaces/agent-state/fleet-metrics/staleness-findings-cache.json).

**Dead-man / healthchecks.io — DONE (#4182, merged):** `fleet-completion-canary`,
`fleet-loose-ends-canary` (row 7) are retired; the deadman metric + chain prom
files are gone from the repo and the live box.

**GitHub Actions scheduled-workflow candidates — KEEP (2), pending #4161:**
`fleet-issue-close-duplicates`, `fleet-merged-pr-close` are webhook-triggered
with a timer fallback. They cannot move to Actions yet: the worker token has
NO Workflows permission and cannot write `.github/workflows/**` (fleet-ops#3735).
Tracked in #4161; re-audit when the token is upgraded.

**LiteLLM — PENDING (1):** `fleet-seat-comeback-release` (row 6, #4130). The
LiteLLM proxy organ is in flight (#4178 P1); the comeback-release timer retires
when #4130 lands.

Net: 19 live before #4149 → 18 after (truth-staleness-check retired; the other
18 are KEEP or tracked against #4130/#4161).

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
  `cross-browser-matrix.yml`. Stale prom writers
  (`fleet-surface-probe-0050.prom`, `fleet-surface-probe-0509.prom`) wiped
  from `/var/lib/prometheus/node-exporter/` 2026-09-07; no `fleet_probe` /
  `fleet_surface_probe` rule remains in `config/fleet_rules.yml`.

## 6. Total hand-built lines after the GO rows land

GO-row deletions (rows 1, 3, 5, 6, 7, 8, 9 + row-10 GO timers; row 2 is
NO-GO — see §3 row 2 — and is excluded from the total):

| Row | Lines deleted |
|---|---|
| 1 opus-heartbeat family | 3,249 (+7,858 `.bak`) |
| 3 venue-claim + open-question | 1,810 (retired 2026-09-07) |
| 5 claude-telegram-bridge.py | 412 (+753 `.bak`) |
| 6 seat prom writers + corpse-retire + comeback-release | 2,163 |
| 7 dead-man canaries | 2,267+ |
| 8 load-storm-brake + agent-orphan-watchdog | 376 (retired 2026-09-07) |
| 9 codex launcher (wrapper + governed-run + runtime) | 3,976 (+281 `.bak`) |
| 10 fleet-* timer GO rows | (units, not lines — the scripts they run are counted above) |
| **Total** | **~14,253 lines** (+8,892 `.bak` lines) |

**Total hand-built lines deleted after the GO rows land: ~14,253 lines of
live code + 8,892 lines of `.bak` copies = ~23,145 lines.** Against a
23,814-line `~/.local` snapshot count (the original 19,838-line figure did
not include the row-9 runtime tree under `libexec/`, added here at 3,976
lines), the GO rows remove the majority of the hand-built surface. The
seat-lib deletion (row 6) is the single largest chunk
and is owned by #4130. Row 2 (repo-sync-snapshot.py, 1,311 lines) is NO-GO and
not counted; see §3 row 2.

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
| 1 opus-heartbeat family | #4141 (DONE) |
| 2 repo-sync-snapshot.py | #4154 (NO-GO — filed from the wrong row; see §3 row 2) |
| 3 venue-claim + open-question | #4143 (dup #4155) |
| 5 claude-telegram-bridge.py | #4156 |
| 7 dead-man canaries | #4157 |
| 8 load-storm-brake + agent-orphan-watchdog | #4147 (dup #4158) |
| 9 codex launcher wrapper | #4148 (canonical; #4159 closed as dup) |
| 10 baseline-delta + truth-staleness -> Prom alert | #4160 (DONE — truth-staleness retired by #4245, TruthStalenessMismatch rule live; baseline-delta re-classified KEEP per its #1151 review-conference contract) |
| 10 issue-close-duplicates + merged-pr-close -> Actions | #4161 |
| 11 oracle-* classify | #4162 |
| 11 memory-index-dedupe + hermes-staff + 0509-surface-probe classify | #4150 |

Spec-gate note (2026-09-12, #6021): every #4140-row issue body above now carries the line-anchored `accept:`/`moves:` tokens — all 20 pass `lib/agent-ready-spec-gate.py check-body --repo fleet-ops`; the hourly refuse loop (>120 comments on #4160 alone) is closed. The ten bodies still refusing on 2026-09-12 (#4142, #4144, #4145, #4146, #4149, #4153, #4154, #4155, #4158, #4159) were appended in place, two lines each, prose verbatim; no machinery touched.
