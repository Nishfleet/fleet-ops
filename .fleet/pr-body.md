## docs(design): hand-built vs off-the-shelf replace/delete table (fleet-ops#4140)

Inventory and verdict table for every hand-built mechanism vs a battle-tested
or built-in equivalent. Companion to `docs/design/litellm-vs-seat-lib.md`
(#4130). One row per mechanism with live-verified line counts, owner units,
the off-the-shelf replacement, what gets DELETED, and a GO/NO-GO verdict.

### Acceptance (from #4140)

- every row has a verdict — **met**: all 11 rows carry GO / NO-GO / PARTIAL.
- total hand-built lines after the GO rows land is stated — **met**:
  ~11,869 lines of live code + 8,611 `.bak` lines = ~20,480 lines deleted.
- no new organ is proposed without naming what it deletes — **met**: every
  replacement (Prometheus, Alertmanager, gh CLI, github-exporter, GitHub
  native, Hermes, healthchecks.io, systemd-oomd, systemd-run, LiteLLM) already
  exists or is off-the-shelf, and each row names the exact deletion.

### Filed issues (one per GO row, referencing #4140)

- #4153 opus-heartbeat family -> PromQL + Alertmanager
- #4154 repo-sync-snapshot.py -> gh GraphQL / github-exporter
- #4155 venue-claim + open-question -> GitHub native
- #4156 claude-telegram-bridge.py -> Hermes
- #4157 dead-man canaries -> healthchecks.io + Prometheus absent()
- #4158 load-storm-brake + agent-orphan-watchdog -> systemd-oomd
- #4159 codex wrapper -> systemd-run properties
- #4160 baseline-delta + truth-staleness -> Prom alert rules
- #4161 issue-close-duplicates + merged-pr-close -> Actions workflows
- #4162 oracle-* classify

Row 6 (seat prom writers + corpse-retire + comeback-release) is covered by
#4130 — no new issue. Row 4 (fleet-pr-rebase) is NO-GO — already retired.

### Verification

- `wc -l` on every seed-map mechanism run live 2026-09-07; line counts in the
  doc are the live counts, not the seed-map numbers (deltas named).
- systemd user units counted live: 80 `pi-*` + 47 `fleet-*` (issue said 82/48;
  two units retired since the snapshot — delta named).
- 10 agent-ready issues filed via `gh issue create` (URLs above), each
  referencing #4140.

run-proof: issues #4153-#4162 filed via gh issue create; wc -l verified live; systemd unit counts verified live

net-positive-because: this is a phase-0 design doc (paper, not machinery) that
inventories ~20,480 lines of hand-built code for deletion; the net-positive
diff is the inventory itself, and the GO rows it files will drive the net
negative.

Closes #4140
