# Gap-audit pi-transport seam mechanism match for #7073

Issue #7073 flags a hand-performed operation — "Repair fleet stall after
vacation: pi transport clobbered, all seats poisoned" (memoryctl outcome
`outcome-20260904-065536-758759`, captured 2026-09-04T06:55:36Z) — as work
with no queued mechanism. The record's own frontmatter names its mechanism:
`derived_from`/`sources` point at
[fleet-ops#3111](https://github.com/Nishfleet/fleet-ops/issues/3111). The
"no queued mechanism issue" premise does not hold; the seam was queued,
delivered, and later retired. This report supplies the per-requirement
delivery mapping the issue's acceptance line asks for.

## Requirement-to-delivery map

#3111 was split into seven single-requirement children on 2026-09-04
(orchestrator comment on #3111, 15:14:31Z). All eight issues are CLOSED;
every delivered PR below is MERGED and its squash commit is an ancestor of
`origin/main` (`gh api repos/Nishfleet/fleet-ops/compare/<sha>...main` →
`behind_by: 0` for each; the deploy clone is shallow, so the API compare
stands in for `merge-base --is-ancestor`).

| Child | Requirement | Delivery |
|---|---|---|
| #3237 + #3243 (folded) | `pi-transport-check` self-heal without pi; `npm rebuild -g` wired as drop-in on the existing unit | [PR #3235](https://github.com/Nishfleet/fleet-ops/pull/3235) `cec6440a` merged 2026-09-04T15:11Z shipped `bin/pi-transport-self-heal` + `systemd/pi-transport-check.service.d/20-self-heal.conf`; regression test [PR #3337](https://github.com/Nishfleet/fleet-ops/pull/3337) `388a17ca` merged 17:41Z closed #3237 |
| #3238 | seat-bench writers gate on transport health; `transport-down` marker; down-window bench sweep | gate shipped in PR #3235 (`lib/seat-lib.sh`); fail-open edge fixed by [PR #3335](https://github.com/Nishfleet/fleet-ops/pull/3335) `88c9f471` merged 17:40Z; observe-to-close receipt on #3238 |
| #3239 | `pi-seat-health.json` >30 min = UNKNOWN; `seat_health_age_s` metric + alert >1800 | metric/console/rule shipped in PR #3235 (`libexec/fleet-metrics-export.py`, `libexec/fleet-console-pi/generate.py`, `config/fleet_rules.yml`); IST-parse fix [PR #3520](https://github.com/Nishfleet/fleet-ops/pull/3520) `7146d90f` merged 2026-09-05T08:03Z; `FleetPiSeatHealthStale` >1800 test pin [PR #3717](https://github.com/Nishfleet/fleet-ops/pull/3717) `50416d2d` merged 20:28Z; orchestrator close on #3239 `verified-by: orchestrator` |
| #3240 | find the clobber writer | closed by orchestrator 2026-09-04: writer identified in #3111 comment 08:09:38Z — sudo log 2026-09-03T02:58:49+05:30 shows the pi-issue worker for #2924 running `/usr/bin/install -D -m 0755 /dev/null /home/nish/.local/bin/pi` while stubbing binaries for a test; an ad-hoc session command, no committed code, nothing to build |
| #3241 | stale `cap=0` seats must expire back to default | [PR #3578](https://github.com/Nishfleet/fleet-ops/pull/3578) `3cd29a53` merged 2026-09-05T10:13Z: load model `.reason`, log undated loudly, date the live entries in `config/seat-caps.json` |
| #3244 | spawn-guard danger pattern for sudo writes into `~/.local/bin`, `~/.local/lib/node_modules`, `~/.pi`, `/etc/systemd`, `/dev/null` sources | guard drill shipped in PR #3235 (`tests/fleet-spawn-guard-sudo-write.test.sh`, `tests/tests-no-local-bin-clobber.test.sh`); wired into the rule-enforcement suite by [PR #3334](https://github.com/Nishfleet/fleet-ops/pull/3334) `57deae04` merged 17:39Z |

The acceptance's live-transport receipt also exists: the orchestrator
decision on this issue records `pi-transport-self-heal` logging
`PI-TRANSPORT-OK` at 2026-09-17T19:55:27Z — the mechanism was not only
merged but running two weeks after delivery.

## Verified live, 2026-09-21 (host netcup-rs2000)

- `~/.local/bin/pi` → symlink to
  `../lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js`;
  `pi --version` → `0.85.1`. The clobbered-binary symptom is not present.
- The transport organ itself is retired on main: `30333dccc`
  ("cut(mirrors+transport): delete git-mirror-update and
  pi-transport-check/self-heal", 2026-09-18) removed
  `bin/pi-transport-check`, `bin/pi-transport-self-heal`,
  `systemd/pi-transport-check.service.d/20-self-heal.conf` and the three
  transport tests. `systemctl --user list-unit-files` shows no
  `pi-transport-*` units.
- The rest of the delivery was retired the same week by deliberate cuts,
  not bit-rot: `lib/seat-lib.sh` left with pick_seat in `5411da097`
  (#5993, 2026-09-12, LiteLLM groups own routing now);
  `libexec/fleet-metrics-export.py` went in the 2026-09-18 exporter cuts
  (`f65e812c4`, 67 → 14 rules); `FleetPiSeatHealthStale` no longer exists
  in `config/fleet_rules.yml`; the pi spawn-guard extensions were cut in
  `7c2b2beac`.
- The clobber vector is still covered on main, in stronger form:
  `template/extensions/permission-gate.ts` (stock fork, pi 0.85.1) denies
  every `sudo` command (`/\bsudo\b/i` at line 30) — broader than #3244's
  scoped path list — and `template/extensions/protected-paths.ts` still
  guards `node_modules/` and `~/.pi/agent/auth.json`. A worker running
  `sudo install -D -m 0755 /dev/null ~/.local/bin/pi` today hits the
  blanket sudo deny.

## Disposition

Record #7073 as matched to #3111 and its children #3237/#3238/#3239/#3240/
#3241/#3243/#3244, delivered by PRs #3235, #3334, #3335, #3337, #3520,
#3578, #3717 — all merged and on `origin/main`. The flagged operation was
queued work with real acceptance receipts; the specific organs were later
retired in the 2026-09-12/18 sweeps, so the finding cannot refire against
them. The residual protection against the exact clobber vector (root sudo
write into `~/.local/bin`) is live on main today. The fuzzy duplicate
suggestions #5741/#6185/#6928 are unrelated findings sharing only the
"[gap-audit] manual seam:" title prefix and are not used as proof. This
report supplies the audit link; no new mechanism is built.
