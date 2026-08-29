## Summary

The fix for #1278 shipped in #1363 (commit 4f51c7a): explicit kB→GB/MB→GB unit conversions in `ram_governor_cap`, a sanity assertion that fails loud at cap >= 64, and `tests/ram-metric-compare.test.sh` scenario 8 proving that assertion.

That PR used `fleet-ops#1278` in the title and body, so the issue stayed open. This close-only PR adds the missing `Closes #1278` linkage.

## Scope

No file changes. The fix, test, and sanity assertion are already on `main`. This is a close-only PR.

## Verification

The live fix has already been verified on this box:

```
$ bash tests/ram-metric-compare.test.sh
OK: 1. #202 fixture flags mismatch, records both p95s, leaves ram_gb_per_worker alone
OK: 2. equal memory.current and VmRSS report mismatch=0
OK: 3. zero units exit 0 and write state
OK: 4. admission formula is 0.5 G from cap map, no self-calibrate
OK: 5. 35 MB is labelled process VmRSS; memory.current + #202 are recorded
OK: 6. heartbeat section 14 and MANIFEST wire ram-metric-compare
OK: 7. activating oneshot + named properties (not --value order)
OK: 8. ram_governor_cap fails loud when a unit slip yields cap >= 64

ALL OK

$ bash -n lib/seat-lib.sh tests/ram-metric-compare.test.sh
$ bash tests/same-repo-closes-gate.test.sh
OK: same-repo-closes-gate drill: REJECT same-repo short-owner and silent-bare-missing, PASS bare/fully-qualified/cross-repo/prose-when-closed
```

`ram_governor_cap` on this box now returns a sane cap under the configured `ram_gb_per_worker=0.5`.

Closes #1278
