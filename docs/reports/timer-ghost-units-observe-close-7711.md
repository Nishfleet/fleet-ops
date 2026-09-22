# Observe-close for #7711 — ghost timer signals, resolved by the organ deletions; regression gate is a CI step, not a tests/ file

Second resolution record. The first (#8171) carried the same analysis —
the grade confirmed it sound — plus a `tests/timer-ghost-signal.test.py`
guard that asserted implementation, not behaviour, and was reverted in
#8228. This record ships the same resolution with the guard rebuilt as
the only mechanism the post-sweep rules allow: a required-check step in
`.github/workflows/ci.yml` (the `ci` job). `no-glue` (same file) keeps
`tests/` deleted and bars new `*.py`/`*.sh` anywhere, so a test file
cannot exist — the gate is the executable artifact.

Issue #7711 (filed 2026-09-18, from the 2026-09-18T09:06Z capped-signal
list) asked for three things: fix the stale unit inventory emitting
`loud/timer-no-next/0509.timer` and `loud/timer-no-next/fleet-ops.timer`
every tick, decide `0509-digest-headline-ratio-guard.timer` into the
manifest or the unmanaged list, and add a check that no emitter alarms on
a unit that fails `systemctl --user cat`.

## What the ghost signals actually were

The issue hypothesized a stale unit inventory. The real chain, re-read
from history:

