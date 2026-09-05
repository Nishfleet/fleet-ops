Fix the residual "alert-repair run hop stalled" component of FleetEscalationStorm (#3349) — a duplicate family of #3180 whose pi-issue@* fix already landed (#3579).

## What was broken

`fleet_escalations_24h` (in `libexec/fleet-metrics-export.py`) counts every
`unit-escalation@<failed-unit>` START that is not inside the exclusion list.
After #3579, `pi-issue@*` and `*-repair@*` are excluded. But the
`alert-repair-*` units use a hyphen separator, so they escape the
`*-repair@*` glob (verified: `fnmatch('alert-repair-FleetMainRed-…', '*-repair@*') == False`).
Each live alert-repair run hop still counts toward the storm metric — the
exact "alert-repair run hop stalled=1" component named in #3349's body.

Live evidence (this VPS):

- `journalctl --user -u unit-escalation@alert-repair* --since "24 hours ago"` shows
  10 `alert-repair-*` starts in 24h, each landing in `fleet_escalations_24h`.
- Current live `sum(fleet_escalations_24h)` = 51 (below the 300 threshold);
  `FleetEscalationStorm` is not in the live alertmanager firing set.
- Current `/var/lib/prometheus/node-exporter/fleet.prom` lists
  `alert-repair-FleetMainRed-*` etc. with value 1 — recovery hops miscounted as
  flapping-worker escalations.

## The fix

Add `alert-repair-*` to the `_escalations_24h()` exclusion globs, alongside the
existing `*-repair@*` recovery-machinery entry, and lock it in the #3180
drift-lock regression in `tests/fleet-metrics-export.test.sh` so the glob cannot
silently re-drift again.

## Verification

- `bash tests/fleet-metrics-export.test.sh` → rc=0, 104 `OK:` lines, including
  "12 writer-refused globs replayed through _escalations_24h — none counted;
  control counted once".
- Direct live-style repro: injected one `alert-repair-FleetMainRed-…` START and
  one `alert-repair-SustainedLoadHigh-…` START plus `pi-issue@*` and
  control `pi-intake@ctlrepo`; `_escalations_24h()` now returns only the
  control (`{'pi-intake@ctlrepo': 1}`), all three recovery/refused classes excluded.
- `sgscan` → "No new security findings."
- crgate → not signed in on this host (`coderabbit auth login` needed); sgscan
  + the full exporter suite are green in its place. Greptile and autoreview run
  on the PR as normal.

## Mechanical prevention

This is a detector-fix; the mechanism shipped is the drift-lock regression
extension: it replays `alert-repair-*` through the real filter and asserts none
count, so the exclusion cannot drift again the way `pi-issue@*` did before
#3180.

net-positive-because: two exclusion globs and two test lines permanently stop
alert-repair recovery hops from inflating the escalation-storm signal.

Fixes #3349 (family of #3180, already resolved at the pi-issue@* source by #3579).
