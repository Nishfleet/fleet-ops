# Plan — fleet-ops#5001: trailing-window SQL compares ISO TEXT against datetime('now')

Manager mode (heavy), fleet-ops#3274. Plan lineage: the stock planner wrote 6
phases; the manager amended that to 4 (phases 1-3 of the planner's list are one
atomic edit set over the same two files, so they run as one phase — the manager
may amend the plan with a one-line reason).

Resume note (session-pickup, 2026-09-10): this unit's prior run crashed
(StartLimitBurst x3) after banking phase 1 via `bin/pi-salvage-worktree`. The
claim branch `claim/issue-5001` held a salvage commit with phase 1's edit. The
claim names this unit, so the branch was reused: it was re-based onto current
`origin/main` and only the two hunk-sets of phase 1 were re-applied (the
salvage commit also carried an unrelated `deepseek-v4-flash` -> `<retired-V4-flash>`
model-name revert from a stale base; that was dropped, not shipped).

Defect (reproduced): the four predicates compare an ISO-8601 TEXT column
(`user.createdAt`, `delivery_attempt.sent_at`) against SQLite's
`datetime('now','-N days')` (space-separated, no `Z`). SQLite compares TEXT, so
every row on the cutoff CALENDAR DAY counts as inside the window — a 29-hour-old
row reads as "last 24h".

## Phases (acceptance-driven)

- [x] phase 1: every window comparison parses both sides — `julianday(<col>) >= julianday('now','-1 day')` / `'-7 days'` for all four predicates, changing no other predicate, token handling, ID validation or the absent-not-zero contract (accept #1 + #2)
- [x] phase 2: `tests/fleet-product-slo.test.sh` boundary scenario through the existing mocked D1 seam — fixture rows 25h / 23h / 8d / 6d23h old, `fleet_product_signups_24h` counts only the 23h row, every existing scenario kept (accept #3 + #5)
- [x] phase 3: `tests/fleet-metrics-export.test.sh` mirror boundary scenario for `_S7_SQL` — 8d excluded, 6d23h included (accept #4 + #5)
- [x] phase 4: no new timer/unit/service/MANIFEST/token, no threshold change; both suites + `promtool` green; `git diff` touches only the two lib files and the two test files (accept #6)

## Phase detail

- p1 files: `lib/fleet-product-slo.py` (`_D1_QUERIES`: `signups_24h` :1079,
  `activated_24h` :1087, `briefs_delivered_24h` :1098),
  `libexec/fleet-metrics-export.py` (`_S7_SQL` :1650).
- p2 file: `tests/fleet-product-slo.test.sh` — new scenario after (o).
  Seam: the real literals go out over `urllib.request.urlopen` (module-level
  `urlopen` in `lib/fleet-product-slo.py`); the existing mock replaces
  `m.urlopen`. The boundary runs the CAPTURED real SQL against an in-memory
  `sqlite3` DB seeded with fixture rows, so no network and no fabricated 0.
- p3 file: `tests/fleet-metrics-export.test.sh` — the `fleet_signups_7d` block
  (16d, ~4290-4360). Same shape: `_S7_SQL` run against an in-memory `sqlite3`
  DB with rows 8d and 6d23h old.
- p4: `bash tests/fleet-product-slo.test.sh && bash tests/fleet-metrics-export.test.sh`,
  `promtool check rules config/fleet_rules.yml`.

## Reviewer rounds

- Phases 1-3 were implemented by this unit's prior crashed runs and banked via
  `bin/pi-salvage-worktree`; this run (manager) rebased the claim branch onto
  origin/main b581df4ca — which had meanwhile landed fleet-ops#5000 (a fifth
  `_D1_QUERIES` entry, `table_census`, plus census scenarios (p)/(q)/(r) in the
  same test file) — resolved the collision by keeping both and relabelling the
  boundary scenario to (s), updated its fake-D1 seam to return real column
  names (the census query needs named columns, not `{"n": ...}`), seeded the
  three census-only fixture tables, and made the capture-count assert read
  `len(m._D1_QUERIES)` instead of a hard-coded 4.
- Manager whole-diff review after rebase: all four predicates parse both
  sides via `julianday()`; no other predicate, token handling, ID validation
  or absent-not-zero contract touched; `grep -rn "datetime('now'" lib
  libexec` returns nothing outside the julianday form. Boundary tests pin the
  shipped SQL literals against an in-memory sqlite3 fixture (25h excluded /
  23h included for the 24h gauges; 8d excluded / 6d23h + an older
  cutoff-calendar-day row handled for `_S7_SQL`), with a guard asserting the
  pre-fix TEXT predicate really would miscount on the same fixture.
- Verification (this worktree, post-rebase):
  `bash tests/fleet-product-slo.test.sh` — green incl. "(s) 24h boundary";
  `bash tests/fleet-metrics-export.test.sh` — exit 0, 230 OK lines incl.
  "fleet-ops#5001: signups_7d trailing-7d SQL parses both sides";
  `promtool check rules config/fleet_rules.yml` — SUCCESS, 107 rules;
  issue's sqlite3 probe prints `1|0` (TEXT compare wrong, julianday right).
