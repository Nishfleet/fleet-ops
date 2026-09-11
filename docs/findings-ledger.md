# Findings ledger — the single durable list of every finding the fleet

## Purpose

Nish, 2026-09-11 (order): "EVERY FINDING WILL BE QUEUED FOR FIXING AND NOT
DROPPED SILENTLY? NO DUCT TAPE. The ledger proving it should be in the vault
and on the nish.sh/fleet page."

This doc and `lib/findings_ledger.py` define the canonical answer:

- **File:** `~/workspaces/tooling/nish-vault/_system/shared-memory/findings-ledger.jsonl`
  (same home + conventions as `decisions-ledger.md` and
  `promotion-denial-ledger.json`: append-only JSONL, written ONLY through
  `lib/findings_ledger.py`; every row carries a `disposition` AND a `ref`,
  and `tests/findings-ledger.test.sh` refuses a row without both.)
- **Row:** `{ts, source_organ, run_id, finding_id, severity, title,
  evidence_ref, disposition, ref, reason, [occurrences]}` where
  `finding_id = sha1(source_organ|run_id|normalised-title)[:16]` — stable so
  a later worker can upsert `carried_over → filed` with the same id.
- **dispositions:** `filed` (in an issue/PR, ref=owner/repo#n) |
  `carried_over` (cap-skipped, ref=audit_fix_pending:<organ>, must age out) |
  `panel_fail` | `by_design` (ref=citation of the design decision) |
  `duplicate_of` (ref=duplicate issue).
- **Writers:** `lib/findings_ledger.py` ONLY (append / backfill / import-md /
  sync-carryover / measure / validate). `bin/fleet-blind-audit` mirrors one
  row per verdict into it (fleet-ops#5443).
- **Judges:** `measure.sh` emits
  `findings: total=n filed=n carried_over=n oldest_carry_h=n panel_fail=n`
  next to `visitor:` — an ageing carry-over is their fault to clear
  (prompts/fable-check.md header order).
- **Console:** the nish.sh/fleet page renders totals + last 50 rows and a
  red banner when a carried_over row is older than 24h or the ledger went
  48h without an append (a silent ledger is itself a finding).
- **Backfill:** 2026-09-11 the ledger was seeded with every panel-PASS
  finding the filing cap skipped since 2026-08-20 (disposition
  `carried_over`), every outside-in audit row (source_organ
  `outside-in-audit`), and the silent-drop sweep table (source_organ
  `silent-drop-sweep`).

## Commands

```bash
python3 lib/findings_ledger.py measure                  # the judge line
python3 lib/findings_ledger.py validate                 # schema + mandatory fields
python3 lib/findings_ledger.py backfill --since 2026-08-20
python3 lib/findings_ledger.py append --source-organ X --run-id R \
        --title T --disposition carried_over --ref audit_fix_pending:X
bash tests/findings-ledger.test.sh
bash tests/findings-measure-line.test.sh
```