1. **Emitter: `bin/fleet-heartbeat-tier1` block 5** ("VERIFY SCOUT /
   INTAKE TIMERS ARMED"). It built `verify_timers` from
   `config/intake-repos.json` as `pi-scout@<repo>.timer` /
   `pi-intake@<repo>.timer`, checked `is-enabled` +
   `NextElapseUSecRealtime`, and raised `TIMER-NO-NEXT` on any enabled
   timer with no next firing (the NextElapse false-positive loop is
   sibling #7710's scope, observe-closed at
   `docs/reports/timer-arm-no-next-emitter-swept-observe-close-7710.md`).
   Deleted in `ca33faa96` ("refactor(rail): the unit IS the worker —
   collapse intake/worker/scout to pi --print", 2026-09-18 16:39 IST).
2. **The ghost keys were a parsing artifact, not a stale inventory.**
   `lib/detector-queue-reconciler.py::_extract_signal_key` harvested
   signal keys with `FILE_RE = [A-Za-z0-9_.-]+\.(...|timer|...)` — a
   class with no `@`. Applied to a real loud line naming
   `pi-intake@0509.timer`, the word boundary after `@` yields the key
   `0509.timer`. `loud/timer-no-next/0509.timer` and
   `loud/timer-no-next/fleet-ops.timer` were real template instances
   with their `pi-intake@`/`pi-scout@` prefixes stripped by the
   harvester. The reconciler (and its SIGNAL-RECONCILE-CAP unfiled list
   the issue cites) was deleted in `a437f7be6` ("chore(second-cut-B):
   delete the fleet-state reconcilers…", 2026-09-18 16:47 IST).
3. **`timer-manifest/0509-digest-headline-ratio-guard.timer`** was
   `bin/fleet-timer-manifest-drift-canary`'s `TIMER-MANIFEST-DRIFT` loud
   for a live unmanaged timer — deleted in `ada87b543` ("chore(glue-
   sweep): delete canary-fleet", 2026-09-18 15:43 IST). The manifest pair
   it read (`systemd/timer-manifest.json`,
   `config/timer-manifest-unmanaged.json`), `tests/timer-manifest.test.sh`
   and `bin/fleet-ops-drift.py` went out in `f8b567588` / `72b38e857`,
   all 2026-09-18, all ancestors of origin/main (`1359397b2`).

## Fresh live verification (2026-09-22 ~11:12 IST, netcup-rs2000)

| Check | Result |
|---|---|
| `systemctl --user is-enabled 0509.timer fleet-ops.timer` | `not-found` both — the ghosts are gone, not just skipped |
| `systemctl --user list-unit-files --type=timer` | 12 rows, zero ghost names; the only `0509`/`fleet-ops` hits are `pi-intake@0509.timer`, `pi-intake@fleet-ops.timer`, `pi-scout@fleet-ops.timer` — real template instances (`pi-scout@0509.timer` no longer exists either) |
| `~/.config/systemd/user/timers.target.wants/` | 8 symlinks, all resolve into the deploy clone's `systemd/`; no dangling bare `0509.timer`/`fleet-ops.timer` entries |
| `systemctl --user cat 0509-digest-headline-ratio-guard.timer` | `No files found`, rc=1 — the timer no longer exists live |
| `systemctl --user list-timers --all` | 9 live timers, none named digest-headline, none named fleet-heartbeat |
| `journalctl --user --since 2026-09-18` | no `timer-no-next`, `TIMER-MANIFEST` or `SIGNAL-RECONCILE` rows — the only hits are worker transcripts quoting the names |

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
  replacement is out of scope"). The issue's `verify:`/`termination:`
  blocks name `tests/timer-manifest.test.sh` and the manifest configs —
  all deleted; the live systemctl halves of both blocks are run above
  and pass.

## Acceptance mapping

| Bullet | Resolution |
|---|---|
| Fix the emitting pass to resolve names and skip ghosts | The emitting pass, the reconciler that keyed the ghosts, and the manifest canary are all deleted; nothing emits the signals and the journal is clean. There is no inventory left to keep accurate. |
| Decide the digest-headline guard (a)/(b) | Moot — the timer is absent live and its guarded module is deleted; no manifest exists to join. Documented above. |
| Test under tests/ for ghost-keyed signals | Substituted, with the reason on the record: `no-glue` (ci.yml) keeps `tests/` deleted and bars new `*.py`/`*.sh`, so the assertion ships as the required-check step "No timer-inventory signal emitters on committed surfaces" in the same file. It greps every emitting surface (`prompts`, `systemd`, `etc`, `config`, `template`, `patches`, `.github`, `credentials`, `AGENTS.md`, `README.md`) for the signal family names and fails the check on any match — a reintroduced emitter must amend the gate in the same PR. A code emitter cannot return at all (no-glue bans the file); the gate covers the remaining emission paths. |

What the gate does and does not prove, stated exactly: it asserts the
signal family is carried by no committed emitting surface — an output
token, not a mechanism, so it cannot be satisfied by a comment naming a
resolution call and does not prescribe how a future emitter must resolve
units. It has no skip path (grep's exit code is the verdict) and no
uncounted checks. It does not prove a hypothetical emitter would skip
ghosts at runtime — it makes the emitter's return a deliberate,
review-visible act, which is the strongest assertion available while the
family is extinct by design.

## Verification

- The gate command run against this PR's tree:
  `grep -rEin --exclude-dir=.git --exclude-dir=.fleet --exclude-dir=docs 'timer-no-nex[t]|timer-manifes[t]' AGENTS.md README.md prompts systemd etc config template patches .github credentials` → rc=1, clean.
- Negative drill: a planted file under `prompts/` carrying a family name
  makes the same command print the file and exit the gate's failure
  path; removing it returns rc=1.
- Deletion ancestry: `git merge-base --is-ancestor` → yes for
  `ca33faa96`, `a437f7be6`, `ada87b543`, `f8b567588`, `72b38e857`
  against origin/main `1359397b2`.
- Live probes in the table above, all run this run.

## Residual note

No follow-up filed: there is no emitter, inventory, or manifest left to
keep accurate, and the only real-unit question the ghost keys pointed at
(an enabled template timer reporting empty `NextElapseUSecRealtime`
mid-run) is #7710's scope, already observe-closed. If a timer-inventory
pass ever returns it arrives as a deliberate change — the file is banned
by `no-glue` and the family name on any emitting surface fails `ci`.
