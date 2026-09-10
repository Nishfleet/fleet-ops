# Plan — Nishfleet/fleet-ops#5000

D1 business-table census gauge + `ProductDataCensusDropped` alert.
Manager mode (`difficulty: heavy`). Implementer: fresh `worker` per phase; `reviewer` on each phase diff.

## Phases

- [x] phase 1: One `_D1_QUERIES` census entry (single row, five named counts) parsed into a `table_census` dict; the four existing outcome queries and windows byte-identical; census failure drops only the census (accept 1, 6, 7)
- [x] phase 2: Emit `fleet_product_table_rows{table="..."}` for `user_plan`, `watchlist`, `delivery_attempt`, `proof_capture`, `session` — all five present or the family omitted, never a fabricated 0 (accept 2)
- [ ] phase 3: `ProductDataCensusDropped` rule in `config/fleet_rules.yml`: severity critical, `for: 5m`, `expr: fleet_product_table_rows == 0 and max_over_time(fleet_product_table_rows[24h] offset 5m) >= 1`; annotation names the table, says "production product data is empty — rows were deleted, not aged out", links Nishfleet/fleet-ops#5000, never says "repair the exporter" (accept 3, 4)
- [ ] phase 4: Tests in `tests/fleet-product-slo.test.sh`: mocked-D1 census `{user_plan: 6, watchlist: 12, ...}` emits all five lines with those values; read failure omits the family instead of zeroing it; new embedded `promtool test rules` fire/silent pair (census 0 with history >= 1 FIRES, census 3 SILENT); fail-soft e2e blip still writes the file and exits 0 (accept 5, 7)
- [ ] phase 5: No new timer/service/unit/MANIFEST entry proved by diff; existing outcome queries unchanged; full suite + `promtool check rules` + live read-only D1 census against production green (accept 6, 7)

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
