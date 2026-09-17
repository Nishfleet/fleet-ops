# Metrics drop-in mechanism match for #7072

Issue #7072 asks to file or match a mechanism for the manual repair in #2920.
The existing mechanism is PR #2937, merge commit
`6f0d578afbd9228561c68c4746e04f97a9b7e18d`. No new runtime code is needed.

## Existing check

`bin/fleet-ops-drift.py::check_metrics_export_dropins` reads the expected
metrics-export drop-ins from `origin/main:MANIFEST`, not the checkout's
working files. It runs before the checkout guard, so an off-main checkout
cannot hide a missing drop-in behind that guard's early exit.

A missing drop-in triggers `DRIFT-METRICS-DROPIN` and files a repair issue.
The marker `metrics-export-dropin-missing: fleet-ops#2920` deduplicates reports.
The original repair and its cause are recorded in PR #2937.

## Verification

Checked on 2026-09-17 at 14:03 UTC from branch `claim/issue-7072`, based on
`273dc57baf3fdad252fb863d19d8017e2d5c8350`.

- `git merge-base --is-ancestor 6f0d578afbd9228561c68c4746e04f97a9b7e18d origin/main`
  passed. The original mechanism is on main.
- `bash tests/fleet-ops-drift-metrics-dropin.test.sh` passed all three cases:
  missing drop-in fails and files, present drop-in does not fire, and an
  existing report prevents a duplicate.
- Called `check_metrics_export_dropins(Path.cwd())` against the live user unit,
  with fetch, issue filing, and closure disabled and its audit log in `/tmp`.
  Result: `all 8 fleet-metrics-export drop-ins present in live unit`.
- Both `intake-effectiveness.conf` and `scout-effectiveness.conf` exist under
  `~/.config/systemd/user/fleet-metrics-export.service.d/`.
- `systemctl --user cat fleet-metrics-export.service` includes both commands.
  `systemctl --user show ... -p ExecStart` independently confirms both are in
  the manager's loaded configuration, not just files on disk.
- The local node-exporter endpoint returned
  `fleet_intake_effectiveness_last_run_seconds 1.789653699962e+09` and
  `fleet_scout_effectiveness_last_run_seconds 1.789653401e+09` at 14:02 UTC.
  Both observations were within six minutes of the check.

This receipt matches #7072 to the existing detector and regression test.
It does not install files, reload units, or change the check.
