# Plan — Nishfleet/fleet-ops#5000

D1 business-table census gauge + `ProductDataCensusDropped` alert.
Manager mode (`difficulty: heavy`). Implementer: fresh `worker` per phase; `reviewer` on each phase diff.

## Manager amendments

- 2026-09-10: phases 3+4 merged into ONE worker phase — the rule annotation text
  and the promtool `exp_annotations` must match byte-for-byte, so they cannot be
  written or reviewed independently.
- 2026-09-10: correction to the issue's accept §5 wording —
  `tests/fleet-product-slo.test.sh` has only `promtool check rules` today (no
  embedded `promtool test rules` block), so phase 4 ADDS one, following the
  existing pattern in `tests/fleet-metrics-export.test.sh`.

## Phases

- [x] phase 1: One `_D1_QUERIES` census entry (single row, five named counts) parsed into a `table_census` dict; the four existing outcome queries and windows byte-identical; census failure drops only the census (accept 1, 6, 7)
- [x] phase 2: Emit `fleet_product_table_rows{table="..."}` for `user_plan`, `watchlist`, `delivery_attempt`, `proof_capture`, `session` — all five present or the family omitted, never a fabricated 0 (accept 2)
- [x] phase 3+4: `ProductDataCensusDropped` rule in `config/fleet_rules.yml`: severity critical, `for: 5m`, `expr: fleet_product_table_rows == 0 and max_over_time(fleet_product_table_rows[24h] offset 5m) >= 1`; annotation names the table, says "production product data is empty — rows were deleted, not aged out", links Nishfleet/fleet-ops#5000, never says "repair the exporter" (accept 3, 4)
- [x] phase 3+4: Tests in `tests/fleet-product-slo.test.sh`: mocked-D1 census `{user_plan: 6, watchlist: 12, ...}` emits all five lines with those values; read failure omits the family instead of zeroing it; new embedded `promtool test rules` fire/silent pair (census 0 with history >= 1 FIRES, census 3 SILENT); fail-soft e2e blip still writes the file and exits 0 (accept 5, 7)
- [x] phase 5: No new timer/service/unit/MANIFEST entry proved by diff; existing outcome queries unchanged; full suite + `promtool check rules` + live read-only D1 census against production green (accept 6, 7)

## Phase review record (manager, per-phase reviewer)

- Salvage: phases 1-4 implemented by the prior crashed run of this same unit
  (claim branch, unpushed); rebased onto origin/main aeba9d11f, then verified.
- Whole-diff review (read-only reviewer, `/tmp/fleet-ops-5000.diff`, 348 lines):
  **0 ACT-ON, 5 CONSIDER, all seven accept bullets verified against the
  applied tree** (incl. the five table names vs the real 0509 schema and the
  promtool drill math).
- CONSIDER, recorded not re-delegated:
  1. (p)/(q) monkeypatch `_product_outcome` wholesale, so the census-failure
     `continue` path and the `rows[0][t]` parse have no direct coverage — a
     urlopen-mocked `_product_outcome` test would pin it (follow-up).
  2. Asymmetric coupling: a scalar-query failure still returns None and
     blinds the census (correlated-failure hole) — same permanent-SQL-break
     variant already recorded in Risks; file as follow-up if it recurs.
  3. Spec-chosen false-positive surface: `delivery_attempt` retention sweep
     (LIMIT 500/tick) can legitimately drain a ≤500-row cohort to 0 and read
     as "deleted"; the level-at-zero design cannot distinguish bulk-ageing —
     the issue explicitly chose it over a decay rule.
  4. FIXED inline: module docstring metric-family list omitted
     `fleet_product_table_rows` — added.
  5. promtool is optional in the suite (SKIP without it) and the (f) e2e is
     non-hermetic on token-bearing hosts — both pre-existing house patterns.
- Spec tension recorded: accept §3's mandated expr needs
  `max_over_time(...[24h]) >= 1` history, but the metric family is new — for
  the CURRENT (retroactive) wipe there is no >=1 history, so the alert is
  INACTIVE post-deploy, not FIRING as the verify comment hopes. It arms
  correctly for the next drop. Accept §3's verbatim expr shipped as written.

## Files to modify
- `lib/fleet-product-slo.py` — `_D1_QUERIES` (~1076), `_product_outcome` (~1104), `HELP_/TYPE_` constants (~259), `export_prom` (~1231)
- `config/fleet_rules.yml` — `fleet_product_slo` group (~834-884)
- `tests/fleet-product-slo.test.sh` — new scenarios + promtool test block

No new files. No MANIFEST change.

## Risks
- `promtool test rules` compares `exp_annotations` strictly → expected text must match the rendered rule exactly.
- `table` is a reserved-ish word in SQLite; the census SQL must not rely on table-name aliasing beyond the column aliases.
- Retention sweep on 0509 makes gradual decay expected → no percentage-decay rule.
- Census series absent forever if the SQL breaks permanently (level check, not `absent()`): accepted, follow-up issue.
