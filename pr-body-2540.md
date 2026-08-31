## Why

fleet-ops#2469 (PR #2511) will retire corpse seat ledgers into dated
`seats-corpse-retired-<UTC-ts>/` dirs that are **append-only** — the
retirement bin never deletes them; they are the post-mortem audit trail for
corpse-seat terminations (c=150/dead=true/class=corpse ledger preserved for
forensic review). With no GC organ the dir count grows unbounded: observed
2026-08-31, **9 `seats-corpse-retired-*` dirs in 5h18m**, created by test
invocations of the not-yet-deployed bin alone. A test loop or hot patch can
fan out 1000s of dirs in minutes; the fleet had no scheduled deletion path
and no detector for the class. This PR ships that GC organ.

## What changed

- **bin/fleet-seat-corpse-retire-gc** (new): daily GC that prunes
  `seats-corpse-retired-*` dirs strictly older than a 30-day retention
  floor (the post-mortem window, same as the deadcred-quarantine GC class),
  with a **hard guard that never deletes anything newer than 30d regardless
  of count** (the audit window wins). `--dry-run` reports without deleting;
  `--max-dirs N` (default 10) is a stop-gap cap that only emits a LOUD
  journal line on bursts and never force-prunes. Idempotent: a clean sweep
  is a no-op, exit 0. A failed prune exits 1 (systemd fails the run).
- **systemd/fleet-seat-corpse-retire-gc.{service,timer}** (new): daily
  oneshot at 04:45 UTC, 10 min after PR #2511's planned 04:30 UTC retire
  slot; `Persistent=true` (a missed day is caught up), `RandomizedDelaySec=5min`.
- **config/fleet-organs.json**: register the new organ.
- **config/fleet_rules.yml**: `FleetSeatCorpseRetireGcAbsent` — 48h "two
  missed daily cycles" absent() threshold, matching the baseline-delta /
  asset-census doctrine (promtool: 57 rules, SUCCESS).
- **lib/role-quality-gates.py**: `fleet-seat-corpse-retire-gc` joins
  NON_ROLE_UNIT_PREFIXES (pure directory GC — no model, no prompt, no work
  items, same shape as fleet-seat-comeback-release).
- **MANIFEST**: install entries for bin + service + timer.
- **tests/fleet-seat-corpse-retire-gc.test.sh** (new, 8 hermetic scenarios),
  hosted from tests/fleet-seat-recovery.test.sh (already in P14) with a
  named pin in tests/p14-test-listing-gate.test.sh (the #2462 pattern).

Metric (written every run, no-op sweeps included, so the absent() rule
catches a missing file):
`fleet_seat_corpse_retire_gc_last_run_seconds` +
`fleet_seat_corpse_retire_gc_total{dir="seats-corpse-retired",outcome="scanned|kept|pruned"}`.

## Mechanics

Failure-fix class (fleet-ops#366): the prevention mechanism is the GC organ
itself — a daily timer + loud absent() rule + 30d hard guard, plus the
hermetic regression test (host + named pin) and the over-cap LOUD line. A
future resume of unbounded dir growth is detected by
`FleetSeatCorpseRetireGcAbsent` and bounded by the cap's loud line; the
regression test proves the guard fires.

## Verification

- `bash tests/fleet-seat-corpse-retire-gc.test.sh` → exit 0, all 8 scenarios
  green (empty→noop, 3 fresh→noop, 3 stale→pruned, mixed→only stale pruned,
  --dry-run deletes nothing, over-cap 10→stale pruned + fresh kept + LOUD
  line, metric shape, unit shape).
- Host regression: `bash tests/fleet-seat-recovery.test.sh` → exit 0.
- `bash tests/p14-test-listing-gate.test.sh` → exit 0 (named pin green, P14
  list closed).
- `bash tests/ci-standards-audit.test.sh` → exit 0.
- `bin/fleet-organ-heartbeat-check verify` → exit 0, **21/21 organs** have an
  absent() rule (seat-corpse-retire-gc included).
- `promtool check rules config/fleet_rules.yml` → SUCCESS, 57 rules.
- **Live run of the deliverable** against the real 9-dir set (no dir > 30d
  old → all kept):
  ```
  $ bash bin/fleet-seat-corpse-retire-gc
  [2026-08-31T14:41:39Z] [fleet-seat-corpse-retire-gc] sweep complete: scanned=9 kept=9 pruned=0 (root=/home/nish/workspaces/agent-state/lanes, retention=2592000s, cap=10)
  ```
  → `ls -d .../lanes/seats-corpse-retired-* | wc -l` still 9 (nothing pruned;
  all fresh), and
  `/var/lib/prometheus/node-exporter/fleet-seat-corpse-retire-gc.prom`
  contains `fleet_seat_corpse_retire_gc_last_run_seconds 1788187299` and
  `fleet_seat_corpse_retire_gc_total{...outcome="scanned"} 9` /
  `{...outcome="kept"} 9` / `{...outcome="pruned"} 0`.
- `sgscan` on the diff → no new security findings.

run-proof: real systemd one-shot of the shipped unit files (name-swapped
drill), started via `systemctl --user` against the live dir set:
```
$ systemctl --user start fleet-seat-corpse-retire-gc-drill.service
$ systemctl --user show ... -p ActiveState -p Result -p ExecMainStatus
ActiveState=inactive  Result=success  ExecMainStatus=0
$ journalctl --user -u fleet-seat-corpse-retire-gc-drill.service -o cat
Starting ... - Daily GC of seats-corpse-retired-* audit dirs (fleet-ops#2540)...
[2026-08-31T14:42:59Z] [fleet-seat-corpse-retire-gc] sweep complete: scanned=9 kept=9 pruned=0 (root=/home/nish/workspaces/agent-state/lanes, retention=2592000s, cap=10)
Finished ... - Daily GC of seats-corpse-retired-* audit dirs (fleet-ops#2540).
```

research: last-30-days-scale pass (live search across merged fleet-ops PRs these 30d + the repo's existing GC organs) compared the proven options and why they lost or were adopted — (1) fleet-worktree-reaper (fleet-ops#2227, daily `git worktree remove` GC with 4 gates) is a DIFFERENT class (agent worktrees, not seats-corpse-retired dirs) and was rejected as the host for this GC; (2) the deadcred-quarantine GC sweep class and (3) the fleet-seat-corpse-retire retirement bin (PR #2511) are append-ONLY producers that never delete their own dirs, so neither can GC them; (4) `find -mtime +30 -exec rm -r` is a shell incantation, not a maintained bin. None GCs the seats-corpse-retired-* dirs, so a new organ (new dir class + name + retention window) was built — adopting the fleet-worktree-reaper shape (daily timer + oneshot bash bin + heartbeat + absent() rule + regression test + named pin) as the proven rails.

help-first: ran `bin/fleet-seat-corpse-retire-gc --help`, `bin/fleet-worktree-reaper --help` and `bin/fleet-seat-corpse-retire --help` (PR #2511's retirement bin, the append-onLY producer) — and no existing tool does this GC: fleet-worktree-reaper only GCs git worktrees (not the retirement dir class), fleet-seat-corpse-retire explicitly never deletes its own dirs (they are the audit trail), and there is no maintained bin that enforces the 30d retention floor + hard guard + --max-dirs cap, so the small durable organ was built rather than hand-overriding a tool that does not already do it.

Closes #2540
