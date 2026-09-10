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
- [ ] phase 2: `tests/fleet-product-slo.test.sh` boundary scenario through the existing mocked D1 seam — fixture rows 25h / 23h / 8d / 6d23h old, `fleet_product_signups_24h` counts only the 23h row, every existing scenario kept (accept #3 + #5)
- [ ] phase 3: `tests/fleet-metrics-export.test.sh` mirror boundary scenario for `_S7_SQL` — 8d excluded, 6d23h included (accept #4 + #5)
- [ ] phase 4: no new timer/unit/service/MANIFEST/token, no threshold change; both suites + `promtool` green; `git diff` touches only the two lib files and the two test files (accept #6)

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

(to be filled by the manager after each phase review)
