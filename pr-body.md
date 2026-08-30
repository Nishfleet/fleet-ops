feat(baseline-delta): week-over-week strangeness pre-pass for the WFR (fleet-ops#1151)

## Why

Issue #1151: catch unknown-unknowns as statistical strangeness. The
Weekly Fleet Review (#1146) currently sees only what lenses know to look
for; a weekly deterministic pass over the whole metric set surfaces
week-over-week shifts nothing else watches. Per the issue: median + MAD
robust stats, |z|>3 flags, top 20 only, report to the review's input dir,
never a page, stdlib + Prometheus HTTP API only, heartbeat metric.

## Scope

- `libexec/fleet-baseline-delta.py` — the pass. Queries Prometheus for
  every `fleet_*` metric name plus a curated key `node_*` set, one
  query_range per name (5 weeks at 6h step, within the 40d retention),
  buckets per series into 5 weekly windows, grades this week vs the
  trailing 4-week baseline (per-week median; median + MAD; robust z =
  (x - med) / (1.4826*MAD), flag |z|>3). Timestamp-class fleet_* clocks
  (`*_last_run_seconds`, `*_timestamp_seconds`, `*_reset`) are excluded:
  a steady clock's weekly median sits one week above the baseline every
  week, so they would re-flag as noise each run. Series with fewer than
  two populated baseline weeks are skipped and counted — the TSDB history
  on this box only reaches back ~1 week today (it accrues toward the
  configured 40d), so the report honestly says the baseline is
  accumulating instead of manufacturing flags.
- Writes `agent-state/WFR/baseline-delta.md` (+ `.json`) — the dir the
  review prompt already reads — and the WFR prompt now lists it as
  Input 6 with the "missing file / None this week = no strangeness, not
  a fail" contract.
- `systemd/fleet-baseline-delta.{service,timer}` — Sun 04:00 IST,
  between the maintenance chain (quiesce 03:15, vps-weekly-update 03:30)
  and the review (04:30 IST). ExecStart is `/usr/bin/python3
  /home/nish/.local/libexec/fleet-baseline-delta.py` so CI
  systemd-analyze verify needs no host-binary stub (this worker's token
  cannot edit workflows).
- Heartbeat per standing pattern: `fleet_baseline_delta_last_run_seconds`
  (+ anomalies/scanned gauges) written to
  `/var/lib/prometheus/node-exporter/fleet-baseline-delta.prom`, registry
  entry in `config/fleet-organs.json`, absent() rule in
  `config/fleet_rules.yml` (`fleet_baseline_delta_supply` group, warning,
  14d = two missed weekly cycles, same doctrine as asset-census/scout).
- Wiring: MANIFEST, install.sh enable --now, timer-manifest reason,
  NON_ROLE_UNIT_PREFIXES, organ-catalog row, WFR-prompt input lock in
  `tests/weekly-fleet-review.test.sh`.
- `tests/fleet-baseline-delta.test.sh` — offline suite (help, MAD
  fixture, cap-20, insufficient-history skip, heartbeat, fake-Prometheus
  HTTP path, fail-loud, non-http(s) URL refusal, MANIFEST/install shape,
  timer/service shape, rules contract), nested from
  `tests/rule-enforcement.test.sh` so CI runs it without a workflow edit.

## Tradeoffs

- Single self-contained libexec python (fleet-metrics-export /
  staleness-checker shape) over a bash wrapper (asset-census shape): no
  shell layer, and the unit keeps passing systemd-analyze verify on a
  hosted runner with only `/usr/bin/python3`.
- Weekly-only grading over the draft's daily-warmup fallback: the first
  live run proved the fallback manufactures MAD=0 `inf` flags from
  day-level noise (127 flagged). A truthfully-empty report during the
  retention warm-up is the correct quiet state; the skipped count tells
  the review why.
- Relocated the organ alert from `fleet_watchdog` into a dedicated
  `fleet_baseline_delta_supply` group, matching the per-organ `_supply`
  convention; dropped the dead `config/fleet-baseline-delta.rule.yml`
  fragment (nothing assembled it; install reads fleet_rules.yml).

## Blast Radius

New timer/unit/script/registry entry; nothing existing is changed except
the WFR prompt's Inputs list (additive) and fleet_rules.yml (new alert
only — absent() on a brand-new gauge). No existing alert, rule, or unit
behavior changes. The report writes only under `agent-state/WFR/` and the
node-exporter textfile dir. If Prometheus is unreachable the job fails
loud and the absent() rule eventually fires; the review simply lacks the
pre-pass for that week.

## Verification

- `run-proof: journal/systemctl` — live run of the real deliverable on
  this host:
  `$ /usr/bin/python3 libexec/fleet-baseline-delta.py`
  `[fleet-baseline-delta] wrote /home/nish/workspaces/agent-state/WFR/baseline-delta.md scanned=1472 ranked=0`
  Report header after fix: `scanned: 1472`, `flagged (|z|>3): 0`,
  `skipped (insufficient history): 1472` (TSDB history accrues past the
  40d retention boundary; weekly baseline populates in ~4 weeks).
  Heartbeat confirmed live in Prometheus:
  `GET /api/v1/query?query=fleet_baseline_delta_last_run_seconds` →
  `{'fleet_baseline_delta_last_run_seconds': 1788053670.26}`.
- `systemd-analyze verify` on the two new units: no errors.
- `bash tests/fleet-baseline-delta.test.sh` — all 10 checks + sub-items
  pass (promtool validates fleet_rules.yml clean on this host).
- `bash tests/timer-manifest.test.sh`, `manifest-shape.test.sh`,
  `system-dropins-shape.test.sh`, `fleet-rules-severity-page.test.sh`,
  `fleet-organ-heartbeat.test.sh` — pass.
- NOTE (pre-existing, not this PR): `tests/weekly-fleet-review.test.sh`
  and `lib/role-quality-gates.py` still lock the 6-lens contract while
  #2173 moved the WFR prompt to 8-lens; both fail on pristine origin/main
  too. Filed as fleet-ops#2186; this PR inherits the red from main in the
  P14 tests job but does not touch those locks (out of scope, and an
  auto-revert of #2173 may supersede). Required checks (Gitleaks, Semgrep,
  Shellcheck, systemd-analyze) are unaffected by it.

Closes #1151