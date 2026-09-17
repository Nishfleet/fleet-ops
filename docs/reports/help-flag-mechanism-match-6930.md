# Help-flag mechanism match for #6930

Issue #6930 asks to file or match a mechanism for the help-flag repair
recorded for #2889. The existing fix is PR #2927, which GitHub reports
merged on 2026-09-02 at 20:19:33 UTC with merge commit
`754d364d0b49957a76a7fc11cea649ab296239cd`.

## Existing mechanism

`bin/lifecycle-label-sweep` and `bin/fleet-stale-auto-revert-sweep`
handle `--help` and `-h` before live side effects.
`tests/fleet-help-flag-runs-live.test.sh` invokes both scripts with both
flags, checks usage and exit zero, and checks that their scratch lock
directories remain empty. It also covers the audit and researcher scripts.

The test is called by `tests/ci-standards-audit.test.sh`, which is listed
in `.github/workflows/ci.yml`. This is an existing regression guard, not a
new checker needed for this audit finding.

## Verification

On 2026-09-17, at current main commit
`2e5f32358546a70af56ed6b2410497cbb6fde032`:

- `bash tests/fleet-help-flag-runs-live.test.sh` exited 0. All four scripts
  printed usage for both flags without creating entries in their scratch
  state or lock directories. Final output: `OK: help-flag-runs-live guard green`.
- Source inspection confirmed the existing CI host above.
- Historical merge ancestry returned 1 in this shallow checkout. This
  receipt relies on the current source and test run, not an ancestry claim.
- The full `tests/ci-standards-audit.test.sh` run timed out twice, after
  120 and 100 seconds. No full-suite pass is claimed.

This report matches #6930 to #2889 / PR #2927 and its regression guard.
It changes no executable, test assertion, workflow, unit, or installed file.
