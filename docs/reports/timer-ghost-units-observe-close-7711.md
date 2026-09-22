# Observe-close for #7711 — ghost timer signals, resolved by the sweep that deleted every named organ

Issue #7711 (filed 2026-09-18, from the 2026-09-18T09:06Z capped-signal
list) asked for three things: fix the stale unit inventory emitting
`loud/timer-no-next/0509.timer` and `loud/timer-no-next/fleet-ops.timer`
every tick, decide `0509-digest-headline-ratio-guard.timer` into the
manifest or the unmanaged list, and add a test that no emitter alarms on
a unit that fails `systemctl --user cat`.

By the claim run (2026-09-22, origin/main `07b6779a2`) every organ the
issue names was already deleted — the same 2026-09-18 sweep that
resolved sibling #7511. This record is the resolution, with the fresh
live checks the verify block asked for. A regression test ships with it
(`tests/timer-ghost-signal.test.py`); the other two bullets are resolved
by deletion and re-verified below.

## What the ghost signals actually were

The issue hypothesized a stale unit inventory. The real chain, re-read
from history:

1. **Emitter: `bin/fleet-heartbeat-tier1` block 5** ("VERIFY SCOUT /
   INTAKE TIMERS ARMED"). It built `verify_timers` from
   `config/intake-repos.json` as `pi-scout@<repo>.timer` /
   `pi-intake@<repo>.timer`, checked `is-enabled` +
   `NextElapseUSecRealtime`, and `loud "TIMER-NO-NEXT"`'d any enabled
   timer with no next firing (the NextElapse false-positive loop is
   sibling #7710's scope). Deleted in `ca33faa96` ("refactor(rail): the
   unit IS the worker — collapse intake/worker/scout to pi --print",
   2026-09-18T11:09Z), ancestor of main.
2. **The ghost keys were a parsing artifact, not a stale inventory.**
   `lib/detector-queue-reconciler.py::_extract_signal_key` harvested
   signal keys with `FILE_RE = [A-Za-z0-9_.-]+\.(...|timer|...)` — a
   class with no `@`. Applied to a real loud line naming
   `pi-intake@0509.timer`, the word boundary after `@` yields the key
   `0509.timer`. `loud/timer-no-next/0509.timer` and
   `loud/timer-no-next/fleet-ops.timer` were the real template instances
   with their `pi-intake@`/`pi-scout@` prefixes stripped by the
   harvester. The reconciler (and its SIGNAL-RECONCILE-CAP unfiled list
   the issue cites) was deleted in `a437f7be6` ("chore(second-cut-B):
   delete the fleet-state reconcilers…", 2026-09-18T11:17Z).
3. **`timer-manifest/0509-digest-headline-ratio-guard.timer`** was
   `bin/fleet-timer-manifest-drift-canary`'s `TIMER-MANIFEST-DRIFT` loud
   for a live unmanaged timer — deleted in `ada87b543` ("chore(glue-
   sweep): delete canary-fleet", 2026-09-18T10:13Z). The manifest pair
   it read (`systemd/timer-manifest.json`,
   `config/timer-manifest-unmanaged.json`), `tests/timer-manifest.test.sh`
   and `bin/fleet-ops-drift.py` went out in `f8b567588` / `72b38e857`,
   all 2026-09-18 and all ancestors of origin/main.
4. **Zero live emissions.** `journalctl --user` over the whole retained
   window (2026-09-17 onward) contains no `timer-no-next`,
   `TIMER-MANIFEST` or `SIGNAL-RECONCILE` rows — the only hits are this
   run's own transcript quoting them.

## Fresh live verification (2026-09-22T05:3x IST, netcup-rs2000)

| Check | Result |
|---|---|
| `systemctl --user is-enabled 0509.timer fleet-ops.timer` | `not-found` both — ghosts are gone, not just skipped |
| `systemctl --user list-unit-files --type=timer` | zero ghost names; the only `0509.timer`/`fleet-ops.timer` substring hits are `pi-intake@0509.timer`, `pi-intake@fleet-ops.timer`, `pi-scout@fleet-ops.timer` — real instances |
| `~/.config/systemd/user/timers.target.wants/` | 9 symlinks, all resolve; no dangling `0509.timer`/`fleet-ops.timer` entries |
| `systemctl --user cat 0509-digest-headline-ratio-guard.timer` | `No files found`, rc=1 — the timer no longer exists live |
| `list-timers --all` | 10 live timers, none named digest-headline |

## Why the digest-headline guard needed no manifest decision

Acceptance bullet 2 offered (a) repo unit + manifest entry or (b) an
unmanaged-list entry. Both targets are gone, and so is the guard itself:

- The guard watched 0509's `app/lib/digest-headline-ratio.ts` (created
  by 0509 commit `2fb551ca5`, scheduled via systemd by `920dfdf1c`).
  Nishfleet/0509 PR **#3804** ("cut(lib): delete 2 dead + 5 test-only
  modules in app/lib", merged 2026-09-20T08:36:09Z, closing 0509#3777)
  deleted that module and its tests; the 0509 repo was additionally
  wiped and rebuilt in place on 2026-09-20 (charter #3842). The timer
  vanished from the host between the issue's observation
  (2026-09-18T15:23 IST, live) and #7511's inventory
  (2026-09-21T20:22:40Z, absent) — consistent with retiring it alongside
  its subject.
- With no manifest file, no unmanaged list, and no guarded subsystem,
  neither arm has a target. Re-creating the unit would install a
  production timer guarding deleted code — the inverse of the issue's
  own scope limit ("deleting a live production timer without a
  replacement is out of scope").

## Acceptance mapping

| Bullet | Resolution |
|---|---|
| Fix the emitting pass to resolve names and skip ghosts | The emitting pass, the reconciler that keyed the ghosts, and the manifest canary are all deleted; nothing emits the signals. The skip-with-log rule is preserved as the gate below rather than prose on a corpse. |
| Decide the digest-headline guard (a)/(b) | Moot — the timer is absent live and its guarded module is deleted; no manifest exists to join. Documented above. |
| Test under tests/ for ghost-keyed signals | `tests/timer-ghost-signal.test.py` — scans every emitter surface for `timer-no-next`/`timer-manifest` family names; any emitter must carry a `list-unit-files`/`systemctl cat` resolution call, and every literal unit key it names must pass `systemctl --user cat` (templates and no-user-bus CI excluded). Vacuous-green today, bites on reintroduction. |

## Verification

- `python3 tests/timer-ghost-signal.test.py` → PASS (zero emitters; both
  enforcement arms in place).
- Deletion ancestry: `git merge-base --is-ancestor` → yes for
  `ca33faa96`, `a437f7be6`, `ada87b543`, `f8b567588`, `72b38e857` against
  origin/main `07b6779a2`.
- Live probes in the table above, all re-run this run.
- The issue's verify line names `tests/timer-manifest.test.sh` — deleted
  in `f8b567588`; the systemctl half of it is run above and the
  substituted repo check is the new test.

## Residual note

No follow-up filed: there is no emitter, inventory, or manifest left to
keep accurate, and the only real-unit question the ghost keys pointed at
(an enabled template timer reporting empty NextElapseUSecRealtime) is
#7710's scope. If a timer-inventory pass ever returns,
`tests/timer-ghost-signal.test.py` fails on the ghost-keyed-signal class.
The issue's `agent-in-progress` label closes via this record's PR.
