# Observe-close for #7511 — timer-manifest stale records, resolved by the registry's own deletion

Issue #7511 (filed 2026-09-17T18:06:23Z) asked for a follow-up to the #7461
timer audit: correct stale `systemd/timer-manifest.json` records for
`vault-conflict-resolver` and `fleet-deploy-check`, reconcile the audit's
four live-only records against a fresh inventory, check the deprecated
fleet2 and repair-template pseudo-timer records against installed units,
and re-run the manifest test plus drift canary.

By the time the claim ran (2026-09-21), every target the issue names was
already deleted from main. The manifest, the two units whose descriptions
were stale, the test, the canary drill host, and the audit report itself
all went out in the 2026-09-18 glue sweep — one day after the issue was
filed. No new code is needed; this report is the resolution record, with
the fresh-inventory reconciliation the acceptance bullets asked for.

## What was found

1. **The registry is deleted.** `f8b567588` ("cut(rule-enforcement):
   delete the rule matrix, the rule renderers and the timer registry",
   2026-09-18) removed `systemd/timer-manifest.json` (89 records at the
   audit's source commit `0b5c34270`, 63 by deletion day),
   `config/timer-manifest-unmanaged.json`, `tests/timer-manifest.test.sh`
   (274 lines) and its `ci.yml` step. Recorded rationale: the manifest's
   only live reader was fleet-heartbeat-tier1 block 47, deleted in an
   earlier cut, and every unit already carries its named reason in its
   own header comment. `git merge-base --is-ancestor f8b567588
   origin/main` passes at origin/main `dc7efe3e5`.
2. **The vault-conflict-resolver mechanism is deleted, not just
   mis-described.** `efaa7fa57` ("cut(memory-vault): delete the memoryctl
   loop, the vault linters and their units", 2026-09-18T18:02Z) removed
   `systemd/vault-conflict-resolver.{path,timer,service}`,
   `lib/vault-conflict-resolver.py` and its test. The audit's prior-art
   reading was accurate — the `.path` unit was the event trigger
   (`PathExistsGlob=.../nish-vault/*.sync-conflict-*`) and the 10-min
   `.timer` was the documented dead-man backstop for deep directories the
   non-recursive glob cannot see — but there is no manifest left to
   correct and no unit left to describe. The standing-rule freeze check
   on `*.sync-conflict-*` survives as an agent rule, not a unit.
3. **The fleet-deploy-check cluster is deleted; its cadence survives in
   the replacement.** `72b38e857` ("cut(deploy): delete the
   copy-then-detect-drift deploy cluster; one linked-unit sync timer
   replaces it", 2026-09-18T18:33Z) removed `bin/fleet-deploy-check`
   (724 lines), `systemd/fleet-deploy-check.{service,timer}` and its
   1069-line test. The manifest's promised path conversion was already
   doubly dead — the `.path` unit had been removed earlier per #2123
   (git ref renames self-retriggered it), and the service's own header
   said the 2-min timer was deliberate. `systemd/fleet-sync.timer` now
   carries that cadence: `OnCalendar=*:00/2`, with a header stating
   "Same cadence as the fleet-deploy-check.timer it replaces" — the
   documented recovery schedule the issue asked to keep.
4. **The audit evidence file is deleted.** `reports/
   timer-audit-2026-09-17.jsonl` went out with the rest of `reports/` in
   `1ae2704cc` (glue sweep, #8076). It remains readable in history at
   `1ae2704cc^:reports/timer-audit-2026-09-17.jsonl` — all rows below
   were re-read from that blob.
5. **No live reference remains on main.** Grep over origin/main
   (`dc7efe3e5`) for `timer-manifest`, `timer_manifest` and
   `timer-audit` hits only `.fleet/bench7371/` fixtures and historical
   observe-close docs under `docs/reports/` — no code, config, workflow
   or unit references the registry.

## Fresh-inventory reconciliation (2026-09-21T20:22:40Z, netcup-rs2000)

`systemctl --user list-timers --all` shows 9 live user timers:
`fleet-sync`, `fleet-metrics-export`, `pi-intake@0509`,
`pi-intake@fleet-ops`, `launchpadlib-cache-clean`,
`systemd-tmpfiles-clean`, `pi-scout@fleet-ops`, `daily-digest`,
`fleet-gardener`. The audit's four live-only records reconcile as:

| Audit live-only record | Fresh state | Disposition |
|---|---|---|
| `launchpadlib-cache-clean.timer` | still live (next 2026-09-22 03:40 IST, Persistent=no) | OS-owned package cleanup (launchpadlib). Correctly excluded from the fleet manifest; exclusion now documented here. |
| `systemd-tmpfiles-clean.timer` | still live (next 2026-09-22 03:40 IST, Persistent=no) | OS-owned user tmpfiles cleanup. Same exclusion. |
| `0509-digest-headline-ratio-guard.timer` | **absent** — no unit file, not in list-timers | The product digest guard was retired between the audit snapshot and this inventory; nothing to add. |
| `restart-fleet-ops-intake-after-quota.timer` | **absent** | The one-shot quota-reset timer fired and released as designed (Persistent=no); `pi-intake@fleet-ops.timer` is live and ticking (last trigger 2026-09-22 01:46 IST). Expired one-shot, documented. |

## fleet2 and repair-template pseudo-timer records

- `fleet2-digest.timer`, `fleet2-dispatch.timer`, `fleet2-events.timer`
  (all "DEPRECATED" records): zero `fleet2-*` unit files exist on the
  host — `systemctl --user list-unit-files` and
  `~/.config/systemd/user/` both return nothing. Proven stale; removed
  with the manifest.
- `pi-intake-repair@.timer`, `pi-scout-repair@.timer` and the 16
  instantiated `pi-*-repair@<repo>.timer` records were pseudo-records —
  no `.timer` file ever existed for them in the repo (`systemd/` holds
  only `pi-intake-repair@.service` / `pi-scout-repair@.service`) or on
  the host (`list-unit-files` shows the two repair **services** linked
  and enabled, no repair timers). The live repair path is alert-driven:
  `config/fleet_rules.yml` severities route to `prometheus-am-executor`,
  which runs `prompts/alert-repair.md` on `worker-cheap` — no
  `OnFailure=` wiring to repair units exists on `pi-intake@.service` /
  `pi-scout@.service` today (the issue templates' `OnFailure=
  pi-issue-failed@%i.service` is a different chain). All records removed
  with the manifest; the machinery they pointed at is intact.

## Why the acceptance arms do not apply as written

Every accept bullet targets `systemd/timer-manifest.json`, which does not
exist. "Correct the records" and "remove only proven stale records" are
both subsumed by `f8b567588`: the file and its readers are gone, which
is a stronger resolution than per-record edits. "Run the existing timer
manifest tests and drift canary in their documented modes" is
unreachable — `tests/timer-manifest.test.sh` (which itself hosted the
timer-guard drill #4472 and the drift-canary drill #4647) and its CI
step were deleted in the same commit; the fresh inventory timestamp
above stands in as the required live citation. No live unit was deleted
or deployed by this issue, per its own scope limit.

The audit's advisory probabilities (delete ≤0.26 on every timer) never
authorized these deletions — they were separate, adjudicated glue-sweep
decisions that happened to land first.

## Acceptance verification (2026-09-21, netcup-rs2000)

| Check | Result |
|---|---|
| Deletion commits on origin/main | `git merge-base --is-ancestor` → yes for `f8b567588`, `efaa7fa57`, `72b38e857`, `1ae2704cc` (origin/main `dc7efe3e5`) |
| Manifest/test/canary presence | `find` for `*timer-manifest*` / `*timer-audit*` → zero hits at HEAD |
| Fresh inventory | `systemctl --user list-timers --all` 2026-09-21T20:22:40Z → 9 timers, table above |
| fleet2 / repair `.timer` units | `list-unit-files` + `~/.config/systemd/user/` → zero fleet2 files; repair services present, zero repair timers |
| Deploy cadence preserved | `systemd/fleet-sync.timer` `OnCalendar=*:00/2`, live and triggering (last 2026-09-22 01:52 IST) |
| No self-triggering deploy path unit | no `fleet-deploy-check.path` or equivalent in repo or host |

## Residual note

The issue carries `agent-in-progress` from the 2026-09-21 claim; this
record's PR performs the `Closes #7511` close. No follow-up is filed:
there is no manifest left to keep accurate, and the audit's delete
advisories were superseded by the sweep's own adjudicated cuts.
