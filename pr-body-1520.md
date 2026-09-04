## Why

nish-memory-curator.service used to print the full `trust_denials.entries`
list (~40KB, 101 dispositioned denials) to the journal every 5 minutes.
That was ~11MB/day of noise and it poisoned broad `journalctl` greps
during incident triage.

The stdout cap shipped in nish3451/memory-compound#9 (merge be8c9db,
2026-08-30). That PR said `Relates to fleet-ops#1520` instead of
`Closes Nishfleet/fleet-ops#1520`, so GitHub never closed this tracker.
The live unit has been journal-safe since then. This PR is the fleet-ops
class lock so a revert of `journal_safe_status` fails CI here, and so
the merged PR can close the tracker.

## Scope

- `tests/curator-journal-cap.test.sh`: imports live `memoryctl.journal_safe_status`,
  proves entries are emptied, `entries_capped` is recorded, and the original
  status dict is not mutated (health-file write still gets the full list).
  On the VPS it also asserts the live curator journal line is under 2KiB
  with `entries: []` while `curator-health.json` still holds 101 entries.
  Hosted CI skips when memoryctl / the user journal / the vault health
  file are absent.
- Hosted from `tests/ci-standards-audit.test.sh` (already listed in ci.yml).
- Named pin in `tests/p14-test-listing-gate.test.sh` so dropping the host
  or parking the test on `known_orphans` fails by name.

Out of scope: the memory-compound helper itself (already on main).

## Blast radius

The lock-test is read-only. It imports `journal_safe_status` and reads
journalctl + `curator-health.json`. It does not start the curator, write
the vault, or change the unit. A revert of the helper fails the offline
layer in CI. A hosted runner without memory-compound skips rather than
failing P14.

## Verification

```
$ bash tests/curator-journal-cap.test.sh
OK: 1: journal_safe_status empties entries, records entries_capped=101, leaves original intact
live_bytes=467 entries=[] entries_capped=101 total=101
OK: 2a: live curator stdout is journal-safe (467 bytes)
health_bytes=43203 entries=101
OK: 2b: curator-health.json still holds the full entries list
OK: curator-journal-cap.test.sh

$ CURATOR_JOURNAL_CAP_LIVE=0 bash tests/curator-journal-cap.test.sh
OK: 1: journal_safe_status empties entries, records entries_capped=101, leaves original intact
OK: 2: live layer skipped (CURATOR_JOURNAL_CAP_LIVE=0)
OK: curator-journal-cap.test.sh

$ MEMORYCTL=/no/such/memoryctl.py bash tests/curator-journal-cap.test.sh
OK: memoryctl absent (/no/such/memoryctl.py) — hosted skip
OK: curator-journal-cap.test.sh

$ bash tests/p14-test-listing-gate.test.sh
OK: curator-journal-cap.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#1520)
OK: p14-test-listing-gate.test.sh: P14 test list is closed
(all 358 test files accounted for)

$ sgscan --base origin/main
No new security findings.
```

A missing-helper fixture (`journal_safe_status` absent, then a no-op
passthrough) exits 1 as required. The first live-layer run failed with
`SyntaxError: unexpected character after line continuation character`
in a `python3 -c` string; that quoting is now a heredoc.

run-proof: journalctl --user -u nish-memory-curator.service -o cat --since "2 hours ago" — latest curate JSON is 467 bytes, trust_denials.entries=[], entries_capped=101, total=101, dispositioned=101, classes intact. curator-health.json is 43203 bytes with 101 entries.

loose-ends-canary: pr:nishfleet/fleet-ops#pending stale-worker-pr

Closes #1520
