# Verification for issue #1485

## Issue
tests/pi-issue-start-packet-regen.test.sh not registered in ci.yml (ci-standards-audit fails on main)

## Verdict
Already fixed on main. No code change needed.

The test `tests/pi-issue-start-packet-regen.test.sh` was added in #1481
(commit 2d62250) without ci.yml registration, which made
`tests/ci-standards-audit.test.sh` exit 1 on a clean main checkout. PR #2097
(commit 7df0183, merged 2026-08-29) recreated `.github/workflows/ci.yml` and
registered the test. On main HEAD 8c71d67 the test is listed at ci.yml line
208 and the audit is green for this specific complaint.

## Evidence (live, on main HEAD 8c71d67)

- `git rev-parse HEAD` -> `8c71d674448007d26be0a0dde0b9e5d881ce3638`
- `grep -n "pi-issue-start-packet-regen" .github/workflows/ci.yml` ->
  `208:        bash tests/pi-issue-start-packet-regen.test.sh`
- `git blame -L 208,208 origin/main -- .github/workflows/ci.yml` ->
  `^7df0183 (Nish 2026-08-29 ... 208) bash tests/pi-issue-start-packet-regen.test.sh`
- `bash tests/pi-issue-start-packet-regen.test.sh` ->
  `all pi-issue-start-packet-regen cases passed`, exit 0
- `bash tests/p14-test-listing-gate.test.sh` ->
  `all 287 test files accounted for (listed+hosted: 263, live skip: 7, known orphan: 17)`, exit 0

## Note on the audit's current state

`bash tests/ci-standards-audit.test.sh` on main HEAD 8c71d67 exits 1, but on
a DIFFERENT unregistered test introduced later by #2167
(`memory-index-autocompact-migrated.test.sh`). That is a separate finding
filed as #2172 — same bug class as #1485 (worker/App PR cannot push to
`.github/workflows/**`). It is out of scope for #1485 and not fixed here.

## Why a PR (and not just a comment)

A worker cannot `gh issue close` (worker rule; the merged PR closes it).
#2097 did not reference #1485, so neither GitHub auto-close nor the
`fleet-merged-pr-close` observe-to-close helper (which matches a merged PR
that references the issue by `#<N>`) fires — the issue was re-claimed every
heartbeat tick (5+ claim/release rounds on 2026-08-30). This PR carries
`Closes #1485` so the merge closes the loop and breaks the re-claim cycle.
The change is paper only (this file); no machinery is added.
