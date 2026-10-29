# D1 off-site backup for a database that holds a virtual table (fleet-ops#10745)

**Decision: a dump over the query API is the mechanism, and it is proven. No
repository can hold it yet — every candidate is archived or held to net-zero
workflow code lines — so this change lands the record and nothing that runs.**
This answers what the issue asked: whether a SQL dump is the mechanism at all, and
which repo owns it.

## The problem, as three live runs

`Nishfleet/drive` backs up six databases weekly from `.github/workflows/d1-export.yml`.
The `drive` database is the only one the stock path cannot touch:

- run [40714070907](https://github.com/Nishfleet/drive/actions/runs/40714070907), `waitlist` exported, `drive` died: `cannot export databases with virtual tables (like FTS5)`
- run [40715881740](https://github.com/Nishfleet/drive/actions/runs/40715881740), same with `dump_options.tables`
- run [40726174871](https://github.com/Nishfleet/drive/actions/runs/40726174871), same with `dump_options.no_schema`

The refusal is by design, not a bug: Cloudflare, [import-export-data](https://developers.cloudflare.com/d1/best-practices/import-export-data/),
"Export is **not supported for virtual tables**, including databases with virtual
tables". `drive` holds one because `migrations/0039_file_index_fts.sql` creates an
FTS5 index over `file_index`.

No Cloudflare-side path replaces an off-site copy. Time Travel restores to any
minute inside the last 30 days (7 on free) but has no clone or fork, and the
legacy snapshot backups were removed on 2025-07-01. Dropping and recreating the
index was ruled out on the issue: it stops production search writes for the
length of the export.

## The mechanism, and that it is proven

The reference implementation is `Nishfleet/drive#1090` (closed unmerged). It walks
`sqlite_master` through the D1 query API, renders every row through `quote()`, and
writes a SQL text file that carries the schema with it. Run
[40720030752](https://github.com/Nishfleet/drive/actions/runs/40720030752) ran it
against the real database, in-run, with no checked-out file:

```
drive: 8194 rows from 39 tables (+43 indexes and triggers)
waitlist-20261028.sql  1258 bytes  sha256 3b5b1db92e1e…
drive …fa7c87d72c66bd07e855fd3dfcaec20d0eba187e2dbb8b96722b14e6dba65fb5  (.age)
waitlist …4a9244ec289f181d220b886b8ee99c707206976fdcaee92ffa4037f85f167d69  (.age)
```

The same program, run against a real SQLite file carrying an FTS5 index in the
drive schema's shape, restores to the same data:

- `user: 2 rows`, `file_index: 1203 rows`, `1205 rows from 2 tables (+1 indexes and triggers), 1 virtual table(s) left to the migrations`, `dump bytes: 75188`
- all values byte-exact through SQLite's own `quote()`: `9007199254740993` as `INTEGER` (past 2^53, which JSON would round), `00FF10EF` as `BLOB`, `quote''here`, `NULL`
- no `CREATE VIRTUAL TABLE`, no FTS shadow table (`file_search_data|idx|content|docsize|config`), no `_cf_KV`
- the restored index answers `MATCH`: replaying the migration's own `CREATE VIRTUAL TABLE` + rebuild populates `file_search`, and `SELECT … WHERE file_search MATCH '1203'` returns 1 row
- the delivered dump replays through the **existing** restore path's exact invocation, `sqlite3 -safe -bail`, and the counts survive: `user=2 file_index=1203`

Three design points make that work, and each matters for a restore:

1. **Values travel as SQLite's own text.** Every value leaves the database through
   `quote(col)`, so a blob is `X'00FF10'` and an INTEGER past 2^53 is exact. D1's
   JSON boundary represents numbers as JavaScript doubles, so reading `row[col]`
   directly would silently round large ids.
2. **Derived data is not dumped.** A virtual table and the triggers that write
   into it are left to the migration that creates them; `_cf_KV` (D1 internal) is
   never dumped.
3. **The schema travels with the data.** Without `CREATE TABLE`, a dump restores
   into an empty file.

## What still has to be fixed before adoption

The mechanism works, and it is not yet a backup anyone should trust. These are the
limits a review of the implementation found, in the order they bite:

- **Triggers and indexes are created before the rows are inserted.** The script
  emits every `CREATE TRIGGER` in the schema block, then replays rows, so on
  restore every non-FTS trigger fires per row: an audit, counter or `updated_at`
  trigger duplicates rows or rewrites values, and a UNIQUE conflict aborts the
  restore under `-bail`. Indexes and triggers belong after the data.
- **`sqlite_sequence` is not dumped**, so an `AUTOINCREMENT` table restarts at
  `max(rowid)+1` and can reuse the ids of rows that were deleted.
- **Paged reads are not one snapshot.** Each table is read in pages through
  separate HTTP queries, so a write during the dump yields a copy that never
  existed, for example a child row without its parent. The restore runs with
  `foreign_keys=OFF`, so nothing catches it.
- **Two table shapes fail loudly, not silently.** A `WITHOUT ROWID` table breaks
  the `SELECT rowid` paging, and a table with generated columns breaks the
  `SELECT *` → `INSERT` round trip. Both should be named limits or handled.
- **Only databases without a virtual table can use the stock export.** A repo whose
  databases are mixed needs both paths: the engine-made dump for most, this one
  for the FTS database.

## Which repository holds it

The issue's own conclusion holds: it cannot be a per-repo dump program, because
every candidate repo holds workflow code to a net-zero ratchet.
`Nishfleet/drive#1090` was written that way — +124 net code lines — and
`ratchet / ratchet` is a required check on `drive` and on `fleet-ops`, so it
cannot merge. `ratchet.yml` names the way out itself: "Delete as many as you add,
or build the mechanism in its own repo behind an official extension point."

The official extension point is a reusable workflow (`uses:`). Its homes, checked
2026-10-29:

| home | state |
|---|---|
| `Nishfleet/shared-workflows` | **archived**, read-only. This is the fleet's "defined once" reusable-workflow repo, and every consumer still resolves `deploy-production.yml@v1` from it, but no new workflow can be added. |
| `Nishfleet/fleet-ops` | reusable workflows do live here (`ratchet.yml` is called by 0509), but `ratchet / ratchet` is required on `main` and counts `.github/workflows`: this workflow is +243 net code lines. |
| `Nishfleet/drive` | same required check, same count. |
| this host (a systemd unit next to `fleet-d1-restore-drill`) | the drill's own test forbids the D1 API anywhere in its body, and every agent lane here runs in a jail that mounts an empty tmpfs over `~/.config/cloudflare` — the dump needs the API and the token, so neither is reachable from a lane. |

A copy parked in `template/` would be code nothing runs, kept where the ratchet
does not count it. That is the gate's loophole, not its answer, so no such file is
in this change. The missing step is a repository that can hold a new workflow:
unarchive `shared-workflows`, or create the repo that replaces it. No fleet lane
performs that step, so it is filed as its own parked item.

## Adoption, in order

1. The hosting repo exists, and the program lands in it as
   `.github/workflows/d1-backup.yml` with the fixes above.
2. `Nishfleet/drive`'s `d1-export.yml` calls it: the six matrix rows, the
   environment and the schedule stay, the inline mechanism leaves. Only that
   shape keeps drive's ratchet at zero while it gains the dump — drive#1090
   added the new path without deleting the poller it superseded, which is what
   made it +124.
3. Flip drive's row to the dump path. Its artifact appears as
   `d1-backup-drive`, which is what `fleet-d1-restore-drill` already looks for, so
   the monthly drill restores it with no change of its own, and drive#1027 closes
   on a green weekly run.

## Not in this change

- `fleet-ops#10829` (each product database's backup in its own repository) stays
  parked: the four product databases keep their rows in drive's matrix until each
  product repo holds its own export credential.
- Customer-data deletion and production D1 migration stay process-gated; nothing
  here deletes or migrates anything.
