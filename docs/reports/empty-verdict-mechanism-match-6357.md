# Empty-verdict mechanism match for #6357

Issue #6357 asks for two changes inside the audit machinery after
`pi-escalation-audit@fleet-ops--6236--senior.service` exited 1 with an empty
verdict three consecutive times on 2026-09-13 (chain ae0681d0c947,
StartLimitBurst exhausted 14:25:41):

1. keep the third strike's combined auditor output so a 3x-empty vote is
   diagnosable post-hoc, and
2. write a storm-tolerant SKIP vote on the third consecutive empty verdict
   instead of burning StartLimit.

The match is the 2026-09-18 sweep: the organ that could produce the failure
mode no longer exists. No new code is needed.

## Mechanism

The failure mode lived in two organs, both retired:

- `bin/pi-escalation-audit` + `pi-escalation-audit@.service` (the #234
  senior panel that ran the failing unit) — deleted by 9f0cba02c
  `chore(glue-sweep): delete escalation-tower (16948 lines, Jev 0.87)`,
  merged 2026-09-18.
- `bin/pi-audit-run` + `bin/pi-audit-tally` + `pi-audit@.service` +
  `pi-audit.slice` (the #146 scout-candidate panel holding
  `extract_verdict` and the evidence-deleting EXIT trap) — kept by the
  glue sweep, then removed by d02760b53 and finished by 3c3d74443
  `chore(second-cut-B): finish the pi-audit panel removal — registries,
  gates, CI` (Jev p(delete)=0.66), merged 2026-09-18.

With no verdict extractor, no vote writer, and no launcher left, a
consecutive-empty-verdict streak cannot occur: there is nothing to
produce the empty verdict, nothing to delete its evidence, and no chain
to stall.

## Prior work on this issue

Commit be77a773c (`fix(audit): keep + SKIP on the 3rd consecutive empty
verdict`) on `wip/pi-issue-fleet-ops-6357-20260914T002417Z` implemented
both suggested fixes in `bin/pi-audit-run`; PR #6619 was armed
2026-09-14T00:19:32Z and closed unmerged with its head deleted by worker
automation on 2026-09-17T14:47:35Z. The salvage cannot be re-applied:
every file it touched is deleted on current `origin/main` (cherry-pick
reports modify/delete conflicts on `bin/pi-audit-run` and
`tests/pi-audit-run.test.sh`).

## Verification

On 2026-09-20, at `origin/main` b86925bea:

- `git merge-base --is-ancestor` confirms 9f0cba02c, d02760b53 and
  3c3d74443 are ancestors of `origin/main`.
- `git grep pi-audit origin/main` outside docs/bench fixtures: no hits;
  no file in `bin/`, `lib/`, `systemd/` or `.github/` instantiates the
  lane.
- Live host: `~/.config/systemd/user/` holds no `pi-audit` or
  `pi-escalation-audit` unit files; `systemctl --user list-units
  --state=failed` is empty; only the cgroup artifacts
  `app-pi-escalation-audit.slice` and `app-unit-escalation.slice` remain.
- Journal shows the last `pi-audit@` execution was a PASS vote for
  0509/#2952 at 2026-09-18 07:53 UTC, hours before the removal commits.

## Disposition

Match #6357 to the sweep deletions 9f0cba02c / d02760b53 / 3c3d74443.
The requested fixes are moot: the empty-verdict drop-point and the
chain-stall path were retired with the organs that contained them. No
new detector, unit, configuration, or runtime code is required. This
report supplies the resolution record, not a repair.
